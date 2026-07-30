#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PLAYWRIGHT_BROWSER=webkit

exec bash "${project_root}/scripts/test-playwright-docker.sh" "$@"
