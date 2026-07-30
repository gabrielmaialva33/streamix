#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compose_file="${1:-${project_root}/deploy/docker-compose.production.yml}"
runtime_env=$(mktemp)
rendered_config=$(mktemp)

cleanup() {
  rm -f "${runtime_env}" "${rendered_config}"
}

trap cleanup EXIT

if [ ! -f "${compose_file}" ]; then
  echo "[compose] missing production compose: ${compose_file}" >&2
  exit 1
fi

cat >"${runtime_env}" <<'EOF'
DB_PASSWORD=test-only
RABBITMQ_USERNAME=streamix
RABBITMQ_PASSWORD=test-only
RABBITMQ_VHOST=/
PHX_SERVER=true
DATABASE_URL=ecto://streamix:test-only@postgres/streamix_prod
REDIS_URL=redis://redis:6379
QDRANT_URL=http://qdrant:6333
RABBITMQ_HOST=rabbitmq
EOF

STREAMIX_ENV_FILE="${runtime_env}" \
  STREAMIX_IMAGE="ghcr.io/gabrielmaialva33/streamix@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  docker compose --env-file "${runtime_env}" -f "${compose_file}" config \
  --format json >"${rendered_config}"

expected_services=$'postgres\nqdrant\nrabbitmq\nredis\nstreamix'
actual_services=$(jq -r '.services | keys[]' "${rendered_config}" | LC_ALL=C sort)

if [ "${actual_services}" != "${expected_services}" ]; then
  echo "[compose] unexpected production services:" >&2
  printf '%s\n' "${actual_services}" >&2
  exit 1
fi

jq -e '
  .name == "streamix" and
  .networks.shared_network.external == true and
  .services.streamix.image
    == "ghcr.io/gabrielmaialva33/streamix@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and
  (.services.postgres.command
    | any(. == "shared_preload_libraries=timescaledb,pg_stat_statements"))
' "${rendered_config}" >/dev/null

for service in postgres qdrant rabbitmq redis streamix; do
  if [ "$(jq -r --arg service "${service}" '.services[$service].restart' "${rendered_config}")" != "unless-stopped" ]; then
    echo "[compose] ${service} must use restart: unless-stopped" >&2
    exit 1
  fi
done

echo "[compose] production contract is valid"
