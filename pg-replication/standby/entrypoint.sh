#!/usr/bin/env bash
# script-kind: executable
# Purpose: Bootstrap the standby from the primary on first start, then run postgres as a replica.
# Usage: entrypoint.sh [-h | --help] -- COMMAND [ARGUMENT ...]
# Requires: cat chmod chown date find gosu id mkdir mktemp mv pg_isready rm sleep
# Exit codes: 0 success, 1 failure, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PGDATA, PRIMARY_HOST, REPLICATION_USER_FILE and REPLICATION_PASSWORD_FILE (the
# paths of the files that hold the replication role name and password) and POSTGRES_USER are
# required (checked in check_environment). PRIMARY_PORT defaults to 5432, STANDBY_NAME to
# standby1, and STANDBY_SLOT to standby1_slot. RUN_LOG_DIR defaults to the temporary directory.
readonly PGDATA="${PGDATA:-}"
readonly PRIMARY_HOST="${PRIMARY_HOST:-}"
readonly PRIMARY_PORT="${PRIMARY_PORT:-5432}"
readonly REPLICATION_USER_FILE="${REPLICATION_USER_FILE:-}"
readonly REPLICATION_PASSWORD_FILE="${REPLICATION_PASSWORD_FILE:-}"
readonly POSTGRES_USER="${POSTGRES_USER:-}"
readonly STANDBY_NAME="${STANDBY_NAME:-standby1}"
readonly STANDBY_SLOT="${STANDBY_SLOT:-standby1_slot}"
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
readonly CLONE_ATTEMPTS=30
readonly INTEGER_PATTERN='^[0-9]+$'
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

# Fail early if a required command is missing.
require_commands() {
  local cmd

  for cmd in "$@"; do
    command -v "${cmd}" > /dev/null || die 1 "missing required command: ${cmd}"
  done
}

# Fail early if a value is not a whole number.
require_integer() {
  local name="${1:?name required}"
  local value="${2:?value required}"

  if [[ ! "${value}" =~ ${INTEGER_PATTERN} ]]; then
    die 2 "${name} must be a whole number, got: ${value}"
  fi
}

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: entrypoint.sh [-h | --help] -- COMMAND [ARGUMENT ...]

Bootstraps the standby from the primary on first start, then runs COMMAND (postgres
and its options) as a streaming replica. On later starts the existing data
directory is reused and streaming resumes where it left off.

  1. If the data directory is empty (first start): wait for the primary, clone it
     with pg_basebackup (retrying, because the primary may still be starting), and
     mark the clone as a standby that streams from the primary.
  2. Hand over to COMMAND with exec, so postgres becomes PID 1 and receives
     Docker's stop signals directly. gosu drops root to the postgres user.

The command must follow `--` (docker-compose.yml: entrypoint ends with "--").

Environment: PGDATA, PRIMARY_HOST, REPLICATION_USER_FILE, REPLICATION_PASSWORD_FILE (paths of
Docker secret files holding the replication role and its password) and POSTGRES_USER are
required. PRIMARY_PORT (5432), STANDBY_NAME (standby1) and STANDBY_SLOT (standby1_slot) have
defaults. RUN_LOG_DIR is the run log directory.

Exit codes: 0 success, 1 failure, 2 usage or configuration error
USAGE
}

# Fail early if a required environment value is missing.
check_environment() {
  if [[ -z "${PGDATA}" ]]; then
    die 2 'PGDATA must be set'
  fi
  if [[ -z "${PRIMARY_HOST}" ]]; then
    die 2 'PRIMARY_HOST must be set'
  fi
  if [[ -z "${REPLICATION_USER_FILE}" ]]; then
    die 2 'REPLICATION_USER_FILE must be set'
  fi
  if [[ ! -r "${REPLICATION_USER_FILE}" ]]; then
    die 2 'the file named by REPLICATION_USER_FILE is not readable'
  fi
  if [[ -z "${REPLICATION_PASSWORD_FILE}" ]]; then
    die 2 'REPLICATION_PASSWORD_FILE must be set'
  fi
  if [[ ! -r "${REPLICATION_PASSWORD_FILE}" ]]; then
    die 2 'the file named by REPLICATION_PASSWORD_FILE is not readable'
  fi
  if [[ -z "${POSTGRES_USER}" ]]; then
    die 2 'POSTGRES_USER must be set'
  fi
  require_integer PRIMARY_PORT "${PRIMARY_PORT}"
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

# Record a progress message in the run log and print it on standard output, where docker
# captures it (see `docker logs -t pg-standby` or scripts/collect-logs.sh).
announce() {
  local message="${1:?message required}"

  log INFO "${message}"
  printf '[standby] %s\n' "${message}"
}

# Postgres refuses to start unless the directory is owned by the postgres user and mode 0700.
prepare_data_directory() {
  mkdir -p "${PGDATA}"
  chown postgres:postgres "${PGDATA}"
  chmod 0700 "${PGDATA}"
}

# Wait until the primary is up (pg_isready exits 0 when it accepts connections).
wait_for_primary() {
  until pg_isready -q -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${POSTGRES_USER}"; do
    announce 'waiting for primary...'
    sleep 1
  done
}

# Clone the primary once. -X stream copies WAL generated during the backup, -S attaches to the
# slot created by init-replication.sh so no WAL is lost between backup and streaming, and
# --checkpoint=fast avoids waiting for the primary's next scheduled checkpoint.
run_basebackup() {
  local password
  local role

  password="$(< "${REPLICATION_PASSWORD_FILE}")"
  role="$(< "${REPLICATION_USER_FILE}")"
  PGPASSWORD="${password}" gosu postgres pg_basebackup \
    -h "${PRIMARY_HOST}" \
    -p "${PRIMARY_PORT}" \
    -U "${role}" \
    -D "${PGDATA}" \
    -X stream \
    -S "${STANDBY_SLOT}" \
    --checkpoint=fast
}

# Clone the primary. On failure, clear the half-written directory and retry (up to
# CLONE_ATTEMPTS attempts).
clone_primary() {
  local attempt=0

  until run_basebackup; do
    attempt=$(( attempt + 1 ))
    if (( attempt >= CLONE_ATTEMPTS )); then
      die 1 "pg_basebackup failed after ${attempt} attempts"
    fi
    announce "pg_basebackup failed (attempt ${attempt}), retrying..."
    find "${PGDATA}" -mindepth 1 -delete
    sleep 2
  done
}

# Print a settings file without its primary_conninfo, primary_slot_name and
# synchronous_standby_names lines. The clone carries the writer's copies: a stale line would keep
# an old password on disk, and a standby that names a synchronous standby blocks all its writes
# once it is promoted.
# Usage: keep_other_settings FILE
keep_other_settings() {
  local file="${1:?file required}"
  local line

  while IFS= read -r line; do
    case "${line}" in
      primary_conninfo* | primary_slot_name* | synchronous_standby_names*)
        continue
        ;;
      *)
        printf '%s\n' "${line}"
        ;;
    esac
  done < "${file}"
}

# Turn the clone into a standby. standby.signal means: start in recovery and stream from
# primary_conninfo. application_name is what the primary reports in pg_stat_replication and
# what synchronous_standby_names matches (see scripts/set-replication-mode.sh). The two settings
# replace any earlier ones, in a new file moved into place, so a killed run leaves either the
# old file or the new one, never a half-written one.
mark_as_standby() {
  local settings="${PGDATA}/postgresql.auto.conf"
  local conninfo
  local password
  local replaced

  password="$(< "${REPLICATION_PASSWORD_FILE}")"
  conninfo="host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=$(< "${REPLICATION_USER_FILE}")"
  conninfo+=" password=${password} application_name=${STANDBY_NAME}"
  gosu postgres touch "${PGDATA}/standby.signal"
  replaced="$(mktemp "${settings}.XXXXXX")"
  CLEANUP_PATHS+=("${replaced}")
  keep_other_settings "${settings}" > "${replaced}"
  printf '%s\n' "primary_conninfo = '${conninfo}'" >> "${replaced}"
  printf '%s\n' "primary_slot_name = '${STANDBY_SLOT}'" >> "${replaced}"
  chown postgres:postgres "${replaced}"
  mv -- "${replaced}" "${settings}"
}

# First start only: clone the primary and mark the clone as a standby.
bootstrap_standby() {
  log INFO 'bootstrapping the standby from the primary'
  announce "empty data directory - cloning ${PRIMARY_HOST}:${PRIMARY_PORT}"
  prepare_data_directory
  wait_for_primary
  clone_primary
  mark_as_standby
  announce 'clone complete'
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

  check_environment
  (( $# > 0 )) || die 2 'no command to run: pass it after -- (try --help)'
  require_commands cat chmod chown date find gosu id mkdir mktemp mv pg_isready rm sleep
  if [[ ! -s "${PGDATA}/PG_VERSION" ]]; then
    bootstrap_standby
  fi
  log INFO 'starting postgres (streaming replica; resumes from its stored WAL position)'
  printf '[standby] starting postgres (streaming replica; resumes from its stored WAL position)\n'
  exec gosu postgres "$@"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
