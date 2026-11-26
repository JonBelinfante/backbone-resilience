# Witness detector

<!-- toc -->

- [Problem](#problem)
- [Mechanism](#mechanism)
- [Guards against](#guards-against)
- [Evidence](#evidence)
- [Limits](#limits)
- [Related](#related)

<!-- tocstop -->

**Pattern:** declare a node dead only when two independent observers agree. Say "cannot tell" when one observer cannot see, and do not guess.

## Problem

A controller that probes the writer alone cannot tell "the writer is down" from "I cannot reach the writer". If it acts on the second case, it promotes a healthy writer and creates two. A pause or a short network blip must not trigger a failover either.

## Mechanism

| Where | What it does |
|---|---|
| [services/failover_controller/detector.py](../../../services/failover_controller/detector.py), `Detector.observe` | Makes a pure decision from the controller's probe and the standby's report. It returns one verdict. |
| [services/failover_controller/probe.py](../../../services/failover_controller/probe.py) | Probes the writer through the proxy, and asks the standby how recently it heard from the writer. |
| [lib/controller.sh](../../lib/controller.sh), `controller::start` | Runs the controller in a container. The test script reads its decisions. |

The detector returns one of six verdicts.

- `healthy`: the writer answers.
- `suspect`: a probe failed, but not enough probes have failed yet.
- `fail-over`: three probes in a row failed, and the standby hears nothing from the writer.
- `hold-writer-alive`: the controller cannot reach the writer, but the standby still hears it.
- `cannot-fail-over`: the standby's view is unavailable.
- `writer-read-only`: the node that should be the writer is a replica.

## Guards against

A false failover can come from a pause, a one-sided partition or a blind observer. The two-view rule prevents it.

## Evidence

- **DET-01.** A 3-second freeze gave `suspect` and then `healthy`, with no failover. A hung writer was declared failed after 6.4 seconds. A controller that was cut off from a live writer with traffic gave `hold-writer-alive` and never `fail-over`.
- **The control, which is the trap.** The writer was idle and the witness window was short. The same one-sided cut then gave a false `fail-over`.

## Limits

- **The witness window must exceed the writer's quietest gap.** An idle writer talks to its standby only about every 30 seconds. A short window therefore sees a silence that is not a failure. Either set the window above 30 seconds and accept slower detection, or give the writer a heartbeat.
- The standby is a single witness. If the standby is partitioned, the verdict is `cannot-fail-over`.
- Detection is nearly all of the downtime, which is 2.8 to 8.3 seconds in ACT-01. Shorter timeouts shorten it, but they raise the risk of a false alarm.

## Related

[Lease and guard](lease-and-guard.md) and [restartable actor](restartable-actor.md).
