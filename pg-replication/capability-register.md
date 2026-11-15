# Capability register: Phase 1 (two Postgres nodes, WAL streaming)

What this experiment has **proved**, with the evidence for each claim, and what it has **not**. A capability is listed
as proven only if it has been run and the result observed. Last evidence run: **2026-11-14**, one machine (Docker
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

## 3. Operations, observability and engineering controls

| ID | Capability | Status | Evidence |
|---|---|---|---|
| OPS-01 | The failover test is repeatable: it can be run again straight away and always leaves the stack in its starting state | **Proven (auto)** | Passed on every run during this work, including back-to-back runs; about 22 s |
| OPS-02 | A node can be stopped and started cleanly with confirmation and a health wait | **Proven (auto, and manual 2026-11-14)** | `bring-down-database.sh`, `bring-up-database.sh` (round trip steps 8, 12, 14) |
| OPS-03 | A standby is built automatically from the primary on first start (`pg_basebackup`, slot, `standby.signal`) | **Proven once** | The initial stack bring-up on 2026-11-05 (reported by the user). Not re-run in this evidence run |
| OBS-01 | Every script run leaves an audit trail: UTC millisecond timestamps, start, steps, decisions (`DECISION:` and `CHANGE:` lines), and on failure the line, function and command | **Proven (auto)** | Enforced by the Bash standard checker; seen in run logs |
| OBS-02 | A whole run can be reconstructed as one ordered timeline | **Proven (manual)** | `run-with-log-folder.sh --merge`: 16 logs and 295 lines for one round trip (re-measured 2026-11-15), in millisecond order (it was 87 logs before the shared libraries) |
| OBS-03 | The failover test tells its own story: each SQL statement, the data returned, each script run, with time and script name | **Proven (auto)** | Output of `test-failover-roundtrip.sh` |
| ENG-01 | All shell scripts conform to the house Bash standard (version 7), shellcheck and syntax checks | **Proven (auto)** | `run-all-checks.sh`: `PASS lint` (22 files, including `runtime.sh`, which is checked word for word against the standard) |
| ENG-02 | All docker and database calls live in libraries; no script outside `lib/` runs `docker` or `psql`. The standard's own functions come from one shared `runtime.sh` | **Proven (manual)** | Search of `pg-replication/scripts/` found only usage text. 16 host scripts import `runtime.sh`; about 945 lines of duplicated function bodies were removed (2026-11-15) |
| ENG-03 | No secrets in the repository or its history; the database ports are not exposed to the network | **Proven (manual)** | 2026-11-14: pattern scan of all files and both commits found no tokens or keys (only the documented throwaway credentials); ports bound to `127.0.0.1` and **closed on the LAN address**, open on localhost |

## 4. Gaps: not proven yet

| ID | Gap | Why it matters | What would prove it |
|---|---|---|---|
| GAP-01 | **Observed RPO** under asynchronous replication: acknowledged writes missing on the surviving node after failover | The headline number for the async option | Write continuously, hard-kill the primary, promote, count missing acknowledged writes |
| GAP-02 | **Zero loss under synchronous replication** | RPO 0 is a claim, not yet a measurement | Same experiment with `sync` on; expect 0 missing |
| GAP-03 | **Fencing**: nothing stops a returning old primary except our own script | Real split-brain protection needs an epoch or token | Phase 2: fencing epoch; test with a plain `docker start` of the old primary |
| GAP-04 | **A true `pg_rewind` divergence** (old primary accepted writes the new one never saw) | Every test so far reported "no rewind required" | Write on the old primary after the split, then rejoin; check the rewound result |
| GAP-05 | **Observed RTO** from a client's view | The cost of each failure in seconds | A client-side prober measuring time to first success |
| GAP-06 | **Crash failures**: all stops so far are clean (`docker stop`) | `kill`, power loss and a crash during a transaction behave differently, and `pg_rewind` needs a cleanly stopped target | `docker kill` the primary and the standby, at several points |
| GAP-07 | **Automatic failure detection and failover** | Today a person decides and runs the script | Phase 2: failure detector and controller |
| GAP-08 | **Replica lag and the rule "decisions never read lagging replicas"** | A core design decision, untested | Induce lag; show a decision reads the primary only |
| GAP-09 | **Slot growth limit** (`max_slot_wal_keep_size=1GB`): a standby too far behind must be re-cloned | Disk-fill risk from a dead standby | Stop the standby, write past 1 GB, observe, re-clone |
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
