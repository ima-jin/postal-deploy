# postal-deploy
Imajin's small, pinned Postal image and build/deployment pipeline. The narrow
authenticated admin endpoint is separate work in #2; this repository does not
change Postal, DNS, MariaDB, RabbitMQ, or mailbox providers.

## Upstream
`Dockerfile` has one `FROM` line: Postal **3.3.6**, pinned to the exact digest
already running in production. The first deployment changes no upstream code.
To bump upstream, change that one line (version **and** verified digest) in a PR.
CI builds Linux amd64, matching the current host.

## Build and deploy
PRs run offline acceptance tests, actionlint, and a Docker build. They do not
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
No `POSTAL_ADMIN_TOKEN` is needed until #2.

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
`bash -n scripts/deploy.sh scripts/deploy-ssh.sh`, and `docker build .`.
Tests mock Docker/curl to cover successful deployment, exact-image rollback,
partial startup/pull/health failures, non-200 responses, validation, locking,
SSH trust boundaries, main-only publishing, and dev-before-production gating.
An offline real-Compose configuration test also verifies that both deployment
and rollback overrides change only the selected images, not dependencies,
commands, mounts, MariaDB, or RabbitMQ.
