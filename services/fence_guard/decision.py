"""The guard's decision, pure so it can be tested without a database."""


def should_fence(*, in_recovery: bool, lease_expired: bool | None) -> bool:
    """Decide whether the guarded node must be stopped now.

    A replica takes no writes, so it is never fenced. A node with no lease installed
    (``lease_expired`` is None) is not fenced either: the guard only enforces a lease that exists.

    Args:
        in_recovery: whether the node is a replica.
        lease_expired: whether the lease has run out, or None if there is no lease.

    Returns:
        True if the node accepts writes and its lease has run out.
    """
    return (not in_recovery) and lease_expired is True
