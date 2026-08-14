#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
attempts="${ASSET_SETUP_ATTEMPTS:-5}"

cd "${project_root}"

export MIX_ENV="${MIX_ENV:-test}"

# tailwind/esbuild binaries come straight from GitHub releases, which answers
# with 503 often enough to break unrelated jobs. Retry with a longer backoff
# than the default mix task offers before giving up.
for attempt in $(seq 1 "${attempts}"); do
  if mix assets.setup; then
    exit 0
  fi

  if [ "${attempt}" -lt "${attempts}" ]; then
    backoff=$((attempt * 10))
    echo "[assets] setup attempt ${attempt}/${attempts} failed; retrying in ${backoff}s" >&2
    sleep "${backoff}"
  fi
done

echo "[assets] setup failed after ${attempts} attempts" >&2
exit 1
