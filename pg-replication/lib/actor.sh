# script-kind: library
# Purpose: Run the controller and the failover actor for a test, and time the client's view.
# Usage: source "${SCRIPT_DIR}../lib/actor.sh", then call actor::watch, run, time_until_writable
# Requires: sleep
# Depends: container controller database story
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly ACTOR_PROXY_ENDPOINT='toxiproxy:15432'
readonly ACTOR_CONTROLLER='auto-controller'
readonly ACTOR_WITNESS_SECONDS=5
readonly ACTOR_WAIT_SECONDS=15
readonly ACTOR_WRITE_LIMIT_SECONDS=60
readonly ACTOR_WRITE_SQL="select pg_logical_emit_message(true, 'auto-failover', 'x')"

# Print the name the controller runs under.
actor::controller_name() {
  printf '%s\n' "${ACTOR_CONTROLLER}"
}

# Give the writer traffic and start a controller that watches it through Toxiproxy.
# Further arguments, NAME=VALUE, go to the controller (for example LEASE_TTL_SECONDS=6).
# Usage: actor::watch WRITER_CONTAINER SCRIPT_DIR [NAME=VALUE ...]
actor::watch() {
  local writer="${1:?writer container required}"
  local script_dir="${2-}"

  database::heartbeat_start "${writer}"
  controller::start \
    "${ACTOR_CONTROLLER}" \
    "$(controller::password_file "${script_dir}")" \
    "${ACTOR_PROXY_ENDPOINT}" \
    "${ACTOR_WITNESS_SECONDS}" \
    "${@:3}"
  sleep 2
}

# Stop the controller and the writer's traffic (the writer may be gone already).
# Usage: actor::unwatch WRITER_CONTAINER
actor::unwatch() {
  local writer="${1:?writer container required}"

  controller::stop "${ACTOR_CONTROLLER}"
  if [[ "$(container::is_running "${writer}")" == 'true' ]]; then
    database::heartbeat_stop "${writer}"
  fi
}

# Run the actor until it finishes. CRASH_AFTER is the test hook: none, epoch, kill or promote.
# Further arguments, NAME=VALUE, are settings for the actor (for example FENCE_WAIT_SECONDS=7).
# Usage: actor::run SCRIPT_DIR EPOCH_FILE CRASH_AFTER [NAME=VALUE ...]
actor::run() {
  local script_dir="${1-}"
  local epoch_file="${2:?epoch file required}"
  local crash_after="${3:?crash point required}"
  local -a command=(env "EPOCH_FILE=${epoch_file}" "WAIT_SECONDS=${ACTOR_WAIT_SECONDS}")

  command+=("ACTOR_CRASH_AFTER=${crash_after}" "${@:4}")
  command+=(bash "${script_dir}act-on-failover.sh" --controller "${ACTOR_CONTROLLER}")
  story::run_logged "${command[@]}"
}

# Run the actor until it finishes, keeping its output in a file instead of the story; ACTOR_LOCK
# is on or off (off is the negative control of the lock). Fails if the actor fails.
# Usage: actor::run_captured SCRIPT_DIR EPOCH_FILE LOCK OUTPUT_FILE
actor::run_captured() {
  local script_dir="${1-}"
  local epoch_file="${2:?epoch file required}"
  local lock="${3:?lock setting required}"
  local output_file="${4:?output file required}"
  local -a command=(env "EPOCH_FILE=${epoch_file}" "WAIT_SECONDS=${ACTOR_WAIT_SECONDS}")

  command+=("ACTOR_LOCK=${lock}" bash "${script_dir}act-on-failover.sh")
  command+=(--controller "${ACTOR_CONTROLLER}")
  "${command[@]}" > "${output_file}" 2>&1
}

# Print the milliseconds, counted from STARTED_MS, until a write succeeds on the node (a client's
# view; a write fails while the node is a replica), or fail after a minute.
# Usage: actor::time_until_writable NODE STARTED_MS
actor::time_until_writable() {
  local node="${1:?node required}"
  local started="${2:?start time required}"
  local give_up=$(( started + ACTOR_WRITE_LIMIT_SECONDS * 1000 ))
  local now

  now="$(story::now_milliseconds)"
  while (( now < give_up )); do
    if database::bare "${node}" <<< "${ACTOR_WRITE_SQL}" > /dev/null 2>&1; then
      now="$(story::now_milliseconds)"
      printf '%s\n' "$(( now - started ))"
      return 0
    fi
    sleep 0.2
    now="$(story::now_milliseconds)"
  done
  die 1 "FAIL: no write succeeded on ${node} within ${ACTOR_WRITE_LIMIT_SECONDS} s"
}

# Try a write on the writer every 0.2 s for some seconds, counted from STARTED_MS; print the time
# of the last accepted write and of the first refused one (0 if none), in ms after the start.
# Usage: actor::watch_writes NODE SECONDS STARTED_MS
actor::watch_writes() {
  local node="${1:?node required}"
  local seconds="${2:?seconds required}"
  local started="${3:?start time required}"
  local give_up=$(( started + seconds * 1000 ))
  local now
  local last_ok=0
  local first_fail=0

  now="$(story::now_milliseconds)"
  while (( now < give_up )); do
    if database::bare "${node}" <<< "${ACTOR_WRITE_SQL}" > /dev/null 2>&1; then
      last_ok=$(( now - started ))
    elif (( first_fail == 0 )); then
      first_fail=$(( now - started ))
    else
      log INFO "${node} still refuses writes"
    fi
    sleep 0.2
    now="$(story::now_milliseconds)"
  done
  printf '%s %s\n' "${last_ok}" "${first_fail}"
}
