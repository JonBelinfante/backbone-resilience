# Proposal: one runtime library for the Bash standard

<!-- toc -->

- [Problem](#problem)
- [What a library cannot do today](#what-a-library-cannot-do-today)
- [Proposed change](#proposed-change)
- [Draft of the library](#draft-of-the-library)
- [Evidence from the prototype](#evidence-from-the-prototype)
- [Decisions](#decisions)
- [Remaining notes for the standard's author](#remaining-notes-for-the-standards-author)
- [Migration plan, once the standard accepts the change](#migration-plan-once-the-standard-accepts-the-change)
- [Outcome (2026-11-15)](#outcome-2026-11-15)

<!-- tocstop -->

**For:** the author of the bash-standard plugin.

**Status:** The plugin accepted the proposal in bash-standard 0.5.0, which is standard version 6, on 2026-11-15. The differences are noted below, and the proposal has been applied to the host scripts. This page is kept for the reasoning and the prototype evidence.

**Date:** 2026-11-14. The proposal was tried against standard version 5.

## Problem

Every script must carry the same six functions, copied exactly. The rules are CLI-009, OBS-004 and STX-004. The functions are `log`, `die`, `on_error`, `require_commands`, `start_run_log` and `cleanup`. In this repository there were **18 scripts with identical copies**. Each script held 54 lines of function bodies, plus comments, blank lines and the state declarations. The standard's own text says that the functions are copied "for now".

The copies cost the project in three ways.

- When `log` moved to millisecond timestamps, all 18 copies had to be rewritten.
- The copies take space in every script. That is a problem near the 400-line limit (LAY-010), and three scripts were already over 300 lines.
- None of the copied code is specific to what a script does, so it hides the part that a reviewer wants to read.

Libraries are now allowed (LIB-001). However, the standard's rules stop the runtime blocks from moving into one, as the next section shows.

## What a library cannot do today

| Rule | Why it blocks the move |
|---|---|
| NAM-001 and STX-103 | Library functions must be named `name::function`. The function `log` would become `runtime::log`, and every `log INFO` call would change. |
| STX-101 | A library's top level may hold only functions and `readonly` constants. The runtime needs two mutable state variables, `RUN_LOG` and `CLEANUP_PATHS`. |
| CFG-002 | The `RUN_LOG_DIR` environment import belongs to the script's environment block and not to a library. |
| REQ-002 | A library that calls another library's function counts as running an external command, and it cannot be listed in `# Requires:`. So `story.sh`, `container.sh` and `database.sh` can call `log` and `die` only as the importing script's own functions. |
| CLI-009, OBS-001 to OBS-005, STX-004 and TIR-003 | These demand the canonical text of each function inside every script. |

## Proposed change

1. **Add one reserved library, `runtime.sh`.** It sits next to the other libraries and is imported first. It defines the six functions under their plain names and holds the state. It is the only library that may use plain function names. It is also the only library that may declare `RUN_LOG`, `CLEANUP_PATHS` and the `RUN_LOG_DIR` import.
2. **Scripts stop defining the functions.** A script keeps `SCRIPT_NAME`, `SCRIPT_DIR`, its `usage` text, the two `trap` lines, `check_environment` and `main`. It adds one import line after its constants.
3. **The checker verifies the canonical text once**, in `lib/runtime.sh`, instead of in every script. For each script it checks that the import exists, as the first import, and that the traps and `main` call the right names.
4. **Other libraries may call the runtime functions** `log` and `die` without listing them in `# Requires:`.
5. **`# Requires:` ignores commands that run inside `runtime.sh`.** A script that does not itself run `date` or `rm` no longer lists them.
6. **Bootstrap rule.** The import comes straight after the version guard and `shopt`. If the library is missing, the script stops at that line with Bash's own message and status 1. The prototype tested this.

## Draft of the library

This is the code that ran in the prototype. Its six functions are the current canonical blocks, unchanged except for one point. The text `${SCRIPT_NAME}` became `${0##*/}`, because `$0` holds the main script's name inside a sourced file.

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

This extract from the prototype of `verify-replication.sh` shows what a script looks like with the library.

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

The prototype was built outside the repository with the repository's own canonical text. It was then run against the live stack.

- The converted `verify-replication.sh` shrank from 318 lines to 251, which is 67 lines or 21 per cent. A shared library of 73 lines was added. The script ran and passed with `PASS: replication is working`. The library functions wrote its run log, which began `2026-11-14T11:01:32.444Z INFO started verify-replication.sh`.
- A probe script exercised the failure paths. Each behaved exactly like today's per-script copies.

| Case | Exit status | Observed |
|---|---|---|
| A normal run. | 0 | The run log held the start, the message and `finished with status 0`, and `cleanup` removed the temporary file. |
| `die 2 '...'`. | 2 | The `ERROR` line appeared on standard error and in the log, and the temporary file was removed. |
| `die` inside `$(...)`. | 3 | The `ERROR` line appeared with the `on_error` trace `at line 20 in main: value="$(die ...)"`. |
| A failing command inside a function. | 1 | The log showed `ERROR failed (status 1) at line 10 in fails_in_a_function: false`, and it ended with the status. |
| `runtime.sh` missing. | 1 | Bash said `No such file or directory` at the import line, and the script did not continue. |

The estimated effect across this repository is about 67 fewer lines for each script, and around 1,200 lines in total. The script `test-failover-roundtrip.sh` would drop from 360 lines to roughly 295.

## Decisions

| Decision | Outcome on 2026-11-14 | Consequence |
|---|---|---|
| Plain names or `runtime::log`. | **Plain names.** The six functions keep their names. | The `log INFO ...` calls do not change. The standard needs one reserved exception to NAM-001 and STX-103 for `runtime.sh`. Libraries that call `log` and `die` need the REQ-002 exemption, which are changes 1 and 4 above. |
| Pin the library version in each script. | **No, not yet.** Scripts do not check a library version string. | A script and the library could drift apart. The prototype shows that a missing library fails at the import line, but a changed library would not be detected. Revisit this if the library starts changing independently of the scripts. |

## Remaining notes for the standard's author

| Topic | Note |
|---|---|
| Self-containment. | A script no longer runs on its own if the library is missing. The test showed that it stops at the import line with status 1 and Bash's own message. |
| Hidden state. | `RUN_LOG` and `CLEANUP_PATHS` become shared globals that the library declares. They already are globals, so behaviour does not change. Only the declaring file changes. |
| The checker cannot follow imports (F9). | It cannot see that a script really gets the right `log`. Check `runtime.sh` against the reference, and check that each script imports it first. |
| Version bump. | The change makes the standard version 6. Every existing script needs the same mechanical edit, which the migration plan below describes. |

## Migration plan, once the standard accepts the change

The plan is mechanical and scripted, and the regression net verifies it.

1. Add `lib/runtime.sh`, which is the draft above as accepted.
2. For each script, delete the six functions and their comments, the `RUN_LOG_DIR` import, and the `RUN_LOG` and `CLEANUP_PATHS` declarations. Add the import line. Drop `date`, `mktemp` and `rm` from `# Requires:` where the script no longer runs them itself.
3. Run `bash pg-replication/scripts/run-all-checks.sh`. It lints every script and then runs the 17-step round trip. It must end with `ALL PASSED`.
4. Save the refactor baseline again, and update the README and `CLAUDE.md`.

The edit in step 2 is the same one that was done by hand in the prototype. It can be applied to the 18 scripts in one pass and reviewed as one commit.

## Outcome (2026-11-15)

The plugin accepted the proposal, with these differences from the draft above.

- The file `runtime.sh` must sit in the **same folder as each script**. A script imports it with exactly `source "${SCRIPT_DIR}runtime.sh"` (LIB-005). Here it lives in `pg-replication/scripts/`. The two container-side scripts keep their own copies, which the standard still allows.
- The library also holds `require_integer` and `INTEGER_PATTERN`. The function `start_run_log` checks for `date` and `mktemp` itself.
- The plugin adopted plain names and added no version pinning, as decided.
- The function `require_commands` moved to after the argument loop for large scripts (REQ-004).
- In this repository, 16 host scripts were migrated and about 945 lines of function bodies were removed. All 22 files conform to version 6, and the 17-step round trip passes.
- Later, standard version 7 added `end_run_log`, `on_signal` and `trap_signals`. It also required `start_run_log "$@"` first in `main`. Every script was migrated to it on 2026-11-15, and the two container-side scripts now carry those functions too.
