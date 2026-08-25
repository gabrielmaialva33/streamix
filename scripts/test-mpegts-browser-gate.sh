#!/usr/bin/env bash
set -euo pipefail

browser="${1:-${PLAYWRIGHT_BROWSER:-chromium}}"
case "$browser" in
  chromium | firefox | webkit) ;;
  *)
    printf 'Unsupported browser: %s\n' "$browser" >&2
    exit 64
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assets_root="$root/assets"
lockfile="$assets_root/package-lock.json"

if [[ ! -f "$lockfile" ]]; then
  printf 'Missing Playwright lockfile: %s\n' "$lockfile" >&2
  exit 65
fi

version="${PLAYWRIGHT_VERSION:-}"
if [[ -z "$version" ]]; then
  version="$({
    node - "$lockfile" <<'NODE'
const fs = require("node:fs");
const lock = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const packages = lock.packages || {};
const version =
  packages["node_modules/playwright"]?.version ||
  packages["node_modules/@playwright/test"]?.version ||
  "";
process.stdout.write(version);
NODE
  })"
fi

if [[ -z "$version" ]]; then
  printf 'Could not determine the Playwright version from %s\n' "$lockfile" >&2
  exit 66
fi

if [[ ! -d "$assets_root/node_modules/playwright" ]]; then
  printf 'Missing assets/node_modules/playwright; run npm ci in assets first.\n' >&2
  exit 67
fi

image="${PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v${version}-noble}"
printf 'MPEG-TS browser gate: %s using %s\n' "$browser" "$image"

docker run --rm \
  --network host \
  --ipc host \
  -e CI=1 \
  -e PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
  -v "$root:/work:ro" \
  -w /work/assets \
  "$image" \
  node js/smoke/mpegts_browser_gate.mjs "$browser"
