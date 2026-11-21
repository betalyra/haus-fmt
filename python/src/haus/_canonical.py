"""The canonical form, equality and hashing (spec §12): one exact text per
value, the same in every binding. Equal values (§2) have identical canonical
forms, so `hash` is the same whatever the layout, comments, key order or
spelling of the document the value came from.

    >>> import haus
    >>> haus.canonical(haus.parse('Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }'))
    'Order{id:255,total:19.90,"x-y":1e5}'

A value built in code is checked as the writer checks it (`stringify`), without the limits:
a number is written normalized (`Number("1E+05")` as `1e5`), and a value that has no text raises
`haus.schema.HausEncodeError` with its code and path.
"""

from __future__ import annotations

import hashlib
import re
from collections.abc import Iterable, Iterator, Mapping, Sequence
from itertools import chain, repeat
from typing import Final, Never, cast

from ._decode import HausEncodeError
from ._error_codes import ErrorCode
from ._errors import PathKey
from ._number import UNLIMITED, normalize_number
from ._scan import ESCAPED, TAG, key_text, quote
from ._value import Array, Bytes, Number, Record, String, Value, Variant

_Children = Iterator[tuple[str, Value]]
"""What is left to write of a container: each child with the text before it (`,`, `key:`, `,key:`)."""

_FIRST_KEYS: dict[str, str] = {}
"""`key:` of keys written before: field names repeat, from record to record and value to value."""
_NEXT_KEYS: dict[str, str] = {}
"""`,key:` the same way."""
_TAGS: dict[str, None] = {}
"""Tags written before, which are tags."""
_KEYS_KEPT: Final = 4096
"""At most this many keys (and tags) in each of them (they start over when full), each at most `_KEY_KEPT` long."""
_KEY_KEPT: Final = 64

_SURROGATE: Final = re.compile(r"[\ud800-\udfff]")
_ESCAPED_OR_SURROGATE: Final = re.compile(ESCAPED.pattern[:-1] + r"\ud800-\udfff]")
"""What a string can't hold raw, and the lone surrogates (not Unicode text) it can't hold at all."""
_NUMBER: Final = r"-?(?:[1-9][0-9]*+|0)(?:\.[0-9]++)?(?:e-?[1-9][0-9]*+|e0)?"
_NUMBERS: Final = re.compile(f"{_NUMBER}(?:\x00{_NUMBER})*+")
"""Normalized literals (spec §2) separated by NULs: the numbers of a value, checked at once."""
_DEEP: Final = 4096
"""Nesting at which the fast writer hands over to the checked one, which notices a value that contains itself."""


class _Recheck(Exception):
    """Something the fast writer doesn't write: the checked writer writes it, or reports why it can't."""


def _key_prefix(key: str, keys: dict[str, str], comma: str) -> str:
    if type(key) is not str or (not key.isascii() and _SURROGATE.search(key)):
        raise _Recheck
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


def _numbers(values: tuple[Value, ...]) -> list[str] | None:
    """The texts of an array of numbers (a vector, coordinates), written at once; None for any other."""
    if not values or type(values[0]) is not Number:
        return None
    texts = [x.text for x in values if type(x) is Number]
    return texts if len(texts) == len(values) else None


def _tag(tag: str) -> str:
    """A tag the fast writer writes: one written before, or one that is a tag."""
    if tag not in _TAGS:
        if type(tag) is not str or not TAG.fullmatch(tag):
            raise _Recheck
        if len(_TAGS) >= _KEYS_KEPT:
            _TAGS.clear()
        if len(tag) <= _KEY_KEPT:
            _TAGS[tag] = None
    return tag


def _write(root: Value) -> str:
    """Iterative, with a stack of the open containers: any depth works.

    Scalars are written where they are met; a container is opened, and its children are written
    before the rest of its parent's. Values as the parser gives them, fast: number literals are
    collected and checked to be normalized at the end, in one match. Anything else (a number to
    normalize, a value with no text, nesting deeper than `_DEEP`) raises `_Recheck`.
    """
    out: list[str] = []
    write = out.append
    numbers: list[str] = []
    number = numbers.append
    escaped = _ESCAPED_OR_SURROGATE.search
    tags = _TAGS
    stack: list[tuple[_Children, str]] = []
    children: _Children = iter((("", root),))
    closer = ""
    while True:
        for prefix, v in children:
            write(prefix)
            # The most common first, by exact type (subclasses below).
            if type(v) is String:
                s = v.value
                if escaped(s) is None:
                    write(f'"{s}"')
                elif not s.isascii() and _SURROGATE.search(s):
                    raise _Recheck
                else:
                    write(quote(s))
                continue
            if type(v) is Number:
                t = v.text
                number(t)
                write(t)
                continue
            if type(v) is Record:
                write("{")
                inner, inner_closer = _fields(v.fields), "}"
            elif type(v) is Array and (texts := _numbers(v.items)) is not None:
                numbers.extend(texts)
                write("[" + ",".join(texts) + "]")
                continue
            else:
                match v:
                    case String() | Number():
                        raise _Recheck  # subclasses: rare
                    case Bytes(data) if type(data) is bytes or isinstance(data, bytearray):
                        write(f'x"{data.hex()}"')
                        continue
                    case Array(values):
                        write("[")
                        inner, inner_closer = _items(values), "]"
                    case Record(fields):
                        write("{")
                        inner, inner_closer = _fields(fields), "}"
                    case Variant(tag, ()):
                        write(tag if tag in tags else _tag(tag))
                        continue
                    case Variant(tag, (Record(fields),)):
                        write((tag if tag in tags else _tag(tag)) + "{")
                        inner, inner_closer = _fields(fields), "}"
                    case Variant(tag, args):
                        write((tag if tag in tags else _tag(tag)) + "(")
                        inner, inner_closer = _items(args), ")"
                    case _:
                        raise _Recheck
            if len(stack) >= _DEEP:
                raise _Recheck  # it might contain itself
            stack.append((children, closer))
            children, closer = inner, inner_closer
            break
        else:
            write(closer)
            if not stack:
                break
            children, closer = stack.pop()
    joined = "\x00".join(numbers)
    if numbers and (_NUMBERS.fullmatch(joined) is None or joined.count("\x00") != len(numbers) - 1):
        raise _Recheck  # a number to normalize, or one that isn't a number literal
    return "".join(out)


class _Checked:
    """The canonical form of any value built in code, checked as `stringify` checks it (without its
    limits): numbers normalized, and `HausEncodeError` at the first value in canonical order that has
    no text. Iterative, so any depth works; a value that contains itself is `cyclic-value`."""

    __slots__ = ("on_path", "out", "path")

    def __init__(self) -> None:
        self.out: list[str] = []
        self.path: list[PathKey] = []
        self.on_path: set[int] = set()
        """The ids of the open containers."""

    def fail(self, code: ErrorCode, reason: str) -> Never:
        raise HausEncodeError(reason, tuple(self.path), code)

    def string(self, s: object, what: str) -> str:
        if not isinstance(s, str):
            self.fail("cannot-encode", f"{what} that isn't a str: {type(s).__name__}")
        if not s.isascii() and _SURROGATE.search(s):
            self.fail("cannot-encode", f"{what} with a lone surrogate (not Unicode text)")
        return s

    def values(self, values: object, what: str) -> Sequence[object]:
        if not isinstance(values, tuple | list):
            self.fail("cannot-encode", f"{what} that aren't a tuple: {type(values).__name__}")
        return cast("Sequence[object]", values)

    def fields(self, fields: object) -> list[tuple[PathKey, str, object]]:
        """The fields in canonical order: (key, text before the value, value)."""
        if not isinstance(fields, Mapping):
            self.fail("cannot-encode", f"fields that aren't a mapping: {type(fields).__name__}")
        fs = cast("Mapping[object, object]", fields)
        keys = sorted(self.string(k, "a key") for k in fs)
        return [(k, f"{',' if i else ''}{key_text(k)}:", fs[k]) for i, k in enumerate(keys)]

    def open(self, container: object) -> None:
        if id(container) in self.on_path:
            self.fail("cyclic-value", "the value contains itself, so it has no finite text")
        self.on_path.add(id(container))

    def scalar(self, v: object) -> str | None:
        """The text of a scalar, or None for a container."""
        if isinstance(v, String):
            return quote(self.string(v.value, "a string"))
        if isinstance(v, Number):
            text = cast("object", v.text)  # anything, in a value built in code
            if not isinstance(text, str):
                self.fail("cannot-encode", f"a number whose text isn't a str: {type(text).__name__}")
            normalized = normalize_number(text, UNLIMITED)
            if normalized is None:
                self.fail("invalid-number", f"a number that isn't a number literal: {text!r}")
            return normalized
        if isinstance(v, Bytes):
            data = cast("object", v.data)
            if not isinstance(data, bytes | bytearray):
                self.fail("cannot-encode", f"bytes that aren't bytes: {type(data).__name__}")
            return f'x"{data.hex()}"'
        if isinstance(v, Variant):
            tag = cast("object", v.tag)
            if not isinstance(tag, str) or not TAG.fullmatch(tag):
                self.fail("invalid-tag", f"the tag {tag!r} isn't [A-Z][A-Za-z0-9_]*")
            return None if self.values(v.args, "arguments") else tag
        if isinstance(v, Array | Record):
            return None
        self.fail("cannot-encode", f"not a haus value: {type(v).__name__}")

    def write(self, root: object) -> str:
        write = self.out.append
        path = self.path
        # Each open container: its children left (path key, text before, value), its closer, its id.
        stack: list[tuple[Iterator[tuple[PathKey, str, object]], str, int]] = []
        children: Iterator[tuple[PathKey, str, object]] = iter((("", "", root),))
        closer = ""
        while True:
            for key, prefix, v in children:
                write(prefix)
                if stack:
                    path.append(key)
                text = self.scalar(v)
                if text is not None:
                    write(text)
                    if stack:
                        path.pop()
                    continue
                container: object = v
                inner: Iterator[tuple[PathKey, str, object]]
                if isinstance(v, Array):
                    self.open(v)
                    write("[")
                    items = self.values(v.items, "items")
                    inner = iter([(i, "," if i else "", x) for i, x in enumerate(items)])
                    inner_closer = "]"
                elif isinstance(v, Record):
                    self.open(v)
                    write("{")
                    inner, inner_closer = iter(self.fields(v.fields)), "}"
                else:
                    variant = cast("Variant", v)
                    args = self.values(variant.args, "arguments")
                    if len(args) == 1 and isinstance(record := args[0], Record):
                        container = record
                        self.open(record)
                        write(variant.tag + "{")
                        inner, inner_closer = iter(self.fields(record.fields)), "}"
                    else:
                        self.open(v)
                        write(variant.tag + "(")
                        inner = iter([(i, "," if i else "", x) for i, x in enumerate(args)])
                        inner_closer = ")"
                stack.append((children, closer, id(container)))
                children, closer = inner, inner_closer
                break
            else:
                write(closer)
                if not stack:
                    return "".join(self.out)
                children, closer, done = stack.pop()
                self.on_path.discard(done)
                if stack:
                    path.pop()


def _text(value: Value) -> str:
    try:
        return _write(value)
    except (_Recheck, TypeError, AttributeError):
        return _Checked().write(value)


def canonical(value: Value) -> str:
    """The canonical form of a value (spec §12). Every value has one: integers are written in decimal, however long.

    A value built in code is checked as `stringify` checks it, without the limits: its numbers are
    written normalized, and `haus.schema.HausEncodeError` is raised (spec §11) for a number whose
    text isn't a number literal (`invalid-number`), a tag that isn't `[A-Z][A-Za-z0-9_]*`
    (`invalid-tag`), a string or key with a lone surrogate or an object that isn't a haus value
    (`cannot-encode`), or a value that contains itself (`cyclic-value`).
    """
    return _text(value)


def equals(a: Value, b: Value) -> bool:
    """Whether two values are equal (spec §2): the same normalized literals, and so the same canonical form.

    Raises `HausEncodeError` as `canonical` does.
    """
    return _text(a) == _text(b)


def compare(a: Value, b: Value) -> int:
    """Orders values by the bytes of their canonical forms (spec §12): -1, 0 or 1.

    A total order consistent with `equals`, for sorting
    (`sorted(values, key=functools.cmp_to_key(compare))`) and ordered maps.
    Not numeric order: `10` sorts before `9`. Raises `HausEncodeError` as `canonical` does.
    """
    x, y = _text(a), _text(b)
    return (x > y) - (x < y)


def hash(value: Value) -> str:
    """The SHA-256 digest of the canonical form, as 64 lowercase hex digits (spec §12).

    Raises `HausEncodeError` as `canonical` does.
    """
    return hashlib.sha256(_text(value).encode("utf-8")).hexdigest()


def hash_all(values: Iterable[Value]) -> str:
    """The hash of a list of values, such as a whole file (spec §12).

    The SHA-256 digest of their canonical forms joined by `,`. A list of one
    value hashes like the value: `hash_all([v]) == hash(v)`. The items of a
    stream are hashed one by one with `hash`. Raises `HausEncodeError` as `canonical` does,
    with the value's index first in its path (as `stringify_all`).
    """
    vs = list(values)
    texts: list[str] = []
    for i, v in enumerate(vs):
        try:
            texts.append(_text(v))
        except HausEncodeError as e:
            if len(vs) == 1:
                raise
            raise HausEncodeError(e.reason, (i, *e.path), e.code) from None
    return hashlib.sha256(",".join(texts).encode("utf-8")).hexdigest()
