# Transcript: A true divergence is rewound

**Test:** [test-divergence-rewind.sh](../../pg-replication/scripts/test-divergence-rewind.sh)  
**Register rows:** FOV-09  
**Run:** 2026-11-25, at commit 6becac0, on one machine. It took about 26 seconds.  
**Result:** the test exited with status 0.

## What to look for

- Step 3: the old primary acknowledged three writes, `lost-1` to `lost-3`, that the standby never received.
- Step 5: the two nodes hold different histories. The new writer holds `kept-1` and `kept-2`.
- Step 7: pg_rewind says that the servers diverged and does a real rewind. The node is not cloned.
- Step 9: the three acknowledged writes are gone and both nodes hold the same rows. That loss is the cost of asynchronous replication.

## Limit

The fault is staged by clearing the standby's connection setting, not by a network fault.

## Output

The output is unedited. The timestamps and the log path are real. The credentials are throwaway values and do not appear.

```text
2026-11-25T15:15:37.971Z test-divergence-rewind.sh story: divergence and pg_rewind on pg-primary and pg-standby

2026-11-25T15:15:37.972Z test-divergence-rewind.sh == Step 1 of 10: restore the starting state and create the test table with one row ==
2026-11-25T15:15:37.974Z test-divergence-rewind.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:15:38.267Z test-divergence-rewind.sh   => pg-primary is up
2026-11-25T15:15:38.268Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151538Z-97536.log
2026-11-25T15:15:38.521Z test-divergence-rewind.sh   => pg-standby is up
2026-11-25T15:15:38.522Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151538Z-97562.log
2026-11-25T15:15:39.076Z test-divergence-rewind.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:15:39.153Z test-divergence-rewind.sh   => ALTER SYSTEM
2026-11-25T15:15:39.215Z test-divergence-rewind.sh   => Asynchronous replication ON.
2026-11-25T15:15:40.310Z test-divergence-rewind.sh   =>  synchronous_standby_names 
2026-11-25T15:15:40.312Z test-divergence-rewind.sh   => ---------------------------
2026-11-25T15:15:40.313Z test-divergence-rewind.sh   =>  
2026-11-25T15:15:40.314Z test-divergence-rewind.sh   => (1 row)
2026-11-25T15:15:40.315Z test-divergence-rewind.sh   => 
2026-11-25T15:15:40.378Z test-divergence-rewind.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:15:40.380Z test-divergence-rewind.sh   => ------------------+-----------+------------
2026-11-25T15:15:40.381Z test-divergence-rewind.sh   =>  standby1         | streaming | async
2026-11-25T15:15:40.382Z test-divergence-rewind.sh   => (1 row)
2026-11-25T15:15:40.383Z test-divergence-rewind.sh   => 
2026-11-25T15:15:40.385Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151539Z-97626.log
2026-11-25T15:15:40.386Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151537Z-97517.log
2026-11-25T15:15:40.388Z test-divergence-rewind.sh SQL on pg-primary: drop table if exists divergence_test
2026-11-25T15:15:40.441Z test-divergence-rewind.sh   => DROP TABLE
2026-11-25T15:15:40.442Z test-divergence-rewind.sh   => NOTICE:  table "divergence_test" does not exist, skipping
2026-11-25T15:15:40.448Z test-divergence-rewind.sh SQL on pg-primary: create table divergence_test (id serial primary key, note text not null)
2026-11-25T15:15:40.502Z test-divergence-rewind.sh   => CREATE TABLE
2026-11-25T15:15:40.508Z test-divergence-rewind.sh SQL on pg-primary: insert into divergence_test(note) values ('base-before-the-split')
2026-11-25T15:15:40.559Z test-divergence-rewind.sh   => INSERT 0 1
2026-11-25T15:15:40.565Z test-divergence-rewind.sh waiting 2 seconds for replication
2026-11-25T15:15:42.678Z test-divergence-rewind.sh SQL on pg-standby: select coalesce(string_agg(note, ',' order by id), '') from divergence_test
2026-11-25T15:15:42.681Z test-divergence-rewind.sh   => base-before-the-split
2026-11-25T15:15:42.682Z test-divergence-rewind.sh PASS: pg-standby returned the expected data (got 'base-before-the-split')

2026-11-25T15:15:42.683Z test-divergence-rewind.sh == Step 2 of 10: the fault: the standby stops following the primary ==
2026-11-25T15:15:42.763Z test-divergence-rewind.sh waiting 2 seconds for the WAL receiver to end
2026-11-25T15:15:44.850Z test-divergence-rewind.sh PASS: no standby is streaming from the primary (got '0')

2026-11-25T15:15:44.851Z test-divergence-rewind.sh == Step 3 of 10: the primary accepts three writes the standby never sees ==
2026-11-25T15:15:44.851Z test-divergence-rewind.sh SQL on pg-primary: insert into divergence_test(note) values ('lost-1'),('lost-2'),('lost-3')
2026-11-25T15:15:44.910Z test-divergence-rewind.sh   => INSERT 0 3
2026-11-25T15:15:44.917Z test-divergence-rewind.sh waiting 2 seconds: the standby must still not have them
2026-11-25T15:15:47.029Z test-divergence-rewind.sh SQL on pg-standby: select coalesce(string_agg(note, ',' order by id), '') from divergence_test
2026-11-25T15:15:47.031Z test-divergence-rewind.sh   => base-before-the-split
2026-11-25T15:15:47.032Z test-divergence-rewind.sh PASS: pg-standby returned the expected data (got 'base-before-the-split')
2026-11-25T15:15:47.104Z test-divergence-rewind.sh SQL on pg-primary: select coalesce(string_agg(note, ',' order by id), '') from divergence_test
2026-11-25T15:15:47.105Z test-divergence-rewind.sh   => base-before-the-split,lost-1,lost-2,lost-3
2026-11-25T15:15:47.106Z test-divergence-rewind.sh PASS: pg-primary returned the expected data (got 'base-before-the-split,lost-1,lost-2,lost-3')

2026-11-25T15:15:47.106Z test-divergence-rewind.sh == Step 4 of 10: promote the standby while the old primary still accepts writes (forced) ==
2026-11-25T15:15:47.108Z test-divergence-rewind.sh RUN bash scripts/promote-standby-to-primary.sh --force 
2026-11-25T15:15:47.403Z test-divergence-rewind.sh   => Promoting pg-standby ...
2026-11-25T15:15:47.727Z test-divergence-rewind.sh   => in recovery: f (expect f)
2026-11-25T15:15:47.729Z test-divergence-rewind.sh   => timeline:    648 (was 1 before promotion)
2026-11-25T15:15:47.729Z test-divergence-rewind.sh   => 
2026-11-25T15:15:47.730Z test-divergence-rewind.sh   => pg-standby is now the writable primary.
2026-11-25T15:15:47.731Z test-divergence-rewind.sh   => Do NOT restart the old primary as-is: it must be rebuilt or rewound (pg_rewind) as a standby first.
2026-11-25T15:15:47.732Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-standby-to-primary.sh-20261125T151547Z-97699.log

2026-11-25T15:15:47.733Z test-divergence-rewind.sh == Step 5 of 10: the new writer takes different writes: two histories now exist ==
2026-11-25T15:15:47.734Z test-divergence-rewind.sh SQL on pg-standby: insert into divergence_test(note) values ('kept-1'),('kept-2')
2026-11-25T15:15:47.788Z test-divergence-rewind.sh   => INSERT 0 2
2026-11-25T15:15:47.851Z test-divergence-rewind.sh SQL on pg-standby: select coalesce(string_agg(note, ',' order by id), '') from divergence_test
2026-11-25T15:15:47.852Z test-divergence-rewind.sh   => base-before-the-split,kept-1,kept-2
2026-11-25T15:15:47.852Z test-divergence-rewind.sh PASS: pg-standby returned the expected data (got 'base-before-the-split,kept-1,kept-2')
2026-11-25T15:15:47.910Z test-divergence-rewind.sh SQL on pg-primary: select coalesce(string_agg(note, ',' order by id), '') from divergence_test
2026-11-25T15:15:47.912Z test-divergence-rewind.sh   => base-before-the-split,lost-1,lost-2,lost-3
2026-11-25T15:15:47.912Z test-divergence-rewind.sh PASS: pg-primary returned the expected data (got 'base-before-the-split,lost-1,lost-2,lost-3')

2026-11-25T15:15:47.913Z test-divergence-rewind.sh == Step 6 of 10: stop the old primary cleanly ==
2026-11-25T15:15:47.915Z test-divergence-rewind.sh RUN bash scripts/bring-down-database.sh --database primary 
2026-11-25T15:15:48.180Z test-divergence-rewind.sh   => pg-primary is down
2026-11-25T15:15:48.181Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-down-database.sh-20261125T151547Z-97737.log
2026-11-25T15:15:48.203Z test-divergence-rewind.sh container::is_running pg-primary => false
2026-11-25T15:15:48.204Z test-divergence-rewind.sh PASS: pg-primary is stopped (got 'false')

2026-11-25T15:15:48.204Z test-divergence-rewind.sh == Step 7 of 10: rebuild the old primary as a standby of the new writer (pg_rewind) ==
2026-11-25T15:15:52.480Z test-divergence-rewind.sh   => pg_rewind: connected to server
2026-11-25T15:15:52.481Z test-divergence-rewind.sh   => pg_rewind: servers diverged at WAL location 3/9503E8C0 on timeline 647
2026-11-25T15:15:52.482Z test-divergence-rewind.sh   => pg_rewind: rewinding from last common checkpoint at 3/950030F8 on timeline 647
2026-11-25T15:15:52.482Z test-divergence-rewind.sh   => pg_rewind: reading source file list
2026-11-25T15:15:52.483Z test-divergence-rewind.sh   => pg_rewind: reading target file list
2026-11-25T15:15:52.484Z test-divergence-rewind.sh   => pg_rewind: reading WAL in target
2026-11-25T15:15:52.485Z test-divergence-rewind.sh   => pg_rewind: need to copy 181 MB (total source directory size is 208 MB)
2026-11-25T15:15:52.486Z test-divergence-rewind.sh   =>      0/185896 kB (0%) copied
2026-11-25T15:15:52.486Z test-divergence-rewind.sh   =>  39862/185896 kB (21%) copied
2026-11-25T15:15:52.487Z test-divergence-rewind.sh   => 185896/185896 kB (100%) copied
2026-11-25T15:15:52.488Z test-divergence-rewind.sh   => pg_rewind: creating backup label and updating control file
2026-11-25T15:15:52.489Z test-divergence-rewind.sh   => pg_rewind: syncing target data directory
2026-11-25T15:15:52.489Z test-divergence-rewind.sh   => pg_rewind: Done!
2026-11-25T15:15:52.490Z test-divergence-rewind.sh   => pg-primary is up
2026-11-25T15:15:52.491Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151549Z-97813.log
2026-11-25T15:15:52.492Z test-divergence-rewind.sh   => pg-primary in recovery: t (expect t)
2026-11-25T15:15:52.493Z test-divergence-rewind.sh   => pg-primary is now a standby of pg-standby
2026-11-25T15:15:52.494Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-primary-to-standby.sh-20261125T151548Z-97755.log
2026-11-25T15:15:52.496Z test-divergence-rewind.sh PASS: pg_rewind found the servers diverged (got 'yes')
2026-11-25T15:15:52.497Z test-divergence-rewind.sh PASS: pg_rewind did a real rewind (got 'yes')
2026-11-25T15:15:52.499Z test-divergence-rewind.sh PASS: pg_rewind did not say "no rewind required" (got 'no')
2026-11-25T15:15:52.500Z test-divergence-rewind.sh PASS: the old primary was rewound, not cloned (got 'no')

2026-11-25T15:15:52.501Z test-divergence-rewind.sh == Step 8 of 10: the old primary is a streaming replica again ==
2026-11-25T15:15:52.557Z test-divergence-rewind.sh SQL on pg-primary: select pg_is_in_recovery()
2026-11-25T15:15:52.558Z test-divergence-rewind.sh   => t
2026-11-25T15:15:52.558Z test-divergence-rewind.sh PASS: pg-primary returned the expected data (got 't')
2026-11-25T15:15:52.616Z test-divergence-rewind.sh PASS: the new writer reports one streaming standby (got '1')

2026-11-25T15:15:52.617Z test-divergence-rewind.sh == Step 9 of 10: the three lost writes are gone and both nodes hold identical rows ==
2026-11-25T15:15:52.675Z test-divergence-rewind.sh SQL on pg-primary: select coalesce(string_agg(note, ',' order by id), '') from divergence_test
2026-11-25T15:15:52.676Z test-divergence-rewind.sh   => base-before-the-split,kept-1,kept-2
2026-11-25T15:15:52.677Z test-divergence-rewind.sh PASS: pg-primary returned the expected data (got 'base-before-the-split,kept-1,kept-2')
2026-11-25T15:15:52.735Z test-divergence-rewind.sh SQL on pg-standby: select coalesce(string_agg(note, ',' order by id), '') from divergence_test
2026-11-25T15:15:52.736Z test-divergence-rewind.sh   => base-before-the-split,kept-1,kept-2
2026-11-25T15:15:52.737Z test-divergence-rewind.sh PASS: pg-standby returned the expected data (got 'base-before-the-split,kept-1,kept-2')

2026-11-25T15:15:52.738Z test-divergence-rewind.sh == Step 10 of 10: what this showed ==
2026-11-25T15:15:52.738Z test-divergence-rewind.sh PASS: all 10 steps passed. What this showed:
2026-11-25T15:15:52.739Z test-divergence-rewind.sh   pg_rewind found where the two histories split and undid the old primary.
2026-11-25T15:15:52.740Z test-divergence-rewind.sh   Three writes it had acknowledged (lost-1..3) were discarded: the cost of
2026-11-25T15:15:52.741Z test-divergence-rewind.sh   replacing a writer that holds writes its standby never received.
2026-11-25T15:15:52.742Z test-divergence-rewind.sh == Cleanup: restore the starting state ==
2026-11-25T15:15:52.744Z test-divergence-rewind.sh RUN bash scripts/restore-starting-state.sh 
2026-11-25T15:15:53.047Z test-divergence-rewind.sh   => pg-primary is up
2026-11-25T15:15:53.048Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151552Z-97891.log
2026-11-25T15:15:53.294Z test-divergence-rewind.sh   => pg-standby is up
2026-11-25T15:15:53.295Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151553Z-97925.log
2026-11-25T15:15:53.668Z test-divergence-rewind.sh   => pg-primary is down
2026-11-25T15:15:53.670Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-down-database.sh-20261125T151553Z-97963.log
2026-11-25T15:15:54.242Z test-divergence-rewind.sh   => pg_rewind: connected to server
2026-11-25T15:15:54.246Z test-divergence-rewind.sh   => pg_rewind: source and target cluster are on the same timeline
2026-11-25T15:15:54.246Z test-divergence-rewind.sh   => pg_rewind: no rewind required
2026-11-25T15:15:57.175Z test-divergence-rewind.sh   => pg-primary is up
2026-11-25T15:15:57.176Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151554Z-98026.log
2026-11-25T15:15:57.295Z test-divergence-rewind.sh   => pg-primary in recovery: t (expect t)
2026-11-25T15:15:57.296Z test-divergence-rewind.sh   => pg-primary is now a standby of pg-standby
2026-11-25T15:15:57.297Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-primary-to-standby.sh-20261125T151553Z-97979.log
2026-11-25T15:15:57.505Z test-divergence-rewind.sh   => pg-standby is down
2026-11-25T15:15:57.506Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-down-database.sh-20261125T151557Z-98080.log
2026-11-25T15:15:57.798Z test-divergence-rewind.sh   => Promoting pg-primary ...
2026-11-25T15:15:58.115Z test-divergence-rewind.sh   => in recovery: f (expect f)
2026-11-25T15:15:58.116Z test-divergence-rewind.sh   => timeline:    649 (was 1 before promotion)
2026-11-25T15:15:58.116Z test-divergence-rewind.sh   => 
2026-11-25T15:15:58.117Z test-divergence-rewind.sh   => pg-primary is now the writable primary.
2026-11-25T15:15:58.118Z test-divergence-rewind.sh   => Do NOT restart the old primary as-is: it must be rebuilt or rewound (pg_rewind) as a standby first.
2026-11-25T15:15:58.119Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-standby-to-primary.sh-20261125T151557Z-98094.log
2026-11-25T15:15:58.715Z test-divergence-rewind.sh   => pg_rewind: connected to server
2026-11-25T15:15:58.729Z test-divergence-rewind.sh   => pg_rewind: servers diverged at WAL location 3/950401E8 on timeline 648
2026-11-25T15:15:58.731Z test-divergence-rewind.sh   => pg_rewind: no rewind required
2026-11-25T15:16:01.644Z test-divergence-rewind.sh   => pg-standby is up
2026-11-25T15:16:01.645Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//bring-up-database.sh-20261125T151559Z-98176.log
2026-11-25T15:16:01.772Z test-divergence-rewind.sh   => pg-standby in recovery: t (expect t)
2026-11-25T15:16:01.773Z test-divergence-rewind.sh   => pg-standby is now a standby of pg-primary
2026-11-25T15:16:01.774Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//promote-primary-to-standby.sh-20261125T151558Z-98121.log
2026-11-25T15:16:02.105Z test-divergence-rewind.sh   => pg-primary accepts writes and pg-standby is streaming from it
2026-11-25T15:16:02.180Z test-divergence-rewind.sh   => ALTER SYSTEM
2026-11-25T15:16:02.243Z test-divergence-rewind.sh   => Asynchronous replication ON.
2026-11-25T15:16:03.322Z test-divergence-rewind.sh   =>  synchronous_standby_names 
2026-11-25T15:16:03.323Z test-divergence-rewind.sh   => ---------------------------
2026-11-25T15:16:03.324Z test-divergence-rewind.sh   =>  
2026-11-25T15:16:03.326Z test-divergence-rewind.sh   => (1 row)
2026-11-25T15:16:03.326Z test-divergence-rewind.sh   => 
2026-11-25T15:16:03.385Z test-divergence-rewind.sh   =>  application_name |   state   | sync_state 
2026-11-25T15:16:03.387Z test-divergence-rewind.sh   => ------------------+-----------+------------
2026-11-25T15:16:03.388Z test-divergence-rewind.sh   =>  standby1         | streaming | async
2026-11-25T15:16:03.389Z test-divergence-rewind.sh   => (1 row)
2026-11-25T15:16:03.390Z test-divergence-rewind.sh   => 
2026-11-25T15:16:03.392Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//set-replication-mode.sh-20261125T151602Z-98241.log
2026-11-25T15:16:03.394Z test-divergence-rewind.sh   => log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//restore-starting-state.sh-20261125T151552Z-97872.log
2026-11-25T15:16:03.395Z test-divergence-rewind.sh SQL on pg-primary: drop table if exists divergence_test
2026-11-25T15:16:03.449Z test-divergence-rewind.sh   => DROP TABLE
log: /var/folders/l1/k77q52vj72lfmq5410hw639c0000gn/T//test-divergence-rewind.sh-20261125T151537Z-97506.log
```
