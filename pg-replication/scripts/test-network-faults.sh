#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test the replication link under network faults: delay, a cut link, and a silent link.
# Usage: test-network-faults.sh [-h | --help]
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
readonly PROXY='to-primary'
readonly TOTAL_STEPS=7
readonly SQL_INSERT='insert into net_probe default values returning id'
readonly SQL_COUNT='select count(*) from net_probe'
readonly SQL_DROP='drop table if exists net_probe'
readonly SQL_CREATE='create table net_probe (id bigserial primary key)'
readonly CUT_SECONDS=5

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
# shellcheck source=../lib/toxic.sh
source "${SCRIPT_DIR}../lib/toxic.sh"
# shellcheck source=../lib/measure.sh
source "${SCRIPT_DIR}../lib/measure.sh"
# shellcheck source=../lib/link.sh
source "${SCRIPT_DIR}../lib/link.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: test-network-faults.sh [-h | --help]

Put Toxiproxy between the standby and the writer and test the replication link:
  1. asynchronous, delay of 200 and 1000 ms each way: commits are unaffected, the standby is
     stale by about the delay;
  2. synchronous, delay of 200 ms each way: a commit costs about one round trip more;
  3. synchronous, link cut for 5 s: commits are blocked while it is cut, and resume within the
     standby's retry interval of the link coming back (wal_retrieve_retry_interval: 5 s by
     default, so up to 5 s; within 500 ms when it is set to 500 ms);
  4. link silent (data swallowed, connection open): the writer notices after wal_sender_timeout
     (60 s by default) and after 5 s when it and wal_receiver_timeout are set to 5 s;
  5. asynchronous, delay then a crash of the writer: the loss grows with the delay;
  6. synchronous, the same: nothing acknowledged is lost.
Each limit is the mechanism's, not fitted to a run. About 6 minutes; changes the databases and
replication settings and restores them: throwaway stack only.

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

# Point the standby at the writer directly or through the proxy, and wait until it streams.
# Usage: route_standby proxy|direct
route_standby() {
  local route="${1:?route required}"

  link::route "${SCRIPT_DIR}" "${route}" "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"
}

# Print the median commit time, in milliseconds.
median_commit() {
  link::median_commit "${PRIMARY_CONTAINER}"
}

# Print how many milliseconds a row takes to become visible on the standby after it commits.
staleness() {
  link::staleness "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"
}

# Step 1: restore, make the probe table, and route the standby through the proxy.
prepare() {
  begin_step 1 'restore the stack and route the standby through the proxy'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" 'drop table if exists net_probe'
  story::run_statement "${PRIMARY_CONTAINER}" 'create table net_probe (id bigserial primary key)'
  route_standby proxy
}

# Step 2: asynchronous. Delay leaves commits alone and makes the standby stale by about the delay.
async_latency() {
  local base
  local commit
  local stale
  local delay
  local limit
  local low
  local high

  begin_step 2 'asynchronous: delay on the link leaves commits alone and makes the standby stale'
  base="$(median_commit)"
  story::narrate "baseline: a commit takes ${base} ms"
  for delay in 200 1000; do
    toxic::latency "${PROXY}" "${delay}"
    sleep 1
    commit="$(median_commit)"
    stale="$(staleness)"
    toxic::heal
    sleep 2
    database::wait_for_streaming "${PRIMARY_CONTAINER}"
    limit=$(( base + 50 ))
    story::expect_between "delay ${delay} ms: a commit is unaffected" "${commit}" 0 "${limit}"
    low=$(( delay * 8 / 10 ))
    high=$(( delay + 600 ))
    story::expect_between "delay ${delay} ms: standby staleness" "${stale}" "${low}" "${high}"
  done
}

# Step 3: synchronous. A commit waits for the standby, so delay each way costs a round trip.
sync_latency() {
  local base
  local commit

  begin_step 3 'synchronous: a commit waits one round trip to the standby'
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  base="$(median_commit)"
  toxic::latency "${PROXY}" 200
  sleep 1
  commit="$(median_commit)"
  toxic::heal
  sleep 2
  database::wait_for_streaming "${PRIMARY_CONTAINER}"
  story::narrate "a commit took ${base} ms, and ${commit} ms with 200 ms of delay each way"
  story::expect_between 'the delay adds a round trip (2 x 200 ms)' "$(( commit - base ))" 320 700
}

# Cut the link under a sync commit, heal it after CUT_SECONDS, print: ms blocked, ms after the heal.
cut_and_measure() {
  log INFO 'cutting the link under a commit'
  local started
  local healed
  local ended
  local pid

  toxic::cut "${PROXY}"
  started="${EPOCHREALTIME//[.,]/}"
  database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_INSERT}" > /dev/null &
  pid=$!
  sleep "${CUT_SECONDS}"
  toxic::heal
  healed="${EPOCHREALTIME//[.,]/}"
  wait "${pid}" || die 1 'FAIL: the commit failed instead of waiting'
  ended="${EPOCHREALTIME//[.,]/}"
  printf '%d %d\n' "$(( (ended - started) / 1000 ))" "$(( (ended - healed) / 1000 ))"
  database::wait_for_streaming "${PRIMARY_CONTAINER}"
}

# Step 4: after a cut, commits resume within one retry interval of the link coming back.
cut_link() {
  local stalled_default
  local resumed_default
  local stalled_tuned
  local resumed_tuned

  begin_step 4 "synchronous: the link is cut for ${CUT_SECONDS} s"
  read -r stalled_default resumed_default <<< "$(cut_and_measure)"
  fault::tune "${STANDBY_CONTAINER}" wal_retrieve_retry_interval 500ms
  sleep 1
  read -r stalled_tuned resumed_tuned <<< "$(cut_and_measure)"
  fault::tune "${STANDBY_CONTAINER}" wal_retrieve_retry_interval reset
  story::narrate "stalled ${stalled_default} ms, resumed ${resumed_default} ms after the heal;"
  story::narrate "with a 500 ms retry: ${stalled_tuned} ms and ${resumed_tuned} ms"
  story::expect_between 'blocked while the link was cut' "${stalled_default}" 5000 20000
  story::expect_between 'retry 5 s: resumes within a retry of the heal' "${resumed_default}" 0 7000
  story::expect_between 'retry 500 ms: resumes within a retry of the heal' "${resumed_tuned}" 0 2500
}

# Print how many milliseconds the writer takes to notice that a silent link has lost its standby.
time_to_notice() {
  log INFO 'making the link silent and waiting for the writer to notice'
  local started
  local waited=0

  toxic::silence "${PROXY}"
  started="${EPOCHREALTIME//[.,]/}"
  while [[ "$(database::streaming_count "${PRIMARY_CONTAINER}")" != '0' && waited -lt 400 ]]; do
    sleep 0.25
    waited=$(( waited + 1 ))
  done
  printf '%d\n' "$(( (${EPOCHREALTIME//[.,]/} - started) / 1000 ))"
  toxic::heal
  sleep 2
  database::wait_for_streaming "${PRIMARY_CONTAINER}"
}

# Step 5: a silent link is noticed only when the sender times out.
silent_link() {
  local detected_default
  local detected_tuned

  begin_step 5 'the link goes silent: data swallowed, the connection stays open'
  detected_default="$(time_to_notice)"
  fault::tune "${PRIMARY_CONTAINER}" wal_sender_timeout 5s
  fault::tune "${STANDBY_CONTAINER}" wal_receiver_timeout 5s
  sleep 6
  database::wait_for_streaming "${PRIMARY_CONTAINER}"
  detected_tuned="$(time_to_notice)"
  fault::tune "${PRIMARY_CONTAINER}" wal_sender_timeout reset
  fault::tune "${STANDBY_CONTAINER}" wal_receiver_timeout reset
  story::expect_between 'default: noticed at the sender timeout' "${detected_default}" 50000 70000
  story::expect_between 'with 5 s timeouts: noticed in time' "${detected_tuned}" 2000 8000
}

# Print how many acknowledged writes the promoted standby lacks.
# Usage: lost_after_crash MODE DELAY_MS
lost_after_crash() {
  log INFO 'delaying the link, writing, crashing the writer'
  local mode="${1:?mode required}"
  local delay="${2:?delay required}"
  local acked=0
  local deadline

  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh" > /dev/null
  database::run "${PRIMARY_CONTAINER}" <<< "${SQL_DROP}; ${SQL_CREATE}" > /dev/null
  route_standby proxy
  bash "${SCRIPT_DIR}set-replication-mode.sh" --mode "${mode}" > /dev/null
  toxic::latency "${PROXY}" "${delay}"
  sleep 1
  deadline=$(( SECONDS + 3 ))
  while (( SECONDS < deadline )); do
    database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_INSERT}" > /dev/null
    acked=$(( acked + 1 ))
  done
  fault::crash_node "${PRIMARY_CONTAINER}"
  bash "${SCRIPT_DIR}promote-standby-to-primary.sh" > /dev/null
  toxic::heal
  printf '%d\n' "$(( acked - $(database::bare "${STANDBY_CONTAINER}" <<< "${SQL_COUNT}") ))"
}

# Step 6: delay then a crash. Under async the loss grows with the delay; under sync there is none.
gradual_loss() {
  local lost_small
  local lost_large
  local lost_sync

  begin_step 6 'a delayed link, then the writer crashes: what was lost?'
  lost_small="$(lost_after_crash async 200)"
  lost_large="$(lost_after_crash async 1000)"
  lost_sync="$(lost_after_crash sync 1000)"
  story::narrate "async lost ${lost_small} writes at 200 ms of delay, ${lost_large} at 1000 ms"
  story::expect_between 'async, 1000 ms of delay: acknowledged writes are lost' "${lost_large}" 1 60
  story::expect_between 'async, 200 ms: no more than at 1000 ms' "${lost_small}" 0 "${lost_large}"
  story::expect_between 'sync, 1000 ms of delay: no acknowledged write is lost' "${lost_sync}" 0 0
}

# Step 7: say what the run demonstrated.
narrate_conclusion() {
  begin_step 7 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  Delay costs a synchronous commit a round trip and an asynchronous one nothing;'
  story::narrate '  a cut link blocks sync commits until the standby retries; a silent link is'
  story::narrate '  noticed only after the sender timeout (60 s by default).'
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: network faults on the replication link of ${PRIMARY_CONTAINER}"
  prepare
  async_latency
  sync_latency
  cut_link
  silent_link
  gradual_loss
  narrate_conclusion
}

# Run the steps in a child shell, so a failure cannot skip the clean-up; then put everything back:
# heal the link, restore the stack (both nodes up), reset the settings, async mode, direct route.
run_and_restore() {
  log INFO 'running the experiment, then restoring'
  local outcome='passed'
  local pid

  run_experiment &
  pid=$!
  wait "${pid}" || outcome='failed'
  story::narrate '== Cleanup: heal the link, reset the settings, restore the stack =='
  toxic::heal
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  fault::tune "${STANDBY_CONTAINER}" wal_retrieve_retry_interval reset
  fault::tune "${STANDBY_CONTAINER}" wal_receiver_timeout reset
  fault::tune "${PRIMARY_CONTAINER}" wal_sender_timeout reset
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
  route_standby direct
  story::run_statement "${PRIMARY_CONTAINER}" 'drop table if exists net_probe'
  [[ "${outcome}" == 'passed' ]] || die 1 'the experiment failed (the stack was restored)'
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
