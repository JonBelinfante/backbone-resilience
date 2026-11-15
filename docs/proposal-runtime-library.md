# Proposal: one runtime library for the Bash standard

**For:** the author of the bash-standard plugin. **Status:** proposal, prototyped and run; design decisions taken
(plain names, no version pin); waiting for the plugin to accept it. Not applied to any script.
**Date:** 2026-11-14. **Standard version it was tried against:** 5.

## Problem

Every script must carry the same six functions, copied exactly (rules CLI-009, OBS-004, STX-004):
`log`, `die`, `on_error`, `require_commands`, `start_run_log`, `cleanup`. In this repository that is
**18 scripts with identical copies**: 54 lines of function bodies per script, plus comments, blank lines, and
the state declarations. The standard's own text says they are copied "for now".

Cost seen so far:

- When `log` moved to millisecond timestamps, all 18 copies had to be rewritten.
- The copies take space in every script, which is a problem near the 400-line limit (LAY-010): three scripts are
  already over 300 lines.
- None of it is specific to what a script does, which hides the part a reviewer wants to read.

Libraries are now allowed (LIB-001), but the standard's rules stop the runtime blocks moving into one (below).

## What a library cannot do today

| Rule | Why it blocks the move |
|---|---|
| NAM-001, STX-103 | Library functions must be `name::function`. `log` would become `runtime::log`, and every `log INFO` call changes |
| STX-101 | A library's top level may hold only functions and `readonly` constants. The runtime needs two mutable state variables, `RUN_LOG` and `CLEANUP_PATHS` |
| CFG-002 | The `RUN_LOG_DIR` environment import is in the script's environment block, not a library |
| REQ-002 | A library calling another library's function counts as an external command and cannot be listed in `# Requires:`. So `story.sh`, `container.sh` and `database.sh` can only call `log` and `die` as the importing script's own functions |
| CLI-009, OBS-001 to OBS-005, STX-004, TIR-003 | These demand the canonical text of each function inside every script |

## Proposed change

1. **One reserved library, `runtime.sh`** (next to the other libraries, imported first), defining the six functions
   under their plain names and holding the state. It is the only library allowed to use plain function names
   and to declare `RUN_LOG`, `CLEANUP_PATHS` and the `RUN_LOG_DIR` import.
2. **Scripts stop defining them.** A script keeps: `SCRIPT_NAME`, `SCRIPT_DIR`, its `usage` text, the two `trap`
   lines, `check_environment`, and `main`. It adds one import line after its constants.
3. **The checker verifies the canonical text once**, in `lib/runtime.sh`, instead of in every script. For
   scripts it checks the import exists (as the first import) and that the traps and `main` call the right names.
4. **Other libraries may call the runtime functions** (`log`, `die`) without listing them in `# Requires:`.
5. **`# Requires:` ignores commands run inside `runtime.sh`**: a script that does not itself run `date` or `rm`
   no longer lists them.
6. **Bootstrap rule:** the import comes straight after the version guard and `shopt`. If the library is missing
   the script stops at that line with Bash's own message and status 1 (tested, below).

## Draft of the library

This is the code that was run in the prototype. Its six functions are the current canonical blocks, unchanged
except that `${SCRIPT_NAME}` became `${0##*/}` (`$0` is the main script's name inside a sourced file).

```bash
# script-kind: library
# Purpose: The standard's runtime blocks, once: log, die, error trace, run log, clean-up.
# Usage: source "${SCRIPT_DIR}../lib/runtime.sh" after the constants; keep the two traps in the script

readonly RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}}"
declare RUN_LOG=''
declare -a CLEANUP_PATHS=()

# Append a line to the run log and, for WARN and ERROR, to standard error.
log() {
  local level="${1:?level required}"
  local message="${2:?message required}"
  local now="${EPOCHREALTIME}"
  local fraction="${now#*[.,]}"
  local stamp
  local line

  TZ=UTC printf -v stamp '%(%Y-%m-%dT%H:%M:%S)T' "${now%%[.,]*}"
  line="${stamp}.${fraction:0:3}Z ${level} ${message}"
  if [[ -n "${RUN_LOG}" ]]; then
    printf '%s\n' "${line}" >> "${RUN_LOG}"
  fi
  if [[ "${level}" != 'INFO' ]]; then
    printf '%s: %s\n' "${0##*/}" "${line}" >&2
  fi
}

# Log an error, then exit with the given status.
die() {
  local status="${1:?status required}"
  local message="${2:?message required}"

  log ERROR "${message}"
  exit "${status}"
}

# Log where a command failed: its line, the function it was in, and the command itself.
on_error() {
  local status="${?}"
  local line_no="${1:?line required}"
  local command_text="${2:?command required}"
  local where="${FUNCNAME[1]:-main}"

  log ERROR "failed (status ${status}) at line ${line_no} in ${where}: ${command_text}"
}

# Fail early if a required command is missing.
require_commands() {
  local cmd

  for cmd in "$@"; do
    command -v "${cmd}" > /dev/null || die 1 "missing required command: ${cmd}"
  done
}

# Create this run's log file in RUN_LOG_DIR and record the start.
start_run_log() {
  local stamp

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_LOG="$(mktemp "${RUN_LOG_DIR}/${0##*/}-${stamp}.XXXXXX")"
  log INFO "started ${0##*/}"
}

# Record how the run ended, then remove temporary files created by this script.
cleanup() {
  local status="${?}"

  log INFO "finished with status ${status}"
  if (( ${#CLEANUP_PATHS[@]} > 0 )); then
    rm -f -- "${CLEANUP_PATHS[@]}"
  fi
}
```

What a script looks like with it (extract, from the prototype of `verify-replication.sh`):

```bash
set -Eeuo pipefail
# ... version guard, shopt ...
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="${0%"${SCRIPT_NAME}"}"
# shellcheck source=../lib/runtime.sh
source "${SCRIPT_DIR}../lib/runtime.sh"
# shellcheck source=../lib/database.sh
source "${SCRIPT_DIR}../lib/database.sh"
# ... usage, the script's own functions, main ...
trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

main "$@"
```

## Evidence from the prototype

Built outside the repository with the repository's own canonical text, then run against the live stack.

- `verify-replication.sh` converted: **318 lines became 251 (-67, 21%)**, plus a shared 73-line library. It ran and
  passed: `PASS: replication is working`, with a run log written by the library functions
  (`2026-11-14T11:01:32.444Z INFO started verify-replication.sh` and so on).
- A probe script exercised the failure paths. Each behaved exactly like today's per-script copies:

| Case | Exit | Observed |
|---|---|---|
| normal run | 0 | start, message and `finished with status 0` in the run log; temp file removed by `cleanup` |
| `die 2 '...'` | 2 | `ERROR` on stderr and in the log; temp file removed |
| `die` inside `$(...)` | 3 | `ERROR` plus the `on_error` trace `at line 20 in main: value="$(die ...)"` |
| failing command inside a function | 1 | `ERROR failed (status 1) at line 10 in fails_in_a_function: false`; log ends with the status |
| `runtime.sh` missing | 1 | Bash's `No such file or directory` at the import line; the script does not continue |

- Estimated effect across this repository: about **67 fewer lines per script, around 1,200 lines in total**.
  `test-failover-roundtrip.sh` would drop from 360 to roughly 295 lines.

## Decisions

| Decision | Outcome (2026-11-14) | Consequence |
|---|---|---|
| Plain names or `runtime::log` | **Plain names.** `log`, `die`, `on_error`, `require_commands`, `start_run_log` and `cleanup` keep their names | `log INFO ...` calls do not change. The standard needs one reserved exception to NAM-001 and STX-103 for `runtime.sh`, and libraries calling `log` and `die` need the REQ-002 exemption (changes 1 and 4 above) |
| Pin the library version in each script | **No, not yet.** Scripts do not check a library version string | A script and the library could drift apart. The prototype shows a missing library fails at the import line, but a changed library would not be detected. Revisit if the library starts changing independently of the scripts |

## Remaining notes for the standard's author

| Topic | Note |
|---|---|
| Self-containment | A script no longer runs on its own if the library is missing. Tested: it stops at the import line with status 1 and Bash's own message |
| Hidden state | `RUN_LOG` and `CLEANUP_PATHS` become shared globals declared by the library. They already are globals, so behaviour is unchanged; only the declaring file changes |
| The checker cannot follow imports (F9) | It cannot see that a script really gets the right `log`. Check `runtime.sh` against the reference, and check that each script imports it first |
| Version bump | The change makes the standard version 6; every existing script needs the same mechanical edit (migration plan below) |

## Migration plan (once the standard accepts the change)

Mechanical, scripted, and verified by the regression net:

1. Add `lib/runtime.sh` (the draft above, as accepted).
2. For each script: delete the six functions and their comments, the `RUN_LOG_DIR` import, and the
   `RUN_LOG` and `CLEANUP_PATHS` declarations; add the import line; drop `date`, `mktemp` and `rm` from
   `# Requires:` where the script no longer runs them itself.
3. Run `bash pg-replication/scripts/run-all-checks.sh` (lint of every script, then the 17-step round trip). It must
   end `ALL PASSED`.
4. Re-save the refactor baseline and update the README and `CLAUDE.md`.

The edit in step 2 is the same one done by hand in the prototype; it can be applied to the 18 scripts in one
pass and reviewed as one commit.
