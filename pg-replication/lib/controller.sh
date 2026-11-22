# script-kind: library
# Purpose: Run the failover controller (detect-only) in a container and read what it decided.
# Usage: source "${SCRIPT_DIR}../lib/controller.sh", then call controller::start, verdicts, count
# Requires: docker
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly CONTROLLER_IMAGE='resilience-failover-controller'
readonly CONTROLLER_NETWORK='pg-replication_pgnet'
readonly CONTROLLER_NAME_PATTERN='^[a-z][a-z0-9-]*$'

# Build the controller image from the services folder, next to the scripts folder's parent.
# Usage: controller::build SCRIPT_DIR
controller::build() {
  local script_dir="${1-}"

  log INFO "CHANGE: building ${CONTROLLER_IMAGE}"
  docker build \
    --quiet \
    --tag "${CONTROLLER_IMAGE}" \
    --file "${script_dir}../../services/failover_controller/Dockerfile" \
    "${script_dir}../../services" > /dev/null
}

# Start a detect-only controller. The writer is reached at WRITER_ENDPOINT (host:port), so a test
# can route it through Toxiproxy and cut only the controller's view; the standby is reached
# directly. MAX_AGE is how recent the standby's last message from the writer must be to count.
# Further arguments, NAME=VALUE, are passed to the controller as environment settings (for example
# LEASE_TTL_SECONDS=6 makes it keep the writer's lease alive).
# Usage: controller::start NAME LOGIN_PATH WRITER_ENDPOINT MAX_AGE [NAME=VALUE ...]
controller::start() {
  local name="${1:?name required}"
  local login_path="${2:?login path required}"
  local endpoint="${3:?writer endpoint required}"
  local max_age="${4:?max age required}"
  local -a command=(docker run --detach --name "${name}" --network "${CONTROLLER_NETWORK}")
  local setting

  [[ "${name}" =~ ${CONTROLLER_NAME_PATTERN} ]] || die 2 "not a valid name: ${name}"
  command+=(--volume "${login_path}:/run/secrets/pg-password:ro")
  command+=(--env PASSWORD_FILE=/run/secrets/pg-password)
  command+=(--env "WRITER_HOST=${endpoint%%:*}")
  command+=(--env "WRITER_PORT=${endpoint##*:}")
  command+=(--env STANDBY_HOST=pg-standby)
  command+=(--env "WITNESS_MAX_AGE_SECONDS=${max_age}")
  for setting in "${@:5}"; do
    command+=(--env "${setting}")
  done
  command+=("${CONTROLLER_IMAGE}")
  log INFO "CHANGE: starting controller ${name} (writer at ${endpoint}, witness age ${max_age} s)"
  "${command[@]}" > /dev/null
}

# Stop and remove a controller; succeeds if it is already gone.
# Usage: controller::stop NAME
controller::stop() {
  local name="${1:?name required}"

  log INFO "CHANGE: removing controller ${name}"
  if ! docker rm --force "${name}" > /dev/null 2>&1; then
    log INFO "controller ${name} was already gone"
  fi
}

# Print the controller's decisions, one per line, in order: VERDICT EPOCH_SECONDS.
# Usage: controller::verdicts NAME
controller::verdicts() {
  local name="${1:?name required}"
  local output
  local line
  local verdict

  output="$(docker logs "${name}" 2>&1)"
  while IFS= read -r line; do
    if [[ "${line}" == *'DECISION verdict='* ]]; then
      verdict="${line#*verdict=}"
      printf '%s %s\n' "${verdict%% *}" "${line##*epoch=}"
    fi
  done <<< "${output}"
}

# Print how many times the controller reached a verdict, counting each change once.
# Usage: controller::count NAME VERDICT
controller::count() {
  local name="${1:?name required}"
  local verdict="${2:?verdict required}"
  local decisions
  local count=0
  local line

  decisions="$(controller::verdicts "${name}")"
  while IFS= read -r line; do
    if [[ "${line%% *}" == "${verdict}" ]]; then
      count=$(( count + 1 ))
    fi
  done <<< "${decisions}"
  printf '%s\n' "${count}"
}

# Print the epoch seconds of the first time the controller reached a verdict; nothing if never.
# Usage: controller::first_time NAME VERDICT
controller::first_time() {
  local name="${1:?name required}"
  local verdict="${2:?verdict required}"
  local decisions
  local line

  decisions="$(controller::verdicts "${name}")"
  while IFS= read -r line; do
    if [[ "${line%% *}" == "${verdict}" ]]; then
      printf '%s\n' "${line##* }"
      return 0
    fi
  done <<< "${decisions}"
}

# Print the superuser password file's absolute path (docker needs one to mount it).
# Usage: controller::password_file SCRIPT_DIR
controller::password_file() {
  local script_dir="${1-}"

  if [[ "${script_dir}" == /* ]]; then
    printf '%s../secrets/pg-password.txt\n' "${script_dir}"
  else
    printf '%s/%s../secrets/pg-password.txt\n' "${PWD}" "${script_dir}"
  fi
}
