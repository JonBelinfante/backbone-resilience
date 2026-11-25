#!/usr/bin/env bash
# script-kind: executable
# Purpose: Run the lint, document and failover round-trip checks, one line per result.
# Usage: run-all-checks.sh [-h | --help] [--skip-roundtrip]
# Requires: cat mktemp tail
# Exit codes: 0 every check passed, 1 a check failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: BASHCHECK_WRAPPER and UP_PULL_POLICY are passed on to the checks they belong to.
# TEMP_DIR is where each check's output is kept until the run ends (default: temporary directory).
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly FAILURE_TAIL_LINES=15

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: run-all-checks.sh [-h | --help] [--skip-roundtrip]

Runs the checks and prints one line per result: PASS or FAIL, then the check's name.
A failed check also prints the last lines of its output. Each check's full output
goes to a temporary file that is removed afterwards.

  lint       lint-scripts.sh: bash syntax, shellcheck, the Bash standard (needs BASHCHECK_WRAPPER)
  docs       check-docs.sh: relative links resolve, and named functions exist and are cited correctly
  python     check-python.sh: the house Python standard (ruff, mypy, pytest) and its own fixtures
  hygiene    check-hygiene.sh: calls only in libraries, loopback ports, no secret values
  timeline   check-run-timeline.sh: a merged run timeline is ordered and well formed
  roundtrip  test-failover-roundtrip.sh: the 17-step failover test (needs the stack up)

Options:
  --skip-roundtrip  run the lint check only

Environment: TEMP_DIR is where each check's output is kept (default: temporary directory).
RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 every check passed, 1 a check failed, 2 usage or configuration error
USAGE
}

# Run one check: print PASS or FAIL with its name, and the output tail when it fails.
run_check() {
  local label="${1:?label required}"
  local -a command=("${@:2}")
  local output_file

  output_file="$(mktemp "${TEMP_DIR}/${SCRIPT_NAME}-output.XXXXXX")"
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
  if ! run_check docs bash "${SCRIPT_DIR}check-docs.sh"; then
    failures=$(( failures + 1 ))
  fi
  if ! run_check python bash "${SCRIPT_DIR}check-python.sh"; then
    failures=$(( failures + 1 ))
  fi
  if ! run_check hygiene bash "${SCRIPT_DIR}check-hygiene.sh"; then
    failures=$(( failures + 1 ))
  fi
  if ! run_check timeline bash "${SCRIPT_DIR}check-run-timeline.sh"; then
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
  start_run_log "$@"

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
  require_commands cat mktemp tail
  run_checks "${run_roundtrip}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
