#!/usr/bin/env bash
# script-kind: executable
# Purpose: Return the two databases to their starting roles: primary writes, standby replicates.
# Usage: restore-starting-state.sh [-h | --help]
# Requires: bash cat date docker mktemp rm
# Exit codes: 0 success, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose created
# them (they keep these names after a failover, whatever their role then is).
# RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
declare RUN_LOG=''
declare -a CLEANUP_PATHS=()

# Append a line to the run log and, for WARN and ERROR, to standard error.
log() {
  local level="${1:?level required}"
  local message="${2:?message required}"
  local now="${EPOCHREALTIME}"
  local fraction="${now#*[.,]}"
  local stamp
  local line

  TZ=UTC printf -v stamp '%(%Y-%m-%dT%H:%M:%S)T' "${now%%[.,]*}"
  line="${stamp}.${fraction:0:3}Z ${level} ${message}"
  if [[ -n "${RUN_LOG}" ]]; then
    printf '%s\n' "${line}" >> "${RUN_LOG}"
  fi
  if [[ "${level}" != 'INFO' ]]; then
    printf '%s: %s\n' "${SCRIPT_NAME}" "${line}" >&2
  fi
}

# Log an error, then exit with the given status.
die() {
  local status="${1:?status required}"
  local message="${2:?message required}"

  log ERROR "${message}"
  exit "${status}"
}

# Log where a command failed: its line, the function it was in, and the command itself.
on_error() {
  local status="${?}"
  local line_no="${1:?line required}"
  local command_text="${2:?command required}"
  local where="${FUNCNAME[1]:-main}"

  log ERROR "failed (status ${status}) at line ${line_no} in ${where}: ${command_text}"
}

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: restore-starting-state.sh [-h | --help]

Return the databases to their starting roles: pg-primary accepting writes and
pg-standby replicating from it. Run it after a failover experiment, or let the
round-trip test run it. It reads the current roles and decides:
  primary writer, standby replica   nothing to do
  one node stopped, the other fine  start the stopped node
  standby is the writer             fail back: rebuild the primary as its standby, stop
                                    the standby, promote the primary, rebuild the standby
Any other combination is refused. Failing back under asynchronous replication can lose
writes the new writer had not yet sent to the node being promoted.

Environment:
  PRIMARY_CONTAINER  the node that should be the writer (default: pg-primary)
  STANDBY_CONTAINER  the node that should replicate (default: pg-standby)
  RUN_LOG_DIR        directory for this run's log file (default: temporary directory)

Exit codes: 0 success, 1 failure, 2 usage or configuration error
USAGE
}

# Fail early if a required command is missing.
require_commands() {
  local cmd

  for cmd in "$@"; do
    command -v "${cmd}" > /dev/null || die 1 "missing required command: ${cmd}"
  done
}

# Create this run's log file in RUN_LOG_DIR and record the start.
start_run_log() {
  local stamp

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$(mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-${stamp}.XXXXXX")"
  log INFO "started ${SCRIPT_NAME}"
}

# Record how the run ended, then remove temporary files created by this script.
cleanup() {
  local status="${?}"

  log INFO "finished with status ${status}"
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    rm -f -- "${CLEANUP_PATHS[@]}"
  fi
}

# Print stopped, writer or replica for a container.
role_of_container() {
  local container="${1:?container required}"
  local running
  local recovery
  local sql='select pg_is_in_recovery()'

  running="$(bash "${SCRIPT_DIR}container-info.sh" --container "${container}")"
  if [[ "${running}" != 'true' ]]; then
    printf 'stopped\n'
    return 0
  fi
  recovery="$(docker exec "${container}" psql -U postgres -d appdb -X -Atq -c "${sql}")"
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

  running="$(bash "${SCRIPT_DIR}container-info.sh" --container "${container}")"
  if [[ "${running}" == 'true' ]]; then
    bash "${SCRIPT_DIR}bring-up-database.sh" --database "${database}"
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
      log INFO 'already in the starting state'
      ;;
    writer/stopped)
      bash "${SCRIPT_DIR}bring-up-database.sh" --database standby
      ;;
    stopped/replica)
      bash "${SCRIPT_DIR}bring-up-database.sh" --database primary
      ;;
    stopped/writer | replica/writer | replica/stopped)
      fail_back "${primary_role}"
      ;;
    *)
      die 1 "cannot restore from roles ${primary_role}/${standby_role}: repair by hand"
      ;;
  esac
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
  log INFO 'starting state confirmed'
  printf '%s accepts writes and %s replicates\n' "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"
}

# Script entry point.
main() {
  require_commands bash cat date docker mktemp rm
  start_run_log

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
  restore_starting_state
  check_starting_state
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
