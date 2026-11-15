#!/usr/bin/env bash
# script-kind: executable
# Purpose: Start the primary or the standby database container and wait until it is healthy.
# Usage: bring-up-database.sh [-h | --help] --database primary|standby
# Requires: cat
# Exit codes: 0 success, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose created
# them (they keep these names after a failover, whatever their role then is).
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly HEALTH_ATTEMPTS=60
readonly HEALTH_PAUSE_SECONDS=1

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"

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

# Print the other container of the pair: the standby for the primary and the reverse.
peer_of_container() {
  local container="${1:?container required}"

  if [[ "${container}" == "${PRIMARY_CONTAINER}" ]]; then
    printf '%s\n' "${STANDBY_CONTAINER}"
  else
    printf '%s\n' "${PRIMARY_CONTAINER}"
  fi
}

# Stop the started container again if it and its peer are both writable (split-brain).
guard_against_split_brain() {
  local container="${1:?container required}"
  local peer="${2:?peer required}"
  local peer_running
  local own_state
  local peer_state

  peer_running="$(container::is_running "${peer}")"
  if [[ "${peer_running}" != 'true' ]]; then
    return 0
  fi
  container::wait_healthy "${peer}" "${HEALTH_ATTEMPTS}" "${HEALTH_PAUSE_SECONDS}"
  own_state="$(database::in_recovery "${container}")"
  peer_state="$(database::in_recovery "${peer}")"
  if [[ "${own_state}" == 'f' && "${peer_state}" == 'f' ]]; then
    log ERROR "DECISION: ${container} and ${peer} are both writable: stopping ${container}"
    container::stop "${container}"
    die 1 "split-brain prevented: ${container} was stopped again"
  fi
}

# Start the database's container if needed, wait until it is healthy and guard against split-brain.
bring_up() {
  local database="${1:?database required}"
  local container
  local running

  log INFO 'bringing up the database'
  container="$(container::name_of "${database}" "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}")"
  running="$(container::is_running "${container}")"
  if [[ "${running}" == 'true' ]]; then
    log INFO "${container} is already running"
  else
    container::start "${container}"
  fi
  container::wait_healthy "${container}" "${HEALTH_ATTEMPTS}" "${HEALTH_PAUSE_SECONDS}"
  guard_against_split_brain "${container}" "$(peer_of_container "${container}")"
  printf '%s is up\n' "${container}"
}

# Script entry point.
main() {
  local database=''
  start_run_log "$@"

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

trap_signals

main "$@"
