#!/usr/bin/env bash
# script-kind: executable
# Purpose: Start the primary or the standby database container and wait until it is healthy.
# Usage: bring-up-database.sh [-h | --help] --database primary|standby
# Requires: bash cat date docker mktemp rm sleep
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
readonly HEALTH_ATTEMPTS=60
readonly HEALTH_PAUSE_SECONDS=1
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
Usage: bring-up-database.sh [-h | --help] --database primary|standby

Start one database container and wait up to 60 seconds for its health check. This
only restarts a database; an old primary that was replaced in a failover must be
rebuilt first with promote-primary-to-standby.sh.

Safety net: if the started database is writable while the other one is also
writable (split-brain), it is stopped again and the script fails.

Options:
  --database primary|standby  which container to start (required)

Environment:
  PRIMARY_CONTAINER  name of the primary container (default: pg-primary)
  STANDBY_CONTAINER  name of the standby container (default: pg-standby)
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

# Print the other container of the pair: the standby for the primary and the reverse.
peer_of_container() {
  local container="${1:?container required}"

  if [[ "${container}" == "${PRIMARY_CONTAINER}" ]]; then
    printf '%s\n' "${STANDBY_CONTAINER}"
  else
    printf '%s\n' "${PRIMARY_CONTAINER}"
  fi
}

# Print the container's health: starting, healthy or unhealthy.
container_health() {
  local container="${1:?container required}"

  docker inspect --format '{{.State.Health.Status}}' "${container}"
}

# Print t if Postgres in the container is a standby, and f if it accepts writes.
database_is_standby() {
  local container="${1:?container required}"

  docker exec "${container}" psql -U postgres -d appdb -X -Atq -c 'select pg_is_in_recovery()'
}

# Start the container.
start_container() {
  local container="${1:?container required}"

  log INFO "CHANGE: starting ${container}"
  docker start "${container}" > /dev/null
}

# Wait until the container's health check passes, giving up after HEALTH_ATTEMPTS tries.
wait_until_healthy() {
  local container="${1:?container required}"
  local attempt=1
  local health

  while (( attempt <= HEALTH_ATTEMPTS )); do
    health="$(container_health "${container}")"
    if [[ "${health}" == 'healthy' ]]; then
      log INFO "${container} is healthy"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep "${HEALTH_PAUSE_SECONDS}"
  done
  die 1 "${container} was not healthy after ${HEALTH_ATTEMPTS} attempts"
}

# Stop the started container again if it and its peer are both writable (split-brain).
guard_against_split_brain() {
  local container="${1:?container required}"
  local peer="${2:?peer required}"
  local peer_running
  local own_state
  local peer_state

  peer_running="$(bash "${SCRIPT_DIR}container-info.sh" --container "${peer}")"
  if [[ "${peer_running}" != 'true' ]]; then
    return 0
  fi
  wait_until_healthy "${peer}"
  own_state="$(database_is_standby "${container}")"
  peer_state="$(database_is_standby "${peer}")"
  if [[ "${own_state}" == 'f' && "${peer_state}" == 'f' ]]; then
    log ERROR "DECISION: ${container} and ${peer} are both writable: stopping ${container}"
    docker stop "${container}" > /dev/null
    die 1 "split-brain prevented: ${container} was stopped again"
  fi
}

# Start the database's container if needed, wait until it is healthy and guard against split-brain.
bring_up() {
  local database="${1:?database required}"
  local container
  local running

  log INFO 'bringing up the database'
  container="$(bash "${SCRIPT_DIR}container-info.sh" --database "${database}")"
  running="$(bash "${SCRIPT_DIR}container-info.sh" --container "${container}")"
  if [[ "${running}" == 'true' ]]; then
    log INFO "${container} is already running"
  else
    start_container "${container}"
  fi
  wait_until_healthy "${container}"
  guard_against_split_brain "${container}" "$(peer_of_container "${container}")"
  printf '%s is up\n' "${container}"
}

# Script entry point.
main() {
  local database=''

  require_commands bash cat date docker mktemp rm sleep
  start_run_log

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --database)
        (( $# >= 2 )) || die 2 '--database needs a value'
        database="${2}"
        shift 2
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
  [[ -n "${database}" ]] || die 2 '--database is required (primary or standby)'

  bring_up "${database}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
