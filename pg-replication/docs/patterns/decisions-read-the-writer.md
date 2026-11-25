# Decisions read the writer

**Pattern:** a decision, such as an approval, a decline, a price or a limit, reads only a node that accepts writes. A replica may be read for reports and searches, but never for a decision, because it may lag.

## Problem

A replica applies changes after the writer does. In that gap it shows an old balance. Suppose a service approves a debit by reading the replica. It can approve two debits against the same 100, because the replica still shows 100 when it makes the second decision. The writer is correct, but the decision is wrong.

## Mechanism

| Where | What it does |
|---|---|
| [lib/database.sh](../../lib/database.sh), `database::read_for_decision` | Runs a query for a decision, and refuses a node that is in recovery. |
| [lib/database.sh](../../lib/database.sh), `database::wait_for_replay` | Serves the case where a replica must be read. It waits until the replica has replayed a given position in the write-ahead log (WAL), so that the replica shows every change up to that point. |
| [lib/fault.sh](../../lib/fault.sh), `fault::set_apply_delay` | Makes a standby apply changes late, through PostgreSQL's recovery minimum apply delay setting. The lag is then deterministic, and the anomaly can be shown on demand. |
| [test-replica-lag.sh](../../scripts/test-replica-lag.sh) | Runs the experiment: the wrong way, the right way, the guard and the wait. |


## Guards against

- A decision on lagging data can cause a double approval, an overdraft or a stale limit.
- A caller may forget which node it is talking to. The guard checks the node and does not trust the caller.

## Evidence

The [capability register](../../capability-register.md) records the result as DEC-01.

The standby was 6 seconds behind. Two debits of 100 were decided on the replica, both passed, and the account went to -100. Decided on the writer, the second debit was declined and the account stayed at 0. The guard refused the replica. A replica read after `database::wait_for_replay` showed the new value, and the read before it showed the old one.

## Limits

- The guard is in the database library. It proves that this path is safe. It does not prove that a future service will use the path. The independent checker (GAP-12) is what would show that the whole system obeys the rule.
- The guard checks that the node is a writer when it is asked. A node that is demoted a moment later is not detected. Fencing (GAP-03) closes that gap.
- Reading the writer costs load. A read that waits for replay is the cheaper option for reads that follow your own write. It is never right for decisions that depend on the writes of other clients.

## Related

- [Verify after act](verify-after-act.md) reads back what you wrote, from the right node.
- The [split-brain guard](split-brain-guard.md) addresses two writers, which is the other way that a decision goes wrong.
