#!/usr/bin/env bash
# script-kind: executable
# Purpose: Judge saved recovery trials against their targets and write a markdown report.
# Usage: write-recovery-report.sh [-h | --help] [--results FILE] [--report FILE]
# Requires: cat
# Exit codes: 0 every target met, 1 a target missed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: RTO_TARGET_SECONDS is the longest outage allowed beyond the decision delay of the
# trials; PRIMARY_CONTAINER holds the writer the PostgreSQL version is read from.
readonly RTO_TARGET_SECONDS="${RTO_TARGET_SECONDS:-30}"
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly DEFAULT_RESULTS="${SCRIPT_DIR}../docs/recovery-results.txt"
readonly DEFAULT_REPORT="${SCRIPT_DIR}../docs/recovery-report.md"
readonly MONTH_BUDGET_MS=26000

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# shellcheck source=../lib/measure.sh
source "${SCRIPT_DIR}../lib/measure.sh"
# shellcheck source=../lib/judge.sh
source "${SCRIPT_DIR}../lib/judge.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: write-recovery-report.sh [-h | --help] [--results FILE] [--report FILE]

Read the result lines saved by measure-recovery.sh (default docs/recovery-results.txt), judge each
case against its target, and write a markdown report (default docs/recovery-report.md). Targets:
  stop, crash   outage within the decision delay plus RTO_TARGET_SECONDS; stop loses nothing
  async         at lag above 0 the isolated lag must show up as lost writes (a measurement that
                cannot see loss proves nothing); at lag 0 the numbers are recorded only
  sync          no acknowledged write lost, in every trial
  control       sync at commit level local: loss must come back (the control for sync)
It exits 1 if any target is missed.

Environment: RTO_TARGET_SECONDS (30), PRIMARY_CONTAINER (pg-primary), RUN_LOG_DIR.

Exit codes: 0 every target met, 1 a target missed, 2 usage or configuration error
USAGE
}

# Fail early if a setting is not a whole number.
check_environment() {
  log INFO 'checking the settings'
  require_integer RTO_TARGET_SECONDS "${RTO_TARGET_SECONDS}"
}

# Print the report's title, when and where it was made, and what the numbers mean.
report_header() {
  log INFO 'writing the report header'
  local stamp
  local commit
  local version

  TZ=UTC printf -v stamp '%(%Y-%m-%d %H:%M:%S UTC)T' -1
  commit="$(measure::commit_label "${SCRIPT_DIR}..")"
  version="$(database::bare "${PRIMARY_CONTAINER}" <<< 'show server_version')"
  printf '# Recovery measurements: RPO and RTO\n\n'
  printf 'Written by write-recovery-report.sh on %s, at commit %s.\n' "${stamp}" "${commit}"
  printf 'PostgreSQL %s, two nodes in Docker Compose on one machine.\n' "${version}"
  printf 'A write about every 100 ms. RTO target: %s s beyond the decision delay.\n' \
    "${RTO_TARGET_SECONDS}"
  printf 'This file is overwritten by every run.\n\n'
  printf '**RPO observed**: writes the client was told were committed that are missing on\n'
  printf 'the node that took over. **RTO observed**: first failed write to first success,\n'
  printf 'as the client sees it. A write that failed but is present is in doubt, not lost.\n\n'
}

# Print what a case is held to, in a few words.
# Usage: verdict_target SCENARIO
verdict_target() {
  local scenario="${1:?scenario required}"

  case "${scenario}" in
    stop)
      printf 'outage within the RTO target, nothing lost\n'
      ;;
    crash)
      printf 'outage within the RTO target\n'
      ;;
    async)
      printf 'the lag shows up as loss (lag 0: recorded only)\n'
      ;;
    sync)
      printf '**no acknowledged write lost**\n'
      ;;
    standby-crash)
      printf 'the standby catches up; no write fails\n'
      ;;
    primary-restart)
      printf 'restart within the target; nothing lost; indexes intact\n'
      ;;
    midtx)
      printf 'uncommitted rows gone, committed rows kept; indexes intact\n'
      ;;
    checkpoint)
      printf 'the crash lands in a checkpoint; nothing lost; indexes intact\n'
      ;;
    *)
      printf 'loss reappears at commit level local\n'
      ;;
  esac
}

# Print the verdict table: one row per case, its target and PASS or FAIL.
# Usage: report_verdicts RESULTS CASES
report_verdicts() {
  log INFO 'writing the verdicts'
  local results="${1:?results required}"
  local cases="${2:?cases required}"
  local line
  local target
  local verdict

  printf '## Verdict\n\n'
  measure::row Case 'Lag (s)' Target Result
  measure::row --- --- --- ---
  while IFS= read -r line; do
    target="$(verdict_target "${line% *}")"
    verdict="$(judge::case "${results}" "${line% *}" "${line#* }" "${RTO_TARGET_SECONDS}")"
    measure::row "${line% *}" "${line#* }" "${target}" "${verdict}"
  done <<< "${cases}"
  printf '\n'
}

# Print the RTO table: the outage of the stop and crash cases and its share of the monthly budget.
# Usage: report_rto RESULTS CASES
report_rto() {
  log INFO 'writing the RTO table'
  local results="${1:?results required}"
  local cases="${2:?cases required}"
  local line
  local median
  local tenths
  local share
  local trials
  local spread

  printf '## RTO: how long the client could not write\n\n'
  measure::row Case Trials 'Outage ms (min / median / max)' 'Median share of a month at 99.999%'
  measure::row --- --- --- ---
  while IFS= read -r line; do
    [[ "${line% *}" == 'stop' || "${line% *}" == 'crash' ]] || continue
    median="$(measure::median "${results}" "${line% *}" "${line#* }" longest_outage_ms)"
    tenths=$(( median * 1000 / MONTH_BUDGET_MS ))
    share="$(( tenths / 10 )).$(( tenths % 10 ))% of $(( MONTH_BUDGET_MS / 1000 )) s"
    trials="$(measure::count "${results}" "${line% *}" "${line#* }")"
    spread="$(measure::triple "${results}" "${line% *}" "${line#* }" longest_outage_ms)"
    measure::row "${line% *}" "${trials}" "${spread}" "${share}"
  done <<< "${cases}"
  printf '\nThe outage includes the decision delay: subtract it to get the system time.\n\n'
}

# Print the RPO table: lost, in doubt and blocked time for the cases that isolate the standby.
# Usage: report_rpo RESULTS CASES
report_rpo() {
  log INFO 'writing the RPO table'
  local results="${1:?results required}"
  local cases="${2:?cases required}"
  local line
  local -a heads=()
  local -a cells=()

  printf '## RPO: writes acknowledged and then lost\n\n'
  heads=(Case 'Lag (s)' Trials 'Acknowledged (median)')
  heads+=('Lost (min / median / max)' 'In doubt (max)' 'Outage ms (min / median / max)')
  measure::row "${heads[@]}"
  measure::row --- --- --- --- --- --- ---
  while IFS= read -r line; do
    [[ "${line% *}" == 'stop' || "${line% *}" == 'crash' ]] && continue
    ! measure::is_matrix "${line% *}" || continue
    cells=("${line% *}" "${line#* }")
    cells+=("$(measure::count "${results}" "${cells[0]}" "${cells[1]}")")
    cells+=("$(measure::median "${results}" "${cells[0]}" "${cells[1]}" acked)")
    cells+=("**$(measure::triple "${results}" "${cells[0]}" "${cells[1]}" acked_missing)**")
    cells+=("$(measure::max "${results}" "${cells[0]}" "${cells[1]}" in_doubt)")
    cells+=("$(measure::triple "${results}" "${cells[0]}" "${cells[1]}" longest_outage_ms)")
    measure::row "${cells[@]}"
  done <<< "${cases}"
  printf '\nUnder sync the outage is the time writes were blocked while the standby was cut off:\n'
  printf 'the price of RPO 0.\n\n'
}

# Print the crash-matrix table: what survived a crash with no failover.
# Usage: report_matrix RESULTS CASES
report_matrix() {
  log INFO 'writing the crash matrix'
  local results="${1:?results required}"
  local cases="${2:?cases required}"
  local line
  local name
  local -a heads=()
  local -a cells=()

  printf '## Crash matrix: a node killed and restarted, no failover\n\n'
  heads=(Case 'Down (s)' Trials 'Lost' 'Failed writes' 'Outage ms (min / median / max)')
  heads+=('Index damage' 'Uncommitted rows kept' 'Committed rows missing')
  heads+=('Crashes inside a checkpoint')
  measure::row "${heads[@]}"
  measure::row --- --- --- --- --- --- --- --- --- ---
  while IFS= read -r line; do
    measure::is_matrix "${line% *}" || continue
    cells=("${line% *}" "${line#* }")
    cells+=("$(measure::count "${results}" "${cells[0]}" "${cells[1]}")")
    for name in acked_missing failed; do
      cells+=("$(measure::max "${results}" "${cells[0]}" "${cells[1]}" "${name}")")
    done
    cells+=("$(measure::triple "${results}" "${cells[0]}" "${cells[1]}" longest_outage_ms)")
    for name in index_failures uncommitted committed_missing; do
      cells+=("$(measure::max "${results}" "${cells[0]}" "${cells[1]}" "${name}")")
    done
    if [[ "${cells[0]}" == 'checkpoint' ]]; then
      name="$(measure::sum "${results}" "${cells[0]}" "${cells[1]}" interrupted)"
      cells+=("${name} of ${cells[2]}")
    else
      cells+=('n/a')
    fi
    measure::row "${cells[@]}"
  done <<< "${cases}"
  printf '\nEach figure is the worst over the trials. Index damage is from amcheck.\n\n'
}

# Print every trial as a table row.
# Usage: report_trials RESULTS
report_trials() {
  log INFO 'writing the trials'
  local results="${1:?results required}"
  local line
  local name
  local -a cells=()

  printf '## Every trial\n\n'
  measure::row Case 'Lag (s)' Acknowledged Lost 'In doubt' 'Outage ms'
  measure::row --- --- --- --- --- ---
  while IFS= read -r line; do
    cells=()
    for name in scenario lag acked acked_missing in_doubt longest_outage_ms; do
      cells+=("$(measure::field "${line}" "${name}")")
    done
    measure::row "${cells[@]}"
  done < "${results}"
  printf '\n'
}

# Print what these numbers do not say.
report_limits() {
  log INFO 'writing the limits'
  printf '## Limits\n\n'
  printf -- '- One machine and a process crash (SIGKILL), not a power cut.\n'
  printf -- '- Lag is injected by isolating the standby from the network, so the loss is the\n'
  printf '  writes of the lag window. Gradual latency needs a network fault tool (GAP-11).\n'
  printf -- '- RTO is the time until a write succeeds somewhere, seen through the Docker host.\n'
  printf '  There is no router or client library, and promotion is a script, not a controller.\n'
  printf -- '- About 10 writes a second: loss is counted in tens of writes, not thousands.\n'
  printf -- '- The crash matrix kills the container (SIGKILL); a power cut is not tested.\n'
  printf -- '- Where a case has no target the number is recorded only.\n\n'
  printf 'Reproduce: bash scripts/measure-recovery.sh (its --help lists the settings).\n'
}

# Judge the results and write the whole report.
# Usage: write_report RESULTS REPORT
write_report() {
  log INFO 'writing the report'
  local results="${1:?results required}"
  local report="${2:?report file required}"
  local cases
  local failures

  [[ -s "${results}" ]] || die 2 "no results in ${results}: run measure-recovery.sh first"
  cases="$(measure::cases "${results}")"
  {
    report_header
    report_verdicts "${results}" "${cases}"
    report_rto "${results}" "${cases}"
    report_rpo "${results}" "${cases}"
    report_matrix "${results}" "${cases}"
    report_trials "${results}"
    report_limits
  } > "${report}"
  failures="$(judge::failures "${results}" "${cases}" "${RTO_TARGET_SECONDS}")"
  printf 'report written to %s: %s target(s) missed\n' "${report}" "${failures}"
  (( failures == 0 )) || die 1 "${failures} target(s) missed: see the report"
}

# Script entry point.
main() {
  local results="${DEFAULT_RESULTS}"
  local report="${DEFAULT_REPORT}"
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --results)
        (( $# >= 2 )) || die 2 '--results needs a value'
        results="${2}"
        shift 2
        ;;
      --report)
        (( $# >= 2 )) || die 2 '--report needs a value'
        report="${2}"
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
  require_commands cat
  write_report "${results}" "${report}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
