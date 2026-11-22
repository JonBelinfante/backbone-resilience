# script-kind: library
# Purpose: Keep the failover epoch: a number that only goes up, one step per failover.
# Usage: source "${SCRIPT_DIR}../lib/epoch.sh", then call epoch::read and epoch::advance
# Requires: mv rm
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

# Start a failover and print its epoch. If an earlier attempt began one and did not finish, that
# epoch is printed again, so a restarted actor does not spend a second number on the same failover.
# Usage: epoch::begin FILE
epoch::begin() {
  local file="${1:?epoch file required}"
  local pending="${file}.pending"

  if [[ -e "${pending}" ]]; then
    log INFO 'an earlier failover attempt is unfinished: resuming it'
    epoch::read "${file}"
    return 0
  fi
  epoch::advance "${file}"
  printf 'unfinished\n' > "${pending}"
}

# Mark the failover begun by epoch::begin as finished.
# Usage: epoch::finish FILE
epoch::finish() {
  local file="${1:?epoch file required}"

  rm -f "${file}.pending"
}

# Succeed if a failover begun by epoch::begin has not been finished.
# Usage: epoch::is_unfinished FILE
epoch::is_unfinished() {
  local file="${1:?epoch file required}"

  [[ -e "${file}.pending" ]]
}
