# script-kind: library
# Purpose: Back up the primary (base backup and WAL archive); restore a copy to a WAL position.
# Usage: source "${SCRIPT_DIR}../lib/backup.sh", then call backup::prepare, take_base, wait_archived
# Requires: awk docker sleep
# Depends: database
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly BACKUP_ARCHIVE_VOLUME='pg-replication_pg-archive'
readonly BACKUP_BACKUP_VOLUME='pg-replication_pg-backup'
readonly BACKUP_RESTORE_VOLUME='pg-point-in-time-data'
readonly BACKUP_RESTORE_CONTAINER='pg-point-in-time'
readonly BACKUP_ARCHIVED_SQL='select archived_count from pg_stat_archiver'
readonly BACKUP_ATTEMPTS=120
readonly BACKUP_PAUSE_SECONDS=0.5
readonly BACKUP_RESTORE_COMMAND='cp /archive/%f %p'
readonly BACKUP_COPY_PROGRAM='rm -rf /var/lib/postgresql/data/* && \
cp -a /backup/base/. /var/lib/postgresql/data/'
readonly BACKUP_OWN_PROGRAM='chown -R postgres:postgres /var/lib/postgresql/data && \
chmod 700 /var/lib/postgresql/data'
readonly BACKUP_SIGNAL_PROGRAM='touch /var/lib/postgresql/data/recovery.signal'

# Give the archive and the backup volumes to the postgres user, so the primary can write to them.
# A new volume belongs to root until this has run.
# Usage: backup::prepare IMAGE
backup::prepare() {
  local image="${1:?image required}"
  local program='chown postgres:postgres /archive /backup'

  log INFO 'CHANGE: giving the archive and backup volumes to the postgres user'
  MSYS_NO_PATHCONV=1 docker run \
    --rm \
    --user root \
    --volume "${BACKUP_ARCHIVE_VOLUME}:/archive" \
    --volume "${BACKUP_BACKUP_VOLUME}:/backup" \
    --entrypoint sh \
    "${image}" \
    -c "${program}" > /dev/null
}

# Take a base backup of a node into the backup volume, replacing the previous one. The WAL the
# backup needs is streamed with it (-X stream), so the backup is consistent on its own.
# Usage: backup::take_base NODE
backup::take_base() {
  local node="${1:?node required}"

  log INFO "CHANGE: taking a base backup of ${node}"
  MSYS_NO_PATHCONV=1 docker exec --user postgres "${node}" sh -c 'rm -rf /backup/base' > /dev/null
  MSYS_NO_PATHCONV=1 docker exec \
    --user postgres \
    "${node}" \
    pg_basebackup \
    --pgdata /backup/base \
    --wal-method stream \
    --checkpoint fast > /dev/null
}

# Print how many WAL segments the node has archived so far.
# Usage: backup::archived_count NODE
backup::archived_count() {
  local node="${1:?node required}"

  database::bare "${node}" <<< "${BACKUP_ARCHIVED_SQL}"
}

# Finish the WAL segment the node is writing, so everything before now is archived, and wait until
# the archiver reports at least COUNT archived segments.
# Usage: backup::wait_archived NODE COUNT
backup::wait_archived() {
  local node="${1:?node required}"
  local count="${2:?count required}"
  local attempt=0
  local archived

  database::run "${node}" <<< 'select pg_switch_wal()' > /dev/null
  archived="$(backup::archived_count "${node}")"
  while (( archived < count )); do
    (( attempt < BACKUP_ATTEMPTS )) || die 1 "${node} archived fewer than ${count} segments"
    attempt=$(( attempt + 1 ))
    sleep "${BACKUP_PAUSE_SECONDS}"
    archived="$(backup::archived_count "${node}")"
  done
}

# Print how many lines of the restored copy's log say it read a WAL file from the archive.
backup::archive_reads() {
  docker logs "${BACKUP_RESTORE_CONTAINER}" 2>&1 |
    awk '/restored log file/ { reads++ } END { print reads + 0 }'
}

# Remove the restored copy and its volume, if there are any (safe to repeat).
backup::remove_restore() {
  log INFO 'CHANGE: removing the restored copy and its volume'
  if docker inspect "${BACKUP_RESTORE_CONTAINER}" > /dev/null 2>&1; then
    docker rm --force "${BACKUP_RESTORE_CONTAINER}" > /dev/null
  fi
  if docker volume inspect "${BACKUP_RESTORE_VOLUME}" > /dev/null 2>&1; then
    docker volume rm "${BACKUP_RESTORE_VOLUME}" > /dev/null
  fi
}

# Copy the base backup into a fresh volume, mark it to recover from the archive, and start it as a
# node of its own (not published to the host). With TARGET_LSN the recovery stops at that WAL
# position and promotes there; without it, recovery runs to the end of the archive.
# Usage: backup::restore_to IMAGE [TARGET_LSN]
backup::restore_to() {
  local image="${1:?image required}"
  local target="${2-}"
  local copy_program="${BACKUP_COPY_PROGRAM} && ${BACKUP_OWN_PROGRAM}"
  local -a start=(env MSYS_NO_PATHCONV=1 docker run --detach --user postgres)

  backup::remove_restore
  log INFO "CHANGE: restoring a copy (target: ${target:-end of archive})"
  MSYS_NO_PATHCONV=1 docker run \
    --rm \
    --user root \
    --volume "${BACKUP_BACKUP_VOLUME}:/backup" \
    --volume "${BACKUP_RESTORE_VOLUME}:/var/lib/postgresql/data" \
    --entrypoint sh \
    "${image}" \
    -c "${copy_program}" > /dev/null
  MSYS_NO_PATHCONV=1 docker run \
    --rm \
    --user postgres \
    --volume "${BACKUP_RESTORE_VOLUME}:/var/lib/postgresql/data" \
    --entrypoint sh \
    "${image}" \
    -c "${BACKUP_SIGNAL_PROGRAM}" > /dev/null
  start+=(--name "${BACKUP_RESTORE_CONTAINER}")
  start+=(--volume "${BACKUP_RESTORE_VOLUME}:/var/lib/postgresql/data")
  start+=(--volume "${BACKUP_ARCHIVE_VOLUME}:/archive:ro")
  start+=("${image}" postgres)
  start+=(-c "restore_command=${BACKUP_RESTORE_COMMAND}")
  start+=(-c 'recovery_target_action=promote')
  if [[ -n "${target}" ]]; then
    start+=(-c "recovery_target_lsn=${target}")
  fi
  "${start[@]}" > /dev/null
}

# Wait until the restored copy has finished recovering and is writable (promoted).
# Usage: backup::wait_promoted
backup::wait_promoted() {
  local attempt=0
  local recovery

  while true; do
    recovery="$(database::in_recovery "${BACKUP_RESTORE_CONTAINER}")"
    if [[ "${recovery}" == 'f' ]]; then
      return 0
    fi
    (( attempt < BACKUP_ATTEMPTS )) || die 1 'the restored copy did not promote'
    attempt=$(( attempt + 1 ))
    sleep "${BACKUP_PAUSE_SECONDS}"
  done
}
