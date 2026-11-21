# expect: ruff FBT001
"""A boolean positional argument."""


def switch(flag: bool) -> str:
    """Name a flag."""
    return "on" if flag else "off"
