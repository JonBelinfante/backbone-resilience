#!/usr/bin/env bash
# script-kind: executable
# Purpose: Check the hygiene rules: calls only in libraries, loopback ports, no secret values.
# Usage: check-hygiene.sh [-h | --help]
# Requires: awk cat git
# Exit codes: 0 every check passed, 1 a check failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly PROJECT_DIR="${SCRIPT_DIR}../.."
readonly COMPOSE_FILE="${SCRIPT_DIR}../docker-compose.yml"
# A direct call to the container or database client: the word at the start of a command, after
# the start of a line, a separator (; | &) or a command substitution. Quoted words do not match.
readonly CALL_PATTERN='(^|[;|&]|[$][(])[[:space:]]*(docker|psql|pgbench)[[:space:]]'
# Secret-looking values that must never be committed: a private key, an AWS key, a GitHub token.
readonly LEAK_KEY_BLOCK='-----BEGIN [A-Z ]*PRIVATE KEY'
readonly LEAK_AWS_KEY='AKIA[0-9A-Z]{16}'
readonly LEAK_GITHUB_VALUE='ghp_[A-Za-z0-9]{36}'
readonly LEAK_PATTERN="${LEAK_KEY_BLOCK}|${LEAK_AWS_KEY}|${LEAK_GITHUB_VALUE}"
# The one committed fixture that holds a fake secret on purpose (it tests the Python checker).
readonly FIXTURE_EXCLUDE=':!python-standard/fixtures/bad_secret.py'
readonly PORT_PATTERN='^[[:space:]]*- "[^"]*:[0-9$]'
readonly LOOPBACK_PATTERN='^[[:space:]]*- "127[.]0[.]0[.]1:'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: check-hygiene.sh [-h | --help]

Check three rules of the repository, one PASS or FAIL line each:
  1. only the libraries call docker, psql or pgbench: a host script in pg-replication/scripts
     that runs one of them directly is a failure (the container-side scripts are not checked);
  2. every published port is bound to 127.0.0.1 in docker-compose.yml;
  3. no tracked file holds a private key, an AWS access key or a GitHub token. The throwaway
     database credentials are documented on purpose and are not checked here.

Exit codes: 0 every check passed, 1 a check failed, 2 usage or configuration error
USAGE
}

# Succeed if no host script calls docker, psql or pgbench directly; the calls found are logged.
check_no_direct_calls() {
  local hits

  local pathspec='pg-replication/scripts/*.sh'

  if hits="$(git -C "${PROJECT_DIR}" grep -nE -e "${CALL_PATTERN}" -- "${pathspec}")"; then
    log WARN "direct calls found: ${hits//$'\n'/ | }"
    return 1
  fi
  return 0
}

# Succeed if the compose file publishes at least one port and every published port is on loopback.
check_loopback_ports() {
  local total
  local loopback

  total="$(awk -v re="${PORT_PATTERN}" '$0 ~ re { n++ } END { print n + 0 }' "${COMPOSE_FILE}")"
  loopback="$(awk -v re="${LOOPBACK_PATTERN}" '$0 ~ re { n++ } END { print n + 0 }' \
    "${COMPOSE_FILE}")"
  (( total > 0 && total == loopback ))
}

# Succeed if no tracked file holds a secret-looking value; the files found are logged.
check_no_secret_values() {
  local hits

  if hits="$(git -C "${PROJECT_DIR}" grep -lE -e "${LEAK_PATTERN}" -- . "${FIXTURE_EXCLUDE}")"; then
    log WARN "files with secret-looking values: ${hits//$'\n'/ }"
    return 1
  fi
  return 0
}

# Print the result of one check: pass or fail, with its name.
# Usage: print_result NAME pass|fail
print_result() {
  local name="${1:?check name required}"
  local outcome="${2:?outcome required}"

  if [[ "${outcome}" == 'pass' ]]; then
    printf 'PASS: %s\n' "${name}"
  else
    printf 'FAIL: %s\n' "${name}"
  fi
}

# Run the three checks in turn, print each result, and fail if any check failed.
run_checks() {
  local failures=0

  if check_no_direct_calls; then
    print_result 'database and container calls only in libraries' pass
  else
    print_result 'database and container calls only in libraries' fail
    failures=$(( failures + 1 ))
  fi
  if check_loopback_ports; then
    print_result 'every published port is bound to loopback' pass
  else
    print_result 'every published port is bound to loopback' fail
    failures=$(( failures + 1 ))
  fi
  if check_no_secret_values; then
    print_result 'no tracked file holds a secret value' pass
  else
    print_result 'no tracked file holds a secret value' fail
    failures=$(( failures + 1 ))
  fi
  (( failures == 0 )) || die 1 "${failures} hygiene check(s) failed"
}

# Script entry point.
main() {
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
  require_commands awk cat git
  run_checks
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
