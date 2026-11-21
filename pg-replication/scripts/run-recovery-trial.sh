#!/usr/bin/env bash
# script-kind: executable
# Purpose: Run one failure trial under a write prober and print its measured RPO and RTO.
# Usage: run-recovery-trial.sh [-h | --help] --scenario NAME [--lag SECONDS]
# Requires: bash cat mktemp sleep
# Exit codes: 0 measured, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them. TEMP_DIR holds the ledger and its files until the run ends. DECISION_DELAY is the
# seconds between the failure and the promotion (a person or a controller deciding).
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly DECISION_DELAY="${DECISION_DELAY:-0}"
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly WARMUP_SECONDS=3
readonly RECOVERY_SECONDS=3
readonly SQL_DROP='drop table if exists probe_ledger'
readonly SQL_CREATE='create table probe_ledger(seq bigint primary key)'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/fault.sh
source "${SCRIPT_DIR}../lib/fault.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: run-recovery-trial.sh [-h | --help] --scenario NAME [--lag SECONDS]

Run one trial from a restored stack with run-write-prober.sh writing throughout, then print one
line, RESULT followed by name=value pairs: the scenario, then the figures of report-ledger.sh.
  --scenario stop     stop the writer cleanly, then promote the standby
             crash    kill the writer (SIGKILL), then promote the standby
             async    isolate the standby for --lag seconds, kill the writer, promote
             sync     the same with synchronous replication (no acked write may be lost)
             control  sync with commit level local: the loss must come back (the control)
  --lag SECONDS       how long the standby is isolated before the crash (default 0)
The seconds between the failure and the promotion are DECISION_DELAY (default 0).
Pass or fail, it then reconnects the standby, restores the starting state, asynchronous mode and
the default commit level. The trial changes the databases: use it only on the throwaway stack.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, DECISION_DELAY, TEMP_DIR, RUN_LOG_DIR.

Exit codes: 0 measured, 1 failure, 2 usage or configuration error
USAGE
}

# Restore the starting state, set the replication mode the scenario needs, and make the table.
# Usage: prepare_stack SCENARIO
prepare_stack() {
  log INFO 'preparing the stack'
  local scenario="${1:?scenario required}"
  local mode='async'

  bash "${SCRIPT_DIR}restore-starting-state.sh" > /dev/null
  if [[ "${scenario}" == 'sync' || "${scenario}" == 'control' ]]; then
    mode='sync'
  fi
  bash "${SCRIPT_DIR}set-replication-mode.sh" --mode "${mode}" > /dev/null
  if [[ "${scenario}" == 'control' ]]; then
    fault::set_commit_level "${PRIMARY_CONTAINER}" local
  fi
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_DROP}; ${SQL_CREATE}" > /dev/null
}

# Cause the failure the scenario names, wait out the decision delay, and promote the standby.
# Usage: inject_fault SCENARIO LAG
inject_fault() {
  log INFO 'injecting the fault'
  local scenario="${1:?scenario required}"
  local lag="${2:?lag required}"

  case "${scenario}" in
    stop)
      bash "${SCRIPT_DIR}bring-down-database.sh" --database primary > /dev/null
      ;;
    crash)
      fault::crash_node "${PRIMARY_CONTAINER}"
      ;;
    *)
      if (( lag > 0 )); then
        fault::isolate_node "${STANDBY_CONTAINER}"
        sleep "${lag}"
      fi
      fault::crash_node "${PRIMARY_CONTAINER}"
      ;;
  esac
  sleep "${DECISION_DELAY}"
  bash "${SCRIPT_DIR}promote-standby-to-primary.sh" > /dev/null
}

# Run the trial: probe writes, cause the failure, keep probing, stop, and report against the
# node that took over. The work folder holds the ledger, the stop file and the result.
# Usage: run_trial SCENARIO LAG WORK_FOLDER
run_trial() {
  log INFO 'running the trial'
  local scenario="${1:?scenario required}"
  local lag="${2:?lag required}"
  local work="${3:?work folder required}"
  local mark
  local pid
  local -a command=()

  prepare_stack "${scenario}"
  printf 'go' > "${work}/stop"
  bash "${SCRIPT_DIR}run-write-prober.sh" --ledger "${work}/ledger" --stop-file "${work}/stop" &
  pid=$!
  sleep "${WARMUP_SECONDS}"
  mark="${EPOCHREALTIME//[.,]/}"
  inject_fault "${scenario}" "${lag}"
  sleep "${RECOVERY_SECONDS}"
  printf 'stop' > "${work}/stop"
  wait "${pid}" || die 1 'the write prober ended with an error'
  command=(env "MARK_US=${mark}" bash "${SCRIPT_DIR}report-ledger.sh")
  command+=(--ledger "${work}/ledger" --node "${STANDBY_CONTAINER}")
  "${command[@]}" > "${work}/result"
}

# Put everything back: stop the prober, heal the network, restore the starting state,
# asynchronous mode and the default commit level.
# Usage: put_everything_back WORK_FOLDER
put_everything_back() {
  log INFO 'putting everything back'
  local work="${1:?work folder required}"

  printf 'stop' > "${work}/stop"
  fault::reconnect_node "${STANDBY_CONTAINER}"
  bash "${SCRIPT_DIR}restore-starting-state.sh" > /dev/null
  bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async > /dev/null
  fault::set_commit_level "${PRIMARY_CONTAINER}" default
}

# Run the trial in a child shell so a failure cannot skip the clean-up, put everything back,
# then print the result line.
# Usage: run_and_restore SCENARIO LAG
run_and_restore() {
  log INFO 'running the trial, then restoring'
  local scenario="${1:?scenario required}"
  local lag="${2:?lag required}"
  local work
  local result
  local pid
  local outcome='passed'

  work="$(mktemp -d "${TEMP_DIR}/${SCRIPT_NAME}.XXXXXX")"
  CLEANUP_PATHS+=("${work}")
  run_trial "${scenario}" "${lag}" "${work}" &
  pid=$!
  wait "${pid}" || outcome='failed'
  put_everything_back "${work}"
  [[ "${outcome}" == 'passed' ]] || die 1 'the trial failed (the starting state was restored)'
  result="$(< "${work}/result")"
  printf 'RESULT scenario=%s lag=%s decision_delay=%s %s\n' \
    "${scenario}" \
    "${lag}" \
    "${DECISION_DELAY}" \
    "${result//$'\n'/ }"
}

# Script entry point.
main() {
  local scenario=''
  local lag=0
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --scenario)
        (( $# >= 2 )) || die 2 '--scenario needs a value'
        scenario="${2}"
        shift 2
        ;;
      --lag)
        (( $# >= 2 )) || die 2 '--lag needs a value'
        lag="${2}"
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
  require_commands bash cat mktemp sleep
  require_integer lag "${lag}"
  require_integer DECISION_DELAY "${DECISION_DELAY}"
  run_and_restore "${scenario}" "${lag}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
