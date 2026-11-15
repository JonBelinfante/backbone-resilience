# Change request: bash-standard

| | |
|---|---|
| **ID** | CR-____ (to be assigned) |
| **Title** | Shared runtime library, cross-library calls, and four smaller changes |
| **Raised** | 2026-11-14 |
| **Applies to** | bash-standard plugin 0.4.1, Bash standard version 5 (165 rules) |
| **Type** | Enhancement to the standard and its checker |
| **Status** | CR-1 to CR-7 implemented in plugin 0.5.0 (standard version 6); CR-8 implemented in plugin 0.7.0 (standard version 7); further observations in section 10 |
| **Result if accepted** | Standard version 6 |

## 1. Summary

Version 5 lets scripts share code through libraries (LIB-001), but the standard's own runtime blocks (`log`,
`die`, `on_error`, `require_commands`, `start_run_log`, `cleanup`) must still be copied, exactly, into every
script. Several rules also prevent libraries from being used fully. This request asks for seven changes, in three
priority bands:

| # | Change | Priority |
|---|---|---|
| CR-1 | One reserved runtime library for the standard's own functions | Must |
| CR-2 | Allow libraries to call functions from other libraries | Must |
| CR-3 | Let `--help` and usage errors work when the script's own tools are missing | Should |
| CR-4 | Support temporary directories in the clean-up pattern | Should |
| CR-5 | Narrow BAN-013 so it flags only a shell given a command string | Should |
| CR-6 | Add a library example to the reference examples | Could |
| CR-7 | Document three conventions that are currently found by trial and error | Could |

## 2. Background

- Every script carries the same six functions plus the `RUN_LOG` and `CLEANUP_PATHS` declarations: about 54 lines
  of function bodies, before comments, blank lines and the two traps. The skill text describes this as "still
  copied into each script for now".
- A change to the canonical text, such as a new timestamp format, means rewriting every script in a codebase.
- The copies count against the per-file limit (LAY-010) and bury the code a reviewer needs to read.
- Libraries exist but cannot hold these functions or depend on each other (details below).

## 3. Requested changes

### CR-1. One reserved runtime library (Must)

**Current.** CLI-009, OBS-001 to OBS-005, STX-004 and TIR-003 require the canonical text of the six functions in
each script. NAM-001 and STX-103 require library functions to be named `name::function`. STX-101 allows only
functions and `readonly` constants at a library's top level. CFG-002 puts environment imports in the script's
own environment block. A library therefore cannot supply `log` and the rest.

**Requested.**
1. A reserved library, `runtime.sh`, imported first (after the version guard and `shopt`). It defines `log`,
   `die`, `on_error`, `require_commands`, `start_run_log` and `cleanup` under their **plain names**, so calls such
   as `log INFO "..."` do not change.
2. `runtime.sh` is the only library allowed plain function names, and the only one allowed to declare the two
   state variables (`RUN_LOG` and `CLEANUP_PATHS`) and to import `RUN_LOG_DIR` from the environment.
3. A script no longer defines those functions or state. It keeps `SCRIPT_NAME`, `SCRIPT_DIR`, its own `usage`
   text, the two `trap` lines, `check_environment` and `main`, and adds one import line.
4. The checker verifies the canonical text **once**, in `runtime.sh`, against the reference. For each script it
   checks that the import is present and first, and that the traps and `main` use the right names.
5. Commands that run only inside `runtime.sh` (such as `date`, `mktemp`, `rm`) need not be listed in a script's
   `# Requires:`.
6. `runtime.sh` is part of the reference examples, so it is copied rather than written from memory.

**Rationale.** One definition instead of one per script; format changes become one edit; smaller scripts; more
room under LAY-010.

**Acceptance.** A script that imports `runtime.sh` and contains none of the six functions passes the checker. A
script missing the import, or importing it after other code, fails with a clear finding. `runtime.sh` with altered
canonical text fails.

### CR-2. Libraries may call other libraries' functions (Must)

**Current.** REQ-002 treats a call to another library's `stem::function`, made from inside a library, as an
external command. REQ-001 allows only plain command names in `# Requires:`, so the call cannot be listed. LIB-001
makes imports a property of the script, so a library has no way to declare a dependency.

**Requested.** Inside a library, a call to `stem::function` of another library is not an external command and
needs no `# Requires:` entry, on the same footing as the existing exemption for scripts. The importing script is
responsible for importing both. Optionally, a header line (for example `# Depends:` listing library stems) lets a
reader see the dependency; the checker may check the stems are well-formed but cannot verify them (F9).

**Rationale.** Without it, helper code that combines two libraries must live in each script, and the libraries
cannot be layered.

**Acceptance.** A library that calls `other::function` passes REQ-001 to REQ-003 with no `# Requires:` entry for it.

### CR-3. `--help` and usage errors without the script's tools (Should)

**Current.** The template calls `require_commands` before reading options (OBS-001 places `start_run_log`
straight after it), so `--help` exits with "missing required command" on a machine that lacks one of the script's
tools. CFG-007 already moves the environment check **after** the argument loop for exactly this reason.

**Requested.** Do the same for the script's own tools: `require_commands` runs after the argument loop (or
after `-h`/`--help` is handled). The tools the run log itself needs (`date`, `mktemp`) stay first, so a log is
still produced for `--help` and usage errors as OBS-001 requires. Adjust OBS-001 and the template order.

**Rationale.** A help screen is most needed on a machine where something is missing.

**Acceptance.** `script --help` exits 0 and prints usage when the script's own tools are absent.

### CR-4. Temporary directories in the clean-up pattern (Should)

**Current.** ERR-004 requires each `mktemp` result to be added to `CLEANUP_PATHS` on the next statement, and the
canonical `cleanup` removes with `rm -f --`, which cannot remove a directory. A script that needs a temporary
directory cannot follow the rule; the only workaround is a placeholder file.

**Requested.** Define a pattern for directories: for example `mktemp -d` results go into a second list removed
with `rm -rf --`, or `cleanup` handles both kinds. Update SEC-001 and ERR-004 accordingly. If directories are
meant to be kept after the run, state how that is expressed.

**Rationale.** Removes a rule that cannot be satisfied for a common need.

**Acceptance.** A script that creates a directory with `mktemp -d`, registers it, and has it removed on exit
passes the checker.

### CR-5. BAN-013 false positive (Should)

**Current.** BAN-013 reports "a shell is run with a command string" for `bash path/to/script.sh ... -c "..."`,
where `-c` belongs to the called script, not to `bash`.

**Requested.** Flag `-c` only when it is an option of the shell itself, that is, before the first non-option
argument (the script path).

**Rationale.** The current rule forces a script to change its own interface to avoid a pattern that is safe.

**Acceptance.** `bash ./tool.sh --flag -c "text"` passes; `bash -c "$cmd"` and `sh -c "$cmd"` still fail.

### CR-6. A library in the reference examples (Could)

**Current.** The skill says to copy the closest reference example, but `references/examples/` contains no library
and no script that imports one.

**Requested.** Add a small library and a script that imports it. Show the library header (`script-kind: library`,
no shebang, `# Requires:`), the `name::function` naming, the import line, and the `# shellcheck source=` hint (see
CR-7).

**Acceptance.** The examples pass the checker and cover each library rule (HDR-001, HDR-002, STX-101 to STX-103,
LIB-001, LIB-002).

### CR-7. Document three conventions (Could)

1. **`# shellcheck source=` hint.** ShellCheck cannot follow `source "${SCRIPT_DIR}…"`. A directive above the
   import (with `source-path=SCRIPTDIR` in the repository's ShellCheck configuration) makes it work from any
   working directory. Recommend it in the skill and reference.
2. **`SCRIPT_DIR` has one form.** State that the mandated form is the only accepted one and why: command
   substitution is not allowed in top-level constants, so `dirname` and `cd … && pwd` are rejected.
3. **Libraries depend on the importing script.** State what a library may assume (for example `log` and `die`
   exist) and that the checker cannot verify it.

## 4. Decisions already taken

- Plain function names for the runtime library (rather than `runtime::log`).
- No library version pinning from scripts for now. To be revisited if the library changes independently of the
  scripts that import it.

## 5. Impact and migration

- Standard version becomes 6. The skill text, reference examples, rule explanations and checker change.
- Existing scripts need one mechanical edit: delete the six functions and state declarations, add the import,
  prune `# Requires:`. It can be scripted and applied in a single pass.
- With CR-1 accepted, the per-script template shrinks by roughly 70 lines, which also eases the file-length limit.

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| A script is no longer self-contained: it fails if the library is missing | Tested: the script stops at the import line with status 1 and Bash's own message. Document the bootstrap order |
| The checker cannot follow imports (F9), so it cannot see that a script gets a correct `log` | Check `runtime.sh` against the reference, and check the import in each script |
| A changed library goes unnoticed by scripts | Accepted for now (no pinning); revisit if drift appears |
| Shared mutable state (`RUN_LOG`, `CLEANUP_PATHS`) | Unchanged in behaviour: they are already shell globals. Only the declaring file changes |

## 7. Alternatives considered

| Alternative | Why not |
|---|---|
| Namespaced runtime functions (`runtime::log`) | Every call changes, and libraries calling them hit REQ-002 |
| A generator that stamps the blocks into new scripts | Removes typing errors but not the duplication; a change to the canonical text still rewrites every script |
| Leave as is | Keeps self-contained scripts at the cost of duplication and per-file limit pressure |

## 8. Out of scope

Changes to rules unrelated to the above, and any change to the Bash version baseline.

## 9. Evidence

A prototype ran the six functions from a shared library with a script that imported it, and compared behaviour
with the per-script copies for: a normal run, `die`, `die` inside a command substitution, a failing command inside
a function, and a missing library. Exit status, standard-error output, run-log content and clean-up were
identical in each case, except that a missing library stops at the import line with Bash's own message.

## 10. Outcome and follow-up observations (2026-11-15)

Result of this request in plugin 0.5.0:

| # | Result |
|---|---|
| CR-1 | **Implemented**, with a difference: `runtime.sh` must sit in the same folder as the script that imports it (LIB-005) and is checked word for word (LIB-004). It also holds `require_integer` |
| CR-2 | **Implemented** as a `# Depends:` header line (LIB-003) |
| CR-3 | **Implemented** (REQ-004), for large scripts |
| CR-4 | **Implemented**: `mktemp -d` is allowed and `cleanup` removes with `rm -rf` |
| CR-5 | **Implemented**: BAN-013 reports `-c` only when it is the shell's own option |
| CR-6 | **Partly**: `runtime.sh` is in the examples; there is still no small non-runtime library with an importing script |
| CR-7 | **Implemented** in the skill text |

Observations from applying the change to a real codebase, as candidates for a follow-up request:

1. **CFG-005 does not exempt names the runtime library provides.** A script that imports `runtime.sh` cannot read
   `RUN_LOG_DIR` inside a function (flagged as an environment read), although `RUN_LOG_DIR` is the runtime's own
   documented setting. Scripts that need the log folder for another purpose had to import a second variable whose
   default is `${RUN_LOG_DIR}`. Suggested: treat the names the runtime library declares (`RUN_LOG_DIR`, `RUN_LOG`,
   `INTEGER_PATTERN`) as set at the top level of any script that imports it.
2. **A library reading `SCRIPT_NAME` is flagged by CFG-005**, although the skill says a library may assume
   `SCRIPT_NAME` exists. Suggested: exempt `SCRIPT_NAME`, `log` and `die` in libraries, or change the text.
3. **ShellCheck warns SC2154 on `runtime.sh`** (it reads `SCRIPT_NAME`, which the importing script sets). The file cannot
   be edited, so a project must disable that one code for that file in its own tooling. Suggested: add a
   `# shellcheck disable=SC2154` line to the standard's `runtime.sh`, or document the exception.
4. **A medium script that falls into the large tier after a small edit** starts failing REQ-004 and OBS-006 at once.
   Suggested: report the tier in the checker's output, so the cause is clear.

### CR-8. Run log files end in `.log` (Should; raised 2026-11-15; implemented in standard version 7)

**Outcome (2026-11-15).** Implemented by approach 1: the file is created with the existing template, renamed to end in `.log`, and the new path is the one registered for clean-up. The reference names it `<script>-<time>-<process id>.XXXXXX`, then renames it.

**Current.** `start_run_log` in the runtime library creates the run log with
`mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-${stamp}.XXXXXX"`, so a file is named like `name.sh-20261113T094018Z.oEkFeV`:
it ends in random characters and has no extension. SEC-001 requires the `mktemp` template to end in `XXXXXX`, and
LIB-004 requires the library text to match the standard word for word, so a project cannot add a suffix itself. The
small-script form (TIR-003) already uses a `.log` name, so the two forms are inconsistent.

**Requested.** Run log file names end in `.log`, for example `<script>-<UTC time>.<random>.log`.

Possible ways, in order of preference:
1. Create the file with the existing template, then rename it by appending `.log`, point `RUN_LOG` at the new
   path, and register the new path (not the old one) in `CLEANUP_PATHS`. Portable, because it does not rely on a
   suffix after the `X` characters.
2. Allow a suffix after the `X` characters. Not portable: BSD `mktemp` (macOS) requires the template to end in the
   `X` characters, while GNU `mktemp` accepts a suffix only with `--suffix`.
3. Build a unique name without `mktemp`. Rejected: SEC-001 forbids names built from `$$`, `$RANDOM` or `date`.

**Rules affected.** OBS-001 (run-log naming), SEC-001 and ERR-004 (the `mktemp` pattern and registration), LIB-004
(canonical text of the runtime library), TIR-003 (keep the small form consistent).

**Rationale.** Editors, viewers and log tools recognise `.log`; a pattern such as `*.log` then matches every run log
for listing, ignoring (version control, rotation) and archiving; it is consistent with the small form and with
conventional log naming.

**Acceptance.** After a run, `RUN_LOG_DIR` contains `<script>-<time>.<random>.log` for each run, on Linux, macOS and
Git Bash; `*.log` matches all run logs; clean-up and the final "finished with status" line are unaffected; the
checker accepts the new canonical text and rejects the old one.

**Compatibility.** Tools that derive the script name from the file name by stripping from the timestamp onward are
unaffected. Tools that match the whole name or the end of it need a one-line update. Part of the next standard
version.
