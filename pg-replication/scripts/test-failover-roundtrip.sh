#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test a failover and fail-back round trip: data must survive on both databases.
# Usage: test-failover-roundtrip.sh [-h | --help]
# Requires: cat sleep
# Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them.
# UP_PULL_POLICY is passed to docker compose up --pull (use never when Docker Hub is unreachable).
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly UP_PULL_POLICY="${UP_PULL_POLICY:-missing}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly COMPOSE_FILE="${SCRIPT_DIR}../docker-compose.yml"
readonly SETTLE_SECONDS=2
readonly TOTAL_STEPS=17
readonly TEST_SCHEMA='public'
readonly TEST_TABLE='failover_test'
readonly SQL_ROLE='select pg_is_in_recovery()'
readonly SQL_TABLES="select count(*) from pg_tables where schemaname = '${TEST_SCHEMA}'"
readonly SQL_NOTES="select coalesce(string_agg(note, ',' order by id), '') from ${TEST_TABLE}"
readonly IS_WRITER='f'
readonly IS_REPLICA='t'
readonly NOTE_ONE='row-1-written-on-primary'
readonly NOTE_TWO='row-2-written-on-promoted-standby'
readonly NOTE_THREE='row-3-written-while-replica-was-down'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/story.sh
source "${SCRIPT_DIR}../lib/story.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-failover-roundtrip.sh [-h | --help]

Run the failover round trip in 17 steps: replicate a row, fail over, rejoin the old
primary, write while the replica is down, and compare both databases. It stops at the
first FAIL. Pass or fail, it then restores the starting roles and drops its table.
Terminal and run log tell the story: each line has a UTC time and the script name, and
shows every SQL statement, the data it returned, and each script run.

Environment:
  PRIMARY_CONTAINER, STANDBY_CONTAINER  (defaults: pg-primary, pg-standby)
  UP_PULL_POLICY  docker compose up --pull value (default: missing)
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

# Wait step: pause so replication has time to deliver, as the test plan asks.
settle() {
  local number="${1:?step number required}"

  begin_step "${number}" "wait ${SETTLE_SECONDS} seconds"
  story::narrate "waiting ${SETTLE_SECONDS} seconds for replication"
  sleep "${SETTLE_SECONDS}"
}

# Step 1: start both databases and confirm the starting roles.
start_both_databases() {
  begin_step 1 'start the primary and the standby'
  story::run_logged container::compose_up "${COMPOSE_FILE}" "${UP_PULL_POLICY}"
  story::run_logged bash "${SCRIPT_DIR}bring-up-database.sh" --database primary
  story::run_logged bash "${SCRIPT_DIR}bring-up-database.sh" --database standby
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_ROLE}" "${IS_WRITER}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_ROLE}" "${IS_REPLICA}"
}

# Steps 2-4: drop every table on the primary, wait, and check the standby has none.
drop_tables_and_check_standby() {
  begin_step 2 'drop every table on the primary'
  story::drop_all_tables "${PRIMARY_CONTAINER}" "${TEST_SCHEMA}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_TABLES}" 0
  settle 3
  begin_step 4 'check all tables are dropped on the standby'
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_TABLES}" 0
}

# Steps 5-7: create a table and a row on the primary, wait, and check the standby has them.
write_row_and_check_standby() {
  local create="create table ${TEST_TABLE} (id serial primary key, note text not null)"
  local insert="insert into ${TEST_TABLE}(note) values ('${NOTE_ONE}')"

  begin_step 5 'create a table and insert a row on the primary'
  story::run_statement "${PRIMARY_CONTAINER}" "${create}"
  story::run_statement "${PRIMARY_CONTAINER}" "${insert}"
  settle 6
  begin_step 7 'check the data is on the standby'
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_NOTES}" "${NOTE_ONE}"
}

# Steps 8-9: stop the primary, check it is down, promote the standby and write to it.
fail_over_to_standby() {
  local insert="insert into ${TEST_TABLE}(note) values ('${NOTE_TWO}')"

  begin_step 8 'bring the primary down and check it is down'
  story::run_logged bash "${SCRIPT_DIR}bring-down-database.sh" --database primary
  story::expect_stopped "${PRIMARY_CONTAINER}"
  begin_step 9 'promote the standby and insert a row into it'
  story::run_logged bash "${SCRIPT_DIR}promote-standby-to-primary.sh"
  story::run_statement "${STANDBY_CONTAINER}" "${insert}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_NOTES}" "${NOTE_ONE},${NOTE_TWO}"
}

# Steps 10-11: bring the old primary back as a standby, wait, and check it has the data.
rejoin_old_primary() {
  begin_step 10 'bring the old primary back as a standby of the new writer'
  story::run_logged bash "${SCRIPT_DIR}promote-primary-to-standby.sh"
  story::narrate 'waiting 2 seconds for replication'
  sleep "${SETTLE_SECONDS}"
  begin_step 11 'check the data is on the old primary'
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_ROLE}" "${IS_REPLICA}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_NOTES}" "${NOTE_ONE},${NOTE_TWO}"
}

# Steps 12-13: stop the replica and write to the writer while it is down.
write_while_replica_is_down() {
  local insert="insert into ${TEST_TABLE}(note) values ('${NOTE_THREE}')"

  begin_step 12 'bring the replica down and check it is down'
  story::run_logged bash "${SCRIPT_DIR}bring-down-database.sh" --database primary
  story::expect_stopped "${PRIMARY_CONTAINER}"
  begin_step 13 'insert a row into the writer while the replica is down'
  story::run_statement "${STANDBY_CONTAINER}" "${insert}"
}

# Steps 14-16: start the replica, wait, and check it caught up.
replica_catches_up() {
  begin_step 14 'bring the replica back up'
  story::run_logged bash "${SCRIPT_DIR}bring-up-database.sh" --database primary
  settle 15
  begin_step 16 'check the new row is on the replica'
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_NOTES}" "${NOTE_ONE},${NOTE_TWO},${NOTE_THREE}"
}

# Step 17: both databases hold identical data and keep the roles they ended with.
compare_both_databases() {
  local all_notes="${NOTE_ONE},${NOTE_TWO},${NOTE_THREE}"

  begin_step 17 'final check: the data is in both databases'
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_NOTES}" "${all_notes}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_NOTES}" "${all_notes}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_ROLE}" "${IS_WRITER}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_ROLE}" "${IS_REPLICA}"
}

# Say what the whole run demonstrated, so the log reads as a story with evidence.
narrate_conclusion() {
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  Writes reached the standby (2-7); the promoted standby took writes (8-9).'
  story::narrate '  The old primary rejoined via pg_rewind (10-11); the replica caught up (12-16)'
  story::narrate '  Both databases ended with identical rows and swapped roles (17).'
}

# Run all the steps in order; the first failure stops the run.
run_round_trip() {
  story::narrate "story: failover round trip on ${PRIMARY_CONTAINER} and ${STANDBY_CONTAINER}"
  start_both_databases
  drop_tables_and_check_standby
  write_row_and_check_standby
  fail_over_to_standby
  rejoin_old_primary
  write_while_replica_is_down
  replica_catches_up
  compare_both_databases
  narrate_conclusion
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore the
# starting roles and drop the test table.
run_and_restore() {
  log INFO 'running the round trip, then restoring the starting state'
  local outcome='passed'
  local pid

  run_round_trip &
  pid=$!
  if ! wait "${pid}"; then
    outcome='failed'
  fi
  story::narrate '== Cleanup: restore the starting state =='
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "drop table if exists ${TEST_TABLE}"
  [[ "${outcome}" == 'passed' ]] || die 1 'the round trip failed (the starting state was restored)'
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
