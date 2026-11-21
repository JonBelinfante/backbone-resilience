# expect: ruff DTZ005
"""A datetime without a timezone."""

from datetime import datetime


def now() -> datetime:
    """Return the current time with no timezone."""
    return datetime.now()
