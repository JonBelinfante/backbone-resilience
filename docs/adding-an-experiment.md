# Adding an experiment

<!-- toc -->

- [The template](#the-template)
- [The steps](#the-steps)
- [Lessons from this repository](#lessons-from-this-repository)
- [Check and record](#check-and-record)

<!-- tocstop -->

An experiment is a test that injects one fault and checks one claim. This guide sets out the template and the steps. Use [test-divergence-rewind.sh](../pg-replication/scripts/test-divergence-rewind.sh) as the worked example. The terms are in the [glossary](glossary.md).

## The template

Write these seven items down before you write any code. They become the usage text of the script and the row in the register.

| Item | Question to answer | Example from the divergence test |
|---|---|---|
| Hypothesis | What do you expect to be true? | After a true divergence, pg_rewind removes the old primary's extra writes, and both nodes end identical. |
| Fault | What do you do to the system? | Stop the standby following, write on the old primary, then promote the standby by force. |
| Expected behaviour | What should you observe at each step? | The old primary is rewound and not cloned, and it streams from the new writer. |
| Pass criterion | Which observations make the test pass? | pg_rewind reports that the servers diverged, and both nodes hold the same rows. |
| Abort condition | When is the test meaningless, so that it must stop? | The standby still streams after the fault, because then nothing diverged. |
| Control | What variant must fail, to show that the test can see the fault? | See below. |
| Restore | How does the stack return to its starting state? | The restore script runs in a clean-up, even after a failure. |

A claim without a control is weak. A test that passes may not have been able to fail. See the [negative control pattern](../pg-replication/docs/patterns/negative-control.md).

## The steps

1. **Pick the register row.** Find a row or a gap in the [capability register](../pg-replication/capability-register.md), or add a new row with the next identifier in its group.
2. **Copy a script.** Copy the closest existing test. Keep its header, its environment block, its usage text, its step functions and its clean-up.
3. **Start from a known state.** The first step runs the restore script. Never assume that the stack is healthy.
4. **Narrate each step.** Print the step number and its purpose, then check the result. The story library gives the functions, which are in [story.sh](../pg-replication/lib/story.sh). They include story::narrate, story::run_logged, story::expect_equal, story::expect_query and story::expect_between.
5. **Keep calls in libraries.** A host script must not run `docker`, `psql` or `pgbench` directly. The libraries [container.sh](../pg-replication/lib/container.sh) and [database.sh](../pg-replication/lib/database.sh) do that. The hygiene check fails otherwise.
6. **Run the steps in a child shell.** The pattern is in run_and_restore in [test-divergence-rewind.sh](../pg-replication/scripts/test-divergence-rewind.sh). A failure then cannot skip the clean-up. The clean-up restores the stack and drops the test table.
7. **Add the control.** Make a variant, or a final step, in which the fault is absent or the protection is off. It must fail in the way that you predicted.
8. **Check the state afterwards.** The stack must end as it started. Assert the settings that the test touched, as the replication modes test does for the synchronous setting.
9. **Run it twice from a healthy stack.** One pass is one observation. Record the number of runs.

## Lessons from this repository

- A test that leaves a setting behind breaks the next test. The restore once left the writer synchronous, and the following test hung. Assert the state after the clean-up.
- A kill that lands after the work has finished tests nothing. Report such a case, as the hard-kill test does.
- A control can expose a real race. The two-actors control did.
- Fix a defect that a test finds, and record it in the evidence log. The defect is evidence too.

## Check and record

1. Run `bash pg-replication/scripts/run-all-checks.sh`. Set `BASHCHECK_WRAPPER` so that the lint runs.
2. If you changed a restore or rebuild script, run `bash pg-replication/scripts/test-hard-kill.sh` as well.
3. Run the new test with `TEMP_DIR` set to an empty folder, and confirm that the folder is empty afterwards. Repeat after a `kill -TERM`.
4. Add the row to the register, with the runs and the date of the last run in the Evidence column.
5. Add a dated section to the [evidence log](../pg-replication/evidence-log.md) with the commands, the numbers and the limits.
6. Add an entry to the [capability catalogue](capability-catalogue.md), and a row to the [failure modes](failure-modes.md) if the experiment covers a new fault.
7. Update the script tables in the [pg-replication README](../pg-replication/README.md).
8. Run `bash pg-replication/scripts/check-docs.sh`.
