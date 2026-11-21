# expect: ruff BLE001
"""A blind except that hides every error."""


def risky() -> int:
    """Return one, hiding any failure."""
    try:
        return int("1")
    except Exception:
        return 0
