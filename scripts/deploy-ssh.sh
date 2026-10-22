#!/usr/bin/env bash
set -euo pipefail

for name in POSTAL_HOST POSTAL_USER POSTAL_COMPOSE_DIR POSTAL_SERVICES POSTAL_HEALTH_URL POSTAL_IMAGE POSTAL_DEPLOY_SSH_KEY POSTAL_SSH_KNOWN_HOSTS; do
  if [[ -z ${!name:-} ]]; then
    printf 'Missing required configuration: %s\n' "$name" >&2
    exit 1
  fi
done
[[ $POSTAL_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || exit 1
[[ $POSTAL_USER =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || exit 1
port=${POSTAL_PORT:-22}
[[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port > 0 && 10#$port <= 65535)) || exit 1

umask 077
ssh_dir=$(mktemp -d)
trap 'rm -rf -- "$ssh_dir"' EXIT
# Never enable shell tracing here. Values arrive only through the secret env.
printf '%s\n' "$POSTAL_DEPLOY_SSH_KEY" > "$ssh_dir/key"
printf '%s\n' "$POSTAL_SSH_KNOWN_HOSTS" > "$ssh_dir/known_hosts"
unset POSTAL_DEPLOY_SSH_KEY POSTAL_SSH_KNOWN_HOSTS
remote_command=$(python3 - <<'PY'
import os
import shlex
print(shlex.join(["bash", "-s", "--", *(
    os.environ[name] for name in
    ("POSTAL_IMAGE", "POSTAL_COMPOSE_DIR", "POSTAL_SERVICES", "POSTAL_HEALTH_URL")
)]))
PY
)
ssh -T -p "$port" -i "$ssh_dir/key" \
  -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$ssh_dir/known_hosts" -o ConnectTimeout=15 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  "$POSTAL_USER@$POSTAL_HOST" "$remote_command" < scripts/deploy.sh
