# script-kind: library
# Purpose: Tell a test's story: timestamped lines on the terminal and in the run log, and checks.
# Usage: source "${SCRIPT_DIR}../lib/story.sh", then call story::narrate and the other functions
# Requires: die log
# Exit codes: none (the functions return, or call die of the script that imported them)

# Tell the story: print one line (UTC time in ms, script name, message) and log the message.
# The importing script must define log, which writes to its run log.
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
