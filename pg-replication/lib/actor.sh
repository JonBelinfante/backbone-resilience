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

# Give the writer traffic and start a controller that watches it through Toxiproxy.
# Usage: actor::watch WRITER_CONTAINER SCRIPT_DIR
actor::watch() {
  local writer="${1:?writer container required}"
  local script_dir="${2-}"

  database::heartbeat_start "${writer}"
  controller::start \
    "${ACTOR_CONTROLLER}" \
    "$(controller::password_file "${script_dir}")" \
    "${ACTOR_PROXY_ENDPOINT}" \
    "${ACTOR_WITNESS_SECONDS}"
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
# Usage: actor::run SCRIPT_DIR EPOCH_FILE CRASH_AFTER
actor::run() {
  local script_dir="${1-}"
  local epoch_file="${2:?epoch file required}"
  local crash_after="${3:?crash point required}"

  story::run_logged env \
    "EPOCH_FILE=${epoch_file}" \
    "WAIT_SECONDS=${ACTOR_WAIT_SECONDS}" \
    "ACTOR_CRASH_AFTER=${crash_after}" \
    bash \
    "${script_dir}act-on-failover.sh" \
    --controller "${ACTOR_CONTROLLER}"
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
