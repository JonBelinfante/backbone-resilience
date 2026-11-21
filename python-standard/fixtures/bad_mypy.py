# expect: mypy return-value
"""A type error that only the type checker sees."""


def label(number: int) -> str:
    """Return a label."""
    return number
