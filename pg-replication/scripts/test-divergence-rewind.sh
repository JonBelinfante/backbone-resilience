#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test a true divergence: the old primary accepts writes the new one never saw.
# Usage: test-divergence-rewind.sh [-h | --help]
# Requires: bash cat sleep
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
readonly SETTLE_SECONDS=2
readonly TOTAL_STEPS=10
readonly TEST_TABLE='divergence_test'
readonly SQL_ROLE='select pg_is_in_recovery()'
readonly SQL_NOTES="select coalesce(string_agg(note, ',' order by id), '') from ${TEST_TABLE}"
readonly IS_REPLICA='t'
readonly NOTE_BASE='base-before-the-split'
readonly NOTES_LOST='lost-1,lost-2,lost-3'
readonly NOTES_KEPT='kept-1,kept-2'
readonly REWOUND_TEXT='rewinding from last common checkpoint'
readonly NOT_NEEDED_TEXT='no rewind required'

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
Usage: test-divergence-rewind.sh [-h | --help]

Prove that pg_rewind really rewinds. The standby is made to stop following the primary, the
primary then accepts three writes the standby never sees, and the standby is promoted anyway
(forced) so that two histories exist. After the old primary is stopped cleanly it is rebuilt
as a standby. The test requires pg_rewind to report a real rewind (not "no rewind required"),
the three writes to be gone from the old primary, and both nodes to end with identical rows.

Those three writes were acknowledged to the client and are lost: that is the observed cost of
asynchronous replication when the writer is replaced while it holds writes the standby lacks.

It stops at the first FAIL. Pass or fail, it then restores the starting state and drops its table.
The test changes the databases: use it only on the throwaway stack.

Environment:
  PRIMARY_CONTAINER, STANDBY_CONTAINER  (defaults: pg-primary, pg-standby)
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

# Insert rows whose notes are given as a comma-separated list, on a node.
# Usage: insert_notes CONTAINER NOTE_LIST
insert_notes() {
  local container="${1:?container required}"
  local notes="${2:?notes required}"
  local values="('${notes//,/\'),(\'}')"

  story::run_statement "${container}" "insert into ${TEST_TABLE}(note) values ${values}"
}

# Step 1: start from the restored stack, create the table and one row that replicates.
prepare_table() {
  begin_step 1 'restore the starting state and create the test table with one row'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "drop table if exists ${TEST_TABLE}"
  story::run_statement "${PRIMARY_CONTAINER}" \
    "create table ${TEST_TABLE} (id serial primary key, note text not null)"
  insert_notes "${PRIMARY_CONTAINER}" "${NOTE_BASE}"
  story::narrate "waiting ${SETTLE_SECONDS} seconds for replication"
  sleep "${SETTLE_SECONDS}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_NOTES}" "${NOTE_BASE}"
}

# Step 2: the fault. The standby stops following; nothing is streaming any more.
cut_the_standby_off() {
  local streaming

  begin_step 2 'the fault: the standby stops following the primary'
  fault::stop_streaming "${STANDBY_CONTAINER}"
  story::narrate "waiting ${SETTLE_SECONDS} seconds for the WAL receiver to end"
  sleep "${SETTLE_SECONDS}"
  streaming="$(database::streaming_count "${PRIMARY_CONTAINER}")"
  story::expect_equal 'no standby is streaming from the primary' "${streaming}" 0
}

# Step 3: writes the standby will never see. Abort if the standby has them (nothing was tested).
write_lost_rows() {
  begin_step 3 'the primary accepts three writes the standby never sees'
  insert_notes "${PRIMARY_CONTAINER}" "${NOTES_LOST}"
  story::narrate "waiting ${SETTLE_SECONDS} seconds: the standby must still not have them"
  sleep "${SETTLE_SECONDS}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_NOTES}" "${NOTE_BASE}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_NOTES}" "${NOTE_BASE},${NOTES_LOST}"
}

# Steps 4-5: promote the standby while the old primary still runs, then write on both sides.
split_the_history() {
  begin_step 4 'promote the standby while the old primary still accepts writes (forced)'
  story::run_logged bash "${SCRIPT_DIR}promote-standby-to-primary.sh" --force
  begin_step 5 'the new writer takes different writes: two histories now exist'
  insert_notes "${STANDBY_CONTAINER}" "${NOTES_KEPT}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_NOTES}" "${NOTE_BASE},${NOTES_KEPT}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_NOTES}" "${NOTE_BASE},${NOTES_LOST}"
}

# Step 6: stop the old primary cleanly, which pg_rewind requires.
stop_old_primary() {
  begin_step 6 'stop the old primary cleanly'
  story::run_logged bash "${SCRIPT_DIR}bring-down-database.sh" --database primary
  story::expect_stopped "${PRIMARY_CONTAINER}"
}

# Print yes if the text appears in the output, otherwise no.
# Usage: contains_text OUTPUT TEXT
contains_text() {
  local output="${1-}"
  local text="${2:?text required}"

  if [[ "${output}" == *"${text}"* ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# Step 7: rebuild the old primary as a standby, keeping the output to check what pg_rewind did.
rewind_old_primary() {
  local output
  local answer

  begin_step 7 'rebuild the old primary as a standby of the new writer (pg_rewind)'
  output="$(bash "${SCRIPT_DIR}promote-primary-to-standby.sh" 2>&1)"
  story::narrate_stream <<< "${output}"
  answer="$(contains_text "${output}" 'servers diverged')"
  story::expect_equal 'pg_rewind found the servers diverged' "${answer}" yes
  answer="$(contains_text "${output}" "${REWOUND_TEXT}")"
  story::expect_equal 'pg_rewind did a real rewind' "${answer}" yes
  answer="$(contains_text "${output}" "${NOT_NEEDED_TEXT}")"
  story::expect_equal 'pg_rewind did not say "no rewind required"' "${answer}" no
  answer="$(contains_text "${output}" 'emptying volume')"
  story::expect_equal 'the old primary was rewound, not cloned' "${answer}" no
}

# Steps 8-9: the old primary is a replica again, the lost writes are gone, both nodes agree.
check_both_nodes() {
  local streaming

  begin_step 8 'the old primary is a streaming replica again'
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_ROLE}" "${IS_REPLICA}"
  streaming="$(database::streaming_count "${STANDBY_CONTAINER}")"
  story::expect_equal 'the new writer reports one streaming standby' "${streaming}" 1
  begin_step 9 'the three lost writes are gone and both nodes hold identical rows'
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_NOTES}" "${NOTE_BASE},${NOTES_KEPT}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_NOTES}" "${NOTE_BASE},${NOTES_KEPT}"
}

# Step 10: say what the run demonstrated.
narrate_conclusion() {
  begin_step 10 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  pg_rewind found where the two histories split and undid the old primary.'
  story::narrate '  Three writes it had acknowledged (lost-1..3) were discarded: the cost of'
  story::narrate '  replacing a writer that holds writes its standby never received.'
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: divergence and pg_rewind on ${PRIMARY_CONTAINER} and ${STANDBY_CONTAINER}"
  prepare_table
  cut_the_standby_off
  write_lost_rows
  split_the_history
  stop_old_primary
  rewind_old_primary
  check_both_nodes
  narrate_conclusion
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore the
# starting roles and drop the test table.
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
  require_commands bash cat sleep
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
