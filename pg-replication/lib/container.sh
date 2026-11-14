# script-kind: library
# Purpose: Every docker call for the database containers: look them up, start, stop, wait, inspect.
# Usage: source "${SCRIPT_DIR}../lib/container.sh", then call container::start, stop, health ...
# Requires: die docker log sleep
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly CONTAINER_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

# Print the container name for a database ("primary" or "standby"); the two names are passed in.
# Usage: container::name_of DATABASE PRIMARY_CONTAINER STANDBY_CONTAINER
container::name_of() {
  local database="${1:?database required}"
  local primary="${2:?primary container required}"
  local standby="${3:?standby container required}"

  case "${database}" in
    primary)
      printf '%s\n' "${primary}"
      ;;
    standby)
      printf '%s\n' "${standby}"
      ;;
    *)
      die 2 "unknown database: ${database} (use primary or standby)"
      ;;
  esac
}

# Print true if the container is running and false if it is stopped; fail if it does not exist.
container::is_running() {
  local container="${1:?container required}"

  if [[ ! "${container}" =~ ${CONTAINER_NAME_PATTERN} ]]; then
    die 2 "not a valid container name: ${container}"
  fi
  if ! docker inspect --format '{{.State.Running}}' "${container}" 2> /dev/null; then
    die 1 "no such container: ${container}"
  fi
}

# Print one value from docker inspect for a container (a Go template such as '{{.State.Running}}').
# Usage: container::inspect CONTAINER GO_TEMPLATE
container::inspect() {
  local container="${1:?container required}"
  local template="${2:?template required}"

  docker inspect --format "${template}" "${container}"
}

# Print the image the container was created from.
container::image() {
  local container="${1:?container required}"

  container::inspect "${container}" '{{.Config.Image}}'
}

# Print the name of the Docker network the container is attached to.
container::network() {
  local container="${1:?container required}"

  container::inspect "${container}" '{{.HostConfig.NetworkMode}}'
}

# Print the name of the Docker volume mounted in the container (each node has exactly one).
container::volume() {
  local container="${1:?container required}"
  local template='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}'

  container::inspect "${container}" "${template}"
}

# Print the value of an environment variable set inside a running container.
container::setting() {
  local container="${1:?container required}"
  local name="${2:?name required}"

  docker exec "${container}" printenv "${name}"
}

# Print the container's health: starting, healthy or unhealthy.
container::health() {
  local container="${1:?container required}"

  container::inspect "${container}" '{{.State.Health.Status}}'
}

# Start the container.
container::start() {
  local container="${1:?container required}"

  log INFO "CHANGE: starting ${container}"
  docker start "${container}" > /dev/null
}

# Stop the container. The optional second argument is the seconds to wait for a clean shutdown.
container::stop() {
  local container="${1:?container required}"
  local timeout="${2-}"
  local -a options=()

  if [[ -n "${timeout}" ]]; then
    options=(--time "${timeout}")
  fi
  log INFO "CHANGE: stopping ${container}"
  docker stop "${options[@]}" "${container}" > /dev/null
}

# Wait until the container's health check passes, giving up after the given number of tries.
# Usage: container::wait_healthy CONTAINER ATTEMPTS PAUSE_SECONDS
container::wait_healthy() {
  local container="${1:?container required}"
  local attempts="${2:?attempts required}"
  local pause="${3:?pause required}"
  local attempt=1
  local health

  while (( attempt <= attempts )); do
    health="$(container::health "${container}")"
    if [[ "${health}" == 'healthy' ]]; then
      log INFO "${container} is healthy"
      return 0
    fi
    attempt=$(( attempt + 1 ))
    sleep "${pause}"
  done
  die 1 "${container} was not healthy after ${attempts} attempts"
}

# Create and start the compose stack. The pull policy is passed to docker compose up --pull.
# Usage: container::compose_up COMPOSE_FILE PULL_POLICY
container::compose_up() {
  local file="${1:?compose file required}"
  local policy="${2:?pull policy required}"

  log INFO "CHANGE: docker compose up (${file})"
  docker compose -f "${file}" up -d --pull "${policy}"
}

# Print the container's log, with the timestamp docker adds to every line.
container::logs() {
  local container="${1:?container required}"

  docker logs -t "${container}"
}

# Run pg_rewind in a throwaway container that mounts the target's data volume and joins its
# network, so it can read the source's files over a normal connection. The target must be
# cleanly stopped.
# Usage: container::rewind TARGET_CONTAINER SOURCE_CONTAINER PORT
container::rewind() {
  local target="${1:?target container required}"
  local source="${2:?source container required}"
  local port="${3:?port required}"
  local image
  local network
  local volume
  local password
  local data_dir

  image="$(container::image "${target}")"
  network="$(container::network "${target}")"
  volume="$(container::volume "${target}")"
  password="$(container::setting "${source}" POSTGRES_PASSWORD)"
  data_dir="$(container::setting "${source}" PGDATA)"
  log INFO "CHANGE: pg_rewind of volume ${volume} against ${source}"
  PGPASSWORD="${password}" docker run \
    --rm \
    --user postgres \
    --network "${network}" \
    --env PGPASSWORD \
    --volume "${volume}:${data_dir}" \
    "${image}" \
    pg_rewind \
    --target-pgdata="${data_dir}" \
    --source-server="host=${source} port=${port} user=postgres dbname=postgres" \
    --progress
}

# Print the two settings lines that make a data directory follow the writable node.
container::standby_settings() {
  local conninfo="${1:?connection string required}"
  local slot="${2:?slot required}"

  printf "primary_conninfo = '%s'\n" "${conninfo}"
  printf "primary_slot_name = '%s'\n" "${slot}"
}

# Mark the target's data directory as a standby of the source. The settings are appended, so
# they override the copies pg_rewind brought over (the last occurrence in the file wins).
# Usage: container::mark_standby TARGET_CONTAINER SOURCE_CONTAINER CONNINFO SLOT
container::mark_standby() {
  local target="${1:?target container required}"
  local source="${2:?source container required}"
  local conninfo="${3:?connection string required}"
  local slot="${4:?slot required}"
  local program='touch standby.signal && cat >> postgresql.auto.conf'
  local image
  local volume
  local data_dir

  image="$(container::image "${target}")"
  volume="$(container::volume "${target}")"
  data_dir="$(container::setting "${source}" PGDATA)"
  log INFO "CHANGE: configuring ${target} as a standby of ${source}"
  container::standby_settings "${conninfo}" "${slot}" |
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
