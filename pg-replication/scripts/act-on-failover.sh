#!/usr/bin/env bash
# script-kind: executable
# Purpose: When the failover controller decides "fail-over", fence, promote and record the epoch.
# Usage: act-on-failover.sh [-h | --help] --controller NAME
# Requires: cat sleep
# Exit codes: 0 acted or nothing to do, 1 failure, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly EPOCH_FILE="${EPOCH_FILE:-}"
readonly REBUILD_MARKER_DIR="${REBUILD_MARKER_DIR:-${TMPDIR:-/tmp}}"
readonly FENCE_WAIT_SECONDS="${FENCE_WAIT_SECONDS:-0}"
readonly ACTOR_LOCK="${ACTOR_LOCK:-on}"
readonly ACTOR_CRASH_AFTER="${ACTOR_CRASH_AFTER:-none}"
readonly WAIT_SECONDS="${WAIT_SECONDS:-120}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/controller.sh
source "${SCRIPT_DIR}../lib/controller.sh"
# shellcheck source=../lib/lock.sh
source "${SCRIPT_DIR}../lib/lock.sh"
# shellcheck source=../lib/epoch.sh
source "${SCRIPT_DIR}../lib/epoch.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: act-on-failover.sh [-h | --help] --controller NAME

Watch the detect-only controller NAME. When it decides "fail-over" this script acts, in order:
  1. raises the epoch in EPOCH_FILE by one (the record that a failover began, written first);
  2. stops the old writer for good (SIGKILL), so it cannot answer a client again;
  3. promotes the standby (promote-standby-to-primary.sh, which also fences the old writer).
A step already done is skipped, so a re-run is safe. Only one actor acts at a time (the
maintenance lock; ACTOR_LOCK=off removes it, as a test control).
It waits up to WAIT_SECONDS (default 120) for the decision, then exits 0 having done nothing.

Where the old writer cannot be reached to be killed, set FENCE_WAIT_SECONDS to its lease time plus a
margin: the actor then waits that long for the writer's guard to stop it, and promotes with --force.

Environment: EPOCH_FILE (required), FENCE_WAIT_SECONDS, ACTOR_CRASH_AFTER (a test hook: none, epoch, kill or promote makes
the script SIGKILL itself after that step), PRIMARY_CONTAINER, STANDBY_CONTAINER, WAIT_SECONDS, RUN_LOG_DIR.

Exit codes: 0 acted or nothing to do, 1 failure, 2 usage or configuration error
USAGE
}

# Wait until the controller has decided "fail-over"; succeed if it did, fail on time-out.
# Usage: wait_for_decision NAME SECONDS
wait_for_decision() {
  log INFO 'waiting for the controller to decide'
  local name="${1:?controller name required}"
  local seconds="${2:?seconds required}"
  local waited=0
  local decisions

  while (( waited < seconds )); do
    decisions="$(controller::count "${name}" fail-over)"
    if (( decisions > 0 )); then
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 1
}

# Make sure the old writer can no longer take writes. If the actor can reach it, kill it. If not
# (FENCE_WAIT_SECONDS is set), wait for its lease to run out: its guard then stops it.
stop_old_writer() {
  if (( FENCE_WAIT_SECONDS > 0 )); then
    log INFO "DECISION: not killing ${PRIMARY_CONTAINER}: waiting ${FENCE_WAIT_SECONDS} s (lease)"
    sleep "${FENCE_WAIT_SECONDS}"
  elif [[ "$(container::is_running "${PRIMARY_CONTAINER}")" == 'true' ]]; then
    log INFO "DECISION: killing the old writer ${PRIMARY_CONTAINER}"
    container::kill "${PRIMARY_CONTAINER}"
  else
    log INFO "${PRIMARY_CONTAINER} is already stopped"
  fi
}

# Promote the standby. After a lease wait the old writer may still run (stopped by its guard, or
# not), so the promotion is forced; the promotion script fences its data directory either way.
promote_standby() {
  local -a command=(bash "${SCRIPT_DIR}promote-standby-to-primary.sh")

  if (( FENCE_WAIT_SECONDS > 0 )); then
    command+=(--force)
  fi
  "${command[@]}"
}

# Test hook: SIGKILL this script right after the named step, as a crash would.
# Usage: crash_point STEP
crash_point() {
  local step="${1:?step required}"

  if [[ "${ACTOR_CRASH_AFTER}" == "${step}" ]]; then
    log WARN "test hook: crashing after the ${step} step"
    kill -KILL "$$"
  fi
}

# Do the failover: epoch first, then the old writer, then the promotion. A re-run after a crash
# resumes the same failover (the same epoch) and skips what is already done.
# Usage: fail_over EPOCH_FILE
fail_over() {
  log INFO 'starting the failover'
  local epoch_file="${1:?epoch file required}"
  local epoch

  if [[ "${ACTOR_LOCK}" == 'on' ]]; then
    lock::acquire "${REBUILD_MARKER_DIR}" "${SCRIPT_NAME}"
  fi
  if [[ "$(database::in_recovery "${STANDBY_CONTAINER}")" == 'f' ]]; then
    log INFO "DECISION: ${STANDBY_CONTAINER} is already the writer: nothing to promote"
    epoch::finish "${epoch_file}"
    return 0
  fi
  epoch="$(epoch::begin "${epoch_file}")"
  log INFO "DECISION: failing over at epoch ${epoch}"
  printf 'failing over at epoch %s\n' "${epoch}"
  crash_point epoch
  stop_old_writer
  crash_point kill
  promote_standby
  crash_point promote
  epoch::finish "${epoch_file}"
  log INFO "DECISION: ${STANDBY_CONTAINER} is the writer at epoch ${epoch}"
}

# Check the environment: the epoch file is required and the wait is a whole number.
check_environment() {
  if [[ -z "${EPOCH_FILE}" ]]; then
    die 2 'EPOCH_FILE must be set'
  fi
  require_integer WAIT_SECONDS "${WAIT_SECONDS}"
  require_integer FENCE_WAIT_SECONDS "${FENCE_WAIT_SECONDS}"
}

# Script entry point.
main() {
  local controller=''
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --controller)
        (( $# >= 2 )) || die 2 '--controller needs a value'
        controller="${2}"
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
  [[ -n "${controller}" ]] || die 2 '--controller is required'
  check_environment
  require_commands cat sleep
  if ! wait_for_decision "${controller}" "${WAIT_SECONDS}"; then
    log INFO "no fail-over decision within ${WAIT_SECONDS} s: nothing done"
    return 0
  fi
  fail_over "${EPOCH_FILE}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
