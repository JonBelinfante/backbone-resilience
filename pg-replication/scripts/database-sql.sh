#!/usr/bin/env bash
# script-kind: executable
# Purpose: Run SQL in a database container with psql, or answer whether it is in recovery.
# Usage: database-sql.sh [-h | --help] --container NAME [--bare] [--ask recovery]
# Requires: cat date mktemp rm
# Exit codes: 0 success, 1 failure (psql or docker failed), 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"

# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"

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
Usage: database-sql.sh [-h | --help] --container NAME [--bare] [--ask recovery]
         [-- PSQL_ARGUMENT ...]

Small reusable way for the other scripts to run SQL: call it and read its output.
It runs psql inside the container as the postgres user on appdb and stops at the
first SQL error. The SQL is read from standard input.

  --container NAME  the database container to run psql in
  --bare            bare output for scripts: unaligned, no headers, no decoration
  --ask recovery    print t if the server is in recovery (a standby), f if it accepts writes
  -- ARGUMENT ...   any further psql arguments, passed unchanged

Examples:
  database-sql.sh --container pg-primary --bare <<< 'select 1'
  database-sql.sh --container pg-standby --ask recovery

Environment: RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 success, 1 failure (psql or docker failed), 2 usage or configuration error
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

# Run psql in the container with the arguments given, or answer a named question.
run_sql() {
  log INFO 'running SQL'
  local container="${1-}"
  local ask="${2-}"
  local -a psql_args=("${@:3}")

  [[ -n "${container}" ]] || die 2 '--container is required (try --help)'
  if [[ -n "${ask}" ]]; then
    [[ "${ask}" == 'recovery' ]] || die 2 "unknown question: ${ask} (use recovery)"
    database::in_recovery "${container}"
  else
    database::run "${container}" "${psql_args[@]}"
  fi
}

# Script entry point.
main() {
  local container=''
  local ask=''
  local -a psql_args=()
  require_commands cat date mktemp rm
  start_run_log
  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --container)
        (( $# >= 2 )) || die 2 '--container needs a value'
        container="${2}"
        shift 2
        ;;
      --bare)
        psql_args+=(-Atq)
        shift
        ;;
      --ask)
        (( $# >= 2 )) || die 2 '--ask needs a value'
        ask="${2}"
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
  run_sql "${container}" "${ask}" "${psql_args[@]}" "$@"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
