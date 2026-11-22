#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test fencing: after a failover, the old primary cannot accept writes when it is started.
# Usage: test-fencing.sh [-h | --help]
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
readonly TOTAL_STEPS=6
readonly SETTLE_SECONDS=4
readonly TEST_TABLE='fencing_test'
readonly READY_ATTEMPTS=30
readonly SQL_ROLE='select pg_is_in_recovery()'
readonly SQL_WRITE="insert into ${TEST_TABLE}(note) values ('written by the old primary')"

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
# shellcheck source=../lib/fence.sh
source "${SCRIPT_DIR}../lib/fence.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-fencing.sh [-h | --help]

Prove that a failed-over primary cannot come back as a second writer (split-brain):
  1. the primary crashes and the standby is promoted;
  2. the old primary is started directly with docker start, not through the scripts;
  3. it must come up read-only and refuse a write (the fence);
  4. control: with the fence lifted, the same start accepts a write, so the test can detect
     split-brain (two writers) when fencing is absent;
  5. the fence is applied again and the old primary refuses writes once more;
  6. the stack is restored: the old primary rejoins as a standby.
It stops at the first FAIL. Pass or fail, it then restores the starting state and drops its table.
The test crashes the writer: use it only on the throwaway stack.

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

# Wait until a node that was just started accepts connections.
# Usage: wait_ready CONTAINER
wait_ready() {
  local container="${1:?container required}"
  local attempt=1

  while (( attempt <= READY_ATTEMPTS )); do
    if database::is_ready "${container}"; then
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep 1
  done
  die 1 "${container} did not accept connections after ${READY_ATTEMPTS} seconds"
}

# Try a write on a node; print accepted, or refused (a read-only server refuses it).
# Usage: write_outcome CONTAINER
write_outcome() {
  local container="${1:?container required}"

  if database::run "${container}" <<< "${SQL_WRITE}" > /dev/null 2>&1; then
    printf 'accepted\n'
  else
    printf 'refused\n'
  fi
}

# Step 1: crash the primary and promote the standby the normal way.
fail_over() {
  begin_step 1 'the primary crashes and the standby is promoted'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "drop table if exists ${TEST_TABLE}"
  story::run_statement "${PRIMARY_CONTAINER}" \
    "create table ${TEST_TABLE} (id serial primary key, note text not null)"
  fault::crash_node "${PRIMARY_CONTAINER}"
  story::run_logged bash "${SCRIPT_DIR}promote-standby-to-primary.sh"
  story::expect_query "${STANDBY_CONTAINER}" "${SQL_ROLE}" 'f'
}

# Step 2: start the old primary directly and try to write; the fence must refuse.
start_old_primary_directly() {
  local outcome

  begin_step 2 'the old primary is started directly (docker start) and must refuse a write'
  story::narrate "fence marker on ${PRIMARY_CONTAINER}: $(fence::is_applied "${PRIMARY_CONTAINER}")"
  container::start "${PRIMARY_CONTAINER}"
  wait_ready "${PRIMARY_CONTAINER}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_ROLE}" 't'
  story::narrate "SQL on ${PRIMARY_CONTAINER}: ${SQL_WRITE}"
  outcome="$(write_outcome "${PRIMARY_CONTAINER}")"
  story::expect_equal 'the fenced old primary refuses the write' "${outcome}" 'refused'
}

# Step 3: control. Without the fence the same start accepts a write: two writers.
control_without_fence() {
  local outcome

  begin_step 3 'control: with the fence lifted, the old primary accepts a write (split-brain)'
  container::stop "${PRIMARY_CONTAINER}"
  fence::lift "${PRIMARY_CONTAINER}"
  container::start "${PRIMARY_CONTAINER}"
  wait_ready "${PRIMARY_CONTAINER}"
  story::expect_query "${PRIMARY_CONTAINER}" "${SQL_ROLE}" 'f'
  story::narrate "SQL on ${PRIMARY_CONTAINER}: ${SQL_WRITE}"
  outcome="$(write_outcome "${PRIMARY_CONTAINER}")"
  story::expect_equal 'without the fence the old primary accepts the write' "${outcome}" 'accepted'
}

# Step 4: fence again, and show that the refusal returns.
fence_again() {
  local outcome

  begin_step 4 'fence again: the diverged old primary still takes no write'
  container::stop "${PRIMARY_CONTAINER}"
  fence::apply "${PRIMARY_CONTAINER}"
  container::start "${PRIMARY_CONTAINER}"
  story::narrate "waiting ${SETTLE_SECONDS} seconds: a diverged node may refuse to start"
  sleep "${SETTLE_SECONDS}"
  story::narrate "SQL on ${PRIMARY_CONTAINER}: ${SQL_WRITE}"
  outcome="$(write_outcome "${PRIMARY_CONTAINER}")"
  story::expect_equal 'the re-fenced old primary refuses the write' "${outcome}" 'refused'
  story::narrate 'stopping it: a fenced node must be rebuilt (rewound) before it can rejoin'
  container::stop "${PRIMARY_CONTAINER}"
}

# Step 5: the rogue write never reached the real writer.
check_new_writer() {
  begin_step 5 'the new writer holds none of the old primary writes'
  story::expect_query "${STANDBY_CONTAINER}" "select count(*) from ${TEST_TABLE}" '0'
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: fencing the old primary ${PRIMARY_CONTAINER}"
  fail_over
  start_old_primary_directly
  control_without_fence
  fence_again
  check_new_writer
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
run_and_restore() {
  log INFO 'running the experiment, then restoring the starting state'
  local outcome='passed'
  local pid

  run_experiment &
  pid=$!
  wait "${pid}" || outcome='failed'
  begin_step 6 'restore the starting state: the old primary rejoins as a standby'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "drop table if exists ${TEST_TABLE}"
  [[ "${outcome}" == 'passed' ]] || die 1 'the experiment failed (the state was restored)'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed: the old primary cannot return as a writer"
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
