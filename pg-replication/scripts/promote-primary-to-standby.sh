#!/usr/bin/env bash
# script-kind: executable
# Purpose: Turn the stopped old primary into a standby of the current writable node (pg_rewind).
# Usage: promote-primary-to-standby.sh [-h | --help]
# Requires: bash cat date docker mktemp rm sleep
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
# RUN_LOG_DIR defaults to the temporary directory and must exist.
readonly PRIMARY_CONTAINER="${PRIMARY_CONTAINER:-pg-primary}"
readonly STANDBY_CONTAINER="${STANDBY_CONTAINER:-pg-standby}"
readonly REPLICATION_USER="${REPLICATION_USER:-replicator}"
readonly STANDBY_NAME="${STANDBY_NAME:-standby1}"
readonly STANDBY_SLOT="${STANDBY_SLOT:-standby1_slot}"
readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly DATABASE_SQL="${SCRIPT_DIR}database-sql.sh"
readonly DATABASE_PORT=5432
readonly STREAM_ATTEMPTS=30
readonly STREAM_PAUSE_SECONDS=1
declare RUN_LOG=''
declare -a CLEANUP_PATHS=()

# Append a line to the run log and, for WARN and ERROR, to standard error.
log() {
  local level="${1:?level required}"
  local message="${2:?message required}"
  local now="${EPOCHREALTIME}"
  local fraction="${now#*[.,]}"
  local stamp
  local line

  TZ=UTC printf -v stamp '%(%Y-%m-%dT%H:%M:%S)T' "${now%%[.,]*}"
  line="${stamp}.${fraction:0:3}Z ${level} ${message}"
  if [[ -n "${RUN_LOG}" ]]; then
    printf '%s\n' "${line}" >> "${RUN_LOG}"
  fi
  if [[ "${level}" != 'INFO' ]]; then
    printf '%s: %s\n' "${SCRIPT_NAME}" "${line}" >&2
  fi
}

# Log an error, then exit with the given status.
die() {
  local status="${1:?status required}"
  local message="${2:?message required}"

  log ERROR "${message}"
  exit "${status}"
}

# Log where a command failed: its line, the function it was in, and the command itself.
on_error() {
  local status="${?}"
  local line_no="${1:?line required}"
  local command_text="${2:?command required}"
  local where="${FUNCNAME[1]:-main}"

  log ERROR "failed (status ${status}) at line ${line_no} in ${where}: ${command_text}"
}

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

# Fail early if a required command is missing.
require_commands() {
  local cmd

  for cmd in "$@"; do
    command -v "${cmd}" > /dev/null || die 1 "missing required command: ${cmd}"
  done
}

# Create this run's log file in RUN_LOG_DIR and record the start.
start_run_log() {
  local stamp

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$(mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-${stamp}.XXXXXX")"
  log INFO "started ${SCRIPT_NAME}"
}

# Record how the run ended, then remove temporary files created by this script.
cleanup() {
  local status="${?}"

  log INFO "finished with status ${status}"
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    rm -f -- "${CLEANUP_PATHS[@]}"
  fi
}

# Print one value from docker inspect for a container.
# Usage: inspect_value CONTAINER GO_TEMPLATE
inspect_value() {
  local container="${1:?container required}"
  local template="${2:?template required}"

  docker inspect --format "${template}" "${container}"
}

# Print the name of the Docker volume mounted in a container (each node has exactly one).
volume_of_container() {
  local container="${1:?container required}"
  local template='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}'

  inspect_value "${container}" "${template}"
}

# Print the name of the Docker network a container is attached to.
network_of_container() {
  local container="${1:?container required}"

  inspect_value "${container}" '{{.HostConfig.NetworkMode}}'
}

# Print the value of an environment variable set inside a running container.
read_container_setting() {
  local container="${1:?container required}"
  local name="${2:?name required}"

  docker exec "${container}" printenv "${name}"
}

# Print the Postgres data directory used inside the containers (the image sets PGDATA).
data_dir_of_writer() {
  read_container_setting "${STANDBY_CONTAINER}" PGDATA
}

# Print the two settings lines that make the data directory follow the writable node.
print_standby_settings() {
  local conninfo="${1:?connection string required}"

  printf "primary_conninfo = '%s'\n" "${conninfo}"
  printf "primary_slot_name = '%s'\n" "${STANDBY_SLOT}"
}

# Fail unless the old primary is stopped: pg_rewind needs a cleanly stopped server.
check_old_primary_stopped() {
  local running
  local hint='bring-down-database.sh --database primary'

  running="$(inspect_value "${PRIMARY_CONTAINER}" '{{.State.Running}}')"
  if [[ "${running}" != 'false' ]]; then
    die 1 "${PRIMARY_CONTAINER} is running: stop it first (${hint})"
  fi
  log INFO "${PRIMARY_CONTAINER} is stopped"
}

# Fail unless the other node is running and accepting writes.
check_writer_is_writable() {
  local recovery

  recovery="$(bash "${DATABASE_SQL}" --container "${STANDBY_CONTAINER}" --ask recovery)"
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
  bash "${DATABASE_SQL}" \
    --container "${STANDBY_CONTAINER}" \
    --bare <<< "${create}${missing}${named}" > /dev/null
}

# Force a checkpoint on the writable node. Until it has one after promotion, its control file
# still shows the old timeline and pg_rewind would wrongly decide no rewind is needed.
checkpoint_writer() {
  log INFO 'forcing a checkpoint on the writable node'
  bash "${DATABASE_SQL}" --container "${STANDBY_CONTAINER}" --bare <<< 'checkpoint' > /dev/null
}

# Run pg_rewind in a throwaway container that mounts the old primary's data volume and joins
# its network, so it can read the writable node's files over a normal connection.
rewind_old_primary() {
  local image
  local network
  local volume
  local postgres_password
  local data_dir
  local source_server="host=${STANDBY_CONTAINER} port=${DATABASE_PORT}"

  log INFO 'rewinding the old primary to the new timeline'
  image="$(inspect_value "${PRIMARY_CONTAINER}" '{{.Config.Image}}')"
  network="$(network_of_container "${PRIMARY_CONTAINER}")"
  volume="$(volume_of_container "${PRIMARY_CONTAINER}")"
  postgres_password="$(read_container_setting "${STANDBY_CONTAINER}" POSTGRES_PASSWORD)"
  data_dir="$(data_dir_of_writer)"
  source_server+=' user=postgres dbname=postgres'
  log INFO "CHANGE: pg_rewind of volume ${volume} against ${STANDBY_CONTAINER}"
  PGPASSWORD="${postgres_password}" docker run \
    --rm \
    --user postgres \
    --network "${network}" \
    --env PGPASSWORD \
    --volume "${volume}:${data_dir}" \
    "${image}" \
    pg_rewind \
    --target-pgdata="${data_dir}" \
    --source-server="${source_server}" \
    --progress
}

# Mark the rewound data directory as a standby of the writable node. The settings are appended,
# so they override the copies pg_rewind brought over (the last occurrence in the file wins).
write_standby_settings() {
  local image
  local volume
  local replication_password
  local data_dir
  local conninfo
  local program='touch standby.signal && cat >> postgresql.auto.conf'

  log INFO 'marking the rewound data directory as a standby'
  image="$(inspect_value "${PRIMARY_CONTAINER}" '{{.Config.Image}}')"
  volume="$(volume_of_container "${PRIMARY_CONTAINER}")"
  replication_password="$(read_container_setting "${STANDBY_CONTAINER}" REPLICATION_PASSWORD)"
  data_dir="$(data_dir_of_writer)"
  conninfo="host=${STANDBY_CONTAINER} port=${DATABASE_PORT} user=${REPLICATION_USER}"
  conninfo+=" password=${replication_password} application_name=${STANDBY_NAME}"
  log INFO "CHANGE: configuring ${PRIMARY_CONTAINER} as a standby of ${STANDBY_CONTAINER}"
  print_standby_settings "${conninfo}" |
    docker run \
      --rm \
      --interactive \
      --user postgres \
      --volume "${volume}:${data_dir}" \
      --workdir "${data_dir}" \
      --entrypoint sh \
      "${image}" \
      -c "${program}"
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
    streaming="$(bash "${DATABASE_SQL}" \
      --container "${STANDBY_CONTAINER}" \
      --bare <<< "${query}${filter}")"
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
  recovery="$(bash "${DATABASE_SQL}" --container "${PRIMARY_CONTAINER}" --ask recovery)"
  printf '%s in recovery: %s (expect t)\n' "${PRIMARY_CONTAINER}" "${recovery}"
  printf '%s is now a standby of %s\n' "${PRIMARY_CONTAINER}" "${STANDBY_CONTAINER}"
}

# Script entry point.
main() {
  require_commands bash cat date docker mktemp rm sleep
  start_run_log

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

main "$@"
