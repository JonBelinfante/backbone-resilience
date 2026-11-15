#!/usr/bin/env bash
# script-kind: executable
# Purpose: Check every shell script in the repository against the Bash standard.
# Usage: lint-scripts.sh [-h | --help]
# Requires: bash cat find grep python3 shellcheck sort
# Exit codes: 0 all clean, 1 problems found, 2 usage or configuration error, 3 required tool missing
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

# Environment: BASHCHECK_WRAPPER is required (checked in check_environment); see usage.
readonly BASHCHECK_WRAPPER="${BASHCHECK_WRAPPER:-}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly REPO_ROOT="${SCRIPT_DIR}../.."
readonly EXIT_MISSING_TOOL=3

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"

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

# Print the path of every shell script in the repository, one per line.
list_shell_scripts() {
  log INFO 'list shell scripts'
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

# Run shellcheck on each file. The standard's own text is exempt from two warnings that are
# intended there: runtime.sh reads SCRIPT_NAME, which the importing script sets (SC2154), and a
# copy of trap_signals expands a loop variable into a trap on purpose (SC2064). A file gets the
# exemption only if it carries that standard text, so the exemption cannot hide anything else.
check_shellcheck() {
  local file
  local failed='no'
  local -a exempt=()

  for file in "$@"; do
    exempt=()
    if [[ "${file##*/}" == 'runtime.sh' ]]; then
      exempt+=(-e SC2154)
    fi
    if grep -q '^trap_signals() {' "${file}"; then
      exempt+=(-e SC2064)
    fi
    if ! shellcheck -x "${exempt[@]}" "${file}"; then
      failed='yes'
    fi
  done
  if [[ "${failed}" == 'yes' ]]; then
    report FAIL 'shellcheck'
    return 1
  fi
  report PASS 'shellcheck'
}

# Run the Bash standard checker on the given files.
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
  log INFO 'linting the shell scripts'
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
  check_environment
  require_commands bash cat find grep python3 shellcheck sort

  listing="$(list_shell_scripts)"
  if [[ -n "${listing}" ]]; then
    mapfile -t scripts <<< "${listing}"
  fi
  (( ${#scripts[@]} > 0 )) || die 1 "no shell scripts found under ${REPO_ROOT}"

  lint_scripts "${scripts[@]}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
