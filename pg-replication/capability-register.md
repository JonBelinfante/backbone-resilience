# Capability register: Phase 1 (two Postgres nodes, WAL streaming)

What this experiment has **proved**, with the evidence for each claim, and what it has **not**. A capability is listed
as proven only if it has been run and the result observed. Last evidence run: **2026-11-20** (hard-kill tests, section 6); earlier evidence **2026-11-14**, one machine (Docker
Compose, macOS), PostgreSQL 16, two nodes `pg-primary` and `pg-standby`.

**Status legend**

| Status | Meaning |
|---|---|
| **Proven (auto)** | Checked by a command that can be re-run and gives PASS or FAIL: `run-all-checks.sh` or `verify-replication.sh` |
| **Proven (manual)** | Run by hand and the result recorded below; re-runnable, but no automatic pass/fail yet |
| **Partial** | The main behaviour is shown, with a stated limit that matters |
| **Not proven** | Not tested. See "Gaps" |

Re-run everything automated: `bash scripts/run-all-checks.sh` (lint of all scripts, then the 17-step round trip, about 22 s).

## 1. Replication

| ID | Capability | Status | Evidence | Limit |
|---|---|---|---|---|
| REP-01 | A committed write on the primary reaches the hot standby | **Proven (auto)** | `verify-replication.sh`: row visible on the standby after about 62 ms (includes `docker exec` overhead). Round trip steps 5-7: row present after a 2 s wait | One row at a time; no load; delay measured by polling |
| REP-02 | The standby is read-only | **Proven (auto)** | `verify-replication.sh`: "standby rejected the write" | |
| REP-03 | Schema changes replicate | **Proven (auto)** | Round trip steps 2-4: all tables dropped on the primary, 0 on the standby after 2 s; steps 5-7: table created | |
| REP-04 | Asynchronous mode: the primary keeps accepting writes while the standby is down; the replication slot keeps the WAL; the standby catches up on restart | **Proven (manual)** | 2026-11-14: insert took **62 ms** with the standby stopped; slot `standby1_slot active=false wal_status=reserved`; after restart the row was on the standby within about 1 s and 1 standby was streaming | One small write. The 1 GB slot cap (`max_slot_wal_keep_size`) was not exceeded or tested |
| REP-05 | Synchronous mode (RPO 0 setting) is reachable and costs availability: with the standby up commits stay fast; with it down they block | **Proven (manual)** | 2026-11-14: `sync_state=sync`; insert with standby up **60 ms**; with the standby stopped the insert was still **blocked after 6 s**, and completed **8.6 s** after it started, when the standby returned | Shows the cost. It does **not** show zero data loss; see GAP-02 |
| REP-06 | Switch async/sync without a restart | **Proven (manual)** | `set-replication-mode.sh --mode sync|async|status` used throughout the 2026-11-14 experiments (`ALTER SYSTEM` plus reload) | |

## 2. Failover and recovery

| ID | Capability | Status | Evidence | Limit |
|---|---|---|---|---|
| FOV-01 | Manual promotion: the standby becomes writable and accepts writes; the timeline increments | **Proven (auto)** | Round trip steps 8-9: primary stopped, `promote-standby-to-primary.sh`, row 2 inserted on the promoted node | Planned, **clean** stop of the primary only |
| FOV-02 | Promotion guard: refuses while the old primary still answers | **Proven (manual)** | 2026-11-14: exit status 1, "Primary 'pg-primary' is still accepting connections ... (split-brain)"; standby stayed in recovery | A script check, not fencing; direct `pg_promote` bypasses it |
| FOV-03 | Split-brain guard: a restarted old primary is stopped again when the other node is already writable | **Proven (manual)** | 2026-11-14: `bring-up-database.sh --database primary` exited 1, logged `DECISION: ... both writable: stopping pg-primary`, "split-brain prevented"; the container was not running afterwards | Only when started through `bring-up-database.sh`. A plain `docker start pg-primary` bypasses it (GAP-03) |
| FOV-04 | The old primary rejoins as a standby of the new writer: slot, checkpoint, `pg_rewind`, standby settings, start, streaming | **Proven (auto)** | Round trip steps 10-11: old primary is a replica and holds the rows written while it was away | `pg_rewind` reported "no rewind required" every time; the divergent-writes case is not exercised (GAP-04) |
| FOV-05 | A replica that was down catches up on writes made in its absence | **Proven (auto)** | Round trip steps 12-16: row 3 written while the replica was down is present after restart | |
| FOV-06 | After the whole sequence both nodes hold identical data and the roles are swapped | **Proven (auto)** | Round trip step 17: all three test rows on both nodes; writer and replica roles as expected | Compares the test table only, not a whole-database checksum |
| FOV-07 | The stack can be returned to its starting state (primary writes, standby replicates) from any known state, including after a failed or interrupted test | **Proven (auto, restore step); interrupted run was proven manually on 2026-11-13** | Every round trip ends with `restore-starting-state.sh` (fail-back with `pg_rewind`) and drops its table; also run from swapped roles and from a half-finished fail-back, and after a run killed mid-step-10 | Fail-back under async replication can lose writes the new writer had not yet sent (documented, not measured) |
| FOV-08 | A script killed with SIGKILL part way through a failover, fail-back or rebuild leaves a state that `restore-starting-state.sh` always recovers: primary writes and the standby is **streaming** | **Proven (auto)**: `test-hard-kill.sh` | 2026-11-20: 16 kills of the round trip (1 s to 18 s) and 10 real kills of the restore itself (0.5 s to 5 s, each from a failed-over start) all recovered; the restore ends only when `pg_stat_replication` shows one streaming standby | Only the scripts are killed, not Postgres: a database process killed mid-transaction is still GAP-06. Docker-side work started before the kill can finish by itself, so some kills land on an already-finished step |
| FOV-09 | **A true divergence is rewound.** The old primary accepts writes the new writer never saw, the standby is promoted anyway (forced), and `pg_rewind` undoes the old primary: it rejoins streaming and both nodes hold identical rows | **Proven (auto)**: `test-divergence-rewind.sh` | 2026-11-21, three runs, all exit 0. The standby is made to stop following (0 streaming standbys confirmed), the primary acknowledges 3 writes the standby never gets (confirmed absent on the standby), the standby is promoted with `--force`, the new writer takes 2 different writes. `pg_rewind` reported "servers diverged at WAL location ... on timeline 179", "rewinding from last common checkpoint", copied 117 MB, "Done!"; it did not say "no rewind required" and the node was not cloned. Afterwards the 3 writes are gone from the old primary, both nodes hold `base,kept-1,kept-2`, and the new writer reports one streaming standby | The 3 writes the old primary had acknowledged are **lost**: this is observed data loss under asynchronous replication when a writer is replaced while it holds writes its standby lacks (an RPO of 3 rows in this setup, evidence for GAP-01). The split is staged by clearing `primary_conninfo`, not by a network fault (GAP-11) |
| DEC-01 | **Decisions never read a lagging replica.** A decision read from a replica can approve what the writer would refuse; a decision path that reads only a writer cannot, and the guard refuses a replica | **Proven (auto)**: `test-replica-lag.sh`; guard `database::read_for_decision` | 2026-11-21, two runs, both exit 0, standby made 6 s late (`recovery_min_apply_delay`). Wrong way (negative control): both debits of 100 read a stale balance of 100 and were approved, the account went to **-100**. Right way: the first debit was approved, the second read 0 and was **declined**, the account stayed at 0. The guard answered "refusing to read pg-standby for a decision: it is a replica and may lag". A replica read after `database::wait_for_replay` showed 42; before it, the stale 100. Pattern page: [decisions-read-the-writer](docs/patterns/decisions-read-the-writer.md) | Proves the library guard and the anomaly, not that a future service obeys the rule (needs the application-layer checker, GAP-12). Lag is staged with an apply delay, not a network fault (GAP-11). A node demoted just after the check is not detected (fencing, GAP-03) |

## 3. Operations, observability and engineering controls

| ID | Capability | Status | Evidence |
|---|---|---|---|
| OPS-01 | The failover test is repeatable: it can be run again straight away and always leaves the stack in its starting state | **Proven (auto)** | Passed on every run during this work, including back-to-back runs; about 22 s |
| OPS-02 | A node can be stopped and started cleanly with confirmation and a health wait | **Proven (auto, and manual 2026-11-14)** | `bring-down-database.sh`, `bring-up-database.sh` (round trip steps 8, 12, 14) |
| OPS-03 | A standby is built automatically from the primary on first start (`pg_basebackup`, slot, `standby.signal`) | **Proven once** | The initial stack bring-up on 2026-11-05 (reported by the user). Not re-run in this evidence run |
| OPS-04 | **A dead standby cannot fill the primary's disk.** Past `max_slot_wal_keep_size` (1 GB) the slot is invalidated, the primary keeps accepting writes, and the documented recovery (re-clone with a fresh slot) restores streaming with a healthy slot | **Proven (auto)**: `test-slot-limit.sh`, with a real defect found and fixed | 2026-11-21, three runs. Standby stopped, 20 large WAL messages and a checkpoint per round: slot `reserved` until 918 MB behind (121 MB safe), `lost` in round 7 (about 1 GB). The primary's WAL directory peaked at 944 MB (bound 1,536 MB) and the primary accepted a write in every round. Restarted standby could not stream (log: "requested WAL segment ... has already been removed"). `restore-starting-state.sh` re-cloned it; streaming resumed and the slot read `reserved`. **Defect found:** before the fix the re-cloned standby streamed but the old slot stayed `unreserved` (0 bytes behind, yet no longer protecting WAL); dropping and recreating it gave `reserved`. `replace_unusable_slot` in `promote-primary-to-standby.sh` now drops an inactive slot that is not `reserved` or `extended` before the rebuild | Compose sets both WAL limits on the command line, which `ALTER SYSTEM` cannot override, so the test writes the real 1 GB (about 1.5 minutes). Recovery took about 68 s, of which 60 s is the wait for streaming before the restore gives up and re-clones. Asynchronous mode only: under synchronous replication a dead standby blocks writes instead (REP-05). WAL is generated with `pg_logical_emit_message`, not application writes |
| OBS-01 | Every script run leaves an audit trail: UTC millisecond timestamps, start, steps, decisions (`DECISION:` and `CHANGE:` lines), and on failure the line, function and command | **Proven (auto)** | Enforced by the Bash standard checker; seen in run logs |
| OBS-02 | A whole run can be reconstructed as one ordered timeline | **Proven (manual)** | `run-with-log-folder.sh --merge`: 16 logs and 295 lines for one round trip (re-measured 2026-11-15), in millisecond order (it was 87 logs before the shared libraries) |
| OBS-03 | The failover test tells its own story: each SQL statement, the data returned, each script run, with time and script name | **Proven (auto)** | Output of `test-failover-roundtrip.sh` |
| ENG-01 | All shell scripts conform to the house Bash standard (version 7), shellcheck and syntax checks | **Proven (auto)** | `run-all-checks.sh`: `PASS lint` (22 files, including `runtime.sh`, which is checked word for word against the standard) |
| ENG-02 | All docker and database calls live in libraries; no script outside `lib/` runs `docker` or `psql`. The standard's own functions come from one shared `runtime.sh` | **Proven (manual)** | Search of `pg-replication/scripts/` found only usage text. 16 host scripts import `runtime.sh`; about 945 lines of duplicated function bodies were removed (2026-11-15) |
| ENG-03 | No secrets in the repository or its history; the database ports are not exposed to the network | **Proven (manual)** | 2026-11-14: pattern scan of all files and both commits found no tokens or keys (only the documented throwaway credentials); ports bound to `127.0.0.1` and **closed on the LAN address**, open on localhost |
| ENG-04 | The robustness pattern pages and diagrams point at real files, functions and the right file for each function | **Proven (auto)** | `check-docs.sh` in `run-all-checks.sh`. Checked with three injected faults in a scratch copy (a missing page, an undefined function, a function cited in the wrong file) and a broken root-level link: each reported, exit 1 |
| SEC-R1 | The replication and superuser passwords can be rotated with no failed write and no lost data, by an in-place method and by an overlap method (a second role) | **Proven (manual 2026-11-20; automated 2026-11-21, see SEC-R3)** | 2026-11-20, under a write probe, asynchronous and synchronous: 0 failed inserts in every safe-order run; the deliberate window stalled one synchronous commit for 9.2 s; the failover and fail-back round trip passed with a rotated superuser password. Details: [docs/secrets-rotation.md](docs/secrets-rotation.md) | Manual only; no script or automatic test (gap SEC-01 on that page) |
| SEC-R3 | **Secret rotation is a script with tests.** `rotate-secret.sh` rotates the replication secret by overlap (a second role, alternating replicator_a and replicator_b, the name held in the `pg-replication-user` secret file) and the superuser secret in place; it rolls back before the files change and converges when re-run | **Proven (auto)**: `test-rotation.sh` and `test-hard-kill.sh --target rotate` | 2026-11-21. `test-rotation.sh`, three runs, all exit 0: replication, superuser and replication again under a write probe (32 to 50 rows a run), **0 failed writes**, the standby always streamed as the role in the secret file, exactly one replication role left, the superuser file password logs in over the network, and a standby rebuilt from an empty volume joined using the rotated files. 25 SIGKILLs of the rotation at 0.1 s to 1.3 s: re-running recovered every time. **Findings fixed:** an earlier forced reconnect left the standby reconnecting (up to 5 s, `wal_retrieve_retry_interval`) so the re-run refused to start, and would have stalled synchronous commits; the forced reconnect is gone and the precondition waits for streaming. Guide: [docs/secrets-rotation.md](docs/secrets-rotation.md) | Asynchronous mode only (rotation under synchronous replication was measured by hand, not automated). The in-place file write is not atomic and rotation can be overlapped by a rebuild (SEC-08). Application clients are not covered (SEC-06) |
| SEC-R2 | A node's `postgresql.auto.conf` holds at most one `primary_conninfo` (and one `primary_slot_name`), so a rotated-out password is not left on disk | **Proven (auto)**: `test-hard-kill.sh` asserts it after every recovery | 2026-11-21: before the fix 88 lines on the primary and 3 on the standby (86 and 87 the day before); after the fix 1 on each, after a full round trip and after a standby built from an empty volume; file mode 600, no temporary files left; 9 further hard kills all ended with one line per node. `container::mark_standby` and the standby entrypoint now replace the two settings in a new file moved into place | The password is still stored in plain text in that one line (see SEC-04 in [docs/secrets-rotation.md](docs/secrets-rotation.md)) |

## 4. Gaps: not proven yet

| ID | Gap | Why it matters | What would prove it |
|---|---|---|---|
| GAP-01 | **Observed RPO** under asynchronous replication: acknowledged writes missing on the surviving node after failover | The headline number for the async option | Write continuously, hard-kill the primary, promote, count missing acknowledged writes |
| GAP-02 | **Zero loss under synchronous replication** | RPO 0 is a claim, not yet a measurement | Same experiment with `sync` on; expect 0 missing |
| GAP-03 | **Fencing**: nothing stops a returning old primary except our own script | Real split-brain protection needs an epoch or token | Phase 2: fencing epoch; test with a plain `docker start` of the old primary |
| GAP-05 | **Observed RTO** from a client's view | The cost of each failure in seconds | A client-side prober measuring time to first success |
| GAP-06 | **Crash failures of Postgres itself**: scripts have been hard-killed (FOV-08), but every database stop is still clean (`docker stop`) | `kill`, power loss and a crash during a transaction behave differently, and `pg_rewind` needs a cleanly stopped target | `docker kill` the primary and the standby, at several points |
| GAP-07 | **Automatic failure detection and failover** | Today a person decides and runs the script | Phase 2: failure detector and controller |
| GAP-10 | **Behaviour under load and concurrency** | All tests are single writes | Load generator with idempotency keys (platform Phase 1 service) |
| GAP-11 | **Network faults** (latency, partitions, packet loss) | Only process stops are tested | Toxiproxy on the replication link |
| GAP-12 | **The application layer**: outbox, idempotent consumers, per-aggregate sequences, the independent invariant checker | The platform's actual consistency story | Platform build plan, Phases 1-5 |

## 5. Evidence log, 2026-11-14

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

## 6. Evidence log, 2026-11-20 (hard kills)

Method: `test-hard-kill.sh` starts a script in its own process group and sends SIGKILL to the whole group (no trap runs, docker commands die mid-step), then runs `restore-starting-state.sh`.

| Finding before the fixes (earlier chain of kills of the restore, 1 s to 4.5 s) | Fix |
|---|---|
| Kill at 1 s: both nodes writable, the split-brain guard stopped the standby, and every later restore exited 1 | The restore now empties and re-copies the standby (`--clone`) when it cannot be started safely |
| Kill at 2 s: `pg_rewind` refused ("needs data checksums or wal_log_hints") on the half-rewound directory | A rebuild-pending marker is written before the data directory changes; if it is still there, the node is cloned, not rewound |
| Kill at 2.5 s and 3.5 s: status queries failed with "database system is shutting down" and the restore crashed with exit 2 | `database::in_recovery` retries for up to 30 s, and fails at once if the container is not running |
| Kill at 4.5 s: standby up and in recovery but wedged ("incorrect prev-link", slot inactive, no replication connection), yet the restore reported success | The restore now requires one streaming standby, and re-copies the standby if it is not streaming |

After the fixes: 16 of 16 round-trip kills and 10 of 10 real restore kills recovered; 19 rebuilds were cloned because the marker was found, and the standby was rebuilt by the restore 3 times. One stale marker was left by a kill in the instant between "streaming" and "marker removed"; it is harmless (the next rebuild of that node clones).
