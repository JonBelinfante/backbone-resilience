# script-kind: library
# Purpose: Keep the failover epoch: a number that only goes up, one step per failover.
# Usage: source "${SCRIPT_DIR}../lib/epoch.sh", then call epoch::read and epoch::advance
# Requires: mv
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly EPOCH_PATTERN='^[0-9]+$'

# Print the current epoch stored in the file; 0 if the file does not exist yet.
# Usage: epoch::read FILE
epoch::read() {
  local file="${1:?epoch file required}"
  local value

  if [[ ! -e "${file}" ]]; then
    printf '0\n'
    return 0
  fi
  value="$(< "${file}")"
  [[ "${value}" =~ ${EPOCH_PATTERN} ]] || die 1 "the epoch file ${file} does not hold a number"
  printf '%s\n' "${value}"
}

# Raise the epoch by one and print the new value. The new number is written beside the file and
# moved into place, so a kill leaves the old or the new epoch, never half of one.
# Usage: epoch::advance FILE
epoch::advance() {
  local file="${1:?epoch file required}"
  local current
  local next

  current="$(epoch::read "${file}")"
  next=$(( current + 1 ))
  printf '%s\n' "${next}" > "${file}.new"
  mv "${file}.new" "${file}"
  log INFO "CHANGE: the epoch goes from ${current} to ${next}"
  printf '%s\n' "${next}"
}
