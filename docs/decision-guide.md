# Decision guide

<!-- toc -->

- [1. Which replication mode](#1-which-replication-mode)
- [2. How long should the lease be](#2-how-long-should-the-lease-be)
- [3. Which timeouts](#3-which-timeouts)
- [4. Backup or replication](#4-backup-or-replication)
- [5. A standby that is down for a long time](#5-a-standby-that-is-down-for-a-long-time)
- [What this guide does not cover](#what-this-guide-does-not-cover)

<!-- tocstop -->

This guide turns the measurements into choices. It answers four questions. Which replication mode should I use? How long should the lease be? Which timeouts should I set? When is backup the answer and replication is not?

Every number comes from a run on one machine with two PostgreSQL 16 nodes. A real network, a larger database and a higher write rate will change them. Use the numbers to see which way each choice pushes, and measure your own system before you adopt a value. The register row after each statement holds the evidence and its limits.

## 1. Which replication mode

| Choose | When | You pay | Evidence |
|---|---|---|---|
| Asynchronous | A short outage of writes costs more than losing the last few acknowledged writes. | A crash of the writer loses what the standby had not received. About 6 writes for each second of lag at the test's write rate. | RPO-01. |
| Synchronous | Losing an acknowledged write is worse than blocking writes. | Commits block while the standby is down. Throughput fell to 47 per cent in the load test. A cut link blocked commits for about 10 seconds. | RPO-02, REP-05, LOAD-01 and NET-02. |

Four points help the choice.

- The two modes switch without a restart, so the choice is not permanent. See REP-06.
- Synchronous replication does not remove the window after a failover. The new writer has no standby until the old node rejoins, so there is one copy of each write for several seconds. See SYNC-01.
- Asynchronous loss is bounded by lag, so keep the lag small and watch it. A slow link raises the loss. See RPO-03.
- With one standby, synchronous replication makes the standby a single point of failure for writes. A quorum of several standbys is not tested.

## 2. How long should the lease be

The lease lets a writer take writes only while the controller keeps renewing it. A long lease tolerates a slow or restarting controller. A short lease cuts the time that an isolated writer can still accept writes.

| Setting | Effect | Evidence |
|---|---|---|
| Lease longer than the controller's restart time. | A controller restart costs nothing. Writes continued for 16 seconds with a 6-second lease and a restart after 2 seconds. | CTL-01. |
| Lease shorter than the controller's restart time. | The guard stops a healthy writer. | CTL-01. |
| The wait before promoting an isolated writer. | It must exceed the lease, so that the old writer has stopped. The measured gap between the old writer's last write and the new writer's first was 8.8 to 9.6 seconds. | LEASE-02. |
| The guard's polling interval. | It is 0.5 seconds, so a write can slip in just after expiry. The write check closes this for the tables that have it. | LEASE-01 and LEASE-04. |

The rule is that the lease must exceed the controller's restart time, and the promotion wait must exceed the lease. Run the controller under a supervisor. A lease is a trade of availability for safety, and an outage of the controller path is then an outage of the writer.

## 3. Which timeouts

Two timeouts decide how long a dead or silent standby goes unnoticed. They are the sender timeout on the writer and the receiver timeout on the standby.

| Setting | Effect | Evidence |
|---|---|---|
| The defaults, 60 seconds. | A silent link is noticed after 60.2 seconds. A synchronous commit blocks that long. | NET-03. |
| Both at 5 seconds. | A silent link is noticed after about 4 seconds. | NET-03 and NET-06. |
| Shorter than a slow but healthy link needs. | A false alarm drops a healthy standby. | NET-03. |
| The standby's retry interval at 500 milliseconds, against the default of 5 seconds. | Commits resume 0.3 seconds after a link returns, against 4.8 seconds. It means more connection attempts in a long outage. | NET-02. |

The detector has its own limit. Its witness window must exceed the writer's quietest gap. An idle writer talks to its standby about every 30 seconds, so a window of 5 seconds gave a false failover and a window of 35 seconds held. See DET-01. The alternative is a heartbeat from the writer.

The values of 5 seconds and 500 milliseconds are measured in this lab. They are not recommended defaults.

## 4. Backup or replication

| The problem | Use | Why | Evidence |
|---|---|---|---|
| A node or a disk is lost. | Replication. | The standby holds a current copy, and promotion takes under a second in the test. | RTO-01. |
| A bad delete, a bad migration or a wrong update. | Backup and point-in-time recovery. | Replication copies the mistake to the standby within 2 seconds. | BAK-01. |
| Both. | Both. | They cover different faults. Neither replaces the other. | BAK-01 and FOV-09. |

The backup in this repository is on the same host as the data. It has no off-site copy and no retention, so it shows the mechanism and not a full backup policy.

## 5. A standby that is down for a long time

A replication slot protects a standby that is briefly away. A standby that is away for long makes the log grow. The setting `max_slot_wal_keep_size` bounds the growth, and a standby that falls past the bound must be rebuilt from a clone. Choose the bound as the amount of log that you can afford to hold. See OPS-04.

Under synchronous replication a dead standby blocks writes, so the log growth is not the first problem. The writes are.

## What this guide does not cover

It does not cover a quorum of standbys, a router, an application service or a real network. See the [failure modes](failure-modes.md) for the faults that no test exercises.
