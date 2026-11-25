# Epoch (fencing token)

**Pattern:** give every failover a number that only goes up. Write the number down before acting. If the failover is interrupted and resumed, reuse the same number.

## Problem

After a failover, two nodes may each believe that they are the writer. Without an ordering, nothing says which belief is current. A failover that is interrupted half way must also not count as two failovers when it is run again.

## Mechanism

| Where | What it does |
|---|---|
| [lib/epoch.sh](../../lib/epoch.sh), `epoch::advance` | Raises the number by one. It writes a new file and moves it into place, so a kill leaves the old number or the new one and never half of one. |
| Same library, `epoch::begin` | Starts a failover. It raises the number and writes a pending marker. If a marker exists, it prints the same number again instead of raising it. |
| Same library, `epoch::finish` and `epoch::is_unfinished` | `epoch::finish` removes the marker when the failover is complete. `epoch::is_unfinished` reports whether a marker is still open. |
| [act-on-failover.sh](../../scripts/act-on-failover.sh), `fail_over` | Starts the epoch first, before it touches the old writer, and finishes the epoch last. |
| [lib/lease.sh](../../lib/lease.sh), `lease::install` | Stamps the new writer's lease with the epoch, so the number is also visible on the node. |

```mermaid
flowchart LR
  A["decision: fail over"] --> B["epoch::begin: N+1, pending marker"]
  B --> C["stop old writer"]
  C --> D["promote standby"]
  D --> E["lease at epoch N+1"]
  E --> F["epoch::finish: remove marker"]
```

## Guards against

- One event can be counted as two failovers.
- A failed-over writer can be indistinguishable from the current writer.
- A kill can leave a half-written number.

## Evidence

- **ACT-02 and ACT-04.** The actor was killed after each step, and at delays from 0.1 to 0.9 seconds. Every re-run ended at epoch 1 and not at epoch 2.
- **LEASE-03.** The new writer's lease carries epoch 1 and is renewed.
- **ACT-03.** The control with no lock exposed a real race on the number's file. That is why the actor takes a lock before `epoch::begin`.

## Limits

- **The epoch is a file on the host.** It is not a fence that every node checks in every write. A node that is paused and then resumes can write once before anything stops it (GAP-03).
- The file is only as available as the host that holds it. A real system keeps the epoch in a replicated consensus store.

## Related

[Lease and guard](lease-and-guard.md) and [Restartable actor](restartable-actor.md).
