#!/usr/bin/env bash
# script-kind: executable
# Purpose: Check the Python code against the house Python standard, and check the checkers.
# Usage: check-python.sh [-h | --help]
# Requires: cat find grep
# Exit codes: 0 all clean, 1 a check failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
shopt -s nullglob
export LC_COLLATE=C

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly FIXTURES='python-standard/fixtures'
readonly GOOD_FILES="${FIXTURES}/good_example.py ${FIXTURES}/test_good_example.py"
readonly WAIVER_PATTERN='noqa|type: ignore'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/pytools.sh
source "${SCRIPT_DIR}../lib/pytools.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: check-python.sh [-h | --help]

Check the Python code against the house Python standard (docs/python-standard.md) with ruff
(style, naming, docstrings, security, complexity), mypy in strict mode (types) and pytest, all
at fixed versions in a container. Then refuse waiver comments (noqa, type: ignore), and check
the checkers themselves: the good example in python-standard/fixtures must pass, and every
bad_*.py fixture must fail with the rule named on its first line ("# expect: ruff RULE",
"# expect: mypy CODE" or "# expect: waiver"). The Python under services/ is checked when it exists.
The first run builds the tools image, which needs network access to the Python package index.

Exit codes: 0 all clean, 1 a check failed, 2 usage or configuration error
USAGE
}

# Print the Python files and folders to check: the good example and, if present, services/.
# Usage: python_targets ROOT
python_targets() {
  log INFO 'listing what to check'
  local root="${1:?root required}"

  printf '%s\n' "${GOOD_FILES// /$'\n'}"
  if [[ -d "${root}/services" ]]; then
    printf 'services\n'
  fi
}

# Run ruff, mypy and pytest on the targets; fail on the first one that complains.
# Usage: check_code ROOT
check_code() {
  log INFO 'checking the Python code'
  local root="${1:?root required}"
  local targets
  local -a paths=()

  targets="$(python_targets "${root}")"
  if [[ -n "${targets}" ]]; then
    mapfile -t paths <<< "${targets}"
  fi
  pytools::run "${root}" ruff check "${paths[@]}"
  pytools::run "${root}" ruff format --check "${paths[@]}"
  pytools::run "${root}" mypy "${paths[@]}"
  pytools::run "${root}" pytest -q "${FIXTURES}/test_good_example.py"
  if [[ -n "$(find "${root}/services" -name 'test_*.py' 2> /dev/null)" ]]; then
    pytools::run "${root}" pytest -q services
  fi
}

# Fail if any Python file carries a waiver comment; the fixture that exists to show it is exempt.
# Usage: check_no_waivers ROOT
check_no_waivers() {
  log INFO 'checking for waiver comments'
  local root="${1:?root required}"
  local services="${root}/services"
  local standard="${root}/python-standard"
  local found

  local -a options=(--recursive --line-number --extended-regexp)

  options+=(--include='*.py' --exclude='bad_waiver.py')
  options+=("${WAIVER_PATTERN}" "${services}" "${standard}")
  if found="$(grep "${options[@]}" 2> /dev/null)"; then
    die 1 "waiver comments are not allowed: ${found}"
  fi
  log INFO 'no waiver comments'
}

# Check one bad fixture: it must fail the tool its first line names, with the rule named there.
# Usage: check_fixture_fails ROOT FILE
check_fixture_fails() {
  log INFO 'checking that a bad fixture is caught'
  local root="${1:?root required}"
  local file="${2:?file required}"
  local expectation
  local tool
  local token
  local output=''
  local caught='no'

  IFS= read -r expectation < "${root}/${file}"
  expectation="${expectation#\# expect: }"
  tool="${expectation%% *}"
  token="${expectation#* }"
  case "${tool}" in
    ruff)
      if ! output="$(pytools::run "${root}" ruff check "${file}" 2>&1)"; then
        caught='yes'
      fi
      ;;
    mypy)
      if ! output="$(pytools::run "${root}" mypy "${file}" 2>&1)"; then
        caught='yes'
      fi
      ;;
    *)
      if output="waiver $(grep -E "${WAIVER_PATTERN}" "${root}/${file}")"; then
        caught='yes'
      fi
      ;;
  esac
  if [[ "${caught}" == 'yes' && "${output}" == *"${token}"* ]]; then
    printf 'caught  %s: %s\n' "${file##*/}" "${expectation}"
  else
    die 1 "NOT CAUGHT: ${file} should fail with ${expectation}"
  fi
}

# Check the checkers: every bad fixture must be caught.
# Usage: check_the_checkers ROOT
check_the_checkers() {
  log INFO 'checking the checkers'
  local root="${1:?root required}"
  local file

  for file in "${root}/${FIXTURES}"/bad_*.py; do
    check_fixture_fails "${root}" "${FIXTURES}/${file##*/}"
  done
}

# Script entry point.
main() {
  local root
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
  require_commands cat find grep
  root="$(cd "${SCRIPT_DIR}../.." && pwd -P)"
  pytools::ensure_image "${root}/python-standard"
  check_code "${root}"
  check_no_waivers "${root}"
  check_the_checkers "${root}"
  printf 'PASS: the Python code meets the standard and the checkers catch every bad fixture\n'
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
