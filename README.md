# Resilience: evidence for how a database platform survives failure

This repository is a hands-on library. It shows, with repeatable tests and measured numbers, how a pair of PostgreSQL databases stays available. It also measures when acknowledged data is lost and when it is not, as nodes, networks and the failover machinery itself fail.

It is **not an application**. It is a working laboratory. Each mechanism that a resilient database platform needs is built, broken on purpose and measured. Those mechanisms are replication, failover, fencing, failure detection, lease-based write protection, crash recovery, backup and secret rotation. Each one comes with a test that you can run, a control that proves the test can see the fault, and a plain statement of its limits.

## Why it is useful

Most material on high availability describes designs. This repository shows the **cost and the evidence**.

- **What each guarantee costs.** Synchronous replication loses nothing, but it blocks writes while the standby is unreachable. It also halved throughput in our load test. Asynchronous replication loses about six writes for every second of lag.
- **Where detection time goes.** A promotion takes under a second. Noticing the failure takes between 2 and 60 seconds. That delay, not the promotion, sets the real downtime.
- **Where the dangerous gaps are.** A failed-over node that is restarted by hand becomes a second writer. An idle writer can fool a failure detector. A controller that renews a lease turns its own outage into a writer outage. Each gap is reproduced, and then it is closed or stated as a trade-off.
- **A way of proving things.** The tests use negative controls and kill tests at many points. Every result is recorded in a register.

The repository also supplies evidence that a Target Operating Model for a payments-style platform can use. It holds measured failure behaviour and chaos-test results for the database layer. The risk register and the consistency tiers are not written yet. The [documentation plan](docs/documentation-plan.md) starts them with a failure-mode index.

## Who it is for

The library is for platform engineers, database engineers, site reliability engineers and architects. They need to design, review or teach resilient database platforms. It also suits anyone who wants a worked example of turning an availability claim into a test.

## What you get

| You get | Where |
|---|---|
| A **capability catalogue**: each resilience problem, its mechanism, its test, the measured result and the limit. | [docs/capability-catalogue.md](docs/capability-catalogue.md) |
| A **capability register**: every capability, each with a status, a result and a limit, plus the open gaps. | [pg-replication/capability-register.md](pg-replication/capability-register.md) |
| An **evidence log**: the commands, numbers and defects found in each run of experiments. | [pg-replication/evidence-log.md](pg-replication/evidence-log.md) |
| **Runnable tests and experiments**: the test scripts and a measurement runner, each restoring the starting state. | [pg-replication/](pg-replication/README.md) |
| **Recovery point and recovery time measurements**, with a report. | [pg-replication/docs/recovery-report.md](pg-replication/docs/recovery-report.md) |
| **Robustness patterns** and diagrams. | [pg-replication/docs/patterns/](pg-replication/docs/patterns/README.md) |
| A **secret rotation guide** with no failed writes. | [pg-replication/docs/secrets-rotation.md](pg-replication/docs/secrets-rotation.md) |
| Two small **Python services**: a failover controller and a lease guard. | [services/](services/) |
| Two **house standards** that the code is checked against: one for Bash and one for Python. | [docs/python-standard.md](docs/python-standard.md) and `pg-replication/scripts/lint-scripts.sh` |

## What was measured

All measurements come from one laptop running Docker Compose, PostgreSQL 16 and two nodes. They show behaviour and relative cost. They are not production figures.

Two terms recur below. The recovery point objective (RPO) is the amount of acknowledged data that may be lost. The recovery time objective (RTO) is the time that clients may be unable to write. The evidence column gives identifiers, such as RPO-01, that appear in the capability register.

| Question | Answer | Evidence |
|---|---|---|
| How much data is lost when the writer crashes under asynchronous replication? | About 6 writes for each second of replication lag. | RPO-01 |
| How much is lost under synchronous replication? | None. A control showed that the test can see a loss. | RPO-02 |
| What does zero loss cost? | Writes block while the standby is cut off. Throughput halves under 16 clients. | RPO-02, LOAD-01 |
| How long does a scripted promotion take? | Between 0.3 and 0.7 seconds. | RTO-01 |
| How long does an automatic detector add? | The downtime is 2.8 seconds for a crash and 8.3 seconds for a hung writer. | ACT-01 |
| How long does a silent network link go unnoticed? | 60 seconds by default, or 4 seconds with tuned timeouts. | NET-03 |
| How long are there two writers when the old writer is partitioned and cannot be killed? | 14 to 16 seconds without the lease guard, and none with it. | LEASE-02 |
| How long is safety reduced after a failover from synchronous replication? | 8.0 seconds. The rejoin of the old node closes the window. | SYNC-01 |
| What happens when a paused writer resumes after its lease has run out? | Without a write check it accepted a write 3.1 seconds late. With the check it refused the write. | LEASE-04 |
| What does jitter do to a synchronous commit? | The median rises from about 80 to about 370 milliseconds, with a wide spread. | NET-04 |
| What happens when a link drops every connection after 256 KB? | Replication stalls completely, because each reconnect restarts at the segment start. | NET-07 |
| How many writes fail while the database passwords are rotated? | None. | SEC-R3 |
| How many acknowledged writes are lost to a crash, a mid-transaction kill or a checkpoint kill? | None. | CRS-01 |
| How much data returns after a mistaken delete that replicated? | All 150 rows, with the same checksum, when the restore stops before the delete. None when it runs to the end of the archive. | BAK-01 |
| How many acknowledged rows survive when the new writer dies during a rejoin? | All 8, identical on both nodes. | FOV-11 |

## Run it

You need Docker with Compose and **Bash 5.0 or later**. macOS ships version 3.2, so run `brew install bash` first.

```bash
cd pg-replication
docker compose up -d                       # primary on :5433, standby on :5434 (127.0.0.1 only)
bash scripts/verify-replication.sh         # write on the primary, read on the standby
bash scripts/run-all-checks.sh             # lint, documents, Python checks, then the 17-step failover and fail-back
bash scripts/test-auto-failover.sh         # a controller detects, fences and promotes; the client's downtime is timed
```

The Bash standard checker is a private plugin. `run-all-checks.sh` reports the lint as SKIP when `BASHCHECK_WRAPPER` is not set, and it still runs every other check. The skip is stated in the last line, so a skipped lint never reads as a full pass. See [pg-replication/README.md](pg-replication/README.md) for the value. Every script accepts `--help`, except two log scripts that need `RUN_LOG_DIR` to be set. That README explains the limit.

The credentials are throwaway values and the ports are bound to loopback. Do not expose them, and never put real secrets in this repository.

## How to read it

1. Start with the [capability catalogue](docs/capability-catalogue.md). It is the map, grouped by problem.
2. Run the test that an entry names, and read its narrated output.
3. Read the [capability register](pg-replication/capability-register.md) for the status, result and limit of every capability, and for the open gaps.
4. Read the [patterns](pg-replication/docs/patterns/README.md) and the [diagrams](pg-replication/docs/diagrams/failover-sequence.md) to see why the scripts are shaped as they are.

## Repository map

```
README.md                  this file
LICENSE                    MIT licence
docs/                      capability catalogue, the Python standard, proposals to the Bash standard
pg-replication/            the PostgreSQL pair: compose file, scripts, libraries, tests, register, patterns
services/                  Python services: failover_controller (detector), fence_guard (lease guard)
python-standard/           pinned tools image and test fixtures for the Python checks
CLAUDE.md                  working notes for the coding assistant used on this project
```

## Roadmap and status

| Phase | Scope | State |
|---|---|---|
| 1 | The PostgreSQL pair: replication, failover and fail-back, recovery measurements, crash and network faults, secret rotation, guards, a second failure during a rejoin, and backup with point-in-time recovery. | Complete. Every item is automated. |
| 2 | Failover safety (detector, fencing epoch, actor and leases) and the application layer (outbox, idempotent consumers and an invariant checker). | Failover safety is built, proven and documented as patterns. The application layer is not started. |
| 3 | The service layer: a load generator, clients that retry through a failover, recovery time under load, and rotation for application clients. | Not started. |
| 4 | Hot-hot operation with partitioned ownership. | Not started. |
| 5 | Multi-writer operation for commutative ledger entries, showing where it breaks. | Not started. |
| 6 | A chaos experiment catalogue mapped to a risk register, with service level indicator and error-budget reporting. | Not started. |

## Licence

The licence is MIT. See [LICENSE](LICENSE). You may use, copy, modify and share the code and the documents. The database credentials in the compose file are throwaway values for local experiments only.

## Honest limits

- The work runs on a single machine and a single Docker host. There is no real network, no second site and no power-loss test.
- Point-in-time recovery covers one timeline. The archive sits on the primary with no off-site copy. Recovery is by position, not by time.
- Every synchronous result is for one standby. A quorum of several standbys is not tested.
- There is one controller and one actor, with a lock that works on one host only. Replicating them needs a consensus store.
- The tests write through `psql` and `pgbench`. There is no payments service yet. End-to-end consistency, meaning no lost or duplicated payment, is therefore **not** shown. That belongs to Phases 2 and 3.
- Each number comes from a few trials. The numbers show how a mechanism behaves. They do not give statistical confidence.

Section 4 of the register lists the open gaps.
