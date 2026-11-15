#!/usr/bin/env bash
# script-kind: executable
# Purpose: Print the container name of a database, or whether a container is running.
# Usage: show-container-info.sh [-h | --help] (--database primary|standby | --container NAME)
# Requires: cat
# Exit codes: 0 answer printed, 1 failure (for example no such container), 2 usage error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER and STANDBY_CONTAINER name the two containers as compose
# created them. RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"

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
Usage: show-container-info.sh [-h | --help] (--database primary|standby | --container NAME)

Command-line wrapper over lib/container.sh. Tells you the container name for a database,
or whether a named container is running. Other scripts import container.sh instead of
calling this one; it is here for use by hand.

  --database primary|standby  print the container name for that database
  --container NAME            print true if the container is running, false if not

Exits 1 when the container does not exist.

Environment: PRIMARY_CONTAINER (pg-primary), STANDBY_CONTAINER (pg-standby) and
RUN_LOG_DIR (the run log directory, default: temporary directory).

Exit codes: 0 answer printed, 1 failure (for example no such container), 2 usage error
USAGE
}

# Answer the one question that was asked; exactly one of database and container is given.
answer_question() {
  log INFO 'answering the question'
  local database="${1-}"
  local container="${2-}"

  if [[ -n "${database}" && -z "${container}" ]]; then
    container::name_of "${database}" "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"
  elif [[ -z "${database}" && -n "${container}" ]]; then
    container::is_running "${container}"
  else
    die 2 'give exactly one of --database or --container (try --help)'
  fi
}

# Script entry point.
main() {
  local database=''
  local container=''
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --database)
        (( $# >= 2 )) || die 2 '--database needs a value'
        database="${2}"
        shift 2
        ;;
      --container)
        (( $# >= 2 )) || die 2 '--container needs a value'
        container="${2}"
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
  answer_question "${database}" "${container}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
