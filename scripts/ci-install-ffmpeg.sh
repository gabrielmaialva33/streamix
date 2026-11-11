#!/usr/bin/env bash
# Installs ffmpeg on a GitHub runner for the deterministic media fixtures.
#
# The runner's Ubuntu mirrors (azure.archive / archive / security.ubuntu.com)
# sometimes stop resolving for hours. apt then retries every name for the
# whole job budget and the E2E job is cancelled at its timeout without
# running a test. Each attempt here is bounded, and a failed one switches
# the sources to another Ubuntu mirror before trying again.
set -euo pipefail

attempt_seconds="${FFMPEG_APT_TIMEOUT:-150}"
fallback_mirror="${FFMPEG_APT_FALLBACK_MIRROR:-http://mirrors.edge.kernel.org/ubuntu/}"

install_ffmpeg() {
  timeout "${attempt_seconds}" sudo apt-get \
    -o Acquire::Retries=2 -o Acquire::http::Timeout=20 update -qq &&
    timeout "${attempt_seconds}" sudo apt-get \
      -o Acquire::Retries=2 -o Acquire::http::Timeout=20 \
      install -y --no-install-recommends ffmpeg
}

use_fallback_mirror() {
  echo "[ffmpeg] Ubuntu mirrors unreachable; retrying through ${fallback_mirror}" >&2

  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "${file}" ] || continue
    sudo sed -i -E \
      -e "s#https?://([a-z0-9.-]+\.)?archive\.ubuntu\.com/ubuntu/?#${fallback_mirror}#g" \
      -e "s#https?://security\.ubuntu\.com/ubuntu/?#${fallback_mirror}#g" \
      "${file}"
  done
}

if ! install_ffmpeg; then
  use_fallback_mirror
  install_ffmpeg
fi

ffmpeg -version | head -1
