# Rotating database secrets without losing availability

**Question this page answers:** how do you change the passwords of a two-database system (a writer and a standby)
while it keeps accepting writes, keeps replicating, and loses no data, and how do you know it worked?

**Short answer:** never swap a password; make the old and the new one valid at the same time, move every user of the
secret across, prove the new one works, and only then retire the old one. The rest of this page is what that means
for two Postgres nodes, with measurements from this repository's stack (2026-11-20).

Evidence level: the steps below were first run by hand on the throwaway stack under write load (2026-11-20), then
automated and tested (2026-11-21): `scripts/rotate-secret.sh` does them, `scripts/test-rotation.sh` runs three rotations under a
write probe, and `scripts/test-hard-kill.sh --target rotate` kills the rotation at many points. The results are in
[section 9](#9-evidence); what is still open is in [section 10](#10-what-is-not-solved-yet).

## 1. The secrets in this stack

| Secret | Role | Who presents it | Who checks it |
|---|---|---|---|
| `pg-password` | `postgres` (superuser) | `pg_rewind` (its `--source-server` connection) and any client that connects over TCP | the database that is the source |
| `pg-replication-password` | `replicator` (REPLICATION) | the standby's WAL receiver, `pg_basebackup` (standby build, clone) | the writer's WAL sender |

Connections from inside a container over the Unix socket or `127.0.0.1` are `trust`, so `docker exec ... psql` never
uses a password. Passwords matter only for **TCP between containers** and from the host's published ports.

## 2. One password, many copies

A password is not one thing. Each secret above exists in several places, and each place changes in its own way.
Rotation is the job of changing all of them in an order that never leaves a user of the secret without a working
copy.

| Copy | Where | Replicated to the other node? | How it changes | Seen to behave as |
|---|---|---|---|---|
| Secret file on the host | `secrets/*.txt` | no | write the file | edited in place, it showed up in the running container at once (bind mount, Docker Desktop on macOS) |
| Secret file in the container | `/run/secrets/NAME` | no | follows the host file | read on demand by [container.sh](../lib/container.sh) `container::secret` |
| The database's own verifier | the role's SCRAM hash in the catalog | **yes**, through WAL | `ALTER ROLE ... PASSWORD` on the **writer** | identical on both nodes a second later |
| Login permission | `pg_hba.conf` | **no**, it is a file | edit and reload on **each** node | per node |
| Standby's connection string | primary_conninfo in `postgresql.auto.conf` | no | `ALTER SYSTEM SET` and reload on the standby | contains the password in plain text |

Two consequences that surprise people:

1. **The secret file does not set the database password.** The image reads `POSTGRES_PASSWORD_FILE` (and
   [init-replication.sh](../primary/init-replication.sh) reads the replication file) only when it first creates the
   database. Editing the file later changes what our scripts present, not what the database accepts. The file and
   the database drift apart unless you change both on purpose.
2. **A connection survives its own password change.** Postgres checks the password when a connection is made, not
   afterwards. Changing the password does not drop the standby's open replication connection, so nothing breaks
   *yet*. The risk sits at the next reconnect, which can come at any moment (a network blip, a restart, a failover).

## 3. Principles

1. **Overlap, never swap.** At every moment, every user of the secret must have a credential that works. A rotation
   that has a gap is an outage waiting for a reconnect to happen inside the gap.
2. **Prove the new credential alone** before moving anyone to it, and prove it again by forcing a reconnect after
   the move. Success of `ALTER ROLE` proves only that the catalog changed.
3. **Retire in reversible steps.** `NOLOGIN` first (undo with `LOGIN`), `DROP ROLE` only after a soak period.
4. **Change the writer's catalog, file-based settings on every node.** Role changes replicate; `pg_hba.conf` and
   primary_conninfo do not.
5. **Do not rotate during a failover, a rebuild or a restore.** All three read the secrets. Start only from a
   restored stack (`restore-starting-state.sh` ends with the standby streaming).
6. **Keep the secret off command lines and out of logs.** Pass it on standard input and let `psql` read it with
   `\getenv`, as [init-replication.sh](../primary/init-replication.sh) does. A password in `argv` is visible to every
   process listing on the host.
7. **Rotation is tested like failover is.** An untested rotation is a failover you have not rehearsed.

## 4. Method A: rotate in place (same role name)

Use it when brief exposure to a reconnect failure is acceptable (asynchronous replication, quiet system) or for the
superuser. The order matters.

| Step | Where | Action | Why this order |
|---|---|---|---|
| A1 | the **writer** | `ALTER ROLE replicator PASSWORD :'pw'` | the new hash replicates to the standby by itself |
| A2 | the standby | `ALTER SYSTEM SET primary_conninfo = ...new password...`, then `SELECT pg_reload_conf()` | the WAL receiver restarts on reload and reconnects with the new password |
| A3 | the host | write the new value into `secrets/pg-replication-password.txt` **in place** | later rebuilds and clones read this file |
| A4 | the writer | `SELECT pg_terminate_backend(pid) FROM pg_stat_replication` | forces a reconnect, to prove the stored settings (costly: see below) |

**Cost of A4:** the standby waits up to 5 s before it reconnects (wal_retrieve_retry_interval), and under synchronous
replication every commit waits too. The reload in A2 already restarts the WAL receiver with a fresh login, so A4 is only
needed to prove the *stored* settings; `rotate-secret.sh` leaves it out.

**The window:** between A1 and A2 the writer already wants the new password and the standby still presents the old
one. If the replication link drops inside that window, the standby cannot come back ("password authentication
failed for user replicator"). No data is lost, because the replication slot keeps the WAL, but under **synchronous**
replication every commit waits for the standby, so writes stall until A2 completes.

Keep A1 and A2 seconds apart, script them as one unit, and rotate only when the stack is healthy.

## 5. Method B: overlap with a second identity (no window)

Postgres gives a role one password, so overlap needs two roles. Create the second, move the standby, then retire the
first.

| Step | Where | Action | State after the step |
|---|---|---|---|
| B1 | the writer | `CREATE ROLE replicator_b WITH REPLICATION LOGIN PASSWORD :'pw'` | both roles valid; the standby still uses the old one |
| B2 | **both** nodes | append `host replication replicator_b all scram-sha-256` to `pg_hba.conf`; `SELECT pg_reload_conf()` | either node can authenticate the new role, so it still works after a failover |
| B3 | the standby, towards the writer | open a replication connection as replicator_b and run `IDENTIFY_SYSTEM` | the new credential is proven on its own while nothing depends on it |
| B4 | the standby | `ALTER SYSTEM SET primary_conninfo` (user and password), `SELECT pg_reload_conf()` | the link restarts on the new identity |
| B5 | the writer | check `pg_stat_replication`: `usename = replicator_b`, `state = streaming` | the move is confirmed from the other side |
| B6 | the writer | `ALTER ROLE replicator NOLOGIN` and check the link is still `streaming` as the new role, soak | the old identity is retired reversibly (a forced reconnect, A4, is not needed here: B4 already logged in afresh) |
| B7 | both nodes, later | `DROP ROLE replicator`, delete the old `pg_hba.conf` line, reload | the old identity is gone |

At no point does the standby lack a credential the writer accepts. Under synchronous replication the link was in
`sync` state before, during and after the move.

**The role name is data, not a constant (done 2026-11-21).** It lives in a secret file next to the password,
`secrets/pg-replication-user.txt`, mounted in both containers. The standby entrypoint, the init script and the
scripts read it from there (`container::secret` for the scripts), so a rotation never edits a container's
environment and never restarts a node. The name alternates between replicator_a and replicator_b; the first
rotation moves from the original `replicator` to replicator_a.

### Which method when

| Situation | Method |
|---|---|
| Synchronous replication, or any time a stalled commit is unacceptable | **B** |
| Asynchronous replication and a quiet system | A, scripted, safe order |
| The superuser `postgres` | A (it has no long-lived replication connection; its users read the file when they run) |
| The standby is down or lagging | **B**, and keep the old identity until both nodes are confirmed on the new one |

## 6. Rotating the superuser password

`postgres` is used by `pg_rewind` (the connection to the node it copies from) and by TCP clients. There is no
long-lived connection to protect, so Method A is enough:

1. `ALTER ROLE postgres PASSWORD :'pw'` on the writer. The hash replicates.
2. Write the new value into `secrets/pg-password.txt` in place.
3. Prove it from the other container over TCP: the new password logs in, the old one is refused.
4. Prove the real consumer: run the failover and fail-back round trip, which uses the file for `pg_rewind`.

The only window is between step 1 and step 2, in which a script that reads the file would present a password the
database no longer accepts. It affects a script run, not replication or application writes, so do not run a failover
in that gap.

## 7. What is special about two databases

- **"Primary" is not a fixed node.** After a failover the roles swap. Run `ALTER ROLE` and `CREATE ROLE` on whichever
  node reports `pg_is_in_recovery() = f` at that moment.
- **`pg_hba.conf` must change on both nodes.** The standby today is the writer tomorrow. If only one node has the new
  line, the failover succeeds and the *old primary cannot rejoin* later. This is a latent fault: it passes every test
  until the day it matters.
- **primary_conninfo exists on both nodes and is rewritten on every rebuild.** When the old primary is rebuilt as a
  standby, `container::mark_standby` writes the writer's current secret into it. So the secret file must be updated
  *before* the next rebuild, which is why rotation and failover must not overlap.
- **A standby that was down during the change** still has the old primary_conninfo. It catches up the new hash
  through WAL when it returns, but cannot reconnect under Method A. Under Method B the old identity still works, so it
  reconnects, catches up, and is then moved.
- **Order of confirmation:** retire the old identity only after *both* nodes are confirmed on the new one, because
  either could be the writer tomorrow.

## 8. Runbook (Method B, replication password)

`bash scripts/rotate-secret.sh` does the steps below, and `--secret superuser` rotates the superuser password
in place. After any interruption, run it again: it converges. The manual steps are kept here so the script can be
read against them. Preconditions: `bash scripts/restore-starting-state.sh` passes (writer, one streaming standby); no failover or
rebuild is running.

1. Generate the new secret into a file made under `umask 077`; never type it on a command line.
2. B1 to B3. Stop here if B3 fails; nothing has changed for the standby.
3. B4, B5. If B5 does not show `replicator_b streaming`, switch primary_conninfo back; the old identity is intact.
4. Update `secrets/pg-replication-password.txt` in place and check that the container sees the same bytes
   (`cksum` of the host file and of `/run/secrets/pg-replication-password` must match).
5. B6. Check `streaming` as the new role again, then retire the old role.
6. Run `bash scripts/run-all-checks.sh` (the round trip rebuilds and clones with the new secret).
7. After the soak period, B7.

The secret reaches `psql` like this: the first line of standard input is the secret, the rest is the SQL. This is
`access::run_sql` in [lib/access.sh](../lib/access.sh).

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

2026-11-20, one machine, PostgreSQL 16, the two-node stack. A write probe inserted a row on the writer about every
0.1 s throughout and recorded failures and the slowest insert (which includes about 100 ms of `docker exec`).

| # | Experiment | Result |
|---|---|---|
| 1 | Method A on `replicator`, asynchronous, under load | 104 inserts, **0 failed**; the standby ended with all 104 rows; the new hash was on the standby; after a forced reconnect the link was `streaming` as `replicator` |
| 2 | Method A, `ALTER SYSTEM` on the standby | `postgresql.auto.conf` went from **86** lines containing `password=` to **1** |
| 3 | Secret file edited in place | the running container saw the change within 2 s (checksums matched) |
| 4 | Method B, synchronous, under load | role replicator_b created, allowed on both nodes, proven alone with `IDENTIFY_SYSTEM`, standby moved; link `streaming sync` before, during and after; old role `NOLOGIN`, forced reconnect still `streaming sync` |
| 5 | Method A, synchronous, safe order | 60 inserts, 0 failed, slowest 108 ms |
| 6 | Method B back to the original identity, synchronous | 49 inserts, 0 failed, slowest 121 ms |
| 7 | **The window**: synchronous, password changed, link killed *before* the standby had the new password | standby log: "password authentication failed for user replicator"; the link stayed down; **one commit stalled for 9.2 s**; 0 inserts failed, 0 lost; recovered as soon as the standby was given the new password |
| 8 | Method A in the safe order, original password restored, synchronous | 42 inserts, 0 failed, slowest 319 ms |
| 9 | Superuser, Method A | new password logged in over TCP to both nodes; the old password was refused; the failover and fail-back round trip (including `pg_rewind`) passed with the new password |
| 10 | Cleanup of the 2026-11-20 session | both secret files byte-identical to the originals; temporary role and `pg_hba.conf` lines gone from both nodes; asynchronous mode; one streaming standby |
| 11 | The append fix (2026-11-21) | after the fix each node holds exactly 1 primary_conninfo line after a full round trip and after a standby built from an empty volume; 9 more hard kills ended with 1 per node |
| 12 | `rotate-secret.sh` replication, by overlap (2026-11-21) | `replicator` became replicator_a in 1.6 s: role created, allowed on both nodes, proven alone, standby moved, files updated in place and seen by both containers, old role dropped, its `pg_hba.conf` line removed on both nodes, no temporary files left |
| 13 | `test-rotation.sh`, three runs | each run rotated replication, superuser, replication again under a write probe (32 to 50 rows per run): **0 failed writes**, the standby always streamed as the role in the secret file, one replication role left, the superuser file password logged in over the network, and a standby built from an **empty volume** joined with the rotated secret files |
| 14 | `test-hard-kill.sh --target rotate` | 25 SIGKILLs of `rotate-secret.sh` at 0.1 s to 1.3 s (the whole run is about 1.3 s): re-running it recovered every time, with the standby streaming as the role the files name, one replication role left, and the files' login working |
| 15 | **Finding from experiment 14** | an earlier version forced a reconnect after the file update. A kill just after it left the standby reconnecting (up to 5 s), and the re-run refused to start because the standby was not streaming. Fixed twice: the forced reconnect is gone (it was redundant and would stall synchronous commits) and `check_ready` now waits up to 30 s for streaming |

What the measurements do and do not say: the safe order caused no visible stall at this load; the deliberate window
caused a 9.2 s stall. A light, single-writer probe does not show how long a real window lasts under heavy load.

## 10. What is not solved yet

| ID | Gap | Detail and next step |
|---|---|---|
| SEC-01 | **No script and no automatic test: fixed 2026-11-21** | `rotate-secret.sh` (overlap for replication, in place for the superuser, rollback before the files change, converges when re-run), `test-rotation.sh` and `test-hard-kill.sh --target rotate`. Still manual: choosing when to rotate and the soak period (`--keep-old` stops at NOLOGIN) |
| SEC-02 | **Stale passwords piled up on disk: fixed 2026-11-21** | `container::mark_standby` and the standby entrypoint *appended* primary_conninfo on every rebuild, so a rotated-out password stayed in the file in plain text (88 lines on the primary, 3 on the standby). Both now replace the two settings in a new file moved into place, and `test-hard-kill.sh` fails if a node holds more than one |
| SEC-03 | **The replication role name was hard-coded: fixed 2026-11-21** | It is now the `pg-replication-user` secret file (see section 5) |
| SEC-04 | **File secrets are a development convenience** | Plain files on the developer's machine, and primary_conninfo holds the password in plain text. A real system needs a secret manager and certificate or token authentication |
| SEC-05 | **Edits that replace the file** | An in-place write reached the container. An editor that saves by creating a new file changes the inode and may not. Always compare checksums, as in the runbook. Recreating a container to pick up a secret restarts that node |
| SEC-06 | **Application clients** | The platform's services will have their own database role. They need the same overlap (two roles, or a connection pool that re-authenticates), and a test that rotates under load |
| SEC-07 | **Very long windows and heavy load** | Not measured |
| SEC-08 | **The in-place file write is not atomic** | `cat new > file` truncates then writes, so a container could read an empty file for a moment. `rotate-secret.sh` refuses to start while a rebuild is pending or the standby is not streaming, but nothing stops a rebuild starting during a rotation. Next step: a lock |

## Related

- [Verify after act](patterns/verify-after-act.md): the read-back habit used in steps B3, B5 and A4.
- [Split-brain guard](patterns/split-brain-guard.md): why a restarted node must not become a second writer; a node
  that cannot authenticate is the quiet version of the same problem.
- [capability-register.md](../capability-register.md): the evidence and gaps for every capability.
