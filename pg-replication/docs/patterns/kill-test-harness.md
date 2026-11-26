# Kill-test harness

<!-- toc -->

- [Problem](#problem)
- [Mechanism](#mechanism)
- [Guards against](#guards-against)
- [Evidence](#evidence)
- [Limits](#limits)
- [Related](#related)

<!-- tocstop -->

**Pattern:** kill a script, or a whole process group, with SIGKILL at set delays. Then require that a re-run or a restore returns the platform to a correct state. SIGKILL is the signal that stops a process at once.

## Problem

Recovery code is trustworthy only if it has been tried from the states that a crash really leaves behind. Examples are a data directory that is half rewound, a role that is half changed, or a standby that is in recovery but not streaming. Failure cases that people build by hand miss these states.

## Mechanism

| Where | What it does |
|---|---|
| [test-hard-kill.sh](../../scripts/test-hard-kill.sh), `run_cases` and `run_case` | Start the target script for each delay, kill it, and then recover and check. |
| Same script, `kill_after_delay` | Starts the target in its own process group and sends SIGKILL to the whole group, so that child commands die too. |
| Same script, `recover_stack` and `check_recovered` | Run the restore, and then require a writable node and one **streaming** standby. A standby that is merely in recovery is not enough. |
| [test-actor-timed-kill.sh](../../scripts/test-actor-timed-kill.sh) | Applies the same idea to the failover actor. It kills at 0.1 to 0.9 seconds, runs the actor again, and requires one epoch and a writable standby. |
| [restore-starting-state.sh](../../scripts/restore-starting-state.sh) | Is the recovery under test. From any state, it returns to a primary writer and a streaming standby. |

## Guards against

Recovery that works only from clean states.

## Evidence

- **FOV-08.** All 16 kills of the round trip and all 10 kills of the restore recovered. They found four real faults. These were a stuck split-brain guard, `pg_rewind` on a half-rewound directory, status queries during shutdown, and a wedged standby that was reported as a success.
- **SEC-R3.** All 25 kills of the secret rotation recovered.
- **ACT-04.** All seven kills of the actor that landed recovered.

## Limits

- The harness kills the scripts here and not PostgreSQL. The crash matrix (CRS-01) covers crashes of the database itself.
- Docker commands that start before the kill can finish by themselves. Some kills therefore land on a step that has already finished. A run reports that case, and the default delays were chosen so that kills really land.
- A kill is a process crash. It is not a power cut.

## Related

[Restartable actor](restartable-actor.md), [verify after act](verify-after-act.md) and [negative control](negative-control.md).
