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

from ._value import Array, Bytes, Number, Record, String, Value, Variant

_BARE_KEY = re.compile(r"[a-z_][A-Za-z0-9_]*")
# What a string can't hold raw: quote, backslash, control and bidi characters,
# and the line and paragraph separators U+2028 and U+2029.
_ESCAPED = re.compile(r'["\\\x00-\x1f\x7f-\x9f\u2028-\u202e\u2066-\u2069]')
_SHORT_ESCAPES = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def _escape(m: re.Match[str]) -> str:
    c = m[0]
    return _SHORT_ESCAPES.get(c) or f"\\u{{{ord(c):X}}}"


def quote(s: str) -> str:
    """A `"…"` string with the minimal escapes; the rest as `\\u{…}` in uppercase hex."""
    return '"' + _ESCAPED.sub(_escape, s) + '"'


def _write(root: Value) -> str:
    """Iterative, with a stack of what is left to write (values, and text between them): any depth works."""
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
                # Always the normalized decimal literal, however long (spec §12).
                out.append(text)
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
    """The canonical form of a value (spec §12). Every value has one: integers are written in decimal, however long."""
    return _write(value)


def equals(a: Value, b: Value) -> bool:
    """Whether two values are equal (spec §2): the same normalized literals, and so the same canonical form."""
    return _write(a) == _write(b)


def compare(a: Value, b: Value) -> int:
    """Orders values by the bytes of their canonical forms (spec §12): -1, 0 or 1.

    A total order consistent with `equals`, for sorting
    (`sorted(values, key=functools.cmp_to_key(compare))`) and ordered maps.
    Not numeric order: `10` sorts before `9`.
    """
    x, y = _write(a), _write(b)
    return (x > y) - (x < y)


def hash(value: Value) -> str:
    """The SHA-256 digest of the canonical form, as 64 lowercase hex digits (spec §12)."""
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def hash_all(values: Iterable[Value]) -> str:
    """The hash of a list of values, such as a whole file (spec §12).

    The SHA-256 digest of their canonical forms joined by `,`. A list of one
    value hashes like the value: `hash_all([v]) == hash(v)`. The items of a
    stream are hashed one by one with `hash`.
    """
    return hashlib.sha256(",".join(map(canonical, values)).encode("utf-8")).hexdigest()
