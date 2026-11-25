# Verify after act

**Pattern:** after an action reports success, read the state back and check that it is what the action should have produced.

## Problem

"The command returned 0" is not the same as "the system is in the new state". Replication is asynchronous, so a write on the primary may not be on the standby yet. A promotion may report success on a node that then does not accept writes.

## Mechanism

| Where | What it does |
|---|---|
| [verify-replication.sh](../../scripts/verify-replication.sh), `check_round_trip` | Inserts a row on the primary, and then polls the standby until it sees the row. |
| Same script, `poll_standby` | Polls with a budget of `POLL_ATTEMPTS` (100) times `POLL_PAUSE` (0.1 seconds), which is about 10 seconds. It returns the delay when the row appears. |
| Same script, `check_read_only` | Sends a write to the standby and requires the standby to reject it. |
| [lib/story.sh](../../lib/story.sh), `story::expect_query` | Reads the data back and compares it with the expected value. The round trip calls it after a fixed wait in [test-failover-roundtrip.sh](../../scripts/test-failover-roundtrip.sh). |
| [restore-starting-state.sh](../../scripts/restore-starting-state.sh), `check_starting_state` | Reads both roles back after the restore sets them. |

## Guards against

- An asynchronous standby that has not caught up can be reported as a failure. A standby that has not caught up can also be reported as working.
- A promotion can report success while the node still refuses writes.

## Evidence

- **REP-01** is automated. The replication check measures the delay for one row, which was about 60 milliseconds in recent runs.
- **FOV-05 and FOV-07** are automated. The round trip reads the rows back on both nodes after the failover and after the restore, and it fails if they are missing.

## Limits

- **There are two strengths, and the round trip uses the weaker one.** The script `verify-replication.sh` polls. The round trip waits a fixed 2 seconds, so a slow standby fails the test instead of being waited for. Polling with a stated budget is the better pattern, and you should prefer it.
- **Errors during polling are discarded.** The function `row_delay` sends its error output nowhere. A broken connection therefore looks like "not replicated yet" until the budget runs out. The final message says "never appeared" and does not say why. Keeping the last error would make the failure explain itself.
- **The check covers one row or one table.** It is not a checksum of the whole database, so a difference in other tables would pass.
- **A read-back is only as good as its query.** A check that reads a value that the action could not have changed proves nothing. The round trip compares a concatenated list of notes, which is strict enough to catch a missing row.

## Related

The [promotion guard](promotion-guard.md) and the [split-brain guard](split-brain-guard.md) decide whether to act. This pattern checks that the action worked.
