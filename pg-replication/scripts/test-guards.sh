#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test the two guards that stop a second writer: promotion and start-up (split-brain).
# Usage: test-guards.sh [-h | --help]
# Requires: bash cat
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
# shellcheck source=../lib/fence.sh
source "${SCRIPT_DIR}../lib/fence.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-guards.sh [-h | --help]

Test the two guards that stop a second writer:
  1. the promotion guard: with the primary running, promote-standby-to-primary.sh refuses
     (exit 1, a split-brain message) and the standby stays a replica;
  2. the split-brain guard: the primary crashes, the standby is promoted, the fence on the old
     primary is lifted, then the primary is started through bring-up-database.sh, which sees two
     writers, stops it again and fails;
  3. the control: the same start-up with the standby still a replica is allowed and the primary
     comes up as the replica, so the guard does not refuse a healthy start.
It stops at the first FAIL, then restores the starting state. Throwaway stack only.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, RUN_LOG_DIR.

Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error
USAGE
}

# Print succeeded if the command exits 0, failed otherwise. Its output is discarded.
# Usage: outcome_of COMMAND [ARGUMENT ...]
outcome_of() {
  local -a command=("$@")

  if "${command[@]}" > /dev/null 2>&1; then
    printf 'succeeded\n'
  else
    printf 'failed\n'
  fi
}

# Start a numbered step: print its heading and record it in the run log.
begin_step() {
  local number="${1:?step number required}"
  local title="${2:?title required}"

  printf '\n'
  story::narrate "== Step ${number} of ${TOTAL_STEPS}: ${title} =="
}

# Step 1: the promotion guard refuses while the primary answers.
step_promotion_guard() {
  local outcome
  local recovery

  begin_step 1 'promotion guard: the standby is not promoted while the primary answers'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  outcome="$(outcome_of bash "${SCRIPT_DIR}promote-standby-to-primary.sh")"
  story::expect_equal 'the promotion was refused' "${outcome}" failed
  recovery="$(database::in_recovery "${STANDBY_CONTAINER}")"
  story::expect_equal "${STANDBY_CONTAINER} is still a replica" "${recovery}" t
  recovery="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} is still the writer" "${recovery}" f
}

# Step 2: the split-brain guard stops a restarted old primary when the standby already writes.
# Promotion fences the old primary's data directory, so a normal start comes up read-only (FOV-10).
# The fence is lifted here, so only the guard stands between the old primary and a second writer.
step_split_brain_guard() {
  local outcome
  local running
  local fenced
  local recovery

  begin_step 2 'split-brain guard: a restarted old primary is stopped again'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  fault::crash_node "${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}promote-standby-to-primary.sh"
  fenced="$(fence::is_applied "${PRIMARY_CONTAINER}")"
  story::expect_equal 'promotion fenced the old primary' "${fenced}" yes
  fence::lift "${PRIMARY_CONTAINER}"
  outcome="$(outcome_of bash "${SCRIPT_DIR}bring-up-database.sh" --database primary)"
  story::expect_equal 'the start-up was refused' "${outcome}" failed
  running="$(container::is_running "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} was stopped again" "${running}" false
  recovery="$(database::in_recovery "${STANDBY_CONTAINER}")"
  story::expect_equal "${STANDBY_CONTAINER} is the one writer" "${recovery}" f
}

# Step 3: control: a start of the old primary while the standby is a replica is allowed.
step_control() {
  local outcome
  local running
  local recovery

  begin_step 3 'control: a start with one writer and one replica is allowed'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  bash "${SCRIPT_DIR}bring-down-database.sh" --database primary > /dev/null
  outcome="$(outcome_of bash "${SCRIPT_DIR}bring-up-database.sh" --database primary)"
  story::expect_equal 'the start-up was allowed' "${outcome}" succeeded
  running="$(container::is_running "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} is running" "${running}" true
  recovery="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} is the writer" "${recovery}" f
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
run_and_restore() {
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  (
    step_promotion_guard
    step_split_brain_guard
    step_control
  ) &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: restore the starting state =='
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
  require_commands bash cat
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
