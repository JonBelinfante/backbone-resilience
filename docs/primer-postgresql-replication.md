# Primer: how PostgreSQL replication works

This primer explains the six ideas that the tests in this repository rely on. Read it before the [capability catalogue](capability-catalogue.md) if replication is new to you. It covers PostgreSQL 16, which the stack runs. Each section ends with the test that shows the idea at work and a link to the official documentation.

## 1. The write-ahead log

PostgreSQL does not change a table file as soon as you commit. It first writes the change to the write-ahead log (WAL), flushes the log to disk, and then reports success. After a crash, PostgreSQL replays the log to rebuild what the table files lack.

Replication reuses this log. A standby receives the same stream of changes and applies them. A position in the log is a log sequence number (LSN). Two nodes with the same LSN hold the same data.

- **Test:** [test-replication-modes.sh](../pg-replication/scripts/test-replication-modes.sh), register rows REP-04 to REP-06.
- **Read more:** [Write-ahead logging](https://www.postgresql.org/docs/16/wal-intro.html).

## 2. Streaming replication and the hot standby

A standby connects to the writer and asks for the log from its last position. The writer sends each record as it is written. The standby applies the records and can answer read-only queries, which makes it a hot standby.

The standby is read-only because it is in recovery. It leaves recovery only when you promote it.

- **Test:** `verify-replication.sh` and the round trip, register rows REP-01 to REP-03.
- **Read more:** [Log-shipping standby servers](https://www.postgresql.org/docs/16/warm-standby.html).

## 3. Asynchronous and synchronous commit

In asynchronous mode the writer reports success once its own log is on disk. The standby may be a little behind. If the writer then crashes, the writes that the standby had not received are lost.

In synchronous mode the writer also waits until the standby confirms the log. A crash then loses no acknowledged write. The price is that commits block when the standby is down or slow.

The setting is `synchronous_standby_names` on the writer. Changing it needs a reload and no restart, so the repository can switch modes while it runs.

- **Test:** the recovery point measurements, register rows RPO-01 and RPO-02, and the throughput cost in LOAD-01.
- **Read more:** [Synchronous replication](https://www.postgresql.org/docs/16/warm-standby.html#SYNCHRONOUS-REPLICATION).

## 4. Replication slots

A slot is a marker on the writer that records how far a standby has read. The writer keeps every log segment that a slot still needs. This protects a standby that is slow or briefly down.

The same protection is a risk. A standby that never returns makes the log grow until the disk is full. The setting `max_slot_wal_keep_size` bounds the growth. When the bound is passed, the slot is marked lost, and the standby must be rebuilt from a clone.

- **Test:** [test-slot-limit.sh](../pg-replication/scripts/test-slot-limit.sh), register row OPS-04.
- **Read more:** [Replication slots](https://www.postgresql.org/docs/16/warm-standby.html#STREAMING-REPLICATION-SLOTS).

## 5. Promotion and timelines

Promotion turns a standby into a writer. PostgreSQL then starts a new timeline, which is a numbered branch of history. The new writer's log carries the new timeline number.

Timelines are how PostgreSQL tells two histories apart. If an old writer and a new writer both accepted writes, they sit on different timelines and cannot simply be joined. This is what the repository calls split brain, and the epoch, the fence and the lease exist to prevent it.

- **Test:** [test-guards.sh](../pg-replication/scripts/test-guards.sh), register rows FOV-01 to FOV-03.
- **Read more:** [Continuous archiving and timelines](https://www.postgresql.org/docs/16/continuous-archiving.html#BACKUP-TIMELINES).

## 6. Rejoining the old writer

An old writer cannot follow the new one unless its history is a prefix of the new history. If it accepted writes that the new writer never saw, the histories have diverged. The tool pg_rewind finds the point of divergence and undoes the old writer's changes after it. The old writer then follows the new one.

pg_rewind needs the old writer to have been stopped cleanly. If a rewind is interrupted, the node is in an unknown state, so the repository writes a marker first and clones the node from scratch when the marker remains.

The writes that pg_rewind discards were acknowledged to clients. Their loss is the cost of asynchronous replication, and the tests measure it.

- **Test:** [test-divergence-rewind.sh](../pg-replication/scripts/test-divergence-rewind.sh) for FOV-09, and [test-rejoin-failure.sh](../pg-replication/scripts/test-rejoin-failure.sh) for FOV-11.
- **Read more:** [pg_rewind](https://www.postgresql.org/docs/16/app-pgrewind.html).

## Backup is not replication

Replication copies a mistake as fast as it copies a good write. A dropped table disappears from the standby within seconds. Recovery from a mistake needs a base backup and the WAL archive, which let you replay to a chosen LSN. The test is [test-point-in-time.sh](../pg-replication/scripts/test-point-in-time.sh), register row BAK-01.

- **Read more:** [Continuous archiving and point-in-time recovery](https://www.postgresql.org/docs/16/continuous-archiving.html).
