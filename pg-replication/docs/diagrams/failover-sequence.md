# Failover sequence: the 17-step round trip

The script [test-failover-roundtrip.sh](../../scripts/test-failover-roundtrip.sh) runs the full cycle. It replicates a row, fails over, rejoins the old primary, writes while a node is down, and compares the two nodes. The diagram shows the calls and the check at each step. The step numbers match the test's own output.

The container names `pg-primary` and `pg-standby` never change. After a failover, `pg-standby` is the writer. Step 12 stops the container named `pg-primary`, which is then the **replica**. The roles swap, and the names do not.

```mermaid
sequenceDiagram
  participant T as Round trip (test)
  participant D as bring-down-database.sh
  participant P as promote-standby-to-primary.sh
  participant R as promote-primary-to-standby.sh
  participant U as bring-up-database.sh
  participant A as pg-primary (writer)
  participant B as pg-standby (replica)

  Note over T,B: Steps 1 to 4: start both, drop tables, check standby is empty
  T->>B: step 5 create table and insert row 1 (on writer A)
  T->>B: step 7 read row 1 from standby (after 2 s wait)
  T->>D: step 8 stop pg-primary cleanly
  D->>A: docker stop
  T->>P: step 9 promote standby (guard: is A ready? no)
  P->>B: pg_promote
  T->>B: step 9 insert row 2 into the new writer
  T->>R: step 10 rebuild pg-primary as standby of B
  R->>B: create slot, checkpoint
  R->>A: pg_rewind (throwaway container), standby settings
  R->>U: start pg-primary as standby
  U->>A: start, wait healthy, split-brain guard (B writable, A in recovery: pass)
  T->>A: step 11 rows 1 and 2 present on pg-primary
  T->>D: step 12 stop pg-primary (now the replica)
  D->>A: docker stop
  T->>B: step 13 insert row 3 into the writer
  T->>U: step 14 start pg-primary
  U->>A: start, healthy, guard passes
  T->>A: step 16 rows 1 to 3 present on the replica (after 2 s wait)
  T->>A: step 17 rows on both nodes, roles swapped
  T->>T: restore-starting-state.sh, then drop the test table
```

## What each check proves

| Step | Check | Pattern |
|---|---|---|
| 7 | Row 1 is on the standby. | [Verify after act](../patterns/verify-after-act.md) |
| 9 | The promotion guard passed because the primary was stopped, and the new writer accepts row 2. | [Promotion guard](../patterns/promotion-guard.md) |
| 10 | The old primary rejoined, and the split-brain guard let it start as a standby. | [Split-brain guard](../patterns/split-brain-guard.md) |
| 11, 16 and 17 | Every row is on both nodes, and the roles are as expected. | [Verify after act](../patterns/verify-after-act.md) |

## Known weak points, in the order that a learner should meet them

1. **Fixed waits.** Steps 3, 6 and 15, and the wait after step 10, sleep for 2 seconds. A slow node fails the test and is not waited for. [Verify after act](../patterns/verify-after-act.md) explains the stronger alternative.
2. **Check then act between steps 8 and 9.** The guard checks the primary once and then promotes. Nothing in the round trip stops the old primary coming back in between. The promotion now fences the old primary's data directory, so a restarted node comes up read-only. The [promotion guard](../patterns/promotion-guard.md) lists the remaining limit.
3. **Failure during the test.** If the run is interrupted, the cleanup runs `restore-starting-state.sh`. The [role state machine](role-state-machine.md) holds its decision table.
