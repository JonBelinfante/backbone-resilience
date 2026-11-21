#!/usr/bin/env bash
# script-kind: executable
# Purpose: Promote the standby to primary (manual failover).
# Usage: promote-standby-to-primary.sh [-h | --help] [--force]
# Requires: cat
# Exit codes: 0 success, 1 failure, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly REBUILD_MARKER_DIR="${REBUILD_MARKER_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/lock.sh
source "${SCRIPT_DIR}../lib/lock.sh"

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

# SQL: the timeline, read from the current WAL file name (its first 8 hex digits) rather
# than pg_control_checkpoint(), which still shows the old value until the next checkpoint.
sql_timeline() {
  cat <<'SQL'
select ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int
SQL
}

# Guard rail: stop if the old primary still answers. database::is_ready succeeds if it accepts
# connections; a stopped container counts as "not reachable".
check_primary_unreachable() {
  local message

  if database::is_ready "${PRIMARY_CONTAINER}"; then
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
  database::bare "${STANDBY_CONTAINER}" <<< 'select pg_promote(true, 60)' > /dev/null
}

# Print evidence that promotion worked: the standby is no longer in recovery, and its timeline.
report_promotion() {
  local recovery
  local timeline

  recovery="$(database::in_recovery "${STANDBY_CONTAINER}")"
  timeline="$(database::bare "${STANDBY_CONTAINER}" <<< "$(sql_timeline)")"
  printf 'in recovery: %s (expect f)\n' "${recovery}"
  printf 'timeline:    %s (was 1 before promotion)\n' "${timeline}"
  printf '\n%s is now the writable primary.\n' "${STANDBY_CONTAINER}"
  printf 'Do NOT restart the old primary as-is: '
  printf 'it must be rebuilt or rewound (pg_rewind) as a standby first.\n'
}

# Script entry point.
main() {
  local forced='no'
  start_run_log "$@"

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
  lock::acquire "${REBUILD_MARKER_DIR}" "${SCRIPT_NAME}"
  if [[ "${forced}" == 'no' ]]; then
    check_primary_unreachable
  fi
  promote_standby "${forced}"
  report_promotion
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
