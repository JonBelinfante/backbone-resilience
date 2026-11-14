#!/usr/bin/env bash
# script-kind: executable
# Purpose: Merge the run logs of one run folder into a single timeline, with script names added.
# Usage: merge-run-logs.sh [-h | --help] [--dir FOLDER]
# Requires: cat date find mktemp rm sed sort
# Exit codes: 0 timeline printed, 1 failure (for example no run folder), 2 usage error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

# Environment: RUN_LOG_DIR is where run folders are looked for when --dir is not given; it defaults
# to the temporary directory and must exist.
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
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
Usage: merge-run-logs.sh [-h | --help] [--dir FOLDER]

Read-only. Reads every run log in one run folder (made by run-with-log-folder.sh) and prints
one timeline: each line is "timestamp script LEVEL message", sorted by timestamp. The script
name comes from the log's file name. Lines with equal timestamps keep each file's own order.

  --dir FOLDER  the run folder to merge (default: the newest run-* folder in RUN_LOG_DIR)

Run log timestamps are UTC to the millisecond, and the sort uses them as written. Lines with
the same millisecond keep each file's own order.

Environment: RUN_LOG_DIR is where the newest run folder is looked for (default: temporary directory).

Exit codes: 0 timeline printed, 1 failure (for example no run folder), 2 usage error
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

# Print the newest run folder in RUN_LOG_DIR (the names start with a UTC time).
find_newest_folder() {
  log INFO 'looking for the newest run folder'
  local listing
  local -a folders

  listing="$(find "${RUN_LOG_DIR}" -maxdepth 1 -type d -name 'run-*' | sort)"
  if [[ -n "${listing}" ]]; then
    mapfile -t folders <<< "${listing}"
    printf '%s\n' "${folders[-1]}"
  else
    die 1 "no run-* folder found in ${RUN_LOG_DIR}"
  fi
}

# Print one run log with the script name (from the file name) inserted after the timestamp.
print_with_script_name() {
  local file="${1:?file required}"
  local base="${file##*/}"
  local name="${base%%-2[0-9][0-9][0-9][0-9][0-9][0-9][0-9]T*}"

  sed -E "s/^([^ ]+) /\1 ${name} /" "${file}"
}

# Print every run log in the folder, one after another.
print_all_logs() {
  log INFO 'reading the run logs'
  local folder="${1:?folder required}"
  local listing
  local -a files
  local file

  listing="$(find "${folder}" -maxdepth 1 -type f | sort)"
  if [[ -n "${listing}" ]]; then
    mapfile -t files <<< "${listing}"
    for file in "${files[@]}"; do
      print_with_script_name "${file}"
    done
  else
    die 1 "no run logs in ${folder}"
  fi
}

# Merge the folder's logs into one timeline sorted by timestamp.
print_timeline() {
  log INFO 'merging the run logs'
  local folder="${1:?folder required}"
  local lines

  lines="$(print_all_logs "${folder}")"
  sort -s -k1,1 <<< "${lines}"
}

# Script entry point.
main() {
  local folder=''

  require_commands cat date find mktemp rm sed sort
  start_run_log

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --dir)
        (( $# >= 2 )) || die 2 '--dir needs a value'
        folder="${2}"
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
  if [[ -z "${folder}" ]]; then
    folder="$(find_newest_folder)"
  fi
  [[ -d "${folder}" ]] || die 1 "not a folder: ${folder}"
  print_timeline "${folder}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
