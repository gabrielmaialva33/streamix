#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${IMAGE_DIGEST:?IMAGE_DIGEST is required}"
: "${PRODUCTION_COMPOSE_B64:?PRODUCTION_COMPOSE_B64 is required}"
: "${PRODUCTION_COMPOSE_SHA256:?PRODUCTION_COMPOSE_SHA256 is required}"

DEPLOY_BASE_URL="${DEPLOY_BASE_URL:-https://streamix.mahina.fun}"
EXPECTED_REVISION="${EXPECTED_REVISION:-}"
DEPLOY_PREFLIGHT_ONLY="${DEPLOY_PREFLIGHT_ONLY:-false}"

if [[ ! "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[deploy] invalid image digest: ${IMAGE_DIGEST}" >&2
  exit 2
fi

cd /opt/streamix

image_ref="${IMAGE_NAME}@${IMAGE_DIGEST}"
legacy_compose="/opt/streamix/docker-compose.yml"
production_compose="/opt/streamix/docker-compose.production.yml"
compose_state="/opt/streamix/.docker-compose.production.sha256"
compose_candidate=$(mktemp /opt/streamix/.docker-compose.production.XXXXXX)
compose_backup=""
compose_state_backup=""
had_versioned_compose=false
candidate_installed=false
validated_compose_hash=""
previous_image=$(docker inspect -f '{{.Image}}' streamix 2>/dev/null || true)
readiness_body=$(mktemp)
manifest_headers=$(mktemp)
auth_body=$(mktemp)

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  rm -f "${readiness_body}" "${manifest_headers}" "${auth_body}" "${compose_candidate}"
}

trap cleanup EXIT

compose() {
  local image="$1"
  shift

  STREAMIX_IMAGE="${image}" \
    STREAMIX_ENV_FILE="/opt/streamix/.env" \
    docker compose --env-file /opt/streamix/.env -f "${production_compose}" "$@"
}

restore_compose_contract() {
  if [ "${had_versioned_compose}" = true ]; then
    cp -p "${compose_backup}" "${production_compose}"

    if [ -n "${compose_state_backup}" ]; then
      cp -p "${compose_state_backup}" "${compose_state}"
    else
      rm -f "${compose_state}"
    fi
  else
    rm -f "${production_compose}" "${compose_state}"
  fi

  candidate_installed=false
}

rollback() {
  echo "[deploy] FAIL: ${1}"
  docker logs --tail 200 streamix || true

  if [ "${candidate_installed}" = true ]; then
    restore_compose_contract
  fi

  if [ -n "${previous_image}" ]; then
    echo "[deploy] rolling back to ${previous_image}"
    docker tag "${previous_image}" "${IMAGE_NAME}:latest"

    if [ "${had_versioned_compose}" = true ]; then
      compose "${IMAGE_NAME}:latest" up -d --force-recreate --remove-orphans streamix
    else
      docker compose -f "${legacy_compose}" up -d --force-recreate --remove-orphans streamix
    fi
  fi

  exit 1
}

normalize_compose() {
  local source_file="$1"

  STREAMIX_IMAGE="${image_ref}" \
    STREAMIX_ENV_FILE="/opt/streamix/.env" \
    docker compose --env-file /opt/streamix/.env -f "${source_file}" config --format json |
    jq -S '
      del(.name) |
      del(.services.streamix.image) |
      .services |= with_entries(
        .value.environment = ((.value.environment // {}) | keys)
      )
    '
}

preflight_compose() {
  local env_mode expected_services actual_services
  local active_compose normalized_active normalized_candidate recorded_hash
  local required_env_key required_env_value

  for command_name in base64 docker jq sha256sum; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "[deploy] required command is missing: ${command_name}" >&2
      exit 1
    fi
  done

  if [ ! -f /opt/streamix/.env ]; then
    echo "[deploy] missing /opt/streamix/.env" >&2
    exit 1
  fi

  env_mode=$(stat -c '%a' /opt/streamix/.env)
  if [ $((8#${env_mode} & 077)) -ne 0 ]; then
    echo "[deploy] /opt/streamix/.env must not be group/world accessible" >&2
    exit 1
  fi

  for required_env_key in \
    DATABASE_URL \
    DB_PASSWORD \
    LIVE_VIEW_SIGNING_SALT \
    PHX_HOST \
    PROVIDER_ENCRYPTION_KEY \
    RABBITMQ_PASSWORD \
    RABBITMQ_USERNAME \
    REDIS_URL \
    SECRET_KEY_BASE; do
    required_env_value=$(
      sed -n "s/^[[:space:]]*${required_env_key}=//p" /opt/streamix/.env |
        tail -n 1
    )

    if [ -z "${required_env_value//[[:space:]]/}" ] ||
      [ "${required_env_value}" = '""' ] ||
      [ "${required_env_value}" = "''" ]; then
      echo "[deploy] /opt/streamix/.env is missing ${required_env_key}" >&2
      exit 1
    fi
  done

  printf '%s' "${PRODUCTION_COMPOSE_B64}" | base64 --decode >"${compose_candidate}"
  validated_compose_hash=$(sha256sum "${compose_candidate}" | awk '{print $1}')

  if [ "${validated_compose_hash}" != "${PRODUCTION_COMPOSE_SHA256}" ]; then
    echo "[deploy] production compose checksum mismatch" >&2
    exit 1
  fi

  chmod 0644 "${compose_candidate}"

  STREAMIX_IMAGE="${image_ref}" \
    STREAMIX_ENV_FILE="/opt/streamix/.env" \
    docker compose --env-file /opt/streamix/.env -f "${compose_candidate}" config --quiet

  expected_services=$'postgres\nqdrant\nrabbitmq\nredis\nstreamix'
  actual_services=$(
    STREAMIX_IMAGE="${image_ref}" \
      STREAMIX_ENV_FILE="/opt/streamix/.env" \
      docker compose --env-file /opt/streamix/.env -f "${compose_candidate}" config --services |
      LC_ALL=C sort
  )

  if [ "${actual_services}" != "${expected_services}" ]; then
    echo "[deploy] production compose service contract changed unexpectedly" >&2
    exit 1
  fi

  if ! docker network inspect shared_network >/dev/null 2>&1; then
    echo "[deploy] required external Docker network shared_network is missing" >&2
    exit 1
  fi

  if [ -f "${production_compose}" ]; then
    had_versioned_compose=true
    active_compose="${production_compose}"

    if [ ! -f "${compose_state}" ]; then
      echo "[deploy] versioned compose exists without its recorded checksum" >&2
      exit 1
    fi

    IFS= read -r recorded_hash <"${compose_state}"

    if [ "$(sha256sum "${production_compose}" | awk '{print $1}')" != "${recorded_hash}" ]; then
      echo "[deploy] production compose drift detected; reconcile the VPS before deploying" >&2
      exit 1
    fi
  else
    active_compose="${legacy_compose}"

    if [ ! -f "${active_compose}" ]; then
      echo "[deploy] no legacy compose exists for first-time contract adoption" >&2
      exit 1
    fi

    normalized_active=$(mktemp)
    normalized_candidate=$(mktemp)
    normalize_compose "${active_compose}" >"${normalized_active}"
    normalize_compose "${compose_candidate}" >"${normalized_candidate}"

    if ! cmp -s "${normalized_active}" "${normalized_candidate}"; then
      rm -f "${normalized_active}" "${normalized_candidate}"
      echo "[deploy] versioned compose does not match the live legacy topology" >&2
      exit 1
    fi

    rm -f "${normalized_active}" "${normalized_candidate}"
  fi

  echo "[deploy] production compose ${validated_compose_hash} passed drift and topology preflight"
}

install_compose_contract() {
  local candidate_hash="$1"
  local timestamp

  if [ "${had_versioned_compose}" = true ]; then
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    compose_backup="${production_compose}.bak-${timestamp}"
    compose_state_backup="${compose_state}.bak-${timestamp}"

    cp -p "${production_compose}" "${compose_backup}" || return 1
    cp -p "${compose_state}" "${compose_state_backup}" || return 1
  fi

  candidate_installed=true

  install -m 0644 "${compose_candidate}" "${production_compose}" || return 1
  printf '%s\n' "${candidate_hash}" >"${compose_state}" || return 1
  chmod 0600 "${compose_state}" || return 1

  echo "[deploy] installed production compose ${candidate_hash}"
}

read_json_string() {
  local key="$1"
  local file="$2"

  jq -er --arg key "${key}" '
    .[$key]
    | select(type == "string" and length > 0)
  ' "${file}"
}

read_release_revision() {
  local file="$1"

  jq -er '
    (.release.revision // .revision)
    | select(type == "string" and length > 0)
  ' "${file}"
}

run_authenticated_canary() {
  if [ -z "${DEPLOY_CANARY_EMAIL:-}" ] && [ -z "${DEPLOY_CANARY_PASSWORD:-}" ]; then
    echo "[deploy] authenticated canary credentials are required"
    return 1
  fi

  if [ -z "${DEPLOY_CANARY_EMAIL:-}" ] || [ -z "${DEPLOY_CANARY_PASSWORD:-}" ]; then
    echo "[deploy] authenticated canary requires both email and password"
    return 1
  fi

  local login_status token

  login_status=$(
    curl -sS -o "${auth_body}" -w '%{http_code}' \
      --data-urlencode "email=${DEPLOY_CANARY_EMAIL}" \
      --data-urlencode "password=${DEPLOY_CANARY_PASSWORD}" \
      "${DEPLOY_BASE_URL}/api/v1/auth/login" || true
  )

  if [ "${login_status}" != "200" ]; then
    echo "[deploy] authenticated login canary returned HTTP ${login_status}"
    return 1
  fi

  token=$(read_json_string "token" "${auth_body}")

  if [ -z "${token}" ]; then
    echo "[deploy] authenticated login canary returned no token"
    return 1
  fi

  curl -fsS -H "authorization: Bearer ${token}" \
    "${DEPLOY_BASE_URL}/api/v1/auth/me" >/dev/null &&
    curl -fsS -X POST -H "authorization: Bearer ${token}" \
      "${DEPLOY_BASE_URL}/api/v1/auth/logout" >/dev/null
}

run_http_canaries() {
  local readiness_status="" release_revision=""

  echo "[deploy] waiting up to 60s for public readiness"

  for _attempt in $(seq 1 30); do
    readiness_status=$(
      curl -sS -o "${readiness_body}" -w '%{http_code}' \
        "${DEPLOY_BASE_URL}/api/health/ready" || true
    )

    if [ "${readiness_status}" = "200" ]; then
      break
    fi

    sleep 2
  done

  if [ "${readiness_status}" != "200" ]; then
    echo "[deploy] readiness returned HTTP ${readiness_status}"
    return 1
  fi

  release_revision=$(read_release_revision "${readiness_body}")

  if [ -z "${release_revision}" ]; then
    echo "[deploy] readiness returned no release revision"
    return 1
  fi

  if [ -n "${EXPECTED_REVISION}" ] && [ "${release_revision}" != "${EXPECTED_REVISION}" ]; then
    echo "[deploy] readiness revision ${release_revision} != ${EXPECTED_REVISION}"
    return 1
  fi

  curl -fsS "${DEPLOY_BASE_URL}/" >/dev/null || return 1
  curl -fsS "${DEPLOY_BASE_URL}/sw.js" >/dev/null || return 1
  curl -fsS -D "${manifest_headers}" -o /dev/null "${DEPLOY_BASE_URL}/manifest.json" ||
    return 1

  if ! tr -d '\r' <"${manifest_headers}" | grep -qi '^cache-control:.*no-cache'; then
    echo "[deploy] manifest is missing its revalidation cache policy"
    return 1
  fi

  run_authenticated_canary
}

preflight_compose

if [ "${DEPLOY_PREFLIGHT_ONLY}" = "true" ]; then
  echo "[deploy] preflight-only mode completed without changing production"
  exit 0
fi

if [ -n "${previous_image}" ]; then
  docker tag "${previous_image}" "${IMAGE_NAME}:rollback"
fi

echo "[deploy] pulling ${image_ref}"
docker pull "${image_ref}"
expected_image=$(docker image inspect -f '{{.Id}}' "${image_ref}")
image_revision=$(
  docker image inspect \
    -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "${image_ref}" 2>/dev/null || true
)

if [ -z "${EXPECTED_REVISION}" ] || [ "${EXPECTED_REVISION}" = "<no value>" ]; then
  EXPECTED_REVISION="${image_revision}"
fi

if [[ ! "${EXPECTED_REVISION}" =~ ^[0-9a-f]{40,64}$ ]]; then
  echo "[deploy] expected release revision is missing or invalid" >&2
  exit 1
fi

if [[ ! "${image_revision}" =~ ^[0-9a-f]{40,64}$ ]]; then
  echo "[deploy] image revision label is missing or invalid" >&2
  exit 1
fi

if [ "${image_revision}" != "${EXPECTED_REVISION}" ]; then
  echo "[deploy] image revision ${image_revision} != ${EXPECTED_REVISION}" >&2
  exit 1
fi

docker tag "${image_ref}" "${IMAGE_NAME}:latest"

if ! install_compose_contract "${validated_compose_hash}"; then
  rollback "failed to install the versioned Compose contract"
fi

echo "[deploy] running migrations"
if ! compose "${image_ref}" run --rm --no-deps streamix /app/bin/migrate; then
  rollback "migration failed"
fi

echo "[deploy] recreating container"
if ! compose "${image_ref}" up -d --force-recreate --remove-orphans streamix; then
  rollback "container recreation failed"
fi

echo "[deploy] waiting up to 90s for healthy status"
for _attempt in $(seq 1 45); do
  status=$(docker inspect -f '{{.State.Health.Status}}' streamix 2>/dev/null || true)

  if [ "${status}" = "healthy" ]; then
    running_image=$(docker inspect -f '{{.Image}}' streamix 2>/dev/null || true)

    if [ "${running_image}" != "${expected_image}" ]; then
      echo "[deploy] FAIL: healthy container is running ${running_image}, expected ${expected_image}"
      break
    fi

    if run_http_canaries; then
      echo "[deploy] OK: ${IMAGE_DIGEST} is healthy and passed public canaries"
      docker image prune -f >/dev/null 2>&1 || true
      exit 0
    fi

    break
  fi

  if [ "${status}" = "unhealthy" ]; then
    break
  fi

  sleep 2
done

rollback "rollout did not pass container health and HTTP canaries"
