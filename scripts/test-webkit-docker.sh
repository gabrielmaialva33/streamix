#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
container_name="streamix-playwright-webkit-$$"

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

trap cleanup EXIT INT TERM

if [ "$(uname -s)" != "Linux" ]; then
  echo "[webkit] this runner currently requires Linux host networking" >&2
  exit 2
fi

if ss -H -ltn "sport = :${playwright_port}" | grep -q .; then
  echo "[webkit] port ${playwright_port} is already in use" >&2
  exit 2
fi

if ! docker image inspect "${image}" >/dev/null 2>&1; then
  echo "[webkit] pulling ${image}"
  docker pull "${image}"
fi

echo "[webkit] starting Playwright ${playwright_version} on port ${playwright_port}"
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
    echo "[webkit] Playwright server exited before becoming ready" >&2
    docker logs "${container_name}" >&2 || true
    exit 1
  fi

  sleep 0.25
done

if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${playwright_port}" 2>/dev/null; then
  echo "[webkit] timed out waiting for Playwright server" >&2
  docker logs "${container_name}" >&2 || true
  exit 1
fi

if [ "$#" -eq 0 ]; then
  set -- \
    test/streamix_web/e2e/player_lifecycle_test.exs \
    test/streamix_web/e2e/webkit_reconnect_test.exs \
    test/streamix_web/e2e/home_skeleton_test.exs \
    test/streamix_web/e2e/premium_visibility_test.exs
fi

echo "[webkit] building current frontend assets"
cd "${project_root}"
MIX_ENV=test mix assets.build

echo "[webkit] running $*"
if ! PLAYWRIGHT_BROWSER=webkit \
  PLAYWRIGHT_WS_ENDPOINT="ws://127.0.0.1:${playwright_port}" \
  mix test --include playwright "$@"; then
  echo "[webkit] test run failed; Playwright server logs:" >&2
  docker logs --tail 100 "${container_name}" >&2 || true
  exit 1
fi
