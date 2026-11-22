"""Failure detection for the failover controller: pure decisions, no input or output.

The detector sees two vantage points. The controller's own probe of the writer says whether the
writer answers the controller. The standby's view says whether the writer is still feeding the
standby. Failing over needs both to agree the writer is gone: a controller cut off from a healthy
writer must not promote.
"""

from dataclasses import dataclass
from enum import Enum


class Verdict(Enum):
    """What the controller concludes after one round of probes."""

    HEALTHY = "healthy"
    SUSPECT = "suspect"
    FAIL_OVER = "fail-over"
    HOLD_WRITER_ALIVE = "hold-writer-alive"
    CANNOT_FAIL_OVER = "cannot-fail-over"
    WRITER_READ_ONLY = "writer-read-only"


@dataclass(frozen=True, kw_only=True)
class Observation:
    """One round of probes.

    Attributes:
        writer_answers: the writer answered the controller's probe in time.
        writer_in_recovery: the writer reports it is a standby (meaningful if it answers).
        standby_answers: the standby answered the controller's probe in time.
        standby_in_recovery: the standby is in recovery, so it can be promoted.
        standby_receiving: the standby reports a recent message from the writer.
    """

    writer_answers: bool
    writer_in_recovery: bool
    standby_answers: bool
    standby_in_recovery: bool
    standby_receiving: bool


class Detector:
    """Counts consecutive failed probes of the writer and turns each round into a verdict."""

    def __init__(self, threshold: int) -> None:
        """Create a detector that needs this many consecutive failures before it decides.

        Args:
            threshold: consecutive failed probes of the writer before a decision, at least 1.

        Raises:
            ValueError: if the threshold is below 1.
        """
        if threshold < 1:
            message = "threshold must be at least 1"
            raise ValueError(message)
        self.threshold = threshold
        self.failures = 0

    def observe(self, observation: Observation) -> Verdict:
        """Take one round of probes and return the verdict.

        Args:
            observation: what the probes saw this round.

        Returns:
            The verdict. FAIL_OVER only when the writer has failed the controller's probe
            `threshold` times in a row, the standby is ready to be promoted, and the standby
            no longer hears from the writer either.
        """
        if observation.writer_answers:
            self.failures = 0
            if observation.writer_in_recovery:
                return Verdict.WRITER_READ_ONLY
            return Verdict.HEALTHY
        self.failures += 1
        if self.failures < self.threshold:
            return Verdict.SUSPECT
        if not (observation.standby_answers and observation.standby_in_recovery):
            return Verdict.CANNOT_FAIL_OVER
        if observation.standby_receiving:
            return Verdict.HOLD_WRITER_ALIVE
        return Verdict.FAIL_OVER
