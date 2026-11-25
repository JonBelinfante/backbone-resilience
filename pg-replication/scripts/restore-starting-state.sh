#!/usr/bin/env bash
# script-kind: executable
# Purpose: Return the two databases to their starting roles: primary writes, standby replicates.
# Usage: restore-starting-state.sh [-h | --help]
# Requires: bash cat sleep
# Exit codes: 0 success, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose created
# them (they keep these names after a failover, whatever their role then is). REBUILD_MARKER_DIR
# is where maintenance state is kept: rebuild markers and the maintenance lock.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly REBUILD_MARKER_DIR="${REBUILD_MARKER_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly STREAM_ATTEMPTS=30
readonly STREAM_PAUSE_SECONDS=2
readonly RESTORE_TIMELINE_READ="pg_controldata \"\$1\""
readonly RESTORE_TIMELINE_PARSE="sed -n 's/^Latest checkpoint.s TimeLineID: *//p'"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/lock.sh
source "${SCRIPT_DIR}../lib/lock.sh"
# shellcheck source=../lib/fence.sh
source "${SCRIPT_DIR}../lib/fence.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: restore-starting-state.sh [-h | --help]

Return the databases to their starting roles: pg-primary accepting writes and
pg-standby replicating from it. Run it after a failover experiment, or let the
round-trip test run it. It reads the current roles and decides:
  primary writer, standby replica   nothing to do (the standby must be streaming)
  one node stopped, the other fine  start the stopped node
  standby cannot start or is not    rebuild it: empty it and copy the primary
    streaming
  primary replica, standby writer   rebuild the primary from the writer, then fail back
  standby is the writer             fail back: rebuild the primary as its standby, stop
                                    the standby, promote the primary, rebuild the standby
Any other combination is refused. Failing back under async replication can lose writes.

Environment:
  PRIMARY_CONTAINER  the node that should be the writer (default: pg-primary)
  STANDBY_CONTAINER  the node that should replicate (default: pg-standby)
  RUN_LOG_DIR        directory for this run's log file (default: temporary directory)

Exit codes: 0 success, 1 failure, 2 usage or configuration error
USAGE
}

# Print stopped, writer or replica for a container.
role_of_container() {
  local container="${1:?container required}"
  local running
  local recovery

  running="$(container::is_running "${container}")"
  if [[ "${running}" != 'true' ]]; then
    printf 'stopped\n'
    return 0
  fi
  recovery="$(database::in_recovery "${container}")"
  if [[ "${recovery}" == 't' ]]; then
    printf 'replica\n'
  else
    printf 'writer\n'
  fi
}

# Run a sibling script with the container names for its two roles: the node that is stopped
# (or being replaced) and the node that is, or becomes, the writer.
# Usage: run_with_roles STOPPED_NODE WRITER_NODE SCRIPT [ARGUMENT ...]
run_with_roles() {
  local stopped="${1:?stopped node required}"
  local writer="${2:?writer node required}"
  local script="${3:?script required}"
  local path="${SCRIPT_DIR}${script}"
  local -a command=(env "PRIMARY_CONTAINER=${stopped}" "STANDBY_CONTAINER=${writer}")

  command+=(bash "${path}" "${@:4}")
  "${command[@]}"
}

# Wait until a node that is running is healthy; a stopped node is left alone.
# Usage: wait_for_running_node DATABASE CONTAINER
wait_for_running_node() {
  local database="${1:?database required}"
  local container="${2:?container required}"
  local running

  running="$(container::is_running "${container}")"
  if [[ "${running}" == 'true' ]]; then
    bash "${SCRIPT_DIR}bring-up-database.sh" --database "${database}"
  fi
}

# Succeed if the primary reports one streaming standby within STREAM_ATTEMPTS tries.
wait_for_streaming() {
  local attempt=1
  local streaming

  while (( attempt <= STREAM_ATTEMPTS )); do
    streaming="$(database::streaming_count "${PRIMARY_CONTAINER}")"
    if [[ "${streaming}" == '1' ]]; then
      log INFO "${STANDBY_CONTAINER} is streaming from ${PRIMARY_CONTAINER}"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep "${STREAM_PAUSE_SECONDS}"
  done
  log WARN "${STANDBY_CONTAINER} is not streaming after ${STREAM_ATTEMPTS} attempts"
  return 1
}

# Replace the standby's data with a fresh copy of the primary: stop it, empty it, copy.
rebuild_standby() {
  log INFO 'DECISION: the standby cannot be trusted: rebuilding it from the primary'
  bash "${SCRIPT_DIR}bring-down-database.sh" --database standby
  run_with_roles \
    "${STANDBY_CONTAINER}" \
    "${PRIMARY_CONTAINER}" \
    promote-primary-to-standby.sh \
    --clone
}

# Start the stopped standby; if it cannot be started safely (it was a writer too), rebuild it.
start_or_rebuild_standby() {
  if ! bash "${SCRIPT_DIR}bring-up-database.sh" --database standby; then
    rebuild_standby
  fi
}

# Rebuild the standby if the primary does not report it as streaming.
rebuild_standby_unless_streaming() {
  if ! wait_for_streaming; then
    rebuild_standby
  fi
}

# Return the writer role to the primary after a failover. The primary is rebuilt as a standby
# of the current writer first if it is stopped, then the roles are swapped back.
fail_back() {
  local primary_role="${1:?primary role required}"

  log INFO 'failing back to the original roles'
  if [[ "${primary_role}" == 'stopped' ]]; then
    run_with_roles "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}" promote-primary-to-standby.sh
  fi
  bash "${SCRIPT_DIR}bring-down-database.sh" --database standby
  run_with_roles "${STANDBY_CONTAINER}" "${PRIMARY_CONTAINER}" promote-standby-to-primary.sh
  run_with_roles "${STANDBY_CONTAINER}" "${PRIMARY_CONTAINER}" promote-primary-to-standby.sh
}

# Print the timeline a stopped node's data directory is on, or 0 if it cannot be read (a rebuild
# that was killed part way can leave a directory that pg_controldata does not read).
# Usage: timeline_of NODE
timeline_of() {
  local node="${1:?node required}"
  local program="${RESTORE_TIMELINE_READ} | ${RESTORE_TIMELINE_PARSE}"
  local timeline

  if timeline="$(fence::in_volume "${node}" "${program}")"; then
    printf '%s\n' "${timeline:-0}"
  else
    printf '0\n'
  fi
}

# Print the node to start as the writer when both are stopped: the one without the replica
# marker (standby.signal). If both or neither have it, the one on the newer timeline wins, and
# a tie goes to the primary.
writer_candidate() {
  local primary_fenced
  local standby_fenced
  local primary_timeline
  local standby_timeline

  primary_fenced="$(fence::is_applied "${PRIMARY_CONTAINER}")"
  standby_fenced="$(fence::is_applied "${STANDBY_CONTAINER}")"
  if [[ "${primary_fenced}" != "${standby_fenced}" ]]; then
    if [[ "${primary_fenced}" == 'no' ]]; then
      printf '%s\n' "${PRIMARY_CONTAINER}"
    else
      printf '%s\n' "${STANDBY_CONTAINER}"
    fi
    return 0
  fi
  primary_timeline="$(timeline_of "${PRIMARY_CONTAINER}")"
  standby_timeline="$(timeline_of "${STANDBY_CONTAINER}")"
  if (( standby_timeline > primary_timeline )); then
    printf '%s\n' "${STANDBY_CONTAINER}"
  else
    printf '%s\n' "${PRIMARY_CONTAINER}"
  fi
}

# Both nodes are stopped (a second failure, for example during a rejoin): start the node most
# likely to hold the latest writes as the writer. The roles are then restored from there.
start_writer_candidate() {
  local candidate
  local database

  candidate="$(writer_candidate)"
  if [[ "${candidate}" == "${PRIMARY_CONTAINER}" ]]; then
    database=primary
  else
    database=standby
  fi
  log INFO "DECISION: both nodes are stopped: starting ${candidate} as the writer"
  bash "${SCRIPT_DIR}bring-up-database.sh" --database "${database}"
}

# Read the roles of both nodes and bring them back to writer and replica.
restore_starting_state() {
  local primary_role
  local standby_role

  log INFO 'restoring the starting state'
  wait_for_running_node primary "${PRIMARY_CONTAINER}"
  wait_for_running_node standby "${STANDBY_CONTAINER}"
  primary_role="$(role_of_container "${PRIMARY_CONTAINER}")"
  standby_role="$(role_of_container "${STANDBY_CONTAINER}")"
  log INFO "DECISION: roles are ${primary_role}/${standby_role} (primary/standby)"
  case "${primary_role}/${standby_role}" in
    writer/replica)
      rebuild_standby_unless_streaming
      ;;
    writer/stopped)
      start_or_rebuild_standby
      rebuild_standby_unless_streaming
      ;;
    stopped/replica)
      bash "${SCRIPT_DIR}bring-up-database.sh" --database primary
      ;;
    stopped/writer | replica/stopped)
      fail_back "${primary_role}"
      ;;
    stopped/stopped)
      start_writer_candidate
      restore_starting_state
      ;;
    replica/writer)
      log INFO 'DECISION: the primary is a replica of unknown history: rebuilding it first'
      bash "${SCRIPT_DIR}bring-down-database.sh" --database primary
      fail_back stopped
      ;;
    *)
      die 1 "cannot restore from roles ${primary_role}/${standby_role}: repair by hand"
      ;;
  esac
}

# Wait until the standby has replayed everything the writer has written so far. Streaming alone
# can still mean a backlog (a node just cloned replays for a while), and a test that starts from
# this state must not find the standby behind.
wait_until_caught_up() {
  log INFO "waiting for ${STANDBY_CONTAINER} to replay what ${PRIMARY_CONTAINER} has written"
  local position

  position="$(database::bare "${PRIMARY_CONTAINER}" <<< 'select pg_current_wal_lsn()')"
  database::wait_for_replay "${STANDBY_CONTAINER}" "${position}"
}

# Fail unless the primary is the writer and the standby is a replica.
check_starting_state() {
  local primary_role
  local standby_role

  primary_role="$(role_of_container "${PRIMARY_CONTAINER}")"
  standby_role="$(role_of_container "${STANDBY_CONTAINER}")"
  if [[ "${primary_role}/${standby_role}" != 'writer/replica' ]]; then
    die 1 "restore failed: roles are ${primary_role}/${standby_role} (primary/standby)"
  fi
  wait_for_streaming || die 1 "restore failed: ${STANDBY_CONTAINER} is not streaming"
  wait_until_caught_up
  log INFO 'starting state confirmed'
  printf '%s accepts writes and %s is streaming from it\n' \
    "${PRIMARY_CONTAINER}" \
    "${STANDBY_CONTAINER}"
}

# Switch the writer to asynchronous replication, which is the starting state. A test that ended in
# synchronous mode would otherwise leave every commit waiting for a standby that may be detached.
set_asynchronous() {
  log INFO 'DECISION: the starting state is asynchronous: resetting the writer to async'
  bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
}

# Script entry point.
main() {
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
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
  require_commands bash cat sleep
  lock::acquire "${REBUILD_MARKER_DIR}" "${SCRIPT_NAME}"
  restore_starting_state
  check_starting_state
  set_asynchronous
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
