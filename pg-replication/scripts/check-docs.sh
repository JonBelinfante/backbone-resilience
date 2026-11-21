#!/usr/bin/env bash
# script-kind: executable
# Purpose: Check that the documents' relative links resolve and that the functions they name exist.
# Usage: check-docs.sh [-h | --help]
# Requires: awk cat find mktemp sort
# Exit codes: 0 every reference resolves, 1 a reference is broken, 2 usage or configuration error

set -Eeuo pipefail

if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 500 )); then
  printf '%s requires Bash 5.0 or later\n' "${0##*/}" >&2
  exit 1
fi

shopt -s inherit_errexit
export LC_COLLATE=C

# Environment: TEMP_DIR is where the temporary definitions file goes (default: temporary directory).
# RUN_LOG_DIR is the run log directory (see runtime.sh).
readonly TEMP_DIR="${TEMP_DIR:-${TMPDIR:-/tmp}}"

readonly SCRIPT_NAME="${0##*/}"
# SCRIPT_DIR is the folder the script was started from, with its trailing slash (empty when
# started by its bare name), so paths to sibling files work however the script is started.
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
readonly ROOT_DIR="${SCRIPT_DIR}.."
readonly AWK_PROGRAM="${SCRIPT_DIR}check-docs.awk"

# shellcheck source=./runtime.sh
source "${SCRIPT_DIR}runtime.sh"

# Print how to run this script.
usage() {
  cat <<'USAGE'
Usage: check-docs.sh [-h | --help]

Checks every markdown document in this project (read-only):

  1. Links: each relative link points to a file or folder that exists.
  2. Names: each function name written in backticks (such as check_round_trip) is defined in one
     of the repository's shell scripts. Names starting with pg_ are PostgreSQL's own and are skipped.
  3. Pairs: where a line links a script and names a function, that function must be defined in one
     of the scripts the line links to.

Prints one line per problem and exits 1. Fix the document, or the code it describes.

Only the pages in docs/ are checked for named functions: the other documents also name PostgreSQL
settings and columns. Paths in the report are shown as the script found them, from the folder it was started in.

Environment: TEMP_DIR is where the temporary definitions file is written (default: temporary directory).
RUN_LOG_DIR is the run log directory (default: temporary directory).

Exit codes: 0 every reference resolves, 1 a reference is broken, 2 usage or configuration error
USAGE
}

# Print a path in normal form: resolve . and .. and drop repeated slashes.
# Usage: normalise_path PATH
normalise_path() {
  local path="${1:?path required}"
  local -a parts=()
  local -a kept=()
  local part
  local joined=''
  local prefix=''

  if [[ "${path}" == /* ]]; then
    prefix='/'
  fi
  IFS='/' read -r -a parts <<< "${path}"
  for part in "${parts[@]}"; do
    case "${part}" in
      '..')
        if [[ "${#kept[@]}" -gt 0 && "${kept[-1]-}" != '..' ]]; then
          unset 'kept[-1]'
        else
          kept+=('..')
        fi
        ;;
      *)
        if [[ -n "${part}" && "${part}" != '.' ]]; then
          kept+=("${part}")
        fi
        ;;
    esac
  done
  for part in "${kept[@]}"; do
    joined+="${part}/"
  done
  printf '%s%s\n' "${prefix}" "${joined%/}"
}

# List files under a folder (default: repository root) matching a pattern, sorted, one per line.
# Usage: list_files PATTERN [FOLDER]
list_files() {
  local pattern="${1:?pattern required}"
  local folder="${2:-${ROOT_DIR}}"
  local listing
  local path

  listing="$(find "${folder}" -name "${pattern}" -not -path '*/logs/*' | sort)"
  while IFS= read -r path; do
    if [[ -n "${path}" ]]; then
      normalise_path "${path}"
    fi
  done <<< "${listing}"
}

# Run check-docs.awk in one mode over the files in a listing, and print its output. Any further
# arguments are passed to awk before the program, for example -v name=value.
# Usage: run_awk MODE LISTING [AWK_ARGUMENT ...]
run_awk() {
  local mode="${1:?mode required}"
  local listing="${2:?listing required}"
  local -a options=("${@:3}")
  local -a files=()

  if [[ -n "${listing}" ]]; then
    mapfile -t files <<< "${listing}"
    awk -v "mode=${mode}" "${options[@]}" -f "${AWK_PROGRAM}" "${files[@]}"
  fi
}

# Print a problem for each relative link whose target does not exist.
# Usage: check_links LISTING
check_links() {
  log INFO 'checking relative links'
  local listing="${1:?listing required}"
  local links
  local line
  local doc
  local dir
  local target

  links="$(run_awk links "${listing}")"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    doc="${line%%$'\t'*}"
    target="${line#*$'\t'}"
    dir="${doc%/*}"
    if [[ "${dir}" == "${doc}" ]]; then
      dir='.'
    fi
    if [[ ! -e "$(normalise_path "${dir}/${target}")" ]]; then
      printf 'BROKEN LINK %s -> %s\n' "${doc}" "${target}"
    fi
  done <<< "${links}"
}

# Write the function definitions in the scripts to a temporary file, one "file<TAB>name" per line.
# Usage: write_definitions LISTING FILE
write_definitions() {
  log INFO 'indexing function definitions'
  local listing="${1:?listing required}"
  local file="${2:?file required}"

  run_awk definitions "${listing}" > "${file}"
}

# Run the link and name checks on the documents and print the problems found.
# The temporary file is made by the caller, because a file registered for clean-up inside a
# command substitution (a subshell) would never be removed.
# Usage: check_documents DOCS CODE DEFINITIONS_FILE
check_documents() {
  local docs="${1:?docs required}"
  local code="${2:?code required}"
  local definitions_file="${3:?definitions file required}"

  write_definitions "${code}" "${definitions_file}"
  run_awk pairs "${docs}" -v "definitions_file=${definitions_file}"
}

# Run the checks in order and report the result.
run_checks() {
  log INFO 'checking the documents'
  local docs
  local pages
  local code
  local report
  local definitions_file
  local -a findings=()

  definitions_file="$(mktemp "${TEMP_DIR}/${SCRIPT_NAME}-definitions.XXXXXX")"
  CLEANUP_PATHS+=("${definitions_file}")
  docs="$(list_files '*.md')"
  pages="$(list_files '*.md' "${ROOT_DIR}/docs")"
  code="$(list_files '*.sh')"
  report="$(check_links "${docs}"; check_documents "${pages}" "${code}" "${definitions_file}")"
  if [[ -n "${report}" ]]; then
    printf '%s\n' "${report}"
    mapfile -t findings <<< "${report}"
    die 1 "${#findings[@]} reference problem(s) found in the documents"
  fi
  printf 'PASS: every relative link resolves and every named function exists\n'
}

# Script entry point.
main() {
  start_run_log "$@"

  while (( $# > 0 )); do
    case "${1}" in
      -h | --help)
        usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die 2 "unknown option: ${1} (try --help)"
        ;;
      *)
        die 2 "unexpected argument: ${1} (try --help)"
        ;;
    esac
  done

  (( $# == 0 )) || die 2 "unexpected argument: ${1} (try --help)"
  require_commands awk cat find mktemp sort
  run_checks
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

trap_signals

main "$@"
