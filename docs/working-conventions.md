# Working conventions

<!-- toc -->

- [Conventions](#conventions)
- [Script and library rules that bite](#script-and-library-rules-that-bite)

<!-- tocstop -->

This page is for anyone who changes or extends the project. It lists the rules that the checks enforce and the traps that catch new contributors.

## Conventions

- **Language.** Services are written in Python and run in containers. Use a current Python image, because the host has no database driver. Infrastructure scripts and experiments are Bash under the house Bash standard, which the `bashcheck` tool checks. Python follows the [Python standard](python-standard.md), with ruff, mypy in strict mode and pytest in a pinned container, and no waivers.
- **Regression net.** Run `bash pg-replication/scripts/run-all-checks.sh` after every script change. Set `BASHCHECK_WRAPPER` so that the lint runs, because it is reported as skipped without it. The option `--skip-roundtrip` leaves out the round trip. After you change a rebuild or restore script, also run `test-hard-kill.sh`.
- **Evidence rule.** Do not claim that something works until it has run. Report the real output. Every new experiment has a control, restores the starting state and gets a row in the [capability register](../pg-replication/capability-register.md).
- **Host.** The host is macOS with Homebrew Bash 5.x first in `PATH`. The scripts need Bash 5.0 or later. Run scripts as `bash script.sh`. Keep the project outside OneDrive. Database files live in named Docker volumes and never in bind mounts.
- **Credentials.** They are throwaway values, and the ports stay bound to `127.0.0.1`. Never commit `pg-replication/secrets/` or `.env`, which git ignores. The replication role name is itself a secret file called `pg-replication-user`, so never hard-code it. Avoid the words secret, password, token and credential in names (rule CFG-001). Use `*_file` and `*_path` instead.
- **Documents.** Keep the README, the capability catalogue, the register and the evidence log in step with every change. The register gets a row for each test. A gap leaves its open-gaps table only when its pass criterion is met. The evidence log gets a new dated section for each run.
- **English.** Use British English and short sentences. Begin every sentence with a capital letter and end it with a full stop. Expand each acronym on first use in a document. Do not use vague placeholders or open-ended lists. Name the items instead.

## Script and library rules that bite

- Only `lib/database.sh` runs `psql`. Most `docker` calls are in `lib/container.sh`. The libraries for a single job run `docker` themselves. They are `fence.sh`, `lease.sh`, `backup.sh` and `access.sh`. `check-hygiene.sh` enforces that no host script under `pg-replication/scripts/` runs `docker`, `psql` or `pgbench` directly.
- Import a library with `source "${SCRIPT_DIR}../lib/NAME.sh"` and a `# shellcheck source=` hint. Import `runtime.sh` first. List library dependencies in a `# Depends:` header. A library never reads `SCRIPT_NAME` or `RUN_LOG_DIR` inside a function.
- Register temporary files with `CLEANUP_PATHS+=(...)` in the main shell. Never register them inside `$(...)`, a pipeline or a subshell. After a script change, run it with `TEMP_DIR` set to an empty folder and confirm that the folder is empty afterwards. Repeat the check after `kill -TERM`.
- The Bash standard has limits that catch people. A function has at most 40 lines. A file has at most 400 lines. A line has at most 100 columns. A function has at most 4 parameters. Top-level constants may not use command substitution. A prefix assignment to a `readonly` variable fails, so use `env` in an array. `lint-scripts.sh` exempts only SC2154 for `runtime.sh` and SC2064 for `trap_signals`.
- **A standby never carries `synchronous_standby_names`.** The rejoin switches synchronous mode on again for the new writer when the wanted mode was synchronous.
- **Settings files are replaced and never appended.** This applies to `primary_conninfo` and `primary_slot_name`. Each node holds at most one `primary_conninfo` line.
- **A rebuild replaces a slot that no longer protects write-ahead log (WAL).** Such a slot has a `wal_status` that is not `reserved` or `extended`. Compose sets the WAL limits on the command line, so `ALTER SYSTEM` cannot change them in a test.
- **The rebuild-pending marker** is written before a data directory changes. It is removed once the node streams. If a node still has the marker, the node is cloned and never rewound. A success report must mean that the node is *streaming*, not only that it is in recovery.
- **Synchronous replication blocks writes if the standby is down.** That is intended. It is the cost of a recovery point objective of 0.
