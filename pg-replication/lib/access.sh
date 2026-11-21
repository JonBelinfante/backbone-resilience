# script-kind: library
# Purpose: Control access to the database nodes: set passwords, allow roles, probe logins.
# Usage: source "${SCRIPT_DIR}../lib/access.sh", then call access::run_sql and others
# Requires: cat docker
# Depends: container database
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly ACCESS_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
readonly ACCESS_ROLE_PATTERN='^[a-z][a-z0-9_]*$'
readonly ACCESS_SQL_READ='IFS= read -r NEWPW; export NEWPW'
readonly ACCESS_SQL_PSQL='exec psql -U postgres -d appdb -X -v ON_ERROR_STOP=1 -q'
readonly ACCESS_SQL_PROGRAM="${ACCESS_SQL_READ}; ${ACCESS_SQL_PSQL}"
readonly ACCESS_HBA_TEST="grep -qxF \"\$1\" \"\$2/pg_hba.conf\""
readonly ACCESS_HBA_APPEND="printf '%s\\n' \"\$1\" >> \"\$2/pg_hba.conf\""
readonly ACCESS_HBA_ADD="if ! ${ACCESS_HBA_TEST}; then ${ACCESS_HBA_APPEND}; fi"
readonly ACCESS_HBA_FILTER="grep -vxF \"\$1\" \"\$2/pg_hba.conf\" > \"\$2/pg_hba.new\""
readonly ACCESS_HBA_DROP="${ACCESS_HBA_FILTER} && mv \"\$2/pg_hba.new\" \"\$2/pg_hba.conf\""
readonly ACCESS_PROBE_START='IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql'
readonly ACCESS_PROBE_REPLICATION="\"host=\$1 user=\$2 replication=true dbname=postgres\""
readonly ACCESS_PROBE_LOGIN="\"host=\$1 user=\$2 dbname=appdb connect_timeout=5\""

# Run SQL on the container with a secret that psql reads with \getenv NAME NEWPW. The SQL comes
# from standard input. The secret travels as the first line of the input to the container, so it
# is never on a command line or in a file there. Use it to set passwords.
# Usage: access::run_sql CONTAINER ACCESS_FILE
access::run_sql() {
  local container="${1:?container required}"
  local file="${2:?secret file required}"
  local sql

  if [[ ! "${container}" =~ ${ACCESS_NAME_PATTERN} ]]; then
    die 2 "not a valid container name: ${container}"
  fi
  [[ -r "${file}" ]] || die 2 "cannot read the secret file ${file}"
  sql="$(cat)"
  {
    cat -- "${file}"
    printf '\n%s\n' "${sql}"
  } |
    docker exec -i "${container}" sh -c "${ACCESS_SQL_PROGRAM}"
}

# Check a role name and print the pg_hba.conf line that lets it stream WAL from any address.
# Usage: access::replication_login_line ROLE
access::replication_login_line() {
  local role="${1:?role required}"

  [[ "${role}" =~ ${ACCESS_ROLE_PATTERN} ]] || die 2 "not a valid role name: ${role}"
  printf 'host replication %s all scram-sha-256\n' "${role}"
}

# Allow a role to stream WAL from this node: add its line to pg_hba.conf if it is not there.
# The change takes effect at the next reload. Safe to repeat.
# Usage: access::allow_replication_login CONTAINER ROLE
access::allow_replication_login() {
  local container="${1:?container required}"
  local role="${2:?role required}"
  local line
  local data_dir

  line="$(access::replication_login_line "${role}")"
  data_dir="$(container::setting "${container}" PGDATA)"
  log INFO "CHANGE: allowing ${role} to stream from ${container} (pg_hba.conf)"
  docker exec --user postgres "${container}" sh -c "${ACCESS_HBA_ADD}" sh "${line}" "${data_dir}"
}

# Remove a role's replication line from pg_hba.conf (takes effect at the next reload).
# Usage: access::remove_replication_login CONTAINER ROLE
access::remove_replication_login() {
  local container="${1:?container required}"
  local role="${2:?role required}"
  local line
  local data_dir

  line="$(access::replication_login_line "${role}")"
  data_dir="$(container::setting "${container}" PGDATA)"
  log INFO "CHANGE: removing ${role}'s replication line from ${container} (pg_hba.conf)"
  docker exec --user postgres "${container}" sh -c "${ACCESS_HBA_DROP}" sh "${line}" "${data_dir}"
}

# Succeed if a replication login works: connect from SOURCE to TARGET_HOST as ROLE with the
# password in ACCESS_FILE (sent on standard input) and ask IDENTIFY_SYSTEM. Fail otherwise.
# Usage: access::probe_replication_login SOURCE TARGET_HOST ROLE ACCESS_FILE
access::probe_replication_login() {
  local source="${1:?source container required}"
  local target="${2:?target host required}"
  local role="${3:?role required}"
  local file="${4:?secret file required}"
  local program="${ACCESS_PROBE_START} ${ACCESS_PROBE_REPLICATION} -Atc IDENTIFY_SYSTEM"

  {
    cat -- "${file}"
    printf '\n'
  } |
    docker exec -i "${source}" sh -c "${program}" sh "${target}" "${role}" > /dev/null 2>&1
}

# Succeed if an ordinary login works over TCP: as probe_replication_login, but a plain query.
# Usage: access::probe_login SOURCE TARGET_HOST ROLE ACCESS_FILE
access::probe_login() {
  local source="${1:?source container required}"
  local target="${2:?target host required}"
  local role="${3:?role required}"
  local file="${4:?secret file required}"
  local program="${ACCESS_PROBE_START} ${ACCESS_PROBE_LOGIN} -Atc 'select 1'"

  {
    cat -- "${file}"
    printf '\n'
  } |
    docker exec -i "${source}" sh -c "${program}" sh "${target}" "${role}" > /dev/null 2>&1
}

# Create a replication role on the writer with the password in a file, or update the role if an
# earlier run left it behind. The role is checked against ACCESS_ROLE_PATTERN first.
# Usage: access::create_replication_role WRITER ROLE PASSWORD_FILE
access::create_replication_role() {
  local writer="${1:?writer required}"
  local role="${2:?role required}"
  local password_file="${3:?password file required}"
  local sql="select count(*) from pg_roles where rolname = '${role}'"
  local exists
  local verb='CREATE'

  [[ "${role}" =~ ${ACCESS_ROLE_PATTERN} ]] || die 2 "not a valid role name: ${role}"
  exists="$(database::bare "${writer}" <<< "${sql}")"
  if [[ "${exists}" == '1' ]]; then
    verb='ALTER'
  fi
  log INFO "CHANGE: ${verb} ROLE ${role} on ${writer}"
  printf '%s\n' '\getenv pw NEWPW' "${verb} ROLE ${role} WITH REPLICATION LOGIN PASSWORD :'pw';" |
    access::run_sql "${writer}" "${password_file}"
}
