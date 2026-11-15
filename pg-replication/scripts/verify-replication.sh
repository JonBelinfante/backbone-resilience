#!/usr/bin/env bash
# script-kind: executable
# Purpose: Prove that the standby is streaming WAL from the primary and replaying it.
# Usage: verify-replication.sh [-h | --help]
# Requires: cat head sleep
# Exit codes: 0 all checks passed, 1 a check failed, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly POLL_ATTEMPTS=100
readonly POLL_PAUSE='0.1'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: verify-replication.sh [-h | --help]

Proves, with a live write, that the standby is streaming WAL from the primary and replaying
it. Both containers must be running. The checks run in order and stop at the first failure:

  1. Roles       the primary accepts writes and the standby is in recovery.
  2. Streaming   the primary lists a standby in the 'streaming' state.
  3. Round trip  insert a row on the primary, poll the standby for up to about 10 s and report
                 how long the row took to appear; it fails if the row never arrives.
  4. Read-only   a write sent to the standby must be rejected.
  5. WAL         received and replayed positions on the standby (equal = fully caught up).

Side effect: creates the table replication_check if missing and adds one row per run (kept).

Environment:
  PRIMARY_CONTAINER, STANDBY_CONTAINER  container names (defaults: pg-primary, pg-standby)
  RUN_LOG_DIR  directory for this run's log file, which must exist (default: temporary directory)

Exit codes: 0 all checks passed, 1 a check failed, 2 usage or configuration error
USAGE
}

# Print a section heading.
heading() {
  local title="${1:?title required}"

  printf '\n== %s ==\n' "${title}"
}

# SQL: one row per connected standby, with its state and lag.
sql_replication() {
  cat <<'SQL'
select application_name, state, sync_state, write_lag, flush_lag, replay_lag,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as replay_lag_bytes
from pg_stat_replication
SQL
}

# SQL: how many standbys are streaming.
sql_streaming_count() {
  cat <<'SQL'
select count(*) from pg_stat_replication where state = 'streaming'
SQL
}

# SQL: the test table; written_at records the commit moment using the wall clock.
sql_create_table() {
  cat <<'SQL'
create table if not exists replication_check (
  id bigserial primary key,
  note text not null,
  written_at timestamptz not null default clock_timestamp())
SQL
}

# SQL: insert a test row and return its id.
sql_insert_row() {
  cat <<'SQL'
insert into replication_check(note) values ('hello from primary') returning id
SQL
}

# SQL: milliseconds since the row :id was written; no rows until the standby has replayed it.
sql_row_delay() {
  cat <<'SQL'
select round(extract(epoch from clock_timestamp() - written_at) * 1000)
from replication_check where id = :id
SQL
}

# SQL: a write that the standby must reject.
sql_rejected_write() {
  cat <<'SQL'
insert into replication_check(note) values ('should be rejected')
SQL
}

# SQL: WAL received (written to disk) and replayed (applied) on the standby.
sql_wal_positions() {
  cat <<'SQL'
select pg_last_wal_receive_lsn() as received, pg_last_wal_replay_lsn() as replayed
SQL
}

# Check 1: the primary is not in recovery and the standby is.
check_roles() {
  local primary
  local standby

  heading '1. Roles'
  primary="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  standby="$(database::in_recovery "${STANDBY_CONTAINER}")"
  printf 'primary in recovery: %s (expect f)\n' "${primary}"
  printf 'standby in recovery: %s (expect t)\n' "${standby}"
  if [[ "${primary}" != 'f' || "${standby}" != 't' ]]; then
    die 1 'unexpected roles'
  fi
  log INFO 'roles are as expected'
}

# Check 2: the primary sees at least one standby in the streaming state.
check_streaming() {
  local streaming

  heading '2. Streaming connection, as seen by the primary'
  database::run "${PRIMARY_CONTAINER}" <<< "$(sql_replication)"
  streaming="$(database::bare "${PRIMARY_CONTAINER}" <<< "$(sql_streaming_count)")"
  if (( streaming < 1 )); then
    die 1 'no streaming standby'
  fi
  log INFO "streaming standbys: ${streaming}"
}

# Ask the standby how long ago the row was written. Fails if the query fails.
row_delay() {
  local id="${1:?id required}"
  local query

  query="$(sql_row_delay)"
  database::bare "${STANDBY_CONTAINER}" <<< "\\set id ${id}"$'\n'"${query}" 2> /dev/null
}

# Poll the standby until the row appears; print the delay in milliseconds, or nothing
# if it never appears. A failed poll (for example the table not yet replicated) is not an error.
poll_standby() {
  local id="${1:?id required}"
  local reply
  local attempt=0

  while (( attempt < POLL_ATTEMPTS )); do
    if reply="$(row_delay "${id}")"; then
      if [[ -n "${reply}" ]]; then
        printf '%s\n' "${reply}"
        return 0
      fi
    fi
    sleep "${POLL_PAUSE}"
    attempt=$(( attempt + 1 ))
  done
}

# Check 3: insert a row on the primary and time how long until the standby can read it.
check_round_trip() {
  local id
  local delay

  heading '3. Write on primary, read on standby'
  database::run "${PRIMARY_CONTAINER}" <<< "$(sql_create_table)"
  id="$(database::bare "${PRIMARY_CONTAINER}" <<< "$(sql_insert_row)" | head -n 1)"
  printf 'inserted row id=%s on primary\n' "${id}"
  delay="$(poll_standby "${id}")"
  if [[ -z "${delay}" ]]; then
    die 1 "row ${id} never appeared on standby within 10s"
  fi
  printf 'row %s visible on standby after ~%s ms ' "${id}" "${delay}"
  printf '(includes docker exec overhead)\n'
  log INFO "row ${id} replicated in ${delay} ms"
}

# Check 4: a write on the standby must be rejected. Output is discarded because the
# error message is the expected outcome here.
check_read_only() {
  heading '4. Standby is read-only'
  if database::run "${STANDBY_CONTAINER}" <<< "$(sql_rejected_write)" > /dev/null 2>&1; then
    die 1 'standby accepted a write'
  fi
  printf 'OK: standby rejected the write\n'
  log INFO 'standby rejected the write'
}

# Check 5: show received and replayed WAL positions on the standby.
check_wal_positions() {
  heading '5. WAL positions'
  database::run "${STANDBY_CONTAINER}" <<< "$(sql_wal_positions)"
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
  require_commands cat head sleep

  check_roles
  check_streaming
  check_round_trip
  check_read_only
  check_wal_positions
  printf '\nPASS: replication is working\n'
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
