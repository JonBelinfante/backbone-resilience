# Commands for monitoring and control

<!-- toc -->

- [1. Are the containers up?](#1-are-the-containers-up)
- [2. Which node is the writer?](#2-which-node-is-the-writer)
- [3. Is the standby streaming, and how far behind is it?](#3-is-the-standby-streaming-and-how-far-behind-is-it)
- [4. Replication slots and WAL on disk](#4-replication-slots-and-wal-on-disk)
- [5. Is the WAL archive working?](#5-is-the-wal-archive-working)
- [6. Who is connected, and what is running?](#6-who-is-connected-and-what-is-running)
- [7. Control: change the state of the pair](#7-control-change-the-state-of-the-pair)
- [8. What to look at first](#8-what-to-look-at-first)

<!-- tocstop -->

This page lists the Docker and SQL commands that the scripts in this repository use to watch and steer the database pair. Each command was run against the stack on 2026-11-26, except the fault commands in section 7, which the test scripts run. Use it to learn what the tests look at, or copy a command into a runbook.

**Conventions.** The containers are `pg-primary`, `pg-standby` and `toxiproxy`. The host ports are 5433 for the primary and 5434 for the standby. Both are bound to `127.0.0.1`. The scripts run `psql` inside a container as the `postgres` user on the database `appdb`, so the commands below do the same. Run them from the `pg-replication` folder.

Define two shell functions once. The option `-Atc` prints unaligned rows with no header, which suits a runbook or a script.

```bash
p() { docker exec pg-primary psql -U postgres -d appdb -X -Atc "$1"; }
s() { docker exec pg-standby psql -U postgres -d appdb -X -Atc "$1"; }
```

## 1. Are the containers up?

| Question | Command |
|---|---|
| What is running? | `docker compose ps` |
| Is each node healthy? | `docker inspect --format '{{.State.Health.Status}}' pg-primary pg-standby` |
| Does the server accept connections? | `docker exec pg-primary pg_isready -U postgres` |
| Is a container paused? | `docker inspect --format '{{.State.Status}} paused={{.State.Paused}}' pg-standby` |
| What are the containers using? | `docker stats --no-stream` |
| What did the server log lately? | `docker logs --since 2m pg-standby` |
| Which volumes hold the data? | `docker volume ls` shows `primary-data`, `standby-data`, `pg-archive` and `pg-backup`, each with the prefix `pg-replication_`. |

## 2. Which node is the writer?

```bash
p 'select pg_is_in_recovery()'   # f means this node accepts writes
s 'select pg_is_in_recovery()'   # t means this node is a standby
```

The script `run-database-sql.sh` gives the same answer: `bash scripts/run-database-sql.sh --container pg-standby --ask recovery`. The script `show-container-info.sh --database primary` prints the container name for a role.

After a failover the roles swap, so ask the node and do not assume from its name.

## 3. Is the standby streaming, and how far behind is it?

```bash
p 'select application_name, state, sync_state, replay_lag from pg_stat_replication'
p 'select application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as replay_lag_bytes from pg_stat_replication'
s 'select pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()'
s 'select status, sender_host from pg_stat_wal_receiver'
```

How to read the results:

- A healthy standby shows `streaming` and a lag of 0 bytes. Equal received and replayed positions mean the standby has caught up.
- The time-based lag columns are empty when no write has happened lately. Use the byte difference instead.
- A **paused or cut-off standby still shows `streaming`** for up to the write-ahead log (WAL) sender timeout, which is one minute here. In the test, one row was still listed three seconds after `docker pause`. A growing byte lag is the reliable signal.
- If `pg_stat_replication` returns no rows, no standby is connected.

The script `bash scripts/verify-replication.sh` proves the whole path with a live write. It inserts a row, times its arrival on the standby and checks that the standby rejects a write. The line `cannot execute INSERT in a read-only transaction` in the standby log is that check working, not a fault.

## 4. Replication slots and WAL on disk

```bash
p 'select slot_name, active, wal_status, safe_wal_size from pg_replication_slots'
p 'select count(*), pg_size_pretty(sum(size)) from pg_ls_waldir()'
p "select name, setting, unit from pg_settings where name in ('max_wal_size','max_slot_wal_keep_size','wal_keep_size','wal_receiver_timeout')"
p "select pg_size_pretty(pg_database_size('appdb'))"
```

- The slot's `wal_status` is `reserved` or `extended` while the slot protects the WAL it needs. `unreserved` or `lost` means the limit was passed and the standby must be rebuilt.
- The value `safe_wal_size` is the number of bytes that can still be written before the slot loses WAL.
- A dead standby makes the primary keep WAL up to the limit in `max_slot_wal_keep_size`. Watch `pg_ls_waldir()` while a standby is down.

## 5. Is the WAL archive working?

```bash
p 'select archived_count, failed_count, last_archived_wal, last_failed_wal, last_failed_time from pg_stat_archiver'
```

The count `failed_count` must stay at 0 while `archived_count` rises. If `failed_count` rises and `archived_count` stays flat, archiving fails and the WAL piles up on the primary.

**Known limit.** On a new stack, the archive volume belongs to root until `backup::prepare` has run. That function runs inside `test-point-in-time.sh`. Until then the postgres user cannot write to `/archive`, and `failed_count` rises with `Permission denied` in the primary log.

## 6. Who is connected, and what is running?

```bash
p "select state, count(*) from pg_stat_activity where datname='appdb' group by state"
p "select pid, now()-query_start as running, left(query,40) from pg_stat_activity where state<>'idle' and pid<>pg_backend_pid()"
p 'select pg_postmaster_start_time()'
p 'show server_version'
```

The standby's own walsender appears in the second query as `START_REPLICATION`. That row is normal and lasts as long as the standby streams.

## 7. Control: change the state of the pair

**Use the scripts** for anything that moves the writer. They check the guards that prevent two writers. The raw commands below are for learning what the scripts do.

| Task | Script | Raw command |
|---|---|---|
| Show or switch the replication mode. | `bash scripts/set-replication-mode.sh --mode status`, `--mode sync` or `--mode async` | The script sets `synchronous_standby_names` on the primary and reloads it. |
| Return to the starting state. | `bash scripts/restore-starting-state.sh` | None. It chooses between a start, a rebuild and a fail-back. |
| Fail over to the standby. | `bash scripts/promote-standby-to-primary.sh` | The script wraps the promotion call in the guards. |
| Rebuild the old primary as a standby. | `bash scripts/promote-primary-to-standby.sh` | The script runs `pg_rewind`, or clones the node. |

Raw commands the tests use to inject a fault:

```bash
docker pause pg-standby       # freeze the process; the container stays up
docker unpause pg-standby
docker stop pg-primary        # clean shutdown
docker kill pg-primary        # crash, with no clean shutdown
docker start pg-primary
p 'select pg_reload_conf()'   # re-read the settings without a restart
p 'checkpoint'                # force a checkpoint
p 'select pg_switch_wal()'    # close the current WAL segment, so it is archived
```

Two cautions:
- Synchronous replication blocks writes when the standby is down. That is the cost of an RPO of 0, and `set-replication-mode.sh --mode async` removes the block.
- A stopped or killed primary is not safe to start again after a failover, because the standby may now be the writer. Run `restore-starting-state.sh` and let it decide.

## 8. What to look at first

| Symptom | First command | What it tells you |
|---|---|---|
| A write hangs. | `p 'show synchronous_standby_names'` | A name here means commits wait for that standby. Check that the standby is up. |
| The standby seems behind. | Section 3, the byte lag. | A rising lag means the standby is slow or cut off. |
| The disk on the primary grows. | `pg_ls_waldir()`, the slot's `wal_status` and `pg_stat_archiver`. | A dead standby, or a failing archive, keeps WAL on disk. |
| Two nodes say they are writers. | `pg_is_in_recovery()` on each. | Both returning `f` is split-brain. Stop one node before anything else. |
| A node will not start. | `docker logs pg-standby` | The log names the cause, such as a missing WAL segment. |

The commands in this page come from the libraries `lib/database.sh` and `lib/container.sh` and from the test scripts. The [decision guide](decision-guide.md) explains which mode and timeouts to choose, and the [failure-mode index](failure-modes.md) lists what each fault does.
