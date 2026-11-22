#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test the failover controller's failure detector (detect-only) against real faults.
# Usage: test-detector.sh [-h | --help]
# Requires: cat sleep
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

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly TOTAL_STEPS=7
readonly PROXY_ENDPOINT='toxiproxy:15432'
readonly PROXY_NAME='to-primary'
readonly WITNESS_SHORT=5
readonly WITNESS_LONG=35
readonly WATCH_SECONDS=10
readonly IDLE_AGE_SECONDS=10
readonly WAIT_LIMIT_SECONDS=30
readonly FAILOVER_MIN_MS=3000
readonly FAILOVER_MAX_MS=15000
readonly SQL_AGE='extract(epoch from now() - last_msg_receipt_time)'
readonly SQL_IDLE_AGE="select coalesce(${SQL_AGE} > ${IDLE_AGE_SECONDS}, false)
  from pg_stat_wal_receiver"

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
# shellcheck source=../lib/controller.sh
source "${SCRIPT_DIR}../lib/controller.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-detector.sh [-h | --help]

Run the detect-only failover controller against real faults and check what it decides. The
controller reaches the writer through Toxiproxy (so only its own view can be cut) and the
standby directly; a heartbeat writer gives the writer traffic. Steps:
  1. healthy writer: only "healthy";
  2. a freeze shorter than the threshold: never "fail-over";
  3. a freeze (hung writer) longer than the threshold: "fail-over", timed;
  4. controller cut off from a live writer with traffic: "hold-writer-alive", never fail-over;
  5. control: the same cut with an idle writer and a short witness window: a false "fail-over";
  6. the same idle cut with a witness window longer than the idle gap: "hold-writer-alive";
  7. writer crash: "fail-over", timed; then the stack is restored.
It stops at the first FAIL. The test pauses and crashes the writer: throwaway stack only.

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

# Give the writer traffic (a heartbeat message every second) and say so.
start_heartbeat() {
  story::narrate 'the writer now has traffic: a heartbeat message every second'
  database::heartbeat_start "${PRIMARY_CONTAINER}"
}

# Take the traffic away again.
stop_heartbeat() {
  story::narrate 'the writer is idle again'
  database::heartbeat_stop "${PRIMARY_CONTAINER}"
}

# Start a controller whose writer view goes through Toxiproxy.
# Usage: start_controller NAME WITNESS_SECONDS
start_controller() {
  local name="${1:?name required}"
  local window="${2:?witness seconds required}"

  controller::start \
    "${name}" \
    "$(controller::password_file "${SCRIPT_DIR}")" \
    "${PROXY_ENDPOINT}" \
    "${window}"
  sleep 2
}

# Wait until the controller reaches a verdict; print its epoch milliseconds, or nothing on timeout.
# Usage: wait_for_verdict NAME VERDICT
wait_for_verdict() {
  local name="${1:?name required}"
  local verdict="${2:?verdict required}"
  local attempt=1
  local when

  while (( attempt <= WAIT_LIMIT_SECONDS )); do
    when="$(controller::first_time "${name}" "${verdict}")"
    if [[ -n "${when}" ]]; then
      printf '%s\n' "${when/./}"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep 1
  done
}

# Narrate the decisions a controller made.
# Usage: narrate_decisions NAME
narrate_decisions() {
  local name="${1:?name required}"

  story::narrate "decisions of ${name} (verdict, epoch):"
  controller::verdicts "${name}" | story::narrate_stream
}

# Step 1: a healthy writer is only ever judged healthy.
step_healthy() {
  begin_step 1 'a healthy writer is judged healthy and nothing else'
  start_heartbeat
  start_controller detector-healthy "${WITNESS_SHORT}"
  sleep "${WATCH_SECONDS}"
  narrate_decisions detector-healthy
  story::expect_equal 'healthy verdicts' "$(controller::count detector-healthy healthy)" 1
  story::expect_equal 'suspect verdicts' "$(controller::count detector-healthy suspect)" 0
  story::expect_equal 'fail-over verdicts' "$(controller::count detector-healthy fail-over)" 0
  controller::stop detector-healthy
}

# Step 2: a freeze shorter than the threshold must not fail over.
step_short_freeze() {
  begin_step 2 'a freeze shorter than the threshold never decides to fail over'
  start_controller detector-short "${WITNESS_SHORT}"
  fault::freeze_node "${PRIMARY_CONTAINER}"
  sleep 3
  fault::thaw_node "${PRIMARY_CONTAINER}"
  sleep "${WATCH_SECONDS}"
  narrate_decisions detector-short
  story::expect_equal 'fail-over verdicts' "$(controller::count detector-short fail-over)" 0
  story::expect_equal 'it ends healthy' "$(controller::count detector-short healthy)" 2
  controller::stop detector-short
}

# Step 3: a hung writer is detected after the threshold.
step_long_freeze() {
  local started
  local decided
  local elapsed

  begin_step 3 'a hung writer is detected: fail-over after the threshold'
  start_controller detector-long "${WITNESS_SHORT}"
  started="$(story::now_milliseconds)"
  fault::freeze_node "${PRIMARY_CONTAINER}"
  decided="$(wait_for_verdict detector-long fail-over)"
  fault::thaw_node "${PRIMARY_CONTAINER}"
  narrate_decisions detector-long
  [[ -n "${decided}" ]] || die 1 'FAIL: the controller never decided to fail over a hung writer'
  elapsed=$(( decided - started ))
  story::narrate "time from the freeze to the decision: ${elapsed} ms"
  story::expect_between 'hung-writer detection (ms)' \
    "${elapsed}" \
    "${FAILOVER_MIN_MS}" \
    "${FAILOVER_MAX_MS}"
  controller::stop detector-long
}

# Cut the controller's view of the writer for a while, then heal; the writer itself is untouched.
# Usage: cut_controller_view NAME VERDICT
cut_controller_view() {
  local name="${1:?name required}"
  local verdict="${2:?verdict required}"

  toxic::cut "${PROXY_NAME}"
  wait_for_verdict "${name}" "${verdict}" > /dev/null
  sleep 2
  toxic::heal "${PROXY_NAME}"
  sleep 2
  narrate_decisions "${name}"
}

# Step 4: cut off from a live writer that has traffic: the standby still hears it.
step_partition_with_traffic() {
  begin_step 4 'cut off from a live writer with traffic: hold, never fail over'
  start_controller detector-cut "${WITNESS_SHORT}"
  cut_controller_view detector-cut hold-writer-alive
  story::expect_equal 'hold verdicts' "$(controller::count detector-cut hold-writer-alive)" 1
  story::expect_equal 'fail-over verdicts' "$(controller::count detector-cut fail-over)" 0
  controller::stop detector-cut
}

# Wait until the idle writer's last message to the standby is older than IDLE_AGE_SECONDS.
wait_until_idle_gap() {
  local attempt=1
  local old

  while (( attempt <= WAIT_LIMIT_SECONDS )); do
    old="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_IDLE_AGE}")"
    if [[ "${old}" == 't' ]]; then
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep 1
  done
  die 1 'the idle writer never went quiet for long enough'
}

# Step 5: control. An idle writer looks dead to a short witness window: a false fail-over.
step_idle_false_alarm() {
  begin_step 5 'control: idle writer, short witness window: a FALSE fail-over (the trap)'
  stop_heartbeat
  start_controller detector-idle "${WITNESS_SHORT}"
  wait_until_idle_gap
  cut_controller_view detector-idle fail-over
  story::expect_equal 'false fail-overs' "$(controller::count detector-idle fail-over)" 1
  controller::stop detector-idle
}

# Step 6: the witness window must exceed the quietest gap between the writer's messages.
step_idle_long_window() {
  begin_step 6 'idle writer, witness window longer than the quiet gap: hold'
  start_controller detector-wide "${WITNESS_LONG}"
  cut_controller_view detector-wide hold-writer-alive
  story::expect_equal 'hold verdicts' "$(controller::count detector-wide hold-writer-alive)" 1
  story::expect_equal 'fail-over verdicts' "$(controller::count detector-wide fail-over)" 0
  controller::stop detector-wide
}

# Step 7: a crashed writer is detected.
step_crash() {
  local started
  local decided
  local elapsed

  begin_step 7 'a crashed writer is detected: fail-over'
  start_heartbeat
  start_controller detector-crash "${WITNESS_SHORT}"
  started="$(story::now_milliseconds)"
  fault::crash_node "${PRIMARY_CONTAINER}"
  decided="$(wait_for_verdict detector-crash fail-over)"
  narrate_decisions detector-crash
  [[ -n "${decided}" ]] || die 1 'FAIL: the controller never decided to fail over a crashed writer'
  elapsed=$(( decided - started ))
  story::narrate "time from the crash to the decision: ${elapsed} ms"
  story::expect_between 'detection time of a crashed writer (ms)' "${elapsed}" 1000 10000
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: failure detector watching ${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  step_healthy
  step_short_freeze
  step_long_freeze
  step_partition_with_traffic
  step_idle_false_alarm
  step_idle_long_window
  step_crash
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Remove every controller and heal every fault, whatever happened.
clean_up_faults() {
  local name

  if [[ "$(container::is_running "${PRIMARY_CONTAINER}")" == 'true' ]]; then
    database::heartbeat_stop "${PRIMARY_CONTAINER}"
  fi
  for name in healthy short long cut idle wide crash; do
    controller::stop "detector-${name}"
  done
  if ! toxic::heal "${PROXY_NAME}"; then
    log WARN 'could not heal the proxy'
  fi
  if ! fault::thaw_node "${PRIMARY_CONTAINER}" 2> /dev/null; then
    log INFO "${PRIMARY_CONTAINER} was not frozen"
  fi
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
run_and_restore() {
  log INFO 'running the experiment, then restoring the starting state'
  local outcome='passed'
  local pid

  run_experiment &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: remove controllers, heal faults, restore the starting state =='
  clean_up_faults
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  [[ "${outcome}" == 'passed' ]] || die 1 'the experiment failed (the state was restored)'
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
  require_commands cat sleep
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
