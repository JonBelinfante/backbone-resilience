# script-kind: library
# Purpose: Read the result lines of run-recovery-trial.sh and work out minimum, median and maximum.
# Usage: source "${SCRIPT_DIR}../lib/measure.sh", then call measure::field, measure::values ...
# Requires: git sort
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly MEASURE_EXCLUDE_REPORT=':!docs/recovery-report.md'
readonly MEASURE_EXCLUDE_RESULTS=':!docs/recovery-results.txt'

# Print the value of a name=value pair in a result line, or nothing if the line has no such pair.
# Usage: measure::field LINE NAME
measure::field() {
  local line=" ${1-} "
  local name="${2:?name required}"

  if [[ "${line}" == *" ${name}="* ]]; then
    line="${line#*" ${name}="}"
    printf '%s\n' "${line%% *}"
  fi
}

# Print the values of one name from every result line of a scenario and lag, one per line.
# Usage: measure::values RESULTS_FILE SCENARIO LAG NAME
measure::values() {
  local results="${1:?results file required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local name="${4:?name required}"
  local line

  while IFS= read -r line; do
    [[ "$(measure::field "${line}" scenario)" == "${scenario}" ]] || continue
    [[ "$(measure::field "${line}" lag)" == "${lag}" ]] || continue
    measure::field "${line}" "${name}"
  done < "${results}"
}

# Read whole numbers, one per line, from standard input and print: minimum median maximum.
# Prints n/a n/a n/a when there are none. The median of an even count is the upper middle value.
measure::min_median_max() {
  local sorted
  local -a numbers=()

  sorted="$(sort -n)"
  if [[ -n "${sorted}" ]]; then
    mapfile -t numbers <<< "${sorted}"
    printf '%s %s %s\n' "${numbers[0]}" "${numbers[$(( ${#numbers[@]} / 2 ))]}" "${numbers[-1]}"
  else
    printf 'n/a n/a n/a\n'
  fi
}

# Print how many result lines there are for a scenario and lag.
# Usage: measure::count RESULTS_FILE SCENARIO LAG
measure::count() {
  local results="${1:?results file required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local output
  local -a found=()

  output="$(measure::values "${results}" "${scenario}" "${lag}" attempts)"
  if [[ -n "${output}" ]]; then
    mapfile -t found <<< "${output}"
  fi
  printf '%d\n' "${#found[@]}"
}

# Print each case that has results, once, as "scenario lag", in the order first seen.
# Usage: measure::cases RESULTS_FILE
measure::cases() {
  local results="${1:?results file required}"
  local line
  local key
  local -A seen=()

  while IFS= read -r line; do
    key="$(measure::field "${line}" scenario) $(measure::field "${line}" lag)"
    if [[ -z "${seen[${key}]-}" ]]; then
      seen["${key}"]=1
      printf '%s\n' "${key}"
    fi
  done < "${results}"
}

# Print "minimum median maximum" of a name over the trials of a case, separated by spaces.
# Usage: measure::summary RESULTS SCENARIO LAG NAME
measure::summary() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local name="${4:?name required}"

  measure::values "${results}" "${scenario}" "${lag}" "${name}" | measure::min_median_max
}

# Print "minimum / median / maximum" of a name over the trials of a case.
# Usage: measure::triple RESULTS SCENARIO LAG NAME
measure::triple() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local name="${4:?name required}"
  local -a parts=()

  read -r -a parts <<< "$(measure::summary "${results}" "${scenario}" "${lag}" "${name}")"
  printf '%s / %s / %s\n' "${parts[0]}" "${parts[1]}" "${parts[2]}"
}

# Print the median of a name over the trials of a case.
# Usage: measure::median RESULTS SCENARIO LAG NAME
measure::median() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local name="${4:?name required}"
  local -a parts=()

  read -r -a parts <<< "$(measure::summary "${results}" "${scenario}" "${lag}" "${name}")"
  printf '%s\n' "${parts[1]}"
}

# Print the largest value of a name over the trials of a case.
# Usage: measure::max RESULTS SCENARIO LAG NAME
measure::max() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local name="${4:?name required}"
  local -a parts=()

  read -r -a parts <<< "$(measure::summary "${results}" "${scenario}" "${lag}" "${name}")"
  printf '%s\n' "${parts[2]}"
}

# Print one markdown table row made of the arguments.
measure::row() {
  local cell

  printf '|'
  for cell in "$@"; do
    printf ' %s |' "${cell}"
  done
  printf '\n'
}

# Print the short hash of the commit a repository is at, with "plus uncommitted changes" if the
# working tree differs. The report and results files are left out of that check: they are what
# is being written. Prints unknown outside a git repository.
# Usage: measure::commit_label REPOSITORY_DIR
measure::commit_label() {
  local folder="${1:?repository folder required}"
  local label
  local changes

  if ! label="$(git -C "${folder}" rev-parse --short HEAD 2> /dev/null)"; then
    printf 'unknown\n'
    return 0
  fi
  changes="$(git -C "${folder}" status --porcelain -- . \
    "${MEASURE_EXCLUDE_REPORT}" \
    "${MEASURE_EXCLUDE_RESULTS}")"
  if [[ -n "${changes}" ]]; then
    label+=' plus uncommitted changes'
  fi
  printf '%s\n' "${label}"
}
