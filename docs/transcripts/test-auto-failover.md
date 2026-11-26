# Transcript: Automatic failover

<!-- toc -->

- [What to look for](#what-to-look-for)
- [Limit](#limit)
- [Output](#output)

<!-- tocstop -->

**Test:** [test-auto-failover.sh](../../pg-replication/scripts/test-auto-failover.sh)  
**Register rows:** ACT-01, DET-01  
**Run:** 2026-11-25, at commit 6becac0, on one machine. It took about 62 seconds.  
**Result:** the test exited with status 0.

## What to look for

- Step 1: a freeze shorter than the threshold causes no action, and the epoch stays 0.
- Step 2: after a crash, a client write succeeded on the new writer after 2,914 milliseconds. The epoch is 1, and the old writer is stopped.
- Step 3: after a hung writer, the first successful write came after 7,223 milliseconds. Detection is most of that time.

## Limit

The load is a heartbeat and not payments. The epoch is a file on the host, and no node checks it (GAP-03).

## Output

The output is unedited. The timestamps and the log path are real. The credentials are throwaway values and do not appear.

```text
2026-11-25T15:16:03.500Z test-auto-failover.sh story: automatic failover of pg-primary
2026-11-25T15:16:03.501Z test-auto-failover.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:16:03.797Z test-auto-failover.sh   => pg-primary is up
2026-11-25T15:16:03.798Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151603Z-98300.log
2026-11-25T15:16:04.059Z test-auto-failover.sh   => pg-standby is up
2026-11-25T15:16:04.060Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151603Z-98328.log
2026-11-25T15:16:04.619Z test-auto-failover.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:16:04.699Z test-auto-failover.sh   => ALTER SYSTEM
2026-11-25T15:16:04.766Z test-auto-failover.sh   => Asynchronous replication ON.
2026-11-25T15:16:05.866Z test-auto-failover.sh   =>  synchronous_standby_names 
2026-11-25T15:16:05.868Z test-auto-failover.sh   => ---------------------------
2026-11-25T15:16:05.870Z test-auto-failover.sh   =>  
2026-11-25T15:16:05.872Z test-auto-failover.sh   => (1 row)
2026-11-25T15:16:05.873Z test-auto-failover.sh   => 
2026-11-25T15:16:05.932Z test-auto-failover.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:16:05.933Z test-auto-failover.sh   => ------------------+-----------+------------
2026-11-25T15:16:05.933Z test-auto-failover.sh   =>  standby1         | streaming | async
2026-11-25T15:16:05.934Z test-auto-failover.sh   => (1 row)
2026-11-25T15:16:05.935Z test-auto-failover.sh   => 
2026-11-25T15:16:05.938Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151604Z-98384.log
2026-11-25T15:16:05.940Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151603Z-98281.log

2026-11-25T15:16:06.588Z test-auto-failover.sh == Step 1 of 3: a freeze shorter than the threshold: the actor does nothing ==
2026-11-25T15:16:10.881Z test-auto-failover.sh RUN env EPOCH_FILE=/var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//failover-epoch.pxNT7Z/epoch WAIT_SECONDS=15 ACTOR_CRASH_AFTER=none bash scripts/act-on-failover.sh --controller auto-controller 
2026-11-25T15:16:26.717Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//act-on-failover.sh-20261125T151610Z-98440.log
2026-11-25T15:16:26.723Z test-auto-failover.sh PASS: the epoch (got '0')
2026-11-25T15:16:26.820Z test-auto-failover.sh PASS: pg-primary in recovery (got 'f')

2026-11-25T15:16:26.997Z test-auto-failover.sh == Step 2 of 3: a crashed writer: fenced, promoted, timed ==
2026-11-25T15:16:26.999Z test-auto-failover.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:16:27.298Z test-auto-failover.sh   => pg-primary is up
2026-11-25T15:16:27.300Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151627Z-98626.log
2026-11-25T15:16:27.547Z test-auto-failover.sh   => pg-standby is up
2026-11-25T15:16:27.548Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151627Z-98652.log
2026-11-25T15:16:28.098Z test-auto-failover.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:16:28.174Z test-auto-failover.sh   => ALTER SYSTEM
2026-11-25T15:16:28.238Z test-auto-failover.sh   => Asynchronous replication ON.
2026-11-25T15:16:29.342Z test-auto-failover.sh   =>  synchronous_standby_names 
2026-11-25T15:16:29.344Z test-auto-failover.sh   => ---------------------------
2026-11-25T15:16:29.346Z test-auto-failover.sh   =>  
2026-11-25T15:16:29.348Z test-auto-failover.sh   => (1 row)
2026-11-25T15:16:29.351Z test-auto-failover.sh   => 
2026-11-25T15:16:29.414Z test-auto-failover.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:16:29.415Z test-auto-failover.sh   => ------------------+-----------+------------
2026-11-25T15:16:29.416Z test-auto-failover.sh   =>  standby1         | streaming | async
2026-11-25T15:16:29.417Z test-auto-failover.sh   => (1 row)
2026-11-25T15:16:29.418Z test-auto-failover.sh   => 
2026-11-25T15:16:29.422Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151628Z-98716.log
2026-11-25T15:16:29.424Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151627Z-98607.log
2026-11-25T15:16:31.615Z test-auto-failover.sh RUN env EPOCH_FILE=/var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//failover-epoch.pxNT7Z/epoch WAIT_SECONDS=15 ACTOR_CRASH_AFTER=none bash scripts/act-on-failover.sh --controller auto-controller 
2026-11-25T15:16:33.867Z test-auto-failover.sh   => failing over at epoch 1
2026-11-25T15:16:34.193Z test-auto-failover.sh   => Promoting pg-standby ...
2026-11-25T15:16:34.513Z test-auto-failover.sh   => in recovery: f (expect f)
2026-11-25T15:16:34.514Z test-auto-failover.sh   => timeline:    650 (was 1 before promotion)
2026-11-25T15:16:34.515Z test-auto-failover.sh   => 
2026-11-25T15:16:34.515Z test-auto-failover.sh   => pg-standby is now the writable primary.
2026-11-25T15:16:34.516Z test-auto-failover.sh   => Do NOT restart the old primary as-is: it must be rebuilt or rewound (pg_rewind) as a standby first.
2026-11-25T15:16:34.517Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-standby-to-primary.sh-20261125T151633Z-98829.log
2026-11-25T15:16:34.518Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//act-on-failover.sh-20261125T151631Z-98758.log
2026-11-25T15:16:34.528Z test-auto-failover.sh time from the fault to a successful client write: 2914 ms
2026-11-25T15:16:34.529Z test-auto-failover.sh PASS: observed RTO (ms): 2914 (limits 1000 to 20000)
2026-11-25T15:16:34.531Z test-auto-failover.sh PASS: the epoch (got '1')
2026-11-25T15:16:34.588Z test-auto-failover.sh PASS: pg-standby in recovery (got 'f')
2026-11-25T15:16:34.611Z test-auto-failover.sh container::is_running pg-primary => false
2026-11-25T15:16:34.616Z test-auto-failover.sh PASS: pg-primary is stopped (got 'false')

2026-11-25T15:16:34.756Z test-auto-failover.sh == Step 3 of 3: a hung writer: killed, promoted, timed ==
2026-11-25T15:16:34.758Z test-auto-failover.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:16:34.930Z test-auto-failover.sh   => pg-standby is up
2026-11-25T15:16:34.931Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151634Z-98897.log
2026-11-25T15:16:35.619Z test-auto-failover.sh   => pg_rewind: connected to server
2026-11-25T15:16:35.631Z test-auto-failover.sh   => pg_rewind: executing "/usr/lib/postgresql/16/bin/postgres" for target server to complete crash recovery
2026-11-25T15:16:35.636Z test-auto-failover.sh   => 2026-11-25 15:16:35.635 UTC [10] FATAL:  lock file "postmaster.pid" already exists
2026-11-25T15:16:35.637Z test-auto-failover.sh   => 2026-11-25 15:16:35.635 UTC [10] HINT:  Is another postmaster (PID 1) running in data directory "/var/lib/postgresql/data"?
2026-11-25T15:16:35.637Z test-auto-failover.sh   => pg_rewind: error: postgres single-user mode in target cluster failed
2026-11-25T15:16:35.638Z test-auto-failover.sh   => pg_rewind: detail: Command was: /usr/lib/postgresql/16/bin/postgres --single -F -D /var/lib/postgresql/data template1 < /dev/null
2026-11-25T15:16:35.731Z test-auto-failover.sh   => promote-primary-to-standby.sh: 2026-11-25T15:16:35.730Z WARN DECISION: pg_rewind of pg-primary failed: cloning it instead
2026-11-25T15:16:39.299Z test-auto-failover.sh   => pg-primary is up
2026-11-25T15:16:39.300Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151636Z-98990.log
2026-11-25T15:16:39.425Z test-auto-failover.sh   => pg-primary in recovery: t (expect t)
2026-11-25T15:16:39.427Z test-auto-failover.sh   => pg-primary is now a standby of pg-standby
2026-11-25T15:16:39.427Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-primary-to-standby.sh-20261125T151635Z-98922.log
2026-11-25T15:16:39.678Z test-auto-failover.sh   => pg-standby is down
2026-11-25T15:16:39.679Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-down-database.sh-20261125T151639Z-99036.log
2026-11-25T15:16:39.979Z test-auto-failover.sh   => Promoting pg-primary ...
2026-11-25T15:16:40.288Z test-auto-failover.sh   => in recovery: f (expect f)
2026-11-25T15:16:40.290Z test-auto-failover.sh   => timeline:    651 (was 1 before promotion)
2026-11-25T15:16:40.291Z test-auto-failover.sh   => 
2026-11-25T15:16:40.292Z test-auto-failover.sh   => pg-primary is now the writable primary.
2026-11-25T15:16:40.292Z test-auto-failover.sh   => Do NOT restart the old primary as-is: it must be rebuilt or rewound (pg_rewind) as a standby first.
2026-11-25T15:16:40.293Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-standby-to-primary.sh-20261125T151639Z-99050.log
2026-11-25T15:16:40.873Z test-auto-failover.sh   => pg_rewind: connected to server
2026-11-25T15:16:40.875Z test-auto-failover.sh   => pg_rewind: servers diverged at WAL location 3/970000A0 on timeline 650
2026-11-25T15:16:40.876Z test-auto-failover.sh   => pg_rewind: no rewind required
2026-11-25T15:16:43.794Z test-auto-failover.sh   => pg-standby is up
2026-11-25T15:16:43.795Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151641Z-99132.log
2026-11-25T15:16:43.922Z test-auto-failover.sh   => pg-standby in recovery: t (expect t)
2026-11-25T15:16:43.923Z test-auto-failover.sh   => pg-standby is now a standby of pg-primary
2026-11-25T15:16:43.924Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-primary-to-standby.sh-20261125T151640Z-99085.log
2026-11-25T15:16:44.249Z test-auto-failover.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:16:44.323Z test-auto-failover.sh   => ALTER SYSTEM
2026-11-25T15:16:44.387Z test-auto-failover.sh   => Asynchronous replication ON.
2026-11-25T15:16:45.476Z test-auto-failover.sh   =>  synchronous_standby_names 
2026-11-25T15:16:45.478Z test-auto-failover.sh   => ---------------------------
2026-11-25T15:16:45.481Z test-auto-failover.sh   =>  
2026-11-25T15:16:45.482Z test-auto-failover.sh   => (1 row)
2026-11-25T15:16:45.484Z test-auto-failover.sh   => 
2026-11-25T15:16:45.543Z test-auto-failover.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:16:45.545Z test-auto-failover.sh   => ------------------+-----------+------------
2026-11-25T15:16:45.546Z test-auto-failover.sh   =>  standby1         | streaming | async
2026-11-25T15:16:45.547Z test-auto-failover.sh   => (1 row)
2026-11-25T15:16:45.547Z test-auto-failover.sh   => 
2026-11-25T15:16:45.550Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151644Z-99206.log
2026-11-25T15:16:45.551Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151634Z-98876.log
2026-11-25T15:16:47.739Z test-auto-failover.sh RUN env EPOCH_FILE=/var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//failover-epoch.pxNT7Z/epoch WAIT_SECONDS=15 ACTOR_CRASH_AFTER=none bash scripts/act-on-failover.sh --controller auto-controller 
2026-11-25T15:16:54.189Z test-auto-failover.sh   => failing over at epoch 1
2026-11-25T15:16:54.680Z test-auto-failover.sh   => Promoting pg-standby ...
2026-11-25T15:16:54.996Z test-auto-failover.sh   => in recovery: f (expect f)
2026-11-25T15:16:54.997Z test-auto-failover.sh   => timeline:    652 (was 1 before promotion)
2026-11-25T15:16:54.998Z test-auto-failover.sh   => 
2026-11-25T15:16:54.998Z test-auto-failover.sh   => pg-standby is now the writable primary.
2026-11-25T15:16:54.999Z test-auto-failover.sh   => Do NOT restart the old primary as-is: it must be rebuilt or rewound (pg_rewind) as a standby first.
2026-11-25T15:16:55.000Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-standby-to-primary.sh-20261125T151654Z-99402.log
2026-11-25T15:16:55.002Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//act-on-failover.sh-20261125T151647Z-99237.log
2026-11-25T15:16:55.003Z test-auto-failover.sh time from the fault to a successful client write: 7223 ms
2026-11-25T15:16:55.004Z test-auto-failover.sh PASS: observed RTO (ms): 7223 (limits 1000 to 20000)
2026-11-25T15:16:55.006Z test-auto-failover.sh PASS: the epoch (got '1')
2026-11-25T15:16:55.064Z test-auto-failover.sh PASS: pg-standby in recovery (got 'f')
2026-11-25T15:16:55.088Z test-auto-failover.sh container::is_running pg-primary => false
2026-11-25T15:16:55.089Z test-auto-failover.sh PASS: pg-primary is stopped (got 'false')
2026-11-25T15:16:55.222Z test-auto-failover.sh PASS: all 3 steps passed
2026-11-25T15:16:55.224Z test-auto-failover.sh == Cleanup: remove the controller, heal faults, restore the starting state ==
2026-11-25T15:16:55.286Z test-auto-failover.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:16:55.451Z test-auto-failover.sh   => pg-standby is up
2026-11-25T15:16:55.452Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151655Z-99472.log
2026-11-25T15:16:56.140Z test-auto-failover.sh   => pg_rewind: connected to server
2026-11-25T15:16:56.155Z test-auto-failover.sh   => pg_rewind: executing "/usr/lib/postgresql/16/bin/postgres" for target server to complete crash recovery
2026-11-25T15:16:56.162Z test-auto-failover.sh   => 2026-11-25 15:16:56.161 UTC [10] FATAL:  lock file "postmaster.pid" already exists
2026-11-25T15:16:56.164Z test-auto-failover.sh   => 2026-11-25 15:16:56.161 UTC [10] HINT:  Is another postmaster (PID 1) running in data directory "/var/lib/postgresql/data"?
2026-11-25T15:16:56.166Z test-auto-failover.sh   => pg_rewind: error: postgres single-user mode in target cluster failed
2026-11-25T15:16:56.166Z test-auto-failover.sh   => pg_rewind: detail: Command was: /usr/lib/postgresql/16/bin/postgres --single -F -D /var/lib/postgresql/data template1 < /dev/null
2026-11-25T15:16:56.244Z test-auto-failover.sh   => promote-primary-to-standby.sh: 2026-11-25T15:16:56.242Z WARN DECISION: pg_rewind of pg-primary failed: cloning it instead
2026-11-25T15:16:59.693Z test-auto-failover.sh   => pg-primary is up
2026-11-25T15:16:59.695Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151657Z-99565.log
2026-11-25T15:16:59.818Z test-auto-failover.sh   => pg-primary in recovery: t (expect t)
2026-11-25T15:16:59.819Z test-auto-failover.sh   => pg-primary is now a standby of pg-standby
2026-11-25T15:16:59.820Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-primary-to-standby.sh-20261125T151655Z-99497.log
2026-11-25T15:17:00.058Z test-auto-failover.sh   => pg-standby is down
2026-11-25T15:17:00.059Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-down-database.sh-20261125T151659Z-99611.log
2026-11-25T15:17:00.372Z test-auto-failover.sh   => Promoting pg-primary ...
2026-11-25T15:17:00.677Z test-auto-failover.sh   => in recovery: f (expect f)
2026-11-25T15:17:00.678Z test-auto-failover.sh   => timeline:    653 (was 1 before promotion)
2026-11-25T15:17:00.679Z test-auto-failover.sh   => 
2026-11-25T15:17:00.680Z test-auto-failover.sh   => pg-primary is now the writable primary.
2026-11-25T15:17:00.681Z test-auto-failover.sh   => Do NOT restart the old primary as-is: it must be rebuilt or rewound (pg_rewind) as a standby first.
2026-11-25T15:17:00.681Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-standby-to-primary.sh-20261125T151700Z-99625.log
2026-11-25T15:17:01.271Z test-auto-failover.sh   => pg_rewind: connected to server
2026-11-25T15:17:01.277Z test-auto-failover.sh   => pg_rewind: servers diverged at WAL location 3/990000A0 on timeline 652
2026-11-25T15:17:01.279Z test-auto-failover.sh   => pg_rewind: no rewind required
2026-11-25T15:17:04.232Z test-auto-failover.sh   => pg-standby is up
2026-11-25T15:17:04.233Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151701Z-99707.log
2026-11-25T15:17:04.354Z test-auto-failover.sh   => pg-standby in recovery: t (expect t)
2026-11-25T15:17:04.355Z test-auto-failover.sh   => pg-standby is now a standby of pg-primary
2026-11-25T15:17:04.356Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-primary-to-standby.sh-20261125T151700Z-99660.log
2026-11-25T15:17:04.680Z test-auto-failover.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:17:04.754Z test-auto-failover.sh   => ALTER SYSTEM
2026-11-25T15:17:04.819Z test-auto-failover.sh   => Asynchronous replication ON.
2026-11-25T15:17:05.914Z test-auto-failover.sh   =>  synchronous_standby_names 
2026-11-25T15:17:05.916Z test-auto-failover.sh   => ---------------------------
2026-11-25T15:17:05.918Z test-auto-failover.sh   =>  
2026-11-25T15:17:05.919Z test-auto-failover.sh   => (1 row)
2026-11-25T15:17:05.920Z test-auto-failover.sh   => 
2026-11-25T15:17:05.975Z test-auto-failover.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:17:05.976Z test-auto-failover.sh   => ------------------+-----------+------------
2026-11-25T15:17:05.977Z test-auto-failover.sh   =>  standby1         | streaming | async
2026-11-25T15:17:05.978Z test-auto-failover.sh   => (1 row)
2026-11-25T15:17:05.978Z test-auto-failover.sh   => 
2026-11-25T15:17:05.982Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151704Z-99781.log
2026-11-25T15:17:05.984Z test-auto-failover.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151655Z-99451.log
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//test-auto-failover.sh-20261125T151603Z-98269.log
```
