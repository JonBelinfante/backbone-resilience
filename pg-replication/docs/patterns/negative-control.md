# Negative control

**Pattern:** for every test that proves a protection works, also run the same test with the protection removed, and require that one to fail.

## Problem

A test that passes proves nothing if it could not have failed. "No data was lost" is meaningless if the test would have said
that anyway. A passing result has to mean the test could see the problem.

## Mechanism

Each protected behaviour has a switch or a variant that removes only that protection, and a step that expects the fault:

| Protection | Control | What the control showed |
|---|---|---|
| Synchronous commit (RPO-02) | commit level `local` | 17 writes lost where sync lost 0 |
| The lease guard (LEASE-01, LEASE-02) | no guard | the old writer kept writing; 14 to 16 s of two writers |
| The write check (LEASE-04) | no trigger | a paused writer accepted a write 3.1 s after its lease ran out |
| The fence (FOV-10) | fence lifted | the old primary started writable and accepted a write |
| The actor lock (ACT-03) | `ACTOR_LOCK=off` | both actors ran, and a real race on the epoch file appeared |
| The witness window (DET-01) | a short window with an idle writer | a false failover |
| Decisions read the writer (DEC-01) | read the replica | both debits approved, balance -100 |

The tests are in [scripts/](../../scripts/): `test-replica-lag.sh`, `test-fencing.sh`, `test-detector.sh`, `test-lease-fence.sh`, `test-lease-failover.sh`, `test-resume-fence.sh` and `test-two-actors.sh`; the RPO controls are in `measure-recovery.sh`.

## Guards against

A test that passes because it cannot see the fault; a protection that is never really exercised.

## Evidence

Several controls found real defects: the lock-off control exposed the epoch-file race; the fence test failed first, before the fence existed, which showed the gap. Every control above is recorded with its numbers in the capability register.

## Limits

- A control removes one protection at a time; it does not show that no other protection hides the fault.
- Control outcomes can depend on timing (both actors reaching the race); they are repeated, and the register says when a result was seen once.
- A control that damages the platform (two writers, divergence) needs the restore script, which is why every test restores the starting state.

## Related

[Kill-test harness](kill-test-harness.md), [Decisions read the writer](decisions-read-the-writer.md).
