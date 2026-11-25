# Evidence log

This log holds the raw evidence behind the [capability register](capability-register.md). It has one section for each run of experiments, in date order. Each section gives the commands, the numbers observed, the defects found, and what the result does and does not show. The register holds the conclusions. This log holds the detail. The identifiers, such as FOV-09, are the register's.

The log uses these terms. The write-ahead log (WAL) is the stream of changes that PostgreSQL replicates. The recovery point objective (RPO) is the amount of acknowledged data that may be lost. The recovery time objective (RTO) is the time that clients may be unable to write. A log sequence number (LSN) is a position in the WAL. SIGKILL is the signal that stops a process at once.

| Date | Section |
|---|---|
| 2026-11-14 | [Observations behind the manual rows](#2026-11-14-observations-behind-the-manual-rows) |
| 2026-11-20 | [Hard kills](#2026-11-20-hard-kills) |
| 2026-11-21 | [First gap-closing runs](#2026-11-21-first-gap-closing-runs) |
| 2026-11-21 | [Recovery point and recovery time measurements](#2026-11-21-recovery-point-and-recovery-time-measurements) |
| 2026-11-21 | [The crash matrix](#2026-11-21-the-crash-matrix) |
| 2026-11-21 | [The maintenance lock and rotation under synchronous replication](#2026-11-21-the-maintenance-lock-and-rotation-under-synchronous-replication) |
| 2026-11-21 | [Concurrent load](#2026-11-21-concurrent-load) |
| 2026-11-21 | [Network faults](#2026-11-21-network-faults) |
| 2026-11-22 | [Start-time fencing](#2026-11-22-start-time-fencing) |
| 2026-11-22 | [The detector](#2026-11-22-the-detector) |
| 2026-11-22 | [The acting half](#2026-11-22-the-acting-half) |
| 2026-11-22 | [Live fencing](#2026-11-22-live-fencing) |
| 2026-11-23 | [The actor, the controller and the hand-over](#2026-11-23-the-actor-the-controller-and-the-hand-over) |
| 2026-11-24 | [Synchronous replication switched on again by the rejoin](#2026-11-24-synchronous-replication-switched-on-again-by-the-rejoin) |
| 2026-11-25 | [The write check, the fail-back and link faults](#2026-11-25-the-write-check-the-fail-back-and-link-faults) |
| 2026-11-25 | [The Phase 1 remainder](#2026-11-25-the-phase-1-remainder) |

## 2026-11-14: observations behind the manual rows

Both containers were healthy at the start, in asynchronous mode with the starting roles. Automated tests have since replaced the manual rows that these observations supported.

| Experiment | Observation |
|---|---|
| Asynchronous mode, standby stopped. | An insert took 62 milliseconds. The slot read `standby1_slot active=false wal_status=reserved`. After a restart the row was on the standby within about 1 second, and 1 standby was streaming. |
| Synchronous mode, standby up. | The state was `sync_state=sync`, and an insert took 60 milliseconds. |
| Synchronous mode, standby stopped. | An insert was still blocked after 6 seconds. It completed 8,578 milliseconds after it started, when the standby returned. The standby then held all 3 rows. |
| Promotion guard, primary running. | The script exited with status 1. It said that the primary was still accepting connections and that it should be stopped first, or that `--force` should be passed. The standby stayed in recovery. |
| Split-brain guard. | After the primary was stopped and the standby was promoted, `bring-up-database.sh --database primary` exited with status 1. It logged that both nodes were writable and that it was stopping `pg-primary`. The container was not running afterwards. `restore-starting-state.sh` then exited with status 0 and the starting roles were back. |
| `verify-replication.sh`. | The row was visible on the standby after about 62 milliseconds. The standby rejected a write. |
| `run-all-checks.sh`. | The lint check and the round trip both passed. |
| Port exposure. | Before the fix, port 5433 was reachable on the machine's network address. After the fix it was bound to `127.0.0.1` only, and it was closed on the network address. |

The evidence of 2026-11-05 and 2026-11-13 was gathered in earlier work. It is described in the project history, and it was not repeated unless a row says 2026-11-14.

## 2026-11-20: hard kills

`test-hard-kill.sh` starts a script in its own process group and sends SIGKILL to the whole group. No trap runs, and Docker commands die in the middle of a step. It then runs `restore-starting-state.sh`.

The first chain of kills of the restore, between 1 and 4.5 seconds, found four defects. The table gives each defect and its fix.

| Finding before the fixes | Fix |
|---|---|
| A kill at 1 second left both nodes writable. The split-brain guard stopped the standby, and every later restore exited with status 1. | The restore now empties and copies the standby again with `--clone` when it cannot start it safely. |
| A kill at 2 seconds made `pg_rewind` refuse the half-rewound directory. It said that it needed data checksums or `wal_log_hints`. | A rebuild-pending marker is written before the data directory changes. A node that still has the marker is cloned and not rewound. |
| Kills at 2.5 and 3.5 seconds made status queries fail with "database system is shutting down". The restore then crashed with exit status 2. | `database::in_recovery` retries for up to 30 seconds. It fails at once if the container is not running. |
| A kill at 4.5 seconds left the standby up and in recovery but wedged. The log said "incorrect prev-link", the slot was inactive, and there was no replication connection. The restore still reported success. | The restore now requires one streaming standby. It copies the standby again if it is not streaming. |

After the fixes, all 16 round-trip kills and all 10 real restore kills recovered. The marker was found in 19 rebuilds, so those nodes were cloned. The restore rebuilt the standby 3 times. One stale marker remained after a kill in the instant between "streaming" and "marker removed". It is harmless, because the next rebuild of that node clones it.

## 2026-11-21: first gap-closing runs

Every run started from a restored stack and ended with the starting state restored.

| Experiment | Runs | Result |
|---|---|---|
| `test-divergence-rewind.sh` (FOV-09) | 5 | All runs exited with status 0. |
| `test-replica-lag.sh` (DEC-01) | 4 | Three runs exited with status 0. The first failed on a wrong expected value in the test, not in the system, and was corrected. |
| `test-slot-limit.sh` (OPS-04) | 4 | The first run found the unreserved-slot defect. The next three runs, with the fix, exited with status 0. |
| `test-rotation.sh` (SEC-R3) | 3 | All runs exited with status 0, with no failed write. |
| `test-hard-kill.sh --target rotate` (SEC-R3) | 25 | All 25 kills recovered after the fix. The first sweep, before the fix, failed at 1 second. |
| `test-hard-kill.sh` for the round trip and the restore, with the one-`primary_conninfo` assertion | 17 | All 11 kills of the round trip and all 6 kills of the restore recovered. |
| `run-all-checks.sh` | After every change | The lint, document and round-trip checks passed. |

The experiments found eight defects. A test that could fail found each one, and no reading of the code found any.

| Found by | Defect | Fix |
|---|---|---|
| The cleanup check of `run-all-checks.sh`. | `check-docs.sh` left a temporary file on every run, because its cleanup was registered inside a subshell. | The file is now created and registered in the main shell. |
| A hard kill of the restore at 4.5 seconds. | A wedged standby was reported as replicating, and the restore exited with status 0. | The restore requires a streaming standby and clones one that is not streaming. |
| A hard kill of the restore at 2 seconds. | `pg_rewind` ran on a half-rewound directory and refused. | A rebuild-pending marker makes a pending node be cloned and not rewound. |
| A hard kill of the restore at 2.5 and 3.5 seconds. | Status queries failed while a database was shutting down, and the restore crashed. | `database::in_recovery` retries. |
| A hard kill of the restore at 1 second. | The split-brain guard left a node stopped, and no later restore could continue. | The restore rebuilds that standby. |
| An inspection of the standby's settings. | `primary_conninfo` was appended on every rebuild. It left 88 stale plain-text password lines. | The setting is written into a new file that is moved into place (SEC-R2). |
| `test-slot-limit.sh`. | An invalidated slot that was reused after a clone stayed `unreserved` and no longer protected the WAL. | An unusable slot is dropped and created again (OPS-04). |
| `test-hard-kill.sh --target rotate` at 1 second. | A forced reconnect left the standby reconnecting for up to 5 seconds. The re-run refused to start, and the delay would also have stalled synchronous commits. | The forced reconnect was removed, and the precondition waits for streaming. |

## 2026-11-21: recovery point and recovery time measurements

`measure-recovery.sh` runs `run-recovery-trial.sh` for each case. A prober, `run-write-prober.sh`, writes numbered rows about every 100 milliseconds. It records every attempt in a ledger outside both databases. A fault is then caused. It is a clean stop or a crash (SIGKILL) of the writer. For the RPO cases, the standby is first cut off the network with `docker network disconnect` for the length of the lag. The standby is promoted by script. `report-ledger.sh` then compares the ledger with the node that took over. The stack is restored after every trial.

There were 21 trials. All completed, and all targets were met. Every trial is in [docs/recovery-results.txt](docs/recovery-results.txt), and the tables are in [docs/recovery-report.md](docs/recovery-report.md).

| Case | Trials | Acknowledged writes (median) | Lost writes | Outage in milliseconds (minimum, median, maximum) |
|---|---|---|---|---|
| Clean stop. | 3 | 33 | 0, 0, 0 | 369, 374, 482 |
| Crash. | 3 | 34 | 0, 0, 0 | 312, 499, 726 |
| Asynchronous, lag 0 seconds. | 3 | 35 | 0, 0, 0 | 307, 400, 482 |
| Asynchronous, lag 1 second. | 3 | 42 | 6, 6, 6 | 307, 311, 400 |
| Asynchronous, lag 3 seconds. | 3 | 53 | 17, 17, 18 | 295, 310, 583 |
| Synchronous, lag 3 seconds. | 3 | 35 | 0, 0, 0 | 3,446, 3,576, 3,702 |
| Control: synchronous with commit level `local`, lag 3 seconds. | 3 | 51 | 17, 17, 17 | 317, 317, 330 |

Loss tracks lag at about the write rate, which is 6 writes for each second of lag. Synchronous replication loses nothing. Its price is that writes block for as long as the standby is unreachable. The control shows that the test would have seen a loss. A promotion by script takes well under a second. The numbers do not show what a detector, a router or a person adds. They also do not show what happens at higher write rates (GAP-15 and GAP-10).

| Found by | Finding | Result |
|---|---|---|
| A feasibility probe. | Isolating the standby with `docker network disconnect` injects controlled lag with no extra tool. RPO against lag can therefore be measured before a network fault tool exists. | The method was used for the RPO cases. |
| A crash trial. | `pg_rewind` of a node that was killed with SIGKILL fails, because "lock file postmaster.pid already exists" in its crash-recovery step. A crashed old primary cannot be rewound as it is. | `promote-primary-to-standby.sh` now falls back to a clone when `pg_rewind` fails. A restore from a crash recovers in one call. |
| The synchronous trials. | Zero loss is bought with blocked writes. The outage is as long as the isolation, which is 3.4 to 3.7 seconds for a 3-second lag. | The price is recorded in RPO-02. |

## 2026-11-21: the crash matrix

The crash matrix uses the same trials as the previous section, with a write prober and a ledger. It adds four scenarios that kill a node and restart it, with no failover. After each trial, `report-ledger.sh` compares the ledger with the node that holds the data, and `amcheck` checks the B-tree indexes. There were 12 trials. All completed, and every target was met. Every trial is in [docs/recovery-results.txt](docs/recovery-results.txt).

| Case | Trials | Acknowledged writes | Lost writes | Failed writes | Outage in milliseconds | Index damage | Other check |
|---|---|---|---|---|---|---|---|
| Standby killed. | 3 | 62, 63, 63 | 0, 0, 0 | 0, 0, 0 | 0 | 0 | The standby caught up from its slot. |
| Writer killed and restarted. | 3 | 43, 43, 44 | 0, 0, 0 | 32 | 3,397, 3,439, 3,500 | 0 | None. |
| Writer killed in a transaction. | 3 | 50, 50, 51 | 0, 0, 0 | 32 | 3,456, 3,490, 3,538 | 0 | No uncommitted row was kept, and all 1,000 committed rows were kept. |
| Writer killed in a checkpoint. | 3 | 50, 54, 57 | 0, 0, 0 | 34 to 40 | 3,614, 3,794, 4,419 | 0 | The crash was inside a checkpoint in 3 of 3 trials. All 1,500,000 committed rows were kept. |

| Found by | Finding | Result |
|---|---|---|
| The first version of the checkpoint case. | It passed, but the PostgreSQL log showed that the checkpoint had finished in 41 milliseconds, before the kill 150 milliseconds later. The case had not tested a crash during a checkpoint. | The case now dirties 1.5 million rows and kills at 0.1 seconds. The trial reads the log and records whether the last crash recovery followed an unfinished checkpoint. The verdict fails if no trial hit one. |
| The mid-transaction case. | A crash in a transaction needs proof that the transaction was open. | The trial checks `pg_stat_activity` for the open transaction just before the kill, and it stops if the transaction is not there. |
| All four cases. | Crash recovery on a node with this much data is fast. About 0.4 to 0.5 seconds of the 3.4 to 3.5 seconds of outage was recovery. The rest was the 3 seconds that the node was kept down. | The restart outage is judged against the downtime plus the RTO target. |

## 2026-11-21: the maintenance lock and rotation under synchronous replication

| Experiment | Result |
|---|---|
| `test-maintenance-lock.sh`. | The first run had 5 steps. A second concurrent rotation was refused, and the first completed. A rotation during a rebuild was refused, and the rebuild completed, because its child scripts re-enter the lock. A stale lock was taken over. A reused process identifier was not honoured. |
| `ROTATION_MODE=sync test-rotation.sh`, run twice. | The standby stayed synchronous through three rotations. There were 34 writes and none failed. The slowest took 123 milliseconds, against 93 milliseconds in asynchronous mode. A standby rebuilt from an empty volume joined. |
| A defect found by the synchronous run (REP-07). | The first synchronous run left the standby with the writer's `synchronous_standby_names`. The next failover round trip then hung for 8 minutes on the first write to the promoted node. The setting was reset by hand. It is now fixed in both rebuild paths and covered by an assertion in the synchronous rotation test. |

## 2026-11-21: concurrent load

| Experiment | Result |
|---|---|
| `test-load.sh`, final version. | All 6 steps passed. Asynchronous replication ran at 19,193 transactions a second, and synchronous replication at 8,957, which is 47 per cent. Money was conserved exactly. The standby was identical in both modes and after a mid-run crash. |
| A first version that proved less than it seemed. | With 5,000 keys, every key was accepted in the first fraction of a second. So 99.7 per cent of the transactions were duplicates that were rejected as no-ops, which are reads and not writes. Asynchronous and synchronous runs both reached 105,000 to 110,000 transactions a second, and the comparison wrongly said that synchronous replication was free. Widening the key space to a million made most transactions real writes. The cost of synchronous replication then appeared, as a drop to 47 per cent. |
| A defect in the test's own script. | A function printed narration into the output that was captured as a number, so the arithmetic broke. The first run found it. The count is now separate from the narration. |

## 2026-11-21: network faults

A Toxiproxy container on the compose network sits between the standby and the writer. The file `toxiproxy/proxies.json` configures it. For the test, the standby's `primary_conninfo` points at the proxy. `test-network-faults.sh` adds delay, adds a toxic that swallows data and keeps the connection open, or cuts the proxy. The calls are in `lib/toxic.sh`. There were three full runs. Every limit in the test comes from the mechanism, not from a run.

| Experiment | Result |
|---|---|
| Asynchronous mode, delay of 200 and 1,000 milliseconds each way. | Commits were unaffected, at 65 milliseconds for the baseline and 66 to 75 milliseconds under delay. The standby was stale by 215 to 225 milliseconds and by 1,009 to 1,089 milliseconds. |
| Synchronous mode, delay of 200 milliseconds each way. | A commit cost 401 to 422 milliseconds more, which is one round trip. |
| Synchronous mode, link cut for 5 seconds. | Commits blocked for 10.0 seconds, and once for 11.9 seconds. They resumed 4.8 seconds after the heal. With the retry interval at 500 milliseconds they resumed 0.3 seconds after the heal. |
| Silent link. | The writer noticed after 60.2 seconds by default, and after 4.0 to 4.1 seconds with 5-second timeouts. |
| Delay, then a writer crash. | Asynchronous replication lost 0 writes at 200 milliseconds and 14 to 15 writes at 1,000 milliseconds. Synchronous replication lost 0. |

Detecting a silent link takes 60 seconds by default. That is far more than the 0.3 to 0.7 seconds that a promotion takes (RTO-01). A cut link costs up to one retry interval more. A synchronous setup blocks writes for the whole time. Tuning `wal_sender_timeout`, `wal_receiver_timeout` and `wal_retrieve_retry_interval` shortens all three delays, but it raises the risk of false alarms on a slow link. The controller's thresholds should be chosen against these measurements.

| Found by | Finding | Result |
|---|---|---|
| The first scratch probe. | A multi-statement `ALTER SYSTEM` fails with "cannot run inside a transaction block". A missing semicolon also skipped a setting silently. Two of the "tuned" figures were therefore really the defaults. | The figures were discarded and measured again with the settings confirmed. `fault::tune` now runs each statement on its own. |
| Run 1. | The test passed all 7 steps but exited with status 1. After the last case the writer was crashed, and the cleanup tried to reset a setting on the dead node before it restored the stack. | The cleanup now restores first and resets the settings afterwards. |
| Run 2. | The cut-link check failed on a limit that was too tight. Healing the proxy takes about 1.5 seconds, so a cut of 5 seconds lasted about 6.5 seconds. | The check now measures from the end of the heal, and it separately checks that commits blocked while the link was cut. The run also confirmed that the cleanup works after a failed step. |

## 2026-11-22: start-time fencing

`test-fencing.sh` crashes the primary, promotes the standby, and starts the old primary with a plain `docker start`. It then tries a write. A control lifts the fence and shows that the write is accepted, so the test can detect a split-brain. The test failed first, because the old primary was writable. The fence call was then added to `promote-standby-to-primary.sh`.

| Run | Result |
|---|---|
| `test-fencing.sh`. | Four runs after the fix all exited with status 0. The early runs failed on faults in the test. A stopped node has no readable `PGDATA`. Narration was captured as data. A diverged node was left running for the restore to promote. |
| `test-divergence-rewind.sh`. | It passes with the fence applied to a running old primary, in a forced promotion. |
| `test-hard-kill.sh --target restore`. | Delays of 1 to 4 seconds pass. One earlier run failed at 2 seconds and left a standby without a slot and a stale marker. One restore repaired it, and 5 later runs passed. The failure is not explained and was not reproduced. |

## 2026-11-22: the detector

The controller runs in a container on the compose network. It reaches the writer through Toxiproxy, so only its own view can be cut. It reaches the standby directly. `test-detector.sh` freezes the writer with `docker pause`, crashes it, and cuts the network. A heartbeat writer gives the writer traffic. The heartbeat writes one WAL message a second from inside the writer's container. The limits come from the mechanism. The shortest possible detection is two failed probes of 2 seconds each, which gives 3 seconds. The longest is the probes plus the witness window plus slack, which gives 15 seconds.

| Run | Result |
|---|---|
| `test-detector.sh`. | Two full runs, of about 2 minutes each, exited with status 0. The first run passed at once. |
| The Python standard on `services/`. | Ruff, ruff format, mypy in strict mode and 8 pytest tests pass. The `psycopg` library was added to the pinned tools image so that mypy sees its types. The image must be rebuilt after this change. |
| An idle-writer measurement. | The age of the standby's `last_msg_receipt_time` cycles from 0 to about 30 seconds on an idle writer. There were 14 samples, 3 seconds apart. |

## 2026-11-22: the acting half

`test-auto-failover.sh` runs the controller and `act-on-failover.sh` together. The controller works through Toxiproxy, and a heartbeat runs on the writer. The client's view is a write that is retried every 0.2 seconds on the standby. The call to `pg_logical_emit_message` fails in recovery and succeeds once the node is a writer. The RTO is the time from the fault to the first success. The limits are 1 to 20 seconds.

| Run | Result |
|---|---|
| `test-auto-failover.sh`. | Two full runs exited with status 0 and passed at once. A crash took 2.9 and 2.8 seconds. A hung writer took 7.2 and 8.3 seconds. A freeze of 2 seconds caused no action. |
| The restore after each case. | `pg_rewind` of the killed old primary fails, so the script clones it. A crashed node cannot be rewound. The stack ends with the primary as the writer and the standby streaming. |

The same day, `test-actor-kill.sh` ran three cases. Each froze the writer, killed the actor with SIGKILL after one step, and checked the half-done state. It then ran the actor again and checked the end state. All three passed at once. The error line in the run log for each kill, with status 137, is the expected result of the kill.

## 2026-11-22: live fencing

The lease is a row in the writer's database. The controller renews it through Toxiproxy, so only its path can be cut. A guard container shares the writer's network namespace. When the writer is disconnected from the network, the guard loses nothing that it needs, but the controller cannot renew the lease. Both tests include a control without the guard.

| Run | Result |
|---|---|
| `test-lease-fence.sh`. | One full run passed at once. With renewals, no write was refused in 15 seconds. After the cut, writes were refused after 5.6 seconds and the writer was stopped. In the control, the writer was still writing, with the lease 9.2 seconds past expiry. |
| `test-lease-failover.sh`. | Two full runs passed. With the guard, the gaps were 8.8 and 9.6 seconds. Without it, two writers ran for 14 to 16 seconds. The first run of the test failed on a mistake in the test, because the actor's narration leaked into the captured result. The first full run's restore refused the deliberate split-brain that the control left. The test now stops the old writer, as `test-fencing.sh` does. |
| The Python standard on `services/`. | Ruff, mypy in strict mode and 12 pytest tests pass. |

`test-lease-handover.sh` also ran that day. One run passed at once. The earlier tests of the actor were run again after the actor changed. They were `test-auto-failover.sh`, `test-actor-kill.sh`, `test-two-actors.sh` and `test-lease-failover.sh`. All passed.

## 2026-11-23: the actor, the controller and the hand-over

| Run | Result |
|---|---|
| `test-actor-timed-kill.sh`. | Two full runs. The first used delays of 1 to 3 seconds, and every kill came after the actor had finished, so it tested nothing. The second used 0.1 to 0.9 seconds. Seven kills landed, and all 9 cases recovered. |
| `test-controller-kill.sh`. | One run passed at once. |
| `test-lease-handover.sh`. | One full run with the new third step passed at once. |
| The earlier actor tests. | `test-actor-kill.sh` was run again after its helpers moved to `lib/actor.sh`, and it passed. |

`test-sync-after-failover.sh` ran once and passed at once. The stack ended with both nodes asynchronous and the standby in recovery, which is the starting state.

## 2026-11-24: synchronous replication switched on again by the rejoin

| Run | Result |
|---|---|
| `test-sync-after-failover.sh`, now with 3 steps. | One run passed at once. After the rejoin, with no manual step, the node was synchronous and the setting was `FIRST 1 (standby1)`. The window was 8.0 seconds from the crash. |
| `run-all-checks.sh`. | The lint, document, Python and round-trip checks all passed. |
| `test-hard-kill.sh --target restore`. | All 8 cases recovered. They were kills at 1 to 7 seconds and two runs that finished. |

The change is that `lib/mode.sh` records the wanted mode. `set-replication-mode.sh` writes it, and `restore-starting-state.sh` sets it to asynchronous. `promote-primary-to-standby.sh` reads it after the node streams. For synchronous mode it runs `set-replication-mode.sh --mode sync` for the new writer.

## 2026-11-25: the write check, the fail-back and link faults

| Run | Result |
|---|---|
| `test-link-faults.sh`. | Three full runs passed all 6 steps. The first two runs stopped at thresholds that were wrong, and the thresholds were corrected. The test covers jitter, a bandwidth limit, one-way silence and a dropping link (NET-04 to NET-07). |
| `test-network-faults.sh`. | It passed when run again after its shared helpers moved to `lib/link.sh`. |
| `test-resume-fence.sh`. | Two full runs passed. The control accepted a write 3,103 and 3,121 milliseconds after the lease ran out. With the check, the write was refused (LEASE-04). |
| `test-lease-failback.sh`. | Two full runs passed. The first run's cleanup restore had failed without being noticed (LEASE-05). |
| `run-all-checks.sh`. | It passed after each fix. |

**Corrections made while writing the link-fault test.** The first run timed the writer's notice of one-way silence from after a 2-second wait, so it measured 1.9 seconds. It now measures from the fault. The 4.0 MB threshold for a backlog was borderline at 4.01 MB. It was lowered to 2 MB, and the 14-second wait of the synchronous commit is the real proof.

A first idea was that a link that drops every connection after 256 KB would let small WAL records crawl across. That idea was wrong. With 100,000 small rows the standby made no progress either. The standby's log showed that every reconnect started at the same WAL position, which was the segment start `2/EF000000`. Replay stood 3.7 MB into the segment, so each connection sent again the first 256 KB that the standby already had.

A 20 MB budget with 40 MB of WAL was then tried as a contrast. It did not finish in 60 seconds, and the standby was 22.7 MB behind. The cause is not understood. The test asserts only the stall that was shown and explained.

**Defects found by the fail-back test, both in the restore.** First, after the fail-back the old writer was stopped and fenced. The restore started it and returned without checking that it streamed, in the `writer/stopped` branch. The cleanup then failed with "pg-standby is not streaming". The restore now rebuilds a stopped standby that does not stream.

Second, a later `run-all-checks.sh` failed once at round-trip step 4, where the standby still held 2 tables after the primary dropped them. The round trip waits a fixed 2 seconds, and the restore had returned while the standby was still replaying. The restore now waits until the standby has replayed the writer's position.

Neither defect was caught earlier, because the first fail-back run was judged by its PASS line before its cleanup exit status was read. The cleanup had failed.

The plugin now reports Bash standard version 8, and the scripts conform.

## 2026-11-25: the Phase 1 remainder

| Run | Result |
|---|---|
| `test-replication-modes.sh`. | Two runs passed. They covered REP-04, REP-05 and REP-06, and the standby killed mid-commit under synchronous replication. |
| `test-guards.sh`. | Three runs gave the results passed, failed and passed. The failed run exposed the fence regression below. The last two runs passed (FOV-02 and FOV-03). |
| `test-rejoin-failure.sh`. | Two kill runs and one control passed (FOV-11). The first kill run failed on the restore defect below and passed after the fix. |
| `test-point-in-time.sh`. | Two runs passed (BAK-01). |
| `test-clone-rebuild.sh`. | Two runs passed (REP-07, clone path). The first run did not reproduce the condition, because the source named no synchronous standby. The test now switches the new writer to synchronous mode before the clone and asserts that the source has the setting. |
| `check-hygiene.sh`. | It passed on the repository. Its control was a copy with a bad call, a bad port and a committed key, and it failed all three checks. The control found a defect in the check itself. |
| `check-run-timeline.sh`. | It passed. Its control reversed the lines and failed the ordering check. |
| `run-all-checks.sh`. | It passed after the fence fix. The lint covered 74 files, and the document, Python, hygiene, timeline and round-trip checks passed. |
| `test-fencing.sh` and `test-hard-kill.sh --target restore`. | Both passed after the restore changes, with all 8 kills recovered. |

Three defects were found and fixed.

1. **Restore with both nodes stopped.** After a second failure the restore stopped with "cannot restore from roles stopped/stopped: repair by hand". `restore-starting-state.sh` now starts the writer candidate. That is the node without the replica marker `standby.signal`. If both nodes or neither have it, the node on the newer timeline wins, which is read with `pg_controldata` from the stopped volume through `fence::in_volume`. A tie goes to the primary. The restore then runs again from the resulting roles. The rejoin kill run verified the fix, with 8 of 8 rows on both nodes afterwards, and so did the hard-kill restore test.
2. **Fence and clone found the wrong volume once a node had several volumes.** Adding the archive and backup volumes to the primary made `container::volume` return all volume names joined. The fence path then became `/archive/backup/var/lib/postgresql/data`. The failure showed in the repeat run of `test-guards.sh`, where the promotion fenced the old primary. `container::volume` now returns the volume mounted at `/var/lib/postgresql/data`, and `fence::in_volume` uses that path. `test-guards.sh`, `test-fencing.sh`, `test-rejoin-failure.sh` and the round trip cover the fix again.
3. **The hygiene check passed a pattern that it could not read.** `git grep` took a pattern that began with a dash as an option. The command failed, and the `if` read the failure as "no match". The control found the defect. The pattern is now passed with `-e`. One limit remains: any `git grep` error still reads as "no match".

An interrupted rejoin also left the rebuild marker of `pg-primary`. The cleanup failed to restore, and a second run then found the standby not streaming. That work belongs to the rejoin tests, and the restore now also rebuilds a stopped standby that does not stream.

**What the new tests do not show.** The replication modes test uses one standby only. The rejoin failure test uses one kill point, while the rebuild marker exists. The point-in-time recovery test covers one timeline, with no failover between the backup and the recovery. Its archive is on the primary only, its target is an LSN, and it has no off-site copy. The split-brain guard acts only when the start-time fence has been lifted, because the fence is the first line (FOV-10).
