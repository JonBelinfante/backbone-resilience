#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test the database under many concurrent clients: idempotency keys, atomicity, throughput.
# Usage: test-load.sh [-h | --help]
# Requires: cat sleep
# Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them. LOAD_CLIENTS is the number of concurrent clients, LOAD_SECONDS how long each run
# lasts, and LOAD_KEYS how many idempotency keys the clients draw from (fewer: more collisions).
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly LOAD_CLIENTS="${LOAD_CLIENTS:-16}"
readonly LOAD_SECONDS="${LOAD_SECONDS:-15}"
readonly LOAD_KEYS="${LOAD_KEYS:-1000000}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly TOTAL_STEPS=6
readonly CRASH_AFTER_SECONDS=5
readonly SQL_RESET='truncate payments; update accounts set balance = 0'
readonly SQL_CONSERVED='select (select coalesce(sum(balance), 0) from accounts)
  - (select coalesce(sum(amount), 0) from payments)'
readonly SQL_PAYMENTS='select count(*) from payments'
readonly SQL_SUMMARY="select count(*) || ':' || coalesce(sum(amount), 0) || ':' ||
  md5(coalesce(string_agg(key::text, ',' order by key), '')) from payments"
readonly SQL_BALANCES='select coalesce(sum(balance), 0) from accounts'
readonly SQL_CHECK_PAYMENTS="select bt_index_check('payments_pkey'::regclass)"
readonly SQL_CHECK_ACCOUNTS="select bt_index_check('accounts_pkey'::regclass)"

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
Usage: test-load.sh [-h | --help]

Run 16 concurrent clients (pgbench) for 15 seconds, each inserting a payment with an idempotency
key drawn from a million values, so some keys are chosen twice, often at the same moment; each
accepted payment credits an account exactly once. It requires:
  - no failed transaction, and duplicate keys really collided (else nothing was tested),
  - money conserved: the sum of balances equals the sum of accepted payments, exactly,
  - the standby holds exactly the same payments and balances once it has caught up,
  - the same under synchronous replication (the throughput of both modes is reported),
  - atomicity under a crash: the writer is killed mid-run and restarted, and the invariant
    still holds, with no index damage.
Failover under load needs a client that reconnects (pgbench aborts when its server dies): that
belongs to the Python load generator. Set LOAD_CLIENTS, LOAD_SECONDS and LOAD_KEYS to resize.
It stops at the first FAIL; pass or fail it then restores the stack and drops its tables.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, LOAD_CLIENTS (16), LOAD_SECONDS (15),
LOAD_KEYS (1000000), RUN_LOG_DIR.

Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error
USAGE
}

# Fail early if a setting is not a whole number.
check_environment() {
  log INFO 'checking the settings'
  require_integer LOAD_CLIENTS "${LOAD_CLIENTS}"
  require_integer LOAD_SECONDS "${LOAD_SECONDS}"
  require_integer LOAD_KEYS "${LOAD_KEYS}"
}

# Start a numbered step: print its heading and record it in the run log.
begin_step() {
  local number="${1:?step number required}"
  local title="${2:?title required}"

  printf '\n'
  story::narrate "== Step ${number} of ${TOTAL_STEPS}: ${title} =="
}

# Print the transaction script every client runs: an idempotent payment that credits one account.
payment_script() {
  cat <<SQL
\set k random(1, ${LOAD_KEYS})
\set a random(1, 100)
\set d random(1, 50)
WITH accepted AS (
  INSERT INTO payments(key, account, amount) VALUES (:k, :a, :d)
  ON CONFLICT (key) DO NOTHING RETURNING account, amount)
UPDATE accounts SET balance = balance + accepted.amount
FROM accepted WHERE accounts.id = accepted.account;
SQL
}

# Print the figure that follows a label in pgbench's summary, or nothing if it is not there.
# Usage: summary_figure SUMMARY LABEL
summary_figure() {
  local summary="${1-}"
  local label="${2:?label required}"
  local line

  while IFS= read -r line; do
    if [[ "${line}" == "${label}"* ]]; then
      line="${line#"${label}"}"
      printf '%s\n' "${line%% *}"
      return 0
    fi
  done <<< "${summary}"
}

# Step 1: restore, then create the tables and the extension that checks indexes.
prepare_tables() {
  begin_step 1 'restore the starting state and create the tables'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" 'create extension if not exists amcheck'
  story::run_statement "${PRIMARY_CONTAINER}" 'drop table if exists payments, accounts'
  story::run_statement "${PRIMARY_CONTAINER}" \
    'create table accounts (id int primary key, balance bigint not null)'
  story::run_statement "${PRIMARY_CONTAINER}" \
    'create table payments (key int primary key, account int not null, amount int not null)'
  story::run_statement "${PRIMARY_CONTAINER}" \
    'insert into accounts select g, 0 from generate_series(1, 100) g'
}

# Check on the writer that money is conserved: balances minus accepted payments is exactly 0.
# Usage: check_invariants LABEL
check_invariants() {
  log INFO 'checking the invariants'
  local label="${1:?label required}"
  local difference

  difference="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_CONSERVED}")"
  story::expect_equal "${label}: money is conserved (balances minus payments)" "${difference}" 0
}

# Run the load, using the transaction script, and print pgbench's summary.
run_pgbench() {
  log INFO 'running pgbench'

  payment_script | database::load "${PRIMARY_CONTAINER}" "${LOAD_CLIENTS}" "${LOAD_SECONDS}"
}

# Run the workload once, narrate the summary, and check nothing failed and duplicates collided.
# Usage: run_load LABEL
run_load() {
  log INFO 'running the load'
  local label="${1:?label required}"
  local summary
  local processed
  local accepted
  local failed
  local tps

  summary="$(run_pgbench)"
  processed="$(summary_figure "${summary}" 'number of transactions actually processed: ')"
  failed="$(summary_figure "${summary}" 'number of failed transactions: ')"
  tps="$(summary_figure "${summary}" 'tps = ')"
  story::narrate "${label}: ${processed} transactions, ${tps} per second"
  story::narrate "${label}: latency average $(summary_figure "${summary}" 'latency average = ') ms"
  story::expect_equal "${label}: no transaction failed" "${failed}" 0
  check_invariants "${label}"
  accepted="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_PAYMENTS}")"
  story::narrate "${label}: ${accepted} payments accepted"
  story::narrate "${label}: $(( processed - accepted )) duplicates rejected"
  (( processed > accepted )) || die 1 'FAIL: no duplicate key collided, so nothing was tested'
}

# Check the standby holds exactly the payments and balances the writer holds.
# Usage: check_standby_identical LABEL
check_standby_identical() {
  log INFO 'comparing the standby with the writer'
  local label="${1:?label required}"
  local position
  local expected
  local actual

  position="$(database::bare "${PRIMARY_CONTAINER}" <<< 'select pg_current_wal_lsn()')"
  database::wait_for_replay "${STANDBY_CONTAINER}" "${position}"
  expected="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_SUMMARY}")"
  actual="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_SUMMARY}")"
  story::expect_equal "${label}: the standby holds the same payments" "${actual}" "${expected}"
  expected="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_BALANCES}")"
  actual="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_BALANCES}")"
  story::expect_equal "${label}: the standby holds the same balances" "${actual}" "${expected}"
}

# Steps 2-3: the load under asynchronous replication, then the standby comparison.
async_load() {
  begin_step 2 "asynchronous replication: ${LOAD_CLIENTS} clients for ${LOAD_SECONDS} s"
  run_load async
  begin_step 3 'the standby catches up and holds the same data'
  check_standby_identical async
}

# Step 4: the same load under synchronous replication; the cost shows in the throughput.
sync_load() {
  begin_step 4 'synchronous replication: the same load, the same checks'
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_RESET}"
  run_load sync
  check_standby_identical sync
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
}

# Step 5: kill the writer in the middle of a run and restart it; every transaction is atomic.
crash_during_load() {
  local pid

  begin_step 5 "the writer is killed ${CRASH_AFTER_SECONDS} s into a run and restarted"
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_RESET}"
  run_pgbench > /dev/null 2>&1 &
  pid=$!
  sleep "${CRASH_AFTER_SECONDS}"
  fault::crash_and_restart "${PRIMARY_CONTAINER}" 2
  wait "${pid}" || story::narrate 'the clients lost their connection, as expected'
  check_invariants 'after the crash'
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_CHECK_PAYMENTS}"
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_CHECK_ACCOUNTS}"
}

# Step 6: say what the run demonstrated.
narrate_conclusion() {
  begin_step 6 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  Clients colliding on a few keys: each key took effect once; money conserved.'
  story::narrate '  The standby ended identical to the writer in both replication modes.'
  story::narrate '  A writer killed mid-run recovered with every transaction whole, indexes intact.'
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: concurrent load on ${PRIMARY_CONTAINER} and ${STANDBY_CONTAINER}"
  prepare_tables
  async_load
  sync_load
  crash_during_load
  check_standby_identical 'after the crash'
  narrate_conclusion
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up; then restore.
run_and_restore() {
  log INFO 'running the experiment, then restoring the starting state'
  local outcome='passed'
  local pid

  run_experiment &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: asynchronous mode, restore the starting state, drop the tables =='
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" 'drop table if exists payments, accounts'
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
  check_environment
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
