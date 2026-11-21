# script-kind: library
# Purpose: One maintenance lock, so a secret rotation, a rebuild and a role change never overlap.
# Usage: source "${SCRIPT_DIR}../lib/lock.sh", then call lock::acquire PARENT_FOLDER PURPOSE
# Requires: mkdir ps rm
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly LOCK_NAME='pg-replication-maintenance.lock'
readonly LOCK_HOLDER_FILE='holder'

# Print when a process started, as ps reports it; print nothing if the process does not exist.
# Usage: lock::started_at PID
lock::started_at() {
  local pid="${1:?pid required}"
  local started

  started="$(ps -o lstart= -p "${pid}" 2> /dev/null)" || return 0
  printf '%s\n' "${started}"
}

# Succeed if the process with the given id is the current process or one of its ancestors, so a
# script started by the holder of the lock may enter it again.
# Usage: lock::is_ancestor PID
lock::is_ancestor() {
  local wanted="${1:?pid required}"
  local current="$$"

  while [[ -n "${current}" && "${current}" != '0' && "${current}" != '1' ]]; do
    if [[ "${current}" == "${wanted}" ]]; then
      return 0
    fi
    current="$(ps -o ppid= -p "${current}" 2> /dev/null)" || return 1
    current="${current// /}"
  done
  return 1
}

# Take the maintenance lock, or stop if another run holds it. The lock is a folder made with
# mkdir (atomic) that records the holder's process id, when that process started, and why. It is
# held only while that process lives: a run that ended, or was killed, leaves a folder that the
# next run takes over without fuss. A script started by the holder may enter again. Recording the
# start time stops a reused process id from keeping a dead run's lock alive.
# Usage: lock::acquire PARENT_FOLDER PURPOSE
lock::acquire() {
  local parent="${1:?parent folder required}"
  local purpose="${2:?purpose required}"
  local folder="${parent}/${LOCK_NAME}"
  local holder_pid
  local holder_started
  local holder_purpose

  if [[ -r "${folder}/${LOCK_HOLDER_FILE}" ]]; then
    IFS='|' read -r holder_pid holder_started holder_purpose < "${folder}/${LOCK_HOLDER_FILE}"
    if [[ "$(lock::started_at "${holder_pid}")" == "${holder_started}" ]]; then
      lock::is_ancestor "${holder_pid}" && return 0
      die 1 "maintenance is locked by ${holder_purpose} (process ${holder_pid}): try later"
    fi
    log INFO "the previous holder of the maintenance lock (${holder_purpose}) has ended"
    rm -rf -- "${folder:?}"
  fi
  mkdir -- "${folder}" || die 1 'maintenance is locked: another run took the lock first'
  printf '%s|%s|%s\n' "$$" "$(lock::started_at "$$")" "${purpose}" > "${folder}/${LOCK_HOLDER_FILE}"
  log INFO "CHANGE: took the maintenance lock for ${purpose}"
}
