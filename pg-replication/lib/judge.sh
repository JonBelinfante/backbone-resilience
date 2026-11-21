# script-kind: library
# Purpose: Judge saved recovery trials against their targets: PASS, or FAIL and the reason.
# Usage: source "${SCRIPT_DIR}../lib/judge.sh", then call judge::case and judge::failures
# Requires: none
# Depends: measure
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly JUDGE_NO_RESULTS='FAIL: no results'

# Print PASS, or FAIL, for a clean stop that must lose nothing, or PASS for a crash.
# Usage: judge::loss_in_stop RESULTS SCENARIO
judge::loss_in_stop() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lost

  lost="$(measure::max "${results}" "${scenario}" 0 acked_missing)"
  if [[ "${scenario}" == 'stop' && "${lost}" != '0' ]]; then
    printf 'FAIL: %s acknowledged writes lost in a clean stop\n' "${lost}"
  else
    printf 'PASS\n'
  fi
}

# Print PASS, or FAIL and the reason, for a stop or crash case against its RTO target.
# Usage: judge::outage RESULTS SCENARIO TARGET_SECONDS
judge::outage() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local target="${3:?target required}"
  local outage
  local open
  local limit

  outage="$(measure::max "${results}" "${scenario}" 0 longest_outage_ms)"
  open="$(measure::max "${results}" "${scenario}" 0 open_outage)"
  limit=$(( ($(measure::max "${results}" "${scenario}" 0 decision_delay) + target) * 1000 ))
  if [[ "${outage}" == 'n/a' ]]; then
    printf '%s\n' "${JUDGE_NO_RESULTS}"
  elif (( open > 0 )); then
    printf 'FAIL: the prober never wrote again\n'
  elif (( outage > limit )); then
    printf 'FAIL: outage %s ms is over %s ms\n' "${outage}" "${limit}"
  else
    judge::loss_in_stop "${results}" "${scenario}"
  fi
}

# Print PASS, or FAIL and the reason, for an async or control case: the lag must show as loss.
# Usage: judge::loss RESULTS SCENARIO LAG
judge::loss() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local lost

  lost="$(measure::max "${results}" "${scenario}" "${lag}" acked_missing)"
  if [[ "${lost}" == 'n/a' ]]; then
    printf '%s\n' "${JUDGE_NO_RESULTS}"
  elif [[ "${scenario}" == 'async' && "${lag}" == '0' ]]; then
    printf 'PASS (recorded, no target at lag 0)\n'
  elif (( lost > 0 )); then
    printf 'PASS (most lost in a trial: %s)\n' "${lost}"
  else
    printf 'FAIL: no loss seen, so the measurement cannot see loss\n'
  fi
}

# Print the reason if committed rows are missing after a crash, otherwise nothing.
# Usage: judge::committed RESULTS SCENARIO LAG
judge::committed() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local missing

  missing="$(measure::max "${results}" "${scenario}" "${lag}" committed_missing)"
  if [[ "${missing}" != '0' ]]; then
    printf '%s committed rows are missing after the crash' "${missing}"
  fi
}

# Print PASS, or FAIL and the reason, for the checks one crash-matrix case adds to the common ones.
# Usage: judge::extra RESULTS SCENARIO LAG TARGET_SECONDS
judge::extra() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local target="${4:?target required}"
  local value
  local limit=$(( (lag + target) * 1000 ))
  local problem=''

  case "${scenario}" in
    midtx)
      value="$(measure::max "${results}" "${scenario}" "${lag}" uncommitted)"
      [[ "${value}" == '0' ]] || problem="${value} uncommitted rows survived the crash"
      problem="${problem:-$(judge::committed "${results}" "${scenario}" "${lag}")}"
      ;;
    checkpoint)
      value="$(measure::max "${results}" "${scenario}" "${lag}" interrupted)"
      [[ "${value}" != '0' ]] || problem='no trial crashed inside a checkpoint: nothing was tested'
      problem="${problem:-$(judge::committed "${results}" "${scenario}" "${lag}")}"
      ;;
    standby-crash)
      value="$(measure::max "${results}" "${scenario}" "${lag}" failed)"
      [[ "${value}" == '0' ]] || problem="${value} writes failed while only the standby was down"
      ;;
    primary-restart)
      value="$(measure::max "${results}" "${scenario}" "${lag}" longest_outage_ms)"
      (( value <= limit )) || problem="restart outage ${value} ms is over ${limit} ms"
      ;;
    *)
      problem=''
      ;;
  esac
  if [[ -n "${problem}" ]]; then
    printf 'FAIL: %s\n' "${problem}"
  else
    printf 'PASS\n'
  fi
}

# Print PASS, or FAIL and the reason, for a crash-matrix case: nothing acknowledged lost, no index
# damage, the prober writing again, then the checks that belong to the case.
# Usage: judge::durable RESULTS SCENARIO LAG TARGET_SECONDS
judge::durable() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local target="${4:?target required}"
  local lost
  local damaged
  local open
  local problem=''

  lost="$(measure::max "${results}" "${scenario}" "${lag}" acked_missing)"
  if [[ "${lost}" == 'n/a' ]]; then
    printf '%s\n' "${JUDGE_NO_RESULTS}"
    return 0
  fi
  damaged="$(measure::max "${results}" "${scenario}" "${lag}" index_failures)"
  open="$(measure::max "${results}" "${scenario}" "${lag}" open_outage)"
  if (( lost > 0 )); then
    problem="${lost} acknowledged writes lost"
  elif (( damaged > 0 )); then
    problem='an index check found damage'
  elif (( open > 0 )); then
    problem='the prober never wrote again'
  else
    problem=''
  fi
  if [[ -n "${problem}" ]]; then
    printf 'FAIL: %s\n' "${problem}"
  else
    judge::extra "${results}" "${scenario}" "${lag}" "${target}"
  fi
}

# Print PASS, or FAIL and the reason, for one case against its target.
# Usage: judge::case RESULTS SCENARIO LAG TARGET_SECONDS
judge::case() {
  local results="${1:?results required}"
  local scenario="${2:?scenario required}"
  local lag="${3:?lag required}"
  local target="${4:?target required}"
  local lost

  case "${scenario}" in
    stop | crash)
      judge::outage "${results}" "${scenario}" "${target}"
      ;;
    sync)
      lost="$(measure::max "${results}" sync "${lag}" acked_missing)"
      if [[ "${lost}" == '0' ]]; then
        printf 'PASS\n'
      else
        printf 'FAIL: %s acknowledged writes lost under sync\n' "${lost}"
      fi
      ;;
    async | control)
      judge::loss "${results}" "${scenario}" "${lag}"
      ;;
    *)
      judge::durable "${results}" "${scenario}" "${lag}" "${target}"
      ;;
  esac
}

# Print how many cases missed their target.
# Usage: judge::failures RESULTS CASES TARGET_SECONDS
judge::failures() {
  local results="${1:?results required}"
  local cases="${2:?cases required}"
  local target="${3:?target required}"
  local line
  local failures=0

  while IFS= read -r line; do
    if [[ "$(judge::case "${results}" "${line% *}" "${line#* }" "${target}")" == FAIL* ]]; then
      failures=$(( failures + 1 ))
    fi
  done <<< "${cases}"
  printf '%d\n' "${failures}"
}
