#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test that secrets rotate with no failed write, and that the new secrets really work.
# Usage: test-rotation.sh [-h | --help]
# Requires: cat mktemp sleep
# Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them. UP_PULL_POLICY is passed to docker compose up --pull. TEMP_DIR holds the probe's
# files until the run ends (default: temporary directory). ROTATION_MODE is async (default) or
# sync: in sync the standby must stay a synchronous standby and no write may stall.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly UP_PULL_POLICY="${UP_PULL_POLICY:-missing}"
readonly ROTATION_MODE="${ROTATION_MODE:-async}"
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly COMPOSE_FILE="${SCRIPT_DIR}../docker-compose.yml"
readonly SECRETS_PATH="${SCRIPT_DIR}../secrets"
readonly USER_FILE_PATH="${SECRETS_PATH}/pg-replication-user.txt"
readonly KEY_FILE_PATH="${SECRETS_PATH}/pg-password.txt"
readonly TOTAL_STEPS=7
readonly TEST_TABLE='rotation_probe'
readonly SQL_PROBE_INSERT="insert into ${TEST_TABLE} default values"
readonly SQL_ROW_COUNT="select count(*) from ${TEST_TABLE}"
readonly SQL_STREAMING_ROLE="select usename from pg_stat_replication where state = 'streaming'"
readonly SQL_SYNC_STATE="select sync_state from pg_stat_replication where state = 'streaming'"
readonly STALL_LIMIT_MS=2000
readonly SQL_WAL_POSITION='select pg_current_wal_lsn()'
readonly SQL_ROLE_COUNT='select count(*) from pg_roles where rolreplication and not rolsuper'
readonly PROBE_PAUSE_SECONDS=0.1
readonly SETTLE_SECONDS=2

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/story.sh
source "${SCRIPT_DIR}../lib/story.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/access.sh
source "${SCRIPT_DIR}../lib/access.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-rotation.sh [-h | --help]

Rotate the database secrets while a probe writes to the primary about ten times a second:
the replication secret (by overlap), the superuser secret (in place), the replication secret
again (the role name alternates). It requires:
  - no failed write and every written row on both nodes,
  - after each rotation the standby streams as the role named in pg-replication-user.txt,
  - the old role is gone, and the superuser file's password works over the network,
  - a standby rebuilt from an empty volume authenticates with the new secret files.
It stops at the first FAIL; pass or fail it then restores the stack and drops its table.
The secrets stay rotated afterwards (the replication role keeps the new name).
The test changes the databases and the secret files: use it only on the throwaway stack.

Environment: PRIMARY_CONTAINER, STANDBY_CONTAINER, UP_PULL_POLICY, TEMP_DIR, RUN_LOG_DIR.
ROTATION_MODE=sync runs it under synchronous replication: the standby must stay synchronous
and no write may take 2 s or more.

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

# Insert a row on the primary about every 100 ms while the flag file says go; keep the counts
# (inserted and failed) in a file. Runs in the background.
# Usage: probe_writes FLAG_FILE COUNTS_FILE
probe_writes() {
  log INFO 'probing: writing continuously'
  local flag_file="${1:?flag file required}"
  local counts_file="${2:?counts file required}"
  local inserted=0
  local failed=0
  local slowest=0
  local started
  local took

  while [[ "$(< "${flag_file}")" == 'go' ]]; do
    started="${EPOCHREALTIME//[.,]/}"
    if database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_PROBE_INSERT}" > /dev/null 2>&1; then
      inserted=$(( inserted + 1 ))
    else
      failed=$(( failed + 1 ))
    fi
    took=$(( (${EPOCHREALTIME//[.,]/} - started) / 1000 ))
    (( took <= slowest )) || slowest="${took}"
    printf '%s %s %s\n' "${inserted}" "${failed}" "${slowest}" > "${counts_file}"
    sleep "${PROBE_PAUSE_SECONDS}"
  done
}

# Check the standby streams as the role the secret file names.
check_identity() {
  log INFO 'checking the standby streams as the role in the secret file'
  local role
  local seen

  role="$(< "${USER_FILE_PATH}")"
  seen="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_STREAMING_ROLE}")"
  story::expect_equal "the standby streams as ${role} (from the file)" "${seen}" "${role}"
  if [[ "${ROTATION_MODE}" == 'sync' ]]; then
    seen="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_SYNC_STATE}")"
    story::expect_equal 'the standby is still a synchronous standby' "${seen}" 'sync'
  fi
}

# Step 1: start from the restored stack and create the probe's table.
prepare_table() {
  begin_step 1 'restore the starting state and create the probe table'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode "${ROTATION_MODE}"
  story::run_statement "${PRIMARY_CONTAINER}" "drop table if exists ${TEST_TABLE}"
  story::run_statement "${PRIMARY_CONTAINER}" \
    "create table ${TEST_TABLE} (id bigserial primary key, written timestamptz default now())"
}

# Steps 2-4: rotate replication, superuser, replication, checking after each.
rotate_three_times() {
  local first
  local second

  begin_step 2 'rotate the replication secret (overlap) while writes continue'
  story::run_logged bash "${SCRIPT_DIR}rotate-secret.sh"
  check_identity
  first="$(< "${USER_FILE_PATH}")"
  begin_step 3 'rotate the superuser secret (in place) while writes continue'
  story::run_logged bash "${SCRIPT_DIR}rotate-secret.sh" --secret superuser
  if access::probe_login "${STANDBY_CONTAINER}" "${PRIMARY_CONTAINER}" postgres \
    "${KEY_FILE_PATH}"; then
    story::narrate 'PASS: the superuser file password logs in over the network'
  else
    die 1 'FAIL: the superuser file password does not log in over the network'
  fi
  begin_step 4 'rotate the replication secret again: the role name alternates'
  story::run_logged bash "${SCRIPT_DIR}rotate-secret.sh"
  check_identity
  second="$(< "${USER_FILE_PATH}")"
  [[ "${first}" != "${second}" ]] || die 1 "FAIL: the role did not change (${first})"
  story::narrate "PASS: the role went from ${first} to ${second}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_ROLE_COUNT}" 1
}

# Step 5: the probe has stopped; no write may have failed; every row is on both nodes.
# Usage: check_no_write_failed COUNTS_FILE
check_no_write_failed() {
  local counts_file="${1:?counts file required}"
  local inserted
  local failed
  local slowest
  local position

  begin_step 5 'the probe has stopped: no write failed, and every row is on both nodes'
  read -r inserted failed slowest < "${counts_file}"
  story::narrate "the probe wrote ${inserted} rows, ${failed} writes failed, slowest ${slowest} ms"
  (( inserted > 0 )) || die 1 'FAIL: the probe never wrote'
  story::expect_equal 'no write failed during three rotations' "${failed}" 0
  (( slowest < STALL_LIMIT_MS )) || die 1 "FAIL: a write took ${slowest} ms"
  story::narrate "PASS: no write stalled: the slowest took ${slowest} ms in ${ROTATION_MODE} mode"
  position="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_WAL_POSITION}")"
  database::wait_for_replay "${STANDBY_CONTAINER}" "${position}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_ROW_COUNT}" "${inserted}"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_ROW_COUNT}" "${inserted}"
}

# Step 6: lose the standby's disk; a new standby must bootstrap with the rotated secret files.
rebuild_standby_from_nothing() {
  begin_step 6 'the standby loses its disk and is rebuilt from nothing with the new secrets'
  container::remove_with_volume "${STANDBY_CONTAINER}"
  story::run_logged container::compose_up "${COMPOSE_FILE}" "${UP_PULL_POLICY}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  check_identity > /dev/null
  story::expect_query "${STANDBY_CONTAINER}" 'show synchronous_standby_names' ''
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_ROW_COUNT}" \
    "$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_ROW_COUNT}")"
}

# Step 7: say what the run demonstrated.
narrate_conclusion() {
  begin_step 7 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  Three rotations ran under continuous writes and no write failed.'
  story::narrate '  The standby always streamed as the role the secret file names.'
  story::narrate '  A standby built from an empty volume used the rotated secrets to join.'
}

# Run all the steps in order; the first failure stops the run. The probe writes in the background
# during the three rotations and is stopped before its counts are read.
# Usage: run_experiment FLAG_FILE COUNTS_FILE
run_experiment() {
  local flag_file="${1:?flag file required}"
  local counts_file="${2:?counts file required}"
  local probe_pid

  story::narrate "story: secret rotation on ${PRIMARY_CONTAINER} and ${STANDBY_CONTAINER}"
  prepare_table
  printf 'go' > "${flag_file}"
  printf '0 0\n' > "${counts_file}"
  probe_writes "${flag_file}" "${counts_file}" &
  probe_pid=$!
  story::narrate "the probe is writing; waiting ${SETTLE_SECONDS} seconds"
  sleep "${SETTLE_SECONDS}"
  rotate_three_times
  printf 'stop' > "${flag_file}"
  wait "${probe_pid}" || die 1 'the probe ended with an error'
  check_no_write_failed "${counts_file}"
  rebuild_standby_from_nothing
  narrate_conclusion
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up; then stop the probe,
# restore the starting state and drop the test table.
run_and_restore() {
  log INFO 'running the experiment, then restoring the starting state'
  local outcome='passed'
  local flag_file
  local counts_file
  local pid

  flag_file="$(mktemp "${TEMP_DIR}/${SCRIPT_NAME}-flag.XXXXXX")"
  CLEANUP_PATHS+=("${flag_file}")
  counts_file="$(mktemp "${TEMP_DIR}/${SCRIPT_NAME}-counts.XXXXXX")"
  CLEANUP_PATHS+=("${counts_file}")
  run_experiment "${flag_file}" "${counts_file}" &
  pid=$!
  if ! wait "${pid}"; then
    outcome='failed'
  fi
  printf 'stop' > "${flag_file}"
  story::narrate '== Cleanup: restore the starting state, in asynchronous mode =='
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
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
  require_commands cat mktemp sleep
  [[ "${ROTATION_MODE}" == 'async' || "${ROTATION_MODE}" == 'sync' ]] ||
    die 2 'ROTATION_MODE is async or sync'
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
