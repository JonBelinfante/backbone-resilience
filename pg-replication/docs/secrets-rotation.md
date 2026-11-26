# Rotating database secrets without losing availability

<!-- toc -->

- [1. The secrets in this stack](#1-the-secrets-in-this-stack)
- [2. One password, many copies](#2-one-password-many-copies)
- [3. Principles](#3-principles)
- [4. Method A: rotate in place, with the same role name](#4-method-a-rotate-in-place-with-the-same-role-name)
- [5. Method B: overlap with a second identity, with no window](#5-method-b-overlap-with-a-second-identity-with-no-window)
  - [Which method to use](#which-method-to-use)
- [6. Rotating the superuser password](#6-rotating-the-superuser-password)
- [7. What is special about two databases](#7-what-is-special-about-two-databases)
- [8. Runbook for Method B and the replication password](#8-runbook-for-method-b-and-the-replication-password)
- [9. Evidence](#9-evidence)
- [10. What is not solved yet](#10-what-is-not-solved-yet)
- [Related](#related)

<!-- tocstop -->

**The question this page answers:** how do you change the passwords of a two-database system, with a writer and a standby, while it keeps accepting writes, keeps replicating and loses no data? And how do you know that the change worked?

**The short answer:** never swap a password. Make the old and the new password valid at the same time. Move every user of the secret across, and prove that the new password works. Only then retire the old one. The rest of this page explains what that means for two PostgreSQL nodes. It includes measurements from this repository's stack, taken on 2026-11-20.

The steps below were first run by hand on the throwaway stack under write load, on 2026-11-20. They were then automated and tested on 2026-11-21. `scripts/rotate-secret.sh` performs the steps. `scripts/test-rotation.sh` runs three rotations under a write probe. `scripts/test-hard-kill.sh --target rotate` kills the rotation at many points. [Section 9](#9-evidence) gives the results, and [section 10](#10-what-is-not-solved-yet) lists what is still open.

## 1. The secrets in this stack

| Secret | Role | Who presents it | Who checks it |
|---|---|---|---|
| `pg-password` | `postgres`, the superuser. | `pg_rewind`, in its `--source-server` connection, and any client that connects over the Transmission Control Protocol (TCP). | The database that is the source. |
| `pg-replication-password` | `replicator`, which has the REPLICATION privilege. | The standby's write-ahead log (WAL) receiver, and `pg_basebackup` when it builds or clones a standby. | The writer's WAL sender. |

A connection from inside a container over the Unix socket or over `127.0.0.1` uses `trust`, so `docker exec ... psql` never uses a password. Passwords matter only for TCP connections between containers and for the host's published ports.

## 2. One password, many copies

A password is not one thing. Each secret above exists in several places, and each place changes in its own way. Rotation is the job of changing all of them in an order that never leaves a user of the secret without a working copy.

| Copy | Where | Replicated to the other node? | How it changes | How it behaves |
|---|---|---|---|---|
| The secret file on the host. | `secrets/*.txt` | No. | Write the file. | An in-place edit showed up in the running container at once, through the bind mount on Docker Desktop for macOS. |
| The secret file in the container. | `/run/secrets/NAME` | No. | It follows the host file. | `container::secret` in [container.sh](../lib/container.sh) reads it on demand. |
| The database's own verifier. | The role's Salted Challenge Response Authentication Mechanism (SCRAM) hash in the system catalogue. | **Yes**, through the WAL. | `ALTER ROLE ... PASSWORD` on the **writer**. | It was identical on both nodes a second later. |
| The login permission. | `pg_hba.conf` | **No**, because it is a file. | Edit the file and reload it on **each** node. | It changes per node. |
| The standby's connection string. | primary_conninfo in `postgresql.auto.conf`. | No. | `ALTER SYSTEM SET` and a reload on the standby. | It contains the password in plain text. |

Two consequences surprise people.

1. **The secret file does not set the database password.** The image reads `POSTGRES_PASSWORD_FILE` only when it first creates the database. [init-replication.sh](../primary/init-replication.sh) reads the replication file at the same moment. Editing a file later changes what our scripts present. It does not change what the database accepts. The file and the database drift apart unless you change both on purpose.
2. **A connection survives its own password change.** PostgreSQL checks the password when a connection is made, and not afterwards. Changing the password does not drop the standby's open replication connection, so nothing breaks yet. The risk sits at the next reconnect. A reconnect can come at any moment, for example after a network blip, a restart or a failover.

## 3. Principles

1. **Overlap, never swap.** At every moment, every user of the secret must have a credential that works. A rotation with a gap is an outage that waits for a reconnect to happen inside the gap.
2. **Prove the new credential alone** before you move anyone to it. Prove it again by forcing a reconnect after the move. The success of `ALTER ROLE` proves only that the system catalogue changed.
3. **Retire in reversible steps.** Use `NOLOGIN` first, which `LOGIN` undoes. Use `DROP ROLE` only after a soak period.
4. **Change the writer's catalogue, and the file-based settings on every node.** Role changes replicate. `pg_hba.conf` and primary_conninfo do not.
5. **Do not rotate during a failover, a rebuild or a restore.** All three read the secrets. Start only from a restored stack, because `restore-starting-state.sh` ends with the standby streaming.
6. **Keep the secret off command lines and out of logs.** Pass it on standard input and let `psql` read it with `\getenv`, as [init-replication.sh](../primary/init-replication.sh) does. A password in the argument list is visible to every process listing on the host.
7. **Test a rotation as you test a failover.** An untested rotation is a failover that you have not rehearsed.

## 4. Method A: rotate in place, with the same role name

Use this method when a brief exposure to a reconnect failure is acceptable. That is the case for asynchronous replication on a quiet system, and for the superuser. The order matters.

| Step | Where | Action | Why this order |
|---|---|---|---|
| A1 | The **writer**. | `ALTER ROLE replicator PASSWORD :'pw'` | The new hash replicates to the standby by itself. |
| A2 | The standby. | `ALTER SYSTEM SET primary_conninfo = ...new password...`, and then `SELECT pg_reload_conf()`. | The WAL receiver restarts on the reload and reconnects with the new password. |
| A3 | The host. | Write the new value into `secrets/pg-replication-password.txt` **in place**. | Later rebuilds and clones read this file. |
| A4 | The writer. | `SELECT pg_terminate_backend(pid) FROM pg_stat_replication` | It forces a reconnect, to prove the stored settings. The cost is described below. |

**The cost of A4.** The standby waits up to 5 seconds before it reconnects, because of wal_retrieve_retry_interval. Under synchronous replication, every commit waits too. The reload in A2 already restarts the WAL receiver with a fresh login. Step A4 is therefore needed only to prove the stored settings, and `rotate-secret.sh` leaves it out.

**The window.** Between A1 and A2 the writer already wants the new password, and the standby still presents the old one. If the replication link drops inside that window, the standby cannot come back. It reports "password authentication failed for user replicator". No data is lost, because the replication slot keeps the WAL. Under **synchronous** replication, every commit waits for the standby, so writes stall until A2 completes.

Keep A1 and A2 a few seconds apart. Script them as one unit, and rotate only when the stack is healthy.

## 5. Method B: overlap with a second identity, with no window

PostgreSQL gives a role one password, so an overlap needs two roles. Create the second role and move the standby. Then retire the first role.

| Step | Where | Action | State after the step |
|---|---|---|---|
| B1 | The writer. | `CREATE ROLE replicator_b WITH REPLICATION LOGIN PASSWORD :'pw'` | Both roles are valid, and the standby still uses the old one. |
| B2 | **Both** nodes. | Append `host replication replicator_b all scram-sha-256` to `pg_hba.conf`, and run `SELECT pg_reload_conf()`. | Either node can authenticate the new role, so it still works after a failover. |
| B3 | The standby, towards the writer. | Open a replication connection as replicator_b and run `IDENTIFY_SYSTEM`. | The new credential is proven on its own while nothing depends on it. |
| B4 | The standby. | `ALTER SYSTEM SET primary_conninfo` with the user and password, and then `SELECT pg_reload_conf()`. | The link restarts on the new identity. |
| B5 | The writer. | Check `pg_stat_replication`, which must show `usename = replicator_b` and `state = streaming`. | The move is confirmed from the other side. |
| B6 | The writer. | `ALTER ROLE replicator NOLOGIN`. Check that the link is still `streaming` as the new role, and let it soak. | The old identity is retired reversibly. A forced reconnect, as in A4, is not needed, because B4 already logged in afresh. |
| B7 | Both nodes, later. | `DROP ROLE replicator`, delete the old `pg_hba.conf` line, and reload. | The old identity is gone. |

At no point does the standby lack a credential that the writer accepts. Under synchronous replication, the link was in the `sync` state before, during and after the move.

**The role name is data, not a constant.** This was done on 2026-11-21. The name lives in a secret file next to the password, `secrets/pg-replication-user.txt`, which is mounted in both containers. The standby entrypoint, the init script and the scripts read it from there. The scripts use `container::secret`. A rotation therefore never edits a container's environment and never restarts a node. The name alternates between replicator_a and replicator_b. The first rotation moves from the original `replicator` to replicator_a.

### Which method to use

| Situation | Method |
|---|---|
| Synchronous replication, or any time a stalled commit is unacceptable. | **B**. |
| Asynchronous replication on a quiet system. | A, scripted, in the safe order. |
| The superuser `postgres`. | A. It has no long-lived replication connection, and its users read the file when they run. |
| The standby is down or lagging. | **B**. Keep the old identity until both nodes are confirmed on the new one. |

## 6. Rotating the superuser password

The `postgres` role is used by `pg_rewind`, for the connection to the node that it copies from, and by TCP clients. There is no long-lived connection to protect, so Method A is enough.

1. Run `ALTER ROLE postgres PASSWORD :'pw'` on the writer. The hash replicates.
2. Write the new value into `secrets/pg-password.txt` in place.
3. Prove the change from the other container over TCP. The new password must log in, and the old one must be refused.
4. Prove the real consumer. Run the failover and fail-back round trip, which uses the file for `pg_rewind`.

The only window lies between step 1 and step 2. In that gap, a script that reads the file would present a password that the database no longer accepts. The window affects a script run. It does not affect replication or application writes. Do not run a failover in that gap.

## 7. What is special about two databases

- **"Primary" is not a fixed node.** After a failover the roles swap. Run `ALTER ROLE` and `CREATE ROLE` on whichever node reports `pg_is_in_recovery() = f` at that moment.
- **`pg_hba.conf` must change on both nodes.** The standby today is the writer tomorrow. If only one node has the new line, the failover succeeds, but the old primary cannot rejoin later. This fault is latent. It passes every test until the day it matters.
- **The setting primary_conninfo exists on both nodes, and every rebuild rewrites it.** When the old primary is rebuilt as a standby, `container::mark_standby` writes the writer's current secret into it. The secret file must therefore be updated before the next rebuild. That is why a rotation and a failover must not overlap.
- **A standby that was down during the change** still has the old primary_conninfo. It catches up the new hash through the WAL when it returns, but it cannot reconnect under Method A. Under Method B the old identity still works. The standby reconnects, catches up, and is then moved.
- **Confirm in order.** Retire the old identity only after *both* nodes are confirmed on the new one, because either node could be the writer tomorrow.

## 8. Runbook for Method B and the replication password

`bash scripts/rotate-secret.sh` does the steps below. The option `--secret superuser` rotates the superuser password in place. After any interruption, run the script again, and it converges. The manual steps are kept here so that you can read the script against them.

The preconditions are two. `bash scripts/restore-starting-state.sh` must pass, which gives a writer and one streaming standby. No failover or rebuild may be running.

1. Generate the new secret into a file that is made under `umask 077`. Never type it on a command line.
2. Run B1 to B3. Stop here if B3 fails, because nothing has changed for the standby.
3. Run B4 and B5. If B5 does not show replicator_b streaming, switch primary_conninfo back. The old identity is intact.
4. Update `secrets/pg-replication-password.txt` in place. Check that the container sees the same bytes. The `cksum` of the host file and of `/run/secrets/pg-replication-password` must match.
5. Run B6. Check that the link is `streaming` as the new role again, and then retire the old role.
6. Run `bash scripts/run-all-checks.sh`. The round trip rebuilds and clones with the new secret.
7. After the soak period, run B7.

The secret reaches `psql` in this way. The first line of standard input is the secret, and the rest is the Structured Query Language (SQL) text. This is `access::run_sql` in [lib/access.sh](../lib/access.sh).

```bash
{
  cat -- "${secret_file}"
  printf '\n%s\n' "${sql}"
} |
  docker exec -i "${node}" sh -c \
    'IFS= read -r NEWPW; export NEWPW; exec psql -U postgres -d appdb -X -v ON_ERROR_STOP=1 -q'
# in the SQL:  \getenv pw NEWPW   then   ALTER ROLE replicator_a PASSWORD :'pw';
```

## 9. Evidence

The first experiments ran on 2026-11-20 on one machine, with PostgreSQL 16 and the two-node stack. A write probe inserted a row on the writer about every 0.1 seconds throughout. It recorded failures and the slowest insert, which includes about 100 milliseconds of `docker exec`.

| # | Experiment | Result |
|---|---|---|
| 1 | Method A on `replicator`, asynchronous, under load. | There were 104 inserts and **0 failed**. The standby ended with all 104 rows, and the new hash was on the standby. After a forced reconnect the link was `streaming` as `replicator`. |
| 2 | Method A, `ALTER SYSTEM` on the standby. | `postgresql.auto.conf` went from **86** lines containing `password=` to **1**. |
| 3 | The secret file edited in place. | The running container saw the change within 2 seconds, and the checksums matched. |
| 4 | Method B, synchronous, under load. | The role replicator_b was created, allowed on both nodes, proven alone with `IDENTIFY_SYSTEM`, and the standby was moved. The link was `streaming sync` before, during and after. The old role was `NOLOGIN`, and a forced reconnect was still `streaming sync`. |
| 5 | Method A, synchronous, in the safe order. | There were 60 inserts and 0 failed. The slowest took 108 milliseconds. |
| 6 | Method B back to the original identity, synchronous. | There were 49 inserts and 0 failed. The slowest took 121 milliseconds. |
| 7 | **The window.** Synchronous, with the password changed and the link killed *before* the standby had the new password. | The standby log said "password authentication failed for user replicator". The link stayed down, and **one commit stalled for 9.2 seconds**. No insert failed and none was lost. The link recovered as soon as the standby was given the new password. |
| 8 | Method A in the safe order, with the original password restored, synchronous. | There were 42 inserts and 0 failed. The slowest took 319 milliseconds. |
| 9 | The superuser, Method A. | The new password logged in over TCP to both nodes, and the old password was refused. The failover and fail-back round trip, including `pg_rewind`, passed with the new password. |
| 10 | The cleanup of the 2026-11-20 session. | Both secret files were byte-identical to the originals. The temporary role and the `pg_hba.conf` lines were gone from both nodes. The mode was asynchronous, with one streaming standby. |
| 11 | The append fix, on 2026-11-21. | After the fix, each node held exactly 1 primary_conninfo line after a full round trip and after a standby was built from an empty volume. Nine more hard kills ended with 1 line for each node. |
| 12 | `rotate-secret.sh` for replication, by overlap, on 2026-11-21. | `replicator` became replicator_a in 1.6 seconds. The role was created, allowed on both nodes and proven alone. The standby was moved, and the files were updated in place and seen by both containers. The old role was dropped, its `pg_hba.conf` line was removed on both nodes, and no temporary file was left. |
| 13 | `test-rotation.sh`, three runs. | Each run rotated replication, the superuser and replication again, under a write probe of 32 to 50 rows. **No write failed.** The standby always streamed as the role in the secret file, and one replication role was left. The superuser file password logged in over the network. A standby built from an **empty volume** joined with the rotated secret files. |
| 14 | `test-hard-kill.sh --target rotate`. | The test sent 25 SIGKILL signals to `rotate-secret.sh` at 0.1 to 1.3 seconds, and a whole run takes about 1.3 seconds. A re-run recovered every time. The standby streamed as the role that the files name, one replication role was left, and the files' login worked. |
| 15 | **A finding from experiment 14.** | An earlier version forced a reconnect after the file update. A kill just after it left the standby reconnecting for up to 5 seconds, and the re-run refused to start because the standby was not streaming. The fix has two parts. The forced reconnect is gone, because it was redundant and would stall synchronous commits. And `check_ready` now waits up to 30 seconds for streaming. |

What the measurements do and do not show: The safe order caused no visible stall at this load. The deliberate window caused a stall of 9.2 seconds. A light, single-writer probe does not show how long a real window lasts under heavy load.

## 10. What is not solved yet

| ID | Gap | Detail and next step |
|---|---|---|
| SEC-01 | **No script and no automatic test. Fixed on 2026-11-21.** | `rotate-secret.sh` rotates by overlap for replication and in place for the superuser. It rolls back before the files change, and it converges when run again. `test-rotation.sh` and `test-hard-kill.sh --target rotate` test it. Still manual: choosing when to rotate, and the soak period. The option `--keep-old` stops at `NOLOGIN`. |
| SEC-02 | **Stale passwords piled up on disk. Fixed on 2026-11-21.** | `container::mark_standby` and the standby entrypoint *appended* primary_conninfo on every rebuild. A rotated-out password therefore stayed in the file in plain text, with 88 lines on the primary and 3 on the standby. Both now replace the two settings in a new file that is moved into place. `test-hard-kill.sh` fails if a node holds more than one. |
| SEC-03 | **The replication role name was hard-coded. Fixed on 2026-11-21.** | The name is now the `pg-replication-user` secret file. See section 5. |
| SEC-04 | **File secrets are a development convenience.** | They are plain files on the developer's machine, and primary_conninfo holds the password in plain text. A real system needs a secret manager and certificate or token authentication. |
| SEC-05 | **Edits that replace the file.** | An in-place write reached the container. An editor that saves by creating a new file changes the inode, and the container may not see the change. Always compare checksums, as the runbook does. Recreating a container to pick up a secret restarts that node. |
| SEC-06 | **Application clients.** | The platform's services will have their own database role. They need the same overlap, with two roles or a connection pool that authenticates again. They also need a test that rotates under load. |
| SEC-07 | **Very long windows and heavy load.** | They are not measured. |
| SEC-08 | **The in-place file write is not atomic. Closed on 2026-11-21 by a maintenance lock.** | The command `cat new > file` truncates the file and then writes it, so a container could read an empty file for a moment. Rotation, rebuild and role-change scripts now take one maintenance lock, from `lib/lock.sh`. A second run is refused while the first lives. A child script of the holder enters the lock again. A lock left by a run that ended is taken over. `test-maintenance-lock.sh` proves it. The lock does not cover the standby entrypoint's first-start bootstrap. |

## Related

- [Verify after act](patterns/verify-after-act.md) describes the read-back habit that steps B3, B5 and A4 use.
- The [split-brain guard](patterns/split-brain-guard.md) explains why a restarted node must not become a second writer. A node that cannot authenticate is the quiet version of the same problem.
- The [capability register](../capability-register.md) holds the evidence and the gaps for every capability.
