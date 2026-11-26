# Transcript: Replication modes

<!-- toc -->

- [What to look for](#what-to-look-for)
- [Limit](#limit)
- [Output](#output)

<!-- tocstop -->

**Test:** [test-replication-modes.sh](../../pg-replication/scripts/test-replication-modes.sh)  
**Register rows:** REP-04, REP-05, REP-06  
**Run:** 2026-11-25, at commit 6becac0, on one machine. It took about 30 seconds.  
**Result:** the test exited with status 0.

## What to look for

- Step 2: an asynchronous commit took 59 milliseconds with the standby stopped. The slot read `f|reserved`, so it was inactive but still holding the log.
- Step 3: a synchronous commit was still waiting after 5 seconds and completed after 7.6 seconds, when the standby returned.
- Step 4: after the standby was killed during a commit, all 3 acknowledged rows were on the standby.

## Limit

The last assertion shows that the cleanup left `synchronous_standby_names` empty. An earlier version of the restore did not do that, and the next test hung. The evidence log describes the defect.

## Output

The output is unedited. The timestamps and the log path are real. The credentials are throwaway values and do not appear.

```text
2026-11-25T15:15:07.624Z test-replication-modes.sh story: replication modes, the standby down and killed
2026-11-25T15:15:07.626Z test-replication-modes.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:15:07.951Z test-replication-modes.sh   => pg-primary is up
2026-11-25T15:15:07.952Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151507Z-96913.log
2026-11-25T15:15:08.207Z test-replication-modes.sh   => pg-standby is up
2026-11-25T15:15:08.208Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151507Z-96939.log
2026-11-25T15:15:08.755Z test-replication-modes.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:15:08.828Z test-replication-modes.sh   => ALTER SYSTEM
2026-11-25T15:15:08.892Z test-replication-modes.sh   => Asynchronous replication ON.
2026-11-25T15:15:09.990Z test-replication-modes.sh   =>  synchronous_standby_names 
2026-11-25T15:15:09.993Z test-replication-modes.sh   => ---------------------------
2026-11-25T15:15:09.995Z test-replication-modes.sh   =>  
2026-11-25T15:15:09.997Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:09.999Z test-replication-modes.sh   => 
2026-11-25T15:15:10.063Z test-replication-modes.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:15:10.065Z test-replication-modes.sh   => ------------------+-----------+------------
2026-11-25T15:15:10.067Z test-replication-modes.sh   =>  standby1         | streaming | async
2026-11-25T15:15:10.068Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:10.069Z test-replication-modes.sh   => 
2026-11-25T15:15:10.073Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151508Z-97006.log
2026-11-25T15:15:10.075Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151507Z-96894.log

2026-11-25T15:15:10.076Z test-replication-modes.sh == Step 1 of 4: the mode is switched with no restart ==
2026-11-25T15:15:10.140Z test-replication-modes.sh RUN bash scripts/set-replication-mode.sh --mode sync 
2026-11-25T15:15:10.218Z test-replication-modes.sh   => ALTER SYSTEM
2026-11-25T15:15:10.286Z test-replication-modes.sh   => Synchronous replication ON. Writes will block if the standby is unavailable.
2026-11-25T15:15:11.384Z test-replication-modes.sh   =>  synchronous_standby_names 
2026-11-25T15:15:11.387Z test-replication-modes.sh   => ---------------------------
2026-11-25T15:15:11.389Z test-replication-modes.sh   =>  FIRST 1 (standby1)
2026-11-25T15:15:11.390Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:11.391Z test-replication-modes.sh   => 
2026-11-25T15:15:11.450Z test-replication-modes.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:15:11.451Z test-replication-modes.sh   => ------------------+-----------+------------
2026-11-25T15:15:11.451Z test-replication-modes.sh   =>  standby1         | streaming | sync
2026-11-25T15:15:11.452Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:11.453Z test-replication-modes.sh   => 
2026-11-25T15:15:11.456Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151510Z-97032.log
2026-11-25T15:15:11.517Z test-replication-modes.sh PASS: sync_state after sync (got 'sync')
2026-11-25T15:15:11.519Z test-replication-modes.sh RUN bash scripts/set-replication-mode.sh --mode async 
2026-11-25T15:15:11.596Z test-replication-modes.sh   => ALTER SYSTEM
2026-11-25T15:15:11.659Z test-replication-modes.sh   => Asynchronous replication ON.
2026-11-25T15:15:12.742Z test-replication-modes.sh   =>  synchronous_standby_names 
2026-11-25T15:15:12.743Z test-replication-modes.sh   => ---------------------------
2026-11-25T15:15:12.744Z test-replication-modes.sh   =>  
2026-11-25T15:15:12.745Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:12.746Z test-replication-modes.sh   => 
2026-11-25T15:15:12.804Z test-replication-modes.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:15:12.806Z test-replication-modes.sh   => ------------------+-----------+------------
2026-11-25T15:15:12.807Z test-replication-modes.sh   =>  standby1         | streaming | async
2026-11-25T15:15:12.807Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:12.808Z test-replication-modes.sh   => 
2026-11-25T15:15:12.811Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151511Z-97052.log
2026-11-25T15:15:12.872Z test-replication-modes.sh PASS: sync_state after async (got 'async')
2026-11-25T15:15:12.929Z test-replication-modes.sh PASS: the writer was not restarted by either switch (got '0')

2026-11-25T15:15:12.930Z test-replication-modes.sh == Step 2 of 4: asynchronous, standby stopped: commits go on and the standby catches up ==
NOTICE:  table "mode_probe" does not exist, skipping
2026-11-25T15:15:12.990Z test-replication-modes.sh RUN bash scripts/set-replication-mode.sh --mode async 
2026-11-25T15:15:13.070Z test-replication-modes.sh   => ALTER SYSTEM
2026-11-25T15:15:13.133Z test-replication-modes.sh   => Asynchronous replication ON.
2026-11-25T15:15:14.234Z test-replication-modes.sh   =>  synchronous_standby_names 
2026-11-25T15:15:14.235Z test-replication-modes.sh   => ---------------------------
2026-11-25T15:15:14.237Z test-replication-modes.sh   =>  
2026-11-25T15:15:14.238Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:14.239Z test-replication-modes.sh   => 
2026-11-25T15:15:14.299Z test-replication-modes.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:15:14.301Z test-replication-modes.sh   => ------------------+-----------+------------
2026-11-25T15:15:14.302Z test-replication-modes.sh   =>  standby1         | streaming | async
2026-11-25T15:15:14.303Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:14.304Z test-replication-modes.sh   => 
2026-11-25T15:15:14.307Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151513Z-97081.log
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-down-database.sh-20261125T151514Z-97106.log
2026-11-25T15:15:14.580Z test-replication-modes.sh a commit with the standby stopped took 59 ms
2026-11-25T15:15:14.582Z test-replication-modes.sh PASS: async: the commit is not held up: 59 (limits 0 to 1000)
2026-11-25T15:15:14.637Z test-replication-modes.sh PASS: slot inactive, still reserving WAL (got 'f|reserved')
pg-standby is up
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151514Z-97125.log
2026-11-25T15:15:17.191Z test-replication-modes.sh PASS: the standby has the row written while it was down (got '1')

2026-11-25T15:15:17.192Z test-replication-modes.sh == Step 3 of 4: synchronous, standby stopped: a commit blocks until the standby returns ==
2026-11-25T15:15:17.193Z test-replication-modes.sh RUN bash scripts/set-replication-mode.sh --mode sync 
2026-11-25T15:15:17.268Z test-replication-modes.sh   => ALTER SYSTEM
2026-11-25T15:15:17.331Z test-replication-modes.sh   => Synchronous replication ON. Writes will block if the standby is unavailable.
2026-11-25T15:15:18.420Z test-replication-modes.sh   =>  synchronous_standby_names 
2026-11-25T15:15:18.421Z test-replication-modes.sh   => ---------------------------
2026-11-25T15:15:18.423Z test-replication-modes.sh   =>  FIRST 1 (standby1)
2026-11-25T15:15:18.424Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:18.425Z test-replication-modes.sh   => 
2026-11-25T15:15:18.487Z test-replication-modes.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:15:18.488Z test-replication-modes.sh   => ------------------+-----------+------------
2026-11-25T15:15:18.489Z test-replication-modes.sh   =>  standby1         | streaming | sync
2026-11-25T15:15:18.490Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:18.491Z test-replication-modes.sh   => 
2026-11-25T15:15:18.494Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151517Z-97169.log
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-down-database.sh-20261125T151518Z-97194.log
pg-standby is up
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151523Z-97232.log
2026-11-25T15:15:26.257Z test-replication-modes.sh PASS: the commit was still waiting after 5 s (got 'waiting')
2026-11-25T15:15:26.259Z test-replication-modes.sh the commit completed 7561 ms after it started, when the standby returned
2026-11-25T15:15:26.260Z test-replication-modes.sh PASS: sync: the commit waited for the standby: 7561 (limits 5000 to 60000)
2026-11-25T15:15:26.316Z test-replication-modes.sh PASS: the standby has the row (got '2')

2026-11-25T15:15:26.317Z test-replication-modes.sh == Step 4 of 4: synchronous, standby killed during a commit: no acknowledged row is lost ==
2026-11-25T15:15:26.319Z test-replication-modes.sh RUN bash scripts/set-replication-mode.sh --mode sync 
2026-11-25T15:15:26.394Z test-replication-modes.sh   => ALTER SYSTEM
2026-11-25T15:15:26.464Z test-replication-modes.sh   => Synchronous replication ON. Writes will block if the standby is unavailable.
2026-11-25T15:15:27.561Z test-replication-modes.sh   =>  synchronous_standby_names 
2026-11-25T15:15:27.563Z test-replication-modes.sh   => ---------------------------
2026-11-25T15:15:27.565Z test-replication-modes.sh   =>  FIRST 1 (standby1)
2026-11-25T15:15:27.566Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:27.568Z test-replication-modes.sh   => 
2026-11-25T15:15:27.631Z test-replication-modes.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:15:27.632Z test-replication-modes.sh   => ------------------+-----------+------------
2026-11-25T15:15:27.633Z test-replication-modes.sh   =>  standby1         | streaming | sync
2026-11-25T15:15:27.634Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:27.635Z test-replication-modes.sh   => 
2026-11-25T15:15:27.638Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151526Z-97277.log
pg-standby is up
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151532Z-97328.log
2026-11-25T15:15:35.307Z test-replication-modes.sh PASS: the commit waited while the standby was dead (got 'waiting')
2026-11-25T15:15:35.364Z test-replication-modes.sh PASS: acknowledged rows on the standby, none missing (got '3')
2026-11-25T15:15:35.365Z test-replication-modes.sh PASS: all 4 steps passed
2026-11-25T15:15:35.366Z test-replication-modes.sh == Cleanup: restore the starting state (asynchronous) ==
2026-11-25T15:15:35.369Z test-replication-modes.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:15:35.664Z test-replication-modes.sh   => pg-primary is up
2026-11-25T15:15:35.665Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151535Z-97393.log
2026-11-25T15:15:35.917Z test-replication-modes.sh   => pg-standby is up
2026-11-25T15:15:35.918Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151535Z-97419.log
2026-11-25T15:15:36.484Z test-replication-modes.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:15:36.559Z test-replication-modes.sh   => ALTER SYSTEM
2026-11-25T15:15:36.630Z test-replication-modes.sh   => Asynchronous replication ON.
2026-11-25T15:15:37.729Z test-replication-modes.sh   =>  synchronous_standby_names 
2026-11-25T15:15:37.732Z test-replication-modes.sh   => ---------------------------
2026-11-25T15:15:37.733Z test-replication-modes.sh   =>  
2026-11-25T15:15:37.734Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:37.735Z test-replication-modes.sh   => 
2026-11-25T15:15:37.797Z test-replication-modes.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:15:37.798Z test-replication-modes.sh   => ------------------+-----------+------------
2026-11-25T15:15:37.799Z test-replication-modes.sh   =>  standby1         | streaming | async
2026-11-25T15:15:37.800Z test-replication-modes.sh   => (1 row)
2026-11-25T15:15:37.800Z test-replication-modes.sh   => 
2026-11-25T15:15:37.805Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151536Z-97475.log
2026-11-25T15:15:37.807Z test-replication-modes.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151535Z-97374.log
2026-11-25T15:15:37.866Z test-replication-modes.sh SQL on pg-primary: show synchronous_standby_names
2026-11-25T15:15:37.868Z test-replication-modes.sh   => (no rows)
2026-11-25T15:15:37.869Z test-replication-modes.sh PASS: pg-primary returned the expected data (got '')
2026-11-25T15:15:37.870Z test-replication-modes.sh SQL on pg-primary: drop table if exists mode_probe
2026-11-25T15:15:37.923Z test-replication-modes.sh   => DROP TABLE
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//test-replication-modes.sh-20261125T151507Z-96881.log
```
