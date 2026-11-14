#!/usr/bin/env bash
# script-kind: executable
# Purpose: Switch the primary between asynchronous and synchronous replication.
# Usage: sync-mode.sh [-h | --help] [--mode async|sync|status]
# Requires: cat date docker mktemp rm sleep
# Exit codes: 0 success, 1 failure, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER names the primary container. STANDBY_NAME must equal the
# application_name the standby connects with (set in standby/entrypoint.sh).
# RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_NAME="${STANDBY_NAME:-standby1}"
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
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
Usage: sync-mode.sh [-h | --help] [--mode async|sync|status]

Switch the primary between asynchronous and synchronous replication. No restart
is needed. Whatever the mode, finish by printing the current setting and the
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

# Run psql inside the primary container. Extra arguments (for example -c SQL) are passed through.
psql_primary() {
  docker exec -i "${PRIMARY_CONTAINER}" psql -U postgres -d appdb -X -v ON_ERROR_STOP=1 "$@"
}

# Make a commit wait for the standby (FIRST 1 = the first listed standby must confirm it).
# ALTER SYSTEM writes postgresql.auto.conf; pg_reload_conf() applies it without a restart.
enable_sync() {
  log INFO "CHANGE: enabling synchronous replication (standby=${STANDBY_NAME})"
  psql_primary -c "alter system set synchronous_standby_names = 'FIRST 1 (${STANDBY_NAME})'"
  psql_primary -c 'select pg_reload_conf()' > /dev/null
  printf 'Synchronous replication ON. Writes will block if the standby is unavailable.\n'
}

# An empty synchronous_standby_names means no commit waits for a standby.
enable_async() {
  log INFO 'CHANGE: switching to asynchronous replication'
  psql_primary -c 'alter system reset synchronous_standby_names'
  psql_primary -c 'select pg_reload_conf()' > /dev/null
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

  start_run_log

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

main "$@"
