#!/usr/bin/env bash
# script-kind: executable
# Purpose: Kill a script with SIGKILL part way through, then check the restore recovers the stack.
# Usage: test-hard-kill.sh [-h | --help] [--target NAME] [--delays LIST]
# Requires: bash cat perl sleep
# Exit codes: 0 every kill recovered, 1 a kill was not recovered, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: nothing is configured here; the scripts this one starts read their own settings
# (PRIMARY_CONTAINER, STANDBY_CONTAINER, REBUILD_MARKER_DIR, RUN_LOG_DIR); the two container names
# are also read here, to check each node's settings file.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly DEFAULT_DELAYS='1,2,3,4,5,7,10,14'
readonly FAILOVER_SECONDS=9
readonly SETTLE_SECONDS=2
readonly DELAY_PATTERN='^[0-9]+([.][0-9]+)?$'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-hard-kill.sh [-h | --help] [--target NAME] [--delays LIST]

Start a script in its own process group, kill the whole group with SIGKILL after each delay
(no trap runs, and its docker commands die mid-step), then run restore-starting-state.sh and
require it to recover: primary writes, standby streaming, and no node holding more than one
primary_conninfo line (no old password left on disk). Each case starts from a restored
stack, and the run stops at the first case that does not recover.

  --target NAME  roundtrip: kill test-failover-roundtrip.sh (default)
                 restore: fail over first, then kill restore-starting-state.sh
  --delays LIST  seconds to wait before the kill, comma separated (default: 1,2,3,4,5,7,10,14)

A case where the script finished before the kill is reported, because it tested nothing.
This test changes the databases: use it only on the throwaway stack.

Environment: the scripts it starts read PRIMARY_CONTAINER, STANDBY_CONTAINER and RUN_LOG_DIR.

Exit codes: 0 every kill recovered, 1 a kill was not recovered, 2 usage or configuration error
USAGE
}

# Print the sibling script that a target kills.
# Usage: script_for_target TARGET
script_for_target() {
  log INFO 'looking up the script for the target'
  local target="${1:?target required}"

  case "${target}" in
    roundtrip)
      printf 'test-failover-roundtrip.sh\n'
      ;;
    restore)
      printf 'restore-starting-state.sh\n'
      ;;
    *)
      die 2 "unknown target: ${target} (use roundtrip or restore)"
      ;;
  esac
}

# Run a script in its own process group and kill the whole group after the delay.
# Print killed, or finished if the script ended first.
# Usage: kill_after_delay SECONDS SCRIPT
kill_after_delay() {
  log INFO 'running a script to kill it'
  local seconds="${1:?seconds required}"
  local script="${2:?script required}"
  local pid
  local outcome='killed'

  perl -e 'setpgrp(0, 0); exec @ARGV' bash "${SCRIPT_DIR}${script}" > /dev/null 2>&1 &
  pid=$!
  sleep "${seconds}"
  log INFO "CHANGE: SIGKILL to process group ${pid} (${script}) after ${seconds} seconds"
  kill -KILL -- "-${pid}" 2> /dev/null || outcome='finished'
  wait "${pid}" 2> /dev/null || log INFO "${script} ended with a failure status"
  printf '%s\n' "${outcome}"
}

# Bring the stack to a known good start: restored, and for the restore target also failed over.
# Usage: prepare_case TARGET
prepare_case() {
  log INFO 'preparing the case'
  local target="${1:?target required}"
  local ignored

  bash "${SCRIPT_DIR}restore-starting-state.sh" > /dev/null 2>&1 ||
    die 1 'the stack could not be restored before the case: repair it by hand'
  if [[ "${target}" == 'restore' ]]; then
    ignored="$(kill_after_delay "${FAILOVER_SECONDS}" test-failover-roundtrip.sh)"
    log INFO "failed over by killing the round trip (${ignored})"
    sleep "${SETTLE_SECONDS}"
  fi
}

# Succeed if neither node keeps more than one primary_conninfo line (an old password on disk).
check_single_conninfo() {
  local container
  local count

  for container in "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"; do
    count="$(container::conninfo_count "${container}")"
    if (( count > 1 )); then
      log ERROR "${container} holds ${count} primary_conninfo lines (at most 1 is right)"
      return 1
    fi
  done
}

# Run one case and print its result line; return 1 when the restore did not recover.
# Usage: run_case TARGET DELAY
run_case() {
  log INFO 'running one case'
  local target="${1:?target required}"
  local delay="${2:?delay required}"
  local outcome

  [[ "${delay}" =~ ${DELAY_PATTERN} ]] || die 2 "a delay must be a number of seconds: ${delay}"
  prepare_case "${target}"
  outcome="$(kill_after_delay "${delay}" "$(script_for_target "${target}")")"
  sleep "${SETTLE_SECONDS}"
  if bash "${SCRIPT_DIR}restore-starting-state.sh" > /dev/null 2>&1 &&
    check_single_conninfo; then
    printf 'PASS %s, %s at %ss: the restore recovered the stack, one conninfo per node\n' \
      "${target}" \
      "${outcome}" \
      "${delay}"
    return 0
  fi
  printf 'FAIL %s, %s at %ss: the stack did not recover cleanly\n' \
    "${target}" \
    "${outcome}" \
    "${delay}"
  return 1
}

# Run every delay in order and stop at the first case that fails.
# Usage: run_cases TARGET DELAYS
run_cases() {
  log INFO 'running the cases'
  local target="${1:?target required}"
  local list="${2:?delay list required}"
  local -a delays=()
  local split
  local delay

  split="${list//,/$'\n'}"
  if [[ -n "${split}" ]]; then
    mapfile -t delays <<< "${split}"
  fi
  for delay in "${delays[@]}"; do
    run_case "${target}" "${delay}" || die 1 "the restore did not recover after a kill at ${delay}s"
  done
  printf 'ALL RECOVERED (%d kills)\n' "${#delays[@]}"
}

# Script entry point.
main() {
  local target='roundtrip'
  local delay_list="${DEFAULT_DELAYS}"
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --target)
        (( $# >= 2 )) || die 2 '--target needs a value'
        target="${2}"
        shift 2
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
  require_commands bash cat perl sleep
  run_cases "${target}" "${delay_list}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
