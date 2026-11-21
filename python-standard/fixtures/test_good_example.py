"""Tests for the good example: they prove the test runner works under the standard."""

from good_example import Attempt, count_acknowledged, too_many_failures


def test_counts_only_acknowledged_attempts() -> None:
    """Only acknowledged attempts are counted."""
    attempts = [
        Attempt(seq=1, acknowledged=True),
        Attempt(seq=2, acknowledged=False),
        Attempt(seq=3, acknowledged=True),
    ]
    assert count_acknowledged(attempts) == 2


def test_failure_limit() -> None:
    """More than the limit of failures is too many; the limit itself is not."""
    failed = [Attempt(seq=n, acknowledged=False) for n in range(4)]
    assert too_many_failures(failed)
    assert not too_many_failures(failed[:3])
