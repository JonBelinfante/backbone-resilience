#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test a second failure during a rejoin: the new writer dies while the old node is rebuilt.
# Usage: test-rejoin-failure.sh [--control] [-h | --help]
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

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly TOTAL_STEPS=4
readonly MARKER_WAIT_TRIES=300
readonly SQL_CREATE='create table if not exists rejoin_probe (id bigserial primary key)'
readonly SQL_DROP='drop table if exists rejoin_probe'
readonly SQL_INSERT_FIVE='insert into rejoin_probe select from generate_series(1, 5)'
readonly SQL_INSERT_THREE='insert into rejoin_probe select from generate_series(1, 3)'
readonly SQL_COUNT='select count(*) from rejoin_probe'
readonly SQL_SUM='select md5(coalesce(string_agg(id::text, $$,$$ order by id), $$$$))
  from rejoin_probe'

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
Usage: test-rejoin-failure.sh [--control] [-h | --help]

The writer crashes, the standby is promoted and takes writes, and the old primary is rejoined as a
standby. While its data directory is being rebuilt (the rebuild-pending marker exists), the new
writer is killed. Steps:
  1. the starting data is written and replicated; the writer crashes; the standby is promoted and
     takes more rows;
  2. the rejoin is started; once its marker appears, the new writer is killed (SIGKILL);
  3. the marker is still there (the rebuild was interrupted), and the restore brings the stack back
     to writer and replica, with every row written before the kill on both nodes, identical;
  4. what this showed.
With --control there is no kill: the rejoin completes, the marker is removed, and the restore has
nothing to repair. The control shows the marker is what the kill left behind.
It stops at the first FAIL, then restores the starting state. Throwaway stack only.

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

# Print how many rows the probe table holds on a node.
# Usage: rows_on NODE
rows_on() {
  local node="${1:?node required}"

  database::bare "${node}" <<< "${SQL_COUNT}"
}

# Print the checksum of the probe table's rows on a node.
# Usage: checksum_on NODE
checksum_on() {
  local node="${1:?node required}"

  database::bare "${node}" <<< "${SQL_SUM}"
}

# Step 1: rows replicated, writer crashed, standby promoted, more rows on the new writer.
# Usage: step_failover_and_write
step_failover_and_write() {
  local count

  begin_step 1 'the writer crashes after replicated rows; the standby is promoted and takes more'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_DROP}; ${SQL_CREATE}" > /dev/null
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_INSERT_FIVE}" > /dev/null
  sleep 2
  count="$(rows_on "${STANDBY_CONTAINER}")"
  story::expect_equal 'the standby holds the 5 replicated rows' "${count}" 5
  fault::crash_node "${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}promote-standby-to-primary.sh"
  database::run "${STANDBY_CONTAINER}" <<< "${SQL_INSERT_THREE}" > /dev/null
  count="$(rows_on "${STANDBY_CONTAINER}")"
  story::expect_equal 'the new writer holds 8 rows' "${count}" 8
}

# Wait until the rebuild marker exists, so a kill lands while the data directory is being changed.
# Usage: wait_for_marker SCRATCH_DIR
wait_for_marker() {
  local marker="${1:?scratch folder required}/rebuild-pending-${PRIMARY_CONTAINER}"
  local tries=0

  while [[ ! -e "${marker}" ]] && (( tries < MARKER_WAIT_TRIES )); do
    sleep 0.1
    tries=$(( tries + 1 ))
  done
  [[ -e "${marker}" ]]
}

# Print yes if the rebuild marker is in the folder, no otherwise.
# Usage: marker_state SCRATCH_DIR
marker_state() {
  local scratch="${1:?scratch folder required}"

  if [[ -e "${scratch}/rebuild-pending-${PRIMARY_CONTAINER}" ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# Step 2: the rejoin is killed by the death of the new writer, while the marker exists.
# Usage: step_rejoin_killed SCRATCH_DIR CONTROL
step_rejoin_killed() {
  local scratch="${1:?scratch folder required}"
  local control="${2:?control setting required}"
  local -a rejoin=(env "REBUILD_MARKER_DIR=${scratch}")
  local pid
  local marker_seen
  local marker_left

  begin_step 2 'the new writer is killed while the old node is being rebuilt'
  rejoin+=(bash "${SCRIPT_DIR}promote-primary-to-standby.sh")
  "${rejoin[@]}" > /dev/null 2>&1 &
  pid=$!
  if wait_for_marker "${scratch}"; then
    marker_seen=yes
  else
    marker_seen=no
  fi
  story::expect_equal 'the rebuild started (marker seen)' "${marker_seen}" yes
  if [[ "${control}" == yes ]]; then
    wait "${pid}" || die 1 'FAIL: the control rejoin failed'
  else
    fault::crash_node "${STANDBY_CONTAINER}"
    if ! wait "${pid}"; then
      log INFO 'the rejoin ended with an error, as the kill intended'
    fi
  fi
  marker_left="$(marker_state "${scratch}")"
  if [[ "${control}" == yes ]]; then
    story::expect_equal 'the rejoin completed: no marker left' "${marker_left}" no
  else
    story::expect_equal 'the rebuild was interrupted: marker still there' "${marker_left}" yes
  fi
}

# Step 3: the restore brings the stack back, and every row written before the kill is on both nodes.
# Usage: step_recover
step_recover() {
  local count
  local writer_state
  local replica_state
  local sum_writer
  local sum_replica

  begin_step 3 'restore: writer and replica again, the same rows on both'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  writer_state="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  replica_state="$(database::in_recovery "${STANDBY_CONTAINER}")"
  story::expect_equal "${PRIMARY_CONTAINER} is the writer" "${writer_state}" f
  story::expect_equal "${STANDBY_CONTAINER} is the replica" "${replica_state}" t
  count="$(rows_on "${PRIMARY_CONTAINER}")"
  story::expect_equal 'the writer holds the 8 acknowledged rows' "${count}" 8
  sum_writer="$(checksum_on "${PRIMARY_CONTAINER}")"
  sum_replica="$(checksum_on "${STANDBY_CONTAINER}")"
  story::expect_equal 'the replica holds identical rows' "${sum_replica}" "${sum_writer}"
}

# Step 4: say what the run demonstrated.
step_conclusion() {
  begin_step 4 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  a rebuild killed part way leaves its marker behind; the restore repairs the'
  story::narrate '  roles from whatever state the kill left, and no acknowledged row is lost.'
}

# Run the steps in order; the first failure stops the run.
# Usage: run_experiment SCRATCH_DIR CONTROL
run_experiment() {
  local scratch="${1:?scratch folder required}"
  local control="${2:?control setting required}"

  story::narrate "story: a second failure during a rejoin, control=${control}"
  step_failover_and_write
  step_rejoin_killed "${scratch}" "${control}"
  step_recover
  step_conclusion
}

# Run the steps in a child shell, so a failure cannot skip the clean-up; then restore.
# Usage: run_and_restore SCRATCH_DIR CONTROL
run_and_restore() {
  local scratch="${1:?scratch folder required}"
  local control="${2:?control setting required}"
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment "${scratch}" "${control}" &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: remove the marker, restore the starting state =='
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_DROP}"
  [[ "${outcome}" == 'passed' ]] || die 1 'the experiment failed (the state was restored)'
}

# Script entry point.
main() {
  local control=no
  local scratch
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --control)
        control=yes
        shift
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
  scratch="$(mktemp -d "${TEMP_DIR}/rejoin.XXXXXX")"
  CLEANUP_PATHS+=("${scratch}")
  run_and_restore "${scratch}" "${control}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
