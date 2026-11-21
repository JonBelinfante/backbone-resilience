#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test the slot limit: a dead standby cannot fill the primary's disk, and is re-cloned.
# Usage: test-slot-limit.sh [-h | --help]
# Requires: cat sleep
# Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them; STANDBY_SLOT is the standby's replication slot.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly STANDBY_SLOT="${STANDBY_SLOT:-standby1_slot}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly TOTAL_STEPS=7
readonly TEST_TABLE='slot_probe'
readonly MESSAGES_PER_ROUND=20
readonly MAX_ROUNDS=120
readonly MIN_FREE_MEGABYTES=6000
readonly BOUND_PERCENT=150
readonly SETTLE_SECONDS=10
readonly SQL_LIMIT="select setting::int from pg_settings where name = 'max_slot_wal_keep_size'"
readonly REMOVED_TEXT='has already been removed'

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
Usage: test-slot-limit.sh [-h | --help]

Prove the limit on WAL kept for a dead standby (max_slot_wal_keep_size, 1 GB in compose).
The standby is stopped and the primary writes WAL, with a checkpoint each round, until the
slot is invalidated (wal_status lost). It requires:
  - the primary accepts a write in every round (a dead standby cannot stop it),
  - its WAL directory stays within 150% of the limit,
  - the standby cannot stream when started again ("has already been removed"),
  - restore-starting-state.sh re-clones it and replaces the lost slot, and it streams.

Compose sets the limit on the command line, which ALTER SYSTEM cannot override, so the real
limit is used and about 1.5 GB of WAL is written. It stops if less than 6 GB is free.
It stops at the first FAIL. Pass or fail, it then restores the starting state.

Environment:
  PRIMARY_CONTAINER, STANDBY_CONTAINER  (defaults: pg-primary, pg-standby)
  STANDBY_SLOT    the standby's replication slot (default: standby1_slot)
  RUN_LOG_DIR     directory for this run's log file (default: temporary directory)

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

# Print the slot's status on the primary: reserved, extended, unreserved, lost, or none.
read_slot_status() {
  local state

  state="$(database::slot_state "${PRIMARY_CONTAINER}" "${STANDBY_SLOT}")"
  state="${state:-none}"
  printf '%s\n' "${state%%|*}"
}

# Narrate the slot and the primary's WAL directory.
# Usage: narrate_slot LABEL
narrate_slot() {
  local label="${1:?label required}"
  local state
  local status
  local active
  local behind
  local safe
  local wal

  state="$(database::slot_state "${PRIMARY_CONTAINER}" "${STANDBY_SLOT}")"
  IFS='|' read -r status active behind safe <<< "${state:-none|||}"
  wal="$(database::wal_megabytes "${PRIMARY_CONTAINER}")"
  story::narrate "${label}: slot ${status}, active ${active}, ${behind} MB behind, ${safe} MB safe"
  story::narrate "${label}: the WAL directory holds ${wal} MB"
}

# Step 1: start from the restored stack, check disk space and note the limit.
prepare_and_baseline() {
  local data_path
  local free
  local limit
  local status

  begin_step 1 'restore the starting state, check disk space, note the limit'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  data_path="$(container::setting "${PRIMARY_CONTAINER}" PGDATA)"
  free="$(container::free_megabytes "${PRIMARY_CONTAINER}" "${data_path}")"
  story::narrate "free space on the primary's data volume: ${free} MB (need ${MIN_FREE_MEGABYTES})"
  (( free >= MIN_FREE_MEGABYTES )) || die 1 "ABORT: only ${free} MB free"
  limit="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_LIMIT}")"
  story::narrate "max_slot_wal_keep_size is ${limit} MB"
  story::run_statement "${PRIMARY_CONTAINER}" "drop table if exists ${TEST_TABLE}"
  story::run_statement "${PRIMARY_CONTAINER}" "create table ${TEST_TABLE} (round int primary key)"
  narrate_slot baseline
  status="$(read_slot_status)"
  story::expect_equal 'the slot starts healthy' "${status}" 'reserved'
}

# Step 2: the fault. The standby is stopped, so its slot stops advancing.
stop_the_standby() {
  begin_step 2 'the fault: the standby is stopped cleanly and stays down'
  story::run_logged bash "${SCRIPT_DIR}bring-down-database.sh" --database standby
  story::expect_stopped "${STANDBY_CONTAINER}"
}

# Step 3: write WAL round by round until the slot is invalidated; stop if retention is unbounded.
fill_until_the_slot_is_lost() {
  local round=1
  local status='reserved'
  local limit
  local bound
  local marker
  local wal

  begin_step 3 'the primary writes WAL, with a checkpoint each round, until the slot is lost'
  limit="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_LIMIT}")"
  bound=$(( limit * BOUND_PERCENT / 100 ))
  while [[ "${status}" != 'lost' ]]; do
    (( round <= MAX_ROUNDS )) || die 1 "ABORT: slot not invalidated after ${MAX_ROUNDS} rounds"
    marker="insert into ${TEST_TABLE} values (${round})"
    fault::generate_wal "${PRIMARY_CONTAINER}" "${MESSAGES_PER_ROUND}"
    database::bare "${PRIMARY_CONTAINER}" <<< 'checkpoint' > /dev/null
    database::bare "${PRIMARY_CONTAINER}" <<< "${marker}" > /dev/null
    narrate_slot "round ${round}"
    status="$(read_slot_status)"
    wal="$(database::wal_megabytes "${PRIMARY_CONTAINER}")"
    (( wal <= bound )) || die 1 "FAIL: the WAL directory reached ${wal} MB (bound ${bound} MB)"
    round=$(( round + 1 ))
  done
  story::narrate "PASS: the slot was invalidated, the WAL directory never exceeded ${bound} MB"
  story::narrate "PASS: the primary accepted a write in each of $(( round - 1 )) rounds"
}

# Step 4: the primary is still fully usable with the standby gone.
check_primary_still_writes() {
  begin_step 4 'the primary still accepts writes with its standby gone'
  story::run_statement "${PRIMARY_CONTAINER}" "insert into ${TEST_TABLE} values (100000)"
  story::expect_query "${PRIMARY_CONTAINER}" 'select pg_is_in_recovery()' 'f'
}

# Step 5: start the standby; it cannot stream because the WAL it needs is gone.
start_the_standby_again() {
  local streaming
  local logs
  local answer

  begin_step 5 'start the standby again: the WAL it needs has been removed'
  story::run_logged bash "${SCRIPT_DIR}bring-up-database.sh" --database standby
  story::narrate "waiting ${SETTLE_SECONDS} seconds for it to try to stream"
  sleep "${SETTLE_SECONDS}"
  streaming="$(database::streaming_count "${PRIMARY_CONTAINER}")"
  story::expect_equal 'no standby is streaming' "${streaming}" 0
  logs="$(container::logs "${STANDBY_CONTAINER}" 2>&1)"
  if [[ "${logs}" == *"${REMOVED_TEXT}"* ]]; then
    answer='yes'
  else
    answer='no'
  fi
  story::expect_equal "the standby log says the WAL ${REMOVED_TEXT}" "${answer}" 'yes'
}

# Step 6: the restore script notices the standby is not streaming, re-clones it, fixes the slot.
recover_by_reclone() {
  local streaming
  local status

  begin_step 6 'recovery: restore-starting-state.sh re-clones the standby and replaces the slot'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  streaming="$(database::streaming_count "${PRIMARY_CONTAINER}")"
  story::expect_equal 'the standby streams again' "${streaming}" 1
  narrate_slot recovered
  status="$(read_slot_status)"
  story::expect_equal 'the slot is healthy again' "${status}" 'reserved'
}

# Step 7: say what the run demonstrated.
narrate_conclusion() {
  begin_step 7 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  A dead standby could not stop the primary or fill its disk past the limit.'
  story::narrate '  Past the limit the slot was invalidated and the standby could not catch up.'
  story::narrate '  The documented recovery, a re-clone with a fresh slot, restored streaming.'
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: slot limit on ${PRIMARY_CONTAINER} and ${STANDBY_CONTAINER}"
  prepare_and_baseline
  stop_the_standby
  fill_until_the_slot_is_lost
  check_primary_still_writes
  start_the_standby_again
  recover_by_reclone
  narrate_conclusion
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore the
# starting state and drop the test table.
run_and_restore() {
  log INFO 'running the experiment, then restoring the starting state'
  local outcome='passed'
  local pid

  run_experiment &
  pid=$!
  if ! wait "${pid}"; then
    outcome='failed'
  fi
  story::narrate '== Cleanup: restore the starting state =='
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "drop table if exists ${TEST_TABLE}"
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
  require_commands cat sleep
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
