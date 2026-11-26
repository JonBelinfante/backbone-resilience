# The PostgreSQL pair: replication, failover safety and recovery

<!-- toc -->

- [Where this sits in the roadmap](#where-this-sits-in-the-roadmap)
- [Requirements](#requirements)
- [Run](#run)
- [Things to try](#things-to-try)
- [Scripts and libraries](#scripts-and-libraries)
  - [Everyday scripts](#everyday-scripts)
  - [Libraries](#libraries)
  - [Tests of replication, failover and recovery](#tests-of-replication-failover-and-recovery)
  - [Tests of detection, the actor and fencing](#tests-of-detection-the-actor-and-fencing)
  - [Tests of faults, load and secrets, and the measurement runners](#tests-of-faults-load-and-secrets-and-the-measurement-runners)
  - [Checks and tools](#checks-and-tools)
- [Notes](#notes)
- [Logs and audit trail](#logs-and-audit-trail)
- [Patterns and diagrams](#patterns-and-diagrams)
- [What is proven](#what-is-proven)
- [Design notes](#design-notes)
- [Known limits](#known-limits)

<!-- tocstop -->

New here? Start with the [repository README](../README.md) and the [capability catalogue](../docs/capability-catalogue.md). This file is the working reference for the scripts and libraries.

## Where this sits in the roadmap

| Phase | Scope | State |
|---|---|---|
| 1 | The PostgreSQL pair: synchronous and asynchronous replication, manual failover and fail-back, recovery measurements, crash and network faults, secret rotation, guards, a second failure during a rejoin, backup and point-in-time recovery. | Complete. Every item is automated. The register's section 4 names the stretch items that remain. |
| 2 | Failover safety (detector, epoch, actor, leases and guards) and the application layer (outbox, idempotent consumers and an invariant checker). | Failover safety is built, proven and documented as patterns. Three gaps remain: the write check on every table (GAP-03), a replicated controller (GAP-07) and packet loss (GAP-11). The application layer is not started (GAP-12). |
| 3 | The service layer: a load generator, reconnecting clients, recovery time under load, and rotation for application clients. | Not started. |
| 4 to 6 | Hot-hot operation with partitioned ownership, multi-writer operation for commutative entries, and a chaos catalogue with error-budget reporting. | Not started. |

This folder holds the Phase 1 foundation and the Phase 2 failover work. The [capability register](capability-register.md) shows what is proven and what is not.

The container `pg-primary` listens on `localhost:5433` and accepts writes. The container `pg-standby` listens on `localhost:5434`. It is a hot standby. It clones the primary on first start, and then it streams and replays the primary's write-ahead log (WAL). It serves read-only queries.

```
client -> pg-primary --WAL stream--> pg-standby (read-only)
          (slot standby1_slot keeps WAL until received)
```

## Requirements

- You need Docker with Compose.
- You need **Bash 5.0 or later** on the host. The scripts check this and exit with an error otherwise. macOS ships Bash 3.2 in `/bin/bash`. Install a newer version with `brew install bash`, and make sure that it comes first on your `PATH`. The command `bash --version` should show 5.0 or later.
- Every script accepts `-h` and `--help`. The help shows the usage, options, environment and exit codes, even when a tool that the script needs is missing. The tool check runs after the options are read. Two log scripts are an exception, as the section on logs explains.
- Check the scripts against the Bash standard, version 8, with `bash scripts/lint-scripts.sh`. The linter needs `shellcheck` and the bash-standard plugin. The variable `BASHCHECK_WRAPPER` is required. It must point to the plugin's `bin` directory, which holds `check.py`. That script verifies the checker's Secure Hash Algorithm 256 (SHA-256) checksum before it runs the checker. Set the variable once, for example in `~/.zshrc`: `export BASHCHECK_WRAPPER="$HOME/.claude/local-marketplaces/bashcheck/bash-standard/bin"`.

## Run

```bash
cd pg-replication
docker compose up -d
docker compose ps            # wait for both to be healthy
./scripts/verify-replication.sh          # write on primary, read on standby, confirm standby is read-only
```

You can start the scripts from any folder with `bash x.sh`, `./x.sh` or a full path. They find their siblings from their own path. If the scripts are not executable, run `chmod +x scripts/*.sh primary/*.sh standby/*.sh`.

## Things to try

| Experiment | Command | What to observe |
|---|---|---|
| Synchronous against asynchronous replication. | `./scripts/set-replication-mode.sh --mode sync`, `--mode async` or `--mode status`. | `sync_state` becomes `sync`, and the recovery point objective (RPO) becomes 0. |
| A standby outage in asynchronous mode. | `docker stop pg-standby`, then write to the primary. | Writes keep working, and the slot retains the WAL. |
| A standby outage in synchronous mode. | `./scripts/set-replication-mode.sh --mode sync`, then `docker stop pg-standby`, then insert on the primary. | The insert **hangs** until the standby returns. This is the availability cost of an RPO of 0. |
| Catch-up. | `docker start pg-standby`. | The standby resumes from its position in the WAL, and then it converges. |
| Failover. | `docker stop pg-primary`, then `./scripts/promote-standby-to-primary.sh`. | The standby becomes writable, and the timeline increments. |
| Full failover and fail-back. | `./scripts/run-all-checks.sh`, or `./scripts/test-failover-roundtrip.sh` alone. | 17 steps fail over, rejoin the old primary with `pg_rewind`, write while it is down and compare both databases. The starting state is then restored. |

You can connect directly with `psql -h localhost -p 5433 -U postgres appdb`. The password is `postgres`. These credentials are throwaway values for a local experiment only. The ports are published on `127.0.0.1` only, as `docker-compose.yml` shows, so other machines on your network cannot reach the databases. If you have no `psql` on the host, use `docker exec -it pg-primary psql -U postgres appdb`. Keep the loopback binding, because the well-known superuser password would otherwise be open to the whole network.

## Scripts and libraries

A script runs as a command. A library is sourced by a script and runs in the caller's process, so it adds no process or run log for each call. A library assumes that the importing script has `log` and `die`, which come from `runtime.sh`. Scripts import a library with `source "${SCRIPT_DIR}../lib/NAME.sh"` and a `# shellcheck source=` hint.

### Everyday scripts

| Script | What it does |
|---|---|
| `verify-replication.sh` | Writes a row on the primary, reads it on the standby, and confirms that the standby is read-only. |
| `set-replication-mode.sh --mode async\|sync\|status` | Switches the primary between asynchronous and synchronous replication with no restart. It records the wanted mode, so a rejoin can restore it. |
| `bring-down-database.sh --database primary\|standby` | Stops that container cleanly and confirms that it is down. |
| `bring-up-database.sh --database primary\|standby` | Starts the container and waits until it is healthy. It stops the container again if both nodes would be writable, which is the split-brain guard. |
| `promote-standby-to-primary.sh` | Makes `pg-standby` the writable node. It refuses while `pg-primary` answers, unless `--force` is given. It also fences the old primary's data directory. |
| `promote-primary-to-standby.sh [--clone]` | Rebuilds the stopped old primary as a standby of the new writer. It creates the slot, runs a checkpoint, runs `pg_rewind`, writes the standby settings, starts the node, and waits until it streams. With `--clone` it always copies the whole data directory. |
| `restore-starting-state.sh` | Reads the current roles and returns to the starting state, where `pg-primary` writes and `pg-standby` replicates. It starts a stopped node, or fails back with `pg_rewind` after a failover. It starts the writer candidate when both nodes are stopped. It ends only when the primary reports the standby as streaming and the standby has replayed the writer's position. Run it after any experiment. |
| `rotate-secret.sh [--secret replication\|superuser] [--keep-old]` | Rotates a database password with no failed write. The replication secret rotates by overlap, with a second role whose name alternates between `replicator_a` and `replicator_b` and is kept in `secrets/pg-replication-user.txt`. The superuser secret rotates in place. It rolls back before the secret files change, and a re-run converges. See [docs/secrets-rotation.md](docs/secrets-rotation.md). |
| `act-on-failover.sh` | Waits for the controller's `fail-over` decision, using `--controller NAME` and `EPOCH_FILE`. It then raises the epoch, kills the old writer and promotes the standby. A re-run is safe. |
| `collect-logs.sh` | Saves container logs into `logs/`. Run it **before** `docker compose down`, because removing containers deletes their logs. |
| `show-container-info.sh --database primary\|standby` or `--container NAME` | A command-line wrapper over `lib/container.sh`. It prints the container name for a database, or `true` or `false` for whether a container is running. |
| `run-database-sql.sh --container NAME [--bare] [--ask recovery]` | A command-line wrapper over `lib/database.sh`. It runs the Structured Query Language (SQL) text on standard input with `psql` in that container. With `--ask recovery` it prints `t` for a standby and `f` for a node that accepts writes. |

### Libraries

| Library | What it holds |
|---|---|
| `lib/container.sh` and `lib/database.sh` | Most `docker` calls and every `psql` call. `container::` has `name_of`, `is_running`, `inspect`, `image`, `network`, `volume`, `setting`, `health`, `start`, `stop`, `wait_healthy`, `compose_up`, `logs`, `rewind` and `mark_standby`. `database::` has `run`, `bare`, `in_recovery`, `is_ready` and `drop_all_sql`. |
| `lib/story.sh` | The test narration and checks, as `story::` functions. They are `narrate`, `narrate_stream`, `narrate_query`, `run_logged`, `expect_equal`, `run_statement`, `expect_query`, `expect_stopped` and `drop_all_tables`. It declares `# Depends: container database`, so a script that imports it imports those two as well. |
| `lib/access.sh`, `lib/fault.sh` and `lib/toxic.sh` | Controlled faults and access. `access::` sets passwords and probes logins. `fault::` crashes, freezes and isolates a node, delays apply, and generates WAL. `toxic::` adds network delay, silence or a cut link through Toxiproxy. |
| `lib/fence.sh` and `lib/lock.sh` | `fence::` marks a stopped node's data directory so that any start is read-only. `lock::` holds the maintenance lock that one script at a time may take. |
| `lib/epoch.sh`, `lib/lease.sh`, `lib/controller.sh` and `lib/actor.sh` | The failover control plane. `epoch::` keeps the failover number, which only goes up. `lease::` holds the writer's lease and its guard. `controller::` runs the detect-only controller in a container. `actor::` runs the controller and the actor for a test and times the client's view. |
| `lib/backup.sh` | `backup::prepare`, `take_base`, `wait_archived`, `restore_to` and `wait_promoted`. They manage the base backup, the WAL archive and a restored copy at a log sequence number (LSN). The copy runs in its own container, which is not published to the host. |
| `lib/mode.sh` | `mode::record` and `mode::wanted` remember the replication mode that was asked for, so a rejoin can switch synchronous replication on again. |
| `lib/link.sh` | `link::route` points the standby through the proxy. `link::commit_summary` and `link::staleness` time what a link fault does. `link::restart_places` reads the standby's log for the place where each reconnect began. The two link-fault tests share it. |
| `lib/measure.sh`, `lib/judge.sh` and `lib/pytools.sh` | `measure::` gives statistics for trial results. `judge::` reports PASS or FAIL against targets. `pytools::` runs the pinned Python checkers. |
| `runtime.sh` | The Bash standard's own functions, copied unchanged from the standard's examples and checked word for word. They are `log`, `die`, `on_error`, `require_commands`, `require_integer`, `start_run_log` and `cleanup`, with the run-log state. Every host script imports it, so none carries its own copy. Do not edit it. A change to the standard replaces it. |
| `primary/init-replication.sh` and `standby/entrypoint.sh` | These run inside the PostgreSQL image, not on the host, so they cannot import `runtime.sh`. Each carries its own copy of the standard's functions. The first runs once on an empty data volume. The second runs every time the standby container starts. |
| `../services/failover_controller` and `../services/fence_guard` | Python services that run in containers. The first is the detect-only failover controller, which also renews the lease. The second is the guard that stops a writer whose lease has expired. Each has its own tests, which `check-python.sh` runs. |

### Tests of replication, failover and recovery

In this section, SIGKILL is the signal that stops a process at once. Every test restores the starting state when it ends, whether it passes, fails or is interrupted. Every test changes the databases, so run it only on the throwaway stack.

| Script | What it does |
|---|---|
| `test-failover-roundtrip.sh` | A 17-step test that tells its story. Every line has a time in Coordinated Universal Time (UTC) and the script name, with each SQL statement, the data it returned and each script's output. It drops tables, replicates a row, fails over, writes on the promoted standby, rejoins the old primary, writes while the replica is down, and compares both databases. |
| `test-replication-modes.sh` | A 4-step test. It switches the mode with no restart. It then tests asynchronous mode with the standby stopped, synchronous mode with the standby stopped, and synchronous mode with the standby killed mid-commit. |
| `test-clone-rebuild.sh` | A 4-step test. Synchronous replication is on, and the writer names a synchronous standby. After a failover, the old node is rebuilt by cloning the writer. The rebuilt node streams, names no synchronous standby and holds identical rows. |
| `test-guards.sh` | A 3-step test. The promotion guard refuses while the primary answers. With the fence lifted, the split-brain guard stops a restarted old primary. A start with one writer and one replica is allowed. |
| `test-divergence-rewind.sh` | A 10-step test of a true divergence. The standby stops following, and the primary acknowledges 3 writes that it never sends. The standby is promoted by force, and `pg_rewind` rebuilds the old primary. The test requires a real rewind, the 3 writes gone and identical rows on both nodes. |
| `test-rejoin-failure.sh [--control]` | A 4-step test. The writer crashes, and the standby is promoted and takes rows. The rejoin starts, and the new writer is killed while the rebuild marker exists. The restore must bring back a writer and a replica with every acknowledged row on both. The control runs without the kill. |
| `test-point-in-time.sh` | A 5-step test of point-in-time recovery, which takes about 2 minutes. It writes rows, takes a base backup, writes more rows, and then deletes every row by mistake. The mistake replicates within seconds. A restore to the recorded LSN returns the rows and the checksum from before the delete. The control restore to the end of the archive returns none. |
| `test-hard-kill.sh [--target roundtrip\|restore\|rotate] [--delays LIST]` | Kills a script and its Docker commands with SIGKILL at each delay. It then requires `restore-starting-state.sh` to recover the stack, with the primary writing and the standby streaming. |

### Tests of detection, the actor and fencing

| Script | What it does |
|---|---|
| `test-fencing.sh` | A 6-step test of start-time fencing. After a failover, a plain `docker start` of the old primary must come up read-only and refuse a write. A control with the fence lifted shows the write accepted. |
| `test-detector.sh` | A 7-step test of the detect-only failover controller. It covers a healthy writer, a short freeze that causes no fail-over, a hung writer and a crash that cause timed fail-overs, and a controller cut off from a live writer that holds. It also covers the idle-writer trap, where a short witness window causes a false fail-over. |
| `test-auto-failover.sh` | A 3-step test of automatic failover. The controller and `act-on-failover.sh` raise the epoch, kill the old writer and promote. A short freeze does nothing. A crash and a hung writer each end with a client write that succeeds on the new writer, and the test times it. |
| `test-actor-kill.sh` | A 3-step test. It kills the actor with SIGKILL after the epoch, kill and promote steps, through a test hook. It checks the half-done state, runs the actor again, and requires one epoch and a writable standby each time. |
| `test-actor-timed-kill.sh [--delays LIST]` | Kills the actor's whole process group at set delays, from 0.1 to 0.9 seconds after it starts. The kill can land inside the promote script. It then runs the actor again and requires one epoch and a writable standby each time. |
| `test-two-actors.sh` | A 2-step test. Two actors start at once against a frozen writer. With the lock, exactly one acts. In the control, `ACTOR_LOCK=off` lets both go ahead and race on the epoch file. |
| `test-controller-kill.sh` | A 2-step test. A controller that is killed and restarted within the lease time costs nothing. One that is left dead stops the writer when the lease runs out. |
| `test-lease-fence.sh` | A 3-step test of the writer's lease and the guard that stops the writer when the lease runs out. It covers a renewed lease, a cut path, and a control without the guard. |
| `test-lease-failover.sh` | A 2-step test. The actor may not kill an isolated writer, so it waits for the lease and then promotes. With the guard there is no overlap between the old and new writer. Without it, both write for 14 to 16 seconds. |
| `test-lease-handover.sh` | A 3-step test. After a failover of an isolated writer, the actor gives the new writer a lease at the new epoch and repoints the controller. The lease stays renewed. When renewals stop, the guard stops the new writer. |
| `test-lease-failback.sh` | A 3-step test. It fails over an isolated writer with the lease handed on, rebuilds the old node as a standby, and then fails back with the roles swapped. The epoch becomes 2, the first node holds a lease at epoch 2, and the isolated writer is stopped. |
| `test-resume-fence.sh` | A 3-step test. A writer is paused past its lease with a client write waiting. With no check, it accepts the write 3.1 seconds late. With the write check from `lease::install_write_check`, it refuses the write as "fenced". A valid lease and a missing lease are not blocked. |
| `test-sync-after-failover.sh` | A 3-step measurement. It crashes the writer under synchronous replication and promotes the standby. The new writer is asynchronous and acknowledges a write with no standby. The old node rejoins, and the rejoin switches synchronous replication on again, which closes the window after 8.0 seconds. |

### Tests of faults, load and secrets, and the measurement runners

| Script | What it does |
|---|---|
| `test-replica-lag.sh` | An 8-step test. The standby applies changes 6 seconds late. Two debits that are decided on the replica both pass and overdraw the account, which is the negative control. Decided on the writer, the second debit is declined. The guard `database::read_for_decision` refuses a replica. A replica read after `database::wait_for_replay` is fresh. |
| `test-slot-limit.sh` | A 7-step test of the WAL limit for a dead standby. It stops the standby and writes WAL until its slot is invalidated, at about 1 GB and about 1.5 minutes. The primary must keep accepting writes with a bounded WAL directory, and the standby must fail to stream. `restore-starting-state.sh` must clone the standby and replace the slot. It needs 6 GB free. |
| `test-load.sh` | A 6-step test of 16 concurrent clients that use `pgbench`. They insert payments with idempotency keys from a million values. No transaction fails, duplicates are rejected, money is conserved exactly, and the standby is identical in both modes. The test reports the throughput for both modes. A writer that is killed mid-run recovers whole. `LOAD_CLIENTS`, `LOAD_SECONDS` and `LOAD_KEYS` resize it. |
| `test-network-faults.sh` | A 7-step test of the replication link through Toxiproxy, which takes about 5 minutes. It covers asynchronous delay, synchronous delay, a link cut for 5 seconds, a silent link, and the RPO under delay followed by a writer crash. |
| `test-link-faults.sh` | A 6-step test of the replication link under jitter, a bandwidth limit, silence in one direction and a link that drops every connection after a byte budget. It takes about 5 minutes. Packet loss itself cannot be shown through Toxiproxy. |
| `test-rotation.sh` | A 7-step test. It rotates the replication secret, the superuser secret and the replication secret again under a write probe. It requires no failed write, a standby that streams as the role in the secret file, one replication role left, and a standby rebuilt from an empty volume that joins with the new secrets. `ROTATION_MODE=sync` runs it under synchronous replication. |
| `test-maintenance-lock.sh` | A 5-step test of the maintenance lock. Two rotations together must give a refusal for the second. A rotation during a rebuild is refused, and the rebuild completes. A stale lock is taken over, and a reused process identifier is not honoured. |
| `measure-recovery.sh [--scenarios LIST] [--results FILE]` | Measures the RPO, the recovery time objective (RTO) and crash recovery. It runs failure trials under a write prober, saves one result line for each trial in `docs/recovery-results.txt`, and writes the report. It exits with status 1 if a trial fails or a target is missed. A trial takes about 30 seconds. |
| `write-recovery-report.sh [--results FILE] [--report FILE]` | Judges saved trial results against the targets and writes [docs/recovery-report.md](docs/recovery-report.md). It can regenerate the report from saved results without running the trials again. |
| `run-recovery-trial.sh --scenario NAME [--lag S]` | Runs one trial. It restores the stack, starts the prober, causes the failure, promotes, reports, and restores again. It prints one `RESULT` line. |
| `run-write-prober.sh --ledger FILE --stop-file FILE` | Writes numbered rows about every 100 milliseconds. It logs each attempt, with its start, end, node and outcome, to a ledger outside both databases. It follows a failover by trying the node that last accepted a write and then the other. |
| `report-ledger.sh --ledger FILE --node NODE` | Compares a ledger with the surviving node. It reports acknowledged writes that are missing, writes in doubt, and the longest outage. |

### Checks and tools

| Script | What it does |
|---|---|
| `run-all-checks.sh [--skip-roundtrip]` | Prints one line for each check, which is PASS or FAIL. The checks are `lint`, `docs`, `python`, `hygiene`, `timeline` and `roundtrip`. A failure also prints the last 15 lines of that check's output. |
| `lint-scripts.sh` | Runs `bash -n`, ShellCheck and the Bash standard checker on every shell file. It needs `BASHCHECK_WRAPPER`. |
| `check-python.sh` | Checks the Python against the [house standard](../docs/python-standard.md) with ruff, mypy in strict mode and pytest at pinned versions in a container. It refuses `noqa` and `type: ignore`, and it tests the checkers against good and bad fixtures. It takes about 5 seconds. The first run builds the tools image and needs the network. |
| `check-docs.sh` | Checks the documents without changing them. Every relative link must exist. Every function that `docs/` names must be defined in a script. On a line that links a script, the function must be defined in that script. It uses `check-docs.awk`. |
| `check-hygiene.sh` | Checks that host scripts make no direct `docker`, `psql` or `pgbench` calls, that every published port is on loopback, and that no tracked file holds a private key or an access token. |
| `check-run-timeline.sh` | Runs two scripts under one run folder and checks the merged timeline. Both scripts must be present, every line must have a millisecond timestamp, and the timestamps must never go backwards. |
| `run-with-log-folder.sh [--merge] -- COMMAND ...` | Runs the command with one shared run folder, named `run-<time>.<random>.d`, inside `RUN_LOG_DIR`. Every script that the command starts logs there, however deeply. It prints the folder. With `--merge` it also prints the merged timeline. |
| `merge-run-logs.sh [--dir FOLDER]` | Merges all run logs of one folder into one timeline. The default is the newest folder. The lines read `timestamp script LEVEL message` and are sorted by timestamp. It does not change any file. |
| `report-refactoring.sh [--mode MODE] [--show NAME]` | A read-only refactoring aid. The modes are `duplicates`, `usage`, `size`, `all`, `brief`, `baseline` and `changes`. `--show NAME` prints every copy of a function and how the copies differ. It uses `report-refactoring.awk`. |

## Notes

- The names `primary` and `standby` always mean the containers `pg-primary` and `pg-standby`, whatever role each has after a failover.
- If the stack cannot be restored, `docker compose down -v` **deletes both databases** and starts clean.
- A fail-back under asynchronous replication can lose writes that the new writer had not yet sent to the node that is promoted.
- Set `RUN_LOG_DIR=logs` to keep the story as a run log. Set `UP_PULL_POLICY=never` if Docker Hub is unreachable.
- The scripts read passwords from the writer container's environment. They never store passwords in the scripts.

## Logs and audit trail

Every script run writes one run log, as the Bash standard requires. Each script appends timestamped `INFO`, `WARN` and `ERROR` lines to its own file. The lines show when it started, each step, its decisions and how it ended. A failure records the line, the function and the command that failed. Decisions, such as refusing or performing a promotion or changing the synchronous mode, appear as `DECISION:` and `CHANGE:` lines.

Known limit: `run-with-log-folder.sh` and `merge-run-logs.sh` read `RUN_LOG_DIR` when they start. Their `--help` therefore needs `RUN_LOG_DIR` to be set. The other scripts supply a default. A fix needs the standard to allow a folder read after the library imports. The limit does not change any result.

| File | Contents |
|---|---|
| `$RUN_LOG_DIR/<script>-<UTC time>.<random>.log` | One run of one script. The `.log` suffix is added after creation, as CR-8 in `docs/change-request-bash-standard.md` explains. `RUN_LOG_DIR` defaults to the temporary directory, and the folder must exist. Set `RUN_LOG_DIR=logs` to keep run logs in this folder, which git ignores. |
| `logs/container-<name>-<time>.log` | Container logs, which `./scripts/collect-logs.sh` saves. They hold the PostgreSQL server log and the init and entrypoint lines. `LOG_DIR` sets the folder. The default is `logs`, and the script creates it if it is missing. |

A script's own results still go to the terminal. Its output is not copied into the run log, and there is no `runs.log` index and no `TRACE=1` command trace. Use `bash -x scripts/<script>.sh` to trace a run.

One test run writes 16 run logs. It wrote 87 when the SQL and container helpers were scripts and not libraries. To collect a whole run, use `RUN_LOG_DIR=logs bash scripts/run-with-log-folder.sh --merge -- bash scripts/test-failover-roundtrip.sh`. The log lines carry UTC timestamps to the millisecond, such as `2026-11-14T08:14:36.385Z`. The merged timeline therefore orders events from different scripts correctly. Lines in the same millisecond keep their own file's order.

The logs are small text files in the `logs/` folder. Set `LOG_DIR=/some/other/path` to keep them elsewhere.

## Patterns and diagrams

The [patterns](docs/patterns/README.md) explain the robustness techniques that the scripts use. They cover the promotion guard, the split-brain guard, verify after act, decisions that read the writer, the epoch, the lease and guard, the restartable actor, the witness detector, the negative control and the kill-test harness. [Secrets rotation](docs/secrets-rotation.md) explains how to rotate the database passwords without losing availability. The [diagrams](docs/diagrams/) show the role state machine and the 17-step failover sequence.

## What is proven

The [capability register](capability-register.md) lists each capability with its status, result and limit. It also lists the gaps that remain open. In short, the project has proven replication, failover and fail-back, recovery point and recovery time measurements, crash and network faults, secret rotation, backup with point-in-time recovery, and fencing at start time and while running. It has also proven a failure detector and an acting controller that survives its own kill. The open work is the write check on every table, a replicated controller and real packet loss, which belong to Phase 2. The application layer is also Phase 2, and the client service is Phase 3.

## Design notes

- **Replication slot.** The slot `standby1_slot` guarantees that the primary keeps the WAL the standby still needs, so a temporarily disconnected standby can always catch up. The setting `max_slot_wal_keep_size=1GB` bounds the risk of a dead standby filling the primary's disk. A standby that falls further behind than that must be cloned again.
- **`application_name=standby1`.** It identifies the standby, and it is the name that synchronous replication targets.
- **`wal_log_hints=on`.** With matching WAL settings on the standby, it lets a promoted standby feed a rebuilt old primary. It also allows `pg_rewind`, which `promote-primary-to-standby.sh` uses.
- **WAL archive.** The primary copies each completed WAL segment into the `pg-archive` volume. The `pg-backup` volume holds base backups. Both support point-in-time recovery.
- **Named Docker volumes.** The database files live inside Docker and not in this folder, so no tool that syncs the project folder touches live database files.
- **Reset everything.** `docker compose down -v` deletes both databases.

## Known limits

These limits are deliberate and belong to later phases.

- **One controller and one actor.** They run on one host, and a maintenance lock stops two actors there. Replicating them needs a consensus store, which is out of scope. The controller is on the write path through the lease, so an outage longer than the lease time stops the writer. That is a choice (CTL-01).
- **The epoch is a file on the host.** A guard stops a fenced writer, and the guard must look in time. The lease check (LEASE-04) refuses a write from a process that was paused while its lease ran out. That check is opt-in for each table, it uses the node's own clock, and it compares lease time and not epochs (GAP-03).
- **A failover from synchronous replication leaves the new writer asynchronous** until the old node has rejoined. The rejoin then switches synchronous replication on again (SYNC-01). The window lasts about as long as the rejoin takes, and every write has one copy only.
- **There is no client service yet.** The tests write through `psql` and `pgbench`. There is no router, no reconnecting client with idempotency keys, and no outbox, event stream or idempotent consumer. These belong to Phase 2 (GAP-12) and Phase 3.
- **Real packet loss and reordering are not tested.** The Transmission Control Protocol (TCP) hides them from Toxiproxy (GAP-11). Jitter, a bandwidth limit, one-way silence and a dropping link are tested (NET-04 to NET-07).
- **Point-in-time recovery covers one timeline** (BAK-01). The archive is on the primary only, the target is an LSN, and everything is on one host. There is no failover between backup and recovery, no off-site copy and no retention policy. Recovery by time is not built.
- **Only one standby is tested.** Every synchronous result is for one standby (P1-08, a stretch item).
