#!/usr/bin/env bash
# script-kind: executable
# Purpose: Run the lint check and the failover round trip, printing one line per result.
# Usage: run-all-checks.sh [-h | --help] [--skip-roundtrip]
# Requires: cat date mktemp rm tail
# Exit codes: 0 every check passed, 1 a check failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: BASHCHECK_WRAPPER and UP_PULL_POLICY are passed on to the checks they belong to.
# RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly FAILURE_TAIL_LINES=15
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

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: run-all-checks.sh [-h | --help] [--skip-roundtrip]

Runs the checks and prints one line per result: PASS or FAIL, then the check's name.
A failed check also prints the last lines of its output. Each check's full output
goes to a temporary file that is removed afterwards.

  lint       lint-scripts.sh: bash syntax, shellcheck and the Bash standard (needs BASHCHECK_WRAPPER)
  roundtrip  test-failover-roundtrip.sh: the 17-step failover test (needs the stack up)

Options:
  --skip-roundtrip  run the lint check only

Environment: RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 every check passed, 1 a check failed, 2 usage or configuration error
USAGE
}

# Fail early if a required command is missing.
require_commands() {
  local cmd

  for cmd in "$@"; do
    command -v "${cmd}" > /dev/null || die 1 "missing required command: ${cmd}"
  done
}

# Create this run's log file in RUN_LOG_DIR and record the start.
start_run_log() {
  local stamp

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$(mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-${stamp}.XXXXXX")"
  log INFO "started ${SCRIPT_NAME}"
}

# Record how the run ended, then remove temporary files created by this script.
cleanup() {
  local status="${?}"

  log INFO "finished with status ${status}"
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    rm -f -- "${CLEANUP_PATHS[@]}"
  fi
}

# Run one check: print PASS or FAIL with its name, and the output tail when it fails.
run_check() {
  local label="${1:?label required}"
  local -a command=("${@:2}")
  local output_file

  output_file="$(mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-output.XXXXXX")"
  CLEANUP_PATHS+=("${output_file}")
  log INFO "running check ${label}"
  if "${command[@]}" > "${output_file}" 2>&1; then
    printf 'PASS %s\n' "${label}"
    return 0
  fi
  printf 'FAIL %s (last %d lines of its output follow)\n' "${label}" "${FAILURE_TAIL_LINES}"
  tail -n "${FAILURE_TAIL_LINES}" "${output_file}"
  return 1
}

# Run the checks in order and return the number that failed as the exit status.
run_checks() {
  log INFO 'running the checks'
  local run_roundtrip="${1:?run_roundtrip required}"
  local failures=0

  if ! run_check lint bash "${SCRIPT_DIR}lint-scripts.sh"; then
    failures=$(( failures + 1 ))
  fi
  if [[ "${run_roundtrip}" == 'yes' ]]; then
    if ! run_check roundtrip bash "${SCRIPT_DIR}test-failover-roundtrip.sh"; then
      failures=$(( failures + 1 ))
    fi
  fi
  if (( failures > 0 )); then
    die 1 "${failures} check(s) failed"
  fi
  printf 'ALL PASSED\n'
}

# Script entry point.
main() {
  local run_roundtrip='yes'

  require_commands cat date mktemp rm tail
  start_run_log

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --skip-roundtrip)
        run_roundtrip='no'
        shift
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
  run_checks "${run_roundtrip}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
