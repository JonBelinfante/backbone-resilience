# expect: ruff PLR0913
"""Five parameters: over the limit of four."""


def combine(a: int, b: int, c: int, d: int, e: int) -> int:
    """Add five numbers."""
    return a + b + c + d + e
