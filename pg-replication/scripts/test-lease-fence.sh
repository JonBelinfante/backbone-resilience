#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test that a running writer cut off from its lease stops accepting writes (live fencing).
# Usage: test-lease-fence.sh [-h | --help]
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
readonly TOTAL_STEPS=3
readonly PROXY_ENDPOINT='toxiproxy:15432'
readonly PROXY_NAME='to-primary'
readonly CONTROLLER_NAME='lease-controller'
readonly LEASE_TTL=6
readonly STEADY_SECONDS=15
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
# shellcheck source=../lib/toxic.sh
source "${SCRIPT_DIR}../lib/toxic.sh"
# shellcheck source=../lib/controller.sh
source "${SCRIPT_DIR}../lib/controller.sh"
# shellcheck source=../lib/actor.sh
source "${SCRIPT_DIR}../lib/actor.sh"
# shellcheck source=../lib/lease.sh
source "${SCRIPT_DIR}../lib/lease.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-lease-fence.sh [-h | --help]

The writer holds a lease (a row in its own database) that the controller keeps renewing over the
network; a guard beside the writer stops it when the lease runs out. Steps:
  1. the controller renews the lease: the writer keeps accepting writes;
  2. the controller's path to the writer is cut (the writer itself is alive): writes are refused
     within the lease time plus a margin, and never accepted again;
  3. control, no guard: the same cut, and the writer still accepts a write long after the lease ran
     out (the gap that GAP-03 describes).
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

# Give the writer a lease, and a controller that renews it; optionally a guard that enforces it.
# Usage: set_up_lease GUARD (yes or no)
set_up_lease() {
  local with_guard="${1:?guard setting required}"
  local login

  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  login="$(controller::password_file "${SCRIPT_DIR}")"
  lease::install "${PRIMARY_CONTAINER}" 1 "${LEASE_TTL}"
  if [[ "${with_guard}" == 'yes' ]]; then
    lease::guard_start "${PRIMARY_CONTAINER}" "${login}"
  fi
  controller::start \
    "${CONTROLLER_NAME}" \
    "${login}" \
    "${PROXY_ENDPOINT}" \
    5 \
    "LEASE_TTL_SECONDS=${LEASE_TTL}"
  sleep 3
}

# Step 1: a renewed lease keeps the writer going.
step_renewed() {
  local started
  local result

  begin_step 1 'a renewed lease keeps the writer accepting writes'
  set_up_lease yes
  started="$(story::now_milliseconds)"
  result="$(actor::watch_writes "${PRIMARY_CONTAINER}" "${STEADY_SECONDS}" "${started}")"
  story::narrate "last accepted write, first refused write (ms): ${result}"
  story::expect_equal 'refused writes' "${result#* }" 0
  story::narrate "lease seconds left: $(lease::seconds_left "${PRIMARY_CONTAINER}")"
  controller::stop "${CONTROLLER_NAME}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
}

# Step 2: a writer cut off from its lease is stopped by its guard.
step_cut() {
  local started
  local result
  local last_ok
  local first_fail

  begin_step 2 'the controller is cut off from a live writer: the guard stops the writer'
  set_up_lease yes
  toxic::cut "${PROXY_NAME}"
  started="$(story::now_milliseconds)"
  result="$(actor::watch_writes "${PRIMARY_CONTAINER}" "${WATCH_SECONDS}" "${started}")"
  last_ok="${result% *}"
  first_fail="${result#* }"
  story::narrate "last accepted write ${last_ok} ms, first refused ${first_fail} ms after the cut"
  story::narrate 'guard log:'
  lease::guard_log "${PRIMARY_CONTAINER}" | story::narrate_stream
  (( first_fail > 0 )) || die 1 'FAIL: the writer never stopped accepting writes'
  story::expect_between 'last accepted write (ms)' \
    "${last_ok}" \
    0 \
    $(( LEASE_TTL * 1000 + STOP_MARGIN_MS ))
  story::expect_stopped "${PRIMARY_CONTAINER}"
  toxic::heal "${PROXY_NAME}"
  controller::stop "${CONTROLLER_NAME}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
}

# Step 3: control. Without a guard the lease means nothing: the writer keeps accepting writes.
step_control() {
  local started
  local result

  begin_step 3 'control, no guard: the cut writer keeps accepting writes after its lease ran out'
  set_up_lease no
  toxic::cut "${PROXY_NAME}"
  started="$(story::now_milliseconds)"
  result="$(actor::watch_writes "${PRIMARY_CONTAINER}" "${WATCH_SECONDS}" "${started}")"
  story::narrate "last accepted write, first refused write (ms): ${result}"
  story::narrate "lease seconds left: $(lease::seconds_left "${PRIMARY_CONTAINER}")"
  story::expect_equal 'refused writes' "${result#* }" 0
  story::expect_between 'last accepted write (ms)' \
    "${result% *}" \
    $(( (WATCH_SECONDS - 2) * 1000 )) \
    $(( (WATCH_SECONDS + 2) * 1000 ))
  toxic::heal "${PROXY_NAME}"
  controller::stop "${CONTROLLER_NAME}"
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: a lease and a guard fence the running writer ${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  lease::build "${SCRIPT_DIR}"
  step_renewed
  step_cut
  step_control
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Remove controller and guard, heal the proxy and drop the lease, whatever happened.
clean_up_faults() {
  controller::stop "${CONTROLLER_NAME}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
  if ! toxic::heal "${PROXY_NAME}"; then
    log WARN 'could not heal the proxy'
  fi
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
run_and_restore() {
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: remove controller and guard, heal, restore the starting state =='
  clean_up_faults
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
