#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${IMAGE_DIGEST:?IMAGE_DIGEST is required}"

DEPLOY_BASE_URL="${DEPLOY_BASE_URL:-https://streamix.mahina.cloud}"
EXPECTED_REVISION="${EXPECTED_REVISION:-}"

if [[ ! "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[deploy] invalid image digest: ${IMAGE_DIGEST}" >&2
  exit 2
fi

cd /opt/streamix

image_ref="${IMAGE_NAME}@${IMAGE_DIGEST}"
previous_image=$(docker inspect -f '{{.Image}}' streamix 2>/dev/null || true)
readiness_body=$(mktemp)
manifest_headers=$(mktemp)
auth_body=$(mktemp)

cleanup() {
  rm -f "${readiness_body}" "${manifest_headers}" "${auth_body}"
}

trap cleanup EXIT

rollback() {
  echo "[deploy] FAIL: ${1}"
  docker logs --tail 200 streamix || true

  if [ -n "${previous_image}" ]; then
    echo "[deploy] rolling back to ${previous_image}"
    docker tag "${previous_image}" "${IMAGE_NAME}:latest"
    docker compose up -d --force-recreate --remove-orphans streamix
  fi

  exit 1
}

read_json_string() {
  local key="$1"
  local file="$2"

  sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" "${file}" | head -n 1
}

run_authenticated_canary() {
  if [ -z "${DEPLOY_CANARY_EMAIL:-}" ] && [ -z "${DEPLOY_CANARY_PASSWORD:-}" ]; then
    return 0
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

  release_revision=$(read_json_string "revision" "${readiness_body}")

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

if [ -n "${previous_image}" ]; then
  docker tag "${previous_image}" "${IMAGE_NAME}:rollback"
fi

echo "[deploy] pulling ${image_ref}"
docker pull "${image_ref}"
docker tag "${image_ref}" "${IMAGE_NAME}:latest"
expected_image=$(docker image inspect -f '{{.Id}}' "${image_ref}")
image_revision=$(
  docker image inspect \
    -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "${image_ref}" 2>/dev/null || true
)

if [ -z "${EXPECTED_REVISION}" ] || [ "${EXPECTED_REVISION}" = "<no value>" ]; then
  EXPECTED_REVISION="${image_revision}"
fi

echo "[deploy] running migrations"
if ! docker compose run --rm --no-deps streamix /app/bin/migrate; then
  if [ -n "${previous_image}" ]; then
    docker tag "${previous_image}" "${IMAGE_NAME}:latest"
  fi
  exit 1
fi

echo "[deploy] recreating container"
docker compose up -d --force-recreate --remove-orphans streamix

echo "[deploy] waiting up to 90s for healthy status"
for _attempt in $(seq 1 45); do
  status=$(docker inspect -f '{{.State.Health.Status}}' streamix 2>/dev/null || true)

  if [ "${status}" = "healthy" ]; then
    running_image=$(docker inspect -f '{{.Image}}' streamix)

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
