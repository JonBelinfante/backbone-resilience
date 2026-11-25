#!/usr/bin/env bash
# script-kind: executable
# Purpose: Check that a run of two scripts merges into one ordered timeline of millisecond lines.
# Usage: check-run-timeline.sh [-h | --help]
# Requires: cat cut grep mktemp sort
# Exit codes: 0 every check passed, 1 a check failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly LINE_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z '
readonly MIN_LINES=6

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: check-run-timeline.sh [-h | --help]

Run two scripts under one run-log folder (run-with-log-folder.sh --merge) and check the merged
timeline they print:
  1. both scripts appear in it, each with at least a few lines;
  2. every line starts with a millisecond UTC timestamp and a script name;
  3. the timestamps never go backwards.
Read-only apart from the run logs, which go to a temporary folder. Throwaway stack only: the
scripts it runs only read the containers.

Environment: TEMP_DIR, RUN_LOG_DIR.

Exit codes: 0 every check passed, 1 a check failed, 2 usage or configuration error
USAGE
}

# Succeed if the timeline names both scripts, each on at least MIN_LINES lines.
# Usage: check_both_scripts TIMELINE
check_both_scripts() {
  local timeline="${1:?timeline required}"
  local count

  count="$(grep -c 'show-container-info.sh' "${timeline}")"
  (( count >= 2 * MIN_LINES ))
}

# Succeed if every line of the timeline starts with a millisecond timestamp. The only other lines
# allowed are the blank line and the "run logs:" line that run-with-log-folder.sh prints first.
# Usage: check_line_format TIMELINE
check_line_format() {
  local timeline="${1:?timeline required}"
  local total
  local well_formed

  total="$(grep -cvE '^$|^run logs: ' "${timeline}")"
  well_formed="$(grep -cE "${LINE_PATTERN}" "${timeline}")"
  (( total > 0 && total == well_formed ))
}

# Succeed if the timestamps never go backwards (sorting them changes nothing).
# Usage: check_order TIMELINE
check_order() {
  local timeline="${1:?timeline required}"

  grep -E "${LINE_PATTERN}" "${timeline}" |
    cut -d ' ' -f 1 |
    sort -c
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

# Run the three checks on a timeline, print each result, and fail if any check failed.
# Usage: run_checks TIMELINE
run_checks() {
  local timeline="${1:?timeline required}"
  local failures=0

  if check_both_scripts "${timeline}"; then
    print_result 'both scripts are in the merged timeline' pass
  else
    print_result 'both scripts are in the merged timeline' fail
    failures=$(( failures + 1 ))
  fi
  if check_line_format "${timeline}"; then
    print_result 'every line starts with a millisecond timestamp' pass
  else
    print_result 'every line starts with a millisecond timestamp' fail
    failures=$(( failures + 1 ))
  fi
  if check_order "${timeline}"; then
    print_result 'the timestamps never go backwards' pass
  else
    print_result 'the timestamps never go backwards' fail
    failures=$(( failures + 1 ))
  fi
  (( failures == 0 )) || die 1 "${failures} timeline check(s) failed"
}

# Run two scripts under one run-log folder and write the merged timeline to TIMELINE.
# Usage: merge_run SCRATCH_DIR TIMELINE
merge_run() {
  local scratch="${1:?scratch folder required}"
  local timeline="${2:?timeline required}"
  local show_script="${SCRIPT_DIR}show-container-info.sh"
  local run_script="bash '${show_script}' --database primary > /dev/null;"
  local -a merge=(env "RUN_LOG_DIR=${scratch}")

  run_script+=" bash '${show_script}' --database standby > /dev/null"
  merge+=(bash "${SCRIPT_DIR}run-with-log-folder.sh" --merge -- bash -c "${run_script}")
  "${merge[@]}" > "${timeline}" 2> /dev/null
}

# Script entry point.
main() {
  local scratch
  local timeline

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
  require_commands cat cut grep mktemp sort
  scratch="$(mktemp -d "${TEMP_DIR}/timeline.XXXXXX")"
  CLEANUP_PATHS+=("${scratch}")
  timeline="${scratch}/merged.txt"
  merge_run "${scratch}" "${timeline}"
  run_checks "${timeline}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
