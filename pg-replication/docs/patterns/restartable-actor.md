# Restartable actor

**Pattern:** break an action into ordered steps, record intent before the first, make every step safe to repeat, and let a re-run finish what a crash left half done.

## Problem

The program that carries out a failover can itself be killed at any point: after it raised the epoch, after it killed the old
writer, in the middle of the promotion. A restart must not repeat a step harmfully, skip a step, or leave the platform half moved.

## Mechanism

| Where | What it does |
|---|---|
| [act-on-failover.sh](../../scripts/act-on-failover.sh), `fail_over` | Takes the lock, checks whether the standby is already the writer, then runs epoch, stop, promote, hand-over, finish in that order |
| [lib/epoch.sh](../../lib/epoch.sh), `epoch::begin` | Records intent first and reuses the same number on a re-run |
| same script, `stop_old_writer`, `promote_standby` | Each checks the current state first (already stopped, already writable) and skips what is done |
| same script, `crash_point` | A test hook: with `ACTOR_CRASH_AFTER` set, the script SIGKILLs itself after the named step |
| [lib/lock.sh](../../lib/lock.sh), `lock::acquire` | One actor at a time per host; a dead holder's lock is taken over |

## Guards against

A crash between the steps; a second actor deciding at the same moment; a re-run that raises the epoch again.

## Evidence

- **ACT-02:** killed after the epoch, kill and promote steps; every re-run ended at epoch 1 with a writable standby.
- **ACT-04:** SIGKILL of the whole process group at 0.1 to 0.9 s; seven kills landed, all recovered.
- **ACT-03:** two actors at once, one acted. **Control** with the lock off: both went ahead and the control exposed a race.

## Limits

- The lock is host-local, with no time limit and no wait: a second actor is refused, not queued.
- The crash hook is a test aid inside the production script, set by an environment variable (default none).
- A slow promotion (a long recovery) is not covered by the timed-kill test.

## Related

[Epoch](epoch-fencing-token.md), [Kill-test harness](kill-test-harness.md), [Verify after act](verify-after-act.md).
