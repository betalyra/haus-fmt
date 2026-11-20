"""haus: a data format for humans, friendly to write and pleasant to read.

Without a schema, `parse_all` reads any haus text into `Value`s:

    >>> import haus
    >>> haus.parse('{ name: "Ada", born: Date("1815-12-10") }')
    Record(fields={'name': String(value='Ada'), 'born': Variant(tag='Date', args=(String(value='1815-12-10'),))})

This is a parser in the sense of spec §13.1: it reads the syntax and knows no
types. `Date("2026-02-30")` is just a tag with a string.
"""

from __future__ import annotations

from ._canonical import canonical, compare, equals, hash, hash_all
from ._error_codes import ERROR_CODES, ErrorCategory, ErrorCode, ErrorInfo
from ._errors import HausError, HausJsonError, HausLimitsError, HausSyntaxError, error_docs, is_error_code
from ._json_api import (
    from_haus_json,
    from_haus_json_lines,
    import_json,
    import_json_lines,
    to_haus_json,
    to_haus_json_lines,
)
from ._parser import DEFAULT_LIMITS, MAX_SUPPORTED_DEPTH, Limits, Parser
from ._stream import DEFAULT_MAX_VALUE_LENGTH, Readable, StreamReader, parse_stream
from ._value import Array, Bytes, Number, Record, String, Value, Variant

__version__ = "0.0.1"

__all__ = [
    "DEFAULT_LIMITS",
    "DEFAULT_MAX_VALUE_LENGTH",
    "ERROR_CODES",
    "MAX_SUPPORTED_DEPTH",
    "Array",
    "Bytes",
    "ErrorCategory",
    "ErrorCode",
    "ErrorInfo",
    "HausError",
    "HausJsonError",
    "HausLimitsError",
    "HausSyntaxError",
    "Limits",
    "Number",
    "Readable",
    "Record",
    "StreamReader",
    "String",
    "Value",
    "Variant",
    "__version__",
    "canonical",
    "compare",
    "equals",
    "error_docs",
    "from_haus_json",
    "from_haus_json_lines",
    "hash",
    "hash_all",
    "import_json",
    "import_json_lines",
    "is_error_code",
    "parse",
    "parse_all",
    "parse_bytes",
    "parse_stream",
    "to_haus_json",
    "to_haus_json_lines",
]


def parse_all(text: str, *, limits: Limits = DEFAULT_LIMITS) -> list[Value]:
    """Parse a file: zero or more top-level values, separated by commas."""
    return Parser(text, limits).parse_sequence()


def parse(text: str, *, limits: Limits = DEFAULT_LIMITS) -> Value:
    """Parse a text that must hold exactly one value (spec §6)."""
    values = parse_all(text, limits=limits)
    if len(values) != 1:
        n = len(values)
        raise HausSyntaxError(
            f"expected exactly one value, found {n}",
            0,
            1,
            1,
            "not-one-value",
            expected="one value",
            found=f"{n} values",
        )
    return values[0]


def parse_bytes(data: bytes, *, limits: Limits = DEFAULT_LIMITS) -> list[Value]:
    """Parse raw bytes, which must be UTF-8. A leading byte order mark is skipped."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        valid = data[: e.start].decode("utf-8")
        raise HausSyntaxError.at(valid, len(valid), "invalid-utf8", "invalid UTF-8") from None
    return parse_all(text, limits=limits)
