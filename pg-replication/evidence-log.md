# Evidence log

The raw evidence behind the [capability register](capability-register.md): one section per run of experiments, in date order, with the commands,
the numbers observed, the defects found and what each result does and does not show. The register holds the conclusions
(status, one-line evidence, limits); this file holds the detail. Capability IDs (FOV-09 and so on) are the register's.

| Date | Section |
|---|---|
| 2026-11-14 | [Evidence log, 2026-11-14](#evidence-log-2026-11-14) |
| 2026-11-20 | [Evidence log, 2026-11-20 (hard kills)](#evidence-log-2026-11-20-hard-kills) |
| 2026-11-21 | [Evidence log, 2026-11-21 (gap plan, milestone M1)](#evidence-log-2026-11-21-gap-plan-milestone-m1) |
| 2026-11-21 | [Evidence log, 2026-11-21 (gap plan, milestone M2: RPO and RTO)](#evidence-log-2026-11-21-gap-plan-milestone-m2-rpo-and-rto) |
| 2026-11-21 | [Evidence log, 2026-11-21 (milestone M2: the crash matrix)](#evidence-log-2026-11-21-milestone-m2-the-crash-matrix) |
| 2026-11-21 | [Evidence log, 2026-11-21 (SEC-08: the maintenance lock and rotation under sync)](#evidence-log-2026-11-21-sec-08-the-maintenance-lock-and-rotation-under-sync) |
| 2026-11-21 | [Evidence log, 2026-11-21 (GAP-10 at database level: concurrent load)](#evidence-log-2026-11-21-gap-10-at-database-level-concurrent-load) |
| 2026-11-21 | [Evidence log, 2026-11-21 (GAP-11: network faults)](#evidence-log-2026-11-21-gap-11-network-faults) |
| 2026-11-22 | [Evidence log, 2026-11-22 (GAP-03, start-time fencing)](#evidence-log-2026-11-22-gap-03-start-time-fencing) |
| 2026-11-22 | [Evidence log, 2026-11-22 (GAP-07, the detector)](#evidence-log-2026-11-22-gap-07-the-detector) |
| 2026-11-22 | [Evidence log, 2026-11-22 (GAP-07, the acting half)](#evidence-log-2026-11-22-gap-07-the-acting-half) |
| 2026-11-22 | [Evidence log, 2026-11-22 (GAP-03, live fencing)](#evidence-log-2026-11-22-gap-03-live-fencing) |
| 2026-11-23 | [Evidence log, 2026-11-23 (GAP-07 remainder)](#evidence-log-2026-11-23-gap-07-remainder) |

## Evidence log, 2026-11-14

Raw observations behind the "manual" rows. Setting: both containers healthy, async mode at the start, starting roles.

| Experiment | Observation |
|---|---|
| Async, standby stopped | Insert: 62 ms. Slot: `standby1_slot active=false wal_status=reserved`. After restart: row on the standby within about 1 s; 1 standby streaming |
| Sync, standby up | `sync_state=sync`. Insert: 60 ms |
| Sync, standby stopped | Insert still blocked after 6 s; completed 8,578 ms after it started, once the standby came back. The standby then held all 3 rows |
| Promotion guard, primary running | Exit 1; message "Primary 'pg-primary' is still accepting connections ... Stop it first ... or pass --force"; standby still in recovery |
| Split-brain guard | After primary stopped and standby promoted, `bring-up-database.sh --database primary` exited 1; logged `DECISION: pg-primary and pg-standby are both writable: stopping pg-primary`; "split-brain prevented: pg-primary was stopped again"; container not running; `restore-starting-state.sh` then exited 0 with the starting roles back |
| `verify-replication.sh` | Row visible on the standby after about 62 ms; standby rejected a write; "PASS: replication is working" |
| `run-all-checks.sh` | `PASS lint`, `PASS roundtrip`, `ALL PASSED` |
| Port exposure | Before the fix: `0.0.0.0:5433` reachable on the LAN address. After: `127.0.0.1` only; closed on the LAN address |

The evidence of 2026-11-05 and 2026-11-13 referred to above was gathered in earlier sessions and is described in the project history; it was not repeated in this run unless a row says 2026-11-14.

## Evidence log, 2026-11-20 (hard kills)

Method: `test-hard-kill.sh` starts a script in its own process group and sends SIGKILL to the whole group (no trap runs, docker commands die mid-step), then runs `restore-starting-state.sh`.

| Finding before the fixes (earlier chain of kills of the restore, 1 s to 4.5 s) | Fix |
|---|---|
| Kill at 1 s: both nodes writable, the split-brain guard stopped the standby, and every later restore exited 1 | The restore now empties and re-copies the standby (`--clone`) when it cannot be started safely |
| Kill at 2 s: `pg_rewind` refused ("needs data checksums or wal_log_hints") on the half-rewound directory | A rebuild-pending marker is written before the data directory changes; if it is still there, the node is cloned, not rewound |
| Kill at 2.5 s and 3.5 s: status queries failed with "database system is shutting down" and the restore crashed with exit 2 | `database::in_recovery` retries for up to 30 s, and fails at once if the container is not running |
| Kill at 4.5 s: standby up and in recovery but wedged ("incorrect prev-link", slot inactive, no replication connection), yet the restore reported success | The restore now requires one streaming standby, and re-copies the standby if it is not streaming |

After the fixes: 16 of 16 round-trip kills and 10 of 10 real restore kills recovered; 19 rebuilds were cloned because the marker was found, and the standby was rebuilt by the restore 3 times. One stale marker was left by a kill in the instant between "streaming" and "marker removed"; it is harmless (the next rebuild of that node clones).

## Evidence log, 2026-11-21 (gap plan, milestone M1)

Runs this day, all from a restored stack, all ending with the starting state restored:

| Experiment | Runs | Result |
|---|---|---|
| `test-divergence-rewind.sh` (FOV-09) | 5 | all exit 0 |
| `test-replica-lag.sh` (DEC-01) | 4 | 3 exit 0; the first failed on a wrong expected value in the test itself (not in the system) and was corrected |
| `test-slot-limit.sh` (OPS-04) | 4 | the first run found the unreserved-slot defect; the next three, with the fix, exit 0 |
| `test-rotation.sh` (SEC-R3) | 3 | all exit 0, 0 failed writes in each |
| `test-hard-kill.sh --target rotate` (SEC-R3) | 25 real kills after the fix | all recovered. The first sweep, before the fix, failed at 1 s (see below) |
| `test-hard-kill.sh` roundtrip and restore, with the one-`primary_conninfo` assertion | 11 kills of the round trip, 6 of the restore | all recovered |
| `run-all-checks.sh` | after every change | `PASS lint`, `PASS docs`, `PASS roundtrip` |

**Defects the experiments found, and the fix.** Every one was found by a test that could fail, not by reading the code:

| Found by | Defect | Fix |
|---|---|---|
| Cleanup check of `run-all-checks.sh` | `check-docs.sh` left a temporary file on every run (cleanup registered inside a subshell) | the file is created and registered in the main shell |
| Hard kill of the restore (4.5 s) | a wedged standby was reported as "replicates" and the restore exited 0 | the restore requires a streaming standby and re-clones one that is not |
| Hard kill of the restore (2 s) | `pg_rewind` was run on a half-rewound directory and refused | a rebuild-pending marker; a pending node is cloned, not rewound |
| Hard kill of the restore (2.5 s, 3.5 s) | status queries failed while a database was shutting down and the restore crashed | `database::in_recovery` retries |
| Hard kill of the restore (1 s) | the split-brain guard left a node stopped and no later restore could continue | the restore rebuilds that standby |
| Inspection of the standby's settings | `primary_conninfo` was appended on every rebuild: 88 stale plaintext password lines | replaced in a new file moved into place (SEC-R2) |
| `test-slot-limit.sh` | an invalidated slot reused after a re-clone stayed `unreserved` and no longer protected WAL | an unusable slot is dropped and recreated (OPS-04) |
| `test-hard-kill.sh --target rotate` (1 s) | a forced reconnect left the standby reconnecting for up to 5 s, so the re-run refused to start; it would also have stalled synchronous commits | the forced reconnect was removed and the precondition waits for streaming |

Not yet measured, by design: everything in section 4. The plan to prove each gap is the "How to prove it" column above; M1 is complete.

## Evidence log, 2026-11-21 (gap plan, milestone M2: RPO and RTO)

Method: `measure-recovery.sh` runs `run-recovery-trial.sh` for each case. A prober (`run-write-prober.sh`) writes numbered rows about every 100 ms and records every attempt in a ledger outside both databases. A fault is caused: a clean stop or a crash (SIGKILL) of the writer, and for the RPO cases the standby is first cut off the network (`docker network disconnect`) for the lag. The standby is promoted by script. `report-ledger.sh` then compares the ledger with the node that took over. The stack is restored after every trial. 21 trials, all completed, all targets met; every trial is in [docs/recovery-results.txt](docs/recovery-results.txt) and the tables in [docs/recovery-report.md](docs/recovery-report.md).

| Case | Trials | Acknowledged (median) | Lost | Outage (ms) |
|---|---|---|---|---|
| clean stop | 3 | 33 | 0, 0, 0 | 369 / 374 / 482 |
| crash | 3 | 34 | 0, 0, 0 | 312 / 499 / 726 |
| async, lag 0 s | 3 | 35 | 0, 0, 0 | 307 / 400 / 482 |
| async, lag 1 s | 3 | 42 | 6, 6, 6 | 307 / 311 / 400 |
| async, lag 3 s | 3 | 53 | 17, 17, 18 | 295 / 310 / 583 |
| sync, lag 3 s | 3 | 35 | 0, 0, 0 | 3446 / 3576 / 3702 |
| control (sync, commit local), lag 3 s | 3 | 51 | 17, 17, 17 | 317 / 317 / 330 |

**What the numbers say.** Loss tracks lag at about the write rate (6 writes per second of lag); synchronous replication loses nothing, and its price is writes blocked for as long as the standby is unreachable; the control shows the test would have seen a loss; a promotion by script costs well under a second. They do not say what a detector, a router or a person adds, or what happens at higher write rates (GAP-15, GAP-10).

**Findings.**

| Found by | Finding | Result |
|---|---|---|
| Feasibility probe | Isolating the standby with `docker network disconnect` injects controlled lag with no extra tool, so RPO versus lag is measurable before a network fault tool exists | used for the RPO cases; a plan item for GAP-11 is no longer a prerequisite |
| A crash trial | `pg_rewind` of a node that was SIGKILLed fails ("lock file postmaster.pid already exists" in its crash-recovery step), so a crashed old primary cannot be rewound as it is | `promote-primary-to-standby.sh` now falls back to a clone when `pg_rewind` fails; a restore from a crash recovers in one call |
| The sync trials | Zero loss is bought with blocked writes: an outage as long as the isolation (3.4 to 3.7 s for a 3 s lag) | recorded as the price in RPO-02 |

## Evidence log, 2026-11-21 (milestone M2: the crash matrix)

Method: the same trials as section 8 (`run-recovery-trial.sh`, with a write prober and a ledger), with four scenarios that kill a node and restart it, with no failover. After each, `report-ledger.sh` compares the ledger with the node that holds the data, and `amcheck` checks the B-tree indexes. 12 trials, all completed, every target met. Every trial is in [docs/recovery-results.txt](docs/recovery-results.txt).

| Case | Trials | Acknowledged | Lost | Failed writes | Outage (ms) | Index damage | Other check |
|---|---|---|---|---|---|---|---|
| standby killed | 3 | 62 / 63 / 63 | 0, 0, 0 | 0, 0, 0 | 0 | 0 | caught up from its slot |
| writer killed and restarted | 3 | 43 / 43 / 44 | 0, 0, 0 | 32 | 3397 / 3439 / 3500 | 0 | none |
| writer killed in a transaction | 3 | 50 / 50 / 51 | 0, 0, 0 | 32 | 3456 / 3490 / 3538 | 0 | 0 uncommitted rows kept, 1,000 of 1,000 committed kept |
| writer killed in a checkpoint | 3 | 50 / 54 / 57 | 0, 0, 0 | 34 to 40 | 3614 / 3794 / 4419 | 0 | crash inside a checkpoint in 3 of 3; 1,500,000 of 1,500,000 committed kept |

**Findings.**

| Found by | Finding | Result |
|---|---|---|
| The checkpoint case, first version | It passed, but the Postgres log showed the checkpoint had finished in 41 ms, before the kill 150 ms later: the case had not tested a crash during a checkpoint | the case now dirties 1.5 million rows and kills at 0.1 s; the trial reads the log and records whether the last crash recovery followed an unfinished checkpoint; the verdict fails if no trial hit one |
| The mid-transaction case | A crash-in-a-transaction case needs proof the transaction was open | the trial checks `pg_stat_activity` for the open transaction just before the kill and stops if it is not there |
| All four | Crash recovery on a node with this much data is fast: about 0.4 to 0.5 s of the 3.4 to 3.5 s outage was recovery, the rest was the 3 s the node was kept down | recorded; the restart outage is judged against the downtime plus the RTO target |

## Evidence log, 2026-11-21 (SEC-08: the maintenance lock and rotation under sync)

| Experiment | Result |
|---|---|
| `test-maintenance-lock.sh` | 5 steps, first run: second concurrent rotation refused and the first completed; a rotation during a rebuild refused while the rebuild (whose child scripts re-enter the lock) completed; a stale lock taken over; a reused process id not honoured |
| `ROTATION_MODE=sync test-rotation.sh`, twice | the standby stayed `sync` through three rotations, 34 writes, 0 failed, slowest 123 ms (93 ms in async), a standby rebuilt from an empty volume joined |
| **A defect found by the sync run (REP-07)** | the first sync run left the standby with the writer's `synchronous_standby_names`, so the next failover round trip hung 8 minutes on the first write to the promoted node. Recovered by resetting the setting, then fixed in both rebuild paths and covered by an assertion in the sync rotation test |

## Evidence log, 2026-11-21 (GAP-10 at database level: concurrent load)

| Experiment | Result |
|---|---|
| `test-load.sh`, final version | 6 steps, all pass: async 19,193 tps, sync 8,957 tps (47%), money conserved exactly, standby identical in both modes and after a mid-run crash |
| **A first version that proved less than it seemed** | with 5,000 keys every key was accepted in the first fraction of a second, so 99.7% of transactions were duplicates rejected as no-ops (reads, not writes): async and sync both ran at about 105,000 to 110,000 tps, and the comparison said sync was free. That was wrong. Widening the key space to a million made most transactions real writes, and the cost of sync appeared (a drop to 47%) |
| **A defect in the test's own script** | a function printed narration into the output that was captured as a number, so the arithmetic broke; found on the first run and fixed by separating the count from the narration |

## Evidence log, 2026-11-21 (GAP-11: network faults)

Method: a Toxiproxy container on the compose network sits between the standby and the writer (`toxiproxy/proxies.json`), the standby's `primary_conninfo` is pointed at it for the test, and `test-network-faults.sh` adds delay, a swallowing ("silent") toxic, or cuts the proxy. `lib/toxic.sh` holds the calls. Three full runs; every limit in the test comes from the mechanism, not from a run.

| Experiment | Result |
|---|---|
| async, delay 200 and 1,000 ms each way | commits unaffected (65 ms baseline, 66 to 75 ms); standby stale 215 to 225 ms and 1,009 to 1,089 ms |
| sync, delay 200 ms each way | a commit costs 401 to 422 ms more: one round trip |
| sync, link cut 5 s | commits blocked 10.0 s (11.9 s once); resumed 4.8 s after the heal; with the retry interval at 500 ms, 0.3 s after the heal |
| link silent | noticed after 60.2 s by default, 4.0 to 4.1 s with 5 s timeouts |
| delay then a writer crash | async lost 0 (200 ms) and 14 to 15 (1,000 ms); sync lost 0 |

**What these mean for the failover controller (GAP-07).** Detecting a silent link takes 60 s by default, which dwarfs the 0.3 to 0.7 s a promotion takes (RTO-01); a cut link costs up to a retry interval more; and a synchronous setup blocks writes for the whole time. Tuning `wal_sender_timeout`, `wal_receiver_timeout` and `wal_retrieve_retry_interval` shortens all three, at the price of false alarms on a slow link. The controller's thresholds should be chosen against these measurements.

**Findings.**

| Found by | Finding | Result |
|---|---|---|
| The first scratch probe | a multi-statement `ALTER SYSTEM` fails ("cannot run inside a transaction block"), and a missing semicolon silently skipped the setting: two of my "tuned" figures were really the defaults | discarded; re-measured with the settings confirmed; `fault::tune` runs each statement on its own |
| Run 1 | the test passed all 7 steps but exited 1: after the last case the writer was crashed, and the cleanup tried to reset a setting on the dead node before restoring the stack | cleanup restores first, then resets settings |
| Run 2 | the cut-link check failed on a limit that was too tight: healing the proxy takes about 1.5 s, so a "5 s cut" lasted about 6.5 s | the check now measures from the end of the heal (commits resume within one retry interval) and separately checks that they were blocked while cut. This run also confirmed that the cleanup works after a failed step |

## Evidence log, 2026-11-22 (GAP-03, start-time fencing)

Method: `test-fencing.sh` crashes the primary, promotes the standby, then starts the old primary with a plain `docker start` and tries a write. A control lifts the fence and shows the write is accepted, so the test can detect split-brain. Run order of discovery: the test failed first (the old primary was writable), then the fence call was added to `promote-standby-to-primary.sh`.

| Run | Result |
|---|---|
| `test-fencing.sh` | 4 runs after the fix, all exit 0; the early runs failed on test faults (a stopped node has no readable `PGDATA`, narration captured as data, a diverged node left running for the restore to promote) |
| `test-divergence-rewind.sh` | passes with the fence applied to a running old primary (forced promotion) |
| `test-hard-kill.sh --target restore` | delays 1 to 4 s pass. One earlier run failed at 2 s and left a standby without a slot and a stale marker; one restore repaired it and 5 later runs passed. **Not explained; not reproduced** |

## Evidence log, 2026-11-22 (GAP-07, the detector)

Method: the controller runs in a container on the compose network and reaches the writer through Toxiproxy (so only its own view can be cut) and the standby directly. `test-detector.sh` freezes (`docker pause`), crashes and cuts, with a heartbeat writer (a WAL message a second, run inside the writer's container) giving the writer traffic. Limits are derived from the mechanism: the shortest possible detection is two failed probes of 2 s (hence 3 s), the longest is the probes plus the witness window plus slack (15 s).

| Run | Result |
|---|---|
| `test-detector.sh` | 2 full runs (about 2 minutes each), exit 0; the first passed at once |
| Python standard on `services/` | ruff, ruff format, mypy strict and 8 pytest tests pass; psycopg was added to the pinned tools image so mypy sees its types (rebuild the image after pulling this change) |
| Idle-writer measurement | the standby's `last_msg_receipt_time` age cycles from 0 to about 30 s on an idle writer (14 samples, 3 s apart) |

## Evidence log, 2026-11-22 (GAP-07, the acting half)

Method: `test-auto-failover.sh` runs the controller (through Toxiproxy, a heartbeat on the writer) and `act-on-failover.sh` together. The client's view is a write retried every 0.2 s on the standby (`pg_logical_emit_message` fails in recovery and succeeds once the node is a writer); RTO is the time from the fault to the first success. Limits are 1 to 20 s.

| Run | Result |
|---|---|
| `test-auto-failover.sh` | 2 full runs, exit 0, passed at once. Crash 2.9 s and 2.8 s; hung writer 7.2 s and 8.3 s; a 2 s freeze caused no action |
| Restore after each case | `pg_rewind` of the killed old primary fails and the script clones it instead (a crashed node cannot be rewound); the stack ends primary=writer, standby=streaming |

Actor kills (`test-actor-kill.sh`, same day): three cases, each freezes the writer, SIGKILLs the actor after one step, checks the half-done state, runs the actor again and checks the end state. All three passed at once. The ERROR line in the run log for each kill (status 137) is the expected result of the kill.

## Evidence log, 2026-11-22 (GAP-03, live fencing)

Method: the lease is a row in the writer's database; the controller (through Toxiproxy, so only its path can be cut) renews it; a guard container shares the writer's network namespace, so disconnecting the writer from the network disconnects the guard from nothing it needs but leaves the controller unable to renew. Both tests include a control without the guard.

| Run | Result |
|---|---|
| `test-lease-fence.sh` | 1 full run, passed at once: renewed (no refusal in 15 s); cut (refused after 5.6 s, writer stopped); control (still writing, lease 9.2 s past expiry) |
| `test-lease-failover.sh` | 2 full runs, passed; gap 8.8 s and 9.6 s with the guard; two writers for 14 to 16 s without it. The first run of the test failed on my own mistake (the actor's narration leaked into the captured result), and the first full run's restore refused the deliberate split-brain left by the control (the test now stops the old writer, as test-fencing does) |
| Python standard on `services/` | ruff, mypy strict and 12 pytest tests pass |

Hand-over (`test-lease-handover.sh`, same day): one run, passed at once. The earlier tests of the actor (auto-failover, actor-kill, two-actors, lease-failover) were re-run after the actor changed and all passed.

## Evidence log, 2026-11-23 (GAP-07 remainder)

| Run | Result |
|---|---|
| `test-actor-timed-kill.sh` | 2 full runs: 1 to 3 s delays (all finished before the kill, so nothing tested), then 0.1 to 0.9 s: 7 kills landed, 9 of 9 recovered |
| `test-controller-kill.sh` | 1 run, passed at once |
| `test-lease-handover.sh` | 1 full run with the new third step, passed at once |
| Earlier actor tests | `test-actor-kill.sh` (its helpers moved to `lib/actor.sh`) was re-run and passed |

Sync window (`test-sync-after-failover.sh`, 2026-11-23): one run, passed at once; the stack ended with both nodes asynchronous and the standby in recovery, the starting state.

## Evidence log, 2026-11-24 (GAP-07: sync switched on again by the rejoin)

| Run | Result |
|---|---|
| `test-sync-after-failover.sh` (3 steps now) | 1 run, passed at once: after the rejoin, with no manual step, the node was `sync` and the setting `FIRST 1 (standby1)`; window **8.0 s** from the crash |
| `run-all-checks.sh` | lint, docs, Python and the round trip all passed |
| `test-hard-kill.sh --target restore` | 8 cases (kills at 1 to 7 s, and two that finished), all recovered |

Change: `lib/mode.sh` records the wanted mode (`set-replication-mode.sh` writes it, `restore-starting-state.sh` sets async); `promote-primary-to-standby.sh` reads it after the node streams and, for sync, runs `set-replication-mode.sh --mode sync` for the new writer.

## Evidence log, 2026-11-25 (GAP-03 and GAP-11)

| Run | Result |
|---|---|
| `test-link-faults.sh` | 3 full runs, all 6 steps passed (the first two runs stopped at thresholds that were wrong and were corrected, see below). Jitter, a bandwidth limit, one-way silence, a dropping link (NET-04 to NET-07) |
| `test-network-faults.sh` | re-run after its shared helpers moved to `lib/link.sh`: passed |
| `test-resume-fence.sh` | 2 full runs (3103 ms and 3121 ms late): control accepted a write 3.1 s after the lease ran out; with the check it was refused (LEASE-04) |
| `test-lease-failback.sh` | 2 full runs passed; the first run's cleanup restore had failed unnoticed (see below) (LEASE-05) |
| `run-all-checks.sh` | passed after each fix |

**Corrections made while writing the link-fault test.** The first run timed the writer's notice of one-way silence from after a 2 s wait and so measured 1.9 s; it now measures from the fault. The 4.0 MB threshold for a backlog was borderline (4.01 MB) and was lowered to 2 MB; the proof is the 14 s wait of the synchronous commit. A first idea that a link dropping every connection after 256 KB would make small WAL records crawl across was **wrong**: with 100,000 small rows the standby made no progress either. The standby's log showed every reconnect starting at the same WAL position (the segment start `2/EF000000`, while replay stood 3.7 MB into the segment), so each connection re-sent the first 256 KB the standby already had. A 20 MB budget with 40 MB of WAL was then tried as the contrast and did **not** finish in 60 s (22.7 MB behind); it is recorded as unexplained, and the test asserts only the stall that was shown and explained.

**Defects found by the fail-back test, both in the restore.** (1) After the fail-back the old writer was stopped and fenced; the restore started it and returned without checking that it streamed (`writer/stopped` branch), so the cleanup failed with "pg-standby is not streaming". It now rebuilds a stopped standby that does not stream. (2) A later `run-all-checks.sh` failed once at round-trip step 4 (the standby still held 2 tables after the primary dropped them): the round trip waits a fixed 2 s and the restore had returned while the standby was still replaying. The restore now waits until the standby has replayed the writer's position. Neither was caught earlier because the first fail-back run was judged by its PASS line before its cleanup exit status was read; the cleanup had failed.

**Bash standard.** The plugin now reports standard version 8; the scripts conform.

## Evidence log, 2026-11-25 (Phase 1 remainder: P1-01 to P1-07)

| Run | Result |
|---|---|
| `test-replication-modes.sh` | 2 runs, passed both times (REP-04, REP-05, REP-06, and the standby killed mid-commit under sync) |
| `test-guards.sh` | 3 runs: passed, failed, passed. The failed run exposed the fence regression below; the last two runs passed (FOV-02, FOV-03) |
| `test-rejoin-failure.sh` | 2 kill runs and 1 control, passed (FOV-11). The first kill run failed on the restore defect below and passed after the fix |
| `test-point-in-time.sh` | 2 runs, passed both times (BAK-01) |
| `test-clone-rebuild.sh` | 2 runs, passed both times (REP-07, clone path). The first run did not reproduce the condition (the source named no sync standby), so the test now switches the new writer to sync before the clone and asserts that the source has the setting |
| `check-hygiene.sh` | passed on the repository; its control (a copy with a bad call, a bad port and a committed key) failed all three checks. The control found a defect in the check itself (below) |
| `check-run-timeline.sh` | passed; its control (lines reversed) failed the ordering check |
| `run-all-checks.sh` | passed after the fence fix: lint (74 files), docs, python, hygiene, timeline, round trip |
| `test-fencing.sh`, `test-hard-kill.sh --target restore` | passed after the restore changes (8 of 8 kills recovered) |

**Defects found and fixed this session.**
1. **Restore with both nodes stopped.** After a second failure the restore stopped with "cannot restore from roles stopped/stopped: repair by hand". `restore-starting-state.sh` now starts the writer candidate: the node without the replica marker (`standby.signal`); if both or neither have it, the node on the newer timeline (read with `pg_controldata` from the stopped volume through `fence::in_volume`); a tie goes to the primary. The restore then runs again from the resulting roles. Verified by the rejoin kill run (8 of 8 rows on both nodes afterwards) and the hard-kill restore test.
2. **Fence and clone found the wrong volume once a node had several volumes.** Adding the archive and backup volumes to the primary made `container::volume` return all volume names joined, and the fence path became `/archive/backup/var/lib/postgresql/data`. The failure showed in the repeat run of `test-guards.sh` (the promotion fenced the old primary). Fixed: `container::volume` returns the volume mounted at `/var/lib/postgresql/data`, and `fence::in_volume` uses that path. Covered again by `test-guards.sh`, `test-fencing.sh`, `test-rejoin-failure.sh` and the round trip.
3. **The hygiene check passed a pattern it could not read.** A pattern beginning with a dash was taken by `git grep` as an option; the command failed, and the `if` read the failure as "no match". The control found it. Fixed by passing the pattern with `-e`. Limit that remains: any `git grep` error still reads as "no match".

**Restore defect, earlier in the session (not a Phase 1 item but found by the same work).** An interrupted rejoin left pg-primary's rebuild marker; the cleanup failed to restore, and a second run then found the standby not streaming. Recorded under the rejoin work; the restore now also rebuilds a stopped standby that does not stream, and waits until the standby has replayed the writer's position.

**What the new tests do not show.** Replication modes: one standby only. Rejoin failure: one kill point, while the rebuild marker exists. Point-in-time recovery: one timeline (no failover between the backup and the recovery), the archive on the primary only, the target by LSN, and no off-site copy. The guards: the split-brain guard acts only when the start-time fence has been lifted; the fence is the first line (FOV-10).

