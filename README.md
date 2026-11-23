# Resilience: evidence for how a database platform survives failure

A hands-on library that shows, with repeatable tests and measured numbers, how a pair of PostgreSQL databases stays
available and loses no acknowledged data when nodes, networks and the failover machinery itself fail.

It is **not an application**. It is a working laboratory: every mechanism a resilient database platform needs (replication,
failover, fencing, failure detection, lease-based write protection, crash recovery, secret rotation) is built, broken on
purpose, and measured. Each one comes with a test you can run, a control that proves the test can see the fault, and an honest note of its limits.

## Why it is useful

Most material on high availability describes designs. This repository shows the **cost and the evidence**:

- **What each guarantee costs.** Synchronous replication loses nothing but blocks writes while the standby is unreachable and
  halves throughput in our load test; asynchronous loses about six writes for every second of lag.
- **Where detection time goes.** A promotion takes under a second; noticing the failure takes 2 to 60 seconds, and that, not the
  promotion, sets the real downtime.
- **Where the dangerous gaps are.** A failed-over node restarted by hand becomes a second writer; an idle writer fools a failure
  detector; a controller that renews a lease turns its own outage into a writer outage. Each is reproduced, then closed or stated as a trade-off.
- **A way of proving things.** Tests with negative controls, kill tests at many points, and every result recorded in a register.

It also works as practical material for a **Target Operating Model** for a payments-style platform: consistency tiers, failure
modes, a risk register, and chaos-test evidence.

## Who it is for

Platform and database engineers, SREs, and architects who need to design, review or teach resilient database platforms, and
anyone who wants a worked example of turning an availability claim into a test.

## What you get

| You get | Where |
|---|---|
| A **capability catalogue**: each resilience problem, its mechanism, the test, the measured result and the limit | [docs/capability-catalogue.md](docs/capability-catalogue.md) |
| A **capability register**: 52 capabilities, each with status, evidence and limits, plus the open gaps | [pg-replication/capability-register.md](pg-replication/capability-register.md) |
| An **evidence log**: the commands, numbers and defects found in each run of experiments | [pg-replication/evidence-log.md](pg-replication/evidence-log.md) |
| **Runnable tests and experiments** (20 test scripts and a measurement runner), each restoring the starting state | [pg-replication/](pg-replication/README.md) |
| **RPO and RTO measurements** with a report | [pg-replication/docs/recovery-report.md](pg-replication/docs/recovery-report.md) |
| **Robustness patterns** (guards, verify-after-act, decisions read the writer) and diagrams | [pg-replication/docs/patterns/](pg-replication/docs/patterns/README.md) |
| A **secret rotation guide** with no failed writes | [pg-replication/docs/secrets-rotation.md](pg-replication/docs/secrets-rotation.md) |
| Two small **Python services**: a failover controller and a lease guard | [services/](services/) |
| Two **house standards** the code is checked against (Bash and Python) | [docs/python-standard.md](docs/python-standard.md), `pg-replication/scripts/lint-scripts.sh` |

## What was measured

All on one laptop (Docker Compose, PostgreSQL 16, two nodes). They show behaviour and relative cost, not production figures.

| Question | Answer | Evidence |
|---|---|---|
| Data lost on a writer crash, asynchronous | About 6 writes per second of replication lag | RPO-01 |
| Data lost on a writer crash, synchronous | **0**, and a control showed the test can see loss | RPO-02 |
| Price of zero loss | Writes block while the standby is cut off; about half the throughput under 16 clients | RPO-02, LOAD-01 |
| Downtime of a scripted promotion | 0.3 to 0.7 s | RTO-01 |
| Downtime with an automatic detector | 2.8 s (crash) to 8.3 s (hung writer) | ACT-01 |
| Time to notice a silent network link | 60 s by default, 4 s with tuned timeouts | NET-03 |
| Two writers with a partitioned, unkillable old writer | 14 to 16 s without the lease guard; **none** with it | LEASE-02 |
| Window of reduced safety after failing over from sync | 6.8 s (scripted floor) | SYNC-01 |
| Failed writes while rotating database passwords | 0 | SEC-R3 |
| Acknowledged writes lost across crash, mid-transaction kill and checkpoint kill | 0 | CRS-01 |

## Run it

You need Docker with Compose and **Bash 5.0 or later** (macOS ships 3.2; `brew install bash`).

```bash
cd pg-replication
docker compose up -d                       # primary on :5433, standby on :5434 (127.0.0.1 only)
bash scripts/verify-replication.sh         # write on the primary, read on the standby
bash scripts/run-all-checks.sh             # lint, documents, Python checks, then the 17-step failover and fail-back
bash scripts/test-auto-failover.sh         # a controller detects, fences and promotes; the client's downtime is timed
```

The linter needs `BASHCHECK_WRAPPER` set; see [pg-replication/README.md](pg-replication/README.md). Every script takes `--help`.
The credentials are throwaway and the ports are bound to loopback: do not expose them, and never put real secrets here.

## How to read it

1. [Capability catalogue](docs/capability-catalogue.md): the map, grouped by problem.
2. Run the test named in an entry, and read its narrated output.
3. [Capability register](pg-replication/capability-register.md): the full evidence, limits and open gaps.
4. [Patterns](pg-replication/docs/patterns/README.md) and [diagrams](pg-replication/docs/diagrams/failover-sequence.md): why the scripts are shaped as they are.

## Repository map

```
README.md                  this file
docs/                      capability catalogue, the Python standard, proposals to the Bash standard
pg-replication/            the Postgres pair: compose file, scripts, libraries, tests, register, patterns
services/                  Python services: failover_controller (detector), fence_guard (lease guard)
python-standard/           pinned tools image and test fixtures for the Python checks
CLAUDE.md                  working notes for the AI coding assistant used on this project
```

## Roadmap and status

| Phase | Scope | State |
|---|---|---|
| 1 | The Postgres pair: replication, failover and fail-back, RPO/RTO, crash and network faults, secret rotation | Complete |
| 2 | Failover safety (detector, fencing epoch, actor, leases) and the application layer (outbox, idempotent consumers, invariant checker) | Failover safety built, proven and documented as patterns (11 pages); application layer not started |
| 3 | Service layer: a load generator and clients that retry through a failover; RTO under load; rotation for application clients | Not started |
| 4 | Hot-hot with partitioned ownership | Not started |
| 5 | Multi-writer for commutative ledger entries, showing where it breaks | Not started |
| 6 | Chaos experiment catalogue mapped to a risk register, with SLI and error-budget reporting | Not started |

## Honest limits

- A single machine and a single Docker host: no real network, no second site, no power-loss tests.
- One controller and one actor, with a host-local lock. Replicating them needs a consensus store.
- The tests write through `psql` and `pgbench`. There is no payments service yet, so end-to-end consistency (no lost or duplicated
  payment) is **not** shown; that is Phase 2 and 3.
- Numbers are from a few trials each. They show how a mechanism behaves, not statistical confidence.

The open gaps are listed in section 4 of the register.
