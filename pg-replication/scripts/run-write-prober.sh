#!/usr/bin/env bash
# script-kind: executable
# Purpose: Write numbered rows continuously and log every attempt in a ledger outside the databases.
# Usage: run-write-prober.sh [-h | --help] --ledger FILE --stop-file FILE
# Requires: cat sleep
# Exit codes: 0 stopped as asked, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them. The prober tries the node that last accepted a write, then the other one.
# PROBE_INTERVAL_MS is the pause between writes.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly PROBE_INTERVAL_MS="${PROBE_INTERVAL_MS:-100}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly GO_WORD='go'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: run-write-prober.sh [-h | --help] --ledger FILE --stop-file FILE

Insert a numbered row into the table probe_ledger about every PROBE_INTERVAL_MS milliseconds,
and append one line per attempt to the ledger FILE, which lives outside both databases:
  SEQ START_US END_US NODE ok|fail
START_US and END_US are microseconds since the epoch. ok means the database acknowledged the
commit; fail means it did not (the write may still be present: it is in doubt). The node that
last accepted a write is tried first, then the other, so the prober follows a failover.
It runs until the file given by --stop-file no longer contains the word go. The table must
exist: measure-recovery.sh creates it. A write blocked by synchronous replication simply waits.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, PROBE_INTERVAL_MS (default 100), RUN_LOG_DIR.

Exit codes: 0 stopped as asked, 1 failure, 2 usage or configuration error
USAGE
}

# Try one write on a node and append the attempt to the ledger; succeed if it was acknowledged.
# Usage: try_write NODE SEQ LEDGER
try_write() {
  log INFO 'trying one write'
  local node="${1:?node required}"
  local seq="${2:?sequence number required}"
  local ledger="${3:?ledger required}"
  local sql="insert into probe_ledger(seq) values (${seq})"
  local status='fail'
  local started
  local ended

  started="${EPOCHREALTIME//[.,]/}"
  if database::bare "${node}" <<< "${sql}" > /dev/null 2>&1; then
    status='ok'
  fi
  ended="${EPOCHREALTIME//[.,]/}"
  printf '%08d %s %s %s %s\n' "${seq}" "${started}" "${ended}" "${node}" "${status}" >> "${ledger}"
  [[ "${status}" == 'ok' ]]
}

# Write until the stop file stops saying go.
# Usage: probe_until_stopped LEDGER STOP_FILE
probe_until_stopped() {
  log INFO 'probing until asked to stop'
  local ledger="${1:?ledger required}"
  local stop_file="${2:?stop file required}"
  local preferred="${PRIMARY_CONTAINER}"
  local other="${STANDBY_CONTAINER}"
  local swap
  local seq=0
  local pause

  printf -v pause '%d.%03d' "$(( PROBE_INTERVAL_MS / 1000 ))" "$(( PROBE_INTERVAL_MS % 1000 ))"
  while [[ "$(< "${stop_file}")" == "${GO_WORD}" ]]; do
    seq=$(( seq + 1 ))
    if ! try_write "${preferred}" "${seq}" "${ledger}"; then
      seq=$(( seq + 1 ))
      if try_write "${other}" "${seq}" "${ledger}"; then
        swap="${preferred}"
        preferred="${other}"
        other="${swap}"
      fi
    fi
    sleep "${pause}"
  done
  log INFO "stopped after ${seq} attempts"
}

# Fail unless the arguments make sense.
# Usage: check_arguments LEDGER STOP_FILE
check_arguments() {
  log INFO 'checking the arguments'
  local ledger="${1-}"
  local stop_file="${2-}"

  [[ -n "${ledger}" ]] || die 2 '--ledger is required'
  [[ -r "${stop_file}" ]] || die 2 '--stop-file must name a readable file'
  require_integer PROBE_INTERVAL_MS "${PROBE_INTERVAL_MS}"
}

# Script entry point.
main() {
  local ledger=''
  local stop_file=''
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --ledger)
        (( $# >= 2 )) || die 2 '--ledger needs a value'
        ledger="${2}"
        shift 2
        ;;
      --stop-file)
        (( $# >= 2 )) || die 2 '--stop-file needs a value'
        stop_file="${2}"
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
  require_commands cat sleep
  check_arguments "${ledger}" "${stop_file}"
  probe_until_stopped "${ledger}" "${stop_file}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
