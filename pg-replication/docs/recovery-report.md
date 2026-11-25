# Recovery measurements: recovery point and recovery time

Written by write-recovery-report.sh on 2026-11-25 13:15:24 Coordinated Universal Time (UTC),
at commit 7a6c529 plus uncommitted changes.
The server was PostgreSQL 16.16 (Debian 16.16-1.pgdg13+1), with two nodes in Docker Compose on one machine.
The prober wrote about every 100 milliseconds.
The recovery time target was 30 seconds beyond the decision delay.
Every run overwrites this file.

The recovery point objective (RPO) measures how much data is lost.
**RPO observed** is the number of writes that the client was told were committed
and that are missing on the node that took over.
The recovery time objective (RTO) measures how long clients cannot write.
**RTO observed** is the time from the first failed write to the first success,
as the client sees it.
A write that failed but is present is in doubt and is not lost.

## Verdict

| Case | Lag (s) | Target | Result |
| --- | --- | --- | --- |
| stop | 0 | outage within the RTO target, nothing lost | PASS |
| crash | 0 | outage within the RTO target | PASS |
| async | 0 | the lag shows up as loss (lag 0: recorded only) | PASS (recorded, no target at lag 0) |
| async | 1 | the lag shows up as loss (lag 0: recorded only) | PASS (most lost in a trial: 6) |
| async | 3 | the lag shows up as loss (lag 0: recorded only) | PASS (most lost in a trial: 18) |
| sync | 3 | **no acknowledged write lost** | PASS |
| control | 3 | loss reappears at commit level local | PASS (most lost in a trial: 17) |
| standby-crash | 3 | the standby catches up; no write fails | PASS |
| primary-restart | 3 | restart within the target; nothing lost; indexes intact | PASS |
| midtx | 3 | uncommitted rows gone, committed rows kept; indexes intact | PASS |
| checkpoint | 3 | the crash lands in a checkpoint; nothing lost; indexes intact | PASS |

## RTO: how long the client could not write

| Case | Trials | Outage ms (min / median / max) | Median share of a month at 99.999% |
| --- | --- | --- | --- |
| stop | 3 | 369 / 374 / 482 | 1.4% of 26 s |
| crash | 3 | 312 / 499 / 726 | 1.9% of 26 s |

The outage includes the decision delay. Subtract the delay to get the system time.

## RPO: writes acknowledged and then lost

| Case | Lag (s) | Trials | Acknowledged (median) | Lost (min / median / max) | In doubt (max) | Outage ms (min / median / max) |
| --- | --- | --- | --- | --- | --- | --- |
| async | 0 | 3 | 35 | **0 / 0 / 0** | 0 | 307 / 400 / 482 |
| async | 1 | 3 | 42 | **6 / 6 / 6** | 0 | 307 / 311 / 400 |
| async | 3 | 3 | 53 | **17 / 17 / 18** | 0 | 295 / 310 / 583 |
| sync | 3 | 3 | 35 | **0 / 0 / 0** | 0 | 3446 / 3576 / 3702 |
| control | 3 | 3 | 51 | **17 / 17 / 17** | 0 | 317 / 317 / 330 |

Under synchronous replication, the outage is the time that writes were blocked
while the standby was cut off. That is the price of an RPO of 0.

## Crash matrix: a node killed and restarted, no failover

| Case | Down (s) | Trials | Lost | Failed writes | Outage ms (min / median / max) | Index damage | Uncommitted rows kept | Committed rows missing | Crashes inside a checkpoint |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| standby-crash | 3 | 3 | 0 | 0 | 0 / 0 / 0 | 0 | 0 | 0 | n/a |
| primary-restart | 3 | 3 | 0 | 32 | 3397 / 3439 / 3500 | 0 | 0 | 0 | n/a |
| midtx | 3 | 3 | 0 | 32 | 3456 / 3490 / 3538 | 0 | 0 | 0 | n/a |
| checkpoint | 3 | 3 | 0 | 40 | 3614 / 3794 / 4419 | 0 | 0 | 0 | 3 of 3 |

Each figure is the worst result over the trials.
The amcheck tool reports the index damage.

## Every trial

| Case | Lag (s) | Acknowledged | Lost | In doubt | Outage ms |
| --- | --- | --- | --- | --- | --- |
| stop | 0 | 33 | 0 | 0 | 482 |
| stop | 0 | 35 | 0 | 0 | 369 |
| stop | 0 | 31 | 0 | 0 | 374 |
| crash | 0 | 35 | 0 | 0 | 312 |
| crash | 0 | 34 | 0 | 0 | 499 |
| crash | 0 | 33 | 0 | 0 | 726 |
| async | 0 | 34 | 0 | 0 | 482 |
| async | 0 | 35 | 0 | 0 | 307 |
| async | 0 | 35 | 0 | 0 | 400 |
| async | 1 | 41 | 6 | 0 | 400 |
| async | 1 | 42 | 6 | 0 | 311 |
| async | 1 | 42 | 6 | 0 | 307 |
| async | 3 | 53 | 18 | 0 | 310 |
| async | 3 | 50 | 17 | 0 | 583 |
| async | 3 | 53 | 17 | 0 | 295 |
| sync | 3 | 36 | 0 | 0 | 3446 |
| sync | 3 | 34 | 0 | 0 | 3702 |
| sync | 3 | 35 | 0 | 0 | 3576 |
| control | 3 | 50 | 17 | 0 | 317 |
| control | 3 | 51 | 17 | 0 | 317 |
| control | 3 | 51 | 17 | 0 | 330 |
| standby-crash | 3 | 62 | 0 | 0 | 0 |
| standby-crash | 3 | 63 | 0 | 0 | 0 |
| standby-crash | 3 | 63 | 0 | 0 | 0 |
| primary-restart | 3 | 43 | 0 | 0 | 3500 |
| primary-restart | 3 | 44 | 0 | 0 | 3439 |
| primary-restart | 3 | 43 | 0 | 0 | 3397 |
| midtx | 3 | 50 | 0 | 0 | 3538 |
| midtx | 3 | 51 | 0 | 0 | 3490 |
| midtx | 3 | 50 | 0 | 0 | 3456 |
| checkpoint | 3 | 50 | 0 | 0 | 4419 |
| checkpoint | 3 | 54 | 0 | 0 | 3614 |
| checkpoint | 3 | 57 | 0 | 0 | 3794 |

## Limits

- The measurements ran on one machine, and the fault was a process crash
  (SIGKILL) and not a power cut.
- The test injects lag by isolating the standby from the network, so the loss
  is the writes of the lag window. Gradual latency needs a network fault tool.
- RTO is the time until a write succeeds somewhere, seen through the Docker host.
  There is no router or client library, and promotion is a script and not a
  controller.
- The write rate is about 10 writes a second, so loss is counted in tens of
  writes and not in thousands.
- The crash matrix kills the container with SIGKILL. A power cut is not tested.
- Where a case has no target, the number is recorded only.

To reproduce the run, use bash scripts/measure-recovery.sh. Its --help lists the
settings.
