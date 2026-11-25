# Glossary

This page defines each term that the repository uses, once. Terms are in alphabetical order. Where a term has a page of its own, the entry links to it. The identifiers, such as FOV-02, are rows in the [capability register](../pg-replication/capability-register.md).

| Term | Meaning |
|---|---|
| Acknowledged write | A write for which the database has told the client that it succeeded. Loss is counted only for acknowledged writes. |
| Actor | The program that carries out a failover. It raises the epoch, stops the old writer and promotes the standby. It can be killed and run again. See [restartable actor](../pg-replication/docs/patterns/restartable-actor.md). |
| Archive | The copy of every completed write-ahead log segment, kept in the `pg-archive` volume. Point-in-time recovery reads from it. |
| Asynchronous replication | The writer acknowledges a commit before the standby has the change. Writes never wait for the standby. A crash can lose the writes that the standby had not received. |
| Base backup | A full copy of the data directory, kept in the `pg-backup` volume. It is the starting point for point-in-time recovery. |
| Checker | The component, planned for the application layer, that asserts the platform's invariants after every fault. It is not built yet. |
| Controller | The program that watches the writer, renews its lease and decides when to fail over. There is one controller, which is a known limit (GAP-07). |
| Crash | A process killed without warning, with `docker kill`. It is not a power cut, because the host's page cache survives. |
| Detector | The part of the controller that decides whether the writer has failed. It uses two views. See [witness detector](../pg-replication/docs/patterns/witness-detector.md). |
| Epoch | A number that only goes up, one for each failover. It orders the writers, and an interrupted failover reuses its number. See [epoch](../pg-replication/docs/patterns/epoch-fencing-token.md). |
| Fence | A marker in a stopped node's data directory that makes any start read-only. It stops a restarted old writer from accepting writes. |
| Guard | A check that refuses a dangerous action. The promotion guard and the split-brain guard are script checks. The lease guard is a process beside the writer that stops it when its lease expires. See [lease and guard](../pg-replication/docs/patterns/lease-and-guard.md). |
| Hot standby | A replica that applies the write-ahead log and answers read-only queries. |
| Hot-cold | One node writes and the other follows. This is what the repository builds now. |
| Hot-hot | Both nodes accept writes. It is planned for Phases 4 and 5 and is not built. |
| Lease | A row on the writer with an expiry time. The controller renews it. A writer whose lease has expired must stop taking writes. |
| Log sequence number (LSN) | A position in the write-ahead log. Point-in-time recovery stops at a recorded LSN. |
| Maintenance lock | A lock that lets one script at a time change the nodes. It stops two actors or two rotations from running together. |
| Negative control | A variant of a test that must fail. It proves that the test can see the fault. See [negative control](../pg-replication/docs/patterns/negative-control.md). |
| Old primary | The node that was the writer before a failover. It must rejoin as a standby and never as a second writer. |
| pg_basebackup | The PostgreSQL tool that clones a running node. The repository uses it to build a standby from nothing. |
| pg_rewind | The PostgreSQL tool that rewinds an old primary to the point where it diverged from the new writer. It needs a cleanly stopped node. |
| Point-in-time recovery | Restoring a base backup and replaying the archive up to a recorded position. It undoes a mistake that replication has copied. |
| Primary | The node that is the writer at the start. After a failover the roles swap, so the name refers to the starting state. |
| Prober | A client that writes at a steady rate and records which writes were acknowledged. The measurements use it to count loss and downtime. |
| Rebuild-pending marker | A file written before a data directory changes and removed once the node streams. A node that still has it is cloned and never rewound. |
| Recovery point objective (RPO) | The amount of acknowledged data that may be lost. The observed RPO is the number of acknowledged writes missing on the surviving node. |
| Recovery time objective (RTO) | The time that clients may be unable to write. The observed RTO is the time until a client's write succeeds. |
| Replica | Any node that follows another. The standby is a replica. |
| Replication slot | A record on the writer that keeps the write-ahead log that a standby has not yet received. A dead standby makes the log grow, so the repository bounds it. |
| Split brain | Two nodes accepting writes at once. Their data diverges, and one side's writes must be discarded. |
| Standby | The node that follows the writer and can be promoted. |
| Synchronous replication | The writer waits for the standby before it acknowledges a commit. The RPO is 0, but writes block while the standby is down. |
| Timeline | A number that PostgreSQL raises at each promotion. It tells apart the histories of two nodes. |
| Toxiproxy | A proxy that injects network faults: delay, jitter, bandwidth limits, silence and cut links. It has one proxy for each node, so the tests can fault the traffic to either node. |
| Write-ahead log (WAL) | The stream of changes that PostgreSQL records before it applies them. Replication and recovery both read it. |
| Write check | A trigger on a table that refuses a write when the lease has expired. It closes the window where a paused writer resumes. It is opt-in for each table. |
| Writer | The node that currently accepts writes. |
