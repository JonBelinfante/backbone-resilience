#!/usr/bin/env bash
# script-kind: executable
# Purpose: Run SQL in a database container with psql, or answer whether it is in recovery.
# Usage: run-database-sql.sh [-h | --help] --container NAME [--bare] [--ask recovery]
# Requires: cat
# Exit codes: 0 success, 1 failure (psql or docker failed), 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: run-database-sql.sh [-h | --help] --container NAME [--bare] [--ask recovery]
         [-- PSQL_ARGUMENT ...]

Command-line wrapper over lib/database.sh. Runs the SQL given on standard input with psql
inside a database container, as the postgres user on appdb, and stops at the first SQL
error. Other scripts import database.sh instead of calling this one; it is here for use
by hand.

  --container NAME  the database container to run psql in
  --bare            bare output for scripts: unaligned, no headers, no decoration
  --ask recovery    print t if the server is in recovery (a standby), f if it accepts writes
  -- ARGUMENT ...   any further psql arguments, passed unchanged

Examples:
  run-database-sql.sh --container pg-primary --bare <<< 'select 1'
  run-database-sql.sh --container pg-standby --ask recovery

Environment: RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 success, 1 failure (psql or docker failed), 2 usage or configuration error
USAGE
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
  start_run_log "$@"
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

trap_signals

main "$@"
