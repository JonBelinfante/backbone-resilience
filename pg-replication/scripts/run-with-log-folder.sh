#!/usr/bin/env bash
# script-kind: executable
# Purpose: Run a command with one shared run-log folder, so every script it starts logs there.
# Usage: run-with-log-folder.sh [-h | --help] [--merge] -- COMMAND [ARGUMENT ...]
# Requires: bash cat date mkdir mktemp rm
# Exit codes: 0 the command succeeded, 1 it failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: RUN_LOG_DIR is where the shared run folder is created; it defaults to the temporary
# directory and must exist.
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
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
Usage: run-with-log-folder.sh [-h | --help] [--merge] -- COMMAND [ARGUMENT ...]

Creates a new run folder (run-<UTC time>.<random>) inside RUN_LOG_DIR and runs COMMAND with
RUN_LOG_DIR pointing at it. Every script that COMMAND starts, however deeply, then writes its
run log into that one folder instead of scattering files. Afterwards it prints the folder.

  --merge  also print the merged timeline of the whole run (see merge-run-logs.sh)

Example:
  run-with-log-folder.sh --merge -- bash scripts/test-failover-roundtrip.sh

Environment: RUN_LOG_DIR is the folder the run folder is created in (default: temporary directory).

Exit codes: 0 the command succeeded, 1 it failed, 2 usage or configuration error
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

# Run the command with RUN_LOG_DIR set to the shared folder and wait for it; fail if it fails.
run_command() {
  log INFO 'running the command with the shared run folder'
  local folder="${1:?folder required}"
  local -a command=(env "RUN_LOG_DIR=${folder}" "${@:2}")
  local pid

  "${command[@]}" &
  pid=$!
  if ! wait "${pid}"; then
    return 1
  fi
}

# Create the shared folder (named from a placeholder file that is removed on exit), run the
# command in it, then say where the logs went and merge them when asked.
run_in_new_folder() {
  log INFO 'creating the shared run folder'
  local merge="${1:?merge flag required}"
  local stamp
  local marker
  local folder
  local outcome='passed'

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  marker="$(mktemp "${RUN_LOG_DIR}/run-${stamp}.XXXXXX")"
  CLEANUP_PATHS+=("${marker}")
  folder="${marker}.d"
  mkdir -- "${folder}"
  log INFO "CHANGE: created ${folder}"
  if ! run_command "${folder}" "${@:2}"; then
    outcome='failed'
  fi
  printf '\nrun logs: %s\n' "${folder}"
  if [[ "${merge}" == 'yes' ]]; then
    bash "${SCRIPT_DIR}merge-run-logs.sh" --dir "${folder}"
  fi
  [[ "${outcome}" == 'passed' ]]
}

# Script entry point.
main() {
  local merge='no'

  require_commands bash cat date mkdir mktemp rm
  start_run_log

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --merge)
        merge='yes'
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

  (( $# > 0 )) || die 2 'no command to run: pass it after -- (try --help)'
  run_in_new_folder "${merge}" "$@" || die 1 'the command failed (its logs are in the run folder)'
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
