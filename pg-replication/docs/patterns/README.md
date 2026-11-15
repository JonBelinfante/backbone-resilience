# Robustness patterns

Each page here is one pattern the scripts in this repository use to stay correct when something fails. A page says
what problem the pattern solves, where the code does it, which failure it guards against, what proves it works, and
where it falls short. The scripts are the reference; these pages explain them.

Code references name a **function**, not a line number, so they survive edits. Check a reference with
`grep -n "^<function>()" <file>`.

## Pages

| Pattern | Problem it solves | Proven by |
|---|---|---|
| [Promotion guard](promotion-guard.md) | Promoting a standby while the old primary still accepts writes creates two writers | FOV-02 (manual) |
| [Split-brain guard](split-brain-guard.md) | A node restarted after failover comes back as a second writer | FOV-03 (manual) |
| [Verify after act](verify-after-act.md) | An action reports success, but the data or state has not changed yet | REP-01 (auto), FOV-05, FOV-07 |

## Diagrams

| Diagram | Shows |
|---|---|
| [Role state machine](../diagrams/role-state-machine.md) | Which script moves a node between writer, replica and stopped, and which moves are refused |
| [Failover sequence](../diagrams/failover-sequence.md) | The 17-step round trip as a sequence of calls, with the check at each step |

Capability IDs (FOV-02 and so on) refer to [capability-register.md](../../capability-register.md), which records the
evidence and the gaps for each.

## Adding a page

1. Copy the layout of an existing page: Problem, Mechanism, Guards against, Evidence, Limits, Related.
2. Cite each function as `file` plus `function name`, and link the file relatively, for example
   `[promote-standby-to-primary.sh](../../scripts/promote-standby-to-primary.sh)`. `check-docs.sh` (part of
   `run-all-checks.sh`) fails if a link is broken, a named function is not defined, or a line links the wrong file.
3. Put the evidence in the capability register first. A pattern without evidence is written as "not yet proven".
4. State the limits as plainly as the strengths. Limits are where the next experiment comes from.
5. Add a row to the table above.
