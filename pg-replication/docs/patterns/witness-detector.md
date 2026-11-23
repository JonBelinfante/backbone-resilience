# Witness detector

**Pattern:** declare a node dead only when two independent observers agree, and say "cannot tell" rather than guess when one of them cannot see.

## Problem

A controller that probes the writer alone cannot tell "the writer is down" from "I cannot reach the writer". Acting on the second
promotes a healthy writer and creates two. A pause or a short network blip must not trigger a failover either.

## Mechanism

| Where | What it does |
|---|---|
| [services/failover_controller/detector.py](../../../services/failover_controller/detector.py), `Detector.observe` | A pure decision from the controller's probe and the standby's report. Returns one verdict |
| [services/failover_controller/probe.py](../../../services/failover_controller/probe.py) | Probes the writer through the proxy, and asks the standby how recently it heard from the writer |
| [lib/controller.sh](../../lib/controller.sh), `controller::start` | Runs the controller in a container; the test script reads its decisions |

The verdicts: `healthy`; `suspect` (a probe failed, not yet enough); `fail-over` (three failed probes in a row **and** a standby
that hears nothing); `hold-writer-alive` (the controller cannot reach the writer but the standby still hears it); `cannot-fail-over`
(the standby's view is unavailable); `writer-read-only`.

## Guards against

A false failover from a pause, a one-sided partition, or a blind observer.

## Evidence

- **DET-01:** a 3 s freeze gave `suspect` then `healthy`, no failover. A hung writer was declared after 6.4 s. A controller cut off from a live writer with traffic gave `hold-writer-alive`, never `fail-over`.
- **Control (the trap):** with an idle writer and a short witness window the same one-sided cut gave a false `fail-over`.

## Limits

- **The witness window must exceed the writer's quietest gap.** An idle writer talks to its standby only about every 30 s, so a short window sees silence that is not failure. Either set the window above 30 s (and accept the slower detection) or give the writer a heartbeat.
- The standby is a single witness. If it is partitioned the verdict is `cannot-fail-over`.
- Detection is nearly all of the downtime (2.8 to 8.3 s in ACT-01). Shorter timeouts shorten it and raise the false-alarm risk.

## Related

[Lease and guard](lease-and-guard.md), [Restartable actor](restartable-actor.md).
