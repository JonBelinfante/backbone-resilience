#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test that the maintenance lock stops a rotation and a rebuild overlapping.
# Usage: test-maintenance-lock.sh [-h | --help]
# Requires: bash cat mkdir sleep
# Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them. REBUILD_MARKER_DIR is where the maintenance lock is kept.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly REBUILD_MARKER_DIR="${REBUILD_MARKER_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly USER_FILE_PATH="${SCRIPT_DIR}../secrets/pg-replication-user.txt"
readonly LOCK_HOLDER="${REBUILD_MARKER_DIR}/pg-replication-maintenance.lock/holder"
readonly SQL_STREAMING_ROLE="select usename from pg_stat_replication where state = 'streaming'"
readonly TOTAL_STEPS=5
readonly HEAD_START_SECONDS=0.4
readonly REBUILD_HEAD_START_SECONDS=2

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

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-maintenance-lock.sh [-h | --help]

Prove that a rotation, a rebuild and a role change cannot overlap:
  1. two rotations started together: the second is refused, the first completes;
  2. a rotation started while a rebuild runs is refused, and the rebuild, which runs the
     promote scripts that enter the lock again, completes;
  3. a lock left by a run that ended is taken over without fuss;
  4. a lock naming a live process that did not take it (a reused process id) is not honoured;
  5. after all that the stack is healthy and the standby streams as the role in the secret file.
It stops at the first FAIL; pass or fail it then restores the stack. The test rotates the
replication secret and crashes the writer: use it only on the throwaway stack.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, REBUILD_MARKER_DIR, RUN_LOG_DIR.

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

# Run a rotation and say whether it was refused because of the lock; print refused or ran.
rotation_outcome() {
  log INFO 'trying a rotation'
  local output

  if output="$(bash "${SCRIPT_DIR}rotate-secret.sh" 2>&1)"; then
    printf 'ran\n'
  elif [[ "${output}" == *'maintenance is locked'* ]]; then
    printf 'refused\n'
  else
    printf 'failed: %s\n' "${output}"
  fi
}

# Step 1: two rotations at once. The second must be refused and the first must complete.
two_rotations_together() {
  local pid
  local outcome

  begin_step 1 'two rotations started together: the second is refused'
  bash "${SCRIPT_DIR}rotate-secret.sh" > /dev/null 2>&1 &
  pid=$!
  sleep "${HEAD_START_SECONDS}"
  outcome="$(rotation_outcome)"
  story::expect_equal 'the second rotation is refused' "${outcome}" 'refused'
  wait "${pid}" || die 1 'FAIL: the first rotation did not complete'
  story::narrate 'PASS: the first rotation completed'
}

# Step 2: a rebuild after a crash holds the lock; a rotation meanwhile is refused.
rotation_during_rebuild() {
  local pid
  local outcome

  begin_step 2 'a rotation while a rebuild runs is refused; the rebuild completes'
  fault::crash_node "${PRIMARY_CONTAINER}"
  bash "${SCRIPT_DIR}restore-starting-state.sh" > /dev/null 2>&1 &
  pid=$!
  sleep "${REBUILD_HEAD_START_SECONDS}"
  outcome="$(rotation_outcome)"
  story::expect_equal 'the rotation is refused during the rebuild' "${outcome}" 'refused'
  wait "${pid}" || die 1 'FAIL: the rebuild did not complete (did its scripts enter the lock?)'
  story::narrate 'PASS: the rebuild completed, and its child scripts entered the lock'
}

# Step 3: a lock whose holder has ended is taken over.
take_over_stale_lock() {
  local outcome

  begin_step 3 'a lock left by a run that ended is taken over'
  mkdir -p -- "${LOCK_HOLDER%/*}"
  printf '%s|%s|%s\n' 999999 'Thu Jan  1 00:00:00 1970' 'a run that ended' > "${LOCK_HOLDER}"
  outcome="$(rotation_outcome)"
  story::expect_equal 'the rotation takes over the stale lock' "${outcome}" 'ran'
}

# Step 4: a lock naming a live process, but not the one that took it, is not honoured.
ignore_reused_process_id() {
  local outcome

  begin_step 4 'a lock whose process id now belongs to another process is not honoured'
  printf '%s|%s|%s\n' "$$" 'Thu Jan  1 00:00:00 1970' 'a run whose id was reused' > "${LOCK_HOLDER}"
  outcome="$(rotation_outcome)"
  story::expect_equal 'the rotation is not blocked by the reused id' "${outcome}" 'ran'
}

# Step 5: the stack is healthy and consistent after the rotations and the rebuild.
check_healthy() {
  local role
  local seen

  begin_step 5 'the stack is healthy and the secret file matches the database'
  role="$(< "${USER_FILE_PATH}")"
  seen="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_STREAMING_ROLE}")"
  story::expect_equal "the standby streams as ${role}" "${seen}" "${role}"
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: maintenance lock on ${PRIMARY_CONTAINER} and ${STANDBY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  two_rotations_together
  rotation_during_rebuild
  take_over_stale_lock
  ignore_reused_process_id
  check_healthy
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed: the lock keeps maintenance runs apart"
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
run_and_restore() {
  log INFO 'running the experiment, then restoring the starting state'
  local outcome='passed'
  local pid

  run_experiment &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: restore the starting state =='
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  [[ "${outcome}" == 'passed' ]] || die 1 'the experiment failed (the starting state was restored)'
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
  require_commands bash cat mkdir sleep
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
