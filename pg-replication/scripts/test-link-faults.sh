#!/usr/bin/env bash
# script-kind: executable
# Purpose: Test the replication link under jitter, a bandwidth limit, one-way silence, drops.
# Usage: test-link-faults.sh [-h | --help]
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
readonly PROXY='to-primary'
readonly TOTAL_STEPS=6
readonly SQL_INSERT='insert into net_probe default values returning id'
readonly SQL_LSN='select pg_current_wal_lsn()'
readonly SQL_BEHIND_STANDBY="select pg_wal_lsn_diff('LSN', pg_last_wal_replay_lsn())::bigint"
readonly SQL_DROP='drop table if exists net_probe'
readonly SQL_CREATE='create table net_probe (id bigserial primary key)'

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
Usage: test-link-faults.sh [-h | --help]

Put Toxiproxy between the standby and the writer and test faults beyond delay (delay, a cut
link and a silent link are in test-network-faults.sh):
  2. jitter (100 ms plus or minus 100 each way): asynchronous commits are unaffected; synchronous
     commits vary widely;
  3. a bandwidth limit: a WAL backlog builds, asynchronous commits are unaffected, and a
     synchronous commit waits behind the backlog;
  4. silence in one direction: replies lost (the standby holds the data, the writer cannot know),
     then WAL lost (the standby is behind); how soon each side notices;
  5. a link that drops every connection after a byte budget: each reconnect restarts at the
     start of the 16 MB WAL segment, so a 256 KB budget stalls replication for good, while a
     20 MB budget lets it finish; nothing is lost after the heal;
  6. what this showed. (Step 1 restores the stack and routes the standby through the proxy.)
Packet loss itself is not available (TCP hides it); drops and one-way silence are its effects.
It stops at the first FAIL, then heals the link and restores the stack.

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

# Heal the link and wait until the standby streams again.
heal_link() {
  toxic::heal
  sleep 2
  database::wait_for_streaming "${PRIMARY_CONTAINER}"
}

# Print how many bytes of the writer's WAL, up to a fixed position, the standby has yet to replay.
# Usage: bytes_behind POSITION
bytes_behind() {
  local position="${1:?position required}"
  local sql="${SQL_BEHIND_STANDBY//LSN/${position}}"

  database::bare "${STANDBY_CONTAINER}" <<< "${sql}"
}

# Print the milliseconds, from a start time, until the writer reports no streaming standby (at most
# a minute more).
# Usage: time_until_dropped STARTED_MICROSECONDS
time_until_dropped() {
  log INFO 'waiting for the writer to lose the standby'
  local started="${1:?start time required}"
  local waited=0

  while [[ "$(database::streaming_count "${PRIMARY_CONTAINER}")" != '0' && waited -lt 240 ]]; do
    sleep 0.25
    waited=$(( waited + 1 ))
  done
  printf '%d\n' "$(( (${EPOCHREALTIME//[.,]/} - started) / 1000 ))"
}

# Step 1: restore, make the probe table, and route the standby through the proxy.
prepare() {
  begin_step 1 'restore the stack and route the standby through the proxy'
  story::run_logged bash "${SCRIPT_DIR}restore-starting-state.sh"
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_DROP}"
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_CREATE}"
  route_standby proxy
}

# Step 2: jitter leaves asynchronous commits alone and makes synchronous commits vary widely.
jitter() {
  local base
  local commit
  local stale
  local width
  local -a parts=()
  local -a spread=()

  begin_step 2 'jitter: asynchronous commits are unaffected, synchronous commits vary'
  base="$(link::median_commit "${PRIMARY_CONTAINER}")"
  toxic::jitter "${PROXY}" 100 100
  sleep 1
  stale="$(link::staleness "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}")"
  commit="$(link::median_commit "${PRIMARY_CONTAINER}")"
  story::expect_between 'async, jitter: a commit is unaffected' "${commit}" 0 "$(( base + 60 ))"
  story::expect_between 'async, jitter: staleness is within the delay range' "${stale}" 0 700
  heal_link
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  read -r -a parts <<< "$(link::commit_summary "${PRIMARY_CONTAINER}")"
  toxic::jitter "${PROXY}" 100 100
  sleep 1
  read -r -a spread <<< "$(link::commit_summary "${PRIMARY_CONTAINER}")"
  heal_link
  story::narrate "sync: min ${parts[0]} median ${parts[1]} max ${parts[2]} ms; with jitter:"
  story::narrate "min ${spread[0]} median ${spread[1]} max ${spread[2]} ms"
  width=$(( spread[2] - spread[0] ))
  story::expect_between 'sync, jitter: the spread of commit times' "${width}" 100 1500
  story::expect_between 'sync, jitter: the median grows' "$(( spread[1] - parts[1] ))" 60 500
}

# Step 3: a bandwidth limit builds a WAL backlog; a synchronous commit waits behind it.
bandwidth() {
  local position
  local behind
  local started
  local blocked

  begin_step 3 'a bandwidth limit: a backlog builds; a synchronous commit waits behind it'
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
  toxic::bandwidth "${PROXY}" 512
  sleep 1
  fault::generate_wal "${PRIMARY_CONTAINER}" 1
  position="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_LSN}")"
  behind="$(bytes_behind "${position}")"
  story::narrate "the standby is ${behind} bytes behind after one 8 MB write"
  story::expect_between 'async: the standby is behind by much of it' "${behind}" 2000000 9000000
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode sync
  started="${EPOCHREALTIME//[.,]/}"
  database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_INSERT}" > /dev/null
  blocked="$(( (${EPOCHREALTIME//[.,]/} - started) / 1000 ))"
  heal_link
  story::narrate "a synchronous commit waited ${blocked} ms behind the backlog"
  story::expect_between 'sync: the commit waits for the backlog to drain' "${blocked}" 4000 20000
}

# Silence one direction, write a row under asynchronous replication, report: standby has it (1/0)
# and the milliseconds until the writer drops the standby.
# Usage: one_way_report DIRECTION
one_way_report() {
  log INFO 'silencing one direction and writing a row'
  local direction="${1:?direction required}"
  local row
  local seen
  local sql
  local started

  started="${EPOCHREALTIME//[.,]/}"
  toxic::silence_one_way "${PROXY}" "${direction}"
  row="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_INSERT}")"
  sleep 2
  sql="select count(*) from net_probe where id = ${row}"
  seen="$(database::bare "${STANDBY_CONTAINER}" <<< "${sql}")"
  printf '%s %s\n' "${seen}" "$(time_until_dropped "${started}")"
  heal_link
}

# Step 4: silence in one direction; each side notices through its own timeout.
one_way() {
  local seen_up
  local drop_up
  local seen_down
  local drop_down

  begin_step 4 'silence in one direction only, with 5 s timeouts on both ends'
  story::run_logged bash "${SCRIPT_DIR}set-replication-mode.sh" --mode async
  fault::tune "${PRIMARY_CONTAINER}" wal_sender_timeout 5s
  fault::tune "${STANDBY_CONTAINER}" wal_receiver_timeout 5s
  sleep 6
  database::wait_for_streaming "${PRIMARY_CONTAINER}"
  read -r seen_up drop_up <<< "$(one_way_report upstream)"
  read -r seen_down drop_down <<< "$(one_way_report downstream)"
  story::narrate "replies lost: standby had the row (${seen_up}), writer noticed in ${drop_up} ms"
  story::narrate "WAL lost: standby had the row (${seen_down}), writer noticed in ${drop_down} ms"
  story::expect_equal 'replies lost: the standby still received the row' "${seen_up}" 1
  story::expect_equal 'WAL lost: the standby did not receive the row' "${seen_down}" 0
  story::expect_between 'replies lost: the writer notices at its timeout' "${drop_up}" 4000 14000
  story::expect_between 'WAL lost: dropped at the receiver timeout' "${drop_down}" 4000 14000
}

# Step 5a: with a small budget the standby never gets past that many bytes into the current WAL
# segment, because every reconnect restarts at the segment start (shown in its log).
drop_big_record() {
  local position
  local early
  local late

  toxic::drop_after "${PROXY}" 262144
  sleep 1
  fault::generate_wal "${PRIMARY_CONTAINER}" 1
  position="$(database::bare "${PRIMARY_CONTAINER}" <<< "${SQL_LSN}")"
  sleep 4
  early="$(bytes_behind "${position}")"
  sleep 4
  late="$(bytes_behind "${position}")"
  story::narrate "one 8 MB record: behind after 4 s ${early} bytes, after 8 s ${late} bytes"
  story::expect_between 'the standby is still behind' "${early}" 1000000 9000000
  story::expect_between 'and makes no progress at all' "$(( early - late ))" 0 8192
  heal_link
  database::wait_for_replay "${STANDBY_CONTAINER}" "${position}"
}

# Step 5: a link that drops every connection after 256 KB, read from the standby's own log.
dropping() {
  local places

  begin_step 5 'a link that drops every connection after 256 KB: replication stalls'
  fault::tune "${PRIMARY_CONTAINER}" wal_sender_timeout reset
  fault::tune "${STANDBY_CONTAINER}" wal_receiver_timeout reset
  fault::tune "${STANDBY_CONTAINER}" wal_retrieve_retry_interval 500ms
  drop_big_record
  places="$(link::restart_places "${STANDBY_CONTAINER}" 10)"
  story::narrate "the standby's log: its last 10 restarts began at ${places} WAL position(s)"
  story::expect_between 'every restart began at the same place' "${places}" 1 1
  story::expect_equal 'after the heal the standby holds every row' \
    "$(database::bare "${STANDBY_CONTAINER}" <<< 'select count(*) from net_probe')" \
    "$(database::bare "${PRIMARY_CONTAINER}" <<< 'select count(*) from net_probe')"
}

# Step 6: say what the run demonstrated.
narrate_conclusion() {
  begin_step 6 'what this showed'
  story::narrate "PASS: all ${TOTAL_STEPS} steps passed. What this showed:"
  story::narrate '  Jitter makes synchronous commits unpredictable, not asynchronous ones;'
  story::narrate '  a bandwidth limit makes a synchronous commit wait behind the WAL backlog;'
  story::narrate '  one-way silence is noticed by whichever end stops hearing, and a writer'
  story::narrate '  that loses only the replies cannot tell that the standby has the data;'
  story::narrate '  a dropping link stalls replication unless its budget exceeds a WAL segment.'
}

# Run all the steps in order; the first failure stops the run.
run_experiment() {
  story::narrate "story: link faults on the replication link of ${PRIMARY_CONTAINER}"
  prepare
  jitter
  bandwidth
  one_way
  dropping
  narrate_conclusion
}

# Run the steps in a child shell, so a failure cannot skip the clean-up; then put everything back.
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
  story::run_statement "${PRIMARY_CONTAINER}" "${SQL_DROP}"
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
  require_commands cat sleep
  run_and_restore
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
