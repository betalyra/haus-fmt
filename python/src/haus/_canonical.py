"""The canonical form, equality and hashing (spec §12): one exact text per
value, the same in every binding. Equal values (§2) have identical canonical
forms, so `hash` is the same whatever the layout, comments, key order or
spelling of the document the value came from.

    >>> import haus
    >>> haus.canonical(haus.parse('Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }'))
    'Order{id:255,total:19.90,"x-y":1e5}'
"""

from __future__ import annotations

import hashlib
import re
from collections.abc import Iterable, Mapping
from decimal import Decimal
from typing import Self

from ._errors import HausError
from ._value import Array, Bytes, Number, Record, String, Value, Variant

_BARE_KEY = re.compile(r"[a-z_][A-Za-z0-9_]*")
_INTEGER = re.compile(r"-?[0-9]+")
# What a string can't hold raw: quote, backslash, control and bidi characters,
# and the line and paragraph separators U+2028 and U+2029.
_ESCAPED = re.compile(r'["\\\x00-\x1f\x7f-\x9f\u2028-\u202e\u2066-\u2069]')
HEX_THRESHOLD = 1000
"""Integers whose decimal form is longer are written in hex; longer still in hex, they have no canonical form.

A constant of the canonical form (spec §12), not the number limit of §7: it stays 1000 if the default limits grow.
"""
_SHORT_ESCAPES = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def _escape(m: re.Match[str]) -> str:
    c = m[0]
    return _SHORT_ESCAPES.get(c) or f"\\u{{{ord(c):X}}}"


def quote(s: str) -> str:
    """A `"…"` string with the minimal escapes; the rest as `\\u{…}` in uppercase hex."""
    return '"' + _ESCAPED.sub(_escape, s) + '"'


def number_text(text: str) -> str:
    """A normalized literal, or an integer longer than `HEX_THRESHOLD` in lowercase hex."""
    if len(text) <= HEX_THRESHOLD or not _INTEGER.fullmatch(text):
        return text
    sign, digits = ("-", text[1:]) if text.startswith("-") else ("", text)
    # Via Decimal: `int(str)` refuses more than 4300 digits.
    return f"{sign}0x{int(Decimal(digits)):x}"


def _canonical_number(text: str) -> str:
    """`number_text`, or `number-too-long` if even the hex form is longer than `HEX_THRESHOLD` (spec §12)."""
    written = number_text(text)
    if len(written) > HEX_THRESHOLD and _INTEGER.fullmatch(text):
        reason = f"an integer longer than {HEX_THRESHOLD} characters in hex has no canonical form"
        raise HausError(reason, code="number-too-long", reason=reason)
    return written


def _write(root: Value, checked: bool = True) -> str:
    """Iterative, with a stack of what is left to write (values, and text between them): any depth works.

    `checked`: fail on an integer with no canonical form. Unchecked, it is written in hex anyway,
    which still tells values apart: what equality and order need.
    """
    write_number = _canonical_number if checked else number_text
    out: list[str] = []
    work: list[Value | str] = [root]

    def items(values: tuple[Value, ...], close: str) -> None:
        work.append(close)
        for i in range(len(values) - 1, -1, -1):
            work.append(values[i])
            if i:
                work.append(",")

    def record(fields: Mapping[str, Value]) -> None:
        # `str` order is code point order, which is the order of the UTF-8 bytes.
        out.append("{")
        work.append("}")
        keys = sorted(fields)
        for i in range(len(keys) - 1, -1, -1):
            work.append(fields[keys[i]])
            work.append(("," if i else "") + _key(keys[i]) + ":")

    while work:
        match work.pop():
            case str() as text:
                out.append(text)
            case Number(text):
                out.append(write_number(text))
            case String(s):
                out.append(quote(s))
            case Bytes(data):
                out.append(f'x"{data.hex()}"')
            case Array(values):
                out.append("[")
                items(values, "]")
            case Record(fields):
                record(fields)
            case Variant(tag, ()):
                out.append(tag)
            case Variant(tag, (Record(fields),)):
                out.append(tag)
                record(fields)
            case Variant(tag, args):
                out.append(f"{tag}(")
                items(args, ")")
    return "".join(out)


def _key(k: str) -> str:
    return k if _BARE_KEY.fullmatch(k) else quote(k)


def canonical(value: Value) -> str:
    """The canonical form of a value (spec §12).

    Raises `HausError` (`number-too-long`) for an integer longer than 1000 characters even in hex,
    which has none; only a parser with a raised number limit, or code, makes one.
    """
    return _write(value)


def equals(a: Value, b: Value) -> bool:
    """Whether two values are equal (spec §2): the same normalized literals, and so the same canonical form."""
    return _write(a, checked=False) == _write(b, checked=False)


def compare(a: Value, b: Value) -> int:
    """Orders values by the bytes of their canonical forms (spec §12): -1, 0 or 1.

    A total order consistent with `equals`, for sorting
    (`sorted(values, key=functools.cmp_to_key(compare))`) and ordered maps.
    Not numeric order: `10` sorts before `9`.
    """
    x, y = _write(a, checked=False), _write(b, checked=False)
    return (x > y) - (x < y)


def hash(value: Value) -> str:
    """The SHA-256 digest of the canonical form, as 64 lowercase hex digits (spec §12)."""
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


class Hasher:
    """Hashes a list of values as it grows, e.g. a stream while it is read (spec §12).

    `digest()` gives `hash_all` of the values added so far, at any time.
    Memory stays bounded by the largest value.

        >>> import haus
        >>> h = haus.Hasher()
        >>> for v in haus.parse_all("1, 2,"):
        ...     _ = h.add(v)
        >>> h.digest() == haus.hash_all(haus.parse_all("1, 2"))
        True
    """

    __slots__ = ("_empty", "_sha")

    def __init__(self) -> None:
        self._sha = hashlib.sha256()
        self._empty = True

    def add(self, value: Value) -> Self:
        """Add the next value."""
        if not self._empty:
            self._sha.update(b",")
        self._empty = False
        self._sha.update(canonical(value).encode("utf-8"))
        return self

    def digest(self) -> str:
        """`hash_all` of the values added so far, as 64 lowercase hex digits."""
        return self._sha.copy().hexdigest()


def hash_all(values: Iterable[Value]) -> str:
    """The hash of a list of values, such as a whole file or stream (spec §12).

    The SHA-256 digest of their canonical forms joined by `,`. A list of one
    value hashes like the value: `hash_all([v]) == hash(v)`.
    """
    hasher = Hasher()
    for v in values:
        hasher.add(v)
    return hasher.digest()
