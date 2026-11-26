# Robustness patterns

<!-- toc -->

- [Pages](#pages)
- [Related guide](#related-guide)
- [Diagrams](#diagrams)
- [Adding a page](#adding-a-page)

<!-- tocstop -->

Each page here describes one pattern that the scripts in this repository use to stay correct when something fails. A page says what problem the pattern solves and where the code applies it. It also names the failure that the pattern guards against, the test that proves it, and where it falls short. The scripts are the reference, and these pages explain them.

Code references name a **function**, not a line number, so that they survive edits. You can check a reference with `grep -n "^<function>()" <file>`.

## Pages

The identifiers in the last column, such as FOV-02, are rows in the [capability register](../../capability-register.md).

| Pattern | Problem it solves | Proven by |
|---|---|---|
| [Promotion guard](promotion-guard.md) | Promoting a standby while the old primary still accepts writes creates two writers. | FOV-02. |
| [Split-brain guard](split-brain-guard.md) | A node that restarts after a failover comes back as a second writer. | FOV-03 and FOV-10. |
| [Decisions read the writer](decisions-read-the-writer.md) | A decision that is made on a lagging replica approves what the writer would refuse. | DEC-01. |
| [Verify after act](verify-after-act.md) | An action reports success, but the data or the state has not changed yet. | REP-01, FOV-05 and FOV-07. |
| [Epoch (fencing token)](epoch-fencing-token.md) | A failover needs an ordering, and an interrupted failover must not count twice. | ACT-02 and ACT-04. |
| [Lease and guard](lease-and-guard.md) | A partitioned writer that cannot be killed keeps taking writes. | LEASE-01 to LEASE-05 and CTL-01. |
| [Restartable actor](restartable-actor.md) | The program that does the failover can itself crash half way. | ACT-02 to ACT-04. |
| [Witness detector](witness-detector.md) | One observer cannot tell a dead writer from its own blindness. | DET-01. |
| [Negative control](negative-control.md) | A test that passes may not have been able to fail. | The controls in RPO-02, LEASE-02, LEASE-04, FOV-10, ACT-03, DET-01 and DEC-01. |
| [Kill-test harness](kill-test-harness.md) | Recovery code works only from the clean states that you thought of. | FOV-08, SEC-R3 and ACT-04. |

## Related guide

| Guide | Covers |
|---|---|
| [Rotating database secrets](../secrets-rotation.md) | How to change the superuser and replication passwords across two nodes with no gap, and what was measured. |

## Diagrams

| Diagram | Shows |
|---|---|
| [Role state machine](../diagrams/role-state-machine.md) | Which script moves a node between writer, replica and stopped, and which moves are refused. |
| [Failover sequence](../diagrams/failover-sequence.md) | The 17-step round trip as a sequence of calls, with the check at each step. |

## Adding a page

1. Copy the layout of an existing page. The sections are Problem, Mechanism, Guards against, Evidence, Limits and Related.
2. Cite each function as a file plus a function name, and link the file relatively. For example, link to `[promote-standby-to-primary.sh](../../scripts/promote-standby-to-primary.sh)`. The check `check-docs.sh` runs inside `run-all-checks.sh`. It fails if a link is broken, if a named function is not defined, or if a line links the wrong file.
3. Put the evidence in the capability register first. A pattern without evidence is written as "not yet proven".
4. State the limits as plainly as the strengths. The limits are where the next experiment comes from.
5. Add a row to the table above.
