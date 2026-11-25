# Capability catalogue: how to build a resilient database platform

This is the learning guide to the repository. Each entry names a **problem** a database platform meets when something
fails, the **mechanism** that answers it, the **test** you can run to see it work, the **result** we measured, and the
**limit** of the evidence. Every claim here is backed by a row in the
[capability register](../pg-replication/capability-register.md), which holds the status and limits; the commands and numbers of each run are in the [evidence log](../pg-replication/evidence-log.md).

All measurements come from one laptop (Docker Compose, PostgreSQL 16, two nodes on one host). They show how each
mechanism behaves and what it costs. They are not production figures: a real network, disk and fleet will differ.
Where the test includes a **control** (a variant that must fail, to prove the test can see the problem), it says so.

Every test runs from the `pg-replication/scripts/` folder as `bash scripts/NAME.sh` (see the [README](../README.md#run-it)).
Each test restores the starting state afterwards, so you can run them in any order.

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
- **Problem:** a second copy of the data must exist, be current, and be rebuildable without hand work.
- **Mechanism:** streaming replication of the write-ahead log (WAL) with a replication slot that keeps the WAL the standby
  still needs. The standby clones the primary on first start (`pg_basebackup`) and then follows it read-only.
- **Test:** `verify-replication.sh`, and the first step of every other test.
- **Result:** a committed write appears on the standby; schema changes replicate; the standby refuses writes; a standby that was
  down catches up from its slot (about 1 s for a small write).
- **Limit:** one standby, same host.
- **Register:** REP-01 to REP-04, OPS-03, FOV-05.

### 1.2 Asynchronous or synchronous, switched without a restart
- **Problem:** you need to choose between speed (async) and zero loss (sync), and change your mind while running.
- **Mechanism:** `set-replication-mode.sh --mode async|sync|status` changes `synchronous_standby_names` with a reload.
- **Result:** with the standby up a synchronous commit took 60 ms; with the standby stopped the commit **blocked** (8.6 s) until it
  returned. That block is the price of zero loss. Under 16 concurrent clients, sync gave about **half the throughput** of async
  (8,957 against 19,193 transactions per second, 1.79 ms against 0.83 ms latency).
- **Register:** REP-05, REP-06, LOAD-01.

### 1.3 A rebuilt standby does not inherit the writer's settings
- **Problem:** a promoted standby that still names a synchronous standby blocks every write; a rebuilt node that keeps old
  connection settings keeps an old password.
- **Mechanism:** the rebuild replaces `primary_conninfo` and drops `synchronous_standby_names` in a new file moved into place.
  Each node must hold at most one connection line.
- **Result:** a defect found by test (88 stale lines had piled up), fixed, and checked after every recovery.
- **Register:** REP-07, SEC-R2.

---

### 1.4 The modes, with the standby down and killed
- **Problem:** a standby that is stopped or killed must not cost the writer more than the mode promised.
- **Test:** `test-replication-modes.sh`: the mode is switched with no restart; asynchronous with the standby stopped; synchronous with it stopped; synchronous with it SIGKILLed during a commit.
- **Result:** asynchronous commits took **58 ms** with the standby down, and the replication slot kept the WAL for it. A synchronous commit waited with the standby down (still waiting after 5 s) and completed **7.4 s** later when it returned. Killed mid-commit, the commit waited and completed after the restart, and the standby held all 3 acknowledged rows.
- **Register:** REP-04, REP-05, REP-06.

## 2. Moving the writer safely

### 2.1 Manual failover and fail-back
- **Problem:** the writer is gone; make the standby the writer, then bring the old one back as a standby.
- **Mechanism:** `promote-standby-to-primary.sh` promotes; `promote-primary-to-standby.sh` rebuilds the old primary
  (`pg_rewind`, slot, standby settings) behind the new writer.
- **Test:** `test-failover-roundtrip.sh`, a 17-step failover and fail-back that narrates every SQL statement and its result.
- **Result:** roles swap and swap back; both nodes end with identical data.
- **Register:** FOV-01, FOV-04, FOV-06; sequence in [docs/diagrams](../pg-replication/docs/diagrams/failover-sequence.md).

### 2.2 Guard rails around the role change
- **Problem:** promoting while the old primary still answers, or restarting the old primary after a failover, creates two writers.
- **Mechanism:** a promotion guard (refuses while the old primary is reachable) and a split-brain guard (stops a restarted old
  primary when the other node is already writable).
- **Result:** the promotion exits 1 with "split-brain"; the restarted old primary is stopped again.
- **Result (automated):** `test-guards.sh`. With the primary answering, the promotion was refused and the standby stayed a replica. A restarted old primary was stopped again by the start script, once its fence was lifted (promotion fences it first, see 3.1).
- **Limit:** script checks, not real fencing; see section 3 for the fence.
- **Patterns:** [promotion guard](../pg-replication/docs/patterns/promotion-guard.md), [split-brain guard](../pg-replication/docs/patterns/split-brain-guard.md), [verify after act](../pg-replication/docs/patterns/verify-after-act.md).
- **Register:** FOV-02, FOV-03.

### 2.3 A true divergence is rewound, and the loss is counted
- **Problem:** the old primary accepted writes the new writer never saw. Taking it back must undo them.
- **Test:** `test-divergence-rewind.sh`. The old primary acknowledges 3 writes the standby never gets; the standby is promoted
  anyway; `pg_rewind` reports "servers diverged" and does a real rewind.
- **Result:** the old primary rejoins identical to the new writer. The 3 acknowledged writes are **lost**: observed asynchronous data loss.
- **Register:** FOV-09.

### 2.4 Return to the starting state from anywhere, even after a kill
- **Problem:** a failover script dies half way; the platform must recover by itself.
- **Mechanism:** `restore-starting-state.sh` reads the current roles and repairs; a rebuild-pending marker makes a half-rewound
  node be re-cloned, never trusted.
- **Test:** `test-hard-kill.sh` SIGKILLs the round trip, the restore and the rotation at set delays.
- **Result:** 16 kills of the round trip and 10 of the restore all recovered. It found four real faults (a stuck split-brain
  guard, `pg_rewind` on a half-rewound directory, status queries during shutdown, a wedged standby reported as success), all fixed.
- **Pattern:** [kill-test harness](../pg-replication/docs/patterns/kill-test-harness.md).
- **Register:** FOV-07, FOV-08, OPS-01.

---

### 2.5 A second failure during a rejoin
- **Problem:** the writer dies while the old node is being rebuilt as a standby. Both nodes are down, and one of them has a half-changed data directory.
- **Test:** `test-rejoin-failure.sh`: the new writer is killed once the rebuild marker appears; the restore must bring the stack back with every acknowledged row on both nodes. A `--control` run has no kill and shows the marker is what the kill leaves behind.
- **Result:** the restore first refused, with both nodes stopped. It now starts the writer candidate (the node without the replica marker, else the newer timeline read from the stopped volume), then restores from there. After the fix, **8 of 8 acknowledged rows** were on both nodes, with equal checksums.
- **Register:** FOV-11.

## 3. Fencing: never two writers

### 3.1 Start-time fence
- **Problem:** the old primary is started again with a plain `docker start`, bypassing every script.
- **Mechanism:** the old node's data directory gets `standby.signal`, so any start comes up read-only.
- **Test:** `test-fencing.sh`.
- **Result:** the fenced node came up in recovery and **refused a write**. Control (fence lifted): it came up writable and
  **accepted** the write, the split-brain the test must be able to see.
- **Limit:** fences at the next start only; a node that keeps running is handled by the lease (3.2).
- **Pattern:** [split-brain guard](../pg-replication/docs/patterns/split-brain-guard.md).
- **Register:** FOV-10.

### 3.2 A lease and a guard stop a running writer
- **Problem:** the old writer is partitioned but still running, and cannot be killed.
- **Mechanism:** the controller renews a lease row on the writer (`fence_lease`, using the writer's own clock). A guard beside the
  writer stops it when the lease expires.
- **Test:** `test-lease-fence.sh`, then `test-lease-failover.sh`.
- **Result:** cut off, the writer's last write was accepted 5.3 s after the cut and the first was refused at 5.6 s. In a
  failover of an isolated writer there was a gap of **8.8 to 9.6 s and no overlap** between old and new writer. Control (no
  guard): the old writer kept writing and there were **14 to 16 s of two writers**.
- **Limit and cost:** safety is bought with availability. A controller outage longer than the lease time stops a healthy writer. A
  paused process that resumes can write once before its guard looks; the write check (3.3) closes that for the tables that carry it.
- **Pattern:** [lease and guard](../pg-replication/docs/patterns/lease-and-guard.md), [epoch](../pg-replication/docs/patterns/epoch-fencing-token.md).
- **Register:** LEASE-01, LEASE-02.

### 3.3 The write itself checks the lease
- **Problem:** a writer that is paused (a long pause, a frozen host) while its lease runs out can resume and write once before its guard
  looks, because the guard polls from outside.
- **Mechanism:** a trigger on the table reads the lease inside every write and refuses it if the lease has expired.
- **Test:** `test-resume-fence.sh`: the writer is frozen for 8 s with a 5 s lease and a client write waiting.
- **Result:** with no check the write was **accepted 3.1 s after the lease ran out**; with the check it was refused with "fenced" and nothing was
  written. A write under a valid lease, and a write on a node with no lease, were accepted.
- **Limit:** opt-in per table, the node's own clock, lease time rather than a comparison of epochs.
- **Pattern:** [lease and guard](../pg-replication/docs/patterns/lease-and-guard.md).
- **Register:** LEASE-04.

### 3.4 The lease follows the writer
- **Problem:** after a failover the new writer must be fenced too, or it is unprotected.
- **Mechanism:** the actor installs a lease at the new epoch, starts a guard beside the new writer, and repoints the controller.
- **Test:** `test-lease-handover.sh`, including a kill part way through the hand-over.
- **Result:** the new writer's lease was at epoch 1 and renewed over 9 s; with renewals stopped it was fenced within 5.8 s; a kill
  during the hand-over was repaired by a re-run.
- **Register:** LEASE-03.

### 3.5 The fail-back works the same way
- **Test:** `test-lease-failback.sh`: fail over an isolated writer, rebuild the old node as a standby, then fail back.
- **Result:** the epoch went to 2, the node that was first the writer held a lease at epoch 2 and kept it renewed, and the isolated writer was stopped. Two runs.
- **Register:** LEASE-05.

---

## 4. Automatic failover

### 4.1 A failure detector that is not fooled by a pause
- **Problem:** promoting a healthy writer because the observer, not the writer, has a problem.
- **Mechanism:** two vantage points. A controller probes the writer; the standby reports whether the writer still feeds it.
  `fail-over` needs three failed probes in a row **and** a silent standby. Verdicts include `hold-writer-alive` (controller cut
  off, standby still hears the writer) and `cannot-fail-over` (both views unavailable).
- **Test:** `test-detector.sh` (7 steps) and 8 unit tests of the pure decision function.
- **Result:** a 3 s freeze produced no failover; a hung writer was declared after 6.4 s; a controller cut off from a live writer
  never failed over. **Control (the trap):** with an idle writer and a short witness window the same cut caused a **false failover**.
  An idle writer talks to its standby only about every 30 s, so a witness window shorter than that fools the detector.
- **Pattern:** [witness detector](../pg-replication/docs/patterns/witness-detector.md).
- **Register:** DET-01.

### 4.2 An actor that fences, promotes and records an epoch
- **Problem:** turn the decision into a safe promotion, and make it survive its own failure.
- **Mechanism:** `act-on-failover.sh` does three steps in order: raise the epoch (a number that only goes up), stop the old
  writer, promote. A step already done is skipped, so a re-run finishes the same failover at the same epoch.
- **Test:** `test-auto-failover.sh`; `test-actor-kill.sh` kills it after each step; `test-actor-timed-kill.sh` SIGKILLs its whole
  process group at 0.1 to 0.9 s.
- **Result:** a client could write again **2.8 to 2.9 s** after a crash (8.0 s once) and **7.2 to 8.3 s** after a hung writer; a
  2 s freeze did nothing. Every kill, including seven that landed inside the promote script, recovered to one epoch and a
  writable standby.
- **Pattern:** [restartable actor](../pg-replication/docs/patterns/restartable-actor.md), [epoch](../pg-replication/docs/patterns/epoch-fencing-token.md).
- **Register:** ACT-01, ACT-02, ACT-04.

### 4.3 Only one actor acts
- **Problem:** two actors decide at once and both promote.
- **Mechanism:** a maintenance lock (a host-local folder lock with dead-holder takeover).
- **Test:** `test-two-actors.sh`. **Control** with the lock off: both went ahead, and the control found a real race on the epoch file.
- **Limit:** one host. A distributed lock needs a consensus store, which is out of scope.
- **Register:** ACT-03.

### 4.4 The controller can die
- **Problem:** the controller is on the write path through the lease.
- **Test:** `test-controller-kill.sh`.
- **Result:** restarted within the lease time, nothing was refused and no failover was decided; left dead, the writer was stopped in
  about 5.3 s. This is a **deliberate trade-off**: run the controller under a supervisor and set the lease time longer than its restart time.
- **Register:** CTL-01.

### 4.5 The window after failing over from synchronous replication
- **Problem:** after a failover the new writer has no standby, so it runs asynchronously until sync is on again.
- **Test:** `test-sync-after-failover.sh`.
- **Mechanism:** the wanted mode is recorded when it is set; once the old node has rejoined and streams, the rejoin switches sync on for the new writer.
- **Result:** the new writer acknowledged a write with one copy; the rejoin closed the window with no manual step after **8.0 s** from the crash.
- **Limit:** the window is as long as the rejoin takes (a crashed node is re-cloned). The actor cannot switch sync on itself, because sync with no standby blocks every write.
- **Register:** SYNC-01.

---

## 5. Measuring loss and downtime

Definitions: **RPO** is acknowledged writes missing on the surviving site; **RTO** is the time until a client write succeeds again.

| Measurement | Method | Result |
|---|---|---|
| **RPO, async** (RPO-01) | Isolate the standby for a set lag, crash the writer, promote at once, compare a write ledger | Lag 0 s lost 0; lag 1 s lost 6; lag 3 s lost 17 to 18: about **6 writes per second of lag**, the write rate |
| **RPO, sync** (RPO-02) | The same, with synchronous replication | **0 lost** in every trial. **Control** (commit level `local`): 17 lost, so the test can see loss. Price: writes blocked 3.4 to 3.7 s while the standby was cut off |
| **RPO under gradual delay** (RPO-03) | Toxiproxy latency on the replication link | Loss tracks delay, not just all-or-nothing partitions |
| **RTO, scripted** (RTO-01) | Prober writes about every 100 ms through a clean stop or a crash | **312 to 726 ms** crash, **369 to 482 ms** clean stop, median 1.4 to 1.9% of a monthly 99.999% budget (26 s) |
| **RTO, automatic** (ACT-01) | Same prober with the detector and actor deciding | **2.8 to 8.3 s**; detection is nearly all of it |

Run `measure-recovery.sh` (about 13 minutes); it writes [recovery-report.md](../pg-replication/docs/recovery-report.md).
**The lesson:** a scripted promotion is under a second, and detection dominates the real RTO.

---

## 6. Surviving crashes, load and network faults

### 6.1 Crash recovery is correct
- **Test:** `measure-recovery.sh --scenarios crash-matrix`.
- **Result:** standby killed: 0 failed writes, caught up from its slot. Writer killed and restarted: 0 acknowledged writes lost,
  0 index damage (`amcheck`), outage 3.4 to 3.5 s for 3 s down. Killed in an uncommitted 50,000-row transaction: 0 uncommitted rows
  survived. Killed during a checkpoint (confirmed in the log in 3 of 3 trials): 0 lost, 0 index damage.
- **Limit:** a process crash, not a power cut: the host keeps its page cache, so fsync behaviour is not tested.
- **Register:** CRS-01.

### 6.2 Concurrent load keeps money exact
- **Test:** `test-load.sh`: 16 clients, idempotency keys from a million values, a crash 5 s in.
- **Result:** 287,791 transactions, 0 failed, 37,721 duplicates rejected, **balances minus payments exactly 0**, standby identical, also after a writer kill.
- **Limit:** database-level idempotency. A client that retries through a failover belongs to the service layer (Phase 3).
- **Register:** LOAD-01.

### 6.3 Network faults: delay, a cut link and silence
- **Test:** `test-network-faults.sh` (Toxiproxy on the replication link).
- **Result:** async commits are unaffected by 200 or 1,000 ms of delay, but the standby is stale by about the delay; a sync commit
  rises by the round trip (about 400 ms for 200 ms each way). A cut link blocks sync commits until the standby retries: 4.8 s after
  healing at the default 5 s retry interval, 0.3 s at 500 ms. **A silent link (connection open, data swallowed) is noticed only
  after `wal_sender_timeout`: 60 s by default, 4 s with 5 s timeouts.**
- **Lesson:** detection time, not promotion time, is the largest part of an RTO. Short timeouts shorten it but raise the risk of false alarms.
- **Register:** NET-01 to NET-03.

### 6.4 More link faults: jitter, bandwidth, one-way silence and a dropping link
- **Test:** `test-link-faults.sh`.
- **Result:**
  - **Jitter** (100 ms plus or minus 100): asynchronous commits unaffected (80 to 84 ms); synchronous commits rose from a median of 79 to 87 ms to **364 to 385 ms**, with a wide spread.
  - **Bandwidth limit** (512 KB/s): one 8 MB write left the standby 4 to 5 MB behind; a synchronous commit issued then waited **14.2 s** behind the backlog.
  - **One-way silence** (5 s timeouts): with the standby's replies lost, the standby **still had the data** while the writer dropped it after 4.0 s; with the writer's WAL lost, the standby did not have it and the connection dropped after 4.7 s.
  - **A link that drops every connection after 256 KB:** replication **stalls completely**, because each reconnect restarts at the start of the current WAL segment (the standby's log shows the same start position every time).
- **Limit:** TCP hides packet loss, so loss itself is not shown (drops and silence are its effects); the byte budget at which replication finishes is not mapped.
- **Register:** NET-04 to NET-07.

### 6.5 A dead standby cannot fill the primary's disk
- **Test:** `test-slot-limit.sh` (writes 1.5 GB of WAL; needs 6 GB free).
- **Result:** the slot went `reserved` to `lost` at about 1 GB; the primary's WAL peaked at 944 MB against a bound of 1,536 MB and
  accepted a write every round; restore re-cloned the standby. **Defect found by the test:** a re-cloned standby kept an old slot that no
  longer protected WAL; the rebuild now replaces it.
- **Register:** OPS-04.

---

## 7. Safe decisions and safe secrets

### 7.1 Decisions never read a lagging replica
- **Problem:** two debits of 100 on a balance of 100, each decided on a stale replica.
- **Test:** `test-replica-lag.sh`.
- **Result:** the wrong way approved both and the account went to **-100**; the guarded path declined the second and stayed at 0.
  A replica read after waiting for the replay position was correct.
- **Pattern:** [decisions read the writer](../pg-replication/docs/patterns/decisions-read-the-writer.md).
- **Limit:** proves the library guard and the anomaly, not that a future service obeys the rule.
- **Register:** DEC-01.

### 7.2 Rotating database secrets with no failed write
- **Problem:** change the replication and superuser passwords across two nodes under live traffic.
- **Mechanism:** replication secret by **overlap** (a second role, alternating names, then retire the old one); superuser in
  place; rollback before the files change; converges when re-run; a maintenance lock stops rotation, rebuild and role change overlapping.
- **Test:** `test-rotation.sh` (async and `ROTATION_MODE=sync`), `test-maintenance-lock.sh`, `test-hard-kill.sh --target rotate`.
- **Result:** **0 failed writes** in every run; 25 SIGKILLs of the rotation all recovered on re-run.
- **Guide:** [secrets rotation](../pg-replication/docs/secrets-rotation.md).
- **Register:** SEC-R1 to SEC-R4.

---

## 8. Backup and point-in-time recovery

Replication copies a mistake as faithfully as it copies data. Only a backup with the archived log can undo one.

### 8.1 A mistaken delete is undone from a base backup and the archive
- **Problem:** every row is deleted by mistake on the primary. The standby loses them within seconds.
- **Mechanism:** the primary archives completed WAL segments (`archive_command`). A base backup is taken with `pg_basebackup -X stream`. A copy is restored into a separate container, to a recorded WAL position (LSN) before the delete, and promoted there.
- **Test:** `test-point-in-time.sh` (5 steps, with a control).
- **Result:** the delete reached the standby within 2 s. The restore to the recorded LSN gave **150 rows and the checksum from before the delete**. The control, recovery to the end of the archive, gave **0 rows**: the position is what makes the difference.
- **Limit:** one timeline (a failover between the backup and the recovery is not tested); a target by position, not time; a separate copy, not an in-place repair; the archive and the backup are volumes on the same host, with no off-site copy and no retention policy.
- **Register:** BAK-01.

## 9. Engineering practice that makes the proof trustworthy

- **Every claim is re-runnable.** The register's status says Proven (auto), Proven (manual), Partial or Not proven. Nothing is
  claimed that has not been run.
- **Negative controls** ([pattern](../pg-replication/docs/patterns/negative-control.md)). The tests that matter include a variant that must fail (no guard, lock off, fence lifted, `commit=local`),
  so a pass means the test could have seen the problem. Several controls found real defects.
- **Evidence-led defects.** Tests found and fixed: a stuck split-brain guard, `pg_rewind` on a half-rewound node, a wedged
  standby reported as success, 88 piled-up connection lines, an invalid replication slot reused after a rebuild, a race on the epoch file.
- **House standards, checked by tools.** Shell scripts follow a deterministic Bash standard (`lint-scripts.sh`); Python follows its
  own (ruff, mypy strict, pytest in a pinned container, no waivers). `run-all-checks.sh` runs lint, documents, Python and the round trip.
- **An audit trail.** Every script writes a millisecond UTC run log; `run-with-log-folder.sh --merge` merges a whole run into one timeline.
- **Hygiene and timeline checks.** `check-hygiene.sh` checks that host scripts make no direct `docker`, `psql` or `pgbench` calls, that every published port is on loopback, and that no tracked file holds a private key or token. `check-run-timeline.sh` checks that a merged run timeline is ordered and well formed. Both run in `run-all-checks.sh`, and both were shown to fail on a bad copy (ENG-02, ENG-03, OBS-02).
- **Each test that found a defect says so.** Found this session: a restore that refused a double stop, a fence that picked up every volume once a node had several, and a hygiene check that read a failed command as "no match".
- **One place for each kind of call.** Database calls live in `lib/database.sh`, and most `docker` calls in `lib/container.sh`. The libraries for a job (`fence.sh`, `lease.sh`, `backup.sh`, `access.sh`) run `docker` themselves, as CLAUDE.md records.

---

## 10. What this catalogue does not cover

Open and deliberately out of scope for now (details in the register, section 4):

- **Point-in-time recovery across a failover, an off-site archive, a retention policy, and recovery by time** (BAK-01 limits).
- **More than one standby** (a quorum of synchronous standbys) (P1-08, not tested).

- **The write check on every table, a clock step, and a comparison of epochs between nodes** (GAP-03). The check exists (3.3) but is opt-in per table.
- **A replicated controller** (needs a consensus store) (GAP-07).
- **Real packet loss and reordering** (needs `tc netem`), and the byte budget at which a dropping link replicates (GAP-11).
- **The application layer** (Phase 2): outbox, idempotent consumers, per-aggregate sequences, an independent invariant checker (GAP-12).
- **The service layer** (Phase 3): a client with idempotency keys that reconnects through a failover, RTO under realistic load, rotation
  for application clients (GAP-10, GAP-15, SEC-06).
- **Hot-hot, multi-writer and the chaos catalogue** (Phases 4 to 6).
- **Power-loss testing, a real network, several machines, real secrets management.** This is a single-host teaching platform.
