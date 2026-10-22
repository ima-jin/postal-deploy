#!/usr/bin/env bash
# Runs on the target via SSH; changes only Imajin-managed override files.
set -euo pipefail
umask 077

[[ $# == 4 ]] || { printf 'Expected image, compose directory, services, health URL\n' >&2; exit 1; }
image=$1
compose_dir=$2
service_names=$3
health_url=$4
[[ $image =~ ^ghcr\.io/ima-jin/postal-deploy:[a-f0-9]{40}$ ]] || exit 1
[[ $compose_dir == /* && -d $compose_dir && -f $compose_dir/docker-compose.yml ]] || exit 1
[[ $health_url =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]{1,5})?/login$ ]] || exit 1
[[ $service_names != *$'\n'* ]] || exit 1
read -r -a services <<< "$service_names"
(( ${#services[@]} > 0 )) || exit 1
declare -A seen=()
for service in "${services[@]}"; do
  [[ $service =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ && -z ${seen[$service]:-} ]] || exit 1
  seen[$service]=1
done

cd -- "$compose_dir"
# Also protects against another runner/operator invoking this script.
exec 9>.postal-deploy.lock
flock -n 9 || { printf 'Another deployment is active\n' >&2; exit 1; }
base=(docker compose -f docker-compose.yml)
override=docker-compose.imajin.yml
rollback=docker-compose.imajin.rollback.yml
compose=("${base[@]}" -f "$override")
previous=$(mktemp .postal-previous.XXXXXX)
candidate=$(mktemp .postal-candidate.XXXXXX)
trap 'rm -f -- "$previous" "$candidate"' EXIT
printf 'services:\n' > "$previous"
printf 'services:\n' > "$candidate"

# Snapshot actual local image IDs, not a mutable tag (including first deploy).
# Refuse missing/stopped or replicated services before changing anything.
for service in "${services[@]}"; do
  containers=$("${base[@]}" ps --status running -q "$service")
  [[ -n $containers && $containers != *$'\n'* ]] || {
    printf 'Expected one running container per selected service\n' >&2; exit 1;
  }
  previous_image=$(docker inspect --format '{{.Image}}' "$containers")
  [[ $previous_image =~ ^sha256:[a-f0-9]{64}$ ]] || exit 1
  printf '  %s:\n    image: "%s"\n' "$service" "$previous_image" >> "$previous"
  printf '  %s:\n    image: "%s"\n' "$service" "$image" >> "$candidate"
done

# Validate before replacing our override; never modify the operator's files.
"${base[@]}" -f "$candidate" config --quiet
mv -- "$previous" "$rollback"
rollback_on_exit() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then
    printf 'Deployment failed; restoring previous image IDs\n' >&2
    cp -- "$rollback" "$override"
    if ! "${compose[@]}" up -d --no-deps --no-build --pull never "${services[@]}"; then
      printf 'CRITICAL: rollback failed; operator intervention required\n' >&2
    fi
  fi
  rm -f -- "$previous" "$candidate"
  exit "$status"
}
trap rollback_on_exit EXIT
trap 'exit 1' HUP INT TERM
mv -- "$candidate" "$override"
"${compose[@]}" pull "${services[@]}"
"${compose[@]}" up -d --no-deps --no-build --pull never "${services[@]}"
for ((attempt=1; attempt<=30; attempt++)); do
  # Do not follow redirects: /login must itself return 200.
  code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 10 "$health_url") || code=000
  if [[ $code == 200 ]]; then
    printf 'Deployment healthy\n'
    exit 0
  fi
  sleep 2
done
printf 'Health check failed\n' >&2
exit 1
