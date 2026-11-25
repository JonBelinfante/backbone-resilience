# Change request: bash-standard

| | |
|---|---|
| **ID** | CR-____, not yet assigned. |
| **Title** | A shared runtime library, calls between libraries, and four smaller changes. |
| **Raised** | 2026-11-14. |
| **Applies to** | The bash-standard plugin 0.4.1 and Bash standard version 5, which has 165 rules. |
| **Type** | An enhancement to the standard and its checker. |
| **Status** | CR-1 to CR-7 are implemented in plugin 0.5.0, which is standard version 6. CR-8 is implemented in plugin 0.7.0, which is standard version 7. Section 10 lists further observations. |
| **Result if accepted** | Standard version 6. |

The identifiers CR-1 to CR-8 name the changes in this request. The other identifiers, such as LIB-004 or OBS-001, name rules of the standard.

## 1. Summary

Version 5 lets scripts share code through libraries (LIB-001). However, the standard's own runtime blocks must still be copied, exactly, into every script. The blocks are `log`, `die`, `on_error`, `require_commands`, `start_run_log` and `cleanup`. Several rules also stop libraries from being used fully. This request asks for seven changes in three priority bands.

| # | Change | Priority |
|---|---|---|
| CR-1 | One reserved runtime library for the standard's own functions. | Must. |
| CR-2 | Allow libraries to call functions from other libraries. | Must. |
| CR-3 | Let `--help` and usage errors work when the script's own tools are missing. | Should. |
| CR-4 | Support temporary directories in the clean-up pattern. | Should. |
| CR-5 | Narrow BAN-013 so that it flags only a shell that is given a command string. | Should. |
| CR-6 | Add a library example to the reference examples. | Could. |
| CR-7 | Document three conventions that are currently found by trial and error. | Could. |

## 2. Background

- Every script carries the same six functions, plus the `RUN_LOG` and `CLEANUP_PATHS` declarations. That is about 54 lines of function bodies, before comments, blank lines and the two traps. The skill text describes this as "still copied into each script for now".
- A change to the canonical text, such as a new timestamp format, means rewriting every script in a codebase.
- The copies count against the per-file limit (LAY-010), and they bury the code that a reviewer needs to read.
- Libraries exist, but they cannot hold these functions and they cannot depend on each other. The details follow.

## 3. Requested changes

### CR-1. One reserved runtime library (Must)

**Current.** CLI-009, OBS-001 to OBS-005, STX-004 and TIR-003 require the canonical text of the six functions in each script. NAM-001 and STX-103 require library functions to be named `name::function`. STX-101 allows only functions and `readonly` constants at a library's top level. CFG-002 puts environment imports in the script's own environment block. A library therefore cannot supply `log` and the other functions.

**Requested.**

1. A reserved library, `runtime.sh`, is imported first, after the version guard and `shopt`. It defines `log`, `die`, `on_error`, `require_commands`, `start_run_log` and `cleanup` under their **plain names**. Calls such as `log INFO "..."` then do not change.
2. The library `runtime.sh` is the only library that may use plain function names. It is also the only library that may declare the two state variables, `RUN_LOG` and `CLEANUP_PATHS`, and import `RUN_LOG_DIR` from the environment.
3. A script no longer defines those functions or that state. It keeps `SCRIPT_NAME`, `SCRIPT_DIR`, its own `usage` text, the two `trap` lines, `check_environment` and `main`. It adds one import line.
4. The checker verifies the canonical text **once**, in `runtime.sh`, against the reference. For each script it checks that the import is present and first, and that the traps and `main` use the right names.
5. Commands that run only inside `runtime.sh`, such as `date`, `mktemp` and `rm`, need not be listed in a script's `# Requires:`.
6. The file `runtime.sh` is part of the reference examples, so a project copies it and does not write it from memory.

**Rationale.** There is one definition instead of one for each script. A format change becomes one edit. Scripts are smaller, and there is more room under LAY-010.

**Acceptance.** A script that imports `runtime.sh` and contains none of the six functions passes the checker. A script that lacks the import, or imports it after other code, fails with a clear finding. A `runtime.sh` with altered canonical text fails.

### CR-2. Libraries may call other libraries' functions (Must)

**Current.** REQ-002 treats a call to another library's `stem::function`, made from inside a library, as an external command. REQ-001 allows only plain command names in `# Requires:`, so the call cannot be listed. LIB-001 makes imports a property of the script, so a library has no way to declare a dependency.

**Requested.** Inside a library, a call to the `stem::function` of another library is not an external command. It needs no `# Requires:` entry, on the same footing as the existing exemption for scripts. The importing script is responsible for importing both libraries. A header line, for example `# Depends:` followed by library stems, can optionally show the dependency to a reader. The checker may check that the stems are well formed, but it cannot verify them (F9).

**Rationale.** Without this change, helper code that combines two libraries must live in each script, and the libraries cannot be layered.

**Acceptance.** A library that calls `other::function` passes REQ-001 to REQ-003 with no `# Requires:` entry for the call.

### CR-3. `--help` and usage errors without the script's tools (Should)

**Current.** The template calls `require_commands` before it reads options, because OBS-001 places `start_run_log` straight after it. As a result, `--help` exits with "missing required command" on a machine that lacks one of the script's tools. CFG-007 already moves the environment check **after** the argument loop for this reason.

**Requested.** Treat the script's own tools in the same way. Run `require_commands` after the argument loop, or after `-h` and `--help` are handled. The tools that the run log itself needs, `date` and `mktemp`, stay first, so a log is still produced for `--help` and for usage errors, as OBS-001 requires. Adjust OBS-001 and the template order.

**Rationale.** A help screen is most needed on a machine where something is missing.

**Acceptance.** The command `script --help` exits 0 and prints the usage when the script's own tools are absent.

### CR-4. Temporary directories in the clean-up pattern (Should)

**Current.** ERR-004 requires each `mktemp` result to be added to `CLEANUP_PATHS` on the next statement. The canonical `cleanup` removes with `rm -f --`, which cannot remove a directory. A script that needs a temporary directory cannot follow the rule. The only workaround is a placeholder file.

**Requested.** Define a pattern for directories. For example, the results of `mktemp -d` could go into a second list that is removed with `rm -rf --`. Alternatively, `cleanup` could handle both kinds. Update SEC-001 and ERR-004 to match. If a directory is meant to be kept after the run, state how that is expressed.

**Rationale.** The change removes a rule that cannot be satisfied for a common need.

**Acceptance.** A script that creates a directory with `mktemp -d`, registers it, and has it removed on exit passes the checker.

### CR-5. BAN-013 false positive (Should)

**Current.** BAN-013 reports "a shell is run with a command string" for `bash path/to/script.sh ... -c "..."`. In that command, `-c` belongs to the called script and not to `bash`.

**Requested.** Flag `-c` only when it is an option of the shell itself. That means it comes before the first non-option argument, which is the script path.

**Rationale.** The current rule forces a script to change its own interface to avoid a pattern that is safe.

**Acceptance.** The command `bash ./tool.sh --flag -c "text"` passes. The commands `bash -c "$cmd"` and `sh -c "$cmd"` still fail.

### CR-6. A library in the reference examples (Could)

**Current.** The skill says to copy the closest reference example. However, `references/examples/` contains no library and no script that imports one.

**Requested.** Add a small library and a script that imports it. Show the library header, which has `script-kind: library`, no shebang and a `# Requires:` line. Show the `name::function` naming, the import line, and the `# shellcheck source=` hint described in CR-7.

**Acceptance.** The examples pass the checker and cover each library rule. The rules are HDR-001, HDR-002, STX-101 to STX-103, LIB-001 and LIB-002.

### CR-7. Document three conventions (Could)

1. **The `# shellcheck source=` hint.** ShellCheck cannot follow `source "${SCRIPT_DIR}…"`. A directive above the import makes it work from any working directory. The repository's ShellCheck configuration also needs `source-path=SCRIPTDIR`. Recommend the hint in the skill and the reference.
2. **`SCRIPT_DIR` has one form.** State that the mandated form is the only accepted one, and say why. Command substitution is not allowed in top-level constants, so `dirname` and `cd … && pwd` are rejected.
3. **Libraries depend on the importing script.** State what a library may assume. For example, `log` and `die` exist. State also that the checker cannot verify the assumption.

## 4. Decisions already taken

- The runtime library uses plain function names, and not `runtime::log`.
- Scripts do not pin a library version for now. Revisit this if the library changes independently of the scripts that import it.

## 5. Impact and migration

- The standard version becomes 6. The skill text, the reference examples, the rule explanations and the checker change.
- Existing scripts need one mechanical edit. Delete the six functions and the state declarations, add the import, and prune `# Requires:`. A script can apply the edit in a single pass.
- With CR-1 accepted, the per-script template shrinks by roughly 70 lines. That also eases the file-length limit.

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| A script is no longer self-contained, and it fails if the library is missing. | The risk was tested. The script stops at the import line with status 1 and Bash's own message. Document the bootstrap order. |
| The checker cannot follow imports (F9), so it cannot see that a script gets a correct `log`. | Check `runtime.sh` against the reference, and check the import in each script. |
| A changed library goes unnoticed by the scripts. | This is accepted for now, because there is no pinning. Revisit it if drift appears. |
| Shared mutable state in `RUN_LOG` and `CLEANUP_PATHS`. | Behaviour does not change, because they are already shell globals. Only the declaring file changes. |

## 7. Alternatives considered

| Alternative | Why not |
|---|---|
| Namespaced runtime functions, such as `runtime::log`. | Every call changes, and libraries that call them meet REQ-002. |
| A generator that stamps the blocks into new scripts. | It removes typing errors but not the duplication. A change to the canonical text still rewrites every script. |
| Leave things as they are. | Scripts stay self-contained, at the cost of duplication and pressure on the per-file limit. |

## 8. Out of scope

This request does not cover rules that are unrelated to the changes above. It does not cover any change to the Bash version baseline.

## 9. Evidence

A prototype ran the six functions from a shared library with a script that imported it. It compared behaviour with the per-script copies in five cases. The cases were a normal run, `die`, `die` inside a command substitution, a failing command inside a function, and a missing library. The exit status, the standard-error output, the run-log content and the clean-up were identical in each case. The one difference was that a missing library stops at the import line with Bash's own message.

## 10. Outcome and follow-up observations (2026-11-15)

This table shows the result of the request in plugin 0.5.0.

| # | Result |
|---|---|
| CR-1 | **Implemented**, with one difference. The file `runtime.sh` must sit in the same folder as the script that imports it (LIB-005), and the checker compares it word for word (LIB-004). The library also holds `require_integer`. |
| CR-2 | **Implemented** as a `# Depends:` header line (LIB-003). |
| CR-3 | **Implemented** for large scripts (REQ-004). |
| CR-4 | **Implemented.** The checker allows `mktemp -d`, and `cleanup` removes with `rm -rf`. |
| CR-5 | **Implemented.** BAN-013 reports `-c` only when it is the shell's own option. |
| CR-6 | **Partly implemented.** The file `runtime.sh` is in the examples. There is still no small non-runtime library with an importing script. |
| CR-7 | **Implemented** in the skill text. |

Applying the change to a real codebase produced four observations. They are candidates for a follow-up request.

1. **CFG-005 does not exempt names that the runtime library provides.** A script that imports `runtime.sh` cannot read `RUN_LOG_DIR` inside a function, because the checker flags an environment read. Yet `RUN_LOG_DIR` is the runtime's own documented setting. Scripts that need the log folder for another purpose had to import a second variable, with the default `${RUN_LOG_DIR}`. The suggested fix is to treat the names that the runtime library declares as set at the top level of any script that imports it. Those names are `RUN_LOG_DIR`, `RUN_LOG` and `INTEGER_PATTERN`.
2. **CFG-005 flags a library that reads `SCRIPT_NAME`**, although the skill says that a library may assume `SCRIPT_NAME` exists. The suggested fix is to exempt `SCRIPT_NAME`, `log` and `die` in libraries, or to change the text.
3. **ShellCheck warns with SC2154 on `runtime.sh`.** The file reads `SCRIPT_NAME`, which the importing script sets. A project cannot edit the file, so it must disable that one code for that file in its own tooling. The suggested fix is to add a `# shellcheck disable=SC2154` line to the standard's `runtime.sh`, or to document the exception.
4. **A medium script can fall into the large tier after a small edit.** It then starts failing REQ-004 and OBS-006 at once. The suggested fix is to report the tier in the checker's output, so that the cause is clear.

### CR-8. Run log files end in `.log` (Should; raised 2026-11-15; implemented in standard version 7)

**Outcome (2026-11-15).** The standard implemented the first approach. The file is created with the existing template and then renamed to end in `.log`. The new path is the one registered for clean-up. The reference names the file `<script>-<time>-<process id>.XXXXXX` and then renames it.

**Current.** The function `start_run_log` in the runtime library creates the run log with `mktemp "${RUN_LOG_DIR}/${SCRIPT_NAME}-${stamp}.XXXXXX"`. A file is therefore named like `name.sh-20261113T094018Z.oEkFeV`. It ends in random characters and has no extension. SEC-001 requires the `mktemp` template to end in `XXXXXX`. LIB-004 requires the library text to match the standard word for word. A project cannot add a suffix itself. The small-script form (TIR-003) already uses a `.log` name, so the two forms are inconsistent.

**Requested.** Run log file names end in `.log`. An example is `<script>-<UTC time>.<random>.log`. The time in the name uses Coordinated Universal Time (UTC).

There are three possible ways, in order of preference.

1. Create the file with the existing template and rename it by appending `.log`. Point `RUN_LOG` at the new path, and register the new path, not the old one, in `CLEANUP_PATHS`. This is portable, because it does not rely on a suffix after the `X` characters.
2. Allow a suffix after the `X` characters. This is not portable. The Berkeley Software Distribution (BSD) `mktemp` on macOS requires the template to end in the `X` characters. The `mktemp` of GNU's Not Unix (GNU) accepts a suffix only with `--suffix`.
3. Build a unique name without `mktemp`. This is rejected, because SEC-001 forbids names that are built from `$$`, `$RANDOM` or `date`.

**Rules affected.** The change affects OBS-001, which names the run log. It affects SEC-001 and ERR-004, which cover the `mktemp` pattern and its registration. It affects LIB-004, the canonical text of the runtime library. It also affects TIR-003, so that the small form stays consistent.

**Rationale.** Editors, viewers and log tools recognise `.log`. A pattern such as `*.log` then matches every run log, for listing, ignoring in version control, rotation and archiving. The name is consistent with the small form and with conventional log naming.

**Acceptance.** After a run, `RUN_LOG_DIR` contains `<script>-<time>.<random>.log` for each run, on Linux, macOS and Git Bash. The pattern `*.log` matches all run logs. The clean-up and the final "finished with status" line are unaffected. The checker accepts the new canonical text and rejects the old one.

**Compatibility.** Tools that derive the script name from the file name are unaffected if they strip from the timestamp onward. Tools that match the whole name, or the end of it, need a one-line update. The change is part of the next standard version.
