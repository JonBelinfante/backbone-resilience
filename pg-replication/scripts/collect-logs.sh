#!/usr/bin/env bash
# script-kind: executable
# Purpose: Save the containers' own logs into the logs folder, for audit.
# Usage: collect-logs.sh [-h | --help] [--container NAME ...]
# Requires: cat date mkdir rm wc
# Exit codes: 0 success, 1 failure, 2 usage or configuration error
set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: LOG_DIR is where the container logs are saved
# (default: logs in the current directory).
readonly LOG_DIR="${LOG_DIR:-logs}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: collect-logs.sh [-h | --help] [--container NAME ...]

Save each container's own log (the Postgres server log plus the init and
entrypoint lines) into LOG_DIR, so the whole picture of script runs and server
behaviour sits in one place for audit. Each log is written to
container-NAME-TIMESTAMP.log, and docker adds its own timestamp to every line.
A stopped container works too, as long as it has not been removed ('down'
removes it).

Options:
  --container NAME  a container to save; repeat for more
                    (default: pg-primary and pg-standby)

Environment:
  LOG_DIR      directory for the container logs (default: logs)
  RUN_LOG_DIR  directory for this run's log file, which must exist
               (default: temporary directory)

Exit codes: 0 success, 1 failure, 2 usage or configuration error
USAGE
}

# Save the log of each named container and report the number of lines saved.
collect() {
  local stamp
  local container
  local out
  local lines

  mkdir -p "${LOG_DIR}"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for container in "$@"; do
    out="${LOG_DIR}/container-${container}-${stamp}.log"
    if container::logs "${container}" > "${out}" 2>&1; then
      lines="$(wc -l < "${out}")"
      log INFO "saved ${container} to ${out}"
      printf 'saved %d lines from %s -> %s\n' "${lines}" "${container}" "${out}"
    else
      rm -f -- "${out}"
      die 1 "could not read logs for '${container}' (does the container exist?)"
    fi
  done
}

# Script entry point.
main() {
  local -a containers=()
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --container)
        (( $# >= 2 )) || die 2 '--container needs a value'
        containers+=("${2}")
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
  if (( ${#containers[@]} == 0 )); then
    containers=(pg-primary pg-standby)
  fi

  collect "${containers[@]}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
