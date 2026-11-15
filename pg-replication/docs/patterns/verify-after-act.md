# Verify after act

**Pattern:** after an action reports success, read the state back and check that it is what the action should have
produced.

## Problem

"The command returned 0" is not the same as "the system is in the new state". Replication is asynchronous, so a
write made on the primary may not be on the standby yet. A promotion may report success on a node that then does
not accept writes.

## Mechanism

| Where | What it does |
|---|---|
| [verify-replication.sh](../../scripts/verify-replication.sh), `check_round_trip` | Inserts a row on the primary, then polls the standby until it sees the row |
| same script, `poll_standby` | Polls with a budget of `POLL_ATTEMPTS` (100) times `POLL_PAUSE` (0.1 s), so about 10 s, and returns the delay when the row appears |
| same script, `check_read_only` | Sends a write to the standby and requires it to be rejected |
| [lib/story.sh](../../lib/story.sh), `story::expect_query` | Reads the data back and compares it with the expected value. The round trip calls it after a fixed wait ([test-failover-roundtrip.sh](../../scripts/test-failover-roundtrip.sh)) |
| [restore-starting-state.sh](../../scripts/restore-starting-state.sh), `check_starting_state` | Reads both roles back after restoring them |

## Guards against

- An asynchronous standby that has not caught up, reported as a failure, or a standby that has caught up and is
  reported as working when it is not.
- A promotion that reports success while the node still refuses writes.

## Evidence

- **REP-01** (automatic): the replication check measures the delay for one row (about 60 ms in recent runs).
- **FOV-05 and FOV-07** (automatic): the round trip reads the rows back on both nodes after failover and after
  restore, and fails if they are missing.

## Limits

- **Two strengths, and the round trip uses the weaker one.** `verify-replication` polls. The round trip waits a
  fixed 2 seconds, so a slow standby fails the test instead of being waited for. Polling with a stated budget is
  the better pattern; prefer it.
- **Errors during polling are discarded.** `row_delay` sends its stderr to nowhere, so a broken connection looks
  like "not replicated yet" until the budget runs out. The final message says "never appeared", not why. Keeping the
  last error would make the failure explain itself.
- **It checks one row, or one table.** It is not a checksum of the whole database. A difference in other tables
  would pass.
- **Read-back is only as good as the query.** A check that reads a value the action could not have changed proves
  nothing. The round trip compares a concatenated list of notes, which is strict enough to catch a missing row.

## Related

[Promotion guard](promotion-guard.md) and [split-brain guard](split-brain-guard.md) decide whether to act;
this pattern checks that the action worked.
