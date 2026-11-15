# script-kind: library
# Purpose: Every database call for the containers: run SQL, ask the role, check readiness.
# Usage: source "${SCRIPT_DIR}../lib/database.sh", then call database::run, bare, in_recovery ...
# Requires: docker
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly DATABASE_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
readonly DATABASE_RECOVERY_SQL='select pg_is_in_recovery()'

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
database::in_recovery() {
  local container="${1:?container required}"

  database::bare "${container}" <<< "${DATABASE_RECOVERY_SQL}"
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
