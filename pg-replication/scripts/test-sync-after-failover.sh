#!/usr/bin/env bash
# script-kind: executable
# Purpose: Measure the window after a failover from sync replication when writes have one copy.
# Usage: test-sync-after-failover.sh [-h | --help]
# Requires: cat
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
readonly TOTAL_STEPS=4
readonly SQL_NAMES='show synchronous_standby_names'
readonly SQL_SYNC_STATE="select coalesce(string_agg(sync_state, ','), 'none')
  from pg_stat_replication"
readonly SQL_WRITE="select pg_logical_emit_message(true, 'sync-window', 'x')"

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
Usage: test-sync-after-failover.sh [-h | --help]

Run with synchronous replication, crash the writer and promote the standby, then watch the
window until the old node has rejoined and synchronous replication is switched on again. Steps:
  1. synchronous replication is on and the standby is the synchronous one;
  2. after the failover the new writer is asynchronous and has no standby, yet still
     acknowledges a write: that write exists on one node only;
  3. the old node rejoins and streams, but as an asynchronous standby: still no zero-loss;
  4. set-replication-mode.sh --mode sync (run for the new writer) closes the window; its
     length, from the promotion, is reported.
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

# Step 1: synchronous replication on, standby synchronous.
step_sync_on() {
  begin_step 1 'synchronous replication is on and the standby is synchronous'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  story::expect_equal 'sync_state of the standby' \
    "$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_SYNC_STATE}")" \
    sync
  database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_WRITE}" > /dev/null
}

# Step 2: crash, promote; the new writer is asynchronous, with no standby, and still acknowledges.
step_after_failover() {
  begin_step 2 'after the failover the new writer acknowledges writes with no second copy'
  fault::crash_node "${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}promote-standby-to-primary.sh"
  story::expect_equal 'synchronous_standby_names on the new writer' \
    "$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_NAMES}")" \
    ''
  story::expect_equal 'standbys streaming from the new writer' \
    "$(database::streaming_count "${STANDBY_CONTAINER}")" \
    0
  database::bare "${STANDBY_CONTAINER}" <<< "${SQL_WRITE}" > /dev/null
  story::narrate 'PASS: a write was acknowledged while only one copy of it existed'
}

# Step 3: the old node rejoins as an asynchronous standby.
step_rejoined() {
  begin_step 3 'the old node rejoins and streams, but asynchronously'
  story::run_logged bash "${SCRIPT_DIR}promote-primary-to-standby.sh"
  database::wait_for_streaming "${STANDBY_CONTAINER}"
  story::expect_equal 'sync_state of the rejoined node' \
    "$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_SYNC_STATE}")" \
    async
  story::expect_equal 'synchronous_standby_names on the new writer' \
    "$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_NAMES}")" \
    ''
}

# Step 4: switch synchronous replication on for the new writer; report how long the window was.
# Usage: step_sync_again STARTED_MS
step_sync_again() {
  local started="${1:?start time required}"
  local now

  begin_step 4 'synchronous replication is switched on again for the new writer'
  story::run_logged env \
    "PRIMARY_CONTAINER=${STANDBY_CONTAINER}" \
    bash \
    "${SCRIPT_DIR}set-replication-mode.sh" \
    --mode sync
  story::expect_equal 'sync_state of the rejoined node' \
    "$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_SYNC_STATE}")" \
    sync
  now="$(story::now_milliseconds)"
  story::narrate "the window with no zero-loss guarantee: $(( now - started )) ms from the crash"
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  local started

  story::narrate 'story: the window between a failover from sync and the next sync'
  step_sync_on
  started="$(story::now_milliseconds)"
  step_after_failover
  step_rejoined
  step_sync_again "${started}"
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
run_and_restore() {
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment &
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
  require_commands cat
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
