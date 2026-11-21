#!/usr/bin/env bash
# script-kind: executable
# Purpose: Compare a write ledger with the node that survived: lost writes and outage windows.
# Usage: report-ledger.sh [-h | --help] --ledger FILE --node CONTAINER
# Requires: cat comm mktemp
# Exit codes: 0 reported, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

# Environment: TEMP_DIR holds the working files until the run ends (default: temporary directory).
# MARK_US is the moment of the fault, in microseconds since the epoch.
readonly MARK_US="${MARK_US:-0}"
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly SQL_PRESENT="select lpad(seq::text, 8, '0') from probe_ledger order by seq"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: report-ledger.sh [-h | --help] --ledger FILE --node CONTAINER

Read a ledger written by run-write-prober.sh and compare it with the rows in probe_ledger on the
node that survived the failure. Print one name=value line each:
  attempts, acked, failed        what the prober did
  present                        rows found on the node
  acked_missing                  acknowledged writes the node does not hold: LOST WRITES
  in_doubt                       failed attempts whose row is present anyway (not a loss)
  acked_after_mark               acknowledged writes finished at or after MARK_US (the fault)
  missing_after_mark             lost writes among those
  outage_windows                 runs of failed attempts that ended in a success
  longest_outage_ms              first failed attempt to the next success, the longest run
  open_outage                    1 if the prober never succeeded again after a failure

Environment: MARK_US (microseconds since the epoch, default 0), TEMP_DIR, RUN_LOG_DIR.

Exit codes: 0 reported, 1 failure, 2 usage or configuration error
USAGE
}

# Read the ledger: write the sequence numbers of acknowledged, failed and post-mark acknowledged
# attempts to files in the work folder, and print the counts and the outage figures.
# Usage: read_ledger LEDGER WORK_FOLDER MARK
read_ledger() {
  log INFO 'reading the ledger'
  local ledger="${1:?ledger required}"
  local work="${2:?work folder required}"
  local mark="${3:?mark required}"
  local attempts=0 acked=0 failed=0 windows=0 longest=0 last_end=0 open=0
  local line outage_start=''
  local -a fields=()

  while IFS= read -r line; do
    read -r -a fields <<< "${line}"
    attempts=$(( attempts + 1 ))
    last_end="${fields[2]}"
    if [[ "${fields[4]}" == 'ok' ]]; then
      acked=$(( acked + 1 ))
      printf '%s\n' "${fields[0]}" >> "${work}/acked"
      (( last_end < mark )) || printf '%s\n' "${fields[0]}" >> "${work}/after"
      if [[ -n "${outage_start}" ]]; then
        windows=$(( windows + 1 ))
        (( last_end - outage_start <= longest )) || longest=$(( last_end - outage_start ))
        outage_start=''
      fi
    else
      failed=$(( failed + 1 ))
      printf '%s\n' "${fields[0]}" >> "${work}/failed"
      outage_start="${outage_start:-${fields[1]}}"
    fi
  done < "${ledger}"
  if [[ -n "${outage_start}" ]]; then
    open=1
    longest=$(( last_end - outage_start ))
  fi
  printf 'attempts=%d\nacked=%d\nfailed=%d\n' "${attempts}" "${acked}" "${failed}"
  printf 'outage_windows=%d\nlongest_outage_ms=%d\nopen_outage=%d\n' \
    "${windows}" \
    "$(( longest / 1000 ))" \
    "${open}"
}

# Print how many lines a comm comparison of two files gives, for the given comm flags.
# Usage: count_comm FLAGS FIRST SECOND
count_comm() {
  log INFO 'comparing two lists'
  local flags="${1:?flags required}"
  local first="${2:?first file required}"
  local second="${3:?second file required}"
  local output
  local -a lines=()

  output="$(comm "${flags}" "${first}" "${second}")"
  if [[ -n "${output}" ]]; then
    mapfile -t lines <<< "${output}"
  fi
  printf '%d\n' "${#lines[@]}"
}

# Compare the ledger lists with the rows on the node and print the loss figures.
# Usage: compare_with_node NODE WORK_FOLDER
compare_with_node() {
  log INFO 'comparing the ledger with the surviving node'
  local node="${1:?node required}"
  local work="${2:?work folder required}"

  database::bare "${node}" <<< "${SQL_PRESENT}" > "${work}/present"
  comm -23 "${work}/acked" "${work}/present" > "${work}/missing"
  printf 'present=%s\n' "$(count_comm -12 "${work}/present" "${work}/present")"
  printf 'acked_missing=%s\n' "$(count_comm -23 "${work}/acked" "${work}/present")"
  printf 'in_doubt=%s\n' "$(count_comm -12 "${work}/failed" "${work}/present")"
  printf 'acked_after_mark=%s\n' "$(count_comm -12 "${work}/after" "${work}/after")"
  printf 'missing_after_mark=%s\n' "$(count_comm -12 "${work}/missing" "${work}/after")"
}

# Make the work folder, read the ledger and compare it with the node.
# Usage: run_report LEDGER NODE
run_report() {
  log INFO 'making the report'
  local ledger="${1-}"
  local node="${2-}"
  local work

  [[ -r "${ledger}" && -n "${node}" ]] || die 2 '--ledger (a readable file) and --node are required'
  require_integer MARK_US "${MARK_US}"
  work="$(mktemp -d "${TEMP_DIR}/${SCRIPT_NAME}.XXXXXX")"
  CLEANUP_PATHS+=("${work}")
  printf '' > "${work}/acked"
  printf '' > "${work}/failed"
  printf '' > "${work}/after"
  read_ledger "${ledger}" "${work}" "${MARK_US}"
  compare_with_node "${node}" "${work}"
}

# Script entry point.
main() {
  local ledger=''
  local node=''
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --ledger)
        (( $# >= 2 )) || die 2 '--ledger needs a value'
        ledger="${2}"
        shift 2
        ;;
      --node)
        (( $# >= 2 )) || die 2 '--node needs a value'
        node="${2}"
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
  require_commands cat comm mktemp
  run_report "${ledger}" "${node}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
