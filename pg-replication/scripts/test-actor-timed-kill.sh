#!/usr/bin/env bash
# script-kind: executable
# Purpose: SIGKILL the failover actor at set delays, promote script included, then re-run it.
# Usage: test-actor-timed-kill.sh [-h | --help] [--delays LIST]
# Requires: cat mktemp perl rm sleep
# Exit codes: 0 every kill recovered, 1 a kill was not recovered, 2 usage or configuration error

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
readonly DEFAULT_DELAYS='0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9'
readonly DELAY_PATTERN='^[0-9]+([.][0-9]+)?$'
readonly DECISION_LIMIT_SECONDS=30
readonly SETTLE_SECONDS=2

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
Usage: test-actor-timed-kill.sh [-h | --help] [--delays LIST]

For each delay: crash the writer, wait for the controller's "fail-over" decision, start the actor
in its own process group and SIGKILL the whole group after the delay (so a kill can land inside
the promote script, its docker calls, or between steps). Then run the actor again and require:
one epoch (1), no unfinished failover, the old writer stopped, the standby writable.

Options:
  --delays LIST  seconds before the kill, comma separated (default: 0.1 to 0.9 in steps of 0.1)

A case where the actor finished before the kill is reported, because it tested no kill.
Throwaway stack only.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, TEMP_DIR, RUN_LOG_DIR.

Exit codes: 0 every kill recovered, 1 a kill was not recovered, 2 usage or configuration error
USAGE
}

# Wait until the controller has decided "fail-over"; fail on time-out.
wait_for_decision() {
  log INFO 'waiting for the controller to decide'
  local waited=0
  local decisions

  while (( waited < DECISION_LIMIT_SECONDS )); do
    decisions="$(controller::count "$(actor::controller_name)" fail-over)"
    if (( decisions > 0 )); then
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  die 1 'FAIL: the controller never decided to fail over'
}

# Run the actor in its own process group and kill the whole group after the delay.
# Print killed, or finished if the actor ended first.
# Usage: kill_actor_group SECONDS EPOCH_FILE
kill_actor_group() {
  log INFO 'running the actor to kill it'
  local seconds="${1:?seconds required}"
  local epoch_file="${2:?epoch file required}"
  local pid
  local outcome='killed'
  local -a command=(env "EPOCH_FILE=${epoch_file}" WAIT_SECONDS=15)

  command+=(bash "${SCRIPT_DIR}act-on-failover.sh" --controller "$(actor::controller_name)")
  perl -e 'setpgrp(0, 0); exec @ARGV' "${command[@]}" > /dev/null 2>&1 &
  pid=$!
  sleep "${seconds}"
  log INFO "CHANGE: SIGKILL to process group ${pid} (the actor) after ${seconds} seconds"
  kill -KILL -- "-${pid}" 2> /dev/null || outcome='finished'
  wait "${pid}" 2> /dev/null || log INFO 'the actor ended with a failure status'
  printf '%s\n' "${outcome}"
}

# Check the end state after the re-run.
# Usage: expect_finished EPOCH_FILE
expect_finished() {
  local epoch_file="${1:?epoch file required}"
  local recovery

  story::expect_equal 'the epoch' "$(epoch::read "${epoch_file}")" 1
  story::expect_equal 'no unfinished failover' "$(actor::pending_word "${epoch_file}")" no
  story::expect_equal 'the old writer is running' "$(actor::running_word "${PRIMARY_CONTAINER}")" no
  recovery="$(database::in_recovery "${STANDBY_CONTAINER}")"
  story::expect_equal 'the standby is in recovery' "${recovery}" f
}

# One case: crash the writer, kill the actor after the delay, re-run it, check.
# Usage: run_case EPOCH_FILE DELAY
run_case() {
  log INFO 'running one case'
  local epoch_file="${1:?epoch file required}"
  local delay="${2:?delay required}"
  local outcome

  [[ "${delay}" =~ ${DELAY_PATTERN} ]] || die 2 "a delay must be a number of seconds: ${delay}"
  printf '\n'
  story::narrate "== the actor is killed ${delay} s after it starts =="
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  rm -f "${epoch_file}" "${epoch_file}.pending"
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}"
  fault::crash_node "${PRIMARY_CONTAINER}"
  wait_for_decision
  outcome="$(kill_actor_group "${delay}" "${epoch_file}")"
  story::narrate "the actor was ${outcome} at ${delay} s; epoch now $(epoch::read "${epoch_file}")"
  sleep "${SETTLE_SECONDS}"
  actor::run "${SCRIPT_DIR}" "${epoch_file}" none
  expect_finished "${epoch_file}"
  actor::unwatch "${PRIMARY_CONTAINER}"
}

# Run every delay in order; the first failure stops the run.
# Usage: run_experiment EPOCH_FILE DELAYS
run_experiment() {
  log INFO 'running the experiment'
  local epoch_file="${1:?epoch file required}"
  local list="${2:?delay list required}"
  local -a delays=()
  local split
  local delay

  split="${list//,/$'\n'}"
  if [[ -n "${split}" ]]; then
    mapfile -t delays <<< "${split}"
  fi
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  for delay in "${delays[@]}"; do
    run_case "${epoch_file}" "${delay}"
  done
  story::narrate "PASS: all ${#delays[@]} kills recovered"
}

# Run the cases in a child shell, so a failing case cannot skip the clean-up, then restore.
# Usage: run_and_restore EPOCH_FILE DELAYS
run_and_restore() {
  local epoch_file="${1:?epoch file required}"
  local list="${2:?delay list required}"
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment "${epoch_file}" "${list}" &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: remove the controller, restore the starting state =='
  actor::unwatch "${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  [[ "${outcome}" == 'passed' ]] || die 1 'a kill was not recovered (the state was restored)'
}

# Script entry point.
main() {
  local delay_list="${DEFAULT_DELAYS}"
  local epoch_dir
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --delays)
        (( $# >= 2 )) || die 2 '--delays needs a value'
        delay_list="${2}"
        shift 2
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
  require_commands cat mktemp perl rm sleep
  epoch_dir="$(mktemp -d "${TEMP_DIR}/failover-epoch.XXXXXX")"
  CLEANUP_PATHS+=("${epoch_dir}")
  run_and_restore "${epoch_dir}/epoch" "${delay_list}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
