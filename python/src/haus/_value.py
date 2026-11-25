"""The haus data model, exactly as written in the source (spec §1).

No schema has been applied: numbers keep their exact literal text, and
variants are generic. Equality follows spec §2: field order doesn't matter,
`1.0` and `1` are different numbers, and `Tag { … }` equals `Tag({ … })`.

The constructors build only haus values (spec §11, "Values built in code"):
they raise `HausEncodeError` (at the path `$`) for anything else, so what
they build can always be written, compared and hashed.

    >>> Number("1E+05"), Number("0xFF")
    (Number(text='1e5'), Number(text='255'))
    >>> Number("01")
    Traceback (most recent call last):
    ...
    haus._errors.HausEncodeError: not a number literal: "01" at $

Values are immutable, and can't be subclassed. One built past the
constructors (`object.__new__`, `object.__setattr__`) isn't a haus value:
what any function does with it is undefined.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from decimal import Decimal
from types import MappingProxyType
from typing import Final, Never, TypeAlias, cast, final, overload

from ._error_codes import ErrorCode
from ._errors import HausEncodeError
from ._scan import NORMALIZED_NUMBER, TAG, quote_for_message

_SURROGATE: Final = re.compile(r"[\ud800-\udfff]")


def _fail(code: ErrorCode, reason: str) -> Never:
    raise HausEncodeError(reason, (), code)


def _sealed(cls: type) -> Never:
    raise TypeError(f"{cls.__mro__[1].__name__} can't be subclassed: a haus value is one of the six classes")


def _str(s: object, what: str) -> str:
    """`s` as Unicode text: an exact `str` without lone surrogates."""
    if type(s) is not str:
        if not isinstance(s, str):
            _fail("cannot-encode", f"{what} that isn't a str: {type(s).__name__}")
        s = str.__str__(s)  # a plain copy of a subclass
    if not s.isascii() and _SURROGATE.search(s):
        _fail("cannot-encode", f"{what} with a lone surrogate (not Unicode text)")
    return s


def _values(values: object, what: str) -> tuple[Value, ...]:
    """The items of an array or the arguments of a variant: a tuple of haus values."""
    if type(values) is not tuple and not isinstance(values, Iterable):
        _fail("cannot-encode", f"{what} that aren't an iterable of values: {type(values).__name__}")
    items = tuple(cast("Iterable[object]", values))  # a tuple itself, not a copy
    if not _VALUE_TYPES.issuperset(map(type, items)):
        odd = next(x for x in items if type(x) not in _VALUE_TYPES)
        _fail("cannot-encode", f"{what} with something that isn't a haus value: {type(odd).__name__}")
    return cast("tuple[Value, ...]", items)


@final
@dataclass(frozen=True, slots=True, init=False)
class Number:
    """An exact number: the normalized literal (spec §2).

    Built from any number literal, normalized as the parser normalizes it, with no limit
    on its length or exponent: digit separators are removed, the exponent is written as
    its value, and hex and binary literals become decimal integers: `"19.90"`, `"-1e10"`, `"255"`.
    Text that isn't a number literal (`"01"`, `"NaN"`, `""`) is `invalid-number`, and
    anything but a `str` `cannot-encode`.
    """

    text: str

    def __init__(self, text: str) -> None:
        _set_text(self, text if type(text) is str and NORMALIZED_NUMBER.fullmatch(text) else _normalized(text))

    def __init_subclass__(cls) -> None:
        _sealed(cls)

    def is_integer_literal(self) -> bool:
        """Whether the literal is written as an integer (no fraction, no exponent)."""
        return "." not in self.text and "e" not in self.text

    def to_int(self) -> int:
        """The value as an `int`. Raises `ValueError` unless it is written as an integer."""
        if not self.is_integer_literal():
            raise ValueError(f"not an integer literal: {self.text}")
        return int(self.text)

    def to_decimal(self) -> Decimal:
        """The exact value. `Decimal` keeps the scale: `19.90` stays `19.90`."""
        return Decimal(self.text)


def _normalized(text: object) -> str:
    """The normalized text of a literal in another spelling (`1_000` → `1000`), without limits."""
    from ._number import UNLIMITED, normalize_number  # the parser's, which imports the values

    literal = _str(text, "a number")
    if (normalized := normalize_number(literal, UNLIMITED)) is None:
        _fail("invalid-number", f'not a number literal: "{quote_for_message(literal)}"')
    return normalized


@final
@dataclass(frozen=True, slots=True, init=False)
class String:
    """A string: Unicode text. One with a lone surrogate, which has no UTF-8 form, is `cannot-encode`."""

    value: str

    def __init__(self, value: str) -> None:
        _set_value(self, value if type(value) is str and value.isascii() else _str(value, "a string"))

    def __init_subclass__(cls) -> None:
        _sealed(cls)


@final
@dataclass(frozen=True, slots=True, init=False)
class Bytes:
    """A byte string, written `x"0b34ff"`. A `bytearray` or `memoryview` is copied to `bytes`."""

    data: bytes

    def __init__(self, data: bytes | bytearray | memoryview) -> None:
        _set_data(self, data if type(data) is bytes else _bytes(data))

    def __init_subclass__(cls) -> None:
        _sealed(cls)


def _bytes(data: object) -> bytes:
    if not isinstance(data, bytes | bytearray | memoryview):
        _fail("cannot-encode", f"bytes that aren't bytes: {type(data).__name__}")
    return bytes(cast("bytes", data))


@final
@dataclass(frozen=True, slots=True, init=False)
class Array:
    """Values in order, from any iterable of values."""

    items: tuple[Value, ...]

    def __init__(self, items: Iterable[Value] = ()) -> None:
        _set_items(self, _values(items, "items"))

    def __init_subclass__(cls) -> None:
        _sealed(cls)

    def __eq__(self, other: object) -> bool:
        return _equal(self, other) if type(other) is Array else NotImplemented

    def __hash__(self) -> int:
        return _hash(self)

    def __repr__(self) -> str:
        return _repr(self)


@final
@dataclass(frozen=True, slots=True, init=False, repr=False)
class Record:
    """Fields in source order, from a mapping or (key, value) pairs. Keys are data: they never become
    attributes (spec §9.4).

    `fields` is a read-only view of the record's own copy, so a record never changes. A key that
    occurs twice among the pairs is `duplicate-key`; a key with a lone surrogate `cannot-encode`.
    """

    fields: Mapping[str, Value]

    @overload
    def __init__(self, fields: Mapping[str, Value] = ..., /) -> None: ...
    @overload
    def __init__(self, fields: Iterable[tuple[str, Value]], /) -> None: ...
    def __init__(self, fields: Mapping[str, Value] | Iterable[tuple[str, Value]] = (), /) -> None:
        _set_fields(self, MappingProxyType(_fields(fields)))

    def __init_subclass__(cls) -> None:
        _sealed(cls)

    def __eq__(self, other: object) -> bool:
        return _equal(self, other) if type(other) is Record else NotImplemented

    def __repr__(self) -> str:
        return _repr(self)

    def __reduce__(self) -> tuple[type[Record], tuple[dict[str, Value]]]:
        return Record, (dict(self.fields),)


def _fields(fields: object) -> dict[str, Value]:
    pairs: Iterable[tuple[object, object]]
    if type(fields) is dict or isinstance(fields, Mapping):
        pairs = cast("Mapping[object, object]", fields).items()
    elif isinstance(fields, Iterable):
        pairs = map(_pair, cast("Iterable[object]", fields))
    else:
        _fail("cannot-encode", f"fields that aren't a mapping or pairs: {type(fields).__name__}")
    out: dict[str, Value] = {}
    for k, v in pairs:
        key = k if type(k) is str and k.isascii() else _str(k, "a key")
        if type(v) not in _VALUE_TYPES:
            _fail("cannot-encode", f"a field with something that isn't a haus value: {type(v).__name__}")
        if key in out:
            _fail("duplicate-key", f'the key "{quote_for_message(key)}" twice')
        out[key] = cast("Value", v)
    return out


def _pair(pair: object) -> tuple[object, object]:
    fields = cast("Sequence[object]", pair)
    if isinstance(pair, tuple | list) and len(fields) == 2:
        return fields[0], fields[1]
    _fail("cannot-encode", f"a field that isn't a (key, value) pair: {type(fields).__name__}")


@final
@dataclass(frozen=True, slots=True, init=False)
class Variant:
    """A tag with zero or more arguments, from any iterable of values. `Tag { … }` has one `Record` argument.

    A tag that isn't `[A-Z][A-Za-z0-9_]*` is `invalid-tag`, one with a lone surrogate included: the tag
    is checked before it is encoded (spec §11).
    """

    tag: str
    args: tuple[Value, ...]

    def __init__(self, tag: str, args: Iterable[Value] = ()) -> None:
        if type(tag) is not str or TAG.fullmatch(tag) is None:
            if isinstance(cast("object", tag), str) and TAG.fullmatch(tag) is None:
                _fail("invalid-tag", f'the tag "{quote_for_message(tag)}" isn\'t [A-Z][A-Za-z0-9_]*')
            tag = _str(tag, "a tag")
        _set_tag(self, tag)
        _set_args(self, _values(args, "arguments"))

    def __init_subclass__(cls) -> None:
        _sealed(cls)

    def __eq__(self, other: object) -> bool:
        return _equal(self, other) if type(other) is Variant else NotImplemented

    def __hash__(self) -> int:
        return _hash(self)

    def __repr__(self) -> str:
        return _repr(self)


Value: TypeAlias = Number | String | Bytes | Array | Record | Variant

_VALUE_TYPES: Final = frozenset({Number, String, Bytes, Array, Record, Variant})


# ── `==` and `hash` without recursion (spec §7: values built in code may be of any depth) ──

_ABSENT: Final = object()


def _equal(a: Value, b: Value) -> bool:
    """`a == b` by spec §2 (fields in any order), with a stack of pairs instead of recursion."""
    pairs: list[tuple[object, object]] = [(a, b)]
    while pairs:
        x, y = pairs.pop()
        if x is y:
            continue
        kind = type(x)
        if kind is not type(y):
            return False
        if kind is Array:
            xs, ys = cast(Array, x).items, cast(Array, y).items
            if len(xs) != len(ys):
                return False
            pairs.extend(zip(xs, ys, strict=True))
        elif kind is Variant:
            vx, vy = cast(Variant, x), cast(Variant, y)
            if vx.tag != vy.tag or len(vx.args) != len(vy.args):
                return False
            pairs.extend(zip(vx.args, vy.args, strict=True))
        elif kind is Record:
            fx, fy = cast(Record, x).fields, cast(Record, y).fields
            if len(fx) != len(fy):
                return False
            for key, value in fx.items():
                if (other := fy.get(key, _ABSENT)) is _ABSENT:
                    return False
                pairs.append((value, other))
        elif x != y:  # Number, String, Bytes: their one field
            return False
    return True


def _hash(v: Array | Variant) -> int:
    """`hash(v)`, from its values in pre-order, with a stack instead of recursion. A record is unhashable."""
    parts: list[object] = []
    todo: list[Value] = [v]
    while todo:
        x = todo.pop()
        match x:
            case Array(items):
                parts += (Array, len(items))
                todo.extend(reversed(items))
            case Variant(tag, args):
                parts += (Variant, tag, len(args))
                todo.extend(reversed(args))
            case Record():
                raise TypeError("unhashable type: 'Record'")
            case _:
                parts.append(x)  # Number, String, Bytes: hashable themselves
    return hash(tuple(parts))


def _repr(v: Array | Record | Variant) -> str:
    """`repr(v)` as a dataclass writes it (`Array(items=(Number(text='1'),))`), with a stack instead of recursion.

    The stack holds values to write and text (a `str`) to write as it is."""
    out: list[str] = []
    todo: list[Value | str] = [v]

    def tuple_of(values: Sequence[Value | str], end: str) -> None:
        """`(a, b)`, `(a,)` or `()`, then `end`, pushed to be written in order."""
        todo.append(("," if len(values) == 1 else "") + ")" + end)
        for i in reversed(range(len(values))):
            todo.append(values[i])
            if i:
                todo.append(", ")

    while todo:
        x = todo.pop()
        match x:
            case str():
                out.append(x)
            case Array(items):
                out.append("Array(items=(")
                tuple_of(items, ")")
            case Variant(tag, args):
                out.append(f"Variant(tag={tag!r}, args=(")
                tuple_of(args, ")")
            case Record(fields):
                out.append("Record(fields={")
                todo.append("})")
                pairs = list(fields.items())
                for i in reversed(range(len(pairs))):
                    key, value = pairs[i]
                    todo += (value, f"{', ' if i else ''}{key!r}: ")
            case _:
                out.append(repr(x))  # Number, String, Bytes: one field
    return "".join(out)


def _setter(cls: type, name: str) -> Callable[[object, object], None]:
    """Sets a field of a value as it is built (the fields are frozen afterwards)."""
    return cast("Callable[[object, object], None]", cls.__dict__[name].__set__)


_set_text: Final = _setter(Number, "text")
_set_value: Final = _setter(String, "value")
_set_data: Final = _setter(Bytes, "data")
_set_items: Final = _setter(Array, "items")
_set_fields: Final = _setter(Record, "fields")
_set_tag: Final = _setter(Variant, "tag")
_set_args: Final = _setter(Variant, "args")
_new: Final = object.__new__


# ── unchecked: for the parser, the readers and the encoders, whose values are checked already ──


def number_unchecked(text: str) -> Number:
    """A number from a normalized literal."""
    v = _new(Number)
    _set_text(v, text)
    return v


def string_unchecked(value: str) -> String:
    """A string from Unicode text (no lone surrogates)."""
    v = _new(String)
    _set_value(v, value)
    return v


def bytes_unchecked(data: bytes) -> Bytes:
    v = _new(Bytes)
    _set_data(v, data)
    return v


def array_unchecked(items: tuple[Value, ...]) -> Array:
    v = _new(Array)
    _set_items(v, items)
    return v


def record_unchecked(fields: dict[str, Value]) -> Record:
    """A record from fields with Unicode keys, which it keeps: the caller never changes them again."""
    v = _new(Record)
    _set_fields(v, MappingProxyType(fields))
    return v


def variant_unchecked(tag: str, args: tuple[Value, ...] = ()) -> Variant:
    """A variant from a tag (`[A-Z][A-Za-z0-9_]*`)."""
    v = _new(Variant)
    _set_tag(v, tag)
    _set_args(v, args)
    return v
