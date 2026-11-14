#!/usr/bin/env bash
# script-kind: executable
# Purpose: Promote the standby to primary (manual failover).
# Usage: promote-standby-to-primary.sh [-h | --help] [--force]
# Requires: bash cat date docker mktemp rm
# Exit codes: 0 success, 1 failure, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers.
# RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly DATABASE_SQL="${SCRIPT_DIR}database-sql.sh"
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
Usage: promote-standby-to-primary.sh [-h | --help] [--force]

Promote the standby to primary (manual failover). Refuses to run while the old
primary is still reachable, because two writable nodes means split-brain. To
simulate a primary failure first: docker stop pg-primary

The standby is asked to leave recovery (pg_promote, waiting up to 60 seconds),
then it prints that the standby is out of recovery and its new timeline. The
guard rail cannot tell a dead primary from one cut off from this machine; real
split-brain protection needs fencing (planned for Phase 2).

Options:
  --force  promote even though the old primary still answers

Environment:
  PRIMARY_CONTAINER  name of the old primary container (default: pg-primary)
  STANDBY_CONTAINER  name of the standby container (default: pg-standby)
  RUN_LOG_DIR        directory for the run log, which must exist (default: tmp)

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

# SQL: the timeline, read from the current WAL file name (its first 8 hex digits) rather
# than pg_control_checkpoint(), which still shows the old value until the next checkpoint.
sql_timeline() {
  cat <<'SQL'
select ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int
SQL
}

# Guard rail: stop if the old primary still answers. pg_isready exits 0 if it accepts
# connections; if the container is stopped the docker exec itself fails, which also counts
# as "not reachable".
check_primary_unreachable() {
  local message

  if docker exec "${PRIMARY_CONTAINER}" pg_isready -q -h 127.0.0.1 > /dev/null 2>&1; then
    log INFO "DECISION: refused to promote ${STANDBY_CONTAINER}: ${PRIMARY_CONTAINER} is reachable"
    message="Primary '${PRIMARY_CONTAINER}' is still accepting connections."
    message+=' Promoting now would create two writable nodes (split-brain).'
    message+=" Stop it first (docker stop ${PRIMARY_CONTAINER}) or pass --force to override."
    die 1 "${message}"
  fi
}

# Ask the standby to leave recovery. pg_promote(wait => true, wait_seconds => 60) returns once
# the standby is writable. Promotion starts a new timeline, so the old primary's later writes
# can be told apart from ours.
promote_standby() {
  local forced="${1:?forced required}"

  log INFO "DECISION: promoting ${STANDBY_CONTAINER} (forced=${forced})"
  printf 'Promoting %s ...\n' "${STANDBY_CONTAINER}"
  bash "${DATABASE_SQL}" \
    --container "${STANDBY_CONTAINER}" \
    --bare <<< 'select pg_promote(true, 60)' > /dev/null
}

# Print evidence that promotion worked: the standby is no longer in recovery, and its timeline.
report_promotion() {
  local recovery
  local timeline

  recovery="$(bash "${DATABASE_SQL}" --container "${STANDBY_CONTAINER}" --ask recovery)"
  timeline="$(bash "${DATABASE_SQL}" \
    --container "${STANDBY_CONTAINER}" \
    --bare <<< "$(sql_timeline)")"
  printf 'in recovery: %s (expect f)\n' "${recovery}"
  printf 'timeline:    %s (was 1 before promotion)\n' "${timeline}"
  printf '\n%s is now the writable primary.\n' "${STANDBY_CONTAINER}"
  printf 'Do NOT restart the old primary as-is: '
  printf 'it must be rebuilt or rewound (pg_rewind) as a standby first.\n'
}

# Script entry point.
main() {
  local forced='no'

  start_run_log

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --force)
        forced='yes'
        shift
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
  if [[ "${forced}" == 'no' ]]; then
    check_primary_unreachable
  fi
  promote_standby "${forced}"
  report_promotion
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
