# Restartable actor

<!-- toc -->

- [Problem](#problem)
- [Mechanism](#mechanism)
- [Guards against](#guards-against)
- [Evidence](#evidence)
- [Limits](#limits)
- [Related](#related)

<!-- tocstop -->

**Pattern:** break an action into ordered steps and record intent before the first step. Make every step safe to repeat. Then a re-run finishes what a crash left half done.

## Problem

The program that carries out a failover can itself be killed at any point. It may die after it raised the epoch, after it killed the old writer, or in the middle of the promotion. A restart must not repeat a step harmfully or skip a step. It must also not leave the platform half moved.

## Mechanism

| Where | What it does |
|---|---|
| [act-on-failover.sh](../../scripts/act-on-failover.sh), `fail_over` | Takes the lock and checks whether the standby is already the writer. It then runs the epoch, stop, promote, hand-over and finish steps in that order. |
| [lib/epoch.sh](../../lib/epoch.sh), `epoch::begin` | Records the intent first, and reuses the same number on a re-run. |
| [act-on-failover.sh](../../scripts/act-on-failover.sh), `stop_old_writer` and `promote_standby` | Each checks the current state first, for example whether the node is already stopped or already writable. Each skips what is done. |
| Same script, `crash_point` | A test hook. When `ACTOR_CRASH_AFTER` is set, the script sends itself SIGKILL after the named step. SIGKILL is the signal that stops a process at once. |
| [lib/lock.sh](../../lib/lock.sh), `lock::acquire` | Allows one actor at a time on a host. It takes over from a dead holder. |

## Guards against

- A crash between the steps.
- A second actor that decides at the same moment.
- A re-run that raises the epoch again.

## Evidence

- **ACT-02.** The actor was killed after the epoch, kill and promote steps. Every re-run ended at epoch 1 with a writable standby.
- **ACT-04.** The test killed the whole process group at delays from 0.1 to 0.9 seconds. Seven kills landed, and all recovered.
- **ACT-03.** Two actors started at once, and one acted. In the control the lock was off. Both actors went ahead, and the control exposed a race.

## Limits

- The lock works on one host. It has no time limit and no wait. A second actor is refused and is not queued.
- The crash hook is a test aid inside the production script. An environment variable sets it, and the default is none.
- The timed-kill test does not cover a slow promotion, such as a long recovery.

## Related

[Epoch](epoch-fencing-token.md), the [kill-test harness](kill-test-harness.md) and [verify after act](verify-after-act.md).
