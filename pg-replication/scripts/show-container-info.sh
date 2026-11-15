#!/usr/bin/env bash
# script-kind: executable
# Purpose: Print the container name of a database, or whether a container is running.
# Usage: show-container-info.sh [-h | --help] (--database primary|standby | --container NAME)
# Requires: cat date mktemp rm
# Exit codes: 0 answer printed, 1 failure (for example no such container), 2 usage error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them. RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"

# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"

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
Usage: show-container-info.sh [-h | --help] (--database primary|standby | --container NAME)

Command-line wrapper over lib/container.sh. Tells you the container name for a database,
or whether a named container is running. Other scripts import container.sh instead of
calling this one; it is here for use by hand.

  --database primary|standby  print the container name for that database
  --container NAME            print true if the container is running, false if not

Exits 1 when the container does not exist.

Environment: PRIMARY_CONTAINER (pg-primary), STANDBY_CONTAINER (pg-standby) and
RUN_LOG_DIR (the run log directory, default: temporary directory).

Exit codes: 0 answer printed, 1 failure (for example no such container), 2 usage error
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

# Answer the one question that was asked; exactly one of database and container is given.
answer_question() {
  log INFO 'answering the question'
  local database="${1-}"
  local container="${2-}"

  if [[ -n "${database}" && -z "${container}" ]]; then
    container::name_of "${database}" "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"
  elif [[ -z "${database}" && -n "${container}" ]]; then
    container::is_running "${container}"
  else
    die 2 'give exactly one of --database or --container (try --help)'
  fi
}

# Script entry point.
main() {
  local database=''
  local container=''

  require_commands cat date mktemp rm
  start_run_log

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --database)
        (( $# >= 2 )) || die 2 '--database needs a value'
        database="${2}"
        shift 2
        ;;
      --container)
        (( $# >= 2 )) || die 2 '--container needs a value'
        container="${2}"
        shift 2
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
  answer_question "${database}" "${container}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
