#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test the replication modes: a switch with no restart, the standby down and killed.
# Usage: test-replication-modes.sh [-h | --help]
# Requires: bash cat mktemp sleep
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
readonly TOTAL_STEPS=4
readonly DOWN_SECONDS=5
readonly SQL_CREATE='create table if not exists mode_probe (id bigserial primary key)'
readonly SQL_DROP='drop table if exists mode_probe'
readonly SQL_INSERT='insert into mode_probe default values returning id'
readonly SQL_COUNT='select count(*) from mode_probe'
readonly SQL_START='select extract(epoch from pg_postmaster_start_time())::bigint'
readonly SQL_SYNC_STATE="select coalesce(string_agg(sync_state, ','), 'none')
  from pg_stat_replication"
readonly SQL_SLOT="select active, wal_status from pg_replication_slots
  where slot_name = 'standby1_slot'"

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
Usage: test-replication-modes.sh [-h | --help]

Test the replication modes of the writer and the standby's behaviour under each:
  1. the mode is switched with no restart: the writer's start time is unchanged, and the
     standby's sync_state follows the setting both ways;
  2. asynchronous, standby stopped: commits are unaffected, the replication slot keeps the WAL,
     and the standby catches up when it starts;
  3. synchronous, standby stopped: a commit blocks while the standby is down and completes when
     it returns, with the row on the standby;
  4. synchronous, standby killed (SIGKILL) while a commit waits: the commit completes after the
     standby restarts, and every acknowledged row is on the standby.
It stops at the first FAIL, then restores the starting state (asynchronous). Throwaway stack only.

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

# Start the standby again through the project's start script (which checks for a second writer),
# and wait until the writer streams to it.
start_standby() {
  bash "${SCRIPT_DIR}bring-up-database.sh" --database standby
  database::wait_for_streaming "${PRIMARY_CONTAINER}"
}

# Insert one row on the writer, run an action while the insert waits, then wait for the insert.
# The state of the insert just before the action (waiting or done) is written to STATE_FILE. The
# insert must complete, or the step fails.
# Usage: commit_during STATE_FILE ACTION [ARGUMENT ...]
commit_during() {
  local state_file="${1:?state file required}"
  local -a action=("${@:2}")
  local pid

  database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_INSERT}" > /dev/null &
  pid=$!
  sleep "${DOWN_SECONDS}"
  if kill -0 "${pid}" 2> /dev/null; then
    printf 'waiting\n' > "${state_file}"
  else
    printf 'done\n' > "${state_file}"
  fi
  "${action[@]}"
  wait "${pid}" || die 1 'FAIL: the commit failed instead of completing'
}

# Step 1: the mode changes without a restart: the writer's start time does not move.
step_switch() {
  local started_before
  local started_after
  local state
  local delta

  begin_step 1 'the mode is switched with no restart'
  started_before="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_START}")"
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  state="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_SYNC_STATE}")"
  story::expect_equal 'sync_state after sync' "${state}" sync
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
  state="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_SYNC_STATE}")"
  story::expect_equal 'sync_state after async' "${state}" async
  started_after="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_START}")"
  delta=$(( started_after - started_before ))
  story::expect_equal 'the writer was not restarted by either switch' "${delta}" 0
}

# Step 2: asynchronous, standby stopped: commits go on, the slot keeps WAL, the standby catches up.
step_async_down() {
  local started
  local elapsed
  local slot
  local count

  begin_step 2 'asynchronous, standby stopped: commits go on and the standby catches up'
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_DROP}; ${SQL_CREATE}" > /dev/null
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
  bash "${SCRIPT_DIR}bring-down-database.sh" --database standby > /dev/null
  started="$(story::now_milliseconds)"
  database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_INSERT}" > /dev/null
  elapsed=$(( $(story::now_milliseconds) - started ))
  story::narrate "a commit with the standby stopped took ${elapsed} ms"
  story::expect_between 'async: the commit is not held up' "${elapsed}" 0 1000
  slot="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_SLOT}")"
  story::expect_equal 'slot inactive, still reserving WAL' "${slot}" 'f|reserved'
  start_standby
  count="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_COUNT}")"
  story::expect_equal 'the standby has the row written while it was down' "${count}" 1
}

# Step 3: synchronous, standby stopped: a commit waits for it and completes when it returns.
# Usage: step_sync_down SCRATCH_DIR
step_sync_down() {
  local scratch="${1:?scratch folder required}"
  local started
  local elapsed
  local count
  local waiting

  begin_step 3 'synchronous, standby stopped: a commit blocks until the standby returns'
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  bash "${SCRIPT_DIR}bring-down-database.sh" --database standby > /dev/null
  started="$(story::now_milliseconds)"
  commit_during "${scratch}/state" start_standby
  waiting="$(< "${scratch}/state")"
  story::expect_equal "the commit was still waiting after ${DOWN_SECONDS} s" "${waiting}" waiting
  elapsed=$(( $(story::now_milliseconds) - started ))
  story::narrate "the commit completed ${elapsed} ms after it started, when the standby returned"
  story::expect_between 'sync: the commit waited for the standby' "${elapsed}" 5000 60000
  count="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_COUNT}")"
  story::expect_equal 'the standby has the row' "${count}" 2
}

# Step 4: synchronous, standby SIGKILLed while a commit waits: the commit completes after the
# restart, and no row the writer acknowledged is missing from the standby.
# Usage: step_sync_crash SCRATCH_DIR
step_sync_crash() {
  local scratch="${1:?scratch folder required}"
  local rows
  local waiting

  begin_step 4 'synchronous, standby killed during a commit: no acknowledged row is lost'
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  fault::crash_node "${STANDBY_CONTAINER}"
  commit_during "${scratch}/state" start_standby
  waiting="$(< "${scratch}/state")"
  story::expect_equal 'the commit waited while the standby was dead' "${waiting}" waiting
  # Three rows were acknowledged in this run: one in step 2, one in step 3 and this one.
  rows="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_COUNT}")"
  story::expect_equal 'acknowledged rows on the standby, none missing' "${rows}" 3
}

# Run the steps in order; the first failure stops the run.
# Usage: run_experiment SCRATCH_DIR
run_experiment() {
  local scratch="${1:?scratch folder required}"

  story::narrate 'story: replication modes, the standby down and killed'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  step_switch
  step_async_down
  step_sync_down "${scratch}"
  step_sync_crash "${scratch}"
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Run the steps in a child shell, so a failure cannot skip the clean-up; then restore asynchronous.
# Usage: run_and_restore SCRATCH_DIR
run_and_restore() {
  local scratch="${1:?scratch folder required}"
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment "${scratch}" &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: restore the starting state (asynchronous) =='
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_DROP}"
  [[ "${outcome}" == 'passed' ]] || die 1 'the experiment failed (the state was restored)'
}

# Script entry point.
main() {
  local scratch
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
  require_commands bash cat mktemp sleep
  scratch="$(mktemp -d "${TEMP_DIR}/modes.XXXXXX")"
  CLEANUP_PATHS+=("${scratch}")
  run_and_restore "${scratch}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
