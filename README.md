# postal-deploy
Imajin's small, pinned Postal image, authenticated domain admin API, and
build/deployment pipeline. The additive API uses Postal's application models;
it does not change DNS, RabbitMQ, or mailbox providers.

## Upstream
`Dockerfile` has one `FROM` line: Postal **3.3.6**, pinned to the exact digest
already running in production. A `COPY` adds only Imajin's controller, routes and
initializer; no upstream source file is replaced and there is no upstream fork.
To bump upstream, change that one line (version **and** verified digest) in a PR.
CI builds Linux amd64, matching the current host.

## Build and deploy
PRs run offline acceptance tests, actionlint, a Docker build, and request tests
against that built image with an isolated MariaDB. They do not
publish or deploy and never receive deployment credentials.
A main push passes those same checks, then publishes
`ghcr.io/ima-jin/postal-deploy:<full-commit-sha>` and `:main` using `GITHUB_TOKEN`.
Deploy uses the full SHA tag, never the moving `:main` tag.

A successful **main push** CI run triggers `deploy-dev` in environment `dev`.
Only after it succeeds does `deploy-prod` enter environment `production`, whose
existing required reviewer is **veteze (Ryan)**. Do not remove that protection.
Both jobs check out the exact built commit. Failed CI, PR runs (including forks),
and other branches cannot trigger a deploy. Deployments serialize across the
whole dev → production gate sequence and are not canceled mid-deploy.

The runner uses SSH noninteractively with pinned host verification. On each
target, `scripts/deploy.sh`:
1. Locks the compose directory and snapshots the actual running image IDs for
   each selected service, including the initial deployment from upstream `latest`.
2. Validates an image-only override, then writes `docker-compose.imajin.yml`;
   it never rewrites `docker-compose.yml` or `postal.yml`.
3. Pulls the selected services and runs compose `up -d --no-deps --no-build
   --pull never`, leaving database/broker services untouched.
4. Checks the configured `/login` for HTTP **200**, without redirects, up to
   30 attempts (2 seconds between attempts; 10 seconds maximum per request).
5. On pull, startup, or health failure, restores the previous local image IDs
   and re-ups only the selected services without pulling. The job stays failed.
   A rollback failure reports `CRITICAL` and requires operator intervention.

Deployment apply invocations use `-f docker-compose.yml -f <managed override>`; host
and directory are not baked into workflows. The compose project must match the
existing installation: the directory's basename is the default project name
(production is `postal`), or set `COMPOSE_PROJECT_NAME` in the host's existing
compose environment. Each selected service must already have exactly one
running container; missing, stopped, or replicated services fail before changes.

## Configuration and provisioning
Jin provisions **all secrets through the kernel vault/seal tools**. This PR and
its workflows never mint credentials, seal tokens, or set repository secrets.
For the admin API, Jin supplies `POSTAL_ADMIN_TOKEN` to the Postal web container
at runtime, or mounts a read-only token file readable by the `postal` user and
sets `POSTAL_ADMIN_TOKEN_FILE` to its absolute in-container path. No workflow
provisions tokens. The mounted file takes precedence (surrounding whitespace is
stripped); missing/unreadable/empty/oversized (>8192 bytes) files fail closed,
even when the environment token is set. An unset/empty token disables API access
(401). Values are read on each request, so rotation needs no image rebuild.
Do not include tokens in URLs, command arguments, fixtures, application config
committed to git, or reverse-proxy logs. Use TLS and restrict network access to
the kernel; this is a node-wide administrative credential, not an org-user token.
Browser sessions and Postal send-API credentials do not authorize these routes.
The existing deployment workflow and operator's compose files are unchanged;
mounting/injecting this runtime secret remains an operator/vault step.

| Name | Kind / scope | Purpose |
| --- | --- | --- |
| `GITHUB_TOKEN` | GitHub-provided token, CI | Publish GHCR on main only; `packages: write`. |
| `POSTAL_DEPLOY_SSH_KEY` | Secret, each environment | Existing least-privilege SSH deployment identity. |
| `POSTAL_SSH_KNOWN_HOSTS` | Secret, each environment | Independently verified OpenSSH known-hosts entry; include `[host]:port` for a nondefault port. Never trust `ssh-keyscan` during deployment. |
| `POSTAL_HOST` | Var, each environment | Target DNS name or IPv4 address; no URL or shell syntax. |
| `POSTAL_USER` | Var, each environment | SSH user allowed to run compose and Docker, and write managed files in the compose directory. |
| `POSTAL_PORT` | Optional var, each environment | SSH port 1–65535; defaults to 22. |
| `POSTAL_COMPOSE_DIR` | Var, each environment | Absolute path containing the existing `docker-compose.yml`. |
| `POSTAL_SERVICES` | Var, each environment | Space-separated **only Postal web/worker/smtp service names** from that compose file. Never include MariaDB or RabbitMQ. |
| `POSTAL_HEALTH_URL` | Var, each environment | Target-specific `https://host[:port]/login` (HTTP permitted for LAN-only dev). No credentials, query, or fragment. It is checked from the Postal host. |
| `POSTAL_DEPLOY_RUNNER` | Optional **repository** var | Runner label used for both deploy jobs, defaults to `ubuntu-latest`. Set a dedicated self-hosted runner label if approved LAN access is needed. PR CI always runs on GitHub-hosted runners. |

Before enabling live deployment, Jin must resolve dev placement and SSH access
from the open decision cards on ima-jin/imajin-ai#3059, then populate both
environments. No choice is silently made by this PR. A LAN-only dev target needs
an appropriately reachable deploy runner. If using a forced-command SSH key,
its host-side policy must explicitly support the reviewed `bash -s -- ...`
protocol; an arbitrary restricted command will fail closed, not bypass it.
The deploy user needs Bash 4+, Docker Compose v2, curl, flock, coreutils, enough
disk, and outbound GHCR access. It must be able to pull the package: either Jin
makes GHCR package visibility public or provisions host-side read access through
the same vault/seal process. The workflow does not transmit a registry credential.
Keep previous local images; do not prune them during deployment/rollback.
Protect `main` with the CI test/build checks; require production approval.

## Rollback
Automatic rollback needs no operator SSH session and keeps the original files.
`docker-compose.imajin.rollback.yml` records the last pre-deploy local image IDs
per service. It is replaced only after the next snapshot validates.
For an ordinary operator rollback without host edits, revert the faulty main
commit via PR: CI publishes the reverted code at a new SHA, dev verifies it, then
Ryan approves production. For an emergency host recovery, use the recorded
rollback override with compose `up -d --no-deps --no-build --pull never` for
the selected Postal services, then restore the managed active override to it.
Do not edit the operator's original compose/config files or pull local image IDs.

## Verification
No browser or live-host tests are required. This repo has no Node package,
`pnpm test:agent`, or SonarCloud project; Sonar is **n/a**, not a fake green gate.
Run the full native suite with `python3 -m unittest discover -s tests -v`,
lint both workflows with actionlint 1.7.7, run
`bash -n scripts/deploy.sh scripts/deploy-ssh.sh scripts/test-admin.sh`, and
`docker build .`. Also run the in-container acceptance command below.
Tests mock Docker/curl to cover successful deployment, exact-image rollback,
partial startup/pull/health failures, non-200 responses, validation, locking,
SSH trust boundaries, main-only publishing, and dev-before-production gating.
An offline real-Compose configuration test also verifies that both deployment
and rollback overrides change only the selected images, not dependencies,
commands, mounts, MariaDB, or RabbitMQ.

## Domain admin API (kernel contract)
All requests require `Authorization: Bearer <runtime-token>`. Responses are JSON
with `Cache-Control: no-store`. Authentication uses a constant-time comparison
of fixed-size SHA-256 digests, before organization/domain lookup. No API action
sets a browser cookie or bypasses ownership verification.

The organization must already exist in Postal: `organization` is its **permalink**
(not its display name, numeric ID or kernel org ID). The kernel maintains this
mapping; this API does not create organizations or mail servers. Domains belong
to the organization, as in Postal's organization-domain UI. Existing Postal
servers in that organization can use organization domains according to Postal's
normal rules; provisioning a server/credential is outside this API.

- `POST /imajin/v1/domains`, JSON body
  `{"organization":"acme","name":"example.org"}`: **201** for a new domain,
  **200** for an existing `(organization, name)`. Creation uses
  `organization.domains.create!` with `verification_method: "DNS"`; Postal
  generates the ownership TXT and DKIM keys. No automatic admin verification.
  Concurrent API retries serialize using the organization model's row lock;
  a retry returns the same domain UUID, ownership record and public DKIM key.
- `GET /imajin/v1/domains/example.org?organization=acme`: **200**, read-only,
  returns the latest persisted records/state. Does not perform DNS queries.
- `POST /imajin/v1/domains/example.org/check?organization=acme`: **200**,
  runs Postal's `verify_with_dns` (if not already ownership-verified) followed
  by `check_dns(:manual)` and returns the new persisted state. An authenticated
  kernel service, not an end-user browser, calls this; no CSRF/session is needed.

Names are lowercased, must contain at least two ASCII DNS labels (punycode is
accepted), at most 253 bytes total and 63 bytes per label, with letters/digits
and interior hyphens only. No wildcards, URL, empty labels or trailing dot.
Organization permalinks use lowercase letters/digits and interior hyphens,
at most 255 bytes. Extra input fields are ignored, never mass-assigned:
clients cannot choose owners, keys, verification timestamps, or DNS statuses.

All three success responses share these fields:
- `organization`, `name`, `id`: Postal permalink, canonical domain, Postal UUID.
- `state`: `"verified"` only when Postal `verified? && dns_ok?`, else `"pending"`.
- `ownership_verified`, `dns_ok`: independent booleans. `verified_at` and
  `dns_checked_at` are ISO-8601 UTC timestamps or `null`.
- `records`: an array of `{kind,type,name,value,required,status,error}` objects.
  `name` is always a full DNS name; values are exact Postal model/config values.
  `error` is Postal's checker message or `null`, not a fabricated local verdict.
  `status` is `"Unchecked"` before DNS checks; afterwards it preserves Postal's
  `"OK"`, `"Missing"` or `"Invalid"`. Ownership is `"Pending"` or `"OK"`.
  Records are:
  - `ownership`: required TXT at the domain, `domain.dns_verification_string`.
    Publish this as well as SPF/DKIM: correct sending records alone do not prove
    domain ownership. Postal retains ownership verification once established.
  - `spf`: required TXT at the domain, `domain.spf_record`, with an extra
    `include` field (`"include:" + Postal::Config.dns.spf_include`). **Merge this
    include into the existing SPF record**, do not add a second SPF TXT or
    overwrite an existing mailbox provider's SPF policy.
  - `dkim`: required TXT at `<domain.dkim_record_name>.<domain>`,
    `domain.dkim_record` (public key only; private keys are never serialized).
  - `return_path`: optional CNAME at `domain.return_path_domain`, pointing to
    `Postal::Config.dns.return_path_domain`.
  - `mx`: optional MX entries at the domain for each configured Postal MX host,
    with `priority: 10`. These describe optional Postal **inbound** mail setup;
    **do not publish them for outbound-only onboarding** or change existing
    mailbox-provider MX records. No route is created or required by this API.

Overall readiness follows Postal 3.3.6: SPF and DKIM must be `OK`; MX and
return-path may be `OK` or `Missing`, but not `Invalid`. Therefore an existing
mailbox provider's MX is compatible with sending. Return-path is recommended
for alignment but optional under Postal's own checker. A later sending-record
failure returns `pending` even when ownership was previously verified.
GET returns cached state; callers choose when to run `/check` and should poll
with backoff while DNS propagates. This API never writes DNS.

Error responses are `{"error":"<code>"}`:
- **400** `invalid_json`: malformed JSON body.
- **401** `unauthorized`: missing/wrong/malformed bearer credential, or unavailable
  runtime secret. Includes `WWW-Authenticate: Bearer`; no token is returned/logged.
- **404** `not_found`: organization missing/soft-deleted, domain missing in that
  organization (never a global domain lookup).
- **409** `organization_suspended`: organization is suspended.
- **422** `invalid_request`: missing/invalid organization or domain input;
  `invalid_domain`: rejected by Postal's model validation.
- **503** `dns_unavailable`: Postal DNS resolver raises a resolver/timeout error;
  retry with backoff. Postal may instead record a `Missing` state for an
  unanswered DNS query; inspect record statuses as well as HTTP status.

Only the three listed routes exist: no update/delete, mailbox or route API.
Only newly created DNS-verification domains are intended for this onboarding
flow; the API does not migrate pre-existing email-verification domains.

### In-container acceptance tests
After `docker build -t postal-admin:local .`, run
`bash scripts/test-admin.sh postal-admin:local`. Docker must be available.
The script starts MariaDB 11.4 on a private internal Docker network with no host
port, loads Postal's shipped schema into a **new disposable `postal_test` DB**
(historical upstream migrations are incompatible with current Rails), and runs
`tests/admin/domains_test.rb` inside the built image in production Rails mode.
Schema loading's production guard override is confined to this isolated test
container, never deployment. No live host, broker, DNS credentials, or runtime
admin secret is required. Test-only credentials are ephemeral in the Ruby
process, never committed or passed on the shell command line.
DNS transport is deterministic; real Rails requests, model validations,
ownership verification, DKIM generation and Postal DNS checker persistence run.
CI runs this same script after building/loading the exact commit-tagged image.
