# Learning path

This path takes you through seven labs. Each lab runs one test and teaches one idea. Do them in order, because each lab uses the ideas of the one before. The tests take about 6 minutes to run, plus the time that you spend predicting and reading.

## Before you start

- Install Docker with Compose, and Bash 5.0 or later. On macOS, run `brew install bash` first.
- Read the [PostgreSQL replication primer](primer-postgresql-replication.md). It takes about ten minutes. Keep the [glossary](glossary.md) open.
- Start the stack from the `pg-replication` folder with `docker compose up -d`, and wait until both databases are healthy.
- Use only a throwaway stack. The tests crash and rebuild the databases. Each test returns the stack to its starting state when it ends.
- Look at the [architecture page](architecture.md) once, so that you know the parts.

## How each lab works

1. Read the question and write down your prediction before you run anything.
2. Run the command from the `pg-replication` folder.
3. Compare the output with the expected result. The [sample transcripts](transcripts/README.md) show real output for four of the tests.
4. Do the exercise. Then open the register row, and read its limit.

## Lab 1: replication works

- **Question:** If you write a row on the primary, how soon can you read it on the standby? Can you write on the standby?
- **Command:** `bash scripts/verify-replication.sh`
- **Expected result:** The script prints `PASS: replication is working`. The row appears on the standby in under a second, and the standby refuses a write.
- **Exercise:** Run `docker exec pg-standby psql -U postgres -d appdb -c "select pg_is_in_recovery()"`. Explain why the answer is `t`.
- **Register rows:** REP-01 and REP-02.
- **Time:** A few seconds.

## Lab 2: the price of synchronous replication

- **Question:** What happens to a commit when the standby is down, in each of the two modes?
- **Command:** `bash scripts/test-replication-modes.sh`
- **Expected result:** An asynchronous commit takes tens of milliseconds with the standby stopped. A synchronous commit waits until the standby returns, which took about 7.6 seconds in the sample run. Read the [transcript](transcripts/test-replication-modes.md).
- **Exercise:** Find the two lines in the output that show the waiting commit. Say which of the two modes you would choose for a payment, and write down what you give up.
- **Register rows:** REP-04, REP-05 and REP-06.
- **Time:** About 30 seconds.

## Lab 3: what a failover can lose

- **Question:** If the old primary accepted writes that the standby never received, what happens to them when the old primary rejoins?
- **Command:** `bash scripts/test-divergence-rewind.sh`
- **Expected result:** The three writes that only the old primary held are removed by pg_rewind. Both nodes end with the same rows. Read the [transcript](transcripts/test-divergence-rewind.md).
- **Exercise:** Explain why those writes count as acknowledged loss, and which replication mode would have prevented it. Then look at the guard in the [promotion guard pattern](../pg-replication/docs/patterns/promotion-guard.md) and say why the test needs `--force`.
- **Register rows:** FOV-09 and FOV-02.
- **Time:** About 30 seconds.

## Lab 4: a decision on a stale replica

- **Question:** If a service reads a balance from a lagging replica, can it approve a payment that the writer would refuse?
- **Command:** `bash scripts/test-replica-lag.sh`
- **Expected result:** Two debits of 100 decided on the replica both pass, and the account goes to -100. Decided on the writer, the second debit is declined. The first case is the negative control.
- **Exercise:** Read the [decisions read the writer pattern](../pg-replication/docs/patterns/decisions-read-the-writer.md). Say what the test does not prove about a future service.
- **Register row:** DEC-01.
- **Time:** About 30 seconds.

## Lab 5: stopping a writer that cannot be killed

- **Question:** If the controller loses contact with a live writer, what stops the writer from taking writes?
- **Command:** `bash scripts/test-lease-fence.sh`
- **Expected result:** With a guard, the writer's last accepted write comes about 6 seconds after the cut, and then the writer is stopped. Without a guard, the writer still accepts writes about 13 seconds later. Read the [transcript](transcripts/test-lease-fence.md).
- **Exercise:** Say what you give up for this safety. Check your answer against the limit in LEASE-01.
- **Register rows:** LEASE-01 and CTL-01.
- **Time:** About 70 seconds.

## Lab 6: automatic failover

- **Question:** When should a controller fail over, and when should it do nothing?
- **Command:** `bash scripts/test-auto-failover.sh`
- **Expected result:** A short freeze causes no action. After a crash, a client write succeeds on the new writer after about 3 seconds. After a hung writer it takes about 7 seconds. Read the [transcript](transcripts/test-auto-failover.md).
- **Exercise:** Read the [witness detector pattern](../pg-replication/docs/patterns/witness-detector.md). Explain why one observer is not enough, and where most of the downtime goes.
- **Register rows:** ACT-01 and DET-01.
- **Time:** About 60 seconds. The first run also builds a controller image.

## Lab 7: undoing a mistake that replication copied

- **Question:** If someone deletes every row by mistake, why does the standby not save you?
- **Command:** `bash scripts/test-point-in-time.sh`
- **Expected result:** The delete reaches the standby within seconds. Recovery from the base backup and the archive to a recorded position brings the rows back. The control recovers to the end of the archive and finds no rows.
- **Exercise:** Read section 4 of the [decision guide](decision-guide.md). Write down which of your own faults need replication and which need backup.
- **Register row:** BAK-01.
- **Time:** About 2 minutes.

## What to read next

- The [failure modes](failure-modes.md) index lists every fault that a test exercises, and the faults that none does.
- The [capability catalogue](capability-catalogue.md) gives one entry for each capability.
- To write your own experiment, follow the guide on [adding an experiment](adding-an-experiment.md).
