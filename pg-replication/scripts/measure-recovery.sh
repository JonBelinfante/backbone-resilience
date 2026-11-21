#!/usr/bin/env bash
# script-kind: executable
# Purpose: Run failure trials to measure RPO and RTO, save the results, and write the report.
# Usage: measure-recovery.sh [-h | --help] [--scenarios LIST] [--results FILE]
# Requires: bash cat
# Exit codes: 0 every target met, 1 a target missed or a trial failed, 2 usage or setup error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: MEASURE_TRIALS is the number of trials per case; MEASURE_LAGS the seconds of lag
# for the asynchronous cases (comma separated); MEASURE_SYNC_LAG the lag for the sync and control
# cases. DECISION_DELAY (seconds between the failure and the promotion) and RTO_TARGET_SECONDS are
# read by the trial and the report; set them in the environment to change them.
readonly MEASURE_TRIALS="${MEASURE_TRIALS:-3}"
readonly MEASURE_LAGS="${MEASURE_LAGS:-0,1,3}"
readonly MEASURE_SYNC_LAG="${MEASURE_SYNC_LAG:-3}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly DEFAULT_RESULTS="${SCRIPT_DIR}../docs/recovery-results.txt"
readonly DEFAULT_SCENARIOS='stop,crash,async,sync,control'

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: measure-recovery.sh [-h | --help] [--scenarios LIST] [--results FILE]

Run failure trials with run-recovery-trial.sh, save one result line per trial in FILE (default
docs/recovery-results.txt, overwritten), then run write-recovery-report.sh, which judges the
targets and writes docs/recovery-report.md. It exits 1 if a trial fails or a target is missed.
Scenarios, comma separated, default stop,crash,async,sync,control:
  stop, crash   a clean stop or a crash of the writer, then promotion: the RTO
  async         the standby isolated for MEASURE_LAGS seconds, then a crash: the RPO under async
  sync          the same under synchronous replication: no acknowledged write may be lost
  control       sync at commit level local: the loss must come back (the control for sync)
Each trial takes about 30 seconds and changes the databases: use only the throwaway stack.

Environment: MEASURE_TRIALS (3), MEASURE_LAGS (0,1,3), MEASURE_SYNC_LAG (3), DECISION_DELAY (0),
RTO_TARGET_SECONDS (30), RUN_LOG_DIR.

Exit codes: 0 every target met, 1 a target missed or a trial failed, 2 usage or configuration error
USAGE
}

# Fail early if a setting is not a whole number.
check_environment() {
  log INFO 'checking the settings'
  require_integer MEASURE_TRIALS "${MEASURE_TRIALS}"
  require_integer MEASURE_SYNC_LAG "${MEASURE_SYNC_LAG}"
}

# Print the lags, one per line, that a scenario is run with.
# Usage: lags_for SCENARIO
lags_for() {
  log INFO 'listing the lags'
  local scenario="${1:?scenario required}"

  case "${scenario}" in
    stop | crash)
      printf '0\n'
      ;;
    async)
      printf '%s\n' "${MEASURE_LAGS//,/$'\n'}"
      ;;
    sync | control)
      printf '%s\n' "${MEASURE_SYNC_LAG}"
      ;;
    *)
      die 2 "unknown scenario: ${scenario}"
      ;;
  esac
}

# Run one trial and print what it printed on standard output; its error output is not kept.
# Usage: run_trial SCENARIO LAG
run_trial() {
  log INFO 'running one trial'
  local scenario="${1:?scenario required}"
  local lag="${2:?lag required}"

  bash "${SCRIPT_DIR}run-recovery-trial.sh" --scenario "${scenario}" --lag "${lag}" 2> /dev/null
}

# Run the trials of one case and append each result line to the results file.
# Usage: run_case SCENARIO LAG RESULTS_FILE
run_case() {
  log INFO 'running one case'
  local scenario="${1:?scenario required}"
  local lag="${2:?lag required}"
  local results="${3:?results file required}"
  local trial=1
  local output
  local line

  while (( trial <= MEASURE_TRIALS )); do
    printf 'trial %d of %d: %s, lag %s s\n' "${trial}" "${MEASURE_TRIALS}" "${scenario}" "${lag}"
    output="$(run_trial "${scenario}" "${lag}")" || die 1 "a trial failed: ${scenario}, lag ${lag}"
    while IFS= read -r line; do
      if [[ "${line}" == RESULT* ]]; then
        printf '%s\n' "${line}" >> "${results}"
        printf '  %s\n' "${line#RESULT }"
      fi
    done <<< "${output}"
    trial=$(( trial + 1 ))
  done
}

# Run every case of the scenarios, in order.
# Usage: run_scenarios SCENARIOS RESULTS_FILE
run_scenarios() {
  log INFO 'running the scenarios'
  local scenarios="${1:?scenarios required}"
  local results="${2:?results file required}"
  local scenario
  local lag
  local lags
  local -a names=()
  local -a lag_list=()

  if [[ -n "${scenarios}" ]]; then
    mapfile -t names <<< "${scenarios//,/$'\n'}"
  fi
  for scenario in "${names[@]}"; do
    lags="$(lags_for "${scenario}")"
    if [[ -n "${lags}" ]]; then
      mapfile -t lag_list <<< "${lags}"
    fi
    for lag in "${lag_list[@]}"; do
      run_case "${scenario}" "${lag}" "${results}"
    done
  done
}

# Run the scenarios, saving the results, then write the report.
# Usage: measure_and_report SCENARIOS RESULTS_FILE
measure_and_report() {
  log INFO 'measuring and reporting'
  local scenarios="${1:?scenarios required}"
  local results="${2:?results file required}"

  printf '' > "${results}"
  run_scenarios "${scenarios}" "${results}"
  bash "${SCRIPT_DIR}write-recovery-report.sh" --results "${results}"
}

# Script entry point.
main() {
  local scenarios="${DEFAULT_SCENARIOS}"
  local results="${DEFAULT_RESULTS}"
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --scenarios)
        (( $# >= 2 )) || die 2 '--scenarios needs a value'
        scenarios="${2}"
        shift 2
        ;;
      --results)
        (( $# >= 2 )) || die 2 '--results needs a value'
        results="${2}"
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
  check_environment
  require_commands bash cat
  measure_and_report "${scenarios}" "${results}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
