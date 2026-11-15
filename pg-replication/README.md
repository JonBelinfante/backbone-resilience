# Phase 1: two Postgres nodes kept in sync by WAL streaming

`pg-primary` (localhost:5433) accepts writes. `pg-standby` (localhost:5434) is a hot standby: it clones the
primary on first start, then streams and replays the primary's write-ahead log (WAL). It serves read-only queries.

```
client -> pg-primary --WAL stream--> pg-standby (read-only)
          (slot standby1_slot keeps WAL until received)
```

## Requirements

- Docker with Compose.
- **Bash 5.0 or later** on the host. The scripts check this and exit with an error otherwise. macOS ships Bash 3.2
  in `/bin/bash`, so install a newer one with `brew install bash` and make sure it comes first on your `PATH`
  (`bash --version` should show 5.0+).
- Every script accepts `-h` / `--help` (usage, options, environment, exit codes), even when a tool it needs is missing: the tool check runs after the options are read.
- Check scripts against the Bash standard (version 7) with `bash scripts/lint-scripts.sh`. It needs `shellcheck`, and
  the bash-standard plugin. `BASHCHECK_WRAPPER` is required and must be the plugin's `bin` directory (it holds
  `check.py`, which verifies the checker's SHA-256 before running it). Set it once, for example in `~/.zshrc`:
  `export BASHCHECK_WRAPPER="$HOME/.claude/local-marketplaces/bashcheck/bash-standard/bin"`.

## Run

```bash
cd pg-replication
docker compose up -d
docker compose ps            # wait for both to be healthy
./scripts/verify-replication.sh          # write on primary, read on standby, confirm standby is read-only
```

The scripts can be started from any folder (`bash x.sh`, `./x.sh` or a full path); they find their siblings from their own path.

If the scripts are not executable: `chmod +x scripts/*.sh primary/*.sh standby/*.sh`.

## Things to try

| Experiment | Command | What to observe |
|---|---|---|
| Sync vs async | `./scripts/set-replication-mode.sh --mode sync` / `--mode async` / `--mode status` | `sync_state` becomes `sync`; RPO becomes 0 |
| Standby outage, async | `docker stop pg-standby`, write to primary | Writes keep working; the slot retains WAL |
| Standby outage, sync | `./scripts/set-replication-mode.sh --mode sync`, `docker stop pg-standby`, then insert on primary | The insert **hangs** until the standby returns. This is the availability cost of RPO 0 |
| Catch-up | `docker start pg-standby` | Standby resumes from its position in the WAL, then converges |
| Failover | `docker stop pg-primary`, then `./scripts/promote-standby-to-primary.sh` | Standby becomes writable; timeline increments |
| Full failover and fail-back | `./scripts/run-all-checks.sh` (or `./scripts/test-failover-roundtrip.sh` alone) | 17 steps: fail over, rejoin the old primary with `pg_rewind`, write while it is down, compare both databases; then the starting state is restored |

Connect directly: `psql -h localhost -p 5433 -U postgres appdb` (password `postgres`).
These are throwaway credentials for a local experiment only, so the ports are published on `127.0.0.1` only (see
`docker-compose.yml`): the databases are not reachable from other machines on your network. If you have no `psql`
on the host, use `docker exec -it pg-primary psql -U postgres appdb`. Keep the loopback binding; the well-known
superuser password would otherwise be open to the whole network.

## Scripts, libraries and the round-trip test

| Script | What it does |
|---|---|
| `bring-down-database.sh --database primary\|standby` | Stops that container cleanly and confirms it is down |
| `bring-up-database.sh --database primary\|standby` | Starts it, waits until healthy, and stops it again if two nodes would both be writable (split-brain guard) |
| `show-container-info.sh --database primary\|standby` / `--container NAME` | Command-line wrapper over `lib/container.sh`: prints the container name for a database, or `true`/`false` for whether a container is running (fails if it does not exist). Other scripts import the library instead of calling this |
| `run-database-sql.sh --container NAME [--bare] [--ask recovery]` | Command-line wrapper over `lib/database.sh`: runs the SQL on standard input with psql in that container (`--bare` for scriptable output), or `--ask recovery` prints `t` (standby) or `f` (accepts writes) |
| `../lib/container.sh`, `../lib/database.sh` (libraries) | **Every docker and database call, reusable from any script.** `container::` has `name_of`, `is_running`, `inspect`, `image`, `network`, `volume`, `setting`, `health`, `start`, `stop`, `wait_healthy`, `compose_up`, `logs`, `rewind` (pg_rewind in a throwaway container) and `mark_standby`. `database::` has `run`, `bare`, `in_recovery`, `is_ready` and `drop_all_sql`. Imported with `source "${SCRIPT_DIR}../lib/NAME.sh"` (plus a `# shellcheck source=` hint); they run in the caller's process, so there is no extra process or run log per call. They assume the importing script has `log` and `die` (from `runtime.sh`) |
| `../lib/story.sh` (a library, sourced not run) | The failover test's story-and-check layer as `story::` functions: `narrate` (ms timestamp, script name, message, also logged), `narrate_stream`, `narrate_query`, `run_logged`, `expect_equal`, and the helpers that combine a database or container call with narration: `run_statement`, `expect_query`, `expect_stopped`, `drop_all_tables`. Declares `# Depends: container database`, so a script importing it imports those two as well |
| `primary/init-replication.sh`, `standby/entrypoint.sh` | Run inside the Postgres image, not on the host, so they cannot import `runtime.sh`. Each carries its own copy of the standard's functions (the same text, copied from the standard's example). `init-replication.sh` runs once, on an empty data volume (the image's init step); `entrypoint.sh` runs every time the standby container starts |
| `runtime.sh` (a library, in this folder) | The Bash standard's own functions, copied unchanged from the standard's examples and checked word for word: `log`, `die`, `on_error`, `require_commands`, `require_integer`, `start_run_log`, `cleanup`, plus the run-log state. Every host script imports it with `source "${SCRIPT_DIR}runtime.sh"`, so none carries its own copy. Do not edit it; a change to the standard replaces it |
| `run-with-log-folder.sh [--merge] -- COMMAND ...` | Runs COMMAND with one shared run folder (`run-<time>.<random>.d` inside `RUN_LOG_DIR`), so every script it starts, however deeply, logs there instead of scattering files. Prints the folder; `--merge` also prints the merged timeline |
| `merge-run-logs.sh [--dir FOLDER]` | Read-only. Merges all run logs of one folder (default: the newest) into one timeline: `timestamp script LEVEL message`, sorted by timestamp |
| `promote-standby-to-primary.sh` | Makes `pg-standby` the writable node (refuses while `pg-primary` answers, unless `--force`) |
| `promote-primary-to-standby.sh` | Rebuilds the stopped old primary as a standby of the new writer: slot, checkpoint, `pg_rewind`, standby settings, start, wait until streaming |
| `test-failover-roundtrip.sh` | 17-step test that tells its story (every line has a UTC time and the script name, with each SQL statement, the data it returned and each script's output): drop tables, replicate a row, fail over, write on the promoted standby, rejoin the old primary, write while the replica is down, compare both databases |
| `restore-starting-state.sh` | Reads the current roles and returns to the starting state (`pg-primary` writes, `pg-standby` replicates): starts a stopped node, or fails back with `pg_rewind` after a failover. Run it after any experiment |
| `run-all-checks.sh [--skip-roundtrip]` | One line per check: `PASS lint`, `PASS roundtrip`. A failure also prints the last 15 lines of that check's output |
| `report-refactoring.sh [--mode MODE] [--show NAME]` | Read-only refactoring aid. Modes: `duplicates`, `usage` (reuse map), `size`, `all`, `brief` (one tagged line per finding), `baseline` (save `refactor-baseline.txt`), `changes` (diff against it). `--show NAME` prints every copy of a function and how they differ. Uses `report-refactoring.awk` |

Notes:

- The names `primary` and `standby` always mean the containers `pg-primary` and `pg-standby`, whatever role each
  has after a failover.
- The test tidies up after itself: whether it passes, fails or is interrupted, it then runs
  `restore-starting-state.sh` and drops its test table, so it can be run again straight away.
- If the stack cannot be restored, `docker compose down -v` **deletes both databases** and starts clean.
- Failing back under asynchronous replication can lose writes the new writer had not yet sent to the node being
  promoted.
- Set `RUN_LOG_DIR=logs` to keep the story as a run log, and `UP_PULL_POLICY=never` if Docker Hub is unreachable.
- Passwords are read from the writer container's environment, never stored in the scripts.

## Logs and audit trail

Every script run writes one run log, following the Bash standard. Each script appends timestamped
`INFO`, `WARN` and `ERROR` lines (when it started, each step, decisions, and how it ended) to its own file,
and a failure records the line, the function and the command that failed.

| File | Contents |
|---|---|
| `$RUN_LOG_DIR/<script>-<UTC time>.<random>.log` | One run of one script (the `.log` suffix is added after creation; see CR-8 in `docs/change-request-bash-standard.md`). `RUN_LOG_DIR` defaults to the temporary directory and the folder must exist. Set `RUN_LOG_DIR=logs` to keep run logs here (git-ignored) |
| `logs/container-<name>-<time>.log` | Container logs (Postgres server log plus init/entrypoint lines), saved by `./scripts/collect-logs.sh`. `LOG_DIR` sets the folder (default `logs`, created if missing) |

A script's own results still go to the terminal as before, but its output is no longer copied into the run log, and
there is no `runs.log` index or `TRACE=1` command trace. Use `bash -x scripts/<script>.sh` to trace a run.
One test run writes 16 run logs (it was 87 when the SQL and container helpers were scripts rather than libraries), so for a whole run use `RUN_LOG_DIR=logs bash scripts/run-with-log-folder.sh --merge -- bash scripts/test-failover-roundtrip.sh`. Run log lines carry UTC timestamps to the millisecond (`2026-11-14T08:14:36.385Z`), so the merged timeline orders events from different scripts correctly; lines in the very same millisecond keep each file's own order.
Run `./scripts/collect-logs.sh` **before** `docker compose down`, because removing containers deletes their logs.
Decisions (refusing or performing a promotion, changing sync mode) are logged as `DECISION:` / `CHANGE:` lines in the run log.
Logs live inside this OneDrive folder; they are small text files, but set `LOG_DIR=/some/other/path` to keep them out of sync.

## What is proven

See `capability-register.md`: each capability with its evidence, status (automated, manual, partial) and limits, plus
the gaps (observed RPO and RTO, fencing, crash failures, a true `pg_rewind` divergence, load, network faults).

## Design notes

- **Replication slot** (`standby1_slot`): guarantees the primary keeps the WAL the standby still needs, so a
  temporarily disconnected standby can always catch up. `max_slot_wal_keep_size=1GB` bounds the risk of a dead
  standby filling the primary's disk (a standby that falls further behind than that must be re-cloned).
- **`application_name=standby1`**: identifies the standby, and is the name that synchronous replication targets.
- **`wal_log_hints=on`** and matching WAL settings on the standby: let a promoted standby feed a rebuilt old
  primary, and allow `pg_rewind` (used by `promote-primary-to-standby.sh`).
- **Named Docker volumes**: database files live inside Docker, not in this folder, so OneDrive never syncs or
  locks live database files.
- **Reset everything**: `docker compose down -v` (deletes both databases).

## Known limits (deliberate, for later phases)

- Failover is manual. There is no failure detector, fencing token or client rerouting yet, so the
  "refuse to promote while the primary is up" check in `promote-standby-to-primary.sh` is a guard rail, not real split-brain protection.
- Rejoining the old primary as a standby is scripted (`promote-primary-to-standby.sh`, `restore-starting-state.sh`) but
  manual: nothing detects the failure or triggers it. The case where the old primary accepted writes the new one never
  received (a true divergence for `pg_rewind` to undo) is not exercised yet; the tests only see "no rewind required".
- Replication here copies state (WAL). The outbox, event stream and idempotent consumers come in later phases.
