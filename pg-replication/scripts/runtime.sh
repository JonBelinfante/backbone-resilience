# script-kind: library
# Purpose: The standard's own functions: log, die, error trace, run log, clean-up and checks.
# Requires: date id mktemp mv rm

# Environment: RUN_LOG_DIR defaults to the temporary directory.
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly INTEGER_PATTERN='^[0-9]+$'
declare RUN_LOG=''
declare -a CLEANUP_PATHS=()

# Append a line to the run log and, for WARN and ERROR, to standard error.
log() {
  local level="${1:?level required}"
  local message="${2:?message required}"
  local now="${EPOCHREALTIME}"
  local fraction="${now#*[.,]}"
  local stamp
  local line

  TZ=UTC printf -v stamp '%(%Y-%m-%dT%H:%M:%S)T' "${now%%[.,]*}"
  line="${stamp}.${fraction:0:3}Z ${level} ${message}"
  if [[ -n "${RUN_LOG}" ]]; then
    printf '%s\n' "${line}" >> "${RUN_LOG}"
  fi
  if [[ "${level}" != 'INFO' ]]; then
    printf '%s: %s\n' "${SCRIPT_NAME}" "${line}" >&2
  fi
}

# Log an error, then exit with the given status.
die() {
  local status="${1:?status required}"
  local message="${2:?message required}"

  log ERROR "${message}"
  exit "${status}"
}

# Log where a command failed: its line, the function it was in, and the command itself.
on_error() {
  local status="${?}"
  local line_no="${1:?line required}"
  local command_text="${2:?command required}"
  local where="${FUNCNAME[1]:-main}"

  log ERROR "failed (status ${status}) at line ${line_no} in ${where}: ${command_text}"
}

# Fail early if a required command is missing.
require_commands() {
  local cmd

  for cmd in "$@"; do
    command -v "${cmd}" > /dev/null || die 1 "missing required command: ${cmd}"
  done
}

# Fail early if a value is not a whole number.
require_integer() {
  local name="${1:?name required}"
  local value="${2:?value required}"

  if [[ ! "${value}" =~ ${INTEGER_PATTERN} ]]; then
    die 2 "${name} must be a whole number, got: ${value}"
  fi
}

# Create this run's log file in RUN_LOG_DIR and say which execution it records.
start_run_log() {
  local stamp
  local cmd
  local final
  local user
  local arg
  local names=''
  local others=0

  for cmd in date id mktemp mv; do
    command -v "${cmd}" > /dev/null || die 1 "missing required command: ${cmd}"
  done
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$(mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-${stamp}-$$.XXXXXX")"
  final="${RUN_LOG%.*}.log"
  mv -- "${RUN_LOG}" "${final}"
  RUN_LOG="${final}"
  user="$(id -un 2> /dev/null || id -u)"
  log INFO "started ${SCRIPT_NAME} (process $$)"
  log INFO "user ${user} on host ${HOSTNAME}"
  log INFO "directory ${PWD}, script ${0}"
  for arg in "$@"; do
    if [[ "${arg}" == --* ]]; then
      names+=" ${arg%%=*}"
    elif [[ "${arg}" == -?* ]]; then
      names+=" ${arg:0:2}"
    else
      others=$(( others + 1 ))
    fi
  done
  log INFO "options${names:- none} (${others} other arguments)"
}

# Remove the temporary paths of the run, write the last log line, and say where the log is.
end_run_log() {
  local status="${1:?status required}"

  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    if ! rm -rf -- "${CLEANUP_PATHS[@]:?no paths to remove}"; then
      log WARN 'some temporary paths could not be removed'
    fi
  fi
  if [[ -n "${RUN_LOG}" ]]; then
    log INFO "finished with status ${status} after ${SECONDS} seconds"
    printf 'log: %s\n' "${RUN_LOG}" >&2
  fi
}

# Record how the run ended: the EXIT handler.
cleanup() {
  local status="${?}"

  end_run_log "${status}"
}

# Handle a signal that ends the run: say which one, then stop with the status a shell gives it.
on_signal() {
  local name="${1:?signal name required}"
  local number

  number="$(kill -l "${name}")"
  die "$(( 128 + number ))" "interrupted by SIG${name}"
}

# Install the traps for the signals that end a run (INT, TERM, HUP); call it after the two traps.
trap_signals() {
  local name

  for name in INT TERM HUP; do
    trap "on_signal ${name}" "${name}"
  done
}
