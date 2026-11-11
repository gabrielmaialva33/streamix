#!/usr/bin/env bash
# Installs ffmpeg on a GitHub runner for the deterministic media fixtures
# (lavfi test sources encoded with libx264 and aac into MPEG-TS).
#
# Ubuntu's apt mirrors are sometimes unreachable from the runners for hours
# (azure.archive, archive and security.ubuntu.com all failed to resolve on
# 2026-11-11, and mirrors.edge.kernel.org timed out too); apt then retried
# for the whole job budget and the E2E job was cancelled without running a
# test. apt gets one bounded attempt; after that the static ffmpeg build in
# the imageio-ffmpeg wheel is installed from PyPI, pinned by version and
# hash, into a private virtualenv.
set -euo pipefail

apt_seconds="${FFMPEG_APT_TIMEOUT:-90}"
wheel="imageio-ffmpeg==0.8.1"
wheel_sha256="050d6850601c3b3890bd2b28306f3b842b3daea390a561101174375a1c460bda"
venv="${RUNNER_TEMP:-/tmp}/ffmpeg-venv"

install_from_apt() {
  timeout "${apt_seconds}" sudo apt-get \
    -o Acquire::Retries=1 -o Acquire::http::Timeout=15 update -qq &&
    timeout "${apt_seconds}" sudo apt-get \
      -o Acquire::Retries=1 -o Acquire::http::Timeout=15 \
      install -y --no-install-recommends ffmpeg
}

install_from_pypi() {
  echo "[ffmpeg] apt unavailable; installing the static build from ${wheel}" >&2

  python3 -m venv "${venv}"
  printf '%s --hash=sha256:%s\n' "${wheel}" "${wheel_sha256}" > "${venv}/requirements.txt"
  "${venv}/bin/pip" install --quiet --require-hashes --only-binary=:all: \
    -r "${venv}/requirements.txt"

  local exe
  exe=$("${venv}/bin/python" -c 'import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())')
  sudo ln -sf "${exe}" /usr/local/bin/ffmpeg
}

if ! install_from_apt; then
  install_from_pypi
fi

ffmpeg -hide_banner -version | head -1

# The fixtures need these; fail here, not halfway through a browser test.
encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
for encoder in libx264 aac; do
  grep -q " ${encoder} " <<<"${encoders}" || {
    echo "[ffmpeg] missing encoder ${encoder}" >&2
    exit 1
  }
done
