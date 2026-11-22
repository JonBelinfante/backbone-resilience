"""Run the failover controller: probe, decide, log, and renew the writer's lease; never promote."""

import logging
import os
import sys
import time
from pathlib import Path

from failover_controller.detector import Detector, Observation, Verdict
from failover_controller.probe import Target, probe_standby, probe_writer, renew_lease

LOG = logging.getLogger("failover_controller")


def observe(writer: Target, standby: Target, max_age_seconds: int) -> Observation:
    """Probe both nodes once and combine the answers.

    Args:
        writer: how to reach the node that should be the writer.
        standby: how to reach the node that should be promoted.
        max_age_seconds: how recent the standby's last message from the writer must be.

    Returns:
        What the two probes saw.
    """
    writer_recovery = probe_writer(writer)
    standby_view = probe_standby(standby, max_age_seconds)
    return Observation(
        writer_answers=writer_recovery is not None,
        writer_in_recovery=bool(writer_recovery),
        standby_answers=standby_view is not None,
        standby_in_recovery=standby_view is not None and standby_view[0],
        standby_receiving=standby_view is not None and standby_view[1],
    )


def run(writer: Target, standby: Target, settings: dict[str, int]) -> None:
    """Probe forever, logging every round and every change of verdict.

    Args:
        writer: how to reach the node that should be the writer.
        standby: how to reach the node that should be promoted.
        settings: threshold, interval_seconds, max_age_seconds and lease_ttl_seconds (0 = no lease).
    """
    detector = Detector(settings["threshold"])
    previous: Verdict | None = None
    while True:
        started = time.monotonic()
        observation = observe(writer, standby, settings["max_age_seconds"])
        verdict = detector.observe(observation)
        LOG.info("probe failures=%d %s", detector.failures, observation)
        if (
            settings["lease_ttl_seconds"] > 0
            and observation.writer_answers
            and not observation.writer_in_recovery
            and not renew_lease(writer, settings["lease_ttl_seconds"])
        ):
            LOG.info("lease not renewed")
        if verdict is not previous:
            LOG.info(
                "DECISION verdict=%s failures=%d epoch=%.3f",
                verdict.value,
                detector.failures,
                time.time(),
            )
            previous = verdict
        time.sleep(max(0.0, settings["interval_seconds"] - (time.monotonic() - started)))


def main() -> None:
    """Read the settings from the environment and run (detect only: it changes nothing)."""
    logging.basicConfig(
        stream=sys.stdout,
        level=logging.INFO,
        format="%(asctime)s.%(msecs)03dZ %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    logging.Formatter.converter = time.gmtime
    password = Path(os.environ["PASSWORD_FILE"]).read_text(encoding="utf-8").strip()
    timeout = int(os.environ.get("PROBE_TIMEOUT_SECONDS", "2"))
    port = int(os.environ.get("DATABASE_PORT", "5432"))
    writer_port = int(os.environ.get("WRITER_PORT", str(port)))
    writer = Target(os.environ["WRITER_HOST"], writer_port, password, timeout)
    standby = Target(os.environ["STANDBY_HOST"], port, password, timeout)
    settings = {
        "threshold": int(os.environ.get("THRESHOLD", "3")),
        "interval_seconds": int(os.environ.get("INTERVAL_SECONDS", "1")),
        "max_age_seconds": int(os.environ.get("WITNESS_MAX_AGE_SECONDS", "5")),
        "lease_ttl_seconds": int(os.environ.get("LEASE_TTL_SECONDS", "0")),
    }
    LOG.info("DECISION detect-only controller started: %s", settings)
    run(writer, standby, settings)


if __name__ == "__main__":
    main()
