#!/usr/bin/env bash
set -euo pipefail

files=("$@")

if [ "${#files[@]}" -eq 0 ]; then
  base_sha="${MIGRATION_BASE_SHA:-}"

  if [ -z "${base_sha}" ] || [[ "${base_sha}" =~ ^0+$ ]]; then
    echo "[migration-safety] no comparison SHA; skipping changed-file scan"
    exit 0
  fi

  if ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null; then
    echo "[migration-safety] comparison commit ${base_sha} is unavailable" >&2
    exit 2
  fi

  mapfile -t files < <(
    git diff --diff-filter=AM --name-only "${base_sha}...HEAD" -- 'priv/repo/migrations/*.exs'
  )
fi

risky_pattern='(^|[^[:alnum:]_])(drop|drop_if_exists|remove|rename)([^[:alnum:]_]|$)|execute[[:space:]]*\(?.*(DROP|TRUNCATE|RENAME|ALTER[[:space:]].*DROP)'
failed=0

for file in "${files[@]}"; do
  [ -f "${file}" ] || continue

  if grep -q 'migration-safety: reviewed' "${file}"; then
    echo "[migration-safety] reviewed ${file}"
    continue
  fi

  if grep -Eni "${risky_pattern}" "${file}"; then
    echo "[migration-safety] ${file} contains a destructive or compatibility-sensitive operation" >&2
    echo "[migration-safety] use an expand/contract rollout, then add '# migration-safety: reviewed' with its rationale" >&2
    failed=1
  fi
done

exit "${failed}"
