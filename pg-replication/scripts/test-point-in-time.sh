#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test point-in-time recovery: a mistaken delete replicates, and a backup recovers it.
# Usage: test-point-in-time.sh [-h | --help]
# Requires: cat mktemp sleep
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
readonly RESTORE_CONTAINER="${RESTORE_CONTAINER:-pg-point-in-time}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly TOTAL_STEPS=5
readonly FIRST_ROWS=100
readonly AFTER_ROWS=50
readonly SQL_CREATE='create table pitr_probe (id bigserial primary key, note text)'
readonly SQL_DROP='drop table if exists pitr_probe'
readonly SQL_FILL='insert into pitr_probe (note) select x::text from generate_series(1, '
readonly SQL_COUNT='select count(*) from pitr_probe'
readonly SQL_SUM="select md5(coalesce(string_agg(id::text, ',' order by id), ''))
  from pitr_probe"
readonly SQL_LSN='select pg_current_wal_lsn()'
readonly SQL_DELETE='delete from pitr_probe'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/story.sh
source "${SCRIPT_DIR}../lib/story.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/backup.sh
source "${SCRIPT_DIR}../lib/backup.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-point-in-time.sh [-h | --help]

Test recovery from a mistake that replication copies:
  1. 100 rows are written and archived; a base backup of the primary is taken; 50 more rows are
     written, and the WAL up to the last of them is archived. The rows and their checksum are
     recorded, with the WAL position (LSN) of the last row;
  2. a mistaken delete of every row runs on the primary; the standby loses the rows too, within
     seconds, so replication alone cannot recover them;
  3. the base backup and the archive are restored to the recorded LSN, before the delete: the copy
     holds the 150 rows and the same checksum, and it is promoted at that point;
  4. control: the same restore with no target (recovery to the end of the archive) reproduces the
     delete, so the test can see the difference;
  5. cleanup removes the copy, drops the test table and restores the starting state.
Throwaway stack only: the primary's archive and backup volumes are created and filled by this test.

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

# Print the number of rows in the test table on a node.
# Usage: rows_on NODE
rows_on() {
  local node="${1:?node required}"

  database::bare "${node}" <<< "${SQL_COUNT}"
}

# Print the checksum of the rows in the test table on a node.
# Usage: checksum_on NODE
checksum_on() {
  local node="${1:?node required}"

  database::bare "${node}" <<< "${SQL_SUM}"
}

# Wait until the WAL that was written before now is archived.
# Usage: archive_now
archive_now() {
  local archived

  archived="$(backup::archived_count "${PRIMARY_CONTAINER}")"
  backup::wait_archived "${PRIMARY_CONTAINER}" "$(( archived + 1 ))"
}

# Step 1: rows, a base backup, more rows; the WAL is archived and the position recorded.
# Usage: step_backup SCRATCH_DIR
step_backup() {
  local scratch="${1:?scratch folder required}"
  local count
  local lsn
  local sum

  begin_step 1 'rows, a base backup, more rows: the WAL is archived and the position recorded'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  backup::prepare "$(container::image "${PRIMARY_CONTAINER}")"
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_DROP}; ${SQL_CREATE}" > /dev/null
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_FILL}${FIRST_ROWS}) as x;" > /dev/null
  archive_now
  backup::take_base "${PRIMARY_CONTAINER}"
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_FILL}${AFTER_ROWS}) as x;" > /dev/null
  lsn="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_LSN}")"
  archive_now
  count="$(rows_on "${PRIMARY_CONTAINER}")"
  sum="$(checksum_on "${PRIMARY_CONTAINER}")"
  story::expect_equal 'the writer holds the 150 rows' "${count}" $(( FIRST_ROWS + AFTER_ROWS ))
  printf '%s\n' "${lsn}" > "${scratch}/lsn"
  printf '%s\n' "${sum}" > "${scratch}/sum"
  story::narrate "recorded position ${lsn}, checksum ${sum}"
}

# Step 2: the mistake (every row deleted) replicates, and the standby cannot undo it.
# Usage: step_mistake
step_mistake() {
  local primary_rows
  local standby_rows

  begin_step 2 'a mistaken delete replicates to the standby within seconds'
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_DELETE}" > /dev/null
  sleep 2
  primary_rows="$(rows_on "${PRIMARY_CONTAINER}")"
  standby_rows="$(rows_on "${STANDBY_CONTAINER}")"
  story::expect_equal 'the writer lost its rows' "${primary_rows}" 0
  story::expect_equal 'the standby lost them too' "${standby_rows}" 0
  archive_now
}

# Check a restored copy: promoted, the test rows, the same checksum as before the delete, and the
# restore used the archive.
# Usage: check_copy EXPECTED_ROWS SCRATCH_DIR
check_copy() {
  local expected_rows="${1:?expected rows required}"
  local scratch="${2:?scratch folder required}"
  local rows
  local sum
  local from_archive
  local expected

  rows="$(rows_on "${RESTORE_CONTAINER}")"
  story::expect_equal "the copy holds ${expected_rows} rows" "${rows}" "${expected_rows}"
  sum="$(checksum_on "${RESTORE_CONTAINER}")"
  if [[ "${expected_rows}" == "$(( FIRST_ROWS + AFTER_ROWS ))" ]]; then
    expected="$(< "${scratch}/sum")"
    story::expect_equal 'the checksum is the one recorded before the delete' "${sum}" "${expected}"
  fi
  from_archive="$(backup::archive_reads)"
  story::expect_between 'the copy read WAL from the archive' "${from_archive}" 1 100000
}

# Step 3: the copy at the recorded position is the data before the mistake.
# Usage: step_restore_before SCRATCH_DIR
step_restore_before() {
  local scratch="${1:?scratch folder required}"
  local lsn

  begin_step 3 'restore to the recorded position: the rows and checksum from before the delete'
  lsn="$(< "${scratch}/lsn")"
  backup::restore_to "$(container::image "${PRIMARY_CONTAINER}")" "${lsn}"
  backup::wait_promoted
  check_copy $(( FIRST_ROWS + AFTER_ROWS )) "${scratch}"
}

# Step 4: control: with no target the same copy reproduces the delete.
step_control_to_end() {
  local scratch="${1:?scratch folder required}"

  begin_step 4 'control: recovery to the end of the archive reproduces the delete'
  backup::restore_to "$(container::image "${PRIMARY_CONTAINER}")"
  backup::wait_promoted
  check_copy 0 "${scratch}"
}

# Step 5: say what the run demonstrated.
step_conclusion() {
  begin_step 5 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  replication copies a mistake within seconds; a base backup and the archived WAL'
  story::narrate '  recover the data to a recorded position before it; recovery to the end of the'
  story::narrate '  archive reproduces the mistake, so the position is what makes the difference.'
}

# Run the steps in order; the first failure stops the run.
# Usage: run_experiment SCRATCH_DIR
run_experiment() {
  local scratch="${1:?scratch folder required}"

  story::narrate "story: point-in-time recovery of ${PRIMARY_CONTAINER}"
  step_backup "${scratch}"
  step_mistake
  step_restore_before "${scratch}"
  step_control_to_end "${scratch}"
  step_conclusion
}

# Run the steps in a child shell, so a failure cannot skip the clean-up; then restore.
# Usage: run_and_restore SCRATCH_DIR
run_and_restore() {
  local scratch="${1:?scratch folder required}"
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment "${scratch}" &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: remove the copy, drop the test table, restore the starting state =='
  backup::remove_restore
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_DROP}"
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
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
  require_commands cat mktemp sleep
  scratch="$(mktemp -d "${TEMP_DIR}/pitr.XXXXXX")"
  CLEANUP_PATHS+=("${scratch}")
  run_and_restore "${scratch}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
