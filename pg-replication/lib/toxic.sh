# script-kind: library
# Purpose: Inject network faults between the nodes with Toxiproxy: delay, silence, and a cut link.
# Usage: source "${SCRIPT_DIR}../lib/toxic.sh", then call toxic::latency, silence, cut, heal
# Requires: docker
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly TOXIC_CONTAINER='toxiproxy'
readonly TOXIC_PROXY_PATTERN='^[a-z][a-z-]*$'
readonly TOXIC_INTEGER_PATTERN='^[0-9]+$'

# Run the Toxiproxy command-line client in its container.
toxic::cli() {
  MSYS_NO_PATHCONV=1 docker exec "${TOXIC_CONTAINER}" /toxiproxy-cli "$@"
}

# Add a toxic to a proxy in one direction. The spec is TYPE:ATTRIBUTE, such as latency:latency=50.
# Usage: toxic::add PROXY NAME DIRECTION SPEC   (DIRECTION is upstream or downstream)
toxic::add() {
  local proxy="${1:?proxy required}"
  local name="${2:?name required}"
  local direction="${3:?direction required}"
  local spec="${4:?spec required}"
  local -a command=(toxic::cli toxic add --type "${spec%%:*}" --attribute "${spec#*:}")

  [[ "${proxy}" =~ ${TOXIC_PROXY_PATTERN} ]] || die 2 "not a valid proxy name: ${proxy}"
  command+=("--${direction}" --toxicName "${name}" "${proxy}")
  "${command[@]}" > /dev/null
}

# Delay everything on a link by some milliseconds in each direction, so a round trip is twice that.
# Usage: toxic::latency PROXY MILLISECONDS
toxic::latency() {
  local proxy="${1:?proxy required}"
  local milliseconds="${2:?milliseconds required}"

  [[ "${milliseconds}" =~ ${TOXIC_INTEGER_PATTERN} ]] || die 2 "not whole ms: ${milliseconds}"
  log INFO "CHANGE: ${proxy} delays each direction by ${milliseconds} ms"
  toxic::add "${proxy}" latency_up upstream "latency:latency=${milliseconds}"
  toxic::add "${proxy}" latency_down downstream "latency:latency=${milliseconds}"
}

# Make a link silent: it keeps the connection open and swallows everything sent, the failure a
# dead switch or a firewall that drops packets produces. Neither end sees a reset.
# Usage: toxic::silence PROXY
toxic::silence() {
  local proxy="${1:?proxy required}"

  log INFO "CHANGE: ${proxy} swallows all data and keeps its connections open"
  toxic::add "${proxy}" silence_up upstream timeout:timeout=0
  toxic::add "${proxy}" silence_down downstream timeout:timeout=0
}

# Print enabled or disabled for a proxy.
# Usage: toxic::state PROXY
toxic::state() {
  local proxy="${1:?proxy required}"
  local listing
  local line
  local -a fields=()

  listing="$(toxic::cli list)"
  while IFS= read -r line; do
    read -r -a fields <<< "${line}"
    if [[ "${fields[0]-}" == "${proxy}" ]]; then
      printf '%s\n' "${fields[3]}"
      return 0
    fi
  done <<< "${listing}"
  die 1 "no proxy named ${proxy}"
}

# Cut a link: the proxy refuses and closes connections until toxic::heal.
# Usage: toxic::cut PROXY
toxic::cut() {
  local proxy="${1:?proxy required}"

  log INFO "CHANGE: ${proxy} is cut"
  if [[ "$(toxic::state "${proxy}")" == 'enabled' ]]; then
    toxic::cli toggle "${proxy}" > /dev/null
  fi
}

# Put every proxy back to normal: remove our toxics and enable any cut proxy. Safe to repeat.
toxic::heal() {
  local listing
  local line
  local proxy
  local toxic
  local inspected
  local -a fields=()
  local -a names=(latency_up latency_down silence_up silence_down)

  log INFO 'CHANGE: healing every proxy'
  listing="$(toxic::cli list)"
  while IFS= read -r line; do
    read -r -a fields <<< "${line}"
    proxy="${fields[0]-}"
    [[ -n "${proxy}" ]] || continue
    inspected="$(toxic::cli inspect "${proxy}")"
    for toxic in "${names[@]}"; do
      if [[ "${inspected}" == *"${toxic}"$'\t'* ]]; then
        toxic::cli toxic remove --toxicName "${toxic}" "${proxy}" > /dev/null
      fi
    done
    if [[ "${fields[3]}" == 'disabled' ]]; then
      toxic::cli toggle "${proxy}" > /dev/null
    fi
  done <<< "${listing}"
}
