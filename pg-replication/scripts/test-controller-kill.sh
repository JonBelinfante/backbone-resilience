#!/usr/bin/env bash
# script-kind: executable
# Purpose: Kill the failover controller and show what the data plane does while it is gone.
# Usage: test-controller-kill.sh [-h | --help]
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
readonly TOTAL_STEPS=2
readonly LEASE_TTL=6
readonly DOWN_SECONDS=2
readonly WATCH_SECONDS=16
readonly STOP_MARGIN_MS=3000

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/story.sh
source "${SCRIPT_DIR}../lib/story.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/controller.sh
source "${SCRIPT_DIR}../lib/controller.sh"
# shellcheck source=../lib/actor.sh
source "${SCRIPT_DIR}../lib/actor.sh"
# shellcheck source=../lib/lease.sh
source "${SCRIPT_DIR}../lib/lease.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-controller-kill.sh [-h | --help]

The writer holds a lease that the controller renews, with a guard beside the writer. Steps:
  1. the controller is killed and started again within the lease time: the writer never refuses
     a write, the lease is renewed again, and the controller never decides to fail over;
  2. the controller is killed and left dead: the writer is stopped by its guard within the lease
     time plus a margin. This is the price of the lease: the controller is on the write path.
It stops at the first FAIL, then restores the starting state. Throwaway stack only.

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

# Restore, then give the writer a lease, a guard and a controller that renews the lease.
set_up_lease() {
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  lease::install "${PRIMARY_CONTAINER}" 1 "${LEASE_TTL}"
  lease::guard_start "${PRIMARY_CONTAINER}" "$(controller::password_file "${SCRIPT_DIR}")"
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}" "LEASE_TTL_SECONDS=${LEASE_TTL}"
}

# Step 1: a controller that is back within the lease time costs nothing.
step_quick_restart() {
  local controller
  local started
  local result
  local left

  begin_step 1 'the controller is killed and restarted within the lease time: nothing is lost'
  set_up_lease
  controller="$(actor::controller_name)"
  started="$(story::now_milliseconds)"
  container::kill "${controller}"
  sleep "${DOWN_SECONDS}"
  container::start "${controller}"
  result="$(actor::watch_writes "${PRIMARY_CONTAINER}" "${WATCH_SECONDS}" "${started}")"
  story::narrate "last accepted write, first refused write (ms): ${result}"
  story::expect_equal 'refused writes' "${result#* }" 0
  left="$(lease::milliseconds_left "${PRIMARY_CONTAINER}")"
  story::expect_between 'lease left after the restart (ms)' "${left}" 1 $(( LEASE_TTL * 1000 ))
  story::expect_equal 'fail-over decisions' "$(controller::count "${controller}" fail-over)" 0
  actor::unwatch "${PRIMARY_CONTAINER}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
}

# Step 2: a controller that stays dead stops the writer, by its lease.
step_stays_dead() {
  local started
  local result
  local last_ok

  begin_step 2 'the controller is killed and stays dead: the lease runs out and the writer stops'
  set_up_lease
  started="$(story::now_milliseconds)"
  container::kill "$(actor::controller_name)"
  result="$(actor::watch_writes "${PRIMARY_CONTAINER}" "${WATCH_SECONDS}" "${started}")"
  last_ok="${result% *}"
  story::narrate "last accepted write, first refused write (ms): ${result}"
  (( ${result#* } > 0 )) || die 1 'FAIL: the writer kept accepting writes without a controller'
  story::expect_between 'last accepted write (ms)' \
    "${last_ok}" \
    0 \
    $(( LEASE_TTL * 1000 + STOP_MARGIN_MS ))
  story::expect_stopped "${PRIMARY_CONTAINER}"
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate 'story: the controller is killed while it holds the writer lease'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  lease::build "${SCRIPT_DIR}"
  step_quick_restart
  step_stays_dead
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
run_and_restore() {
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: remove controller and guard, restore the starting state =='
  actor::unwatch "${PRIMARY_CONTAINER}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  lease::remove "${PRIMARY_CONTAINER}"
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
