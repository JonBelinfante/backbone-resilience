# script-kind: library
# Purpose: Every database call for the containers: run SQL, ask the role, check readiness.
# Usage: source "${SCRIPT_DIR}../lib/database.sh", then call database::run, bare, in_recovery ...
# Requires: docker sleep
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly DATABASE_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
readonly DATABASE_RECOVERY_SQL='select pg_is_in_recovery()'
readonly DATABASE_STREAMING_SQL="select count(*) from pg_stat_replication where state = 'streaming'"
readonly DATABASE_RETRY_ATTEMPTS=15
readonly DATABASE_RETRY_PAUSE_SECONDS=2
readonly DATABASE_REPLAY_ATTEMPTS=60
readonly DATABASE_REPLAY_PAUSE_SECONDS=0.5
readonly DATABASE_LSN_PATTERN='^[0-9A-F]+/[0-9A-F]+$'
readonly DATABASE_WAL_SIZE_SQL='select (coalesce(sum(size), 0) / 1048576)::int from pg_ls_waldir()'
readonly DATABASE_SLOT_BEHIND='pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)'
readonly DATABASE_SLOT_LAG_SQL="coalesce(round(${DATABASE_SLOT_BEHIND} / 1048576), -1)"

# Run psql in the container as the postgres user on appdb, stopping at the first SQL error. The
# SQL comes from standard input; any further arguments go to psql unchanged.
# Usage: database::run CONTAINER [PSQL_ARGUMENT ...]
database::run() {
  local container="${1:?container required}"

  if [[ ! "${container}" =~ ${DATABASE_NAME_PATTERN} ]]; then
    die 2 "not a valid container name: ${container}"
  fi
  docker exec -i "${container}" psql -U postgres -d appdb -X -v ON_ERROR_STOP=1 "${@:2}"
}

# Like database::run, with bare output for scripts: unaligned, no headers, no decoration.
database::bare() {
  local container="${1:?container required}"

  database::run "${container}" -Atq
}

# Print t if the server in the container is in recovery (a standby), f if it accepts writes.
# A server that is starting up or shutting down (a killed run can leave one in either state)
# is asked again every DATABASE_RETRY_PAUSE_SECONDS, up to DATABASE_RETRY_ATTEMPTS times. A
# container that is not running fails at once.
database::in_recovery() {
  local container="${1:?container required}"
  local attempt=1
  local answer
  local running

  while (( attempt <= DATABASE_RETRY_ATTEMPTS )); do
    if answer="$(database::bare "${container}" <<< "${DATABASE_RECOVERY_SQL}" 2> /dev/null)"; then
      printf '%s\n' "${answer}"
      return 0
    fi
    running="$(docker inspect --format '{{.State.Running}}' "${container}")"
    [[ "${running}" == 'true' ]] || die 1 "${container} is not running"
    log INFO "${container} did not answer yet (attempt ${attempt}), waiting"
    attempt=$(( attempt + 1 ))
    sleep "${DATABASE_RETRY_PAUSE_SECONDS}"
  done
  die 1 "${container} did not answer after ${DATABASE_RETRY_ATTEMPTS} attempts"
}

# Print how many standbys the writable node in the container reports as streaming.
database::streaming_count() {
  local container="${1:?container required}"

  database::bare "${container}" <<< "${DATABASE_STREAMING_SQL}"
}

# Run a query for a decision (approve, decline, price, limit): the answer must be current, so
# only a node that accepts writes is asked. A replica may lag, so it is refused. The SQL comes
# from standard input, and the answer is printed bare, as database::bare does.
database::read_for_decision() {
  local container="${1:?container required}"
  local recovery

  recovery="$(database::in_recovery "${container}")"
  if [[ "${recovery}" != 'f' ]]; then
    die 1 "refusing to read ${container} for a decision: it is a replica and may lag"
  fi
  database::bare "${container}"
}

# Wait until the replica in the container has replayed at least the given WAL position, so a
# read on it sees every change made up to that position (read-your-writes). Fail on time-out.
# Usage: database::wait_for_replay CONTAINER LSN
database::wait_for_replay() {
  local container="${1:?container required}"
  local lsn="${2:?WAL position required}"
  local sql="select pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '${lsn}') >= 0"
  local attempt=1
  local reached

  [[ "${lsn}" =~ ${DATABASE_LSN_PATTERN} ]] || die 2 "not a WAL position: ${lsn}"
  while (( attempt <= DATABASE_REPLAY_ATTEMPTS )); do
    reached="$(database::bare "${container}" <<< "${sql}")"
    if [[ "${reached}" == 't' ]]; then
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep "${DATABASE_REPLAY_PAUSE_SECONDS}"
  done
  die 1 "${container} did not replay up to ${lsn} after ${DATABASE_REPLAY_ATTEMPTS} attempts"
}

# Succeed if the server in the container accepts connections (pg_isready). Fail otherwise,
# which includes a stopped container.
database::is_ready() {
  local container="${1:?container required}"

  docker exec "${container}" pg_isready -q -h 127.0.0.1 > /dev/null 2>&1
}

# Print the statements that drop every table in a schema, as one line, or nothing if it is empty.
# Usage: database::drop_all_sql CONTAINER SCHEMA
database::drop_all_sql() {
  local container="${1:?container required}"
  local schema="${2:?schema required}"
  local sql="select string_agg(format('drop table if exists %I cascade', tablename), '; ')"

  sql+=" from pg_tables where schemaname = '${schema}'"
  database::bare "${container}" <<< "${sql}"
}

# Print the megabytes of WAL files the node keeps in its WAL directory.
database::wal_megabytes() {
  local container="${1:?container required}"

  database::bare "${container}" <<< "${DATABASE_WAL_SIZE_SQL}"
}

# Print one line about a replication slot: status|active|megabytes behind|megabytes still safe.
# The status is none for a slot that does not exist and lost for one that was invalidated; the
# megabytes behind are -1 once the slot has lost its position.
# Usage: database::slot_state CONTAINER SLOT
database::slot_state() {
  local container="${1:?container required}"
  local slot="${2:?slot required}"
  local sql="select coalesce(wal_status, 'lost'), active, ${DATABASE_SLOT_LAG_SQL},"

  [[ "${slot}" =~ ${DATABASE_NAME_PATTERN} ]] || die 2 "not a valid slot name: ${slot}"
  sql+=" coalesce(safe_wal_size, 0) / 1048576 from pg_replication_slots where slot_name = '${slot}'"
  database::bare "${container}" <<< "${sql}"
}
