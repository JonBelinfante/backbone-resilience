#!/usr/bin/env bash
# script-kind: executable
# Purpose: Show that two failover actors deciding at once do not both act, with a control.
# Usage: test-two-actors.sh [-h | --help]
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
readonly TOTAL_STEPS=2
readonly ACT_MARKER='failing over at epoch'
readonly RACE_MARKER='epoch::begin'

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
Usage: test-two-actors.sh [-h | --help]

Freeze the writer and start two actors (act-on-failover.sh) at the same moment, so both see
the controller's "fail-over" decision. Steps:
  1. with the lock (the default): exactly one actor acts, the epoch is 1, the standby is writable;
  2. control, ACTOR_LOCK=off: both actors go ahead (one fails inside the epoch step, because two
     actors write the epoch file at once): the lock is what prevents it, and the test can tell.
It stops at the first FAIL, then restores the starting state. Throwaway stack only.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, TEMP_DIR, RUN_LOG_DIR.

Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error
USAGE
}

# Print how many lines of a file show the actor went ahead with the failover: it said so, or it
# failed inside the epoch step (two actors writing the epoch at once).
# Usage: count_acts FILE
count_acts() {
  local file="${1:?file required}"
  local count=0
  local line

  while IFS= read -r line; do
    if [[ "${line}" == *"${ACT_MARKER}"* || "${line}" == *"${RACE_MARKER}"* ]]; then
      count=$(( count + 1 ))
    fi
  done < "${file}"
  printf '%s\n' "${count}"
}

# Narrate what an actor printed.
# Usage: narrate_output NAME FILE
narrate_output() {
  local name="${1:?name required}"
  local file="${2:?file required}"

  story::narrate "output of actor ${name}:"
  story::narrate_stream < "${file}"
}

# Start both actors at once and wait for both; narrate what each said.
# Usage: race_actors EPOCH_FILE LOCK
race_actors() {
  local epoch_file="${1:?epoch file required}"
  local lock="${2:?lock setting required}"
  local pid_one
  local pid_two

  actor::run_captured "${SCRIPT_DIR}" "${epoch_file}" "${lock}" "${epoch_file}.one" &
  pid_one=$!
  actor::run_captured "${SCRIPT_DIR}" "${epoch_file}" "${lock}" "${epoch_file}.two" &
  pid_two=$!
  if ! wait "${pid_one}"; then
    story::narrate 'actor one stopped with an error'
  fi
  if ! wait "${pid_two}"; then
    story::narrate 'actor two stopped with an error'
  fi
  narrate_output one "${epoch_file}.one"
  narrate_output two "${epoch_file}.two"
}

# One case: freeze the writer, race two actors, return with the files filled.
# Usage: run_case EPOCH_FILE NUMBER LOCK TITLE
run_case() {
  local epoch_file="${1:?epoch file required}"
  local number="${2:?step number required}"
  local lock="${3:?lock setting required}"
  local title="${4:?title required}"

  printf '\n'
  story::narrate "== Step ${number} of ${TOTAL_STEPS}: ${title} =="
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  rm -f "${epoch_file}" "${epoch_file}.pending"
  actor::watch "${PRIMARY_CONTAINER}" "${SCRIPT_DIR}"
  fault::freeze_node "${PRIMARY_CONTAINER}"
  sleep 8
  race_actors "${epoch_file}" "${lock}"
  actor::unwatch "${PRIMARY_CONTAINER}"
}

# Count the actors that went ahead, from the two output files.
# Usage: acts_in EPOCH_FILE
acts_in() {
  local epoch_file="${1:?epoch file required}"
  local one
  local two

  one="$(count_acts "${epoch_file}.one")"
  two="$(count_acts "${epoch_file}.two")"
  printf '%s\n' "$(( one + two ))"
}

# Run all the steps in order; the first failure stops the run.
# Usage: run_experiment EPOCH_FILE
run_experiment() {
  local epoch_file="${1:?epoch file required}"
  local recovery

  story::narrate 'story: two actors decide at the same moment'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  controller::build "${SCRIPT_DIR}"
  run_case "${epoch_file}" 1 on 'two actors, with the lock: one acts'
  story::expect_equal 'actors that acted' "$(acts_in "${epoch_file}")" 1
  story::expect_equal 'the epoch' "$(epoch::read "${epoch_file}")" 1
  recovery="$(database::in_recovery "${STANDBY_CONTAINER}")"
  story::expect_equal "${STANDBY_CONTAINER} in recovery" "${recovery}" f
  run_case "${epoch_file}" 2 off 'control, no lock: both act'
  story::expect_equal 'actors that acted' "$(acts_in "${epoch_file}")" 2
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
  require_commands cat mktemp rm sleep
  epoch_dir="$(mktemp -d "${TEMP_DIR}/failover-epoch.XXXXXX")"
  CLEANUP_PATHS+=("${epoch_dir}")
  run_and_restore "${epoch_dir}/epoch"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
