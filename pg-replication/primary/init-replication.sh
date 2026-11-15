#!/usr/bin/env bash
# script-kind: executable
# Purpose: Create the replication role and slot on the primary, on its first initialisation.
# Usage: init-replication.sh [-h | --help]
# Requires: cat date id mktemp mv psql rm
# Exit codes: 0 success, 1 failure, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: all of these come from docker-compose.yml and are required (checked in
# check_environment). RUN_LOG_DIR defaults to the temporary directory.
readonly PGDATA="${PGDATA:-}"
readonly POSTGRES_USER="${POSTGRES_USER:-}"
readonly POSTGRES_DB="${POSTGRES_DB:-}"
readonly REPLICATION_USER="${REPLICATION_USER:-}"
readonly REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-}"
readonly STANDBY_SLOT="${STANDBY_SLOT:-}"
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
Usage: init-replication.sh [-h | --help]

Runs once, on first initialisation of the primary's data directory. The official
postgres image executes every script in /docker-entrypoint-initdb.d the first
time the data volume is empty; it does not run again on later restarts.

  1. Create a login role the standby will use to stream WAL.
  2. Create a replication slot, so the primary keeps WAL until the standby has
     received it.
  3. Allow that role to connect for replication (pg_hba.conf).

Environment (all required, set in docker-compose.yml): PGDATA, POSTGRES_USER,
POSTGRES_DB, REPLICATION_USER, REPLICATION_PASSWORD, STANDBY_SLOT.
RUN_LOG_DIR is the directory for the run log (default: temporary directory).

Exit codes: 0 success, 1 failure, 2 usage or configuration error
USAGE
}

# Fail early if a required environment value is missing.
check_environment() {
  if [[ -z "${PGDATA}" ]]; then
    die 2 'PGDATA must be set'
  fi
  if [[ -z "${POSTGRES_USER}" ]]; then
    die 2 'POSTGRES_USER must be set'
  fi
  if [[ -z "${POSTGRES_DB}" ]]; then
    die 2 'POSTGRES_DB must be set'
  fi
  if [[ -z "${REPLICATION_USER}" ]]; then
    die 2 'REPLICATION_USER must be set'
  fi
  if [[ -z "${REPLICATION_PASSWORD}" ]]; then
    die 2 'REPLICATION_PASSWORD must be set'
  fi
  if [[ -z "${STANDBY_SLOT}" ]]; then
    die 2 'STANDBY_SLOT must be set'
  fi
}

# Create this run's log file in RUN_LOG_DIR and say which execution it records.
start_run_log() {
  local stamp
  local cmd
  local final
  local user
  local arg
  local names=''
  local others=0

  for cmd in date id mktemp mv; do
    command -v "${cmd}" > /dev/null || die 1 "missing required command: ${cmd}"
  done
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$(mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-${stamp}-$$.XXXXXX")"
  final="${RUN_LOG%.*}.log"
  mv -- "${RUN_LOG}" "${final}"
  RUN_LOG="${final}"
  user="$(id -un 2> /dev/null || id -u)"
  log INFO "started ${SCRIPT_NAME} (process $$)"
  log INFO "user ${user} on host ${HOSTNAME}"
  log INFO "directory ${PWD}, script ${0}"
  for arg in "$@"; do
    if [[ "${arg}" == --* ]]; then
      names+=" ${arg%%=*}"
    elif [[ "${arg}" == -?* ]]; then
      names+=" ${arg:0:2}"
    else
      others=$(( others + 1 ))
    fi
  done
  log INFO "options${names:- none} (${others} other arguments)"
}

# Remove the temporary paths of the run, write the last log line, and say where the log is.
end_run_log() {
  local status="${1:?status required}"

  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    if ! rm -rf -- "${CLEANUP_PATHS[@]:?no paths to remove}"; then
      log WARN 'some temporary paths could not be removed'
    fi
  fi
  if [[ -n "${RUN_LOG}" ]]; then
    log INFO "finished with status ${status} after ${SECONDS} seconds"
    printf 'log: %s\n' "${RUN_LOG}" >&2
  fi
}

# Record how the run ended: the EXIT handler.
cleanup() {
  local status="${?}"

  end_run_log "${status}"
}

# SQL: create the replication role and the slot. The values are read from the environment by
# psql (\getenv) and quoted by psql, so the shell never puts a password into the SQL text.
# A physical slot makes the primary retain WAL until the standby has received it (bounded by
# max_slot_wal_keep_size).
sql_role_and_slot() {
  cat <<'SQL'
\getenv repl_user REPLICATION_USER
\getenv repl_password REPLICATION_PASSWORD
\getenv standby_slot STANDBY_SLOT
CREATE ROLE :"repl_user" WITH REPLICATION LOGIN PASSWORD :'repl_password';
SELECT pg_create_physical_replication_slot(:'standby_slot');
SQL
}

# Steps 1 and 2: run the SQL against the freshly created database. ON_ERROR_STOP makes psql
# exit non-zero on the first error, so initialisation stops.
create_role_and_slot() {
  log INFO "creating role ${REPLICATION_USER} and slot ${STANDBY_SLOT}"
  psql -v ON_ERROR_STOP=1 \
    --username "${POSTGRES_USER}" \
    --dbname "${POSTGRES_DB}" \
    <<< "$(sql_role_and_slot)"
}

# Step 3: allow the standby (anywhere on the Docker network) to stream WAL. "replication" is
# a special pseudo-database; "all" does not match it. The line is appended to pg_hba.conf,
# which is read when the server starts after initialisation.
allow_replication() {
  log INFO "allowing ${REPLICATION_USER} to connect for replication"
  printf '%s\n' "host replication ${REPLICATION_USER} all scram-sha-256" >> "${PGDATA}/pg_hba.conf"
}

# Handle a signal that ends the run: say which one, then stop with the status a shell gives it.
on_signal() {
  local name="${1:?signal name required}"
  local number

  number="$(kill -l "${name}")"
  die "$(( 128 + number ))" "interrupted by SIG${name}"
}

# Install the traps for the signals that end a run (INT, TERM, HUP); call it after the two traps.
trap_signals() {
  local name

  for name in INT TERM HUP; do
    trap "on_signal ${name}" "${name}"
  done
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
  check_environment

  printf '[primary-init] initialising primary: role=%s slot=%s\n' \
    "${REPLICATION_USER}" \
    "${STANDBY_SLOT}"
  create_role_and_slot
  allow_replication
  printf '[primary-init] primary initialisation complete\n'
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
