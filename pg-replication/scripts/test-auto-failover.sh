#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test automatic failover: the controller decides, the actor fences and promotes.
# Usage: test-auto-failover.sh [-h | --help]
# Requires: cat mktemp rm sleep
# Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly TOTAL_STEPS=3
readonly RTO_MIN_MS=1000
readonly RTO_MAX_MS=20000

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/story.sh
source "${SCRIPT_DIR}../lib/story.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/fault.sh
source "${SCRIPT_DIR}../lib/fault.sh"
# shellcheck source=../lib/toxic.sh
source "${SCRIPT_DIR}../lib/toxic.sh"
# shellcheck source=../lib/actor.sh
source "${SCRIPT_DIR}../lib/actor.sh"
# shellcheck source=../lib/controller.sh
source "${SCRIPT_DIR}../lib/controller.sh"
# shellcheck source=../lib/epoch.sh
source "${SCRIPT_DIR}../lib/epoch.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-auto-failover.sh [-h | --help]

Run the detect-only controller together with the actor (act-on-failover.sh) against real faults:
  1. a freeze shorter than the threshold: the actor does nothing, the epoch stays 0;
  2. a crashed writer: the actor kills it, promotes the standby and raises the epoch to 1; the
     time until a client write succeeds on the new writer is the observed RTO;
  3. the same for a hung (frozen) writer.
It stops at the first FAIL, then restores the starting state. It crashes and freezes the writer:
throwaway stack only.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, RUN_LOG_DIR.

Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error
USAGE
}

# Start a numbered step: print its heading and record it in the run log.
begin_step() {
  local number="${1:?step number required}"
  local title="${2:?title required}"

  printf '\n'
  story::narrate "== Step ${number} of ${TOTAL_STEPS}: ${title} =="
}

# Check the outcome of a failover: epoch 1, the old writer gone, the new one writable.
# Usage: expect_failed_over EPOCH_FILE
expect_failed_over() {
  local epoch_file="${1:?epoch file required}"
  local recovery

  story::expect_equal 'the epoch' "$(epoch::read "${epoch_file}")" 1
  recovery="$(database::in_recovery "${STANDBY_CONTAINER}")"
  story::expect_equal "${STANDBY_CONTAINER} in recovery" "${recovery}" f
  story::expect_stopped "${PRIMARY_CONTAINER}"
}

# Step 1: a short freeze must not make the actor do anything.
# Usage: step_short_freeze EPOCH_FILE
step_short_freeze() {
  local epoch_file="${1:?epoch file required}"
  local recovery

  begin_step 1 'a freeze shorter than the threshold: the actor does nothing'
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}"
  fault::freeze_node "${PRIMARY_CONTAINER}"
  sleep 2
  fault::thaw_node "${PRIMARY_CONTAINER}"
  actor::run "${SCRIPT_DIR}" "${epoch_file}" none
  story::expect_equal 'the epoch' "$(epoch::read "${epoch_file}")" 0
  recovery="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} in recovery" "${recovery}" f
  actor::unwatch "${PRIMARY_CONTAINER}"
}

# Steps 2 and 3: break the writer, let the actor act, time the client's view.
# Usage: step_break_writer EPOCH_FILE NUMBER TITLE FAULT_FUNCTION
step_break_writer() {
  local epoch_file="${1:?epoch file required}"
  local number="${2:?step number required}"
  local title="${3:?title required}"
  local fault_function="${4:?fault function required}"
  local -a fault=("${fault_function}" "${PRIMARY_CONTAINER}")
  local started
  local elapsed
  local pid

  begin_step "${number}" "${title}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  rm -f "${epoch_file}"
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}"
  actor::run "${SCRIPT_DIR}" "${epoch_file}" none &
  pid=$!
  started="$(story::now_milliseconds)"
  "${fault[@]}"
  elapsed="$(actor::time_until_writable "${STANDBY_CONTAINER}" "${started}")"
  wait "${pid}" || die 1 'FAIL: the actor failed'
  story::narrate "time from the fault to a successful client write: ${elapsed} ms"
  story::expect_between 'observed RTO (ms)' "${elapsed}" "${RTO_MIN_MS}" "${RTO_MAX_MS}"
  expect_failed_over "${epoch_file}"
  actor::unwatch "${PRIMARY_CONTAINER}"
}

# Run all the steps in order; the first failure stops the run.
# Usage: run_experiment EPOCH_FILE
run_experiment() {
  local epoch_file="${1:?epoch file required}"

  story::narrate "story: automatic failover of ${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  step_short_freeze "${epoch_file}"
  step_break_writer "${epoch_file}" 2 'a crashed writer: fenced, promoted, timed' fault::crash_node
  step_break_writer "${epoch_file}" 3 'a hung writer: killed, promoted, timed' fault::freeze_node
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Remove the controller and heal every fault, whatever happened.
clean_up_faults() {
  if ! fault::thaw_node "${PRIMARY_CONTAINER}" 2> /dev/null; then
    log INFO "${PRIMARY_CONTAINER} was not frozen"
  fi
  actor::unwatch "${PRIMARY_CONTAINER}"
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
# Usage: run_and_restore EPOCH_FILE
run_and_restore() {
  local epoch_file="${1:?epoch file required}"
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment "${epoch_file}" &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: remove the controller, heal faults, restore the starting state =='
  clean_up_faults
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  [[ "${outcome}" == 'passed' ]] || die 1 'the experiment failed (the state was restored)'
}

# Script entry point.
main() {
  local epoch_dir
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
  require_commands cat mktemp rm sleep
  epoch_dir="$(mktemp -d "${TEMP_DIR}/failover-epoch.XXXXXX")"
  CLEANUP_PATHS+=("${epoch_dir}")
  run_and_restore "${epoch_dir}/epoch"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
