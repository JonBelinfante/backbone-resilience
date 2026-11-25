# script-kind: library
# Purpose: Fence a node: mark its data directory so that any start of it is read-only.
# Usage: source "${SCRIPT_DIR}../lib/fence.sh", then call fence::apply, lift or is_applied
# Requires: docker
# Depends: container
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly FENCE_MARKER='standby.signal'

# Run a short shell program in a throwaway container that mounts the node's data volume. The node
# may be running or stopped; the program sees the data directory as its first argument.
# Usage: fence::in_volume NODE PROGRAM
fence::in_volume() {
  local node="${1:?node required}"
  local program="${2:?program required}"
  local image
  local volume
  local data_dir='/var/lib/postgresql/data'

  image="$(container::image "${node}")"
  volume="$(container::volume "${node}")"
  docker run \
    --rm \
    --user postgres \
    --volume "${volume}:${data_dir}" \
    --entrypoint sh \
    "${image}" \
    -c "${program}" \
    sh \
    "${data_dir}"
}

# Fence a node: leave a standby.signal in its data directory. Postgres reads it at the next start
# and comes up in recovery, read-only, however it is started and by whom. A node that is running
# is not affected until it restarts: stopping it first (STONITH) is the controller's job.
# Usage: fence::apply NODE
fence::apply() {
  local node="${1:?node required}"

  log INFO "CHANGE: fencing ${node}: its next start will be read-only"
  fence::in_volume "${node}" "touch \"\$1/${FENCE_MARKER}\""
}

# Lift the fence. Only a deliberate test of the unfenced behaviour does this: a real rebuild
# replaces the marker with a full standby configuration.
# Usage: fence::lift NODE
fence::lift() {
  local node="${1:?node required}"

  log INFO "CHANGE: lifting the fence on ${node}"
  fence::in_volume "${node}" "rm -f \"\$1/${FENCE_MARKER}\""
}

# Print yes if the node's data directory carries the fence marker, otherwise no.
# Usage: fence::is_applied NODE
fence::is_applied() {
  local node="${1:?node required}"

  if fence::in_volume "${node}" "test -e \"\$1/${FENCE_MARKER}\""; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}
