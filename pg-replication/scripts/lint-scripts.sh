#!/usr/bin/env bash
# script-kind: executable
# Purpose: Check every shell script in the repository against the Bash standard.
# Usage: lint-scripts.sh [-h | --help]
# Requires: bash cat date find mktemp python3 rm shellcheck sort
# Exit codes: 0 all clean, 1 problems found, 2 usage or configuration error, 3 required tool missing
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

# Environment: BASHCHECK_WRAPPER is required (checked in check_environment); see usage.
# RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly BASHCHECK_WRAPPER="${BASHCHECK_WRAPPER:-}"
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
readonly REPO_ROOT="${0%"${0##*/}"}../.."
readonly EXIT_MISSING_TOOL=3
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
Usage: lint-scripts.sh [-h | --help]

Check every shell script in the repository (every *.sh file outside .git and
logs) with three checks, and report each as PASS or FAIL:

  1. bash syntax: bash -n parses each file without running it.
  2. shellcheck: static analysis, following sourced files.
  3. the Bash standard: the bash-standard plugin's check.py, which verifies the
     checker's SHA-256 before running the deterministic standards checker.

Nothing is changed. There is no automatic fix: a formatter such as shfmt writes
whitespace that the Bash standard forbids, so it is not used.

Environment:
  BASHCHECK_WRAPPER  the bash-standard plugin's bin directory (required)
  RUN_LOG_DIR  directory for this run's log file, which must exist
               (default: temporary directory)

Exit codes: 0 all clean, 1 problems found, 2 usage or configuration error,
3 required tool missing
USAGE
}

# Fail early if a required environment value or a required tool is missing.
check_environment() {
  local tool

  if [[ -z "${BASHCHECK_WRAPPER}" ]]; then
    die 2 'BASHCHECK_WRAPPER must be set'
  fi
  for tool in python3 shellcheck; do
    if ! command -v "${tool}" > /dev/null; then
      die "${EXIT_MISSING_TOOL}" "'${tool}' is not installed (shellcheck: brew install shellcheck)"
    fi
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

# Print the path of every shell script in the repository, one per line.
list_shell_scripts() {
  find "${REPO_ROOT}" -name '*.sh' -not -path '*/.git/*' -not -path '*/logs/*' | sort
}

# Report the result of one check as PASS or FAIL, on the screen and in the run log.
# Usage: report PASS|FAIL LABEL
report() {
  local result="${1:?result required}"
  local label="${2:?label required}"

  if [[ "${result}" == 'PASS' ]]; then
    log INFO "PASS: ${label}"
  else
    log WARN "FAIL: ${label}"
  fi
  printf '%s: %s\n' "${result}" "${label}"
}

# bash -n parses each file without running it. Returns 1 if any file has a syntax error.
check_syntax() {
  local file
  local failed='no'

  for file in "$@"; do
    if ! bash -n "${file}"; then
      log ERROR "syntax error in ${file}"
      failed='yes'
    fi
  done
  if [[ "${failed}" == 'yes' ]]; then
    report FAIL 'bash syntax'
    return 1
  fi
  report PASS 'bash syntax'
}

# Static analysis of the given scripts with shellcheck, following sourced files.
check_shellcheck() {
  if shellcheck -x "$@"; then
    report PASS 'shellcheck'
  else
    report FAIL 'shellcheck'
    return 1
  fi
}

# Check the given scripts against the Bash standard with bashcheck.
check_standard() {
  if python3 "${BASHCHECK_WRAPPER}/check.py" --plan --root "${REPO_ROOT}" "$@"; then
    report PASS 'bash standard'
  else
    report FAIL 'bash standard'
    return 1
  fi
}

# Run the three checks over the given scripts; stop with status 1 if any of them fails.
lint_scripts() {
  local problems=0

  check_syntax "$@" || problems=$(( problems + 1 ))
  check_shellcheck "$@" || problems=$(( problems + 1 ))
  check_standard "$@" || problems=$(( problems + 1 ))
  if (( problems > 0 )); then
    die 1 "${problems} check(s) failed"
  fi
}

# Script entry point.
main() {
  local listing
  local -a scripts=()

  start_run_log

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
  check_environment

  listing="$(list_shell_scripts)"
  if [[ -n "${listing}" ]]; then
    mapfile -t scripts <<< "${listing}"
  fi
  (( ${#scripts[@]} > 0 )) || die 1 "no shell scripts found under ${REPO_ROOT}"

  lint_scripts "${scripts[@]}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
