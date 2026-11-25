# script-kind: library
# Purpose: The writer's lease and the guard that enforces it: install, guard, read, remove.
# Usage: source "${SCRIPT_DIR}../lib/lease.sh", then call lease::install, guard_start, check
# Requires: docker
# Depends: database
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly LEASE_GUARD_IMAGE='resilience-fence-guard'
readonly LEASE_GUARD_PREFIX='guard-'
readonly LEASE_TABLE_PATTERN='^[a-z][a-z0-9_]*$'
readonly LEASE_CHECK_FUNCTION_SQL="create or replace function fence_check() returns trigger
  language plpgsql as \$body\$
begin
  if to_regclass('fence_lease') is not null and exists (
    select 1 from fence_lease where id = 1 and expires_at < clock_timestamp()) then
    raise exception 'fenced: the writer lease has expired' using errcode = '55000';
  end if;
  return null;
end \$body\$"
readonly LEASE_DROP_SQL='drop table if exists fence_lease;
  drop function if exists fence_check() cascade'
readonly LEASE_TABLE_SQL='create table if not exists fence_lease (
  id int primary key check (id = 1), epoch bigint not null, expires_at timestamptz not null)'

# Build the guard image from the services folder, next to the scripts folder's parent.
# Usage: lease::build SCRIPT_DIR
lease::build() {
  local script_dir="${1-}"

  log INFO "CHANGE: building ${LEASE_GUARD_IMAGE}"
  docker build \
    --quiet \
    --tag "${LEASE_GUARD_IMAGE}" \
    --file "${script_dir}../../services/fence_guard/Dockerfile" \
    "${script_dir}../../services" > /dev/null
}

# Create the lease table on a writer and give it a lease of TTL seconds at the given epoch.
# Usage: lease::install CONTAINER EPOCH TTL
lease::install() {
  local container="${1:?container required}"
  local epoch="${2:?epoch required}"
  local ttl="${3:?ttl required}"
  local sql="${LEASE_TABLE_SQL}; insert into fence_lease values (1, ${epoch},"

  require_integer epoch "${epoch}"
  require_integer ttl "${ttl}"
  sql+=" clock_timestamp() + interval '${ttl} seconds')"
  sql+=' on conflict (id) do update set epoch = excluded.epoch, expires_at = excluded.expires_at'
  log INFO "CHANGE: ${container} gets a lease at epoch ${epoch} for ${ttl} s"
  database::run "${container}" <<< "${sql}" > /dev/null
}

# Drop the lease table, and the write check that reads it, from a writer (safe to repeat).
# Usage: lease::remove CONTAINER
lease::remove() {
  local container="${1:?container required}"

  log INFO "CHANGE: ${container} loses its lease table"
  database::run "${container}" <<< "${LEASE_DROP_SQL}" > /dev/null
}

# Print the seconds the writer's lease has left (negative once it ran out).
# Usage: lease::seconds_left CONTAINER
lease::seconds_left() {
  local container="${1:?container required}"
  local sql='select round(extract(epoch from expires_at - clock_timestamp())::numeric, 1)'

  sql+=' from fence_lease where id = 1'
  database::bare "${container}" <<< "${sql}"
}

# Print the epoch of the writer's lease.
# Usage: lease::epoch CONTAINER
lease::epoch() {
  local container="${1:?container required}"

  database::bare "${container}" <<< 'select epoch from fence_lease where id = 1'
}

# Remove the guard beside a writer; succeeds if there is none.
# Usage: lease::guard_stop CONTAINER
lease::guard_stop() {
  local container="${1:?container required}"

  log INFO "CHANGE: removing the lease guard beside ${container}"
  if ! docker rm --force "${LEASE_GUARD_PREFIX}${container}" > /dev/null 2>&1; then
    log INFO "there was no guard beside ${container}"
  fi
}

# Print the milliseconds the writer's lease has left (negative once it ran out).
# Usage: lease::milliseconds_left CONTAINER
lease::milliseconds_left() {
  local container="${1:?container required}"
  local sql='select round(extract(epoch from expires_at - clock_timestamp()) * 1000)::int'

  sql+=' from fence_lease where id = 1'
  database::bare "${container}" <<< "${sql}"
}

# Start a guard (replacing any there is) in the writer's network namespace, so cutting the writer
# off the network cuts the guard off too. It stops the writer once the lease has run out.
# Usage: lease::guard_start CONTAINER LOGIN_PATH
lease::guard_start() {
  local container="${1:?container required}"
  local login_path="${2:?login path required}"
  local -a command=(docker run --detach --name "${LEASE_GUARD_PREFIX}${container}")

  command+=(--network "container:${container}")
  command+=(--volume "${login_path}:/run/secrets/pg-password:ro")
  command+=(--env PASSWORD_FILE=/run/secrets/pg-password)
  command+=("${LEASE_GUARD_IMAGE}")
  lease::guard_stop "${container}"
  log INFO "CHANGE: starting a lease guard beside ${container}"
  "${command[@]}" > /dev/null
}

# Print the guard's log lines about decisions.
# Usage: lease::guard_log CONTAINER
lease::guard_log() {
  local container="${1:?container required}"

  docker logs "${LEASE_GUARD_PREFIX}${container}" 2>&1
}

# Make a table refuse every write once the writer's lease has run out. The check runs inside the
# write, at the moment it happens, so it does not depend on a guard looking in time. A node with
# no lease table, or no lease row, is not refused.
# Usage: lease::install_write_check CONTAINER TABLE
lease::install_write_check() {
  local container="${1:?container required}"
  local table="${2:?table required}"
  local sql="${LEASE_CHECK_FUNCTION_SQL}; drop trigger if exists fence_write on ${table};"

  [[ "${table}" =~ ${LEASE_TABLE_PATTERN} ]] || die 2 "not a valid table name: ${table}"
  sql+=" create trigger fence_write before insert or update or delete or truncate on ${table}"
  sql+=' for each statement execute function fence_check()'
  log INFO "CHANGE: ${container} refuses writes to ${table} once its lease has run out"
  database::run "${container}" <<< "${sql}" > /dev/null
}

# Take the write check off a table (safe to repeat).
# Usage: lease::remove_write_check CONTAINER TABLE
lease::remove_write_check() {
  local container="${1:?container required}"
  local table="${2:?table required}"

  [[ "${table}" =~ ${LEASE_TABLE_PATTERN} ]] || die 2 "not a valid table name: ${table}"
  log INFO "CHANGE: ${container} stops checking the lease on ${table}"
  database::run "${container}" <<< "drop trigger if exists fence_write on ${table}" > /dev/null
}
