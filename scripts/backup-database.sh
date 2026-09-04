#!/usr/bin/env bash
# Production Postgres backup for Streamix.
#
# Writes a compressed custom-format dump plus the cluster globals, prunes old
# copies, and records the TimescaleDB extension version alongside each dump.
#
# That last part is not decoration. A plain pg_restore of this dump into a
# fresh container fails twice over:
#
#   1. The TimescaleDB image installs its newest bundled extension on init,
#      while the dump carries whatever version production is on.
#      `timescaledb_post_restore()` aborts on a catalog version mismatch, so
#      the target database has to install the *recorded* version first.
#   2. `pg_restore --jobs` reorders TimescaleDB's own catalog tables and
#      produces foreign-key failures. The restore must be serial.
#
# See RESTORE.md next to the dumps for the verified procedure.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/streamix/backups}"
CONTAINER="${POSTGRES_CONTAINER:-streamix-postgres}"
KEEP="${BACKUP_KEEP:-14}"
MIN_BYTES="${BACKUP_MIN_BYTES:-1048576}"

log() { printf '[backup] %s\n' "$*"; }
fail() { printf '[backup] ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker not found"
docker inspect "${CONTAINER}" >/dev/null 2>&1 || fail "container ${CONTAINER} not found"

mkdir -p "${BACKUP_DIR}"
chmod 0700 "${BACKUP_DIR}"

db=$(docker exec "${CONTAINER}" sh -c 'echo "$POSTGRES_DB"')
user=$(docker exec "${CONTAINER}" sh -c 'echo "$POSTGRES_USER"')
[ -n "${db}" ] && [ -n "${user}" ] || fail "could not read POSTGRES_DB/POSTGRES_USER from ${CONTAINER}"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
dump="${BACKUP_DIR}/streamix-${stamp}.dump"
globals="${BACKUP_DIR}/globals-${stamp}.sql"
meta="${BACKUP_DIR}/streamix-${stamp}.meta"

log "dumping ${db} from ${CONTAINER}"
docker exec "${CONTAINER}" pg_dump -U "${user}" -d "${db}" --format=custom --compress=9 >"${dump}"

size=$(stat -c %s "${dump}")
if [ "${size}" -lt "${MIN_BYTES}" ]; then
  rm -f "${dump}"
  fail "dump is only ${size} bytes, below the ${MIN_BYTES} floor; refusing to keep it"
fi

# A dump whose header is unreadable is not a backup. Verify before keeping it.
docker cp "${dump}" "${CONTAINER}:/tmp/verify.dump" >/dev/null
entries=$(docker exec "${CONTAINER}" pg_restore --list /tmp/verify.dump | grep -c '^[0-9]' || true)
docker exec "${CONTAINER}" rm -f /tmp/verify.dump || true
[ "${entries}" -gt 0 ] || { rm -f "${dump}"; fail "pg_restore could not read the dump table of contents"; }

docker exec "${CONTAINER}" pg_dumpall -U "${user}" --globals-only >"${globals}"

ts_version=$(docker exec "${CONTAINER}" psql -U "${user}" -d "${db}" -At \
  -c "select extversion from pg_extension where extname = 'timescaledb'" || true)

{
  printf 'database=%s\n' "${db}"
  printf 'taken_at=%s\n' "${stamp}"
  printf 'dump_bytes=%s\n' "${size}"
  printf 'toc_entries=%s\n' "${entries}"
  printf 'timescaledb_version=%s\n' "${ts_version:-none}"
  printf 'postgres_image=%s\n' "$(docker inspect "${CONTAINER}" --format '{{.Config.Image}}')"
} >"${meta}"

chmod 0600 "${dump}" "${globals}" "${meta}"
log "wrote ${dump} (${size} bytes, ${entries} entries, timescaledb=${ts_version:-none})"

# Retention: keep the newest KEEP dumps and their companions.
mapfile -t stale < <(ls -1t "${BACKUP_DIR}"/streamix-*.dump 2>/dev/null | tail -n +$((KEEP + 1)))
for old in "${stale[@]:-}"; do
  [ -n "${old}" ] || continue
  base=$(basename "${old}" .dump)
  suffix=${base#streamix-}
  rm -f "${old}" "${BACKUP_DIR}/globals-${suffix}.sql" "${BACKUP_DIR}/streamix-${suffix}.meta"
  log "pruned ${base}"
done

retained=$(ls -1 "${BACKUP_DIR}"/streamix-*.dump 2>/dev/null | wc -l)
log "done; ${retained} dump(s) retained in ${BACKUP_DIR}"
