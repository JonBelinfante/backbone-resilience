#!/usr/bin/env bash
# script-kind: executable
# Purpose: Rotate the replication or superuser password with no failed write and no lost data.
# Usage: rotate-secret.sh [-h | --help] [--secret NAME] [--keep-old]
# Requires: cat cp mktemp openssl sleep
# Exit codes: 0 rotated, 1 failed (rolled back where possible), 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them; STANDBY_NAME is the standby's application_name. REBUILD_MARKER_DIR is where
# maintenance state is kept: rebuild markers and the maintenance lock. TEMP_DIR holds the new
# secret until the run ends (default: temporary directory).
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly STANDBY_NAME="${STANDBY_NAME:-standby1}"
readonly REBUILD_MARKER_DIR="${REBUILD_MARKER_DIR:-${TMPDIR:-/tmp}}"
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly SECRETS_PATH="${SCRIPT_DIR}../secrets"
readonly REPLICATION_USER_PATH="${SECRETS_PATH}/pg-replication-user.txt"
readonly REPLICATION_KEY_PATH="${SECRETS_PATH}/pg-replication-password.txt"
readonly SUPERUSER_KEY_PATH="${SECRETS_PATH}/pg-password.txt"
readonly DATABASE_PORT=5432
readonly STREAM_ATTEMPTS=30
readonly SYNC_ATTEMPTS=10
readonly PAUSE_SECONDS=1
readonly ROLE_A='replicator_a'
readonly ROLE_B='replicator_b'
readonly SQL_STREAMING_ROLE="select usename from pg_stat_replication where state = 'streaming'"
readonly SQL_RELOAD='select pg_reload_conf()'
readonly SQL_STREAMING_COUNT="select count(*) from pg_stat_replication where state = 'streaming'"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/access.sh
source "${SCRIPT_DIR}../lib/access.sh"
# shellcheck source=../lib/lock.sh
source "${SCRIPT_DIR}../lib/lock.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: rotate-secret.sh [-h | --help] [--secret NAME] [--keep-old]

Rotate a database password while writes continue and the standby keeps streaming.
  --secret replication  (default) the replication password and role name. By overlap: a second
                        role is created, proven alone, the standby is moved to it, then the old
                        role is retired. The role name alternates between replicator_a and
                        replicator_b, and pg-replication-user.txt holds the live name.
  --secret superuser    the postgres password, changed in place (it has no long-lived link).
  --keep-old            replication only: stop at NOLOGIN for the old role, do not drop it.
Before the secret files change, a failed check rolls the change back. After any interruption
run it again: it converges. It needs the writer, a streaming standby and no pending rebuild.
See docs/secrets-rotation.md.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, STANDBY_NAME, REBUILD_MARKER_DIR, TEMP_DIR,
RUN_LOG_DIR (defaults: pg-primary, pg-standby, standby1, temporary directory).

Exit codes: 0 rotated, 1 failed (rolled back where possible), 2 usage or configuration error
USAGE
}

# Print the container that accepts writes; fail unless exactly one node does.
find_writer() {
  log INFO 'finding the writer'
  local primary_state
  local standby_state

  primary_state="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  standby_state="$(database::in_recovery "${STANDBY_CONTAINER}")"
  case "${primary_state}/${standby_state}" in
    f/t)
      printf '%s\n' "${PRIMARY_CONTAINER}"
      ;;
    t/f)
      printf '%s\n' "${STANDBY_CONTAINER}"
      ;;
    *)
      die 1 "need one writer and one replica, got ${primary_state}/${standby_state}"
      ;;
  esac
}

# Fail unless it is safe to rotate: no pending rebuild, and one streaming standby. A standby that
# is reconnecting (after an interrupted run) is given STREAM_ATTEMPTS seconds to come back.
# Usage: check_ready WRITER
check_ready() {
  log INFO 'checking that it is safe to rotate'
  local writer="${1:?writer required}"
  local node
  local attempt=1

  for node in "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"; do
    if [[ -e "${REBUILD_MARKER_DIR}/rebuild-pending-${node}" ]]; then
      die 1 "a rebuild of ${node} is pending: run restore-starting-state.sh first"
    fi
  done
  while [[ "$(database::bare "${writer}" <<< "${SQL_STREAMING_COUNT}")" != '1' ]]; do
    (( attempt < STREAM_ATTEMPTS )) || die 1 'the standby is not streaming (restore first)'
    attempt=$(( attempt + 1 ))
    sleep "${PAUSE_SECONDS}"
  done
}

# Succeed if the writer reports the standby streaming as the given role within STREAM_ATTEMPTS.
# Usage: wait_for_identity WRITER ROLE
wait_for_identity() {
  log INFO 'waiting for the standby to stream as the expected role'
  local writer="${1:?writer required}"
  local role="${2:?role required}"
  local attempt=1
  local seen

  while (( attempt <= STREAM_ATTEMPTS )); do
    seen="$(database::bare "${writer}" <<< "${SQL_STREAMING_ROLE}")"
    if [[ "${seen}" == "${role}" ]]; then
      log INFO "the standby streams as ${role}"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep "${PAUSE_SECONDS}"
  done
  log WARN "the standby is not streaming as ${role}"
  return 1
}

# Allow the role to stream on both nodes (either may be the writer tomorrow) and reload them.
# Usage: allow_on_both_nodes ROLE
allow_on_both_nodes() {
  log INFO 'allowing the role on both nodes'
  local role="${1:?role required}"
  local node

  for node in "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"; do
    access::allow_replication_login "${node}" "${role}"
    database::bare "${node}" <<< "${SQL_RELOAD}" > /dev/null
  done
}

# Remove the role from the writer and its login line from both nodes.
# Usage: forget_identity WRITER ROLE
forget_identity() {
  log INFO 'removing a replication identity'
  local writer="${1:?writer required}"
  local role="${2:?role required}"
  local node

  log INFO "CHANGE: DROP ROLE ${role} on ${writer}"
  database::bare "${writer}" <<< "drop role if exists ${role}" > /dev/null
  for node in "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"; do
    access::remove_replication_login "${node}" "${role}"
    database::bare "${node}" <<< "${SQL_RELOAD}" > /dev/null
  done
}

# Point the standby's connection to the writer at the given role and password, and reload.
# Usage: switch_standby STANDBY WRITER ROLE KEY_FILE
switch_standby() {
  log INFO 'switching the standby to a replication identity'
  local standby="${1:?standby required}"
  local writer="${2:?writer required}"
  local role="${3:?role required}"
  local key_file="${4:?key file required}"
  local target="host=${writer} port=${DATABASE_PORT} user=${role} password="

  log INFO "CHANGE: ${standby} now connects to ${writer} as ${role}"
  printf '%s\n' \
    '\getenv pw NEWPW' \
    "\\set ci '${target}' :pw ' application_name=${STANDBY_NAME}'" \
    "ALTER SYSTEM SET primary_conninfo = :'ci';" \
    "${SQL_RELOAD};" |
    access::run_sql "${standby}" "${key_file}" > /dev/null
}

# Wait until a container shows the new secret files (they are bind-mounted from the host).
# Usage: wait_for_files NODE ROLE NEW_FILE
wait_for_files() {
  log INFO 'waiting for a container to see the new secret files'
  local node="${1:?node required}"
  local role="${2:?role required}"
  local new_file="${3:?new file required}"
  local attempt=1

  while (( attempt <= SYNC_ATTEMPTS )); do
    if [[ "$(container::secret "${node}" pg-replication-user)" == "${role}" ]]; then
      [[ "$(container::secret "${node}" pg-replication-password)" == "$(< "${new_file}")" ]] ||
        die 1 "${node} sees a different pg-replication-password file"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep "${PAUSE_SECONDS}"
  done
  die 1 "${node} does not see the new pg-replication-user file"
}

# Put the new name and password in the secret files, in place, and check both containers see them.
# Usage: store_replication_files ROLE NEW_FILE
store_replication_files() {
  log INFO 'writing the new replication secret files'
  local role="${1:?role required}"
  local new_file="${2:?new file required}"

  log INFO "CHANGE: ${REPLICATION_USER_PATH} and ${REPLICATION_KEY_PATH} updated in place"
  printf '%s' "${role}" > "${REPLICATION_USER_PATH}"
  cat -- "${new_file}" > "${REPLICATION_KEY_PATH}"
  wait_for_files "${PRIMARY_CONTAINER}" "${role}" "${new_file}"
  wait_for_files "${STANDBY_CONTAINER}" "${role}" "${new_file}"
}

# Move the standby to the new identity. Before the secret files change, any failure puts the
# standby back on the old identity (the files still hold it) and removes the new one.
# Usage: move_standby WRITER STANDBY NEW_ROLE NEW_FILE
move_standby() {
  log INFO 'moving the standby to the new identity'
  local writer="${1:?writer required}"
  local standby="${2:?standby required}"
  local new_role="${3:?new role required}"
  local new_file="${4:?new file required}"
  local old_role

  old_role="$(< "${REPLICATION_USER_PATH}")"
  if ! access::probe_replication_login "${standby}" "${writer}" "${new_role}" "${new_file}"; then
    forget_identity "${writer}" "${new_role}"
    die 1 "the new identity ${new_role} could not log in: nothing was changed"
  fi
  switch_standby "${standby}" "${writer}" "${new_role}" "${new_file}"
  if ! wait_for_identity "${writer}" "${new_role}"; then
    switch_standby "${standby}" "${writer}" "${old_role}" "${REPLICATION_KEY_PATH}"
    forget_identity "${writer}" "${new_role}"
    die 1 "the standby did not stream as ${new_role}: rolled back to ${old_role}"
  fi
}

# Rotate the replication password by overlap: see docs/secrets-rotation.md, method B. The reload
# in switch_standby restarts the WAL receiver, which logs in afresh as the new role: that is the
# proof the new secret works (no forced disconnect, which would stall synchronous commits).
# Usage: rotate_replication WRITER STANDBY NEW_FILE KEEP_OLD
rotate_replication() {
  log INFO 'rotating the replication secret by overlap'
  local writer="${1:?writer required}"
  local standby="${2:?standby required}"
  local new_file="${3:?new file required}"
  local keep_old="${4:?keep-old flag required}"
  local old_role
  local new_role

  old_role="$(< "${REPLICATION_USER_PATH}")"
  new_role="${ROLE_A}"
  if [[ "${old_role}" == "${ROLE_A}" ]]; then
    new_role="${ROLE_B}"
  fi
  log INFO "DECISION: moving the standby from ${old_role} to ${new_role}"
  access::create_replication_role "${writer}" "${new_role}" "${new_file}"
  allow_on_both_nodes "${new_role}"
  move_standby "${writer}" "${standby}" "${new_role}" "${new_file}"
  store_replication_files "${new_role}" "${new_file}"
  wait_for_identity "${writer}" "${new_role}" || die 1 'the standby stopped streaming as expected'
  database::bare "${writer}" <<< "alter role ${old_role} nologin" > /dev/null
  if [[ "${keep_old}" == 'no' ]]; then
    forget_identity "${writer}" "${old_role}"
  fi
  printf 'replication identity is now %s\n' "${new_role}"
}

# Rotate the superuser password in place; a failed check puts the old password back.
# Usage: rotate_superuser WRITER STANDBY NEW_FILE OLD_COPY
rotate_superuser() {
  log INFO 'rotating the superuser secret in place'
  local writer="${1:?writer required}"
  local standby="${2:?standby required}"
  local new_file="${3:?new file required}"
  local old_copy="${4:?old copy required}"
  local sql="ALTER ROLE postgres PASSWORD :'pw';"

  cp -- "${SUPERUSER_KEY_PATH}" "${old_copy}"
  log INFO "CHANGE: ALTER ROLE postgres on ${writer}, ${SUPERUSER_KEY_PATH} updated"
  printf '%s\n' '\getenv pw NEWPW' "${sql}" | access::run_sql "${writer}" "${new_file}"
  cat -- "${new_file}" > "${SUPERUSER_KEY_PATH}"
  if ! access::probe_login "${standby}" "${writer}" postgres "${new_file}"; then
    printf '%s\n' '\getenv pw NEWPW' "${sql}" | access::run_sql "${writer}" "${old_copy}"
    cat -- "${old_copy}" > "${SUPERUSER_KEY_PATH}"
    die 1 'the new superuser password did not work: the old one was put back'
  fi
  if access::probe_login "${standby}" "${writer}" postgres "${old_copy}"; then
    die 1 'the old superuser password is still accepted'
  fi
  printf 'superuser password rotated\n'
}

# Rotate the chosen secret: make the new value, find the nodes, check, then rotate.
# Usage: run_rotation KIND KEEP_OLD
run_rotation() {
  log INFO 'starting the rotation'
  local kind="${1:?kind required}"
  local keep_old="${2:?keep-old flag required}"
  local writer
  local standby
  local new_file
  local old_copy

  new_file="$(mktemp "${TEMP_DIR}/${SCRIPT_NAME}-new.XXXXXX")"
  CLEANUP_PATHS+=("${new_file}")
  old_copy="$(mktemp "${TEMP_DIR}/${SCRIPT_NAME}-old.XXXXXX")"
  CLEANUP_PATHS+=("${old_copy}")
  openssl rand -hex 24 > "${new_file}"
  writer="$(find_writer)"
  standby="${STANDBY_CONTAINER}"
  if [[ "${writer}" == "${STANDBY_CONTAINER}" ]]; then
    standby="${PRIMARY_CONTAINER}"
  fi
  check_ready "${writer}"
  if [[ "${kind}" == 'replication' ]]; then
    rotate_replication "${writer}" "${standby}" "${new_file}" "${keep_old}"
  else
    rotate_superuser "${writer}" "${standby}" "${new_file}" "${old_copy}"
  fi
}

# Script entry point.
main() {
  local kind='replication'
  local keep_old='no'
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --secret)
        (( $# >= 2 )) || die 2 '--secret needs a value'
        kind="${2}"
        shift 2
        ;;
      --keep-old)
        keep_old='yes'
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        die 2 "unknown option: ${1} (try --help)"
        ;;
      *)
        die 2 "unexpected argument: ${1} (try --help)"
        ;;
    esac
  done

  (( $# == 0 )) || die 2 "unexpected argument: ${1} (try --help)"
  [[ "${kind}" == 'replication' || "${kind}" == 'superuser' ]] ||
    die 2 'secret is replication or superuser'
  require_commands cat cp mktemp openssl sleep
  lock::acquire "${REBUILD_MARKER_DIR}" "${SCRIPT_NAME}"
  run_rotation "${kind}" "${keep_old}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
