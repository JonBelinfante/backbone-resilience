# Phases 1 and 2: two Postgres nodes, WAL streaming, and failover safety

New here? Start with the [repository README](../README.md) and the [capability catalogue](../docs/capability-catalogue.md); this file is the working reference for the scripts.

## Where this sits in the roadmap

| Phase | Scope | State |
|---|---|---|
| 1 | The Postgres pair: replication (sync/async), manual failover and fail-back, RPO/RTO, crash and network faults, secret rotation | Complete |
| 2 | Failover safety (detector, epoch, actor, leases and guards) and the application layer (GAP-12: outbox, idempotent consumers, checker) | Failover safety built, proven and documented as patterns; remainder GAP-03, GAP-07, GAP-11; application layer not started |
| 3 | Service layer: load generator, reconnecting clients (GAP-10), RTO under load (GAP-15), rotation for application clients (SEC-06) | Not started |
| 4 to 6 | Hot-hot with partitioned ownership; multi-writer for commutative entries; chaos catalogue with SLI/error-budget reporting | Not started |

This folder holds the Phase 1 foundation and the Phase 2 failover work. What is proven and what is not is in
[capability-register.md](capability-register.md).

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
| `../lib/access.sh`, `../lib/fault.sh`, `../lib/toxic.sh` (libraries) | Controlled faults and access: `access::` sets passwords and probes logins; `fault::` crashes, freezes, isolates a node, delays apply and generates WAL; `toxic::` adds network delay, silence or a cut link through Toxiproxy |
| `../lib/mode.sh` (library) | `mode::record` and `mode::wanted`: remember the replication mode that was asked for, so a rejoin can switch sync on again |
| `../lib/epoch.sh`, `../lib/lease.sh`, `../lib/controller.sh`, `../lib/actor.sh` (libraries) | The failover control plane: `epoch::` the failover number that only goes up; `lease::` the writer's lease and its guard; `controller::` runs the detect-only controller in a container; `actor::` runs controller and actor for a test and times the client's view |
| `../lib/measure.sh`, `../lib/judge.sh`, `../lib/pytools.sh` (libraries) | `measure::` statistics for trial results; `judge::` PASS/FAIL against targets; `pytools::` the pinned Python checkers |
| `../services/failover_controller`, `../services/fence_guard` (Python, run in containers) | The detect-only failover controller (also renews the lease) and the guard that stops a writer whose lease has expired; each has its own tests, run by `check-python.sh` |
| `../lib/story.sh` (a library, sourced not run) | The failover test's story-and-check layer as `story::` functions: `narrate` (ms timestamp, script name, message, also logged), `narrate_stream`, `narrate_query`, `run_logged`, `expect_equal`, and the helpers that combine a database or container call with narration: `run_statement`, `expect_query`, `expect_stopped`, `drop_all_tables`. Declares `# Depends: container database`, so a script importing it imports those two as well |
| `primary/init-replication.sh`, `standby/entrypoint.sh` | Run inside the Postgres image, not on the host, so they cannot import `runtime.sh`. Each carries its own copy of the standard's functions (the same text, copied from the standard's example). `init-replication.sh` runs once, on an empty data volume (the image's init step); `entrypoint.sh` runs every time the standby container starts |
| `runtime.sh` (a library, in this folder) | The Bash standard's own functions, copied unchanged from the standard's examples and checked word for word: `log`, `die`, `on_error`, `require_commands`, `require_integer`, `start_run_log`, `cleanup`, plus the run-log state. Every host script imports it with `source "${SCRIPT_DIR}runtime.sh"`, so none carries its own copy. Do not edit it; a change to the standard replaces it |
| `run-with-log-folder.sh [--merge] -- COMMAND ...` | Runs COMMAND with one shared run folder (`run-<time>.<random>.d` inside `RUN_LOG_DIR`), so every script it starts, however deeply, logs there instead of scattering files. Prints the folder; `--merge` also prints the merged timeline |
| `merge-run-logs.sh [--dir FOLDER]` | Read-only. Merges all run logs of one folder (default: the newest) into one timeline: `timestamp script LEVEL message`, sorted by timestamp |
| `promote-standby-to-primary.sh` | Makes `pg-standby` the writable node (refuses while `pg-primary` answers, unless `--force`) |
| `promote-primary-to-standby.sh` | Rebuilds the stopped old primary as a standby of the new writer: slot, checkpoint, `pg_rewind`, standby settings, start, wait until streaming |
| `test-failover-roundtrip.sh` | 17-step test that tells its story (every line has a UTC time and the script name, with each SQL statement, the data it returned and each script's output): drop tables, replicate a row, fail over, write on the promoted standby, rejoin the old primary, write while the replica is down, compare both databases |
| `restore-starting-state.sh` | Reads the current roles and returns to the starting state (`pg-primary` writes, `pg-standby` replicates): starts a stopped node, or fails back with `pg_rewind` after a failover. Run it after any experiment. It ends only when the primary reports the standby as streaming, and rebuilds a standby that cannot be trusted (`pg_basebackup`) |
| `test-hard-kill.sh [--target roundtrip\|restore\|rotate] [--delays LIST]` | Kills a script and its docker commands with SIGKILL at each delay, then requires `restore-starting-state.sh` to recover the stack (primary writes, standby streaming). Changes the databases: throwaway stack only |
| `test-divergence-rewind.sh` | 10-step test of a true divergence: the standby stops following, the primary acknowledges 3 writes it never receives, the standby is promoted (forced), then `pg_rewind` rebuilds the old primary. Requires a real rewind, the 3 writes gone and identical rows on both nodes. Changes the databases: throwaway stack only |
| `test-replica-lag.sh` | 8-step test: the standby applies changes 6 s late; two debits decided on the replica both pass and overdraw the account (negative control), decided on the writer the second is declined; the guard `database::read_for_decision` refuses a replica; a replica read after `database::wait_for_replay` is fresh. Changes the databases: throwaway stack only |
| `test-slot-limit.sh` | 7-step test of the WAL limit for a dead standby: stops the standby and writes WAL until its slot is invalidated (about 1 GB, about 1.5 minutes), requires the primary to keep accepting writes with a bounded WAL directory, the standby to fail to stream, and `restore-starting-state.sh` to re-clone it and replace the slot. Needs 6 GB free. Changes the databases: throwaway stack only |
| `rotate-secret.sh [--secret replication\|superuser] [--keep-old]` | Rotates a database password with no failed write: the replication secret by overlap (a second role, the name alternates between replicator_a and replicator_b and is kept in `secrets/pg-replication-user.txt`), the superuser secret in place. Rolls back before the secret files change; run it again after any interruption and it converges. See [docs/secrets-rotation.md](docs/secrets-rotation.md) |
| `test-rotation.sh` (`ROTATION_MODE=sync` for synchronous replication) | 7-step test: three rotations (replication, superuser, replication) under a write probe; requires 0 failed writes, the standby streaming as the role in the secret file, one replication role left, and a standby rebuilt from an empty volume joining with the new secrets. Changes the databases and the secret files: throwaway stack only |
| `test-maintenance-lock.sh` | 5-step test of the maintenance lock: two rotations together (second refused), a rotation during a rebuild (refused; the rebuild completes), a stale lock taken over, a reused process id not honoured. Rotates the secret and crashes the writer: throwaway stack only |
| `test-load.sh` | 6-step test of 16 concurrent clients (`pgbench`) inserting payments with idempotency keys from a million values: no failed transaction, duplicates rejected, money conserved exactly, standby identical in async and sync (throughput reported for both), and a writer killed mid-run recovers whole. `LOAD_CLIENTS`, `LOAD_SECONDS`, `LOAD_KEYS` resize it. Throwaway stack only |
| `test-network-faults.sh` | 7-step test of the replication link through Toxiproxy (about 5 minutes): async delay (commits unaffected, standby stale by the delay), sync delay (a commit costs a round trip), a link cut for 5 s (commits resume within one retry interval), a silent link (noticed after the sender timeout, 60 s by default), and RPO under delay then a writer crash. Changes the databases and replication settings and restores them: throwaway stack only |
| `test-fencing.sh` | 6-step test of start-time fencing: after a failover a plain `docker start` of the old primary must come up read-only and refuse a write; a control with the fence lifted shows the write accepted. Crashes the writer: throwaway stack only |
| `test-detector.sh` | 7-step test of the detect-only failover controller (`services/failover_controller`): healthy, a short freeze (no fail-over), a hung writer and a crash (fail-over, timed), a controller cut off from a live writer (hold), and the idle-writer trap (a false fail-over with a short witness window). Pauses and crashes the writer: throwaway stack only |
| `test-auto-failover.sh` | 3-step test of automatic failover: the detect-only controller plus `act-on-failover.sh` (raise the epoch, kill the old writer, promote). A short freeze does nothing; a crash and a hung writer each end with a client write succeeding on the new writer, timed. Crashes and freezes the writer: throwaway stack only |
| `act-on-failover.sh` | waits for the controller's `fail-over` decision (`--controller NAME`, `EPOCH_FILE`), then raises the epoch, kills the old writer and promotes the standby; a re-run is safe |
| `test-actor-kill.sh` | 3-step test: SIGKILL the actor after the epoch, kill and promote steps (a test hook), check the half-done state, re-run it and require one epoch and a writable standby each time. Freezes the writer: throwaway stack only |
| `test-two-actors.sh` | 2-step test: two actors started at once against a frozen writer; with the lock exactly one acts, and the control (`ACTOR_LOCK=off`) shows both going ahead and racing on the epoch file. Freezes the writer: throwaway stack only |
| `test-lease-fence.sh` | 3-step test of the writer's lease (a row renewed by the controller) and the guard that stops the writer when it runs out; a renewed lease, a cut path, and a control without the guard. Cuts the controller's path: throwaway stack only |
| `test-lease-failover.sh` | 2-step test: an isolated writer the actor may not kill; it waits for the lease and promotes. With the guard there is no overlap between the old and new writer; without it, both write for 14 to 16 s |
| `test-lease-handover.sh` | 3-step test: after a failover of an isolated writer the actor gives the new writer a lease at the new epoch and repoints the controller; the lease stays renewed, and when renewals stop the new writer is stopped by its guard |
| `test-actor-timed-kill.sh` | SIGKILL the actor's whole process group at set delays (0.1 to 0.9 s after it starts, so the kill can land inside the promote script), then run it again; one epoch and a writable standby each time. `--delays LIST`. Crashes the writer: throwaway stack only |
| `test-controller-kill.sh` | 2-step test: a controller killed and restarted within the lease time costs nothing; one left dead stops the writer when the lease runs out |
| `test-sync-after-failover.sh` | 3-step measurement: from synchronous replication, crash and promote; the new writer is asynchronous with no standby yet acknowledges a write; the old node rejoins and the rejoin switches sync on again, which closes the window (8.0 s). Crashes the writer: throwaway stack only |
| `measure-recovery.sh [--scenarios LIST] [--results FILE]` | Measures **RPO and RTO and crash recovery**: runs failure trials (stop, crash, async, sync, control, and with `--scenarios crash-matrix` standby-crash, primary-restart, midtx, checkpoint) under a write prober, saves one result line per trial in `docs/recovery-results.txt`, then writes the report. Exits 1 if a trial fails or a target is missed. Takes about 30 s a trial (`MEASURE_TRIALS`, `MEASURE_LAGS`, `MEASURE_SYNC_LAG`, `DECISION_DELAY`, `RTO_TARGET_SECONDS`). Changes the databases: throwaway stack only |
| `write-recovery-report.sh [--results FILE] [--report FILE]` | Judges saved trial results against the targets and writes [docs/recovery-report.md](docs/recovery-report.md): verdict per case, RTO and RPO tables, every trial, limits. Can regenerate the report from saved results without re-running the trials |
| `run-recovery-trial.sh --scenario NAME [--lag S]` | One trial: restores the stack, starts the prober, causes the failure, promotes, reports, restores again. Prints one `RESULT` line |
| `run-write-prober.sh --ledger FILE --stop-file FILE` | Writes numbered rows about every 100 ms and logs each attempt (start, end, node, ok or fail) to a ledger outside both databases; follows a failover by trying the node that last accepted a write, then the other |
| `report-ledger.sh --ledger FILE --node NODE` | Compares a ledger with the surviving node: acknowledged-but-missing (lost) writes, in-doubt writes, and the longest outage |
| `run-all-checks.sh [--skip-roundtrip]` | One line per check: `PASS lint`, `PASS docs`, `PASS python`, `PASS roundtrip`. A failure also prints the last 15 lines of that check's output |
| `check-python.sh` | Checks the Python against the house standard ([docs/python-standard.md](../docs/python-standard.md)): ruff, mypy strict and pytest at pinned versions in a container, refuses `noqa` and `type: ignore`, and tests the checkers against good and bad fixtures. About 5 s; the first run builds the tools image (network needed) |
| `check-docs.sh` | Read-only check of the documents: every relative link must exist, and every function named in `docs/` must be defined in a script (and, on a line that links a script, defined in that script). Uses `check-docs.awk` |
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

## Patterns and diagrams

The robustness patterns the scripts use (promotion guard, split-brain guard, verify after act, decisions read the writer) are explained in
[docs/patterns/](docs/patterns/README.md). How to rotate the database passwords without losing availability is in [docs/secrets-rotation.md](docs/secrets-rotation.md). The role state machine and the 17-step failover sequence are in
[docs/diagrams/](docs/diagrams/).

## What is proven

See [capability-register.md](capability-register.md): each capability with its evidence, status (automated, manual, partial) and
limits, plus the gaps still open. In short: replication, failover and fail-back, RPO and RTO, crash and network faults, secret rotation,
fencing at start time and live (an epoch and a lease with a guard), a failure detector and an acting controller that survives its own
kill. Open: the epoch check in every write, loss/jitter/bandwidth faults, and the application layer (Phase 2); the client service
(Phase 3).

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

- **One controller and one actor**, on one host (a maintenance lock stops two actors there). Replicating them needs a consensus
  store, which is out of scope. The controller is on the write path through the lease, so an outage longer than the lease time
  stops the writer (a choice, CTL-01).
- **The epoch is a file on the host**, and a fenced writer is stopped by a guard that must look in time. A process paused while its
  lease ran out can write once when it resumes; only an epoch check in every write closes that (GAP-03).
- **After a failover from synchronous replication the new writer is asynchronous** until the old node has rejoined (the rejoin
  then switches sync on again, SYNC-01): a window of about the rejoin time with one copy of every write.
- **No client service yet.** The tests write through `psql` and `pgbench`; there is no router, no reconnecting client with
  idempotency keys, and no outbox, event stream or idempotent consumers (GAP-12 in Phase 2; the client service in Phase 3).
- Packet loss, jitter, bandwidth limits and one-way faults on the replication link are not tested (GAP-11).
