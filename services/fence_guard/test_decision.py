"""Tests for the guard's decision."""

from fence_guard.decision import should_fence


def test_writer_with_expired_lease_is_fenced() -> None:
    """A writer whose lease ran out must be stopped."""
    assert should_fence(in_recovery=False, lease_expired=True)


def test_writer_with_live_lease_is_kept() -> None:
    """A writer with a lease in date is left alone."""
    assert not should_fence(in_recovery=False, lease_expired=False)


def test_writer_without_a_lease_is_kept() -> None:
    """With no lease installed there is nothing to enforce."""
    assert not should_fence(in_recovery=False, lease_expired=None)


def test_replica_is_never_fenced() -> None:
    """A replica takes no writes, so an expired lease does not matter."""
    assert not should_fence(in_recovery=True, lease_expired=True)
