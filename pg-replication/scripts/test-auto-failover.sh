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
readonly PROXY_ENDPOINT='toxiproxy:15432'
readonly CONTROLLER_NAME='auto-controller'
readonly WITNESS_SECONDS=5
readonly ACTOR_WAIT=15
readonly WRITE_LIMIT_SECONDS=60
readonly RTO_MIN_MS=1000
readonly RTO_MAX_MS=20000
readonly SQL_WRITE="select pg_logical_emit_message(true, 'auto-failover', 'x')"

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

# Give the writer traffic and start a controller watching it through Toxiproxy.
start_watching() {
  database::heartbeat_start "${PRIMARY_CONTAINER}"
  controller::start \
    "${CONTROLLER_NAME}" \
    "$(controller::password_file "${SCRIPT_DIR}")" \
    "${PROXY_ENDPOINT}" \
    "${WITNESS_SECONDS}"
  sleep 2
}

# Stop the controller and the writer's traffic (the writer may be gone already).
stop_watching() {
  controller::stop "${CONTROLLER_NAME}"
  if [[ "$(container::is_running "${PRIMARY_CONTAINER}")" == 'true' ]]; then
    database::heartbeat_stop "${PRIMARY_CONTAINER}"
  fi
}

# Run the actor until it finishes.
# Usage: run_actor EPOCH_FILE
run_actor() {
  local epoch_file="${1:?epoch file required}"

  story::run_logged env \
    "EPOCH_FILE=${epoch_file}" \
    "WAIT_SECONDS=${ACTOR_WAIT}" \
    bash \
    "${SCRIPT_DIR}act-on-failover.sh" \
    --controller "${CONTROLLER_NAME}"
}

# Print the milliseconds until a write succeeds on the standby (a client's view), or fail.
# Usage: time_until_writable STARTED_MS
time_until_writable() {
  local started="${1:?start time required}"
  local give_up=$(( started + WRITE_LIMIT_SECONDS * 1000 ))
  local now

  now="$(story::now_milliseconds)"
  while (( now < give_up )); do
    if database::bare "${STANDBY_CONTAINER}" <<< "${SQL_WRITE}" > /dev/null 2>&1; then
      now="$(story::now_milliseconds)"
      printf '%s\n' "$(( now - started ))"
      return 0
    fi
    sleep 0.2
    now="$(story::now_milliseconds)"
  done
  die 1 "FAIL: no write succeeded on ${STANDBY_CONTAINER} within ${WRITE_LIMIT_SECONDS} s"
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
  start_watching
  fault::freeze_node "${PRIMARY_CONTAINER}"
  sleep 2
  fault::thaw_node "${PRIMARY_CONTAINER}"
  run_actor "${epoch_file}"
  story::expect_equal 'the epoch' "$(epoch::read "${epoch_file}")" 0
  recovery="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} in recovery" "${recovery}" f
  stop_watching
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
  start_watching
  run_actor "${epoch_file}" &
  pid=$!
  started="$(story::now_milliseconds)"
  "${fault[@]}"
  elapsed="$(time_until_writable "${started}")"
  wait "${pid}" || die 1 'FAIL: the actor failed'
  story::narrate "time from the fault to a successful client write: ${elapsed} ms"
  story::expect_between 'observed RTO (ms)' "${elapsed}" "${RTO_MIN_MS}" "${RTO_MAX_MS}"
  expect_failed_over "${epoch_file}"
  controller::stop "${CONTROLLER_NAME}"
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
  controller::stop "${CONTROLLER_NAME}"
  if ! fault::thaw_node "${PRIMARY_CONTAINER}" 2> /dev/null; then
    log INFO "${PRIMARY_CONTAINER} was not frozen"
  fi
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
