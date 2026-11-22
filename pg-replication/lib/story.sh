# script-kind: library
# Purpose: Tell a test's story: timestamped lines on the terminal and in the run log, and checks.
# Usage: source "${SCRIPT_DIR}../lib/story.sh", then call story::narrate and the other functions
# Requires: none
# Depends: container database
# Exit codes: none (the functions return, or call die of the script that imported them)

# Tell the story: print one line (UTC time in ms, script name, message) and log the message.
# Assumes the importing script supplies log.
story::narrate() {
  local message="${1:?message required}"
  local now="${EPOCHREALTIME}"
  local fraction="${now#*[.,]}"
  local stamp

  TZ=UTC printf -v stamp '%(%Y-%m-%dT%H:%M:%S)T' "${now%%[.,]*}"
  printf '%s.%sZ %s %s\n' "${stamp}" "${fraction:0:3}" "${0##*/}" "${message}"
  log INFO "${message}"
}

# Narrate each line read from standard input as returned data.
story::narrate_stream() {
  local line

  while IFS= read -r line; do
    story::narrate "  => ${line}"
  done
}

# Run a command, narrate the command line, and stream its output into the story.
story::run_logged() {
  local -a command=("$@")
  local text

  text="$(printf '%q ' "${command[@]}")"
  story::narrate "RUN ${text}"
  "${command[@]}" 2>&1 | story::narrate_stream
}

# Narrate a query and the data it returned.
story::narrate_query() {
  local container="${1:?container required}"
  local sql="${2:?sql required}"
  local result="${3-}"

  story::narrate "SQL on ${container}: ${sql}"
  story::narrate_stream <<< "${result:-(no rows)}"
}

# Pass if the two values are equal, otherwise narrate the failure and stop the importing script.
story::expect_equal() {
  local label="${1:?label required}"
  local actual="${2-}"
  local expected="${3-}"

  if [[ "${actual}" != "${expected}" ]]; then
    story::narrate "FAIL: ${label} (expected '${expected}', got '${actual}')"
    die 1 "FAIL: ${label} (expected '${expected}', got '${actual}')"
  fi
  story::narrate "PASS: ${label} (got '${actual}')"
}

# Run a SQL statement that changes data, narrating the SQL and the command tag it returns.
story::run_statement() {
  local container="${1:?container required}"
  local sql="${2:?sql required}"

  story::narrate "SQL on ${container}: ${sql}"
  database::run "${container}" <<< "${sql}" 2>&1 | story::narrate_stream
}

# Run a read-only query, narrate the SQL and the data returned, then check the answer.
story::expect_query() {
  local container="${1:?container required}"
  local sql="${2:?sql required}"
  local expected="${3-}"
  local actual

  actual="$(database::bare "${container}" <<< "${sql}")"
  story::narrate_query "${container}" "${sql}" "${actual}"
  story::expect_equal "${container} returned the expected data" "${actual}" "${expected}"
}

# Pass if the container is stopped.
story::expect_stopped() {
  local container="${1:?container required}"
  local running

  running="$(container::is_running "${container}")"
  story::narrate "container::is_running ${container} => ${running}"
  story::expect_equal "${container} is stopped" "${running}" 'false'
}

# Drop every table in a schema: the database library builds the statements, then they are run.
# Usage: story::drop_all_tables CONTAINER SCHEMA
story::drop_all_tables() {
  local container="${1:?container required}"
  local schema="${2:?schema required}"
  local drops

  drops="$(database::drop_all_sql "${container}" "${schema}")"
  story::narrate_query "${container}" "drop every table in ${schema}" "${drops}"
  if [[ -n "${drops}" ]]; then
    story::run_statement "${container}" "${drops}"
  fi
}

# Pass if a whole number is between two limits (inclusive), otherwise narrate the failure and stop.
# Usage: story::expect_between LABEL VALUE LOW HIGH
story::expect_between() {
  local label="${1:?label required}"
  local value="${2:?value required}"
  local low="${3:?low limit required}"
  local high="${4:?high limit required}"

  if (( value < low || value > high )); then
    story::narrate "FAIL: ${label}: ${value} is outside ${low} to ${high}"
    die 1 "FAIL: ${label}: ${value} is outside ${low} to ${high}"
  fi
  story::narrate "PASS: ${label}: ${value} (limits ${low} to ${high})"
}

# Print the time as whole milliseconds since the epoch.
story::now_milliseconds() {
  local now="${EPOCHREALTIME}"
  local whole="${now%%[.,]*}"
  local fraction="${now#*[.,]}"

  printf '%s\n' "$(( whole * 1000 + 10#${fraction:0:3} ))"
}
