#!/usr/bin/env bash
# script-kind: executable
# Purpose: Kill the failover actor after each of its steps and show that a re-run finishes the job.
# Usage: test-actor-kill.sh [-h | --help]
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
readonly TOTAL_STEPS=3

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

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-actor-kill.sh [-h | --help]

Freeze the writer, let the controller decide, and SIGKILL the actor (act-on-failover.sh) right
after one of its steps; then check the half-done state and run the actor again. Steps:
  1. killed after it raised the epoch (the old writer is still alive, frozen);
  2. killed after it stopped the old writer (the standby is still a replica);
  3. killed after the promotion (the epoch is still marked unfinished).
Every re-run must end the same way: one epoch (1), the old writer stopped, the standby writable.
It stops at the first FAIL, then restores the starting state. Throwaway stack only.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, TEMP_DIR, RUN_LOG_DIR.

Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error
USAGE
}

# Print yes if the node's container is running, no if not.
# Usage: running_word NODE
running_word() {
  local node="${1:?node required}"

  if [[ "$(container::is_running "${node}")" == 'true' ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# Print yes if the epoch file records an unfinished failover, no if not.
# Usage: pending_word EPOCH_FILE
pending_word() {
  local epoch_file="${1:?epoch file required}"

  if [[ -e "${epoch_file}.pending" ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# Check the half-done state after a kill: the epoch is spent and the failover is unfinished, and
# what is done depends on the step: epoch (old writer still alive), kill (old writer gone, standby
# still a replica), promote (standby already writable).
# Usage: expect_half_done EPOCH_FILE POINT
expect_half_done() {
  local epoch_file="${1:?epoch file required}"
  local point="${2:?crash point required}"
  local old_alive='no'
  local recovery='t'
  local actual

  [[ "${point}" != 'epoch' ]] || old_alive='yes'
  [[ "${point}" != 'promote' ]] || recovery='f'
  story::expect_equal 'the epoch' "$(epoch::read "${epoch_file}")" 1
  story::expect_equal 'an unfinished failover is recorded' "$(pending_word "${epoch_file}")" yes
  actual="$(running_word "${PRIMARY_CONTAINER}")"
  story::expect_equal 'the old writer is running' "${actual}" "${old_alive}"
  actual="$(database::in_recovery "${STANDBY_CONTAINER}")"
  story::expect_equal 'the standby is in recovery' "${actual}" "${recovery}"
}

# Check the end state after the re-run.
# Usage: expect_finished EPOCH_FILE
expect_finished() {
  local epoch_file="${1:?epoch file required}"

  story::expect_equal 'the epoch is still' "$(epoch::read "${epoch_file}")" 1
  story::expect_equal 'no unfinished failover' "$(pending_word "${epoch_file}")" no
  story::expect_equal 'the old writer is running' "$(running_word "${PRIMARY_CONTAINER}")" no
  story::expect_equal 'the standby is in recovery' \
    "$(database::in_recovery "${STANDBY_CONTAINER}")" \
    f
}

# Run the actor with a crash point in the background and say whether it was killed.
# Usage: kill_actor_after EPOCH_FILE POINT
kill_actor_after() {
  local epoch_file="${1:?epoch file required}"
  local point="${2:?crash point required}"
  local pid

  actor::run "${SCRIPT_DIR}" "${epoch_file}" "${point}" &
  pid=$!
  if wait "${pid}"; then
    die 1 "FAIL: the actor was not killed after the ${point} step"
  fi
  story::narrate "the actor was killed after the ${point} step"
}

# One case: freeze the writer, kill the actor after POINT, check, re-run, check.
# Usage: run_case EPOCH_FILE NUMBER POINT
run_case() {
  local epoch_file="${1:?epoch file required}"
  local number="${2:?step number required}"
  local point="${3:?crash point required}"
  local started
  local elapsed

  printf '\n'
  story::narrate "== Step ${number} of ${TOTAL_STEPS}: the actor is killed after '${point}' =="
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  rm -f "${epoch_file}" "${epoch_file}.pending"
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}"
  fault::freeze_node "${PRIMARY_CONTAINER}"
  started="$(story::now_milliseconds)"
  kill_actor_after "${epoch_file}" "${point}"
  expect_half_done "${epoch_file}" "${point}"
  actor::run "${SCRIPT_DIR}" "${epoch_file}" none
  expect_finished "${epoch_file}"
  elapsed="$(actor::time_until_writable "${STANDBY_CONTAINER}" "${started}")"
  story::narrate "a client write works ${elapsed} ms after the freeze"
  actor::unwatch "${PRIMARY_CONTAINER}"
}

# Run all the steps in order; the first failure stops the run.
# Usage: run_experiment EPOCH_FILE
run_experiment() {
  local epoch_file="${1:?epoch file required}"

  story::narrate 'story: the failover actor is killed and re-run'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  run_case "${epoch_file}" 1 epoch
  run_case "${epoch_file}" 2 kill
  run_case "${epoch_file}" 3 promote
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
  story::narrate '== Cleanup: thaw, remove the controller, restore the starting state =='
  if ! fault::thaw_node "${PRIMARY_CONTAINER}" 2> /dev/null; then
    log INFO "${PRIMARY_CONTAINER} was not frozen"
  fi
  actor::unwatch "${PRIMARY_CONTAINER}"
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
  require_commands cat mktemp rm
  epoch_dir="$(mktemp -d "${TEMP_DIR}/failover-epoch.XXXXXX")"
  CLEANUP_PATHS+=("${epoch_dir}")
  run_and_restore "${epoch_dir}/epoch"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
