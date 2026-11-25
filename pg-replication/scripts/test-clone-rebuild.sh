#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test the clone rebuild path: a node cloned from the writer carries no sync setting.
# Usage: test-clone-rebuild.sh [-h | --help]
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
readonly FIRST_ROWS=20
readonly AFTER_ROWS=5
readonly SQL_CREATE='create table if not exists clone_probe (id bigserial primary key)'
readonly SQL_DROP='drop table if exists clone_probe'
readonly SQL_INSERT='insert into clone_probe select from generate_series(1, '
readonly SQL_COUNT='select count(*) from clone_probe'
readonly SQL_SUM="select md5(coalesce(string_agg(id::text, ',' order by id), ''))
  from clone_probe"
readonly SQL_SYNC_NAMES='show synchronous_standby_names'

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
Usage: test-clone-rebuild.sh [-h | --help]

Rebuild the old primary as a standby by cloning the whole data directory from the new writer
(promote-primary-to-standby.sh --clone), while synchronous replication was on before the failover:
  1. synchronous replication is on, rows are written and replicated;
  2. the writer crashes and the standby is promoted, and takes more rows;
  3. the clone rebuild runs: the old node streams as a standby, holds every row with the same
     checksum, and carries no synchronous_standby_names (a standby must not name a standby);
  4. what this showed.
It stops at the first FAIL, then restores the starting state (asynchronous). Throwaway stack only.

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

# Step 1: synchronous replication on, rows written and replicated.
step_sync_rows() {
  local count

  begin_step 1 'synchronous replication is on; rows are written and replicated'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_DROP}; ${SQL_CREATE}" > /dev/null
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_INSERT}${FIRST_ROWS});" > /dev/null
  count="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_COUNT}")"
  story::expect_equal 'the standby holds the rows' "${count}" "${FIRST_ROWS}"
}

# Step 2: the writer crashes; the standby is promoted and takes more rows.
step_failover() {
  local count
  local names
  local -a switch

  begin_step 2 'the writer crashes; the standby is promoted and takes more rows'
  fault::crash_node "${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}promote-standby-to-primary.sh"
  database::run "${STANDBY_CONTAINER}" <<< "${SQL_INSERT}${AFTER_ROWS});" > /dev/null
  count="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_COUNT}")"
  story::expect_equal 'the new writer holds every row' "${count}" $(( FIRST_ROWS + AFTER_ROWS ))
  # The new writer names a synchronous standby, so the copy it gives the rebuild carries it.
  # The insert above ran first: a commit would wait for the standby that is down.
  switch=(env "PRIMARY_CONTAINER=${STANDBY_CONTAINER}")
  switch+=(bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync)
  story::run_logged "${switch[@]}"
  names="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_SYNC_NAMES}")"
  story::expect_equal 'the copy source names a synchronous standby' "${names}" 'FIRST 1 (standby1)'
}

# Step 3: the clone rebuild; the rebuilt node streams, has the same rows, and no sync setting.
step_clone_rebuild() {
  local sync_names
  local checksum_writer
  local checksum_rebuilt
  local recovery

  begin_step 3 'the old node is rebuilt by cloning the writer; it streams with no sync setting'
  story::run_logged bash "${SCRIPT_DIR}promote-primary-to-standby.sh" --clone
  database::wait_for_streaming "${STANDBY_CONTAINER}"
  recovery="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} is a replica" "${recovery}" t
  sync_names="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_SYNC_NAMES}")"
  story::expect_equal 'the rebuilt node names no synchronous standby' "${sync_names}" ''
  checksum_writer="$(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_SUM}")"
  database::wait_for_replay "${PRIMARY_CONTAINER}" \
    "$(database::bare "${STANDBY_CONTAINER}" <<< 'select pg_current_wal_lsn()')"
  checksum_rebuilt="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_SUM}")"
  story::expect_equal 'the rebuilt node holds identical rows' \
    "${checksum_rebuilt}" \
    "${checksum_writer}"
}

# Step 4: say what the run demonstrated.
step_conclusion() {
  begin_step 4 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  a node rebuilt from a copy of a writer that had synchronous replication on'
  story::narrate '  carries no synchronous setting, so it can be promoted without blocking writes.'
}

# Run the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate 'story: a clone rebuild after a failover from synchronous replication'
  step_sync_rows
  step_failover
  step_clone_rebuild
  step_conclusion
}

# Run the steps in a child shell, so a failure cannot skip the clean-up; then restore asynchronous.
run_and_restore() {
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: restore the starting state (asynchronous) =='
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_DROP}"
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
