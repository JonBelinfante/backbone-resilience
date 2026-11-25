# script-kind: library
# Purpose: Route the standby's replication link through the proxy and time what a fault does to it.
# Usage: source "${SCRIPT_DIR}../lib/link.sh", then call link::route, commit_summary, staleness
# Requires: sleep
# Depends: access container database measure
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly LINK_PROXY_HOST='toxiproxy'
readonly LINK_PROXY_PORT=15432
readonly LINK_STANDBY_NAME='standby1'
readonly LINK_INSERT_SQL='insert into net_probe default values returning id'
readonly LINK_SAMPLES=9
readonly LINK_PAUSE_SECONDS=0.1
readonly LINK_RESTART_PATTERN='started streaming WAL from primary at ([0-9A-F]+/[0-9A-F]+)'

# Point the standby at the writer directly or through the proxy, and wait until it streams. The
# role and password come from the secret files next to the scripts folder.
# Usage: link::route SCRIPT_DIR proxy|direct WRITER STANDBY
link::route() {
  log INFO 'routing the standby'
  local script_dir="${1-}"
  local route="${2:?route required}"
  local writer="${3:?writer required}"
  local standby="${4:?standby required}"
  local address="host=${writer} port=5432 application_name=${LINK_STANDBY_NAME}"
  local user_file="${script_dir}../secrets/pg-replication-user.txt"
  local key_file="${script_dir}../secrets/pg-replication-password.txt"

  if [[ "${route}" == 'proxy' ]]; then
    address="host=${LINK_PROXY_HOST} port=${LINK_PROXY_PORT} application_name=${LINK_STANDBY_NAME}"
  fi
  access::point_standby_at "${standby}" "${address}" "$(< "${user_file}")" "${key_file}"
  sleep 2
  database::wait_for_streaming "${writer}"
}

# Print how many milliseconds one commit on the writer takes.
# Usage: link::commit_time WRITER
link::commit_time() {
  local writer="${1:?writer required}"
  local started="${EPOCHREALTIME//[.,]/}"

  database::bare "${writer}" <<< "${LINK_INSERT_SQL}" > /dev/null
  printf '%d\n' "$(( (${EPOCHREALTIME//[.,]/} - started) / 1000 ))"
}

# Print the minimum, median and maximum commit time, in milliseconds, of a number of commits.
# Usage: link::commit_summary WRITER
link::commit_summary() {
  log INFO 'timing commits'
  local writer="${1:?writer required}"
  local count=0
  local -a times=()

  while (( count < LINK_SAMPLES )); do
    times+=("$(link::commit_time "${writer}")")
    count=$(( count + 1 ))
    sleep "${LINK_PAUSE_SECONDS}"
  done
  printf '%s\n' "${times[@]}" | measure::min_median_max
}

# Print the median commit time, in milliseconds.
# Usage: link::median_commit WRITER
link::median_commit() {
  local writer="${1:?writer required}"
  local summary
  local -a parts=()

  summary="$(link::commit_summary "${writer}")"
  read -r -a parts <<< "${summary}"
  printf '%d\n' "${parts[1]}"
}

# Print how many milliseconds a row takes to become visible on the standby after it commits.
# Usage: link::staleness WRITER STANDBY
link::staleness() {
  log INFO 'timing how stale the standby is'
  local writer="${1:?writer required}"
  local standby="${2:?standby required}"
  local row
  local started
  local sql

  row="$(database::bare "${writer}" <<< "${LINK_INSERT_SQL}")"
  sql="select count(*) from net_probe where id = ${row}"
  started="${EPOCHREALTIME//[.,]/}"
  while [[ "$(database::bare "${standby}" <<< "${sql}")" != '1' ]]; do
    sleep 0.02
  done
  printf '%d\n' "$(( (${EPOCHREALTIME//[.,]/} - started) / 1000 ))"
}

# Print how many different WAL positions the standby's WAL receiver started streaming at in its
# last COUNT starts, read from its log. A stalled link restarts at the same position every time.
# Usage: link::restart_places STANDBY COUNT
link::restart_places() {
  local standby="${1:?standby required}"
  local count="${2:?count required}"
  local line
  local position
  local seen=' '
  local distinct=0
  local -a positions=()

  while IFS= read -r line; do
    if [[ "${line}" =~ ${LINK_RESTART_PATTERN} ]]; then
      positions+=("${BASH_REMATCH[1]}")
    fi
  done <<< "$(container::logs "${standby}" 2>&1)"
  (( ${#positions[@]} >= count )) || die 1 "only ${#positions[@]} restarts in the log, not ${count}"
  for position in "${positions[@]: -count}"; do
    if [[ "${seen}" != *" ${position} "* ]]; then
      seen+="${position} "
      distinct=$(( distinct + 1 ))
    fi
  done
  printf '%d\n' "${distinct}"
}
