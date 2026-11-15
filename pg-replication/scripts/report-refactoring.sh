#!/usr/bin/env bash
# script-kind: executable
# Purpose: Report duplicated functions, script reuse and script sizes, to guide refactoring.
# Usage: report-refactoring.sh [-h | --help] [--mode MODE] [--show NAME]
# Requires: awk cat diff find mktemp sed sort
# Exit codes: 0 report written, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

# Environment: TEMP_DIR is where the comparison file is written (default: the temporary directory).
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly ROOT_DIR="${SCRIPT_DIR}.."
readonly BASELINE_PATH="${ROOT_DIR}/refactor-baseline.txt"
readonly NAME_PATTERN='^[a-z_0-9]+$'
readonly AWK_PROGRAM="${SCRIPT_DIR}report-refactoring.awk"
readonly TEMPLATE_FUNCTIONS='log die on_error usage start_run_log cleanup main'
readonly RUNTIME_FUNCTIONS='require_commands require_integer'
readonly MANDATED_FUNCTIONS="${TEMPLATE_FUNCTIONS} ${RUNTIME_FUNCTIONS} check_environment"
readonly LINE_LIMIT=400
readonly LINE_WARNING=300
readonly SIMILARITY_PERCENT=60
readonly MINIMUM_STATEMENTS=5

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: report-refactoring.sh [-h | --help] [--mode MODE] [--show NAME]

Read-only report that finds duplicated code, reuse and oversized files across the shell
scripts, to decide what to refactor. It never changes a script.

Modes (default all):
  duplicates  function bodies that are identical, drifted apart or similar (standard ones skipped)
  usage       each script's purpose and usage line, and which other scripts it mentions
  size        lines per script against the 400-line limit (NEAR above 300, OVER above 400)
  all         the three reports above
  brief       one tagged line per finding: IDENTICAL, DRIFTED, SIMILAR or SIZE
  baseline    save the brief report (no line numbers) to refactor-baseline.txt
  changes     compare with that baseline: "<" fixed since then, ">" new
  --show NAME print every copy of function NAME and how the copies differ
Workflow: brief, then --show NAME, refactor, then changes. Functions named a::b are not seen.

Environment: TEMP_DIR is where the comparison file is written (default: temporary directory).
RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 report written, 1 failure, 2 usage or configuration error
USAGE
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
  current_file="$(mktemp "${TEMP_DIR}/${SCRIPT_NAME}-current.XXXXXX")"
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
  start_run_log "$@"
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
  require_commands awk cat diff find mktemp sed sort
  write_reports "${mode}" "$(list_shell_scripts)" "${name}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
