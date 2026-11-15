#!/usr/bin/env bash
# script-kind: executable
# Purpose: Merge the run logs of one run folder into a single timeline, with script names added.
# Usage: merge-run-logs.sh [-h | --help] [--dir FOLDER]
# Requires: cat find sed sort
# Exit codes: 0 timeline printed, 1 failure (for example no run folder), 2 usage error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

# Environment: FOLDER_PARENT is where run folders are looked for when --dir is not given
# (default: RUN_LOG_DIR).
readonly FOLDER_PARENT="${FOLDER_PARENT:-${RUN_LOG_DIR}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"

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

Environment: FOLDER_PARENT is where the newest run folder is looked for (default: RUN_LOG_DIR).
RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 timeline printed, 1 failure (for example no run folder), 2 usage error
USAGE
}

# Print the newest run folder in RUN_LOG_DIR (the names start with a UTC time).
find_newest_folder() {
  log INFO 'looking for the newest run folder'
  local listing
  local -a folders

  listing="$(find "${FOLDER_PARENT}" -maxdepth 1 -type d -name 'run-*' | sort)"
  if [[ -n "${listing}" ]]; then
    mapfile -t folders <<< "${listing}"
    printf '%s\n' "${folders[-1]}"
  else
    die 1 "no run-* folder found in ${FOLDER_PARENT}"
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
  start_run_log "$@"

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
  require_commands cat find sed sort
  if [[ -z "${folder}" ]]; then
    folder="$(find_newest_folder)"
  fi
  [[ -d "${folder}" ]] || die 1 "not a folder: ${folder}"
  print_timeline "${folder}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
