# Design principles

<!-- toc -->

- [Principles](#principles)
- [Definitions](#definitions)
- [Target architecture and the checker](#target-architecture-and-the-checker)
- [Where this stands](#where-this-stands)

<!-- tocstop -->

This page states the ideas that guide the later phases. Phase 1 proves the database layer. These principles describe the application layer that Phases 2 and 3 would add on top of it.

## Principles

1. **The log is the truth.** Every database is a rebuildable projection of a log prefix. Recovery means catching up from a stored position. It does not mean restoring to a point in time.
2. **Position, not time.** Each consumer commits its watermark in the same transaction as the state change.
3. **Per-aggregate sequence numbers.** A version at or below the last applied one is a duplicate. A version one above is applied. A version more than one above is a gap, which the consumer parks and reports.
4. **The outbox location matters.** Compare three designs. The first appends to the log first. The second uses an outbox with synchronous replication. The third uses an outbox with asynchronous replication, where the recovery point objective equals the relay lag.
5. **Consistency has two scopes.** It is strong inside an aggregate and eventual between aggregates. Sagas and compensating events connect aggregates, and history is never edited.
6. **Fencing is mandatory for failover.** An epoch or a lease stops a returning old primary from accepting writes.
7. **Decisions never read lagging replicas or projections.**
8. **Replay is safe.** Projections are deterministic. Effectful reactors are suppressed during replay. Events carry enough data to rebuild state. Retention covers the longest rebuild.
9. **Hot-hot is four different things.** Build them as switchable modes. They are hot-cold asynchronous, hot-cold synchronous, hot-hot with partitioned ownership, and hot-hot multi-writer. Only commutative data merges cleanly in the last mode.
10. **Database replication and application replication are layers, not alternatives.** Run the same faults against both.

## Definitions

- **Recovery point objective (RPO)** is the acceptable data loss. Synchronous replication gives 0, and asynchronous replication gives the replication lag. The *observed RPO* is the number of acknowledged writes that are missing on the surviving site.
- **Recovery time objective (RTO)** is the acceptable downtime. The *observed RTO* is the time until a client-side prober sees success.
- **99.999% availability** allows about 26 seconds of downtime a month. Measure from the client's view, and report the error-budget burn for each experiment. The controller and the router are usually the weakest link.

## Target architecture and the checker

The target runs on one machine with Docker Compose. It has two sites. Each site has stateless service instances, a PostgreSQL database and an outbox relay. A broker connects the sites, with an event archive. Toxiproxy sits on every link. A router with health checks works with a failover controller that uses fencing epochs. A load generator issues payments with idempotency keys. Prometheus and Grafana provide monitoring.

An independent **checker** watches everything. It is the most important component. It asserts the following, continuously and after every fault.

- Every committed change has exactly one outbox event.
- No effect is applied twice.
- No sequence has a gap.
- The fold of the archive equals the current state.
- The ledger reconciles to the simulated payment service provider (PSP) statement.
- Every projection converges within its staleness service level objective (SLO).

Each chaos experiment needs a hypothesis, a fault, the expected behaviour, pass criteria and an abort condition. The guide to [adding an experiment](adding-an-experiment.md) gives the template.

## Where this stands

Phase 1 and the failover-safety part of Phase 2 are built and proven. The application layer, the checker and the later phases are not started. The [roadmap](../README.md#roadmap-and-status) gives the state of each phase, and the [capability register](../pg-replication/capability-register.md) lists the open gaps.
