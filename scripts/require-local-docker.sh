#!/usr/bin/env bash
# Source before build/install/port selection: these runners bind the local tree.
require_local_docker() {
  local endpoint context
  if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
    endpoint=$(docker context inspect "${DOCKER_CONTEXT}" --format '{{.Endpoints.docker.Host}}') || return 64
  elif [[ -n "${DOCKER_HOST:-}" ]]; then
    endpoint="${DOCKER_HOST}"
  else
    context=$(docker context show) || return 64
    endpoint=$(docker context inspect "${context}" --format '{{.Endpoints.docker.Host}}') || return 64
  fi
  case "${endpoint}" in
    unix:///*) return 0 ;;
    *)
      echo 'This runner requires a local Docker endpoint (unix socket).' >&2
      echo 'Select an already available local context explicitly, or use a native browser runner. No daemon was started.' >&2
      return 64
      ;;
  esac
}
