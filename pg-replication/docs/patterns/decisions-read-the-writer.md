# Decisions read the writer

**Pattern:** a decision (approve, decline, price, limit) reads only a node that accepts writes. A replica may be
read for reports and searches, but never for a decision, because it may lag.

## Problem

A replica applies changes after the writer does. In that gap it shows an old balance. A service that approves a debit
by reading the replica can approve two debits against the same 100, because the replica still shows 100 when the
second decision is made. The writer is correct; the decision was wrong.

## Mechanism

| Where | What it does |
|---|---|
| [lib/database.sh](../../lib/database.sh), `database::read_for_decision` | Runs a query for a decision and refuses a node that is in recovery |
| [lib/database.sh](../../lib/database.sh), `database::wait_for_replay` | For the case where a replica must be read: waits until it has replayed a given WAL position, so it shows every change up to that point |
| [lib/fault.sh](../../lib/fault.sh), `fault::set_apply_delay` | Makes a standby apply changes late (the recovery_min_apply_delay setting), so the lag is deterministic and the anomaly can be shown on demand |
| [test-replica-lag.sh](../../scripts/test-replica-lag.sh) | The experiment: the wrong way, the right way, the guard, and the wait |

## Guards against

- Double approval, overdrafts and stale limits caused by a decision made on lagging data.
- A caller that forgets which node it is talking to: the guard checks, it does not trust.

## Evidence

[capability-register.md](../../capability-register.md), DEC-01. With the standby 6 seconds behind, two debits of 100
decided on the replica both passed and the account went to -100. Decided on the writer, the second was declined and the
account stayed at 0. The guard refused the replica. A replica read after `database::wait_for_replay` showed the new value;
before it, the old one.

## Limits

- The guard is in the database library. It proves that path is safe, not that a future service will use it. The
  independent checker (gap GAP-12) is what shows the whole system obeys the rule.
- It checks that the node is a writer when asked. A node demoted a moment later is not detected; fencing (GAP-03) is
  what closes that.
- Reading the writer costs load. Read-your-writes on a replica (wait for replay) is the cheaper option for reads that
  follow your own write, never for decisions that depend on other clients' writes.

## Related

- [Verify after act](verify-after-act.md): read back what you wrote, from the right node.
- [Split-brain guard](split-brain-guard.md): two writers are the other way a decision goes wrong.
