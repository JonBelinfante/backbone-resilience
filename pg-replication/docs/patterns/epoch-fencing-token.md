# Epoch (fencing token)

**Pattern:** give every failover a number that only goes up, write it down before acting, and reuse the same number if the failover is interrupted and resumed.

## Problem

After a failover two nodes may each believe they are the writer. Without an ordering, nothing says which belief is current. A
failover that is interrupted half way must also not count as two failovers when it is run again.

## Mechanism

| Where | What it does |
|---|---|
| [lib/epoch.sh](../../lib/epoch.sh), `epoch::advance` | Raises the number by one. It writes a new file and moves it into place, so a kill leaves the old number or the new one, never half of one |
| same library, `epoch::begin` | Starts a failover: raises the number and writes a pending marker. If a marker exists, it prints the same number again instead of raising it |
| same library, `epoch::finish`, `epoch::is_unfinished` | Remove the marker when the failover is complete; report whether one is still open |
| [act-on-failover.sh](../../scripts/act-on-failover.sh), `fail_over` | Starts the epoch first, before the old writer is touched, and finishes it last |
| [lib/lease.sh](../../lib/lease.sh), `lease::install` | Stamps the new writer's lease with the epoch, so the number is also visible on the node |

```mermaid
flowchart LR
  A["decision: fail over"] --> B["epoch::begin: N+1, pending marker"]
  B --> C["stop old writer"]
  C --> D["promote standby"]
  D --> E["lease at epoch N+1"]
  E --> F["epoch::finish: remove marker"]
```

## Guards against

Two failovers counted for one event; a failed-over writer that cannot be told apart from the current one; a half-written number.

## Evidence

- **ACT-02, ACT-04:** the actor was killed after each step and at 0.1 to 0.9 s; every re-run ended at epoch 1, not 2.
- **LEASE-03:** the new writer's lease carries epoch 1 and is renewed.
- **ACT-03:** the control with no lock exposed a real race on the number's file, which is why the actor takes a lock before `epoch::begin`.

## Limits

- **The epoch is a file on the host, not a fence that every node checks in every write.** A node that is paused and then resumes can write once before anything stops it (register gap GAP-03).
- It is only as available as the host that holds the file. A real system keeps it in a replicated consensus store.

## Related

[Lease and guard](lease-and-guard.md), [Restartable actor](restartable-actor.md).
