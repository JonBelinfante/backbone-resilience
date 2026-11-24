# script-kind: library
# Purpose: Remember the replication mode that was asked for, so a rejoin can put it back.
# Usage: source "${SCRIPT_DIR}../lib/mode.sh", then call mode::record and mode::wanted
# Requires: mv
# Exit codes: none (the functions return, or call die of the script that imported them)

readonly MODE_FILE_NAME='replication-mode'

# Record the mode (async or sync) in a file in the folder. The file is written whole and moved
# into place, so a kill leaves the old mode or the new one.
# Usage: mode::record FOLDER MODE
mode::record() {
  local folder="${1:?folder required}"
  local mode="${2:?mode required}"
  local file="${folder}/${MODE_FILE_NAME}"

  case "${mode}" in
    async | sync)
      printf '%s\n' "${mode}" > "${file}.new"
      mv "${file}.new" "${file}"
      log INFO "CHANGE: the wanted replication mode is now ${mode}"
      ;;
    *)
      die 2 "not a replication mode: ${mode}"
      ;;
  esac
}

# Print the mode last recorded in the folder: async if none was recorded.
# Usage: mode::wanted FOLDER
mode::wanted() {
  local folder="${1:?folder required}"
  local file="${folder}/${MODE_FILE_NAME}"
  local mode

  if [[ ! -e "${file}" ]]; then
    printf 'async\n'
    return 0
  fi
  mode="$(< "${file}")"
  printf '%s\n' "${mode}"
}
