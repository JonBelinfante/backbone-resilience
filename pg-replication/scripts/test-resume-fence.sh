#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test that a check in the write refuses a paused writer resuming with an expired lease.
# Usage: test-resume-fence.sh [-h | --help]
# Requires: cat mktemp sleep
# Exit codes: 0 every step passed, 1 a step failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them. The client runs in the standby's container, as a client on the network.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly TOTAL_STEPS=3
readonly LEASE_TTL=5
readonly PAUSE_SECONDS=8
readonly SQL_TABLE='create table if not exists fence_probe (id serial primary key, late_ms int)'
readonly SQL_WRITE='insert into fence_probe (late_ms)
  select coalesce(round(extract(epoch from clock_timestamp() - expires_at) * 1000)::int, -1)
  from fence_lease where id = 1 returning late_ms'
readonly SQL_COUNT='select count(*) from fence_probe'
readonly SQL_PLAIN_WRITE='insert into fence_probe (late_ms) values (0)'

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
# shellcheck source=../lib/access.sh
source "${SCRIPT_DIR}../lib/access.sh"
# shellcheck source=../lib/controller.sh
source "${SCRIPT_DIR}../lib/controller.sh"
# shellcheck source=../lib/lease.sh
source "${SCRIPT_DIR}../lib/lease.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-resume-fence.sh [-h | --help]

A writer is paused (docker pause) for longer than its lease, with a client write waiting to reach
it; the client's write is executed the moment the writer resumes, before any guard can look.
  1. control, no check: the write is accepted although the lease ran out seconds earlier;
  2. with the check in the write (a trigger that reads the lease): the same write is refused with
     "fenced", and nothing is written;
  3. the check does not get in the way: a write under a valid lease is accepted, and so is a
     write on a node with no lease at all.
It stops at the first FAIL, then thaws the writer and restores the starting state.

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

# Print how many rows the probe table holds on the writer.
count_rows() {
  database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_COUNT}"
}

# Send one write to the writer over the network as a client would; its output goes to a file.
# Usage: client_write RESULT_FILE
client_write() {
  local result="${1:?result file required}"
  local login

  login="$(controller::password_file "${SCRIPT_DIR}")"
  access::network_sql "${STANDBY_CONTAINER}" "${PRIMARY_CONTAINER}" "${login}" \
    <<< "${SQL_WRITE}" > "${result}" 2>&1
}

# Pause the writer for longer than its lease with a client write waiting, then let it resume.
# The word ok or failed, for the client's outcome, is left in the file named RESULT_FILE.state.
# Usage: write_through_pause RESULT_FILE
write_through_pause() {
  log INFO 'pausing the writer past its lease with a client write waiting'
  local result="${1:?result file required}"
  local pid

  fault::freeze_node "${PRIMARY_CONTAINER}"
  client_write "${result}" &
  pid=$!
  sleep "${PAUSE_SECONDS}"
  fault::thaw_node "${PRIMARY_CONTAINER}"
  if wait "${pid}"; then
    printf 'ok\n' > "${result}.state"
  else
    printf 'failed\n' > "${result}.state"
  fi
}

# Give the writer a fresh lease and an empty probe table, with or without the check.
# Usage: arm_writer yes|no
arm_writer() {
  local with_check="${1:?check setting required}"

  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_TABLE}; truncate fence_probe" > /dev/null
  lease::install "${PRIMARY_CONTAINER}" 1 "${LEASE_TTL}"
  if [[ "${with_check}" == 'yes' ]]; then
    lease::install_write_check "${PRIMARY_CONTAINER}" fence_probe
  fi
}

# Step 1: no check: a paused writer that resumes accepts the write although its lease ran out.
step_control() {
  local result="${1:?result file required}"
  local late

  begin_step 1 'control, no check: the resumed writer accepts a write after its lease ran out'
  arm_writer no
  write_through_pause "${result}"
  late="$(< "${result}")"
  story::narrate "the client's write was accepted ${late} ms after the lease ran out"
  story::expect_equal 'the client write succeeded' "$(< "${result}.state")" ok
  story::expect_between 'it was accepted after the lease had run out' "${late}" 1500 8000
  story::expect_equal 'the row is on the writer' "$(count_rows)" 1
}

# Step 2: with the check: the same write is refused, whatever the guard does.
step_check() {
  local result="${1:?result file required}"
  local fenced=0
  local text

  begin_step 2 'with the check in the write: the resumed writer refuses the write'
  arm_writer yes
  write_through_pause "${result}"
  text="$(< "${result}")"
  story::narrate "the client was told: ${text}"
  story::expect_equal 'the client write failed' "$(< "${result}.state")" failed
  if [[ "${text}" == *fenced* ]]; then
    fenced=1
  fi
  story::expect_equal 'the refusal says fenced' "${fenced}" 1
  story::expect_equal 'nothing was written' "$(count_rows)" 0
}

# Step 3: the check refuses nothing it should not: a valid lease and a missing lease both write.
step_not_in_the_way() {
  local result="${1:?result file required}"
  local late

  begin_step 3 'the check does not get in the way of a valid lease or of a node with no lease'
  lease::install "${PRIMARY_CONTAINER}" 1 60
  client_write "${result}"
  late="$(< "${result}")"
  story::expect_between 'a write under a valid lease is accepted' "${late}" -61000 0
  lease::remove "${PRIMARY_CONTAINER}"
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_PLAIN_WRITE}" > /dev/null
  story::expect_equal 'a write with no lease at all is accepted' "$(count_rows)" 2
}

# Run all the steps in order; the first failure stops the run.
# Usage: run_experiment RESULT_FILE
run_experiment() {
  local result="${1:?result file required}"

  story::narrate "story: a paused writer resumes after its lease ran out, ${PRIMARY_CONTAINER}"
  step_control "${result}"
  step_check "${result}"
  step_not_in_the_way "${result}"
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed"
}

# Run the steps in a child shell, so a failing step cannot skip the clean-up, then restore.
# Usage: run_and_restore RESULT_FILE
run_and_restore() {
  local result="${1:?result file required}"
  local outcome='passed'
  local pid

  log INFO 'running the experiment, then restoring the starting state'
  run_experiment "${result}" &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: thaw the writer, drop the probe, restore the state =='
  if ! fault::thaw_node "${PRIMARY_CONTAINER}" 2> /dev/null; then
    log INFO "${PRIMARY_CONTAINER} was not frozen"
  fi
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  lease::remove "${PRIMARY_CONTAINER}"
  story::run_statement "${PRIMARY_CONTAINER}" 'drop table if exists fence_probe'
  [[ "${outcome}" == 'passed' ]] || die 1 'the experiment failed (the state was restored)'
}

# Script entry point.
main() {
  local result_dir
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
  result_dir="$(mktemp -d "${TEMP_DIR}/resume-fence.XXXXXX")"
  CLEANUP_PATHS+=("${result_dir}")
  run_and_restore "${result_dir}/result"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
