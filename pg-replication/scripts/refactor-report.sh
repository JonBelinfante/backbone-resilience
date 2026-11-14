#!/usr/bin/env bash
# script-kind: executable
# Purpose: Report duplicated functions, script reuse and script sizes, to guide refactoring.
# Usage: refactor-report.sh [-h | --help] [--mode MODE] [--show NAME]
# Requires: awk cat date diff find mktemp rm sed sort
# Exit codes: 0 report written, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

# Environment: RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly ROOT_DIR="${SCRIPT_DIR}.."
readonly BASELINE_PATH="${ROOT_DIR}/refactor-baseline.txt"
readonly NAME_PATTERN='^[a-z_0-9]+$'
readonly AWK_PROGRAM="${SCRIPT_DIR}refactor-report.awk"
readonly TEMPLATE_FUNCTIONS='log die on_error usage start_run_log cleanup main require_commands'
readonly MANDATED_FUNCTIONS="${TEMPLATE_FUNCTIONS} check_environment"
readonly LINE_LIMIT=400
readonly LINE_WARNING=300
readonly SIMILARITY_PERCENT=60
readonly MINIMUM_STATEMENTS=5
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
Usage: refactor-report.sh [-h | --help] [--mode MODE] [--show NAME]

Read-only report over the shell scripts, to guide refactoring. Changes no script.

Modes (default all):
  duplicates  identical, drifted and similar function bodies (the standard's own functions,
              such as log, die, usage and check_environment, are left out)
  usage       purpose, usage line and mentioned scripts of each script (reuse map)
  size        line count per script against the 400-line limit
  all         the three reports above
  brief       one tagged line per finding (duplicates, flagged sizes), no headings
  baseline    save the brief report, without line numbers, as the baseline file
  changes     show what differs from the baseline (< fixed, > new)
--show NAME   print every definition of function NAME and how the copies differ

Environment: RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 report written, 1 failure, 2 usage or configuration error
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

# List every shell script under the repository root, one path per line, sorted.
list_shell_scripts() {
  log INFO 'listing the shell scripts'
  local listing

  listing="$(find "${ROOT_DIR}" -name '*.sh' -not -path '*/logs/*' | sort)"
  [[ -n "${listing}" ]] || die 1 "no shell scripts found under ${ROOT_DIR}"
  printf '%s\n' "${listing}"
}

# Print the groups of one kind (identical, samename or similar), one tagged line each.
list_groups() {
  local kind="${1:?kind required}"
  local records="${2:?records required}"
  local -a settings=(-v "threshold=${SIMILARITY_PERCENT}" -v "minimum=${MINIMUM_STATEMENTS}")

  awk -v "mode=${kind}" "${settings[@]}" -f "${AWK_PROGRAM}" <<< "${records}" | sort -r
}

# Print the groups of one kind under the current heading, or say none were found.
group_records() {
  local kind="${1:?kind required}"
  local records="${2:?records required}"
  local output

  output="$(list_groups "${kind}" "${records}")"
  if [[ -z "${output}" ]]; then
    printf '  none found\n'
  else
    printf '%s\n' "${output}"
  fi
}

# Print one record per function (name, location, body) for the scripts given.
list_function_records() {
  local -a scripts=("$@")
  local -a settings=(-v mode=functions -v "ignore=${MANDATED_FUNCTIONS}")

  awk "${settings[@]}" -f "${AWK_PROGRAM}" "${scripts[@]}"
}

# Print one SIZE line per script, largest first; only_flagged=yes leaves out the fine ones.
size_lines() {
  local only_flagged="${1:?only_flagged required}"
  local -a scripts=("${@:2}")
  local -a settings=(-v mode=size -v "limit=${LINE_LIMIT}" -v "warn=${LINE_WARNING}")

  if [[ "${only_flagged}" == 'yes' ]]; then
    settings+=(-v flagged=1)
  fi
  awk "${settings[@]}" -f "${AWK_PROGRAM}" "${scripts[@]}" | sort -k3,3 -rn
}

# Report function bodies that repeat across the scripts: identical, drifted and similar.
report_duplicates() {
  log INFO 'reporting duplicated functions'
  local -a scripts=("$@")
  local records

  records="$(list_function_records "${scripts[@]}")"
  printf '\n== Identical function bodies (merge into one reusable script) ==\n'
  group_records identical "${records}"
  printf '\n== Same name, different bodies (copies that drifted apart) ==\n'
  group_records samename "${records}"
  printf '\n== Similar bodies, %d%%+ alike (candidates to share) ==\n' "${SIMILARITY_PERCENT}"
  group_records similar "${records}"
}

# Report each script's purpose and usage line, and which other scripts it mentions.
report_usage() {
  log INFO 'reporting the reuse map'
  local -a scripts=("$@")
  local names=''
  local script

  for script in "${scripts[@]}"; do
    names+=" ${script##*/}"
  done
  printf '\n== Reuse map: what each script does and which scripts it mentions ==\n'
  awk -v mode=header -v names="${names}" -f "${AWK_PROGRAM}" "${scripts[@]}"
}

# Report each script's line count against the file-length limit, largest first.
report_size() {
  log INFO 'reporting script sizes'
  local -a scripts=("$@")

  printf '\n== Script sizes (limit %d, NEAR above %d) ==\n' "${LINE_LIMIT}" "${LINE_WARNING}"
  size_lines no "${scripts[@]}"
}

# Print the brief report: one tagged line per finding and nothing else.
brief_lines() {
  local -a scripts=("$@")
  local kind
  local records

  records="$(list_function_records "${scripts[@]}")"
  for kind in identical samename similar; do
    list_groups "${kind}" "${records}"
  done
  size_lines yes "${scripts[@]}"
}

# Print the brief report without line numbers, so moved code does not look like a change.
stable_brief() {
  local -a scripts=("$@")

  brief_lines "${scripts[@]}" | sed -E 's/:[0-9]+//g'
}

# Print every definition of one function and how the copies differ.
report_show() {
  log INFO 'showing the definitions of one function'
  local name="${1:?name required}"
  local -a scripts=("${@:2}")

  if [[ ! "${name}" =~ ${NAME_PATTERN} ]]; then
    die 2 "function name must be lower snake case, got: ${name}"
  fi
  awk -v mode=show -v "target=${name}" -f "${AWK_PROGRAM}" "${scripts[@]}"
}

# Save the stable brief report as the baseline that later runs compare with.
save_baseline() {
  log INFO 'saving the baseline'
  local -a scripts=("$@")

  log INFO "CHANGE: writing ${BASELINE_PATH}"
  stable_brief "${scripts[@]}" > "${BASELINE_PATH}"
  printf 'baseline saved: %s\n' "${BASELINE_PATH}"
}

# Show what changed since the baseline: < no longer found, > newly found.
report_changes() {
  log INFO 'comparing with the baseline'
  local -a scripts=("$@")
  local current_file
  local changes

  if [[ ! -f "${BASELINE_PATH}" ]]; then
    die 1 "no baseline at ${BASELINE_PATH}: run with --mode baseline first"
  fi
  current_file="$(mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-current.XXXXXX")"
  CLEANUP_PATHS+=("${current_file}")
  stable_brief "${scripts[@]}" > "${current_file}"
  if changes="$(diff "${BASELINE_PATH}" "${current_file}")"; then
    printf 'no changes since the baseline\n'
  else
    printf '%s\n' "${changes}"
  fi
}

# Run the modes that read the scripts without the full reports: brief, show, baseline, changes.
write_tracking() {
  local mode="${1:?mode required}"
  local name="${2-}"
  local -a scripts=("${@:3}")

  case "${mode}" in
    brief)
      stable_brief "${scripts[@]}"
      ;;
    show)
      report_show "${name}" "${scripts[@]}"
      ;;
    baseline)
      save_baseline "${scripts[@]}"
      ;;
    changes)
      report_changes "${scripts[@]}"
      ;;
    *)
      die 2 "unknown mode: ${mode} (try --help)"
      ;;
  esac
}

# Write the reports the mode asks for.
write_reports() {
  log INFO 'writing the reports'
  local mode="${1:?mode required}"
  local listing="${2:?listing required}"
  local name="${3-}"
  local -a scripts

  if [[ -n "${listing}" ]]; then
    mapfile -t scripts <<< "${listing}"
  fi
  case "${mode}" in
    duplicates)
      report_duplicates "${scripts[@]}"
      ;;
    usage)
      report_usage "${scripts[@]}"
      ;;
    size)
      report_size "${scripts[@]}"
      ;;
    all)
      report_duplicates "${scripts[@]}"
      report_usage "${scripts[@]}"
      report_size "${scripts[@]}"
      ;;
    *)
      write_tracking "${mode}" "${name}" "${scripts[@]}"
      ;;
  esac
}

# Script entry point.
main() {
  local mode='all'
  local name=''

  require_commands awk cat date diff find mktemp rm sed sort
  start_run_log

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --mode)
        (( $# >= 2 )) || die 2 '--mode needs a value'
        mode="${2}"
        shift 2
        ;;
      --show)
        (( $# >= 2 )) || die 2 '--show needs a function name'
        mode='show'
        name="${2}"
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
  write_reports "${mode}" "$(list_shell_scripts)" "${name}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
