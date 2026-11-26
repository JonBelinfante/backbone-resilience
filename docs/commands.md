# Commands for monitoring and control

<!-- toc -->

- [1. Are the containers up?](#1-are-the-containers-up)
- [2. Which node is the writer?](#2-which-node-is-the-writer)
- [3. Is the standby streaming, and how far behind is it?](#3-is-the-standby-streaming-and-how-far-behind-is-it)
- [4. Replication slots and WAL on disk](#4-replication-slots-and-wal-on-disk)
- [5. Is the WAL archive working?](#5-is-the-wal-archive-working)
- [6. Who is connected, and what is running?](#6-who-is-connected-and-what-is-running)
- [7. Control commands](#7-control-commands)
- [8. What to look at first](#8-what-to-look-at-first)

<!-- tocstop -->

This page is a plain reference. It lists the SQL queries and Docker commands that this project uses to watch the database pair. Copy any of them into a runbook. The queries and the `docker` commands in sections 1 to 6 were run against the stack on 2026-11-26. The control commands in section 7 are the ones the tests use, and they were not run for this page.

**Setup.** The containers are `pg-primary`, `pg-standby` and `toxiproxy`. The host ports are 5433 for the primary and 5434 for the standby, both on `127.0.0.1`. To run SQL, open `psql` inside a container and paste the queries.

```bash
docker exec -it pg-primary psql -U postgres -d appdb
docker exec -it pg-standby psql -U postgres -d appdb
```

Each SQL block below says which node to run it on.

## 1. Are the containers up?

```bash
docker compose ps
docker inspect --format '{{.State.Health.Status}}' pg-primary pg-standby
docker exec pg-primary pg_isready -U postgres
docker inspect --format '{{.State.Status}} paused={{.State.Paused}}' pg-standby
docker stats --no-stream
docker logs --since 2m pg-standby
docker volume ls
```

The volumes are `primary-data`, `standby-data`, `pg-archive` and `pg-backup`, each with the prefix `pg-replication_`.

## 2. Which node is the writer?

Run on each node.

```sql
select pg_is_in_recovery();
```

The result `f` means the node accepts writes. The result `t` means it is a standby. After a failover the roles swap, so ask each node and do not assume from its name.

## 3. Is the standby streaming, and how far behind is it?

On the primary:

```sql
select application_name, state, sync_state, replay_lag from pg_stat_replication;

select application_name,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as replay_lag_bytes
from pg_stat_replication;
```

On the standby:

```sql
select pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();

select status, sender_host from pg_stat_wal_receiver;
```

How to read the results:

- A healthy standby shows `streaming` and a lag of 0 bytes. Equal received and replayed positions mean it has caught up.
- The time-based lag columns are empty when no write has happened lately. Use the byte difference instead.
- A paused or cut-off standby still shows `streaming` until the write-ahead log (WAL) sender timeout, which is one minute here. One row was still listed three seconds after `docker pause`. A growing byte lag is the reliable signal.
- If `pg_stat_replication` returns no rows, no standby is connected.

## 4. Replication slots and WAL on disk

On the primary:

```sql
select slot_name, active, wal_status, safe_wal_size from pg_replication_slots;

select count(*), pg_size_pretty(sum(size)) from pg_ls_waldir();

select name, setting, unit
from pg_settings
where name in ('max_wal_size', 'max_slot_wal_keep_size', 'wal_keep_size', 'wal_receiver_timeout');

select pg_size_pretty(pg_database_size('appdb'));
```

- The slot's `wal_status` is `reserved` or `extended` while the slot protects the WAL it needs. The values `unreserved` and `lost` mean the limit was passed and the standby must be rebuilt.
- The value `safe_wal_size` is how many bytes can still be written before the slot loses WAL.
- A dead standby makes the primary keep WAL, up to the limit in `max_slot_wal_keep_size`. Watch `pg_ls_waldir()` while a standby is down.

## 5. Is the WAL archive working?

On the primary:

```sql
select archived_count, failed_count, last_archived_wal, last_failed_wal, last_failed_time
from pg_stat_archiver;
```

The count `failed_count` must stay at 0 while `archived_count` rises. If `failed_count` rises and `archived_count` stays flat, archiving fails and WAL piles up on the primary. The primary log then names the cause, for example `Permission denied`.

## 6. Who is connected, and what is running?

On the primary:

```sql
select state, count(*) from pg_stat_activity where datname = 'appdb' group by state;

select pid, now() - query_start as running, left(query, 40)
from pg_stat_activity
where state <> 'idle' and pid <> pg_backend_pid();

select pg_postmaster_start_time();

show server_version;
```

The standby's own connection appears in the second query as `START_REPLICATION`. That row is normal and lasts as long as the standby streams.

## 7. Control commands

These change the state of the pair. Check the roles in section 2 before and after each one, and never leave two nodes writable.

Docker commands that inject a fault:

```bash
docker pause pg-standby      # freeze the process; the container stays up
docker unpause pg-standby
docker stop pg-primary       # clean shutdown
docker kill pg-primary       # crash, with no clean shutdown
docker start pg-primary
```

SQL on the primary:

```sql
select pg_reload_conf();     -- re-read the settings without a restart
checkpoint;                  -- force a checkpoint
select pg_switch_wal();      -- close the current WAL segment, so it is archived
```

Switch to synchronous replication, and back. This is what the project's mode switch does.

```sql
alter system set synchronous_standby_names = 'FIRST 1 (standby1)';
select pg_reload_conf();

alter system reset synchronous_standby_names;
select pg_reload_conf();
```

Promote the standby. Run it on the standby only, and only after the old primary is stopped or fenced.

```sql
select pg_promote();
```

Two cautions:

- Synchronous replication blocks writes when the standby is down. That is the cost of a recovery point objective of 0. Resetting `synchronous_standby_names` removes the block.
- After a failover the standby is the writer. Starting the old primary again gives two writers, which is split-brain. Rebuild it as a standby first. The [failure-mode index](failure-modes.md) explains the sequence.

## 8. What to look at first

| Symptom | First check | What it tells you |
|---|---|---|
| A write hangs. | `show synchronous_standby_names;` on the primary. | A name means commits wait for that standby. Check that the standby is up. |
| The standby seems behind. | The byte lag in section 3. | A rising lag means the standby is slow or cut off. |
| The disk on the primary grows. | `pg_ls_waldir()`, the slot's `wal_status` and `pg_stat_archiver`. | A dead standby, or a failing archive, keeps WAL on disk. |
| Two nodes say they are writers. | `pg_is_in_recovery()` on each. | Both returning `f` is split-brain. Stop one node before anything else. |
| A node will not start. | `docker logs pg-standby` | The log names the cause, such as a missing WAL segment. |

The [decision guide](decision-guide.md) explains which replication mode and timeouts to choose.
