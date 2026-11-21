# script-kind: library
# Purpose: Inject faults into the database containers, so an experiment can cause a failure.
# Usage: source "${SCRIPT_DIR}../lib/fault.sh", then call fault::stop_streaming and the others
# Requires: none
# Depends: container database
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly FAULT_INTEGER_PATTERN='^[0-9]+$'
readonly FAULT_RESET_DELAY_SQL='alter system reset recovery_min_apply_delay'
readonly FAULT_RELOAD_SQL='select pg_reload_conf()'
readonly FAULT_STOP_STREAMING_SQL="alter system set primary_conninfo = ''; select pg_reload_conf()"

# Make a standby stop following its writer: clear primary_conninfo and reload, so the WAL receiver
# ends and the standby no longer receives anything. The writer keeps accepting writes that the
# standby will never see. The standby's settings stay changed until it is rebuilt or given a new
# primary_conninfo (restore-starting-state.sh does the latter by rebuilding it).
# Usage: fault::stop_streaming STANDBY_CONTAINER
fault::stop_streaming() {
  local container="${1:?container required}"

  log INFO "CHANGE: ${container} stops following its writer (primary_conninfo cleared)"
  database::run "${container}" <<< "${FAULT_STOP_STREAMING_SQL}" > /dev/null
}

# Make a standby apply changes late: it keeps receiving WAL but applies each commit only after the
# given number of seconds, so reads on it are stale by that long. Needs no network tools.
# Usage: fault::set_apply_delay STANDBY_CONTAINER SECONDS
fault::set_apply_delay() {
  local container="${1:?container required}"
  local seconds="${2:?seconds required}"
  local sql="alter system set recovery_min_apply_delay = '${seconds}s'; ${FAULT_RELOAD_SQL}"

  [[ "${seconds}" =~ ${FAULT_INTEGER_PATTERN} ]] || die 2 "not whole seconds: ${seconds}"
  log INFO "CHANGE: ${container} applies changes ${seconds} seconds late"
  database::run "${container}" <<< "${sql}" > /dev/null
}

# Remove the apply delay again, so the standby catches up and reads are fresh.
# Usage: fault::reset_apply_delay STANDBY_CONTAINER
fault::reset_apply_delay() {
  local container="${1:?container required}"
  local sql="${FAULT_RESET_DELAY_SQL}; ${FAULT_RELOAD_SQL}"

  log INFO "CHANGE: ${container} applies changes without delay again"
  database::run "${container}" <<< "${sql}" > /dev/null
}

# Write WAL on a node without changing any table: each message is about 8 MB of log record, and
# each is a separate write, so a checkpoint can recycle the WAL behind them. Use it to fill the WAL
# of a writer whose standby is down.
# Usage: fault::generate_wal CONTAINER MESSAGES
fault::generate_wal() {
  local container="${1:?container required}"
  local messages="${2:?message count required}"
  local sql

  [[ "${messages}" =~ ${FAULT_INTEGER_PATTERN} ]] || die 2 "not a whole number: ${messages}"
  sql="select count(pg_logical_emit_message(false, 'wal-filler', repeat('x', 8000000)))"
  sql+=" from generate_series(1, ${messages})"
  log INFO "CHANGE: ${container} writes ${messages} large WAL messages"
  database::run "${container}" <<< "${sql}" > /dev/null
}

# Crash a node: kill it with SIGKILL, so it cannot shut down cleanly or send its last WAL.
# Usage: fault::crash_node CONTAINER
fault::crash_node() {
  local container="${1:?container required}"

  log INFO "CHANGE: ${container} crashes"
  container::kill "${container}"
}

# Partition a node: cut it off the network but keep it running. Writes on the other node continue
# and never reach it, so the gap grows until fault::reconnect_node.
# Usage: fault::isolate_node CONTAINER
fault::isolate_node() {
  local container="${1:?container required}"

  log INFO "CHANGE: ${container} is isolated from the network"
  container::disconnect "${container}"
}

# Heal the partition of fault::isolate_node. Safe to call when the node is attached.
# Usage: fault::reconnect_node CONTAINER
fault::reconnect_node() {
  local container="${1:?container required}"

  log INFO "CHANGE: ${container} is back on the network"
  container::connect "${container}"
}

# Make commits on a node wait only for the local flush (synchronous_commit = local) or put the
# default back. With a synchronous standby named, local lets a crash lose acknowledged writes:
# it is the negative control for the zero-loss claim.
# Usage: fault::set_commit_level CONTAINER local|default
fault::set_commit_level() {
  local container="${1:?container required}"
  local level="${2:?level required}"
  local sql

  log INFO "CHANGE: ${container} commits at level ${level}"
  case "${level}" in
    local)
      sql="alter system set synchronous_commit = 'local'; ${FAULT_RELOAD_SQL}"
      ;;
    default)
      sql="alter system reset synchronous_commit; ${FAULT_RELOAD_SQL}"
      ;;
    *)
      die 2 "commit level is local or default, got: ${level}"
      ;;
  esac
  database::run "${container}" <<< "${sql}" > /dev/null
}
