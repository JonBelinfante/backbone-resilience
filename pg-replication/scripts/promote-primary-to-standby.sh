#!/usr/bin/env bash
# script-kind: executable
# Purpose: Turn the stopped old primary into a standby of the current writable node (pg_rewind).
# Usage: promote-primary-to-standby.sh [-h | --help]
# Requires: bash cat sleep
# Exit codes: 0 success, 1 failure, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit

# Environment: PRIMARY_CONTAINER is the stopped old primary that becomes a standby, and
# STANDBY_CONTAINER is the node now accepting writes (named as compose created them).
# The passwords are not configured here: they are read from the writable node's environment.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly REPLICATION_USER="${REPLICATION_USER:-replicator}"
readonly STANDBY_NAME="${STANDBY_NAME:-standby1}"
readonly STANDBY_SLOT="${STANDBY_SLOT:-standby1_slot}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly DATABASE_PORT=5432
readonly STREAM_ATTEMPTS=30
readonly STREAM_PAUSE_SECONDS=1

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"
# shellcheck source=../lib/container.sh
source "${SCRIPT_DIR}../lib/container.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: promote-primary-to-standby.sh [-h | --help]

Rebuild the old primary as a standby of the node that took over after a failover.
Stop the old primary first (bring-down-database.sh --database primary) and promote
the other node (promote-standby-to-primary.sh).

The script checks both, creates the replication slot and a checkpoint on the writer,
runs pg_rewind on the old primary, marks it as a standby, starts it and waits
until it streams. The passwords are read from the writer container's environment.

Environment:
  PRIMARY_CONTAINER  the stopped old primary (default: pg-primary)
  STANDBY_CONTAINER  the node accepting writes (default: pg-standby)
  REPLICATION_USER   streaming role (default: replicator)
  STANDBY_NAME       application_name of the standby (default: standby1)
  STANDBY_SLOT       replication slot for the standby (default: standby1_slot)
  RUN_LOG_DIR        directory for the run log (default: temporary directory)

Exit codes: 0 success, 1 failure, 2 usage or configuration error
USAGE
}

# Fail unless the old primary is stopped: pg_rewind needs a cleanly stopped server.
check_old_primary_stopped() {
  local running
  local hint='bring-down-database.sh --database primary'

  running="$(container::is_running "${PRIMARY_CONTAINER}")"
  if [[ "${running}" != 'false' ]]; then
    die 1 "${PRIMARY_CONTAINER} is running: stop it first (${hint})"
  fi
  log INFO "${PRIMARY_CONTAINER} is stopped"
}

# Fail unless the other node is running and accepting writes.
check_writer_is_writable() {
  local recovery

  recovery="$(database::in_recovery "${STANDBY_CONTAINER}")"
  if [[ "${recovery}" != 'f' ]]; then
    die 1 "${STANDBY_CONTAINER} is not accepting writes: promote it first"
  fi
  log INFO "${STANDBY_CONTAINER} is accepting writes"
}

# Create the standby's replication slot on the writable node if it does not exist.
ensure_replication_slot() {
  local create="select pg_create_physical_replication_slot('${STANDBY_SLOT}')"
  local missing=' where not exists (select 1 from pg_replication_slots'
  local named=" where slot_name = '${STANDBY_SLOT}')"

  log INFO 'making sure the replication slot exists on the writable node'
  log INFO "CHANGE: ensuring slot ${STANDBY_SLOT} exists on ${STANDBY_CONTAINER}"
  database::bare "${STANDBY_CONTAINER}" <<< "${create}${missing}${named}" > /dev/null
}

# Force a checkpoint on the writable node. Until it has one after promotion, its control file
# still shows the old timeline and pg_rewind would wrongly decide no rewind is needed.
checkpoint_writer() {
  log INFO 'forcing a checkpoint on the writable node'
  database::bare "${STANDBY_CONTAINER}" <<< 'checkpoint' > /dev/null
}

# Rewind the old primary to the new timeline with pg_rewind (see container::rewind).
rewind_old_primary() {
  log INFO 'rewinding the old primary to the new timeline'
  container::rewind "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}" "${DATABASE_PORT}"
}

# Mark the rewound data directory as a standby of the writable node (see container::mark_standby).
write_standby_settings() {
  log INFO 'marking the rewound data directory as a standby'
  local password
  local conninfo="host=${STANDBY_CONTAINER} port=${DATABASE_PORT} user=${REPLICATION_USER}"

  password="$(container::secret "${STANDBY_CONTAINER}" pg-replication-password)"
  conninfo+=" password=${password} application_name=${STANDBY_NAME}"
  container::mark_standby \
    "${PRIMARY_CONTAINER}" \
    "${STANDBY_CONTAINER}" \
    "${conninfo}" \
    "${STANDBY_SLOT}"
}

# Start the old primary through bring-up-database.sh, which waits until it is healthy.
start_old_primary() {
  log INFO 'starting the old primary as a standby'
  bash "${SCRIPT_DIR}bring-up-database.sh" --database primary
}

# Wait until the writable node reports the standby as streaming, giving up after STREAM_ATTEMPTS.
wait_until_streaming() {
  local attempt=1
  local streaming
  local query="select count(*) from pg_stat_replication where state = 'streaming'"
  local filter=" and application_name = '${STANDBY_NAME}'"

  log INFO 'waiting for the standby to start streaming'
  while (( attempt <= STREAM_ATTEMPTS )); do
    streaming="$(database::bare "${STANDBY_CONTAINER}" <<< "${query}${filter}")"
    if [[ "${streaming}" == '1' ]]; then
      log INFO "${PRIMARY_CONTAINER} is streaming from ${STANDBY_CONTAINER}"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep "${STREAM_PAUSE_SECONDS}"
  done
  die 1 "${PRIMARY_CONTAINER} did not start streaming within ${STREAM_ATTEMPTS} attempts"
}

# Print the old primary's state: whether it is in recovery (a standby) and who it follows.
report_result() {
  local recovery

  log INFO 'reporting the result'
  recovery="$(database::in_recovery "${PRIMARY_CONTAINER}")"
  printf '%s in recovery: %s (expect t)\n' "${PRIMARY_CONTAINER}" "${recovery}"
  printf '%s is now a standby of %s\n' "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"
}

# Script entry point.
main() {
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
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
  require_commands bash cat sleep
  log INFO "DECISION: rebuilding ${PRIMARY_CONTAINER} as a standby of ${STANDBY_CONTAINER}"
  check_old_primary_stopped
  check_writer_is_writable
  ensure_replication_slot
  checkpoint_writer
  rewind_old_primary
  write_standby_settings
  start_old_primary
  wait_until_streaming
  report_result
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
