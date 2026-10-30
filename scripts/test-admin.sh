#!/usr/bin/env bash
# Disposable, network-isolated test database; never connects to a live host.
set -euo pipefail
image=${1:?usage: scripts/test-admin.sh IMAGE}
root=$(cd "$(dirname "$0")/.." && pwd)
network="postal-admin-test-$$"
database="${network}-db"
cleanup() {
  docker rm -f "$database" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create --internal "$network" >/dev/null
docker run -d --name "$database" --network "$network" --network-alias database \
  -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=postal_test \
  mariadb:11.4 >/dev/null
ready=false
for _ in {1..60}; do
  if docker exec "$database" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  printf 'Test MariaDB did not become ready\n' >&2
  exit 1
fi
docker run --rm --network "$network" --entrypoint bash \
  -e MAIN_DB_HOST=database -e MAIN_DB_USERNAME=root -e MAIN_DB_DATABASE=postal_test \
  -e RAILS_ENVIRONMENT=production -e SILENCE_POSTAL_CONFIG_MESSAGES=true \
  -v "$root/tests/admin:/imajin-tests:ro" "$image" -c \
  'DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rake db:schema:load > /tmp/schema.log 2>&1 || { cat /tmp/schema.log; exit 1; }
   bundle exec ruby /imajin-tests/domains_test.rb'
