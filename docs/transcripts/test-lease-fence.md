# Transcript: A lease stops a writer that is cut off

<!-- toc -->

- [What to look for](#what-to-look-for)
- [Limit](#limit)
- [Output](#output)

<!-- tocstop -->

**Test:** [test-lease-fence.sh](../../pg-replication/scripts/test-lease-fence.sh)  
**Register rows:** LEASE-01  
**Run:** 2026-11-25, at commit 6becac0, on one machine. It took about 70 seconds.  
**Result:** the test exited with status 0.

## What to look for

- Step 2: with the controller cut off, the last accepted write came at 6,029 milliseconds and the guard then stopped the writer.
- Step 3 is the negative control. With no guard, the cut writer still accepted a write 13,770 milliseconds later. This shows that the test can see the fault.

## Limit

Safety is bought with availability. A controller outage longer than the lease stops a healthy writer.

## Output

The output is unedited. The timestamps and the log path are real. The credentials are throwaway values and do not appear.

```text
2026-11-25T15:17:06.024Z test-lease-fence.sh story: a lease and a guard fence the running writer pg-primary
2026-11-25T15:17:06.026Z test-lease-fence.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:17:06.309Z test-lease-fence.sh   => pg-primary is up
2026-11-25T15:17:06.310Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151706Z-99828.log
2026-11-25T15:17:06.550Z test-lease-fence.sh   => pg-standby is up
2026-11-25T15:17:06.551Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151706Z-99862.log
2026-11-25T15:17:07.073Z test-lease-fence.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:17:07.146Z test-lease-fence.sh   => ALTER SYSTEM
2026-11-25T15:17:07.208Z test-lease-fence.sh   => Asynchronous replication ON.
2026-11-25T15:17:08.300Z test-lease-fence.sh   =>  synchronous_standby_names 
2026-11-25T15:17:08.301Z test-lease-fence.sh   => ---------------------------
2026-11-25T15:17:08.302Z test-lease-fence.sh   =>  
2026-11-25T15:17:08.302Z test-lease-fence.sh   => (1 row)
2026-11-25T15:17:08.303Z test-lease-fence.sh   => 
2026-11-25T15:17:08.360Z test-lease-fence.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:17:08.362Z test-lease-fence.sh   => ------------------+-----------+------------
2026-11-25T15:17:08.363Z test-lease-fence.sh   =>  standby1         | streaming | async
2026-11-25T15:17:08.364Z test-lease-fence.sh   => (1 row)
2026-11-25T15:17:08.365Z test-lease-fence.sh   => 
2026-11-25T15:17:08.367Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151707Z-99918.log
2026-11-25T15:17:08.369Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151706Z-99809.log

2026-11-25T15:17:09.146Z test-lease-fence.sh == Step 1 of 3: a renewed lease keeps the writer accepting writes ==
2026-11-25T15:17:09.148Z test-lease-fence.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:17:09.419Z test-lease-fence.sh   => pg-primary is up
2026-11-25T15:17:09.420Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151709Z-99980.log
2026-11-25T15:17:09.663Z test-lease-fence.sh   => pg-standby is up
2026-11-25T15:17:09.664Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151709Z-107.log
2026-11-25T15:17:10.189Z test-lease-fence.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:17:10.262Z test-lease-fence.sh   => ALTER SYSTEM
2026-11-25T15:17:10.325Z test-lease-fence.sh   => Asynchronous replication ON.
2026-11-25T15:17:11.425Z test-lease-fence.sh   =>  synchronous_standby_names 
2026-11-25T15:17:11.427Z test-lease-fence.sh   => ---------------------------
2026-11-25T15:17:11.429Z test-lease-fence.sh   =>  
2026-11-25T15:17:11.431Z test-lease-fence.sh   => (1 row)
2026-11-25T15:17:11.432Z test-lease-fence.sh   => 
2026-11-25T15:17:11.495Z test-lease-fence.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:17:11.496Z test-lease-fence.sh   => ------------------+-----------+------------
2026-11-25T15:17:11.497Z test-lease-fence.sh   =>  standby1         | streaming | async
2026-11-25T15:17:11.498Z test-lease-fence.sh   => (1 row)
2026-11-25T15:17:11.499Z test-lease-fence.sh   => 
2026-11-25T15:17:11.502Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151710Z-163.log
2026-11-25T15:17:11.503Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151709Z-99961.log
2026-11-25T15:17:29.954Z test-lease-fence.sh last accepted write, first refused write (ms): 14808 0
2026-11-25T15:17:29.958Z test-lease-fence.sh PASS: refused writes (got '0')
2026-11-25T15:17:30.047Z test-lease-fence.sh lease seconds left: 6.0

2026-11-25T15:17:30.201Z test-lease-fence.sh == Step 2 of 3: the controller is cut off from a live writer: the guard stops the writer ==
2026-11-25T15:17:30.203Z test-lease-fence.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:17:30.491Z test-lease-fence.sh   => pg-primary is up
2026-11-25T15:17:30.492Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151730Z-499.log
2026-11-25T15:17:30.750Z test-lease-fence.sh   => pg-standby is up
2026-11-25T15:17:30.751Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151730Z-544.log
2026-11-25T15:17:31.285Z test-lease-fence.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:17:31.360Z test-lease-fence.sh   => ALTER SYSTEM
2026-11-25T15:17:31.425Z test-lease-fence.sh   => Asynchronous replication ON.
2026-11-25T15:17:32.501Z test-lease-fence.sh   =>  synchronous_standby_names 
2026-11-25T15:17:32.504Z test-lease-fence.sh   => ---------------------------
2026-11-25T15:17:32.506Z test-lease-fence.sh   =>  
2026-11-25T15:17:32.507Z test-lease-fence.sh   => (1 row)
2026-11-25T15:17:32.507Z test-lease-fence.sh   => 
2026-11-25T15:17:32.560Z test-lease-fence.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:17:32.561Z test-lease-fence.sh   => ------------------+-----------+------------
2026-11-25T15:17:32.561Z test-lease-fence.sh   =>  standby1         | streaming | async
2026-11-25T15:17:32.562Z test-lease-fence.sh   => (1 row)
2026-11-25T15:17:32.563Z test-lease-fence.sh   => 
2026-11-25T15:17:32.567Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151731Z-649.log
2026-11-25T15:17:32.569Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151730Z-477.log
NOTICE:  relation "fence_lease" already exists, skipping
2026-11-25T15:17:50.068Z test-lease-fence.sh last accepted write 6029 ms, first refused 6327 ms after the cut
2026-11-25T15:17:50.070Z test-lease-fence.sh guard log:
2026-11-25T15:17:50.109Z test-lease-fence.sh   => 2026-11-25T15:17:32.898Z DECISION guard started: poll every 0.5 s
2026-11-25T15:17:50.111Z test-lease-fence.sh   => 2026-11-25T15:17:42.447Z DECISION fencing: the lease has run out, stopping the node
2026-11-25T15:17:50.112Z test-lease-fence.sh   => 2026-11-25T15:17:42.451Z the node went down while it was being stopped
2026-11-25T15:17:50.116Z test-lease-fence.sh PASS: last accepted write (ms): 6029 (limits 0 to 9000)
2026-11-25T15:17:50.147Z test-lease-fence.sh container::is_running pg-primary => false
2026-11-25T15:17:50.149Z test-lease-fence.sh PASS: pg-primary is stopped (got 'false')

2026-11-25T15:17:50.474Z test-lease-fence.sh == Step 3 of 3: control, no guard: the cut writer keeps accepting writes after its lease ran out ==
2026-11-25T15:17:50.476Z test-lease-fence.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:17:50.645Z test-lease-fence.sh   => pg-standby is up
2026-11-25T15:17:50.646Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151750Z-1054.log
2026-11-25T15:17:53.201Z test-lease-fence.sh   => pg-primary is up
2026-11-25T15:17:53.202Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151750Z-1079.log
2026-11-25T15:17:53.528Z test-lease-fence.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:17:53.602Z test-lease-fence.sh   => ALTER SYSTEM
2026-11-25T15:17:53.675Z test-lease-fence.sh   => Asynchronous replication ON.
2026-11-25T15:17:54.781Z test-lease-fence.sh   =>  synchronous_standby_names 
2026-11-25T15:17:54.783Z test-lease-fence.sh   => ---------------------------
2026-11-25T15:17:54.784Z test-lease-fence.sh   =>  
2026-11-25T15:17:54.785Z test-lease-fence.sh   => (1 row)
2026-11-25T15:17:54.786Z test-lease-fence.sh   => 
2026-11-25T15:17:54.844Z test-lease-fence.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:17:54.845Z test-lease-fence.sh   => ------------------+-----------+------------
2026-11-25T15:17:54.846Z test-lease-fence.sh   =>  standby1         | streaming | async
2026-11-25T15:17:54.847Z test-lease-fence.sh   => (1 row)
2026-11-25T15:17:54.847Z test-lease-fence.sh   => 
2026-11-25T15:17:54.851Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151753Z-1159.log
2026-11-25T15:17:54.853Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151750Z-1032.log
NOTICE:  relation "fence_lease" already exists, skipping
2026-11-25T15:18:12.264Z test-lease-fence.sh last accepted write, first refused write (ms): 13770 0
2026-11-25T15:18:12.357Z test-lease-fence.sh lease seconds left: -9.2
2026-11-25T15:18:12.359Z test-lease-fence.sh PASS: refused writes (got '0')
2026-11-25T15:18:12.360Z test-lease-fence.sh PASS: last accepted write (ms): 13770 (limits 12000 to 16000)
2026-11-25T15:18:12.643Z test-lease-fence.sh PASS: all 3 steps passed
2026-11-25T15:18:12.645Z test-lease-fence.sh == Cleanup: remove controller and guard, heal, restore the starting state ==
2026-11-25T15:18:12.809Z test-lease-fence.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:18:13.094Z test-lease-fence.sh   => pg-primary is up
2026-11-25T15:18:13.095Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151812Z-1501.log
2026-11-25T15:18:13.340Z test-lease-fence.sh   => pg-standby is up
2026-11-25T15:18:13.341Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151813Z-1530.log
2026-11-25T15:18:13.898Z test-lease-fence.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:18:13.979Z test-lease-fence.sh   => ALTER SYSTEM
2026-11-25T15:18:14.044Z test-lease-fence.sh   => Asynchronous replication ON.
2026-11-25T15:18:15.132Z test-lease-fence.sh   =>  synchronous_standby_names 
2026-11-25T15:18:15.133Z test-lease-fence.sh   => ---------------------------
2026-11-25T15:18:15.134Z test-lease-fence.sh   =>  
2026-11-25T15:18:15.135Z test-lease-fence.sh   => (1 row)
2026-11-25T15:18:15.135Z test-lease-fence.sh   => 
2026-11-25T15:18:15.190Z test-lease-fence.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:18:15.191Z test-lease-fence.sh   => ------------------+-----------+------------
2026-11-25T15:18:15.192Z test-lease-fence.sh   =>  standby1         | streaming | async
2026-11-25T15:18:15.192Z test-lease-fence.sh   => (1 row)
2026-11-25T15:18:15.193Z test-lease-fence.sh   => 
2026-11-25T15:18:15.197Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151813Z-1611.log
2026-11-25T15:18:15.198Z test-lease-fence.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151812Z-1480.log
NOTICE:  function fence_check() does not exist, skipping
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//test-lease-fence.sh-20261125T151706Z-99799.log
```
