#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test a failover and then the fail-back, both with leases handed to each new writer.
# Usage: test-lease-failback.sh [-h | --help]
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
readonly LEASE_TTL=6
readonly FENCE_WAIT=8
readonly SAMPLES=4
readonly BACK_ENDPOINT='toxiproxy:15432'

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
# shellcheck source=../lib/epoch.sh
source "${SCRIPT_DIR}../lib/epoch.sh"
# shellcheck source=../lib/actor.sh
source "${SCRIPT_DIR}../lib/actor.sh"
# shellcheck source=../lib/lease.sh
source "${SCRIPT_DIR}../lib/lease.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-lease-failback.sh [-h | --help]

Fail over an isolated writer with the lease handed on (as test-lease-handover.sh does), rejoin
the old node as a standby, then fail back by isolating the new writer in turn. Steps:
  1. the first failover: the new writer holds a lease at epoch 1 and keeps it renewed;
  2. the old node is rebuilt as a standby of the new writer and streams;
  3. the fail-back, with the roles swapped: the epoch goes to 2, the node that was first the
     writer holds a lease at epoch 2 and keeps it renewed, and the isolated writer is stopped.
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

# Isolate a writer that the actor may not kill, and let the actor fail over and hand the lease on.
# Further arguments, NAME=VALUE, swap the roles for the actor.
# Usage: fail_over_isolated EPOCH_FILE VICTIM [NAME=VALUE ...]
fail_over_isolated() {
  local epoch_file="${1:?epoch file required}"
  local victim="${2:?node to isolate required}"
  local pid

  actor::run \
    "${SCRIPT_DIR}" \
    "${epoch_file}" \
    none \
    "FENCE_WAIT_SECONDS=${FENCE_WAIT}" \
    "LEASE_TTL_SECONDS=${LEASE_TTL}" \
    "${@:3}" &
  pid=$!
  fault::isolate_node "${victim}"
  wait "${pid}" || die 1 'FAIL: the actor failed'
}

# Check that a node holds the lease at the given epoch and that it stays renewed for longer than
# one lease time.
# Usage: check_lease NODE EPOCH
check_lease() {
  local node="${1:?node required}"
  local epoch="${2:?epoch required}"
  local left
  local sample=1

  story::expect_equal "epoch of the lease on ${node}" "$(lease::epoch "${node}")" "${epoch}"
  while (( sample <= SAMPLES )); do
    left="$(lease::milliseconds_left "${node}")"
    story::expect_between "lease left on ${node}, sample ${sample} (ms)" \
      "${left}" \
      1 \
      $(( LEASE_TTL * 1000 ))
    sample=$(( sample + 1 ))
    sleep 3
  done
}

# Step 1: the first failover, with the lease handed to the new writer.
# Usage: step_first_failover EPOCH_FILE
step_first_failover() {
  local epoch_file="${1:?epoch file required}"

  begin_step 1 'the first failover: the new writer is leased at epoch 1'
  lease::install "${PRIMARY_CONTAINER}" 1 "${LEASE_TTL}"
  lease::guard_start "${PRIMARY_CONTAINER}" "$(controller::password_file "${SCRIPT_DIR}")"
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}" "LEASE_TTL_SECONDS=${LEASE_TTL}"
  fail_over_isolated "${epoch_file}" "${PRIMARY_CONTAINER}"
  check_lease "${STANDBY_CONTAINER}" 1
  story::expect_equal 'the epoch' "$(epoch::read "${epoch_file}")" 1
  story::expect_stopped "${PRIMARY_CONTAINER}"
}

# Step 2: the old node rejoins as a standby of the new writer.
step_rejoin() {
  local recovery

  begin_step 2 'the old node rejoins as a standby of the new writer'
  fault::reconnect_node "${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}promote-primary-to-standby.sh"
  database::wait_for_streaming "${STANDBY_CONTAINER}"
  recovery="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} in recovery" "${recovery}" t
}

# Step 3: the fail-back: the roles are swapped for the actor, and the lease follows the writer back.
# Usage: step_fail_back EPOCH_FILE
step_fail_back() {
  local epoch_file="${1:?epoch file required}"
  local recovery

  begin_step 3 'the fail-back: the node that was first the writer is leased at epoch 2'
  database::heartbeat_start "${STANDBY_CONTAINER}"
  fail_over_isolated \
    "${epoch_file}" \
    "${STANDBY_CONTAINER}" \
    "PRIMARY_CONTAINER=${STANDBY_CONTAINER}" \
    "STANDBY_CONTAINER=${PRIMARY_CONTAINER}" \
    "CONTROLLER_WRITER_ENDPOINT=${BACK_ENDPOINT}"
  story::expect_equal 'the epoch' "$(epoch::read "${epoch_file}")" 2
  recovery="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} in recovery" "${recovery}" f
  check_lease "${PRIMARY_CONTAINER}" 2
  story::expect_stopped "${STANDBY_CONTAINER}"
}

# Run all the steps in order; the first failure stops the run.
# Usage: run_experiment EPOCH_FILE
run_experiment() {
  local epoch_file="${1:?epoch file required}"

  story::narrate 'story: a failover and the fail-back, both with leases'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  lease::build "${SCRIPT_DIR}"
  rm -f "${epoch_file}" "${epoch_file}.pending"
  step_first_failover "${epoch_file}"
  step_rejoin
  step_fail_back "${epoch_file}"
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Reconnect both nodes, remove the controller and guards, then restore the starting state.
clean_up_and_restore() {
  fault::reconnect_node "${PRIMARY_CONTAINER}"
  fault::reconnect_node "${STANDBY_CONTAINER}"
  actor::unwatch "${PRIMARY_CONTAINER}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
  lease::guard_stop "${STANDBY_CONTAINER}"
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
  require_commands cat mktemp rm sleep
  epoch_dir="$(mktemp -d "${TEMP_DIR}/failover-epoch.XXXXXX")"
  CLEANUP_PATHS+=("${epoch_dir}")
  run_and_restore "${epoch_dir}/epoch"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
