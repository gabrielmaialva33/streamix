#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
browser="${PLAYWRIGHT_BROWSER:-webkit}"
container_name="streamix-playwright-${browser}-$$"

cd "${project_root}"

case "${browser}" in
chromium | firefox | webkit) ;;
*)
  echo "[playwright] unsupported browser: ${browser}" >&2
  exit 2
  ;;
esac

pick_free_port() {
  local candidate

  for _attempt in $(seq 1 50); do
    candidate=$(shuf -i 20000-45000 -n 1)

    if ! ss -H -ltn "sport = :${candidate}" | grep -q .; then
      echo "${candidate}"
      return
    fi
  done

  return 1
}

playwright_port="${PLAYWRIGHT_DOCKER_PORT:-$(pick_free_port)}"

playwright_version=$(
  cd "${project_root}"
  node -e 'console.log(require("./assets/package-lock.json").packages["node_modules/playwright"].version)'
)

image="mcr.microsoft.com/playwright:v${playwright_version}-noble"

cleanup() {
  docker rm -f "${container_name}" >/dev/null 2>&1 || true
}

retry_command() {
  local label="$1"
  shift

  local attempt
  local backoff

  for attempt in 1 2 3; do
    if "$@"; then
      return 0
    fi

    if [ "${attempt}" -lt 3 ]; then
      backoff=$((attempt * 5))
      echo "[playwright] ${label} attempt ${attempt}/3 failed; retrying in ${backoff}s" >&2
      sleep "${backoff}"
    fi
  done

  echo "[playwright] ${label} failed after 3 attempts" >&2
  return 1
}

trap cleanup EXIT INT TERM

if [ "$(uname -s)" != "Linux" ]; then
  echo "[playwright] this runner currently requires Linux host networking" >&2
  exit 2
fi

if ss -H -ltn "sport = :${playwright_port}" | grep -q .; then
  echo "[playwright] port ${playwright_port} is already in use" >&2
  exit 2
fi

echo "[playwright] installing frontend asset binaries"
env MIX_ENV=test bash scripts/install-asset-binaries.sh

echo "[playwright] building current frontend assets"
env MIX_ENV=test mix assets.build

if ! docker image inspect "${image}" >/dev/null 2>&1; then
  echo "[playwright] pulling ${image}"
  retry_command "image pull" docker pull "${image}"
fi

echo "[playwright] starting ${browser} via Playwright ${playwright_version}"
docker run --detach \
  --init \
  --network host \
  --name "${container_name}" \
  --volume "${project_root}:/work:ro" \
  --workdir /work/assets \
  "${image}" \
  node node_modules/playwright/cli.js run-server \
  --host 0.0.0.0 \
  --port "${playwright_port}" >/dev/null

for _attempt in $(seq 1 60); do
  if timeout 1 bash -c "</dev/tcp/127.0.0.1/${playwright_port}" 2>/dev/null; then
    break
  fi

  if ! docker inspect -f '{{.State.Running}}' "${container_name}" 2>/dev/null | grep -qx true; then
    echo "[playwright] server exited before becoming ready" >&2
    docker logs "${container_name}" >&2 || true
    exit 1
  fi

  sleep 0.25
done

if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${playwright_port}" 2>/dev/null; then
  echo "[playwright] timed out waiting for the browser server" >&2
  docker logs "${container_name}" >&2 || true
  exit 1
fi

if [ "$#" -eq 0 ]; then
  set -- \
    test/streamix_web/e2e/home_skeleton_test.exs \
    test/streamix_web/e2e/login_persistence_test.exs \
    test/streamix_web/e2e/player_lifecycle_test.exs \
    test/streamix_web/e2e/premium_visibility_test.exs \
    test/streamix_web/e2e/webkit_reconnect_test.exs

  if [ "${browser}" = "chromium" ]; then
    set -- "$@" test/streamix_web/e2e/torrent_subtitle_tracer_test.exs
  fi
fi

echo "[playwright] running ${browser}: $*"
if ! PLAYWRIGHT_BROWSER="${browser}" \
  PLAYWRIGHT_WS_ENDPOINT="ws://127.0.0.1:${playwright_port}" \
  mix test --include playwright "$@"; then
  echo "[playwright] ${browser} run failed; server logs:" >&2
  docker logs --tail 100 "${container_name}" >&2 || true
  exit 1
fi
