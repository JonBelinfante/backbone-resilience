"""A small module that follows the house Python standard; it must pass every check."""

import logging
from dataclasses import dataclass

LOGGER = logging.getLogger(__name__)
LIMIT = 3


@dataclass(frozen=True)
class Attempt:
    """One write attempt recorded by a prober.

    Attributes:
        seq: The attempt's sequence number.
        acknowledged: True if the database acknowledged the commit.
    """

    seq: int
    acknowledged: bool


def count_acknowledged(attempts: list[Attempt]) -> int:
    """Count the attempts the database acknowledged.

    Args:
        attempts: The attempts to look at.

    Returns:
        How many of them were acknowledged.
    """
    total = sum(1 for attempt in attempts if attempt.acknowledged)
    LOGGER.info("counted %d acknowledged attempts of %d", total, len(attempts))
    return total


def too_many_failures(attempts: list[Attempt]) -> bool:
    """Say whether more than LIMIT attempts failed.

    Args:
        attempts: The attempts to look at.

    Returns:
        True if the number of failed attempts is over the limit.
    """
    return len(attempts) - count_acknowledged(attempts) > LIMIT
