#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tool_version() {
  awk -v runtime="$1" '$1 == runtime { print $2 }' "${repo_root}/.tool-versions"
}

docker_version() {
  sed -n "s/^ARG $1=//p" "${repo_root}/Dockerfile"
}

assert_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    echo "${label} version mismatch: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

elixir_tool_version="$(tool_version elixir)"
elixir_version="${elixir_tool_version%%-otp-*}"
otp_version="$(tool_version erlang)"
node_version="$(tool_version nodejs)"
npm_version="$(tool_version npm:npm)"

assert_equal "Docker Elixir" "${elixir_version}" "$(docker_version ELIXIR_VERSION)"
assert_equal "Docker OTP" "${otp_version}" "$(docker_version OTP_VERSION)"
assert_equal "Docker Node.js" "${node_version}" "$(docker_version NODE_VERSION)"
assert_equal "Docker npm" "${npm_version}" "$(docker_version NPM_VERSION)"

if [[ "${elixir_tool_version}" == *-otp-* ]]; then
  elixir_otp_version="${elixir_tool_version##*-otp-}"
  assert_equal "Elixir build OTP" "${otp_version%%.*}" "${elixir_otp_version}"
fi

if [[ -n "${ELIXIR_VERSION:-}" ]]; then
  assert_equal "CI Elixir" "${elixir_version}" "${ELIXIR_VERSION}"
fi

if [[ -n "${OTP_VERSION:-}" ]]; then
  assert_equal "CI OTP" "${otp_version}" "${OTP_VERSION}"
fi

if [[ -n "${NODE_VERSION:-}" ]]; then
  assert_equal "CI Node.js" "${node_version}" "${NODE_VERSION}"
fi

if [[ -n "${NPM_VERSION:-}" ]]; then
  assert_equal "CI npm" "${npm_version}" "${NPM_VERSION}"
fi

echo "Runtime versions are aligned: Elixir ${elixir_tool_version}, OTP ${otp_version}, Node.js ${node_version}, npm ${npm_version}"
