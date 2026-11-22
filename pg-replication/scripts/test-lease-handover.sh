#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test that after a failover the new writer holds a lease, kept alive, and is fenced by it.
# Usage: test-lease-handover.sh [-h | --help]
# Requires: cat mktemp sleep
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
readonly TOTAL_STEPS=2
readonly LEASE_TTL=6
readonly FENCE_WAIT=8
readonly SAMPLES=4
readonly WATCH_SECONDS=14
readonly STOP_MARGIN_MS=3000

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
# shellcheck source=../lib/controller.sh
source "${SCRIPT_DIR}../lib/controller.sh"
# shellcheck source=../lib/actor.sh
source "${SCRIPT_DIR}../lib/actor.sh"
# shellcheck source=../lib/lease.sh
source "${SCRIPT_DIR}../lib/lease.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-lease-handover.sh [-h | --help]

Fail over an isolated writer that may not be killed (as test-lease-failover.sh does), with the
actor handing the lease on. Steps:
  1. the new writer holds a lease at the new epoch (1), and over a period longer than the lease
     time it is renewed every time we look: the controller now follows the new writer;
  2. the new controller is removed, so the lease is not renewed: the new writer's guard stops it
     within the lease time plus a margin. The new writer is fenced as the old one was.
It stops at the first FAIL, then restores the starting state. Throwaway stack only.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, TEMP_DIR, RUN_LOG_DIR.

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

# Lease, guard, controller on the old writer; then isolate it and let the actor fail over.
# Usage: fail_over_isolated EPOCH_FILE
fail_over_isolated() {
  local epoch_file="${1:?epoch file required}"
  local pid

  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  lease::install "${PRIMARY_CONTAINER}" 1 "${LEASE_TTL}"
  lease::guard_start "${PRIMARY_CONTAINER}" "$(controller::password_file "${SCRIPT_DIR}")"
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}" "LEASE_TTL_SECONDS=${LEASE_TTL}"
  actor::run \
    "${SCRIPT_DIR}" \
    "${epoch_file}" \
    none \
    "FENCE_WAIT_SECONDS=${FENCE_WAIT}" \
    "LEASE_TTL_SECONDS=${LEASE_TTL}" &
  pid=$!

  fault::isolate_node "${PRIMARY_CONTAINER}"
  wait "${pid}" || die 1 'FAIL: the actor failed'
}

# Step 1: the new writer has a lease at epoch 1 that stays renewed beyond one lease time.
step_handed_over() {
  local epoch_file="${1:?epoch file required}"
  local left
  local sample=1

  begin_step 1 'the actor hands the lease to the new writer, and the controller keeps it alive'
  fail_over_isolated "${epoch_file}"
  story::expect_equal 'epoch of the new writer lease' "$(lease::epoch "${STANDBY_CONTAINER}")" 1
  while (( sample <= SAMPLES )); do
    left="$(lease::milliseconds_left "${STANDBY_CONTAINER}")"
    story::expect_between "lease left on the new writer, sample ${sample} (ms)" \
      "${left}" \
      1 \
      $(( LEASE_TTL * 1000 ))
    sample=$(( sample + 1 ))
    sleep 3
  done
}

# Step 2: without renewals the new writer is stopped by its own guard.
step_new_writer_fenced() {
  local started
  local result
  local last_ok
  local first_fail

  begin_step 2 'the lease of the new writer is not renewed: its guard stops it'
  controller::stop "$(actor::controller_name)"
  started="$(story::now_milliseconds)"
  result="$(actor::watch_writes "${STANDBY_CONTAINER}" "${WATCH_SECONDS}" "${started}")"
  last_ok="${result% *}"
  first_fail="${result#* }"
  story::narrate "last accepted write ${last_ok} ms, first refused ${first_fail} ms after the stop"
  (( first_fail > 0 )) || die 1 'FAIL: the new writer never stopped accepting writes'
  story::expect_between 'last accepted write (ms)' \
    "${last_ok}" \
    0 \
    $(( LEASE_TTL * 1000 + STOP_MARGIN_MS ))
  story::expect_stopped "${STANDBY_CONTAINER}"
}

# Run all the steps in order; the first failure stops the run.
# Usage: run_experiment EPOCH_FILE
run_experiment() {
  local epoch_file="${1:?epoch file required}"

  story::narrate 'story: the new writer gets a lease after a failover'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  lease::build "${SCRIPT_DIR}"
  step_handed_over "${epoch_file}"
  step_new_writer_fenced
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Stop a node left running, as a failover would, so the restore can run.
# Usage: stop_node_left_running NODE
stop_node_left_running() {
  local node="${1:?node required}"

  if [[ "$(container::is_running "${node}")" == 'true' ]]; then
    container::stop "${node}"
  fi
}

# Reconnect, remove controller and guards, bring the new writer back, then restore.
clean_up_and_restore() {
  fault::reconnect_node "${PRIMARY_CONTAINER}"
  actor::unwatch "${PRIMARY_CONTAINER}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
  lease::guard_stop "${STANDBY_CONTAINER}"
  stop_node_left_running "${PRIMARY_CONTAINER}"
  if [[ "$(container::is_running "${STANDBY_CONTAINER}")" != 'true' ]]; then
    container::start "${STANDBY_CONTAINER}"
  fi
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  lease::remove "${PRIMARY_CONTAINER}"
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
  story::narrate '== Cleanup: reconnect, remove controller and guards, restore =='
  clean_up_and_restore
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
  require_commands cat mktemp sleep
  epoch_dir="$(mktemp -d "${TEMP_DIR}/failover-epoch.XXXXXX")"
  CLEANUP_PATHS+=("${epoch_dir}")
  run_and_restore "${epoch_dir}/epoch"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
