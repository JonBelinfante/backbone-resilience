# Failure modes

This page indexes the repository by fault. Each row names a fault, what it does, how the platform notices and handles it, the register row that holds the evidence, and the risk that remains. It lists only faults that a test in this repository exercises. The last section names the faults that no test covers.

The page is the first draft of a risk register. It does not give a likelihood or an owner for any risk. The [glossary](glossary.md) defines the terms, and the [capability register](../pg-replication/capability-register.md) holds the numbers and the limits. The few numbers here are quoted from the register, which stays the source.

## How to read a row

- **Handled by** is the mechanism that limits the damage. It may be a guard, a setting or a recovery script.
- **Evidence** is a register row. Open the row for the test, the number of runs and the limit.
- **Remaining risk** is what the mechanism does not cover.

## 1. A node stops or crashes

| Fault | Effect | Handled by | Evidence | Remaining risk |
|---|---|---|---|---|
| The standby stops while the writer is asynchronous. | None for clients. The slot keeps the log, and the standby catches up on restart. | The replication slot. | REP-04. | A standby that never returns fills the disk. See section 5. |
| The standby stops while the writer is synchronous. | Commits block until the standby returns. A commit that was waiting completes and keeps its row. | None. This is the price of an RPO of 0. | REP-05. | One standby only. A quorum of several is not tested. |
| The writer crashes under asynchronous replication. | The writes that the standby had not received are lost. About 6 writes for each second of lag at the test's rate. | None. The loss is measured and not prevented. | RPO-01. | Loss at natural lag on localhost was 0 in three trials. That shows rarity, not safety. |
| The writer crashes under synchronous replication. | No acknowledged write is lost. The outage is a little longer. | Synchronous commit. | RPO-02. | The control with commit level local shows the test can see a loss. Only the writer crashes in the test. |
| The writer is killed in a transaction or during a checkpoint. | No uncommitted row survives, and no index is damaged. | PostgreSQL crash recovery. | CRS-01. | A process crash is not a power cut. The test does not show fsync behaviour. |
| A script is killed part way through a failover, a fail-back or a rebuild. | The nodes are left in a mixed state. | The restore script and the rebuild-pending marker. | FOV-08. | The test kills scripts, not PostgreSQL. |

## 2. Two writers

| Fault | Effect | Handled by | Evidence | Remaining risk |
|---|---|---|---|---|
| A standby is promoted while the old writer still answers. | Two writers. | The promotion guard. | FOV-02. | It is a script check. A direct promotion call bypasses it. |
| A failed-over old primary is started again with a plain Docker start. | A second writer. | The start-time fence. | FOV-10. | The fence acts at the next start only. A running old writer keeps writing until it is stopped. |
| A restarted old primary finds the other node already writable. | A second writer. | The split-brain guard. | FOV-03. | It acts only for starts through the bring-up script. |
| The old writer is cut off but cannot be killed. | It keeps taking writes while a new writer is promoted. | The lease and the lease guard. | LEASE-01 and LEASE-02. | Safety costs availability. A controller outage longer than the lease stops a healthy writer. |
| A paused writer resumes after its lease has expired. | One write can slip in before the guard looks. | The write check on the table. | LEASE-04. | The check is opt-in for each table and uses the node's own clock (GAP-03). |
| Two actors decide at the same moment. | Both promote, and both write the same epoch file. | The maintenance lock. | ACT-03. | The lock works on one host only and has no time limit. |

## 3. The failover machinery fails

| Fault | Effect | Handled by | Evidence | Remaining risk |
|---|---|---|---|---|
| The writer pauses briefly or a link blips. | A false failover, if the detector acts on one view. | The two-view detector. | DET-01. | An idle writer talks to its standby about every 30 seconds, so the witness window must exceed that. |
| The controller cannot reach a live writer. | A false failover. | The detector returns "hold writer alive" when the standby still hears the writer. | DET-01. | The standby is a single witness. If it is cut off, the verdict is "cannot fail over". |
| The actor is killed part way through a failover. | A half-done failover. | The epoch and its pending marker. A re-run finishes the same failover. | ACT-02 and ACT-04. | A slow promotion call is not covered. |
| The controller is killed. | The lease is not renewed. | A supervisor must restart it within the lease time. | CTL-01. | A longer outage stops the writer. The controller is a single instance (GAP-07). |
| A failover from synchronous replication. | A window with one copy of every write. | The rejoin switches synchronous replication on again. | SYNC-01. | A loss of the new writer's disk inside the window loses acknowledged writes. |
| A second failure during a rejoin. | A node that is neither rewound nor cloned. | The rebuild-pending marker and the restore. | FOV-11. | The test kills at one point only. |

## 4. The network misbehaves

| Fault | Effect | Handled by | Evidence | Remaining risk |
|---|---|---|---|---|
| Delay on the replication link. | Replay lag grows. A synchronous commit gains the full round trip. | None. The cost is measured. | NET-01 and NET-04. | The delay is symmetric. |
| The link is cut. | Synchronous commits block until the standby retries. | A shorter retry interval. | NET-02. | A short interval means more connection attempts in a long outage. |
| The link is silent and the connection stays open. | The writer notices after 60 seconds by default. | Shorter timeouts, which reach about 4 seconds. | NET-03. | Short timeouts raise the risk of a false alarm on a slow link. |
| Replies are lost in one direction. | The standby has the data, and the writer cannot know. | Timeouts. | NET-06. | Under synchronous replication, commits block for data that the standby already holds. |
| Bandwidth is limited. | A backlog builds, and a synchronous commit waits behind it. | None. The cost is measured. | NET-05. | A commit is only as fast as the oldest unsent log. |
| The link drops after a small byte budget. | Replication stalls however often the standby reconnects. | None found. The heal restores it. | NET-07. | A budget above one segment is not understood (GAP-11). |

## 5. Data and operations

| Fault | Effect | Handled by | Evidence | Remaining risk |
|---|---|---|---|---|
| A dead standby fills the writer's disk. | The writer stops. | A bound on the slot, `max_slot_wal_keep_size`. The restore clones the standby. | OPS-04. | The test covers asynchronous mode. Under synchronous replication a dead standby blocks writes. |
| A mistake, such as a delete, is replicated. | The standby holds the same mistake. | Base backup and point-in-time recovery. | BAK-01. | One timeline only. There is no off-site copy and no retention. |
| A decision reads a lagging replica. | It approves what the writer would refuse. | The decision library refuses a replica. | DEC-01. | A future service may not obey the rule (GAP-12). |
| A database password is rotated. | A failed write, if the change is not overlapped. | Rotation by overlap, and in place for the superuser. | SEC-R1 and SEC-R3. | Application clients are not tested (SEC-06). |
| A concurrent load runs across modes. | Throughput drops under synchronous replication. | None. The cost is measured. | LOAD-01. | The load is generated by one tool. |

## Faults with no test

These faults are not exercised. Do not read their absence as safety.

- A power cut, which loses the host's page cache.
- Real packet loss and reordering (GAP-11).
- A second machine, a real network or a clock step between nodes (GAP-03).
- A failed controller host, and a replicated controller (GAP-07).
- A client that holds a stale credential after rotation (SEC-06).
- A failover between a base backup and its recovery.
- A disk that fills on the standby, or a corrupt heap page.
- A quorum of several standbys.
- Any fault in an application service, an outbox or a consumer (GAP-12).
