#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runtime_dir=$(mktemp -d)
server_pid=""
base_url="${PWA_BASE_URL:-http://localhost:4002}"

playwright_version=$(
  node -e 'console.log(require("./assets/package-lock.json").packages["node_modules/playwright"].version)'
)
image="${PLAYWRIGHT_DOCKER_IMAGE:-mcr.microsoft.com/playwright:v${playwright_version}-noble}"

cleanup() {
  exit_status=$?

  if [ "${exit_status}" -ne 0 ] && [ -f "${runtime_dir}/server.log" ]; then
    echo "[pwa] Phoenix log after failure:" >&2
    sed -n '1,240p' "${runtime_dir}/server.log" >&2
  fi

  if [ -n "${server_pid}" ] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}"
    wait "${server_pid}" 2>/dev/null || true
  fi

  rm -rf "${runtime_dir}"
}

trap cleanup EXIT INT TERM

cd "${project_root}"

echo "[pwa] preparing test database and production-shaped assets"
env MIX_ENV=test mix ecto.create --quiet
env MIX_ENV=test mix ecto.migrate --quiet
env MIX_ENV=test mix assets.deploy

echo "[pwa] starting Streamix at ${base_url}"
env MIX_ENV=test mix phx.server >"${runtime_dir}/server.log" 2>&1 &
server_pid=$!

for _attempt in $(seq 1 60); do
  if curl --fail --silent --show-error --max-time 1 "${base_url}/login" >/dev/null; then
    break
  fi

  if ! kill -0 "${server_pid}" 2>/dev/null; then
    echo "[pwa] Phoenix exited before becoming ready" >&2
    sed -n '1,200p' "${runtime_dir}/server.log" >&2
    exit 1
  fi

  sleep 0.25
done

if ! curl --fail --silent --show-error --max-time 1 "${base_url}/login" >/dev/null; then
  echo "[pwa] timed out waiting for Phoenix" >&2
  sed -n '1,200p' "${runtime_dir}/server.log" >&2
  exit 1
fi

if ! docker image inspect "${image}" >/dev/null 2>&1; then
  echo "[pwa] pulling ${image}"
  docker pull "${image}"
fi

echo "[pwa] running Chromium installability smoke"
docker run --rm \
  --init \
  --network host \
  --volume "${project_root}:/work:ro" \
  --workdir /work/assets \
  --env "PWA_BASE_URL=${base_url}" \
  "${image}" \
  node js/smoke/pwa_first_install_smoke.cjs

echo "[pwa] running constrained Pixel/Chromium and iPhone/WebKit smoke"
docker run --rm \
  --init \
  --network host \
  --volume "${project_root}:/work:ro" \
  --workdir /work/assets \
  --env "PWA_BASE_URL=${base_url}" \
  "${image}" \
  node js/smoke/mobile_browser_smoke.cjs
