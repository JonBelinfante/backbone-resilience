#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test that a decision read from a lagging replica goes wrong, and that the guard stops it.
# Usage: test-replica-lag.sh [-h | --help]
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
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly SETTLE_SECONDS=2
readonly LAG_SECONDS=6
readonly TOTAL_STEPS=8
readonly TEST_TABLE='lag_accounts'
readonly START_BALANCE=100
readonly DEBIT_AMOUNT=100
readonly OVERDRAWN_BALANCE=-100
readonly SQL_BALANCE="select balance from ${TEST_TABLE} where id = 1"
readonly SQL_WAL_POSITION='select pg_current_wal_lsn()'
readonly SQL_DEBIT="update ${TEST_TABLE} set balance = balance - ${DEBIT_AMOUNT} where id = 1"

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
Usage: test-replica-lag.sh [-h | --help]

Prove why decisions must never read a lagging replica. An account holds 100 and two debits of
100 arrive one after the other. The standby is made to apply changes 6 seconds late.
  1. Decisions read the replica (the wrong way): both debits are approved on a stale balance
     and the account goes to -100. This is the negative control: it must go wrong.
  2. Decisions read only the writer (database::read_for_decision): the second debit is
     declined and the account ends at 0.
  3. The guard refuses to read a replica at all.
  4. If a replica must be read, wait until it has replayed the write's WAL position first.

It stops at the first FAIL. Pass or fail, it then removes the delay, restores the starting
state and drops its table. The test changes the databases: use it only on the throwaway stack.

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

# Decide a debit by reading the balance from a node, then apply it on the writer if approved.
# MODE naive asks the node directly; MODE guarded asks through database::read_for_decision.
# Usage: decide_debit MODE NODE
decide_debit() {
  local mode="${1:?mode required}"
  local node="${2:?node required}"
  local balance

  case "${mode}" in
    guarded)
      balance="$(database::read_for_decision "${node}" <<< "${SQL_BALANCE}")"
      ;;
    *)
      balance="$(database::bare "${node}" <<< "${SQL_BALANCE}")"
      ;;
  esac
  story::narrate "decision (${mode}): the balance read from ${node} is ${balance}"
  if (( balance >= DEBIT_AMOUNT )); then
    story::narrate "decision: APPROVED, debit of ${DEBIT_AMOUNT} applied on ${PRIMARY_CONTAINER}"
    story::run_statement "${PRIMARY_CONTAINER}" "${SQL_DEBIT}"
  else
    story::narrate "decision: DECLINED (balance ${balance} is less than ${DEBIT_AMOUNT})"
  fi
}

# Put the account back to the starting balance and wait until the replica shows it.
reset_balance() {
  local position

  story::run_statement "${PRIMARY_CONTAINER}" \
    "update ${TEST_TABLE} set balance = ${START_BALANCE} where id = 1"
  position="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_WAL_POSITION}")"
  story::narrate "waiting until ${STANDBY_CONTAINER} has replayed up to ${position}"
  database::wait_for_replay "${STANDBY_CONTAINER}" "${position}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_BALANCE}" "${START_BALANCE}"
}

# Step 1: restore the starting state and create the account.
prepare_account() {
  begin_step 1 'restore the starting state and create an account holding 100'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "drop table if exists ${TEST_TABLE}"
  story::run_statement "${PRIMARY_CONTAINER}" \
    "create table ${TEST_TABLE} (id int primary key, balance int not null)"
  story::run_statement "${PRIMARY_CONTAINER}" \
    "insert into ${TEST_TABLE} values (1, ${START_BALANCE})"
  story::narrate "waiting ${SETTLE_SECONDS} seconds for replication"
  sleep "${SETTLE_SECONDS}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_BALANCE}" "${START_BALANCE}"
}

# Step 2: the fault. The standby keeps receiving WAL but applies it late.
make_the_standby_lag() {
  begin_step 2 "the fault: the standby applies changes ${LAG_SECONDS} seconds late"
  fault::set_apply_delay "${STANDBY_CONTAINER}" "${LAG_SECONDS}"
  story::narrate "waiting ${SETTLE_SECONDS} seconds for the setting to apply"
  sleep "${SETTLE_SECONDS}"
}

# Step 3: negative control. Two debits decided on the replica's stale balance both go through.
decide_on_the_replica() {
  begin_step 3 'wrong way: both debits are decided on the lagging replica'
  decide_debit naive "${STANDBY_CONTAINER}"
  decide_debit naive "${STANDBY_CONTAINER}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_BALANCE}" "${START_BALANCE}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_BALANCE}" "${OVERDRAWN_BALANCE}"
  story::narrate 'the replica still showed 100 for the second decision: the account is overdrawn'
}

# Step 4: back to 100, then the same two debits decided on the writer.
decide_on_the_writer() {
  begin_step 4 'right way: put the balance back, then decide both debits on the writer'
  reset_balance
  decide_debit guarded "${PRIMARY_CONTAINER}"
  decide_debit guarded "${PRIMARY_CONTAINER}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_BALANCE}" 0
}

# Step 5: the guard refuses a replica.
check_guard_refuses_replica() {
  local answer

  begin_step 5 'the guard refuses to read the replica for a decision'
  if answer="$(database::read_for_decision "${STANDBY_CONTAINER}" <<< "${SQL_BALANCE}" 2>&1)"; then
    die 1 "FAIL: the guard answered from a replica: ${answer}"
  fi
  story::narrate "the guard said: ${answer}"
  story::narrate "PASS: ${STANDBY_CONTAINER} was refused for a decision"
}

# Step 6: if a replica must be read, wait for it to replay the write first.
read_the_replica_after_waiting() {
  local position

  begin_step 6 'if a replica must be read: wait until it has replayed the write'
  story::run_statement "${PRIMARY_CONTAINER}" "update ${TEST_TABLE} set balance = 42 where id = 1"
  position="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_WAL_POSITION}")"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_BALANCE}" "${START_BALANCE}"
  story::narrate "the replica is still stale (100, not 42); waiting for position ${position}"
  database::wait_for_replay "${STANDBY_CONTAINER}" "${position}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_BALANCE}" 42
}

# Steps 7-8: remove the delay and say what the run showed.
remove_the_delay() {
  begin_step 7 'remove the delay; the replica catches up'
  fault::reset_apply_delay "${STANDBY_CONTAINER}"
  story::narrate "waiting ${SETTLE_SECONDS} seconds"
  sleep "${SETTLE_SECONDS}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_BALANCE}" 42
}

# Step 8: say what the run demonstrated.
narrate_conclusion() {
  begin_step 8 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  Decisions read from a lagging replica approved both debits: overdrawn.'
  story::narrate '  The same decisions read from the writer declined the second debit.'
  story::narrate '  The guard refuses replicas; a replica read needs the write replayed first.'
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: replica lag on ${PRIMARY_CONTAINER} and ${STANDBY_CONTAINER}"
  prepare_account
  make_the_standby_lag
  decide_on_the_replica
  decide_on_the_writer
  check_guard_refuses_replica
  read_the_replica_after_waiting
  remove_the_delay
  narrate_conclusion
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then remove the
# delay, restore the starting state and drop the test table.
run_and_restore() {
  log INFO 'running the experiment, then restoring the starting state'
  local outcome='passed'
  local pid

  run_experiment &
  pid=$!
  if ! wait "${pid}"; then
    outcome='failed'
  fi
  story::narrate '== Cleanup: remove the delay and restore the starting state =='
  fault::reset_apply_delay "${STANDBY_CONTAINER}"
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
