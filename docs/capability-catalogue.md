# Capability catalogue: how to build a resilient database platform

<!-- toc -->

- [Status at a glance](#status-at-a-glance)
- [Contents](#contents)
- [1. Replication and its price](#1-replication-and-its-price)
  - [1.1 A hot standby that builds itself and stays current](#11-a-hot-standby-that-builds-itself-and-stays-current)
  - [1.2 Asynchronous or synchronous, switched without a restart](#12-asynchronous-or-synchronous-switched-without-a-restart)
  - [1.3 A rebuilt standby does not inherit the writer's settings](#13-a-rebuilt-standby-does-not-inherit-the-writers-settings)
  - [1.4 The modes with the standby down and killed](#14-the-modes-with-the-standby-down-and-killed)
  - [1.5 The clone rebuild carries no synchronous setting](#15-the-clone-rebuild-carries-no-synchronous-setting)
- [2. Moving the writer safely](#2-moving-the-writer-safely)
  - [2.1 Manual failover and fail-back](#21-manual-failover-and-fail-back)
  - [2.2 Guard rails around the role change](#22-guard-rails-around-the-role-change)
  - [2.3 A true divergence is rewound and the loss is counted](#23-a-true-divergence-is-rewound-and-the-loss-is-counted)
  - [2.4 Return to the starting state from anywhere, even after a kill](#24-return-to-the-starting-state-from-anywhere-even-after-a-kill)
  - [2.5 A second failure during a rejoin](#25-a-second-failure-during-a-rejoin)
- [3. Fencing: never two writers](#3-fencing-never-two-writers)
  - [3.1 Start-time fence](#31-start-time-fence)
  - [3.2 A lease and a guard stop a running writer](#32-a-lease-and-a-guard-stop-a-running-writer)
  - [3.3 The write itself checks the lease](#33-the-write-itself-checks-the-lease)
  - [3.4 The lease follows the writer](#34-the-lease-follows-the-writer)
  - [3.5 The fail-back works the same way](#35-the-fail-back-works-the-same-way)
- [4. Automatic failover](#4-automatic-failover)
  - [4.1 A failure detector that a pause does not fool](#41-a-failure-detector-that-a-pause-does-not-fool)
  - [4.2 An actor that fences, promotes and records an epoch](#42-an-actor-that-fences-promotes-and-records-an-epoch)
  - [4.3 Only one actor acts](#43-only-one-actor-acts)
  - [4.4 The controller can die](#44-the-controller-can-die)
  - [4.5 The window after failing over from synchronous replication](#45-the-window-after-failing-over-from-synchronous-replication)
- [5. Measuring loss and downtime](#5-measuring-loss-and-downtime)
- [6. Surviving crashes, load and network faults](#6-surviving-crashes-load-and-network-faults)
  - [6.1 Crash recovery is correct](#61-crash-recovery-is-correct)
  - [6.2 Concurrent load keeps money exact](#62-concurrent-load-keeps-money-exact)
  - [6.3 Network faults: delay, a cut link and silence](#63-network-faults-delay-a-cut-link-and-silence)
  - [6.4 More link faults: jitter, bandwidth, one-way silence and a dropping link](#64-more-link-faults-jitter-bandwidth-one-way-silence-and-a-dropping-link)
  - [6.5 A dead standby cannot fill the primary's disk](#65-a-dead-standby-cannot-fill-the-primarys-disk)
- [7. Safe decisions and safe secrets](#7-safe-decisions-and-safe-secrets)
  - [7.1 Decisions never read a lagging replica](#71-decisions-never-read-a-lagging-replica)
  - [7.2 Rotating database secrets with no failed write](#72-rotating-database-secrets-with-no-failed-write)
- [8. Backup and point-in-time recovery](#8-backup-and-point-in-time-recovery)
  - [8.1 A mistaken delete is undone from a base backup and the archive](#81-a-mistaken-delete-is-undone-from-a-base-backup-and-the-archive)
- [9. Engineering practice that makes the proof trustworthy](#9-engineering-practice-that-makes-the-proof-trustworthy)
- [10. What this catalogue does not cover](#10-what-this-catalogue-does-not-cover)

<!-- tocstop -->

This is the learning guide to the repository. Each entry names a **problem** that a database platform meets when something fails. It then gives the **mechanism** that answers the problem, the **test** that shows the mechanism working, the **result** that we measured, and the **limit** of the evidence.

Every claim is backed by a row in the [capability register](../pg-replication/capability-register.md), which holds the status and the limit. The commands and numbers of each run are in the [evidence log](../pg-replication/evidence-log.md).

All measurements come from one laptop running Docker Compose, PostgreSQL 16 and two nodes on one host. They show how each mechanism behaves and what it costs. They are not production figures, because a real network, disk and fleet will differ.

Some tests include a **control**. A control is a variant of the test that must fail, and it proves that the test can see the problem. An entry says so when it has one.

Every test runs from the `pg-replication/` folder as `bash scripts/NAME.sh`. The [README](../README.md#run-it) shows how to start the stack. Each test restores the starting state afterwards, so you can run the tests in any order.

## Status at a glance

Phase 1 is complete. Every Phase 1 capability has an automated test, and each test restores the stack when it ends. Part of Phase 2, the failover safety work, is also built and proven. The open items are listed in section 10.

| Section | Theme | State |
|---|---|---|
| 1 | Replication and its price | Complete and automated. |
| 2 | Moving the writer safely | Complete and automated. |
| 3 | Fencing: never two writers | Built and automated. The write check is opt-in for each table. |
| 4 | Automatic failover | Built and automated. The controller and the actor are single instances. |
| 5 | Measuring loss and downtime | Measured. The detector is measured under a heartbeat only. |
| 6 | Surviving crashes, load and network faults | Complete and automated. Real packet loss is not shown. |
| 7 | Safe decisions and safe secrets | Complete and automated. Application clients are Phase 3. |
| 8 | Backup and point-in-time recovery | Complete and automated for one timeline. |
| 9 | Engineering practice | In place and enforced by the checks. |

## Contents

1. [Replication and its price](#1-replication-and-its-price)
2. [Moving the writer safely](#2-moving-the-writer-safely)
3. [Fencing: never two writers](#3-fencing-never-two-writers)
4. [Automatic failover](#4-automatic-failover)
5. [Measuring loss and downtime](#5-measuring-loss-and-downtime)
6. [Surviving crashes, load and network faults](#6-surviving-crashes-load-and-network-faults)
7. [Safe decisions and safe secrets](#7-safe-decisions-and-safe-secrets)
8. [Backup and point-in-time recovery](#8-backup-and-point-in-time-recovery)
9. [Engineering practice that makes the proof trustworthy](#9-engineering-practice-that-makes-the-proof-trustworthy)
10. [What this catalogue does not cover](#10-what-this-catalogue-does-not-cover)

---

## 1. Replication and its price

### 1.1 A hot standby that builds itself and stays current

- **Problem:** A second copy of the data must exist, stay current and be rebuildable without hand work.
- **Mechanism:** Streaming replication sends the write-ahead log (WAL) to the standby. A replication slot keeps the WAL that the standby still needs. The standby clones the primary on first start with `pg_basebackup` and then follows it read-only.
- **Test:** `verify-replication.sh`, and the first step of every other test.
- **Result:** A committed write appears on the standby. Schema changes replicate. The standby refuses writes. A standby that was down catches up from its slot in about 1 second for a small write.
- **Limit:** There is one standby, on the same host.
- **Register:** REP-01 to REP-04, OPS-03 and FOV-05.

### 1.2 Asynchronous or synchronous, switched without a restart

- **Problem:** You must choose between speed (asynchronous) and zero loss (synchronous). You may need to change your mind while the system runs.
- **Mechanism:** `set-replication-mode.sh --mode async|sync|status` changes `synchronous_standby_names` and reloads the configuration.
- **Result:** With the standby up, a synchronous commit took 60 milliseconds. With the standby stopped, the commit blocked for 8.6 seconds until the standby returned. That block is the price of zero loss. Under 16 concurrent clients, synchronous replication gave about half the throughput of asynchronous replication. The rates were 8,957 and 19,193 transactions per second, and the latencies were 1.79 and 0.83 milliseconds.
- **Register:** REP-05, REP-06 and LOAD-01.

### 1.3 A rebuilt standby does not inherit the writer's settings

- **Problem:** A promoted standby that still names a synchronous standby blocks every write. A rebuilt node that keeps old connection settings also keeps an old password.
- **Mechanism:** The rebuild writes `primary_conninfo` into a new file and moves it into place. It also drops `synchronous_standby_names`. Each node must hold at most one connection line.
- **Result:** A test found 88 stale connection lines. The defect is fixed, and every recovery now checks for it.
- **Register:** REP-07 and SEC-R2.

### 1.4 The modes with the standby down and killed

- **Problem:** A stopped or killed standby must not cost the writer more than the chosen mode promised.
- **Test:** `test-replication-modes.sh` switches the mode with no restart. It then runs asynchronous with the standby stopped, synchronous with the standby stopped, and synchronous with the standby killed (SIGKILL) during a commit.
- **Result:** An asynchronous commit took 58 milliseconds with the standby down, and the replication slot kept the WAL for it. A synchronous commit was still waiting after 5 seconds. It completed 7.4 seconds after it started, when the standby returned. When the standby was killed mid-commit, the commit waited and finished after the restart. The standby then held all 3 acknowledged rows.
- **Register:** REP-04, REP-05 and REP-06.

### 1.5 The clone rebuild carries no synchronous setting

- **Problem:** A node that is cloned from a writer must not copy the writer's synchronous setting.
- **Test:** `test-clone-rebuild.sh` makes the new writer name a synchronous standby. It then rebuilds the old primary by cloning the writer.
- **Result:** The test asserts that the source names a synchronous standby. The rebuilt node names none, streams, and holds identical rows. It can therefore be promoted without blocking writes.
- **Register:** REP-07.

---

## 2. Moving the writer safely

### 2.1 Manual failover and fail-back

- **Problem:** The writer is gone. The standby must become the writer, and the old node must later return as a standby.
- **Mechanism:** `promote-standby-to-primary.sh` promotes the standby. `promote-primary-to-standby.sh` rebuilds the old primary behind the new writer with `pg_rewind`, a slot and standby settings.
- **Test:** `test-failover-roundtrip.sh` runs 17 steps of failover and fail-back. It narrates every Structured Query Language (SQL) statement and its result.
- **Result:** The roles swap and swap back. Both nodes end with identical data.
- **Register:** FOV-01, FOV-04 and FOV-06. The [failover sequence diagram](../pg-replication/docs/diagrams/failover-sequence.md) shows the steps.

### 2.2 Guard rails around the role change

- **Problem:** Two writers appear if the standby is promoted while the old primary still answers. They also appear if the old primary restarts after a failover.
- **Mechanism:** A promotion guard refuses while the old primary is reachable. A split-brain guard stops a restarted old primary when the other node is already writable.
- **Test:** `test-guards.sh`.
- **Result:** With the primary answering, the promotion was refused and the standby stayed a replica. A restarted old primary was stopped again by the start script once its fence was lifted. Promotion fences the old primary first, as section 3.1 explains. A control showed that a start with one writer and one replica is allowed.
- **Limit:** These are script checks, not real fencing. Section 3 describes the fence.
- **Patterns:** [promotion guard](../pg-replication/docs/patterns/promotion-guard.md), [split-brain guard](../pg-replication/docs/patterns/split-brain-guard.md) and [verify after act](../pg-replication/docs/patterns/verify-after-act.md).
- **Register:** FOV-02 and FOV-03.

### 2.3 A true divergence is rewound and the loss is counted

- **Problem:** The old primary accepted writes that the new writer never saw. Taking it back must undo them.
- **Test:** `test-divergence-rewind.sh`. The old primary acknowledges 3 writes that the standby never receives. The standby is promoted anyway. `pg_rewind` then reports "servers diverged" and does a real rewind.
- **Result:** The old primary rejoins identical to the new writer. The 3 acknowledged writes are lost, which is observed data loss under asynchronous replication.
- **Register:** FOV-09.

### 2.4 Return to the starting state from anywhere, even after a kill

- **Problem:** A failover script may die half way. The platform must then recover by itself.
- **Mechanism:** `restore-starting-state.sh` reads the current roles and repairs them. A rebuild-pending marker makes a half-rewound node be cloned again and never trusted.
- **Test:** `test-hard-kill.sh` sends SIGKILL to the round trip, the restore and the rotation at set delays.
- **Result:** All 16 kills of the round trip and all kills of the restore were recovered. The test found four real faults. They were a stuck split-brain guard, `pg_rewind` on a half-rewound directory, status queries during shutdown, and a wedged standby that was reported as a success. All four are fixed. Two later defects, found by the fail-back test, are also fixed. The restore now rebuilds a stopped standby that does not stream. It also waits until the standby has replayed the writer's position before it reports success.
- **Pattern:** [kill-test harness](../pg-replication/docs/patterns/kill-test-harness.md).
- **Register:** FOV-07, FOV-08, OPS-01, OPS-02 and OPS-05.

### 2.5 A second failure during a rejoin

- **Problem:** The writer dies while the old node is being rebuilt as a standby. Both nodes are then down, and one has a half-changed data directory.
- **Test:** `test-rejoin-failure.sh` kills the new writer once the rebuild marker appears. The restore must then bring the stack back with every acknowledged row on both nodes. A `--control` run has no kill, and it shows that the marker is what the kill leaves behind.
- **Result:** The restore first refused to act when both nodes were stopped. It now starts the writer candidate. That is the node without the replica marker, or else the node on the newer timeline, which is read from the stopped volume. It then restores from there. After the fix, all 8 acknowledged rows were on both nodes, with equal checksums.
- **Limit:** The test kills the writer at one point only, while the marker exists.
- **Register:** FOV-11.

---

## 3. Fencing: never two writers

### 3.1 Start-time fence

- **Problem:** The old primary may be started again with a plain `docker start`, which bypasses every script.
- **Mechanism:** The old node's data directory receives a `standby.signal` file, so any start comes up read-only.
- **Test:** `test-fencing.sh`.
- **Result:** The fenced node came up in recovery and refused a write. In the control, the fence was lifted. The node then came up writable and accepted the write. That control is the split-brain that the test must be able to see.
- **Limit:** The fence acts at the next start only. The lease in section 3.2 handles a node that keeps running.
- **Pattern:** [split-brain guard](../pg-replication/docs/patterns/split-brain-guard.md).
- **Register:** FOV-10.

### 3.2 A lease and a guard stop a running writer

- **Problem:** The old writer is partitioned but still running, and it cannot be killed.
- **Mechanism:** The controller renews a lease row on the writer, using the writer's own clock. A guard beside the writer stops it when the lease expires.
- **Test:** `test-lease-fence.sh` and then `test-lease-failover.sh`.
- **Result:** After the writer was cut off, its last write was accepted 5.3 seconds later, and the first refusal came at 5.6 seconds. In a failover of an isolated writer there was a gap of 8.8 to 9.6 seconds and no overlap between the old and new writer. In the control there was no guard. The old writer kept writing, and there were 14 to 16 seconds of two writers.
- **Limit:** Safety is bought with availability. A controller outage that is longer than the lease time stops a healthy writer.
- **Patterns:** [lease and guard](../pg-replication/docs/patterns/lease-and-guard.md) and [epoch](../pg-replication/docs/patterns/epoch-fencing-token.md).
- **Register:** LEASE-01 and LEASE-02.

### 3.3 The write itself checks the lease

- **Problem:** A writer that is paused while its lease runs out can resume and write once before its guard looks. The guard polls from outside, so it can arrive too late.
- **Mechanism:** A trigger on the table reads the lease inside every write. It refuses the write if the lease has expired.
- **Test:** `test-resume-fence.sh` freezes the writer for 8 seconds with a 5-second lease and a client write waiting.
- **Result:** With no check, the write was accepted 3.1 seconds after the lease ran out. With the check, it was refused with the message "fenced", and nothing was written. A write under a valid lease was accepted. So was a write on a node with no lease.
- **Limit:** The check is opt-in for each table. It uses the node's own clock, and it compares lease time, not epochs.
- **Pattern:** [lease and guard](../pg-replication/docs/patterns/lease-and-guard.md).
- **Register:** LEASE-04.

### 3.4 The lease follows the writer

- **Problem:** After a failover the new writer must be fenced too. Otherwise it is unprotected.
- **Mechanism:** The actor installs a lease at the new epoch and starts a guard beside the new writer. It then points the controller at the new writer.
- **Test:** `test-lease-handover.sh`, which includes a kill part way through the hand-over.
- **Result:** The new writer's lease was at epoch 1 and was renewed over 9 seconds. When renewals stopped, the writer was fenced within 5.8 seconds. A re-run repaired the kill during the hand-over.
- **Register:** LEASE-03.

### 3.5 The fail-back works the same way

- **Test:** `test-lease-failback.sh` fails over an isolated writer, rebuilds the old node as a standby and then fails back.
- **Result:** The epoch went to 2. The node that was first the writer held a lease at epoch 2 and kept it renewed. The isolated writer was stopped. Two runs gave the same outcome.
- **Register:** LEASE-05.

---

## 4. Automatic failover

### 4.1 A failure detector that a pause does not fool

- **Problem:** A healthy writer may be promoted because the observer has a problem and the writer does not.
- **Mechanism:** The detector uses two vantage points. A controller probes the writer, and the standby reports whether the writer still feeds it. A verdict of `fail-over` needs three failed probes in a row and a silent standby. Other verdicts include `hold-writer-alive`, where the controller is cut off but the standby still hears the writer. Another is `cannot-fail-over`, where both views are unavailable.
- **Test:** `test-detector.sh` has 7 steps, and the pure decision function has 8 unit tests.
- **Result:** A 3-second freeze produced no failover. A hung writer was declared after 6.4 seconds. A controller that was cut off from a live writer never failed over. In the control, the writer was idle and the witness window was short. The same cut then caused a false failover. An idle writer talks to its standby only about every 30 seconds, so a shorter witness window fools the detector.
- **Pattern:** [witness detector](../pg-replication/docs/patterns/witness-detector.md).
- **Register:** DET-01.

### 4.2 An actor that fences, promotes and records an epoch

- **Problem:** The decision must become a safe promotion, and the actor must survive its own failure.
- **Mechanism:** `act-on-failover.sh` does three steps in order. It raises the epoch, which is a number that only goes up. It stops the old writer. It then promotes the standby. A step that is already done is skipped, so a re-run finishes the same failover at the same epoch.
- **Test:** `test-auto-failover.sh` runs the whole path. `test-actor-kill.sh` kills the actor after each step. `test-actor-timed-kill.sh` kills its whole process group between 0.1 and 0.9 seconds after it starts.
- **Result:** A client could write again 2.8 to 2.9 seconds after a crash, and 8.0 seconds once. After a hung writer the delay was 7.2 to 8.3 seconds. A 2-second freeze caused no action. Every kill recovered to one epoch and a writable standby, including seven kills that landed inside the promote script.
- **Patterns:** [restartable actor](../pg-replication/docs/patterns/restartable-actor.md) and [epoch](../pg-replication/docs/patterns/epoch-fencing-token.md).
- **Register:** ACT-01, ACT-02 and ACT-04.

### 4.3 Only one actor acts

- **Problem:** Two actors may decide at the same moment and both promote.
- **Mechanism:** A maintenance lock allows one actor at a time. It is a folder lock on one host, and it takes over from a dead holder.
- **Test:** `test-two-actors.sh`. In the control the lock is off. Both actors then went ahead, and the control exposed a real race on the epoch file.
- **Limit:** The lock works on one host only. A distributed lock needs a consensus store, which is out of scope.
- **Register:** ACT-03.

### 4.4 The controller can die

- **Problem:** The controller is on the write path through the lease.
- **Test:** `test-controller-kill.sh`.
- **Result:** When the controller restarted within the lease time, nothing was refused and no failover was decided. When it was left dead, its guard stopped the writer in about 5.3 seconds. This is a deliberate trade-off. Run the controller under a supervisor, and set the lease time longer than the restart time.
- **Register:** CTL-01.

### 4.5 The window after failing over from synchronous replication

- **Problem:** After a failover the new writer has no standby, so it runs asynchronously until synchronous replication is switched on again.
- **Mechanism:** The wanted mode is recorded when it is set. After the old node has rejoined and streams, the rejoin switches synchronous replication on for the new writer.
- **Test:** `test-sync-after-failover.sh`.
- **Result:** The new writer acknowledged a write with one copy only. The rejoin closed the window with no manual step, 8.0 seconds after the crash.
- **Limit:** The window lasts as long as the rejoin takes, and a crashed node is cloned again. The actor cannot switch synchronous replication on itself, because that blocks every write while there is no standby.
- **Register:** SYNC-01.

---

## 5. Measuring loss and downtime

The recovery point objective (RPO) is the number of acknowledged writes that are missing on the surviving site. The recovery time objective (RTO) is the time until a client write succeeds again.

| Measurement | Method | Result |
|---|---|---|
| RPO, asynchronous (RPO-01) | Isolate the standby for a set lag, crash the writer, promote at once and compare a write ledger. | A lag of 0 seconds lost 0 writes, 1 second lost 6, and 3 seconds lost 17 to 18. That is about 6 writes for each second of lag, which is the write rate. |
| RPO, synchronous (RPO-02) | The same test with synchronous replication. | No writes were lost in any trial. The control used commit level `local` and lost 17, so the test can see a loss. The price was a write block of 3.4 to 3.7 seconds while the standby was cut off. |
| RPO under gradual delay (RPO-03) | Add Toxiproxy latency to the replication link. | The loss tracks the delay and is not only an all-or-nothing partition. |
| RTO, scripted (RTO-01) | A prober writes about every 100 milliseconds through a clean stop or a crash. | A crash gave 312 to 726 milliseconds. A clean stop gave 369 to 482 milliseconds. The median is 1.4 to 1.9 per cent of a monthly 99.999 per cent budget of 26 seconds. |
| RTO, automatic (ACT-01) | The same prober with the detector and the actor deciding. | The result was 2.8 to 8.3 seconds. Detection is nearly all of it. |

`measure-recovery.sh` takes about 13 minutes, and it writes the [recovery report](../pg-replication/docs/recovery-report.md).

**The lesson:** A scripted promotion takes under a second. Detection dominates the real RTO.

---

## 6. Surviving crashes, load and network faults

### 6.1 Crash recovery is correct

- **Test:** `measure-recovery.sh --scenarios crash-matrix`.
- **Result:** When the standby was killed, there were no failed writes, and it caught up from its slot. When the writer was killed and restarted, no acknowledged write was lost and the indexes were undamaged, as `amcheck` confirmed. The outage was 3.4 to 3.5 seconds for 3 seconds of downtime. A kill inside an uncommitted 50,000-row transaction left no uncommitted rows. A kill during a checkpoint, confirmed in the log in 3 of 3 trials, lost nothing and damaged no index.
- **Limit:** A process crash is not a power cut. The host keeps its page cache, so the test does not show fsync behaviour.
- **Register:** CRS-01.

### 6.2 Concurrent load keeps money exact

- **Test:** `test-load.sh` runs 16 clients with idempotency keys drawn from a million values. It kills the writer 5 seconds in.
- **Result:** There were 287,791 transactions and none failed. The database rejected 37,721 duplicates. The balances minus the payments came to exactly 0, and the standby was identical, also after the writer kill.
- **Limit:** This is idempotency at database level. A client that retries through a failover belongs to Phase 3.
- **Register:** LOAD-01.

### 6.3 Network faults: delay, a cut link and silence

- **Test:** `test-network-faults.sh` puts Toxiproxy on the replication link.
- **Result:** Asynchronous commits are unaffected by 200 or 1,000 milliseconds of delay, but the standby is stale by about the delay. A synchronous commit rises by the round trip, which is about 400 milliseconds for 200 milliseconds each way. A cut link blocks synchronous commits until the standby retries. That took 4.8 seconds after healing with the default 5-second retry interval, and 0.3 seconds with a 500-millisecond interval. A silent link keeps its connection open but swallows the data. The writer notices only after `wal_sender_timeout`, which is 60 seconds by default and 4 seconds with 5-second timeouts.
- **Lesson:** Detection time is the largest part of an RTO. Shorter timeouts reduce it, but they raise the risk of false alarms.
- **Register:** NET-01 to NET-03.

### 6.4 More link faults: jitter, bandwidth, one-way silence and a dropping link

- **Test:** `test-link-faults.sh`.
- **Result for jitter:** The delay was 100 milliseconds, plus or minus 100. Asynchronous commits stayed at 80 to 84 milliseconds. The median synchronous commit rose from 79 to 87 milliseconds to 364 to 385 milliseconds, with a wide spread.
- **Result for a bandwidth limit:** At 512 KB per second, one 8 MB write left the standby 4 to 5 MB behind. A synchronous commit issued then waited 14.2 seconds behind the backlog.
- **Result for one-way silence:** The timeouts were 5 seconds. When the standby's replies were lost, the standby still had the data, but the writer dropped it after 4.0 seconds. When the writer's WAL was lost, the standby did not have the data, and the connection dropped after 4.7 seconds.
- **Result for a dropping link:** When the link dropped every connection after 256 KB, replication stalled completely. Each reconnect restarts at the start of the current WAL segment, and the standby's log shows the same start position every time.
- **Limit:** The Transmission Control Protocol (TCP) hides packet loss, so loss itself is not shown. Drops and silence are its effects. The byte budget at which replication finishes is not mapped.
- **Register:** NET-04 to NET-07.

### 6.5 A dead standby cannot fill the primary's disk

- **Test:** `test-slot-limit.sh` writes 1.5 GB of WAL and needs 6 GB of free disk.
- **Result:** The slot went from `reserved` to `lost` at about 1 GB. The primary's WAL peaked at 944 MB against a bound of 1,536 MB, and the primary accepted a write in every round. The restore cloned the standby again. The test found a defect: a standby that was cloned again kept an old slot that no longer protected the WAL. The rebuild now replaces that slot.
- **Register:** OPS-04.

---

## 7. Safe decisions and safe secrets

### 7.1 Decisions never read a lagging replica

- **Problem:** Two debits of 100 arrive for a balance of 100, and each is decided on a stale replica.
- **Test:** `test-replica-lag.sh`.
- **Result:** The wrong way approved both debits, and the account went to -100. The guarded path declined the second debit, and the account stayed at 0. A replica read after waiting for the replay position was correct.
- **Pattern:** [decisions read the writer](../pg-replication/docs/patterns/decisions-read-the-writer.md).
- **Limit:** The test proves the library guard and the anomaly. It does not prove that a future service obeys the rule.
- **Register:** DEC-01.

### 7.2 Rotating database secrets with no failed write

- **Problem:** The replication and superuser passwords must change across two nodes under live traffic.
- **Mechanism:** The replication secret rotates by overlap. A second role is created with alternating names, and then the old role is retired. The superuser secret changes in place. A rollback is possible before the files change. A re-run converges. A maintenance lock stops a rotation, a rebuild and a role change from overlapping.
- **Test:** `test-rotation.sh` in asynchronous mode and with `ROTATION_MODE=sync`, `test-maintenance-lock.sh`, and `test-hard-kill.sh --target rotate`.
- **Result:** No write failed in any run. All 25 kills of the rotation recovered on a re-run.
- **Guide:** [secrets rotation](../pg-replication/docs/secrets-rotation.md).
- **Register:** SEC-R1 to SEC-R4.

---

## 8. Backup and point-in-time recovery

Replication copies a mistake as faithfully as it copies data. Only a backup with the archived log can undo one.

### 8.1 A mistaken delete is undone from a base backup and the archive

- **Problem:** Every row is deleted by mistake on the primary, and the standby loses the rows within seconds.
- **Mechanism:** The primary archives completed WAL segments with `archive_command`. A base backup is taken with `pg_basebackup -X stream`. A copy is restored into a separate container, up to a recorded WAL position, which is a log sequence number (LSN) before the delete. The copy is then promoted at that point.
- **Test:** `test-point-in-time.sh` has 5 steps and a control.
- **Result:** The delete reached the standby within 2 seconds. The restore to the recorded LSN gave 150 rows and the checksum from before the delete. The control recovered to the end of the archive and gave 0 rows. The position is what makes the difference.
- **Limit:** The test covers one timeline. A failover between the backup and the recovery is not tested. The target is a position, not a time. The copy is separate, so it is not an in-place repair. The archive and the backup are volumes on the same host, with no off-site copy and no retention policy.
- **Register:** BAK-01.

---

## 9. Engineering practice that makes the proof trustworthy

- **Every claim can be run again.** The register's status says whether a result is automated, manual, partial or not proven. Nothing is claimed that has not been run.
- **Negative controls.** The tests that matter include a variant that must fail, for example with no guard, with the lock off, with the fence lifted, or with `commit=local`. A pass therefore means that the test could have seen the problem. Several controls found real defects. The [negative control pattern](../pg-replication/docs/patterns/negative-control.md) explains the method.
- **Defects that the tests found.** The tests found and fixed six defects in the early work. A split-brain guard was stuck. `pg_rewind` ran on a half-rewound node. A wedged standby was reported as a success. Connection lines piled up to 88. An invalid replication slot was reused after a rebuild. The epoch file had a race.
- **More defects from the Phase 1 work of November 2026.** A restore refused a double stop. A fence picked up every volume once a node had several. A hygiene check read a failed command as "no match".
- **House standards, checked by tools.** Shell scripts follow a deterministic Bash standard that `lint-scripts.sh` checks. Python follows its own standard, with ruff, mypy in strict mode and pytest in a pinned container, and no waivers. `run-all-checks.sh` runs lint, documents, Python, hygiene, timeline and the round trip.
- **An audit trail.** Every script writes a run log with millisecond timestamps in Coordinated Universal Time (UTC). `run-with-log-folder.sh --merge` merges a whole run into one timeline.
- **Hygiene and timeline checks.** `check-hygiene.sh` checks three rules. Host scripts make no direct `docker`, `psql` or `pgbench` calls. Every published port is on loopback. No tracked file holds a private key or an access token. `check-run-timeline.sh` checks that a merged timeline is ordered and well formed. Both checks run in `run-all-checks.sh`, and both were shown to fail on a bad copy.
- **Observability and engineering rows.** The register records the run logs, the merged timeline, the Bash standard and the document check as OBS-01 to OBS-03 and ENG-01 to ENG-04.
- **One place for each kind of call.** Database calls live in `lib/database.sh`, and most `docker` calls live in `lib/container.sh`. The libraries that serve one job run `docker` themselves. Those libraries are `fence.sh`, `lease.sh`, `backup.sh` and `access.sh`.

---

## 10. What this catalogue does not cover

These items are open or deliberately out of scope. The register's section 4 gives the detail.

- **Point-in-time recovery beyond one timeline.** A recovery across a failover, an off-site archive, a retention policy and recovery by time are not covered.
- **A quorum of synchronous standbys.** Every synchronous result is for one standby.
- **The write check on every table.** The check exists, but it is opt-in for each table. A clock step and a comparison of epochs between nodes are not tested (GAP-03).
- **A replicated controller.** This needs a consensus store (GAP-07).
- **Real packet loss and reordering.** These need `tc netem`. The byte budget at which a dropping link replicates is also not mapped (GAP-11).
- **The application layer.** This is Phase 2. It covers the outbox, idempotent consumers, per-aggregate sequences and an independent invariant checker (GAP-12).
- **The service layer.** This is Phase 3. It covers a client with idempotency keys that reconnects through a failover, recovery time under realistic load, and secret rotation for application clients (GAP-10, GAP-15 and SEC-06).
- **Hot-hot operation, multi-writer operation and the chaos catalogue.** These are Phases 4 to 6.
- **Power-loss testing, a real network, several machines and real secrets management.** This is a single-host teaching platform.
