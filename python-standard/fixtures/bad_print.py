# expect: ruff T201
"""Printing instead of logging."""


def shout() -> None:
    """Print a message."""
    print("hello")
