#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test failover of an isolated, unkillable writer: the lease must leave no overlap.
# Usage: test-lease-failover.sh [-h | --help]
# Requires: cat mktemp rm
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
readonly WATCH_SECONDS=30
readonly MIN_GAP_MS=1000

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
Usage: test-lease-failover.sh [-h | --help]

The writer is cut off the network but keeps running, and the actor may not kill it (as when a
failure takes the whole machine's control path with it). Clients on the writer's side keep
writing. The actor waits for the writer's lease to run out, then promotes the standby. Steps:
  1. with a guard beside the writer: the old writer's last accepted write comes before the new
     writer's first accepted write, with a gap: no overlap, no split-brain;
  2. control, no guard: the old writer is still accepting writes after the new writer is
     promoted: two writers at once.
It stops at the first FAIL, then restores the starting state. Throwaway stack only.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, TEMP_DIR, RUN_LOG_DIR.

Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error
USAGE
}

# Start the lease, the controller, the optional guard, and the actor (in the background).
# Usage: set_up_case EPOCH_FILE GUARD
set_up_case() {
  local epoch_file="${1:?epoch file required}"
  local with_guard="${2:?guard setting required}"

  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  rm -f "${epoch_file}" "${epoch_file}.pending"
  lease::install "${PRIMARY_CONTAINER}" 1 "${LEASE_TTL}"
  if [[ "${with_guard}" == 'yes' ]]; then
    lease::guard_start "${PRIMARY_CONTAINER}" "$(controller::password_file "${SCRIPT_DIR}")"
  fi
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}" "LEASE_TTL_SECONDS=${LEASE_TTL}"
}

# Isolate the writer, then watch both nodes for writes; write to EPOCH_FILE.result: the old
# writer's last accepted and first refused write, and the new writer's first accepted (ms).
# Usage: isolate_and_watch EPOCH_FILE
isolate_and_watch() {
  local epoch_file="${1:?epoch file required}"
  local result_file="${epoch_file}.watch"
  local started
  local actor_pid
  local old_pid
  local new_first

  actor::run "${SCRIPT_DIR}" "${epoch_file}" none "FENCE_WAIT_SECONDS=${FENCE_WAIT}" &
  actor_pid=$!
  fault::isolate_node "${PRIMARY_CONTAINER}"
  started="$(story::now_milliseconds)"
  actor::watch_writes "${PRIMARY_CONTAINER}" "${WATCH_SECONDS}" "${started}" > "${result_file}" &
  old_pid=$!
  new_first="$(actor::time_until_writable "${STANDBY_CONTAINER}" "${started}")"
  wait "${actor_pid}" || die 1 'FAIL: the actor failed'
  wait "${old_pid}" || die 1 'FAIL: the write watcher failed'
  printf '%s %s\n' "$(< "${result_file}")" "${new_first}" > "${epoch_file}.result"
}

# The control leaves two writers: stop the old one, as a failover would, so the restore can run.
stop_diverged_writer() {
  if [[ "$(container::is_running "${PRIMARY_CONTAINER}")" == 'true' ]]; then
    container::stop "${PRIMARY_CONTAINER}"
  fi
}

# One case: set up, isolate, watch, narrate; the numbers stay in EPOCH_FILE.result.
# Usage: run_case EPOCH_FILE NUMBER GUARD TITLE
run_case() {
  local epoch_file="${1:?epoch file required}"
  local number="${2:?step number required}"
  local with_guard="${3:?guard setting required}"
  local title="${4:?title required}"

  printf '\n'
  story::narrate "== Step ${number} of ${TOTAL_STEPS}: ${title} =="
  fault::reconnect_node "${PRIMARY_CONTAINER}"
  set_up_case "${epoch_file}" "${with_guard}"
  isolate_and_watch "${epoch_file}"
  story::narrate "old last ok, old first refused, new first ok (ms): $(< "${epoch_file}.result")"
  fault::reconnect_node "${PRIMARY_CONTAINER}"
  actor::unwatch "${PRIMARY_CONTAINER}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
  stop_diverged_writer
}

# Read one field (1 to 3) of the last case's result.
# Usage: result_field EPOCH_FILE NUMBER
result_field() {
  local epoch_file="${1:?epoch file required}"
  local number="${2:?field number required}"
  local -a fields

  read -r -a fields < "${epoch_file}.result"
  printf '%s\n' "${fields[number - 1]}"
}

# Run all the steps in order; the first failure stops the run.
# Usage: run_experiment EPOCH_FILE
run_experiment() {
  local epoch_file="${1:?epoch file required}"
  local old_last
  local new_first

  story::narrate 'story: failover of an isolated writer that cannot be killed'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  lease::build "${SCRIPT_DIR}"
  run_case "${epoch_file}" 1 yes 'with a guard: the old writer stops before the new one starts'
  old_last="$(result_field "${epoch_file}" 1)"
  new_first="$(result_field "${epoch_file}" 3)"
  story::expect_between 'gap between the last old write and the first new write (ms)' \
    $(( new_first - old_last )) \
    "${MIN_GAP_MS}" \
    $(( WATCH_SECONDS * 1000 ))
  run_case "${epoch_file}" 2 no 'control, no guard: two writers at once'
  old_last="$(result_field "${epoch_file}" 1)"
  new_first="$(result_field "${epoch_file}" 3)"
  story::expect_between 'old writer still writing after the new one started (ms)' \
    $(( old_last - new_first )) \
    "${MIN_GAP_MS}" \
    $(( WATCH_SECONDS * 1000 ))
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
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
  story::narrate '== Cleanup: reconnect, remove controller and guard, restore the starting state =='
  fault::reconnect_node "${PRIMARY_CONTAINER}"
  actor::unwatch "${PRIMARY_CONTAINER}"
  lease::guard_stop "${PRIMARY_CONTAINER}"
  stop_diverged_writer
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  lease::remove "${PRIMARY_CONTAINER}"
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
  require_commands cat mktemp rm
  epoch_dir="$(mktemp -d "${TEMP_DIR}/failover-epoch.XXXXXX")"
  CLEANUP_PATHS+=("${epoch_dir}")
  run_and_restore "${epoch_dir}/epoch"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
