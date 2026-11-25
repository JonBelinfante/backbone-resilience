# Negative control

**Pattern:** for every test that proves a protection works, run the same test with the protection removed. Require that second run to fail.

## Problem

A test that passes proves nothing if it could not have failed. "No data was lost" means nothing if the test would have said so anyway. A passing result has to mean that the test could see the problem.

## Mechanism

Each protected behaviour has a switch or a variant that removes only that protection. The control then expects the fault.

| Protection | Control | What the control showed |
|---|---|---|
| Synchronous commit (RPO-02). | Commit level `local`. | 17 writes were lost, where synchronous replication lost none. |
| The lease guard (LEASE-01 and LEASE-02). | No guard. | The old writer kept writing, and two writers ran for 14 to 16 seconds. |
| The write check (LEASE-04). | No trigger. | A paused writer accepted a write 3.1 seconds after its lease ran out. |
| The fence (FOV-10). | The fence is lifted. | The old primary started writable and accepted a write. |
| The actor lock (ACT-03). | `ACTOR_LOCK=off`. | Both actors ran, and a real race on the epoch file appeared. |
| The witness window (DET-01). | A short window with an idle writer. | A false failover occurred. |
| Decisions read the writer (DEC-01). | Read the replica. | Both debits were approved, and the balance went to -100. |

The tests are in [scripts/](../../scripts/). They are `test-replica-lag.sh`, `test-fencing.sh`, `test-detector.sh`, `test-lease-fence.sh`, `test-lease-failover.sh`, `test-resume-fence.sh` and `test-two-actors.sh`. The controls for the recovery point objective (RPO) are in `measure-recovery.sh`.

## Guards against

- A test that passes because it cannot see the fault.
- A protection that is never really exercised.

## Evidence

Several controls found real defects. The lock-off control exposed the epoch-file race. The fence test failed first, before the fence existed, and that showed the gap. The [capability register](../../capability-register.md) records every control above with its numbers.

## Limits

- A control removes one protection at a time. It does not show that no other protection hides the fault.
- A control's outcome can depend on timing, for example when both actors must reach the race. The controls are repeated, and the register says when a result was seen once.
- A control that damages the platform, such as two writers or a divergence, needs the restore script. That is why every test restores the starting state.

## Related

The [kill-test harness](kill-test-harness.md) and [decisions read the writer](decisions-read-the-writer.md).
