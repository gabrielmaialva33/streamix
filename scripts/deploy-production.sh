#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_NAME:?IMAGE_NAME is required}"
: "${IMAGE_DIGEST:?IMAGE_DIGEST is required}"

if [[ ! "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "[deploy] invalid image digest: ${IMAGE_DIGEST}" >&2
  exit 2
fi

cd /opt/streamix

image_ref="${IMAGE_NAME}@${IMAGE_DIGEST}"
previous_image=$(docker inspect -f '{{.Image}}' streamix 2>/dev/null || true)

if [ -n "${previous_image}" ]; then
  docker tag "${previous_image}" "${IMAGE_NAME}:rollback"
fi

echo "[deploy] pulling ${image_ref}"
docker pull "${image_ref}"
docker tag "${image_ref}" "${IMAGE_NAME}:latest"
expected_image=$(docker image inspect -f '{{.Id}}' "${image_ref}")

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

    echo "[deploy] OK: streamix healthy at ${IMAGE_DIGEST}"
    docker image prune -f >/dev/null 2>&1 || true
    exit 0
  fi

  if [ "${status}" = "unhealthy" ]; then
    break
  fi

  sleep 2
done

echo "[deploy] FAIL: rollout unhealthy, recent logs:"
docker logs --tail 200 streamix || true

if [ -n "${previous_image}" ]; then
  echo "[deploy] rolling back to ${previous_image}"
  docker tag "${previous_image}" "${IMAGE_NAME}:latest"
  docker compose up -d --force-recreate --remove-orphans streamix
fi

exit 1
