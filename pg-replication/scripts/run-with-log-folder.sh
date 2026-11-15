#!/usr/bin/env bash
# script-kind: executable
# Purpose: Run a command with one shared run-log folder, so every script it starts logs there.
# Usage: run-with-log-folder.sh [-h | --help] [--merge] -- COMMAND [ARGUMENT ...]
# Requires: bash cat date mkdir mktemp
# Exit codes: 0 the command succeeded, 1 it failed, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: FOLDER_PARENT is where the shared run folder is created (default: RUN_LOG_DIR).
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
Usage: run-with-log-folder.sh [-h | --help] [--merge] -- COMMAND [ARGUMENT ...]

Creates a new run folder (run-<UTC time>.<random>) inside RUN_LOG_DIR and runs COMMAND with
RUN_LOG_DIR pointing at it. Every script that COMMAND starts, however deeply, then writes its
run log into that one folder instead of scattering files. Afterwards it prints the folder.

  --merge  also print the merged timeline of the whole run (see merge-run-logs.sh)

Example:
  run-with-log-folder.sh --merge -- bash scripts/test-failover-roundtrip.sh

Environment: FOLDER_PARENT is the folder the run folder is created in (default: RUN_LOG_DIR).
RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 the command succeeded, 1 it failed, 2 usage or configuration error
USAGE
}

# Run the command with RUN_LOG_DIR set to the shared folder and wait for it; fail if it fails.
run_command() {
  log INFO 'running the command with the shared run folder'
  local folder="${1:?folder required}"
  local -a command=(env "RUN_LOG_DIR=${folder}" "${@:2}")
  local pid

  "${command[@]}" &
  pid=$!
  if ! wait "${pid}"; then
    return 1
  fi
}

# Create the shared folder (named from a placeholder file that is removed on exit), run the
# command in it, then say where the logs went and merge them when asked.
run_in_new_folder() {
  log INFO 'creating the shared run folder'
  local merge="${1:?merge flag required}"
  local stamp
  local marker
  local folder
  local outcome='passed'

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  marker="$(mktemp "${FOLDER_PARENT}/run-${stamp}.XXXXXX")"
  CLEANUP_PATHS+=("${marker}")
  folder="${marker}.d"
  mkdir -- "${folder}"
  log INFO "CHANGE: created ${folder}"
  if ! run_command "${folder}" "${@:2}"; then
    outcome='failed'
  fi
  printf '\nrun logs: %s\n' "${folder}"
  if [[ "${merge}" == 'yes' ]]; then
    bash "${SCRIPT_DIR}merge-run-logs.sh" --dir "${folder}"
  fi
  [[ "${outcome}" == 'passed' ]]
}

# Script entry point.
main() {
  local merge='no'
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --merge)
        merge='yes'
        shift
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

  (( $# > 0 )) || die 2 'no command to run: pass it after -- (try --help)'
  require_commands bash cat date mkdir mktemp
  run_in_new_folder "${merge}" "$@" || die 1 'the command failed (its logs are in the run folder)'
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
