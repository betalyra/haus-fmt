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
from collections.abc import Iterable, Iterator, Mapping
from itertools import chain, repeat
from typing import Final

from ._scan import ESCAPED, key_text, quote
from ._value import Array, Bytes, Number, Record, String, Value, Variant

_Children = Iterator[tuple[str, Value]]
"""What is left to write of a container: each child with the text before it (`,`, `key:`, `,key:`)."""

_FIRST_KEYS: dict[str, str] = {}
"""`key:` of keys written before: field names repeat, from record to record and value to value."""
_NEXT_KEYS: dict[str, str] = {}
"""`,key:` the same way."""
_KEYS_KEPT: Final = 4096
"""At most this many keys in each of them (they start over when full), each at most `_KEY_KEPT` long."""
_KEY_KEPT: Final = 64


def _key_prefix(key: str, keys: dict[str, str], comma: str) -> str:
    text = keys.get(key)
    if text is None:
        text = f"{comma}{key_text(key)}:"
        if len(key) <= _KEY_KEPT:
            if len(keys) >= _KEYS_KEPT:
                keys.clear()
            keys[key] = text
    return text


def _fields(fields: Mapping[str, Value]) -> _Children:
    # `str` order is code point order, which is the order of the UTF-8 bytes.
    keys = sorted(fields)
    texts = [_NEXT_KEYS.get(k) or _key_prefix(k, _NEXT_KEYS, ",") for k in keys]
    if keys:
        texts[0] = _FIRST_KEYS.get(keys[0]) or _key_prefix(keys[0], _FIRST_KEYS, "")
    return zip(texts, map(fields.__getitem__, keys), strict=True)


def _items(values: tuple[Value, ...]) -> _Children:
    return zip(chain(("",), repeat(",")), values, strict=False)


def _numbers(values: tuple[Value, ...]) -> str | None:
    """An array of numbers (a vector, coordinates) written at once; None for any other."""
    if not values or type(values[0]) is not Number:
        return None
    texts = [x.text for x in values if type(x) is Number]
    return "[" + ",".join(texts) + "]" if len(texts) == len(values) else None


def _write(root: Value) -> str:
    """Iterative, with a stack of the open containers: any depth works.

    Scalars are written where they are met; a container is opened, and its children are written
    before the rest of its parent's.
    """
    out: list[str] = []
    write = out.append
    escaped = ESCAPED.search
    stack: list[tuple[_Children, str]] = []
    children: _Children = iter((("", root),))
    closer = ""
    while True:
        for prefix, v in children:
            write(prefix)
            # The most common first, by exact type (subclasses below).
            if type(v) is String:
                s = v.value
                write(f'"{s}"' if escaped(s) is None else quote(s))
                continue
            if type(v) is Number:
                write(v.text)  # always the normalized decimal literal, however long (spec §12)
                continue
            if type(v) is Record:
                write("{")
                inner, inner_closer = _fields(v.fields), "}"
            elif type(v) is Array and (numbers := _numbers(v.items)) is not None:
                write(numbers)
                continue
            else:
                match v:
                    case String(s):
                        write(quote(s))
                        continue
                    case Number(text):
                        write(text)
                        continue
                    case Bytes(data):
                        write(f'x"{data.hex()}"')
                        continue
                    case Array(values):
                        write("[")
                        inner, inner_closer = _items(values), "]"
                    case Record(fields):
                        write("{")
                        inner, inner_closer = _fields(fields), "}"
                    case Variant(tag, ()):
                        write(tag)
                        continue
                    case Variant(tag, (Record(fields),)):
                        write(tag + "{")
                        inner, inner_closer = _fields(fields), "}"
                    case Variant(tag, args):
                        write(tag + "(")
                        inner, inner_closer = _items(args), ")"
            stack.append((children, closer))
            children, closer = inner, inner_closer
            break
        else:
            write(closer)
            if not stack:
                return "".join(out)
            children, closer = stack.pop()


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
