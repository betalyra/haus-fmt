from __future__ import annotations

import json
import re
from collections.abc import Iterable

PathKey = str | int
"""A step of a path to a value: a record key or an index."""

_KEY = re.compile(r"[a-z_][A-Za-z0-9_]*")


def format_path(path: Iterable[PathKey]) -> str:
    """`$.items[2].price`, `$["x-y"]`."""
    parts = (
        f"[{p}]" if isinstance(p, int) else f".{p}" if _KEY.fullmatch(p) else f"[{json.dumps(p, ensure_ascii=False)}]"
        for p in path
    )
    return "$" + "".join(parts)


class HausSyntaxError(ValueError):
    """Input that isn't valid haus. The position is 1-based; columns count code points (spec §8)."""

    reason: str
    """The message without the position."""
    offset: int
    """Offset in code points from the start of the text."""
    line: int
    column: int

    def __init__(self, reason: str, offset: int, line: int, column: int) -> None:
        super().__init__(f"{reason} at {line}:{column}")
        self.reason = reason
        self.offset = offset
        self.line = line
        self.column = column

    @classmethod
    def at(cls, text: str, pos: int, reason: str) -> HausSyntaxError:
        """An error at code point `pos` of `text`."""
        last_newline = text.rfind("\n", 0, pos)
        return cls(reason, pos, text.count("\n", 0, pos) + 1, pos - last_newline)


class HausJsonError(ValueError):
    """JSON that can't be read (spec §16).

    Either a text that isn't I-JSON within the limits, with a 1-based `line` and `column`
    (code points), or JSON that isn't a form of the mapping, with the `path` of the value.
    """

    reason: str
    """The message without the position."""
    line: int | None
    column: int | None
    path: tuple[PathKey, ...]

    def __init__(
        self, reason: str, *, line: int | None = None, column: int | None = None, path: tuple[PathKey, ...] = ()
    ) -> None:
        where = f"{line}:{column}" if line is not None else format_path(path)
        super().__init__(f"{reason} at {where}")
        self.reason = reason
        self.line = line
        self.column = column
        self.path = path

    @classmethod
    def at(cls, text: str, pos: int, reason: str) -> HausJsonError:
        """A syntax error at code point `pos` of `text`."""
        last_newline = text.rfind("\n", 0, pos)
        return cls(reason, line=text.count("\n", 0, pos) + 1, column=pos - last_newline)
