# expect: waiver
"""A waiver comment: the standard refuses it."""


def shout() -> None:
    """Print a message."""
    print("hello")  # noqa: T201
