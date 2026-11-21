"""Decoding and encoding with a schema (spec §15): the resolved types of a
schema file (`_schema_file`) built into a tree of nodes, each with `decode`
(haus `Value` → Python) and `encode` (Python → `Value`), and the same with the
type's schema-based JSON (spec §16.3): `read_json` and `write_json`.

Linear whatever the schema (spec §9.8): a variant's case is one dict lookup
on its tag, the nesting depth is limited (256 by default), and every call has
a work budget, 16 steps per value of the input when decoding. A secret's
errors never show its value. The host types are described in `haus.schema`.
"""

from __future__ import annotations

import math
import re
import struct
from collections.abc import Callable, Iterable, Mapping, Sequence
from decimal import Decimal
from typing import Any, Final, Never, Protocol, TypeVar, cast

from ._error_codes import ErrorCode
from ._errors import HausError, HausJsonError, PathKey, format_path
from ._float import FloatKind, float_text, to_float32, to_float64
from ._host import Nothing, Secret, Some, Tagged, Unknown
from ._json import (
    Json,
    JsonNumber,
    describe,
    from_base64,
    from_self_describing,
    imported,
    json_number,
    self_describing,
    self_describing_arguments,
    to_base64,
)
from ._number import INTEGER, UNLIMITED, int_text, normalize_number, number_limit_issue, to_int
from ._parser import Limits, make_room
from ._scan import TAG, quote_for_message
from ._schema_file import (
    ArrayType,
    BuiltinType,
    MapType,
    MaybeType,
    NoPayload,
    ParamType,
    PositionalPayload,
    RecordPayload,
    RecordType,
    RefType,
    SecretType,
    StdType,
    Type,
    VariantType,
)
from ._schema_file import Instance as _Instance
from ._time import check as check_time
from ._value import Array, Bytes, Number, Record, String, Value, Variant

_SURROGATE = re.compile(r"[\ud800-\udfff]")

T = TypeVar("T")
V = TypeVar("V")

STEPS_PER_VALUE: Final = 16
DEFAULT_ENCODE_STEPS: Final = 16 * 1024 * 1024
_MAX_VALUES: Final = 64 * 1024 * 1024


class _ValueError(HausError):
    """An error at a place in a value: its `path`."""

    path: tuple[PathKey, ...]
    """Where the error is: `("items", 2, "price")`, written `$.items[2].price`."""

    def __init__(
        self,
        reason: str,
        path: tuple[PathKey, ...],
        code: ErrorCode,
        *,
        hint: str | None = None,
        expected: str | None = None,
        found: str | None = None,
    ) -> None:
        super().__init__(
            f"{reason} at {format_path(path)}", code=code, reason=reason, hint=hint, expected=expected, found=found
        )
        self.path = path

    def _place(self) -> dict[str, object]:
        return {"path": format_path(self.path)}


class HausDecodeError(_ValueError):
    """A value the type doesn't accept, with the place of the failing value (spec §15)."""


class HausEncodeError(_ValueError):
    """A Python value that doesn't fit its type when encoding."""


class Codec(Protocol):
    """A host type chosen by the application for a named type without arguments (spec §13.4).

    `decode` runs after the type's own decoding, on its default host value, and may reject
    more values (raise `ValueError`: a `HausDecodeError` with the code `codec-rejected`);
    `encode` gives back a default host value.
    """

    def decode(self, value: object, /) -> object: ...

    def encode(self, value: object, /) -> object: ...


# ── where a node is applied ──────────────────────────────────


class _Context:
    __slots__ = ("ancestors", "decoding", "json", "limits", "max_steps", "steps")

    def __init__(self, *, decoding: bool, limits: Limits, max_steps: int, json: bool = False) -> None:
        self.decoding = decoding
        self.json = json
        """Reading or writing JSON (spec §16): what has no JSON form is `no-json-form`."""
        self.limits = limits
        self.max_steps = max_steps
        self.steps = 0
        self.ancestors: set[int] = set()
        """Encoding: the ids of the containers on the current path, to detect values that contain themselves."""


_NO_KEY: Final = object()
_NOTHING: Final = object()
"""`Nothing()` where a `Some`'s value is expected."""
_MISS: Final = object()
"""What `_Node.quick` gives for a value it doesn't decode: `decode` then decodes it, or says what is wrong."""


class _At:
    """The place a node is applied: the path (linked to its parent, built only for errors) and the depth."""

    __slots__ = ("ctx", "depth", "key", "parent")

    def __init__(self, ctx: _Context, parent: _At | None, key: PathKey | None, depth: int) -> None:
        self.ctx = ctx
        self.parent = parent
        self.key = key
        self.depth = depth

    def child(self, key: PathKey) -> _At:
        if self.depth >= self.ctx.limits.max_depth:
            self.fail(f"nesting deeper than {self.ctx.limits.max_depth} levels", key, code="nesting-too-deep")
        return _At(self.ctx, self, key, self.depth + 1)

    def deeper(self) -> _At:
        """One level deeper at the same place: `Some(x)` written as `x` in schema-based JSON."""
        if self.depth >= self.ctx.limits.max_depth:
            self.fail(f"nesting deeper than {self.ctx.limits.max_depth} levels", code="nesting-too-deep")
        return _At(self.ctx, self, None, self.depth + 1)

    def member(self, key: str) -> _At:
        """A JSON member at the same level: the `"values"` array of a payload."""
        return _At(self.ctx, self, key, self.depth)

    def container(self) -> None:
        """Encoding a record, array or payload here: it is one more level of nesting when written."""
        if self.depth >= self.ctx.limits.max_depth:
            self.fail(f"nesting deeper than {self.ctx.limits.max_depth} levels", code="nesting-too-deep")

    def step(self) -> None:
        ctx = self.ctx
        ctx.steps += 1
        if ctx.steps > ctx.max_steps:
            mode = "decode" if ctx.decoding else "encode"
            self.fail(
                f"{mode} budget of {ctx.max_steps} steps exceeded (a schema doing more work than the input)",
                code="step-budget",
            )

    def path(self) -> tuple[PathKey, ...]:
        out: list[PathKey] = []
        at: _At | None = self
        while at is not None:
            if at.key is not None:
                out.append(at.key)
            at = at.parent
        return tuple(reversed(out))

    def fail(
        self,
        reason: str,
        child: object = _NO_KEY,
        *,
        code: ErrorCode | None = None,
        hint: str | None = None,
        expected: str | None = None,
        found: str | None = None,
    ) -> Never:
        """Fail here (or at `child`) with `code`; by default `type-mismatch`, or `cannot-encode` when encoding."""
        path = self.path() if child is _NO_KEY else (*self.path(), _path_key(child))
        error = HausDecodeError if self.ctx.decoding else HausEncodeError
        if code is None:
            code = "type-mismatch" if self.ctx.decoding else "cannot-encode"
        raise error(reason, path, code, hint=hint, expected=expected, found=found)

    def enter(self, obj: object) -> None:
        """Encoding: `obj` is being written here; meeting it again further down is a cycle."""
        if id(obj) in self.ctx.ancestors:
            self.fail("cyclic value: an object contains itself", code="cyclic-value")
        self.ctx.ancestors.add(id(obj))

    def leave(self, obj: object) -> None:
        self.ctx.ancestors.discard(id(obj))


def _path_key(k: object) -> PathKey:
    return k if isinstance(k, str | int) and not isinstance(k, bool) else _describe_py(k)


# ── descriptions for errors (bounded, spec §9.8) ─────────────


def _short(text: str, n: int = 30) -> str:
    """Text as a message shows it (spec §9.2): control and bidi characters escaped, then cut to `n`
    characters and `…` (never inside an escape)."""
    return quote_for_message(text, n + 1)


def _describe(v: Value) -> str:
    match v:
        case Number(text):
            return f"number {_short(text)}"
        case String(s):
            return f'string "{_short(s)}"'
        case Bytes(data):
            return f"bytes ({len(data)})"
        case Array():
            return "array"
        case Record():
            return "record"
        case Variant(tag):
            return f"variant {_short(tag)}"


def _describe_py(x: object) -> str:
    """A short description of a Python value. Never calls the value's own methods."""
    match x:
        case None:
            return "None"
        case bool():
            return repr(x)
        case int():
            return int_text(x) if x.bit_length() < 64 else f"an int of {x.bit_length()} bits"
        case float():
            return float.__repr__(x)
        case str():
            return f'"{_short(x)}"'
        case _:
            return f"a {type(x).__name__}"


def _mismatch(expected: str, v: Value, at: _At, code: ErrorCode = "type-mismatch") -> Never:
    found = _describe(v)
    at.fail(f"expected {expected}, found {found}", code=code, expected=expected, found=found)


def _not_case(expected: str, v: Value, at: _At, cases: Mapping[str, _CasePayload]) -> Never:
    """For a closed variant with these cases (`Bool`, `Maybe`): an unknown tag is `unknown-tag`,
    a known one with the wrong payload `wrong-payload`, anything else a mismatch."""
    if not isinstance(v, Variant):
        _mismatch(expected, v, at)
    if v.tag not in cases:
        _mismatch(expected, v, at, "unknown-tag")
    found = _describe(v)
    at.fail(
        f"expected {expected}, found {found}",
        code="wrong-payload",
        hint=_payload_hint(v.tag, cases[v.tag]),
        expected=expected,
        found=found,
    )


def _not_integer(expected: str, v: Value, at: _At) -> Never:
    """For an integer type: a number with a fraction or an exponent is `not-an-integer`, anything else a mismatch."""
    _mismatch(expected, v, at, "not-an-integer" if isinstance(v, Number) else "type-mismatch")


def _invalid(what: str, x: object, at: _At, code: ErrorCode = "cannot-encode") -> Never:
    found = _describe_py(x)
    at.fail(f"expected {what}, got {found}", code=code, expected=what, found=found)


def _json_mismatch(expected: str, j: Json, at: _At) -> Never:
    found = describe(j)
    at.fail(f"expected {expected}, found {found}", code="type-mismatch", expected=expected, found=found)


def _read_at(at: _At, read: Callable[[], T]) -> T:
    """`read()` at `at`: its JSON errors (paths relative to `at`) as decode errors with the full path."""
    try:
        return read()
    except HausJsonError as e:
        error = e
    raise HausDecodeError(error.reason, (*at.path(), *error.path), error.code)


def _tag_list(tags: Iterable[str]) -> str:
    ts = list(tags)
    return " | ".join(ts) if len(ts) <= 10 else " | ".join(ts[:10]) + f" | … ({len(ts)} tags)"


# ── values written from Python: within the limits (spec §9.8) ──


def _checked_string(s: object, at: _At, what: str = "a string", kind: str = "string") -> str:
    """A string, key (`kind`) within the string limit (spec §7), and Unicode text."""
    if not isinstance(s, str):
        _invalid(what, s, at)
    limit = at.ctx.limits.max_string_length
    if len(s) > limit:
        at.fail(f"{kind} longer than {limit} characters", code="key-too-long" if kind == "key" else "string-too-long")
    if not s.isascii() and _SURROGATE.search(s):
        at.fail("string with a lone surrogate (not Unicode text)", code="no-json-form" if at.ctx.json else None)
    return s


def _checked_bytes(b: object, at: _At) -> bytes:
    if not isinstance(b, bytes | bytearray):
        _invalid("bytes", b, at)
    if 2 * len(b) > at.ctx.limits.max_string_length:
        at.fail(f"byte string longer than {at.ctx.limits.max_string_length} characters", code="string-too-long")
    return bytes(b)


def _checked_number(text: object, at: _At, what: str, code: ErrorCode = "cannot-encode") -> str:
    if not isinstance(text, str):
        _invalid(what, text, at)
    if (normalized := normalize_number(text, UNLIMITED)) is None:
        _invalid(what, text, at, code)
    if (issue := number_limit_issue(normalized, at.ctx.limits)) is not None:
        at.fail(issue[1], code=issue[0])
    return normalized


def _sequence(x: object, at: _At, what: str) -> Sequence[object]:
    """`x` as a list or tuple of anything (each element is checked where it is used)."""
    if not isinstance(x, list | tuple):
        _invalid(what, x, at)
    return cast("Sequence[object]", x)


def _mapping(x: object, at: _At, what: str) -> Mapping[object, object]:
    if not isinstance(x, Mapping):
        _invalid(what, x, at)
    return cast("Mapping[object, object]", x)


def _checked_tag(tag: object, at: _At) -> str:
    if not isinstance(tag, str) or not TAG.fullmatch(tag):
        _invalid("a tag name", tag, at, "invalid-tag")
    if len(tag) > at.ctx.limits.max_string_length:
        at.fail(f"tag longer than {at.ctx.limits.max_string_length} characters", code="tag-too-long")
    return tag


def checked_value(raw: object, at: _At) -> Value:
    """A raw `Value` to write again (an `Any`, an unknown value): a haus value within the limits.

    A `Value` built in code may hold anything, so it is checked node by node; number
    literals are normalized as the parser would. Parts without a change are kept as
    they are, so a parsed value comes back unchanged (the same objects).
    """
    at.step()
    match raw:
        case Number(text):
            # A `Number` whose text isn't a literal (spec §11, values built in code).
            normalized = _checked_number(text, at, "a number literal", "invalid-number")
            return raw if normalized == text else Number(normalized)
        case String(s):
            _checked_string(s, at)
            return raw
        case Bytes(data):
            return raw if _checked_bytes(data, at) is data else Bytes(bytes(data))
        case Array(items):
            at.container()  # an empty array is a level too, as in the parser
            new_items = _checked_items(raw, _sequence(items, at, "a tuple of items"), at)
            return raw if new_items is None else Array(new_items)
        case Record():
            return _checked_record(raw, at)
        case Variant(tag, args):
            _checked_tag(tag, at)
            match _sequence(args, at, "a tuple of arguments"):
                case (Record() as record,):
                    # `Tag { … }` is one level, as in the parser.
                    checked = _checked_record(record, at)
                    return raw if checked is record else Variant(tag, (checked,))
                case values:
                    new_args = _checked_items(raw, values, at)
                    return raw if new_args is None else Variant(tag, new_args)
        case _:
            _invalid("a haus value", raw, at)


def _checked_items(raw: Value, items: Sequence[object], at: _At) -> tuple[Value, ...] | None:
    """The elements or arguments of `raw`, checked; None when nothing changed."""
    if items:
        at.container()
    at.enter(raw)
    out: list[Value] = []
    for i, x in enumerate(items):
        out.append(checked_value(x, at.child(i)))
    at.leave(raw)
    return None if isinstance(items, tuple) and all(map(_same, out, items)) else tuple(out)


def _same(a: object, b: object) -> bool:
    return a is b


def _checked_record(raw: Record, at: _At) -> Record:
    fields = _mapping(raw.fields, at, "a mapping of fields")
    at.container()
    at.enter(raw)
    out: dict[str, Value] = {}
    changed = False
    for k, x in fields.items():
        key = _checked_string(k, at, "a string key", "key")
        y = checked_value(x, at.child(key))
        changed = changed or y is not x
        out[key] = y
    at.leave(raw)
    return Record(out) if changed else raw


# ── nodes ────────────────────────────────────────────────────


class _Node:
    """One type: `decode` a value at a place, `encode` a Python value. Each application is one step.

    `read_json` and `write_json` do the same with the type's schema-based JSON (spec §16.3).
    """

    __slots__ = ("expected",)

    has_quick = False
    """Whether `quick` decodes some values: the loops over a container's children call it first."""

    def __init__(self, expected: str) -> None:
        self.expected = expected
        """What it accepts, for error messages."""

    def decode(self, v: Value, at: _At) -> object:
        raise NotImplementedError

    def quick(self, v: Value) -> object:
        """A scalar's usual value decoded without its place (one step, which the caller counts), or
        `_MISS`: for anything else, and for every error, `decode` with the place is called."""
        return _MISS

    def encode(self, x: object, at: _At) -> Value:
        raise NotImplementedError

    def read_json(self, j: Json, at: _At) -> object:
        raise NotImplementedError

    def write_json(self, x: object, at: _At) -> Json:
        raise NotImplementedError


class _String(_Node):
    __slots__ = ()
    has_quick = True

    def quick(self, v: Value) -> object:
        return v.value if type(v) is String else _MISS

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        if isinstance(v, String):
            return v.value
        _mismatch("String", v, at)

    def encode(self, x: object, at: _At) -> Value:
        return String(self.write_json(x, at))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if isinstance(j, str):
            return _checked_string(j, at)
        _json_mismatch("String (a string)", j, at)

    def write_json(self, x: object, at: _At) -> str:
        at.step()
        return _checked_string(x, at)


class _Bytes(_Node):
    __slots__ = ()

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        if isinstance(v, Bytes):
            return v.data
        _mismatch("Bytes", v, at)

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        return Bytes(_checked_bytes(x, at))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if not isinstance(j, str):
            _json_mismatch("Bytes (a string in base64 with padding)", j, at)
        if (data := from_base64(j)) is None:
            at.fail("expected base64 with padding (RFC 4648 §4)", code="invalid-base64")
        return _checked_bytes(data, at)

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        return to_base64(_checked_bytes(x, at))


_TRUE, _FALSE = Variant("True"), Variant("False")
_BOOLS: Final[Mapping[str, object]] = {"True": True, "False": False}


class _Bool(_Node):
    __slots__ = ()
    has_quick = True

    def quick(self, v: Value) -> object:
        if type(v) is Variant and not v.args:
            return _BOOLS.get(v.tag, _MISS)
        return _MISS

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        match v:
            case Variant("True", ()):
                return True
            case Variant("False", ()):
                return False
            case _:
                _not_case("Bool (True | False)", v, at, {"True": None, "False": None})

    def encode(self, x: object, at: _At) -> Value:
        return _TRUE if self.write_json(x, at) else _FALSE

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if isinstance(j, bool):
            return j
        _json_mismatch("Bool (true or false)", j, at)

    def write_json(self, x: object, at: _At) -> bool:
        at.step()
        if not isinstance(x, bool):
            _invalid("a bool", x, at)
        return x


_DECIMAL_INTEGER = re.compile(r"-?(?:0|[1-9][0-9]*+)")
_JSON_STRING_INTEGERS = frozenset({"Int", "Int64", "UInt64"})
"""Integer types whose schema-based JSON is a string: many JSON parsers round integers beyond 2^53 (spec §16.3)."""


class _Int(_Node):
    """`Int` (any size) and the sized integers, as `int`. Out of range is an error, never clamped."""

    __slots__ = ("high", "low")
    has_quick = True

    def quick(self, v: Value) -> object:
        if type(v) is not Number or not INTEGER.fullmatch(text := v.text):
            return _MISS
        if self.low is None or self.high is None:
            return to_int(text)
        # A literal longer than the bounds' can't be in range.
        return n if len(text) <= 21 and self.low <= (n := int(text)) <= self.high else _MISS

    def __init__(self, name: str, low: int | None = None, high: int | None = None) -> None:
        super().__init__(name)
        self.low = low
        self.high = high

    def _range(self) -> str:
        return f"{self.expected} ({self.low} to {self.high})"

    def _whole(self, text: str, at: _At) -> int | None:
        """The integer of a normalized literal; None if it isn't a whole number. Out of range fails."""
        if not INTEGER.fullmatch(text):
            return None
        if self.low is not None and self.high is not None:
            # A literal longer than the bounds' can't be in range: no need to convert it.
            n = to_int(text) if len(text) <= 21 else None
            if n is None or not self.low <= n <= self.high:
                expected, found = self._range(), _short(text)
                at.fail(f"{found} is out of range for {expected}", code="out-of-range", expected=expected, found=found)
            return n
        return to_int(text)

    def _text(self, x: object, at: _At) -> str:
        if not isinstance(x, int) or isinstance(x, bool):
            _invalid("an int", x, at)
        if self.low is not None and self.high is not None and not self.low <= x <= self.high:
            _invalid(f"an int from {self.low} to {self.high}", x, at)
        text = int_text(x)
        if (issue := number_limit_issue(text, at.ctx.limits)) is not None:
            at.fail(issue[1], code=issue[0])
        return text

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        if not isinstance(v, Number) or (n := self._whole(v.text, at)) is None:
            _not_integer(self.expected, v, at)
        return n

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        return Number(self._text(x, at))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if self.expected in _JSON_STRING_INTEGERS:
            expected = f"{self.expected} (a string of a decimal integer)"
            if not isinstance(j, str):
                _json_mismatch(expected, j, at)
            if not _DECIMAL_INTEGER.fullmatch(j):
                # A number with a fraction or an exponent isn't an integer; anything else isn't a number.
                found = describe(j)
                at.fail(
                    f"expected {expected}, found {found}",
                    code="not-an-integer" if json_number(j) is not None else "invalid-number",
                    expected=expected,
                    found=found,
                )
            # A bounded type checks its range first (`_whole`): a number too long for the limit is out of range.
            if self.low is None and (issue := number_limit_issue(j, at.ctx.limits)) is not None:
                at.fail(issue[1], code=issue[0])
            text = j
        elif isinstance(j, JsonNumber):
            text = j.text
        else:
            _json_mismatch(f"{self.expected} (a number)", j, at)
        if (n := self._whole(text, at)) is None:
            expected, found = f"{self.expected} (a whole number, without fraction or exponent)", describe(j)
            at.fail(f"expected {expected}, found {found}", code="not-an-integer", expected=expected, found=found)
        return n

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        text = self._text(x, at)
        return text if self.expected in _JSON_STRING_INTEGERS else JsonNumber(text)


_SPECIAL_FLOATS: Final = {"NaN": math.nan, "Infinity": math.inf, "NegInfinity": -math.inf}
_JSON_SPECIAL_FLOATS: Final = {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}
_NAN, _INFINITY, _NEG_INFINITY = Variant("NaN"), Variant("Infinity"), Variant("NegInfinity")
_FLOAT32 = struct.Struct("<f")


class _Float(_Node):
    """`Float64`, `Float32` as `float`: the nearest value; too large is an error (spec §15)."""

    __slots__ = ("kind",)
    has_quick = True

    def quick(self, v: Value) -> object:
        if type(v) is not Number:
            return _MISS
        x = to_float32(v.text) if self.kind == "Float32" else to_float64(v.text)
        return _MISS if x is None else x

    def __init__(self, kind: FloatKind) -> None:
        super().__init__(kind)
        self.kind: FloatKind = kind

    def _from_text(self, text: str, at: _At) -> float:
        x = to_float32(text) if self.kind == "Float32" else to_float64(text)
        if x is None:
            found = _short(text)
            at.fail(f"{found} is too large for {self.kind}", code="out-of-range", expected=self.kind, found=found)
        return x

    def _rounded(self, x: object, at: _At) -> float:
        """A Python number as a float of the type (binary32 for `Float32`)."""
        if not isinstance(x, float | int) or isinstance(x, bool):
            _invalid("a float", x, at)
        try:
            f = float(x)
            if self.kind == "Float32" and math.isfinite(f):
                (f,) = _FLOAT32.unpack(_FLOAT32.pack(f))
        except OverflowError:
            _invalid(f"a float within the range of {self.kind}", x, at)
        return f

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        match v:
            case Number(text):
                return self._from_text(text, at)
            case Variant(tag, ()) if tag in _SPECIAL_FLOATS:
                return _SPECIAL_FLOATS[tag]
            case _:
                _mismatch(f"{self.kind} (a number, NaN, Infinity or NegInfinity)", v, at)

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        f = self._rounded(x, at)
        if math.isnan(f):
            return _NAN
        if math.isinf(f):
            return _INFINITY if f > 0 else _NEG_INFINITY
        return Number(float_text(f, self.kind))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        match j:
            case JsonNumber(text):
                return self._from_text(text, at)
            case str() if j in _JSON_SPECIAL_FLOATS:
                return _JSON_SPECIAL_FLOATS[j]
            case _:
                _json_mismatch(f'{self.kind} (a number, "NaN", "Infinity" or "-Infinity")', j, at)

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        f = self._rounded(x, at)
        if math.isnan(f):
            return "NaN"
        if math.isinf(f):
            return "Infinity" if f > 0 else "-Infinity"
        return JsonNumber(float_text(f, self.kind))


class _Decimal(_Node):
    """`Decimal` as the normalized literal text: `"19.90"`, `"1.5e3"` (spec §15)."""

    __slots__ = ()
    has_quick = True

    def quick(self, v: Value) -> object:
        return v.text if type(v) is Number else _MISS

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        if isinstance(v, Number):
            return v.text
        _mismatch("Decimal", v, at)

    def encode(self, x: object, at: _At) -> Value:
        return Number(self.write_json(x, at))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        expected = "Decimal (a string of a JSON number)"
        if not isinstance(j, str):
            _json_mismatch(expected, j, at)
        if (text := json_number(j)) is None:
            found = describe(j)
            at.fail(f"expected {expected}, found {found}", code="invalid-number", expected=expected, found=found)
        if (issue := number_limit_issue(text, at.ctx.limits)) is not None:
            at.fail(issue[1], code=issue[0])
        return text

    def write_json(self, x: object, at: _At) -> str:
        at.step()
        if isinstance(x, Decimal):
            x = str(x)
        if not isinstance(x, str):
            _invalid('a decimal literal like "19.90"', x, at)
        return _checked_number(x, at, 'a decimal literal like "19.90"')


class _StdTime(_Node):
    """A std/time type as its checked text: `Date("2026-11-13")` → `"2026-11-13"`."""

    __slots__ = ()
    has_quick = True

    def quick(self, v: Value) -> object:
        if type(v) is Variant and v.tag == self.expected and len(args := v.args) == 1 and type(args[0]) is String:
            text = args[0].value
            if check_time(self.expected, text) is None:
                return text
        return _MISS

    def _checked(self, text: str, at: _At, child: PathKey | None = None) -> str:
        if (reason := check_time(self.expected, text)) is not None:
            # Decoding: text that isn't valid in the profile. Encoding: a Python value the type can't write.
            code: ErrorCode = "invalid-time" if at.ctx.decoding else "cannot-encode"
            at.fail(_short(reason, 200), _NO_KEY if child is None else child, code=code)
        return text

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        match v:
            case Variant(tag, (String(text),)) if tag == self.expected:
                return self._checked(text, at, 0)
            case _:
                _mismatch(f'{self.expected}("…")', v, at)

    def encode(self, x: object, at: _At) -> Value:
        return Variant(self.expected, (String(self.write_json(x, at)),))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if isinstance(j, str):
            return self._checked(_checked_string(j, at), at)
        _json_mismatch(f"{self.expected} (a string)", j, at)

    def write_json(self, x: object, at: _At) -> str:
        at.step()
        return self._checked(_checked_string(x, at), at)


class _Any(_Node):
    """`Any`: the parsed value, unchanged, in JSON its self-describing form without the envelope (spec §16.2).

    Encoding checks it is a value within the limits.
    """

    __slots__ = ()
    has_quick = True

    def quick(self, v: Value) -> object:
        return v

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        return v

    def encode(self, x: object, at: _At) -> Value:
        return checked_value(x, at)

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        return _read_at(at, lambda: from_self_describing(j, at.ctx.limits, at.depth))

    def write_json(self, x: object, at: _At) -> Json:
        return self_describing(checked_value(x, at))


def _each_item(x: object, at: _At, write: Callable[[object, _At], T]) -> list[T]:
    """`write` applied to each element of a list or tuple."""
    xs = _sequence(x, at, "a list or tuple")
    at.container()
    at.enter(x)
    out: list[T] = []
    for i, y in enumerate(xs):
        out.append(write(y, at.child(i)))
    at.leave(x)
    return out


class _Array(_Node):
    __slots__ = ("item",)

    def __init__(self, item: _Node) -> None:
        super().__init__(f"Array {_short(item.expected, 40)}")
        self.item = item

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        if not isinstance(v, Array):
            _mismatch(self.expected, v, at)
        item, ctx, child = self.item, at.ctx, at.child
        quick = item.quick if item.has_quick else None
        out: list[object] = []
        for i, x in enumerate(v.items):
            if quick is None or (y := quick(x)) is _MISS or ctx.steps >= ctx.max_steps:
                y = item.decode(x, child(i))
            else:
                ctx.steps += 1
            out.append(y)
        return tuple(out)

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        return Array(tuple(_each_item(x, at, self.item.encode)))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if not isinstance(j, list):
            _json_mismatch(f"{self.expected} (an array)", j, at)
        item = self.item
        out: list[object] = []
        for i, x in enumerate(j):
            out.append(item.read_json(x, at.child(i)))
        return tuple(out)

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        return _each_item(x, at, self.item.write_json)


def _each_entry(x: object, at: _At, write: Callable[[object, _At], T]) -> dict[str, T]:
    """`write` applied to each value of a mapping with string keys."""
    entries = _mapping(x, at, "a mapping")
    at.container()
    at.enter(x)
    out: dict[str, T] = {}
    for k, y in entries.items():
        key = _checked_string(k, at, "string keys", "key")
        out[key] = write(y, at.child(key))
    at.leave(x)
    return out


class _Map(_Node):
    """`Map v` as a dict with any string keys."""

    __slots__ = ("value",)

    def __init__(self, value: _Node) -> None:
        super().__init__(f"Map {_short(value.expected, 40)}")
        self.value = value

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        if not isinstance(v, Record):
            _mismatch(f"{self.expected} (a record)", v, at)
        value, ctx, child = self.value, at.ctx, at.child
        quick = value.quick if value.has_quick else None
        out: dict[str, object] = {}
        for k, x in v.fields.items():
            if quick is None or (y := quick(x)) is _MISS or ctx.steps >= ctx.max_steps:
                y = value.decode(x, child(k))
            else:
                ctx.steps += 1
            out[k] = y
        return out

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        return Record(_each_entry(x, at, self.value.encode))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if not isinstance(j, dict):
            _json_mismatch(f"{self.expected} (an object)", j, at)
        value = self.value
        out: dict[str, object] = {}
        for k, x in j.items():
            _checked_string(k, at, kind="key")
            out[k] = value.read_json(x, at.child(k))
        return out

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        return _each_entry(x, at, self.value.write_json)


_NONE = Variant("None")


class _Maybe(_Node):
    """`Maybe a`: `Nothing()` or `Some(value)`.

    In schema-based JSON (spec §16.3) `null` and the value when `a`'s JSON can't be `null`,
    `{"_tag": "None"}` and `{"_tag": "Some", "value": …}` otherwise.
    """

    __slots__ = ("_uses_null", "item")

    def __init__(self, item: _Node) -> None:
        super().__init__(f"Maybe {_short(item.expected, 40)}")
        self.item = item
        self._uses_null: bool | None = None
        """Computed on first use, once the back references of recursive types are set."""

    def uses_null(self) -> bool:
        if self._uses_null is None:
            self._uses_null = not _on_null_cycle(self) and not _json_nullable(self.item)
        return self._uses_null

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        match v:
            case Variant("None", ()):
                return Nothing()
            case Variant("Some", (x,)):
                return Some(self.item.decode(x, at.child(0)))
            case _:
                _not_case(f"None | Some({_short(self.item.expected, 40)})", v, at, {"None": None, "Some": (self.item,)})

    def _some(self, x: object, at: _At) -> object:
        match x:
            case Nothing():
                return _NOTHING
            case Some():
                at.container()
                return cast("Some[object]", x).value
            case _:
                _invalid("a Maybe (Some(value) or Nothing())", x, at)

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        if (value := self._some(x, at)) is _NOTHING:
            return _NONE
        return Variant("Some", (self.item.encode(value, at.child(0)),))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if self.uses_null():
            return Nothing() if j is None else Some(self.item.read_json(j, at.deeper()))
        if not isinstance(j, dict):
            _json_mismatch(f'{self.expected} ({{"_tag": "None"}} or {{"_tag": "Some", "value": …}})', j, at)
        match _read_tag(j, '"None" or "Some"', at):
            case "None":
                _only(j, (), "None", at)
                return Nothing()
            case "Some":
                _only(j, ("value",), "Some", at)
                return Some(self.item.read_json(_member(j, "value", "Some", at), at.child("value")))
            case _:
                at.fail('expected "_tag": "None" or "Some"', code="unknown-tag")

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        null = self.uses_null()
        if (value := self._some(x, at)) is _NOTHING:
            return None if null else {"_tag": "None"}
        if null:
            return self.item.write_json(value, at.deeper())
        return {"_tag": "Some", "value": self.item.write_json(value, at.child("value"))}


class _Secret(_Node):
    """`Secret a`: decoded into a `Secret`; errors inside give its place and type, never the value."""

    __slots__ = ("item",)

    def __init__(self, item: _Node) -> None:
        super().__init__(f"Secret {_short(item.expected, 40)}")
        self.item = item

    def _concealed(self, at: _At) -> Never:
        """Any error inside a secret, as `invalid-secret` at its place: its type, never its value (spec §15)."""
        expected = _short(self.item.expected, 40)
        at.fail(f"expected {expected} (a Secret: the value is not shown)", code="invalid-secret", expected=expected)

    def _exposed(self, x: object, at: _At) -> object:
        if not isinstance(x, Secret):
            # Not even a short description of what was given instead: it may be the secret itself.
            at.fail(f"expected a Secret, got a {type(x).__name__}")
        return x.expose()  # pyright: ignore[reportUnknownMemberType, reportUnknownVariableType]

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        try:
            return Secret(self.item.decode(v, at))
        except HausDecodeError:
            pass
        # Raised after the `except`, so the inner error (which may show the value) isn't its context.
        self._concealed(at)

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        value = self._exposed(x, at)
        try:
            return self.item.encode(value, at)
        except HausEncodeError:
            pass
        self._concealed(at)

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        try:
            return Secret(self.item.read_json(j, at))
        except HausDecodeError:
            pass
        self._concealed(at)

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        value = self._exposed(x, at)
        try:
            return self.item.write_json(value, at)
        except HausEncodeError:
            pass
        self._concealed(at)


class _Field:
    __slots__ = ("key", "node", "optional")

    def __init__(self, key: str, node: _Node, optional: bool) -> None:
        self.key = key
        self.node = node
        self.optional = optional


_Entries = tuple[tuple[str, Callable[[Any], object] | None, Callable[[Any, "_At"], Any], bool], ...]
"""A record's fields for one direction: each key, the field's node's `quick` when decoding (else
None), its method for the direction (both bound), and whether the field is optional."""


class _Record(_Node):
    """`{ … }` as a dict. A missing optional field stays missing: never `None` (spec §1)."""

    __slots__ = ("closed", "decoders", "encoders", "fields", "json_readers", "json_writers", "keys")

    def __init__(self, fields: tuple[_Field, ...], closed: bool) -> None:
        super().__init__("closed record" if closed else "record")
        self.fields = fields
        self.keys = frozenset(f.key for f in fields)
        self.closed = closed

        def entries(method: str, quick: bool = False) -> _Entries:
            return tuple(
                (f.key, f.node.quick if quick and f.node.has_quick else None, getattr(f.node, method), f.optional)
                for f in fields
            )

        # The loops call the fields' methods directly, bound once here.
        self.decoders = entries("decode", quick=True)
        self.encoders = entries("encode")
        self.json_readers = entries("read_json")
        self.json_writers = entries("write_json")

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        if not isinstance(v, Record):
            _mismatch("a record", v, at)
        return self.read_fields(v.fields, at, self.decoders)

    def read_fields(self, fields: Mapping[str, object], at: _At, readers: _Entries) -> dict[str, object]:
        """The listed fields of `fields` (haus values or JSON members), each read with its type."""
        out: dict[str, object] = {}
        ctx, child = at.ctx, at.child
        for key, quick, read, optional in readers:
            if key in fields:
                if ctx.json:
                    # A listed member's name is a key of the value read (spec §16, "Limits").
                    _checked_string(key, at, kind="key")
                x = fields[key]
                if quick is None or (y := quick(x)) is _MISS or ctx.steps >= ctx.max_steps:
                    y = read(x, child(key))
                else:
                    ctx.steps += 1
                out[key] = y
            elif not optional:
                at.fail(f"missing field '{key}'", code="missing-field", expected=f"the field '{key}'")
        if self.closed:
            for k in fields:
                if k not in self.keys:
                    at.fail(f"unexpected field '{_short(k)}' (the record is closed)", k, code="unknown-field")
        return out

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        return Record(self.write_fields(x, at, self.encoders))

    def write_fields(self, x: object, at: _At, writers: _Entries) -> dict[str, Any]:
        """The fields of a Python mapping, each written with its type: haus values or JSON."""
        given = _mapping(x, at, "a mapping of fields")
        at.container()
        at.enter(x)
        out: dict[str, Any] = {}
        child = at.child
        for key, _, write, optional in writers:
            if key in given:
                out[key] = write(given[key], child(key))
            elif not optional:
                at.fail(f"missing field '{key}'")
        if self.closed:
            for k in given:
                if k not in self.keys:
                    at.fail("unexpected field (the record is closed)", k)
        at.leave(x)
        return out

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        if not isinstance(j, dict):
            _json_mismatch("a record (an object)", j, at)
        return self.read_fields(j, at, self.json_readers)

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        return self.write_fields(x, at, self.json_writers)


class _RecordCase:
    """The payload of a record case (spec §15): a record, inline or by name.

    By name (`Circle Disc`), `node` is the named type's node: codecs and back references around
    the record, applied here, so the case's data is that of `Circle { … }` whatever the host type.
    The direction (decoding, JSON, …) is given as the record's entries for it: `_Record.decoders`.
    """

    __slots__ = ("_chain", "node")

    def __init__(self, node: _Node) -> None:
        self.node = node
        self._chain: tuple[tuple[_Coded, ...], _Record] | None = None

    def chain(self) -> tuple[tuple[_Coded, ...], _Record]:
        """The codecs around the record, outermost first, and the record (once back references are set)."""
        if self._chain is None:
            coded: list[_Coded] = []
            node = self.node
            while not isinstance(node, _Record):
                if isinstance(node, _Coded):
                    coded.append(node)
                    node = node.inner
                elif isinstance(node, _BackRef):
                    node = node.resolved()
                else:
                    raise AssertionError(f"a record case of {node.expected}")
            self._chain = (tuple(coded), node)
        return self._chain

    @property
    def record(self) -> _Record:
        return self.chain()[1]

    def read_fields(self, fields: Mapping[str, object], at: _At, readers: Callable[[_Record], _Entries]) -> object:
        coded, record = self.chain()
        x: object = record.read_fields(fields, at, readers(record))
        for c in reversed(coded):
            x = c.decoded(x, at)
        return x

    def write_fields(self, x: object, at: _At, writers: Callable[[_Record], _Entries]) -> dict[str, Any]:
        coded, record = self.chain()
        for c in coded:
            x = c.encoded(x, at)
        return record.write_fields(x, at, writers(record))


def _decoders(r: _Record) -> _Entries:
    return r.decoders


def _encoders(r: _Record) -> _Entries:
    return r.encoders


def _json_readers(r: _Record) -> _Entries:
    return r.json_readers


def _json_writers(r: _Record) -> _Entries:
    return r.json_writers


_CasePayload = _RecordCase | tuple[_Node, ...] | None


class _Variant(_Node):
    """`< … >`: a listed case is a `Tagged`; another tag is an `Unknown` in an open variant.

    In schema-based JSON (spec §16.3) a closed variant whose cases have no payload is the tag as a
    string; any other is an object with the tag as `"_tag"`.
    """

    __slots__ = ("as_string", "cases", "open", "tags")

    def __init__(self, cases: dict[str, _CasePayload], open: bool) -> None:
        self.tags = _tag_list(cases)
        super().__init__(f"< {self.tags}{' | _' if open and cases else ''} >")
        # Dispatch is one lookup on the tag: never "try each case" (spec §9.8).
        self.cases = cases
        self.open = open
        self.as_string = not open and all(p is None for p in cases.values())

    def decode(self, v: Value, at: _At) -> object:
        at.step()
        if not isinstance(v, Variant):
            _mismatch("a variant" if not self.cases else self.expected, v, at)
        tag, args = v.tag, v.args
        if tag not in self.cases:
            if self.open:
                return Unknown(v)
            expected = f"one of {self.tags}"
            at.fail(
                f"unknown tag '{_short(tag)}', {expected}", code="unknown-tag", expected=expected, found=_short(tag)
            )
        payload = self.cases[tag]
        if payload is None:
            if args:
                _wrong_payload(tag, payload, "no payload", f"{len(args)} argument(s)", at)
            return Tagged(tag)
        if isinstance(payload, _RecordCase):
            # One argument that is a record, inline or by name; `Circle(1.5)` and `Wrap(1)` are the
            # wrong payload, at the variant (spec §15).
            if len(args) != 1:
                _wrong_payload(tag, payload, "one argument, a record", f"{len(args)} argument(s)", at)
            if not isinstance(args[0], Record):
                _wrong_payload(tag, payload, "one argument, a record", _describe(args[0]), at)
            return Tagged(tag, cast("Mapping[str, object]", payload.read_fields(args[0].fields, at, _decoders)))
        if len(args) != len(payload):
            _wrong_payload(tag, payload, f"{len(payload)} argument(s)", f"{len(args)} argument(s)", at)
        out: list[object] = []
        for i, node in enumerate(payload):
            out.append(node.decode(args[i], at.child(i)))
        return Tagged(tag, tuple(out))

    def _unknown(self, raw: object, at: _At) -> Variant:
        """The raw value of an `Unknown` to write: a variant this type doesn't list, within the limits."""
        if not self.open:
            at.fail(f"an unknown value, but the variant is closed (one of {self.tags})")
        if not isinstance(raw, Variant):
            _invalid("a Variant in the Unknown", raw, at)
        if raw.tag in self.cases:
            at.fail(f"an Unknown with the listed tag '{_short(raw.tag)}': write it as Tagged")
        checked = checked_value(raw, at)
        assert isinstance(checked, Variant)
        return checked

    def _tagged(self, x: object, at: _At) -> tuple[str, object, _CasePayload]:
        """A `Tagged` to write: its tag, payload and case."""
        if not isinstance(x, Tagged):
            _invalid("a Tagged" + (" or an Unknown" if self.open else ""), x, at)
        tag, given = x.tag, cast("object", x.payload)
        if tag not in self.cases:
            _invalid(f"one of {self.tags}", tag, at)
        case = self.cases[tag]
        if case is None and given != ():
            _invalid(f"no payload for {tag}", given, at)
        return tag, given, case

    def _arguments(self, tag: str, given: object, case: tuple[_Node, ...], at: _At) -> Sequence[object]:
        args = _sequence(given, at, f"a tuple of {len(case)} argument(s) for {tag}")
        if len(args) != len(case):
            _invalid(f"a tuple of {len(case)} argument(s) for {tag}", given, at)
        return args

    def encode(self, x: object, at: _At) -> Value:
        at.step()
        if isinstance(x, Unknown):
            return self._unknown(cast("object", x.value), at)
        tag, given, case = self._tagged(x, at)
        if case is None:
            return Variant(tag)
        if isinstance(case, _RecordCase):
            return Variant(tag, (Record(case.write_fields(given, at, _encoders)),))
        args = self._arguments(tag, given, case, at)
        at.container()
        at.enter(given)
        out: list[Value] = []
        for i, node in enumerate(case):
            out.append(node.encode(args[i], at.child(i)))
        at.leave(given)
        return Variant(tag, tuple(out))

    def read_json(self, j: Json, at: _At) -> object:
        at.step()
        expected = f"one of {self.tags}"
        if self.as_string:
            if not isinstance(j, str):
                _json_mismatch(f"one of the strings {self.tags}", j, at)
            if not TAG.fullmatch(j):
                found = describe(j)
                reason = f"expected a tag ([A-Z][A-Za-z0-9_]*), {expected}, found {found}"
                at.fail(reason, code="invalid-tag", expected=expected, found=found)
            if j not in self.cases:
                found = describe(j)
                at.fail(f"unknown tag {found}, {expected}", code="unknown-tag", expected=expected, found=found)
            return Tagged(_checked_tag(j, at))
        if not isinstance(j, dict):
            _json_mismatch(f'an object with "_tag" ({self.tags})', j, at)
        tag = _read_tag(j, self.tags, at)
        if tag not in self.cases and not self.open:
            found = _short(tag)
            at.fail(f"unknown tag '{found}', {expected}", code="unknown-tag", expected=expected, found=found)
        # A tag of the value read, listed or not (spec §16, "Limits").
        _checked_tag(tag, at)
        if tag not in self.cases:
            return Unknown(self._read_unknown(tag, j, at))
        case = self.cases[tag]
        if case is None:
            _only(j, (), tag, at)
            return Tagged(tag)
        if isinstance(case, _RecordCase):
            _check_payload_keys(case, at)
            fields = {k: x for k, x in j.items() if k != "_tag"}
            return Tagged(tag, cast("Mapping[str, object]", case.read_fields(fields, at, _json_readers)))
        if len(case) == 1:
            _only(j, ("value",), tag, at)
            return Tagged(tag, (case[0].read_json(_member(j, "value", tag, at), at.child("value")),))
        _only(j, ("values",), tag, at)
        values = _member(j, "values", tag, at)
        if not isinstance(values, list) or len(values) != len(case):
            at.fail(f"'{tag}' takes {len(case)} arguments, as \"values\": an array", code="wrong-payload")
        values_at = at.member("values")
        out: list[object] = []
        for i, node in enumerate(case):
            out.append(node.read_json(values[i], values_at.child(i)))
        return Tagged(tag, tuple(out))

    def _read_unknown(self, tag: str, j: dict[str, Json], at: _At) -> Variant:
        """A tag this open variant doesn't list (spec §16.3).

        `{"_tag": "<Tag>", "_args": [<self-describing>, …]}` is the form written; any other members are
        a newer writer's case, read as a record payload by the import (§16.1):
        `{"_tag": "Hexagon", "sides": 6}` is `Hexagon { sides: 6 }`.
        """
        if len(j) == 1:
            return Variant(tag)
        if len(j) == 2 and "_args" in j:
            args = j["_args"]
            return _read_at(at, lambda: self_describing_arguments(tag, args, at.ctx.limits, at.depth))
        members: dict[str, Json] = {k: x for k, x in j.items() if k != "_tag"}
        # `Tag { … }` is one level, as in the parser.
        payload = _read_at(at, lambda: imported(members, at.ctx.limits, at.ctx.limits.max_depth, at.depth))
        return Variant(tag, (payload,))

    def write_json(self, x: object, at: _At) -> Json:
        at.step()
        if isinstance(x, Unknown):
            raw = self._unknown(cast("object", x.value), at)
            if not raw.args:
                return {"_tag": raw.tag}
            return {"_tag": raw.tag, "_args": [self_describing(a) for a in raw.args]}
        tag, given, case = self._tagged(x, at)
        if case is None:
            return tag if self.as_string else {"_tag": tag}
        if isinstance(case, _RecordCase):
            _check_payload_keys(case, at)
            return {"_tag": tag, **case.write_fields(given, at, _json_writers)}
        args = self._arguments(tag, given, case, at)
        at.container()
        at.enter(given)
        if len(case) == 1:
            out: Json = {"_tag": tag, "value": case[0].write_json(args[0], at.child("value"))}
        else:
            values_at = at.member("values")
            values: list[Json] = []
            for i, node in enumerate(case):
                values.append(node.write_json(args[i], values_at.child(i)))
            out = {"_tag": tag, "values": values}
        at.leave(given)
        return out


def _check_payload_keys(case: _RecordCase, at: _At) -> None:
    for key in ("_tag", "_args"):
        if key in case.record.keys:
            reason = f'a record payload with a field named "{key}" has no schema-based JSON form (spec §16.3)'
            at.fail(reason, code="no-json-form")


def _read_tag(j: dict[str, Json], expected: str, at: _At) -> str:
    """The `"_tag"` of a tagged object (spec §16.3): a string that is a tag (§4), else `invalid-tag`, at the object."""
    if "_tag" not in j:
        at.fail(f'expected a member "_tag" ({expected})', code="missing-member", expected='"_tag"')
    tag = j["_tag"]
    if not isinstance(tag, str) or not TAG.fullmatch(tag):
        found = describe(tag)
        reason = f'expected a tag ([A-Z][A-Za-z0-9_]*) in "_tag", found {found}'
        at.fail(reason, code="invalid-tag", expected=expected, found=found)
    return tag


def _only(j: dict[str, Json], allowed: tuple[str, ...], tag: str, at: _At) -> None:
    """A tagged object (spec §16.3) has `_tag` and the members of its form, no others: an other is an error at it."""
    for k in j:
        if k != "_tag" and k not in allowed:
            at.member(k).fail(f"unexpected member {describe(k)} for '{tag}'", code="unexpected-member")


def _member(j: dict[str, Json], name: str, tag: str, at: _At) -> Json:
    if name not in j:
        at.fail(f"'{tag}' needs a member \"{name}\"", code="missing-member", expected=f'"{name}"')
    return j[name]


def _wrong_payload(tag: str, payload: _CasePayload, shape: str, found: str, at: _At) -> Never:
    at.fail(
        f"'{tag}' takes {shape}, found {found}",
        code="wrong-payload",
        hint=_payload_hint(tag, payload),
        expected=shape,
        found=found,
    )


def _types(nodes: Iterable[str]) -> str:
    """Up to ten type descriptions, each shortened (spec §9.8)."""
    ts = [_short(t, 40) for t in nodes]
    return ", ".join(ts) if len(ts) <= 10 else ", ".join(ts[:10]) + f", … ({len(ts)})"


def _payload_hint(tag: str, payload: _CasePayload) -> str:
    """The hint of a `wrong-payload`: what the case of `tag` takes, and how to write it."""
    t = _short(tag)
    if payload is None:
        return f"{t} takes no payload: write `{t}`."
    if isinstance(payload, _RecordCase):
        fields = _types(f"{f.key}{'?' if f.optional else ''}: {f.node.expected}" for f in payload.record.fields)
        return (
            f"{t} takes one argument, a record {{ {fields} }}: write `{t} {{ … }}`."
            if fields
            else (f"{t} takes one argument, a record: write `{t} {{ … }}`.")
        )
    n = len(payload)
    holes = ", ".join("…" for _ in payload) if n <= 10 else "…"
    return (
        f"{t} takes {n} argument{'' if n == 1 else 's'} ({_types(p.expected for p in payload)}): write `{t}({holes})`."
    )


class _BackRef(_Node):
    """A back edge of a recursive type (guarded: the checker made sure), set once its type is built."""

    __slots__ = ("target",)

    def __init__(self, name: str) -> None:
        super().__init__(name)
        self.target: _Node | None = None

    def resolved(self) -> _Node:
        assert self.target is not None
        return self.target

    def decode(self, v: Value, at: _At) -> object:
        return self.resolved().decode(v, at)

    def encode(self, x: object, at: _At) -> Value:
        return self.resolved().encode(x, at)

    def read_json(self, j: Json, at: _At) -> object:
        return self.resolved().read_json(j, at)

    def write_json(self, x: object, at: _At) -> Json:
        return self.resolved().write_json(x, at)


class _Coded(_Node):
    """A codec around a named type's own node (spec §13.4): after it when decoding, before it when encoding."""

    __slots__ = ("codec", "id", "inner")

    def __init__(self, inner: _Node, codec: Codec, id: str) -> None:
        super().__init__(inner.expected)
        self.inner = inner
        self.codec = codec
        self.id = id

    def decoded(self, x: object, at: _At) -> object:
        try:
            return self.codec.decode(x)
        except (ValueError, TypeError, OverflowError) as e:
            reason = _short(str(e), 100)
        at.fail(f"the codec for {self.id} rejects it: {reason}", code="codec-rejected")

    def encoded(self, x: object, at: _At) -> object:
        at.step()
        try:
            return self.codec.encode(x)
        except (ValueError, TypeError, OverflowError) as e:
            reason = _short(str(e), 100)
        at.fail(f"the codec for {self.id} can't encode it: {reason}")

    def decode(self, v: Value, at: _At) -> object:
        return self.decoded(self.inner.decode(v, at), at)

    def encode(self, x: object, at: _At) -> Value:
        return self.inner.encode(self.encoded(x, at), at)

    def read_json(self, j: Json, at: _At) -> object:
        return self.decoded(self.inner.read_json(j, at), at)

    def write_json(self, x: object, at: _At) -> Json:
        return self.inner.write_json(self.encoded(x, at), at)


def _null_step(node: _Node) -> _Node | None:
    """The node whose JSON `node` writes in place, if any: through a `Maybe` (its `Some`), `Secret`, codec or name."""
    match node:
        case _Maybe() | _Secret():
            return node.item
        case _Coded():
            return node.inner
        case _BackRef():
            return node.resolved()
        case _:
            return None


def _json_nullable(node: _Node) -> bool:
    """Whether a type's schema-based JSON can be `null`.

    That is a `Maybe` that uses `null`, directly or through `Secret` or a name.
    """
    while not isinstance(node, _Maybe):
        if (inner := _null_step(node)) is None:
            return False
        node = inner
    return node.uses_null()


def _on_null_cycle(maybe: _Maybe) -> bool:
    """Whether `maybe` writes its own JSON in place, through Maybes, Secrets and names only (`type T = Maybe T`).

    Such a `Maybe` can't decide on `null` from its content (spec §16.3 leaves it open), so it uses `_tag`.
    """
    seen: set[int] = set()
    node: _Node | None = maybe.item
    while node is not None and id(node) not in seen:
        if node is maybe:
            return True
        seen.add(id(node))
        node = _null_step(node)
    return False


# ── building nodes from resolved types ───────────────────────


def _integer(name: str, bits: int, *, signed: bool) -> _Int:
    return _Int(name, -(2 ** (bits - 1)), 2 ** (bits - 1) - 1) if signed else _Int(name, 0, 2**bits - 1)


_BUILTINS: Final[Mapping[str, _Node]] = {
    "String": _String("String"),
    "Bytes": _Bytes("Bytes"),
    "Bool": _Bool("Bool"),
    "Decimal": _Decimal("Decimal"),
    "Int": _Int("Int"),
    "Int8": _integer("Int8", 8, signed=True),
    "Int16": _integer("Int16", 16, signed=True),
    "Int32": _integer("Int32", 32, signed=True),
    "Int64": _integer("Int64", 64, signed=True),
    "UInt8": _integer("UInt8", 8, signed=False),
    "UInt16": _integer("UInt16", 16, signed=False),
    "UInt32": _integer("UInt32", 32, signed=False),
    "UInt64": _integer("UInt64", 64, signed=False),
    "Float32": _Float("Float32"),
    "Float64": _Float("Float64"),
    "Any": _Any("Any"),
}


class Builder:
    """Builds the nodes of resolved types, once per instance; recursion becomes back references."""

    def __init__(self, codecs: Mapping[str, Codec]) -> None:
        self.codecs = codecs
        self.built: dict[_Instance, _Node] = {}
        self.building: set[_Instance] = set()
        self.back: dict[_Instance, list[_BackRef]] = {}
        self.used: set[str] = set()
        """The ids of the codecs applied."""
        self.nodes: dict[int, tuple[Type, _Node]] = {}
        """The node of each type object, by its id (the object kept, so the id stays its own). Arguments are
        shared, not copied: a type written once can be reached along exponentially many paths (`P a a` inside
        `P a a` …) and is built once."""

    def coded(self, node: _Node, id: str) -> _Node:
        if (codec := self.codecs.get(id)) is None:
            return node
        self.used.add(id)
        return _Coded(node, codec, id)

    def ref(self, inst: _Instance) -> _Node:
        if (done := self.built.get(inst)) is not None:
            return done
        if inst in self.building:
            back = _BackRef(inst.key)
            self.back.setdefault(inst, []).append(back)
            return back
        self.building.add(inst)
        node = self.build(inst.body)
        if not inst.args:
            node = self.coded(node, inst.definition.id)
        self.building.discard(inst)
        self.built[inst] = node
        for back in self.back.pop(inst, []):
            back.target = node
        return node

    def build(self, t: Type) -> _Node:
        if isinstance(t, RefType):
            return self.ref(t.instance)
        if (known := self.nodes.get(id(t))) is not None:
            return known[1]
        node = self.build_new(t)
        self.nodes[id(t)] = (t, node)
        return node

    def build_new(self, t: Type) -> _Node:
        match t:
            case BuiltinType(name):
                return self.coded(_BUILTINS[name], f"prelude#{name}")
            case StdType(name):
                return self.coded(_StdTime(name), f"std/time#{name}")
            case ArrayType(item):
                return _Array(self.build(item))
            case MapType(value):
                return _Map(self.build(value))
            case MaybeType(item):
                return _Maybe(self.build(item))
            case SecretType(item):
                return _Secret(self.build(item))
            case RecordType():
                return self.record(t)
            case VariantType(cases, open_):
                payloads: dict[str, _CasePayload] = {}
                for c in cases:
                    match c.payload:
                        case NoPayload():
                            payloads[c.tag] = None
                        case RecordPayload(record):
                            payloads[c.tag] = _RecordCase(self.record(record))
                        case PositionalPayload(items) as p if p.record is not None:
                            # A record case by name: the named type's node, with its codecs (spec §15).
                            payloads[c.tag] = _RecordCase(self.build(items[0]))
                        case PositionalPayload(items):
                            payloads[c.tag] = tuple(self.build(x) for x in items)
                return _Variant(payloads, open_)
            case RefType(inst):
                return self.ref(inst)
            case ParamType(name):
                raise ValueError(f"type parameter {name} in a concrete type")

    def record(self, t: RecordType) -> _Record:
        return _Record(tuple(_Field(f.key, self.build(f.type), f.optional) for f in t.fields), t.closed)


# ── entry points ─────────────────────────────────────────────


def _is_container(v: Value) -> bool:
    """A record, an array or a variant with a payload: one level of nesting, as the parser counts it."""
    return isinstance(v, Array | Record) or (isinstance(v, Variant) and bool(v.args))


def _count_values(root: Value, max_depth: int, at: _At) -> int:
    """The values in a tree, level by level, failing beyond `max_depth` (a Value built in code may be
    deeper than parsed ones)."""
    count = 0
    level: list[Value] = [root]
    depth = 0
    while level:
        count += len(level)
        if count > _MAX_VALUES:
            at.fail(f"value has more than {_MAX_VALUES} nodes", code="too-many-nodes")
        # A container here is one level more (empty or not), as the parser counts it.
        if depth >= max_depth and any(_is_container(v) for v in level):
            at.fail(f"value nested deeper than {max_depth} levels", code="nesting-too-deep")
        below: list[Value] = []
        for v in level:
            if type(v) is String or type(v) is Number:
                continue
            if isinstance(v, Record):
                below += v.fields.values()
            elif isinstance(v, Array):
                below += v.items
            elif isinstance(v, Variant):
                match v.args:
                    case (Record(fields),):
                        count += 1  # `Tag { … }` is one level, as in the parser
                        below += fields.values()
                    case args:
                        below += args
        level = below
        depth += 1
    return count


def _too_deep(at: _At) -> Never:
    at.fail(
        "nesting too deep for Python's recursion limit; lower max_depth or raise sys.setrecursionlimit",
        code="nesting-too-deep",
    )


def decode(node: _Node, value: Value, limits: Limits, max_steps: int | None, key: PathKey | None = None) -> object:
    make_room(limits.max_depth)
    probe = _At(_Context(decoding=True, limits=limits, max_steps=_MAX_VALUES), None, key, 0)
    steps = (
        max_steps if max_steps is not None else STEPS_PER_VALUE * _count_values(value, limits.max_depth, probe) + 1024
    )
    at = _At(_Context(decoding=True, limits=limits, max_steps=steps), None, key, 0)
    try:
        return node.decode(value, at)
    except RecursionError:
        pass
    _too_deep(at)


def encode(
    node: _Node, x: object, limits: Limits, max_steps: int | None, key: PathKey | None = None, *, json: bool = False
) -> Value:
    make_room(limits.max_depth)
    steps = DEFAULT_ENCODE_STEPS if max_steps is None else max_steps
    at = _At(_Context(decoding=False, limits=limits, max_steps=steps, json=json), None, key, 0)
    try:
        return node.encode(x, at)
    except RecursionError:
        pass
    _too_deep(at)


def _count_json(root: Json) -> int:
    """The values in a JSON tree (its depth is limited by the reader)."""
    count = 0
    stack: list[Json] = [root]
    while stack:
        j = stack.pop()
        count += 1
        if isinstance(j, list):
            stack += j
        elif isinstance(j, dict):
            stack += j.values()
    return count


def from_schema_json(node: _Node, j: Json, limits: Limits, max_steps: int | None, key: PathKey | None = None) -> object:
    """A type's schema-based JSON (spec §16.3) as its Python value; the budget is 16 steps per JSON value by default."""
    make_room(limits.max_depth)
    steps = max_steps if max_steps is not None else STEPS_PER_VALUE * _count_json(j) + 1024
    at = _At(_Context(decoding=True, limits=limits, max_steps=steps, json=True), None, key, 0)
    try:
        return node.read_json(j, at)
    except RecursionError:
        pass
    _too_deep(at)


def to_schema_json(node: _Node, x: object, limits: Limits, max_steps: int | None, key: PathKey | None = None) -> Json:
    """A Python value of a type as its schema-based JSON (spec §16.3)."""
    make_room(limits.max_depth)
    steps = DEFAULT_ENCODE_STEPS if max_steps is None else max_steps
    at = _At(_Context(decoding=False, limits=limits, max_steps=steps, json=True), None, key, 0)
    try:
        return node.write_json(x, at)
    except RecursionError:
        pass
    _too_deep(at)


def checked(value: object, limits: Limits, key: PathKey | None = None, *, json: bool = False) -> Value:
    """A `Value` built in code, checked to be a haus value within `limits` (as `Any` encodes it).

    With `json`, for its self-describing JSON: what has no JSON form is `no-json-form`.
    """
    return encode(_BUILTINS["Any"], value, limits, None, key, json=json)
