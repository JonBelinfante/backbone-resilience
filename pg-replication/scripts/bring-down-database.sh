#!/usr/bin/env bash
# script-kind: executable
# Purpose: Stop the primary or the standby database container and confirm it is down.
# Usage: bring-down-database.sh [-h | --help] --database primary|standby
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
readonly STOP_TIMEOUT_SECONDS=30

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: bring-down-database.sh [-h | --help] --database primary|standby

Stop one database container, waiting for Postgres to shut down cleanly, then
confirm it is no longer running. A clean shutdown matters: pg_rewind can only
rebuild an old primary that was shut down cleanly. Stopping a container that
is already stopped changes nothing and succeeds.

Options:
  --database primary|standby  which container to stop (required)

Environment:
  PRIMARY_CONTAINER  name of the primary container (default: pg-primary)
  STANDBY_CONTAINER  name of the standby container (default: pg-standby)
  RUN_LOG_DIR        directory for this run's log file, which must exist
                     (default: temporary directory)

Exit codes: 0 success, 1 failure, 2 usage or configuration error
USAGE
}

# Fail unless the container is stopped.
check_stopped() {
  local container="${1:?container required}"
  local running

  running="$(container::is_running "${container}")"
  if [[ "${running}" != 'false' ]]; then
    die 1 "${container} is still running"
  fi
  log INFO "${container} is stopped"
}

# Stop the database's container unless it is already stopped, then confirm it is down.
bring_down() {
  local database="${1:?database required}"
  local container
  local running

  container="$(container::name_of "${database}" "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}")"
  running="$(container::is_running "${container}")"
  if [[ "${running}" == 'false' ]]; then
    log INFO "${container} is already stopped: nothing to do"
  else
    container::stop "${container}" "${STOP_TIMEOUT_SECONDS}"
  fi
  check_stopped "${container}"
  printf '%s is down\n' "${container}"
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

  bring_down "${database}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
