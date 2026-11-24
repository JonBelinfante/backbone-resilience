#!/usr/bin/env bash
# script-kind: executable
# Purpose: Switch the primary between asynchronous and synchronous replication.
# Usage: set-replication-mode.sh [-h | --help] [--mode async|sync|status]
# Requires: cat sleep
# Exit codes: 0 success, 1 failure, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER names the primary container. STANDBY_NAME must equal the
# application_name the standby connects with (set in standby/entrypoint.sh).
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_NAME="${STANDBY_NAME:-standby1}"
readonly REBUILD_MARKER_DIR="${REBUILD_MARKER_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/mode.sh
source "${SCRIPT_DIR}../lib/mode.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: set-replication-mode.sh [-h | --help] [--mode async|sync|status]

Switch the primary between asynchronous and synchronous replication. No restart
is needed. The mode is recorded, so a rejoin can switch sync on again after a failover. Whatever the mode, finish by printing the current setting and the
standby's sync_state.

Modes:
  async   commit returns once the primary has flushed WAL. RPO > 0 (lag). A
          standby outage never blocks writes.
  sync    commit waits until the standby has flushed WAL. RPO = 0. If the
          standby is down, writes BLOCK.
  status  change nothing; only report (the default)

Environment:
  PRIMARY_CONTAINER  name of the primary container (default: pg-primary)
  STANDBY_NAME       application_name the standby connects with (default: standby1)
  RUN_LOG_DIR        directory for this run's log file, which must exist
                     (default: temporary directory)

Exit codes: 0 success, 1 failure, 2 usage or configuration error
USAGE
}

# Run psql inside the primary container. Extra arguments (for example -c SQL) are passed through.
psql_primary() {
  database::run "${PRIMARY_CONTAINER}" "$@"
}

# Make a commit wait for the standby (FIRST 1 = the first listed standby must confirm it).
# ALTER SYSTEM writes postgresql.auto.conf; pg_reload_conf() applies it without a restart.
enable_sync() {
  log INFO "CHANGE: enabling synchronous replication (standby=${STANDBY_NAME})"
  psql_primary -c "alter system set synchronous_standby_names = 'FIRST 1 (${STANDBY_NAME})'"
  psql_primary -c 'select pg_reload_conf()' > /dev/null
  mode::record "${REBUILD_MARKER_DIR}" sync
  printf 'Synchronous replication ON. Writes will block if the standby is unavailable.\n'
}

# An empty synchronous_standby_names means no commit waits for a standby.
enable_async() {
  log INFO 'CHANGE: switching to asynchronous replication'
  psql_primary -c 'alter system reset synchronous_standby_names'
  psql_primary -c 'select pg_reload_conf()' > /dev/null
  mode::record "${REBUILD_MARKER_DIR}" async
  printf 'Asynchronous replication ON.\n'
}

# Make the change the mode asks for. An unknown mode changes nothing and fails with status 2.
apply_mode() {
  local mode="${1:?mode required}"

  case "${mode}" in
    sync)
      enable_sync
      ;;
    async)
      enable_async
      ;;
    status)
      log INFO 'status only: nothing to change'
      ;;
    *)
      die 2 "unknown mode: ${mode} (use async, sync or status)"
      ;;
  esac
}

# Print the current setting and the standby's state. The pause gives the reload a moment
# to take effect so sync_state is current. sync_state is 'sync' when the standby is the
# synchronous one, 'async' otherwise.
report_status() {
  sleep 1
  psql_primary -c 'show synchronous_standby_names'
  psql_primary -c 'select application_name, state, sync_state from pg_stat_replication'
}

# Script entry point.
main() {
  local mode='status'
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --mode)
        (( $# >= 2 )) || die 2 '--mode needs a value'
        mode="${2}"
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
  apply_mode "${mode}"
  report_status
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
