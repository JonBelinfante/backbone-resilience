# Kill-test harness

**Pattern:** kill a script (or a whole process group) with SIGKILL at set delays, then require that a re-run or a restore returns the platform to a correct state.

## Problem

Recovery code is only trustworthy if it has been tried from the states a crash really leaves behind: a data directory half
rewound, a role half changed, a standby that is "in recovery" but not streaming. Hand-built failure cases miss them.

## Mechanism

| Where | What it does |
|---|---|
| [test-hard-kill.sh](../../scripts/test-hard-kill.sh), `run_cases` and `run_case` | For each delay, start the target script, kill it, then recover and check |
| same script, `kill_after_delay` | Starts the target in its own process group and sends SIGKILL to the whole group, so child commands die too |
| same script, `recover_stack` and `check_recovered` | Run the restore, then require a writable node and one **streaming** standby, not just "in recovery" |
| [test-actor-timed-kill.sh](../../scripts/test-actor-timed-kill.sh) | The same idea for the failover actor: kill at 0.1 to 0.9 s, re-run, require one epoch and a writable standby |
| [restore-starting-state.sh](../../scripts/restore-starting-state.sh) | The recovery being tested: from any state, back to primary writer and standby streaming |

## Guards against

Recovery that works only from clean states.

## Evidence

- **FOV-08:** 16 kills of the round trip and 10 of the restore, all recovered. They found four real faults: a stuck split-brain guard, `pg_rewind` on a half-rewound directory, status queries during shutdown, and a wedged standby reported as success.
- **SEC-R3:** 25 kills of the secret rotation, all recovered.
- **ACT-04:** seven landed kills of the actor, all recovered.

## Limits

- Only the scripts are killed here, not Postgres. Crashes of the database itself are the crash matrix (CRS-01).
- Docker commands started before the kill can finish by themselves, so some kills land on an already-finished step; a run reports that, and the default delays were chosen so that kills really land.
- A kill is a process crash, not a power cut.

## Related

[Restartable actor](restartable-actor.md), [Verify after act](verify-after-act.md), [Negative control](negative-control.md).
