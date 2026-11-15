"""Errors (spec §17): every error has a code from the catalogue (`ERROR_CODES`),
a message (`reason`), a hint, and a JSON form for tools and agents (`to_json`).
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable

from ._error_codes import ERROR_CODES, ErrorCode

PathKey = str | int
"""A step of a path to a value: a record key or an index."""

_KEY = re.compile(r"[a-z_][A-Za-z0-9_]*")
DOCS = "https://haus-fmt.org/docs/errors"


def format_path(path: Iterable[PathKey]) -> str:
    """`$.items[2].price`, `$["x-y"]`."""
    parts = (
        f"[{p}]" if isinstance(p, int) else f".{p}" if _KEY.fullmatch(p) else f"[{json.dumps(p, ensure_ascii=False)}]"
        for p in path
    )
    return "$" + "".join(parts)


def is_error_code(s: object) -> bool:
    """Whether `s` is an error code of the catalogue (spec §17)."""
    return isinstance(s, str) and s in ERROR_CODES


def error_docs(code: ErrorCode) -> str:
    """The documentation of an error code: `https://haus-fmt.org/docs/errors#<code>`."""
    return f"{DOCS}#{code}"


class HausError(ValueError):
    """Every error haus reports (spec §17): a stable `code`, a `reason`, a `hint` and `to_json()`.

    `expected` and `found` say what should be there and what is, where that is natural.
    """

    code: ErrorCode
    """The error's code (spec §17): stable, the same in every binding, e.g. `payload-newline`."""
    reason: str
    """The message, without the position."""
    hint: str
    """A concrete fix: the catalogue's fix for the code, unless the error knows a better one."""
    expected: str | None
    found: str | None

    def __init__(
        self,
        message: str,
        *,
        code: ErrorCode,
        reason: str,
        hint: str | None = None,
        expected: str | None = None,
        found: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.reason = reason
        self.hint = ERROR_CODES[code].hint if hint is None else hint
        self.expected = expected
        self.found = found

    @property
    def docs(self) -> str:
        """`https://haus-fmt.org/docs/errors#<code>`"""
        return error_docs(self.code)

    def _place(self) -> dict[str, object]:
        """Where the error is: `line` and `column`, or `path`."""
        return {}

    def to_json(self) -> dict[str, object]:
        """The JSON form of spec §17: `{ code, message, line?, column?, path?, expected?, found?, hint, docs }`.

        Members that don't apply are left out. `json.dumps(e.to_json())` gives the text.
        """
        out: dict[str, object] = {"code": self.code, "message": self.reason, **self._place()}
        if self.expected is not None:
            out["expected"] = self.expected
        if self.found is not None:
            out["found"] = self.found
        out["hint"] = self.hint
        out["docs"] = self.docs
        return out


class HausSyntaxError(HausError):
    """Input that isn't valid haus. The position is 1-based; columns count code points (spec §8)."""

    offset: int
    """Offset in code points from the start of the text."""
    line: int
    column: int

    def __init__(
        self,
        reason: str,
        offset: int,
        line: int,
        column: int,
        code: ErrorCode,
        *,
        hint: str | None = None,
        expected: str | None = None,
        found: str | None = None,
    ) -> None:
        super().__init__(
            f"{reason} at {line}:{column}", code=code, reason=reason, hint=hint, expected=expected, found=found
        )
        self.offset = offset
        self.line = line
        self.column = column

    @classmethod
    def at(
        cls,
        text: str,
        pos: int,
        code: ErrorCode,
        reason: str,
        *,
        hint: str | None = None,
        expected: str | None = None,
        found: str | None = None,
    ) -> HausSyntaxError:
        """An error at code point `pos` of `text`."""
        last_newline = text.rfind("\n", 0, pos)
        line = text.count("\n", 0, pos) + 1
        return cls(reason, pos, line, pos - last_newline, code, hint=hint, expected=expected, found=found)

    def moved(self, offset: int, line: int, column: int) -> HausSyntaxError:
        """The same error at another position (of a text that holds this one's)."""
        return type(self)(
            self.reason,
            offset,
            line,
            column,
            self.code,
            hint=self.hint,
            expected=self.expected,
            found=self.found,
        )

    def _place(self) -> dict[str, object]:
        return {"line": self.line, "column": self.column}


class HausJsonError(HausError):
    """JSON that can't be read (spec §16).

    Either a text that isn't I-JSON within the limits, with a 1-based `line` and `column`
    (code points), or JSON that isn't a form of the mapping, with the `path` of the value.
    """

    line: int | None
    column: int | None
    path: tuple[PathKey, ...]

    def __init__(
        self,
        reason: str,
        *,
        code: ErrorCode,
        line: int | None = None,
        column: int | None = None,
        path: tuple[PathKey, ...] = (),
        hint: str | None = None,
        expected: str | None = None,
        found: str | None = None,
    ) -> None:
        where = f"{line}:{column}" if line is not None else format_path(path)
        super().__init__(f"{reason} at {where}", code=code, reason=reason, hint=hint, expected=expected, found=found)
        self.line = line
        self.column = column
        self.path = path

    @classmethod
    def at(
        cls,
        text: str,
        pos: int,
        code: ErrorCode,
        reason: str,
        *,
        expected: str | None = None,
        found: str | None = None,
    ) -> HausJsonError:
        """A syntax error at code point `pos` of `text`."""
        last_newline = text.rfind("\n", 0, pos)
        line, column = text.count("\n", 0, pos) + 1, pos - last_newline
        return cls(reason, code=code, line=line, column=column, expected=expected, found=found)

    def with_line(self, line: int) -> HausJsonError:
        """The same error on another line (of JSON Lines)."""
        return HausJsonError(
            self.reason,
            code=self.code,
            line=line,
            column=self.column,
            hint=self.hint,
            expected=self.expected,
            found=self.found,
        )

    def _place(self) -> dict[str, object]:
        if self.line is not None:
            return {"line": self.line, "column": self.column}
        return {"path": format_path(self.path)}


class HausLimitsError(HausError):
    """Limits this binding can't use (spec §7): a `max_depth` above `MAX_SUPPORTED_DEPTH`, or not a whole number.

    Raised when the `Limits` are made, not by any input. Its code is `unsupported-depth`.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(reason, code="unsupported-depth", reason=reason)
