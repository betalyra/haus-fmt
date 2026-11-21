"""JSON (spec §16): a strict I-JSON reader that keeps numbers exact, a writer,
and the forms that need no schema: the JSON import (§16.1) and self-describing
JSON (§16.2). Schema-based JSON (§16.3) is in `_decode`.

    >>> read_json('{"price": 19.90, "tags": ["a"]}', Limits())
    {'price': JsonNumber(text='19.90'), 'tags': ['a']}
    >>> write_json(envelope(self_describing(Number("19.90"))))
    '{"_haus":1,"_value":{"_num":"19.90"}}'
"""

from __future__ import annotations

import base64
import binascii
import codecs
import json
import re
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from typing import Final, Never, TypeAlias, TypeVar

from ._error_codes import ErrorCode
from ._errors import UNPAIRED_SURROGATE, HausJsonError, PathKey, unpaired_surrogate
from ._number import number_limit_issue
from ._parser import Limits
from ._scan import NORMALIZED_NUMBER, TAG, quote_for_message
from ._stream import Readable
from ._value import (
    Array,
    Bytes,
    Number,
    Record,
    String,
    Value,
    Variant,
    array_unchecked,
    bytes_unchecked,
    number_unchecked,
    record_unchecked,
    string_unchecked,
    variant_unchecked,
)

R = TypeVar("R")


@dataclass(frozen=True, slots=True)
class JsonNumber:
    """A JSON number as its normalized literal (spec §2): never rounded through a float."""

    text: str


Json: TypeAlias = "bool | str | JsonNumber | list[Json] | dict[str, Json] | None"
"""A JSON value as read: objects are dicts (no duplicate names), numbers are `JsonNumber`s."""

# ── reading JSON text ────────────────────────────────────────

_WHITESPACE = re.compile(r"[ \t\n\r]*+")
_NUMBER = re.compile(r"-?(?:0|[1-9][0-9]*+)(?:\.[0-9]++)?(?:[eE][+-]?[0-9]++)?")
_NUMBER_EXPONENT = re.compile(r"[eE]([+-]?)0*([0-9]+)$")
_PLAIN_RUN = re.compile(r'[^"\\\x00-\x1f\ud800-\udfff]*+')
_STRICT_RUN = re.compile(r'[^"\\\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069\ud800-\udfff]*+')
"""A run of characters self-describing JSON allows raw: no DEL, C1 or bidi controls either (spec §16)."""
_BIDI = re.compile(r"[\u202a-\u202e\u2066-\u2069]")
_HEX4 = re.compile(r"[0-9A-Fa-f]{4}")
_SURROGATE = re.compile(r"[\ud800-\udfff]")
_ESCAPES: Final = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t"}


def json_number(text: str) -> str | None:
    """The normalized literal (spec §2) of a JSON number `text` (`1E+05` → `1e5`), or None if it isn't one."""
    if not _NUMBER.fullmatch(text):
        return None
    if (m := _NUMBER_EXPONENT.search(text)) is None:
        return text
    sign = "-" if m[1] == "-" and m[2] != "0" else ""
    return f"{text[: m.start()]}e{sign}{m[2]}"


def json_number_issue(text: str, limits: Limits) -> tuple[ErrorCode, str] | None:
    """Why the JSON number literal `text` is beyond the limits of spec §7 (its length, its exponent), or None."""
    if len(text) > limits.max_number_length:
        return "number-too-long", f"number literal longer than {limits.max_number_length} characters"
    if (m := _NUMBER_EXPONENT.search(text)) and (len(m[2]) > 15 or int(m[2]) > limits.max_exponent):
        return "exponent-too-large", f"exponent larger than {limits.max_exponent}"
    return None


def string_length_issue(s: str, limits: Limits) -> tuple[ErrorCode, str] | None:
    """Why the haus string `s` is beyond the string limit (spec §7), counted after escapes are read (§16)."""
    if len(s) > limits.max_string_length:
        return "string-too-long", f"string longer than {limits.max_string_length} characters"
    return None


def key_length_issue(k: str, limits: Limits) -> tuple[ErrorCode, str] | None:
    """Why the record key `k` is beyond the string limit (spec §7), counted after escapes are read (§16)."""
    if len(k) > limits.max_string_length:
        return "key-too-long", f"key longer than {limits.max_string_length} characters"
    return None


class _Container:
    """An object or array being read, with the member name whose value comes next."""

    __slots__ = ("close", "items", "key")

    def __init__(self, items: list[Json] | dict[str, Json]) -> None:
        self.items = items
        self.close = "]" if isinstance(items, list) else "}"
        self.key = ""

    def add(self, value: Json) -> None:
        if isinstance(self.items, list):
            self.items.append(value)
        else:
            self.items[self.key] = value


class _Reader:
    """A reader of one JSON text (RFC 8259, restricted to I-JSON, RFC 7493).

    Iterative, with a stack of open containers: the nesting depth is limited only by `max_depth`.
    """

    __slots__ = ("limits", "max_depth", "pos", "run", "text")

    def __init__(self, text: str, limits: Limits, max_depth: int, bom: bool, strict: bool) -> None:
        self.text: str = text
        self.limits: Limits = limits
        self.max_depth: int = max_depth
        self.pos: int = 1 if bom and text.startswith("\ufeff") else 0
        """A leading byte order mark is ignored, as in haus (spec §16), where `bom` allows one."""
        self.run: re.Pattern[str] = _STRICT_RUN if strict else _PLAIN_RUN
        """What a string may hold raw: with `strict`, no DEL, C1 or bidi controls (self-describing JSON)."""

    def fail(
        self,
        code: ErrorCode,
        reason: str,
        pos: int | None = None,
        *,
        expected: str | None = None,
        found: str | None = None,
    ) -> Never:
        at = self.pos if pos is None else pos
        raise HausJsonError.at(self.text, at, code, reason, expected=expected, found=found)

    def syntax(self, expected: str, reason: str, pos: int | None = None) -> Never:
        """Text that isn't JSON: `expected` should be at `pos` (here by default)."""
        at = self.pos if pos is None else pos
        c = self.text[at : at + 1]
        found = "end of input" if c == "" else f"U+{ord(c):04X}" if c < " " else f"'{quote_for_message(c)}'"
        self.fail("json-syntax", reason, at, expected=expected, found=found)

    def skip(self) -> None:
        m = _WHITESPACE.match(self.text, self.pos)
        assert m is not None
        self.pos = m.end()

    def document(self) -> Json:
        text = self.text
        open_: list[_Container] = []
        self.skip()
        while True:
            # A value starts here: a scalar, or a container that may be empty.
            c = text[self.pos : self.pos + 1]
            value: Json
            if c in ("{", "["):
                if len(open_) >= self.max_depth:
                    self.fail("nesting-too-deep", f"nesting deeper than {self.max_depth} levels")
                self.pos += 1
                self.skip()
                container = _Container({} if c == "{" else [])
                if text.startswith(container.close, self.pos):
                    self.pos += 1
                    value = container.items
                else:
                    open_.append(container)
                    if c == "{":
                        self.member_name(container)
                    continue
            else:
                value = self.scalar(c)
            # The value is complete: add it to its container, closing the containers it completes.
            while True:
                if not open_:
                    self.skip()
                    if self.pos < len(text):
                        self.syntax("the end of the JSON text", "unexpected text after the JSON value")
                    return value
                top = open_[-1]
                top.add(value)
                self.skip()
                c = text[self.pos : self.pos + 1]
                self.pos += 1
                if c == ",":
                    self.skip()
                    if isinstance(top.items, dict):
                        self.member_name(top)
                    break
                if c != top.close:
                    self.syntax(f"',' or '{top.close}'", f"expected ',' or '{top.close}'", self.pos - 1)
                value = open_.pop().items

    def member_name(self, container: _Container) -> None:
        """`"name":` in an object; the name must be new."""
        start = self.pos
        if not self.text.startswith('"', start):
            self.syntax("a member name", "expected a member name (a string)")
        key = self.string()
        if key in container.items:
            self.fail("duplicate-key", f'duplicate member name "{quote_for_message(key)}"', start)
        self.skip()
        if not self.text.startswith(":", self.pos):
            self.syntax("':'", "expected ':' after the member name")
        self.pos += 1
        self.skip()
        container.key = key

    def scalar(self, c: str) -> Json:
        text, pos = self.text, self.pos
        match c:
            case '"':
                return self.string()
            case "t" if text.startswith("true", pos):
                self.pos += 4
                return True
            case "f" if text.startswith("false", pos):
                self.pos += 5
                return False
            case "n" if text.startswith("null", pos):
                self.pos += 4
                return None
            case "-" | "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9":
                return self.number()
            case "":
                self.syntax("a JSON value", "unexpected end of the JSON text, expected a value")
            case _:
                self.syntax("a JSON value", f"unexpected {json.dumps(c)}, expected a JSON value")

    def number(self) -> JsonNumber:
        m = _NUMBER.match(self.text, self.pos)
        if m is None:
            self.syntax("a JSON value", "invalid number")
        if (issue := json_number_issue(m[0], self.limits)) is not None:
            self.fail(*issue)
        normalized = json_number(m[0])
        assert normalized is not None
        self.pos = m.end()
        return JsonNumber(normalized)

    def string(self) -> str:
        """A string token. Its length isn't checked here: limits count the haus value (§16), and a
        JSON string can be a member name of the form (`"_value"`), a number (`"_num"`) or base64."""
        text = self.text
        start = self.pos
        self.pos += 1
        parts: list[str] = []
        while True:
            m = self.run.match(text, self.pos)
            assert m is not None
            if m.end() > m.start():
                parts.append(m[0])
            self.pos = m.end()
            c = text[self.pos] if self.pos < len(text) else ""
            if c == '"':
                self.pos += 1
                break
            if c == "\\":
                parts.append(self.escape())
            elif c == "":
                self.fail("unterminated-string", "unterminated string", start)
            elif _SURROGATE.match(c):
                self.fail("unpaired-surrogate", "a lone surrogate (not Unicode text)")
            elif _BIDI.match(c):
                self.fail(
                    "bidi-control", f"raw bidirectional control U+{ord(c):04X} in a string (write it as an escape)"
                )
            else:
                self.fail(
                    "control-character", f"raw control character U+{ord(c):04X} in a string (write it as an escape)"
                )
        return "".join(parts)

    def escape(self) -> str:
        text, at = self.text, self.pos
        c = text[at + 1 : at + 2]
        if c != "u":
            if c not in _ESCAPES:
                self.fail("invalid-escape", "invalid escape")
            self.pos += 2
            return _ESCAPES[c]
        unit = self.hex4(at + 2)
        if 0xDC00 <= unit <= 0xDFFF:
            self.fail("unpaired-surrogate", "an unpaired surrogate in a \\u escape")
        if 0xD800 <= unit <= 0xDBFF:
            low = self.hex4(at + 8) if text.startswith("\\u", at + 6) else -1
            if not 0xDC00 <= low <= 0xDFFF:
                self.fail("unpaired-surrogate", "an unpaired surrogate in a \\u escape")
            self.pos = at + 12
            return chr(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
        self.pos = at + 6
        return chr(unit)

    def hex4(self, pos: int) -> int:
        if not _HEX4.match(self.text, pos):
            self.fail("invalid-unicode-escape", "expected four hex digits after \\u", pos)
        return int(self.text[pos : pos + 4], 16)


def json_text(data: str | bytes) -> str:
    """The text of JSON input: bytes must be UTF-8, and a `str` Unicode text (no lone surrogate)."""
    if isinstance(data, str):
        if (at := unpaired_surrogate(data)) is not None:
            raise HausJsonError.at(data, at, "invalid-utf8", UNPAIRED_SURROGATE)
        return data
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as e:
        valid = data[: e.start].decode("utf-8")
        raise HausJsonError.at(valid, len(valid), "invalid-utf8", "invalid UTF-8") from None


def read_json(
    data: str | bytes,
    limits: Limits,
    max_depth: int | None = None,
    *,
    bom: bool = True,
    strict: bool = False,
) -> Json:
    """One JSON text, read strictly: I-JSON (no duplicate names, no lone surrogates) within `limits`.

    Numbers are normalized literals. `max_depth` (objects and arrays) is `limits.max_depth` by default.
    A leading byte order mark is ignored if `bom`: in JSON Lines only at the start of the stream.
    With `strict` (self-describing JSON), raw DEL, C1 and bidi controls in strings are errors too.
    """
    text = json_text(data)
    return _Reader(text, limits, limits.max_depth if max_depth is None else max_depth, bom, strict).document()


def schema_json_depth(limits: Limits) -> int:
    """The JSON nesting read for schema-based JSON (§16.3).

    Up to four JSON levels make one haus level (`Tag { … }` is `{"_tag": …, "_args": [{"_rec": {…}}]}`),
    and a number one more (`{"_num": …}`). The haus depth is then checked against `limits`.
    """
    return 4 * limits.max_depth + 1


def haus_json_depth(limits: Limits) -> int:
    """The JSON nesting read for self-describing JSON (§16.2): one more level than schema-based JSON, the envelope."""
    return schema_json_depth(limits) + 1


# ── writing JSON text ────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class _Text:
    """Text to write as it is: punctuation between the parts of a container."""

    text: str


def write_json(j: Json) -> str:
    """JSON text on one line, without spaces; strings as UTF-8 (`"`, `\\` and controls escaped, spec §16).

    Iterative, so any nesting can be written.
    """
    out: list[str] = []
    work: list[Json | _Text] = [j]
    while work:
        match work.pop():
            case _Text(text):
                out.append(text)
            case None:
                out.append("null")
            case True:
                out.append("true")
            case False:
                out.append("false")
            case str() as s:
                out.append(_string(s))
            case JsonNumber(text):
                out.append(text)
            case list() as items:
                out.append("[")
                work.append(_Text("]"))
                for i in range(len(items) - 1, -1, -1):
                    work.append(items[i])
                    if i:
                        work.append(_Text(","))
            case dict() as members:
                out.append("{")
                work.append(_Text("}"))
                pairs = list(members.items())
                for i in range(len(pairs) - 1, -1, -1):
                    k, x = pairs[i]
                    work.append(x)
                    work.append(_Text(_string(k) + ":"))
                    if i:
                        work.append(_Text(","))
    return "".join(out)


_UNSAFE = re.compile(r"[\x7f-\x9f\u2028-\u202e\u2066-\u2069]")
"""What writers escape besides C0 controls (§16): DEL, C1 and bidi controls, which could change what is
displayed, and U+2028 and U+2029, at which some software splits lines."""


def _string(s: str) -> str:
    return _UNSAFE.sub(lambda m: f"\\u{ord(m[0]):04x}", json.dumps(s, ensure_ascii=False))


# ── haus values without a schema (§16.1, §16.2) ─────────────
# Loops rather than comprehensions: one Python frame per level of nesting.

_TRUE, _FALSE, _NONE = Variant("True"), Variant("False"), Variant("None")
_HEX_BYTES = re.compile(r"(?:[0-9a-f]{2})*+")
_VERSION: Final = JsonNumber("1")
"""The version of self-describing JSON, `_haus` in its envelope (§16.2)."""


def imported(
    j: Json, limits: Limits, max_depth: int | None = None, depth: int = 0, path: tuple[PathKey, ...] = ()
) -> Value:
    """Any JSON as a haus value, the JSON import (§16.1): objects are records, `null` is `None`.

    Nothing in the data is special: `{"_tag": "A"}` is a record. Strings and keys are checked against
    `limits` (`HausJsonError` with the path). With `max_depth`, a container at `depth` or deeper is an
    error too; without it, the reader has limited the nesting already.
    """
    if isinstance(j, list | dict) and max_depth is not None and depth >= max_depth:
        raise HausJsonError(f"nesting deeper than {max_depth} levels", code="nesting-too-deep", path=path)
    match j:
        case None:
            return _NONE
        case True:
            return _TRUE
        case False:
            return _FALSE
        case str():
            if (issue := string_length_issue(j, limits)) is not None:
                raise HausJsonError(issue[1], code=issue[0], path=path)
            return string_unchecked(j)
        case JsonNumber(text):
            return number_unchecked(text)
        case list():
            items: list[Value] = []
            for i, x in enumerate(j):
                items.append(imported(x, limits, max_depth, depth + 1, (*path, i)))
            return array_unchecked(tuple(items))
        case dict():
            fields: dict[str, Value] = {}
            for k, x in j.items():
                if (issue := key_length_issue(k, limits)) is not None:
                    raise HausJsonError(issue[1], code=issue[0], path=path)
                fields[k] = imported(x, limits, max_depth, depth + 1, (*path, k))
            return record_unchecked(fields)


def envelope(j: Json) -> Json:
    """A self-describing value in its envelope (§16.2): `{"_haus": 1, "_value": …}`, the form of a whole text."""
    return {"_haus": _VERSION, "_value": j}


def self_describing(v: Value) -> Json:
    """The self-describing form of a value (§16.2), without the envelope.

    The value must be valid (checked with the `Any` type).
    """
    match v:
        case String(s):
            return s
        case Number(text):
            return {"_num": text}
        case Bytes(data):
            return {"_bytes": data.hex()}
        case Array(items):
            return _self_describing_items(items)
        case Record(fields):
            out: dict[str, Json] = {}
            for k, x in fields.items():
                out[k] = self_describing(x)
            return {"_rec": out}
        case Variant(tag, ()):
            return {"_tag": tag}
        case Variant(tag, args):
            return {"_tag": tag, "_args": _self_describing_items(args)}


def _self_describing_items(items: tuple[Value, ...]) -> list[Json]:
    out: list[Json] = []
    for x in items:
        out.append(self_describing(x))
    return out


def from_envelope(j: Json, limits: Limits, prefix: tuple[PathKey, ...] = ()) -> Value:
    """The value of a self-describing JSON text (§16.2): the envelope, then its value.

    Paths start at the envelope (`$._value._args[1]`), after `prefix`. Raises `HausJsonError` with the path.
    """
    reader = _SelfDescribing(limits, prefix)
    if not isinstance(j, dict) or len(j) != 2 or "_haus" not in j or "_value" not in j:
        reader.fail(f'expected the envelope {{"_haus": 1, "_value": …}}, found {describe(j)}', ())
    if j["_haus"] != _VERSION:
        reader.fail(
            f"expected version 1 of self-describing JSON in '_haus', found {describe(j['_haus'])}",
            ("_haus",),
            "haus-json-version",
        )
    return reader.value(j["_value"], 0, ("_value",))


def from_self_describing(j: Json, limits: Limits, depth: int = 0, path: tuple[PathKey, ...] = ()) -> Value:
    """The value whose self-describing form (§16.2, no envelope) is `j`, at nesting `depth`.

    Raises `HausJsonError` with the path (after `path`).
    """
    return _SelfDescribing(limits, path).value(j, depth, ())


class _SelfDescribing:
    __slots__ = ("limits", "prefix")

    def __init__(self, limits: Limits, prefix: tuple[PathKey, ...]) -> None:
        self.limits = limits
        self.prefix = prefix

    def fail(self, reason: str, path: tuple[PathKey, ...], code: ErrorCode = "haus-json-form") -> Never:
        raise HausJsonError(reason, code=code, path=(*self.prefix, *path))

    def deeper(self, depth: int, path: tuple[PathKey, ...]) -> int:
        """Into a container (record, array or payload): one more level, at most `max_depth`."""
        if depth >= self.limits.max_depth:
            self.fail(f"nesting deeper than {self.limits.max_depth} levels", path, "nesting-too-deep")
        return depth + 1

    def value(self, j: Json, depth: int, path: tuple[PathKey, ...]) -> Value:
        match j:
            case str():
                if (issue := string_length_issue(j, self.limits)) is not None:
                    self.fail(issue[1], path, issue[0])
                return string_unchecked(j)
            case list():
                return array_unchecked(self.items(j, self.deeper(depth, path), path))
            case dict():
                return self.object(j, depth, path)
            case _:
                self.fail(f"expected the self-describing form of a haus value, found {describe(j)}", path)

    def object(self, j: dict[str, Json], depth: int, path: tuple[PathKey, ...]) -> Value:
        """`{"_rec": …}`, `{"_num": …}`, `{"_bytes": …}`, `{"_tag": …}` or `{"_tag": …, "_args": […]}`."""
        match j:
            case {"_rec": fields} if len(j) == 1:
                return self.record(fields, depth, path)
            case {"_num": text} if len(j) == 1:
                if not isinstance(text, str) or not NORMALIZED_NUMBER.fullmatch(text):
                    self.fail("expected a normalized number literal in '_num'", (*path, "_num"), "haus-json-number")
                if (issue := number_limit_issue(text, self.limits)) is not None:
                    self.fail(issue[1], (*path, "_num"), issue[0])
                return number_unchecked(text)
            case {"_bytes": digits} if len(j) == 1:
                if not isinstance(digits, str) or not _HEX_BYTES.fullmatch(digits):
                    self.fail(
                        "expected two lowercase hex digits per byte in '_bytes'", (*path, "_bytes"), "haus-json-bytes"
                    )
                if len(digits) > self.limits.max_string_length:
                    limit = self.limits.max_string_length
                    self.fail(f"byte string longer than {limit} characters", (*path, "_bytes"), "string-too-long")
                return bytes_unchecked(bytes.fromhex(digits))
            case {"_tag": tag} if len(j) == 1:
                return variant_unchecked(self.tag(tag, path))
            case {"_tag": tag, "_args": args} if len(j) == 2:
                return self.variant(self.tag(tag, path), args, depth, path)
            case _:
                self.fail(f"expected the self-describing form of a haus value, found {describe(j)}", path)

    def variant(self, tag: str, args: Json, depth: int, path: tuple[PathKey, ...]) -> Variant:
        """A tag with its `_args` at `path` (the variant's object)."""
        args_path = (*path, "_args")
        if not isinstance(args, list) or not args:
            self.fail("'_args' must be a non-empty array (a tag without arguments has no '_args')", args_path)
        match args:
            case [dict() as only] if len(only) == 1 and "_rec" in only:
                # `Tag { … }` is one level, as in the parser.
                return variant_unchecked(tag, (self.record(only["_rec"], depth, (*args_path, 0)),))
            case _:
                return variant_unchecked(tag, self.items(args, self.deeper(depth, path), args_path))

    def items(self, items: list[Json], depth: int, path: tuple[PathKey, ...]) -> tuple[Value, ...]:
        out: list[Value] = []
        for i, x in enumerate(items):
            out.append(self.value(x, depth, (*path, i)))
        return tuple(out)

    def record(self, fields: Json, depth: int, path: tuple[PathKey, ...]) -> Record:
        if not isinstance(fields, dict):
            self.fail(f"expected the fields of a record (an object), found {describe(fields)}", (*path, "_rec"))
        d = self.deeper(depth, path)
        out: dict[str, Value] = {}
        for k, x in fields.items():
            if (issue := key_length_issue(k, self.limits)) is not None:
                self.fail(issue[1], (*path, "_rec"), issue[0])
            out[k] = self.value(x, d, (*path, "_rec", k))
        return record_unchecked(out)

    def tag(self, tag: Json, path: tuple[PathKey, ...]) -> str:
        if not isinstance(tag, str) or not TAG.fullmatch(tag):
            self.fail(f"expected a tag ([A-Z][A-Za-z0-9_]*) in '_tag', found {describe(tag)}", path, "invalid-tag")
        if len(tag) > self.limits.max_string_length:
            self.fail(f"tag longer than {self.limits.max_string_length} characters", path, "tag-too-long")
        return tag


def self_describing_arguments(
    tag: str, args: Json, limits: Limits, depth: int, path: tuple[PathKey, ...] = ()
) -> Variant:
    """`tag` with the self-describing arguments `args` (no envelope), as the `_args` of the object at `path`."""
    return _SelfDescribing(limits, path).variant(tag, args, depth, ())


def describe(j: Json) -> str:
    """A short description of a JSON value, for errors."""
    match j:
        case None:
            return "null"
        case bool():
            return "true" if j else "false"
        case str():
            return f"string {_string(j if len(j) <= 30 else j[:30] + '…')}"
        case JsonNumber(text):
            return f"number {text if len(text) <= 30 else text[:30] + '…'}"
        case list():
            return "an array"
        case dict():
            return "an object" if not j else f"an object with {', '.join(_string(k) for k in list(j)[:3])}"


# ── base64 (RFC 4648 §4, with padding) ───────────────────────

_BASE64 = re.compile(r"(?:[A-Za-z0-9+/]{4})*+(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?")


def from_base64(text: str) -> bytes | None:
    """The bytes of canonical padded base64, or None: other characters, missing padding or nonzero pad bits."""
    if not _BASE64.fullmatch(text):
        return None
    try:
        data = base64.b64decode(text, validate=True)
    except binascii.Error:
        return None
    return data if base64.b64encode(data).decode("ascii") == text else None


def to_base64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


# ── JSON Lines ───────────────────────────────────────────────

_CHUNK_SIZE = 64 * 1024


def json_lines(source: str | bytes | Readable | Iterable[str | bytes]) -> Iterator[str]:
    """The lines of JSON Lines, without their line feeds, from a text, a file or chunks split anywhere.

    A last line without a line feed is a line too; nothing after the last line feed is not. A line
    has no length limit of its own (spec §16): the limits apply to the value read from it.
    """
    decoder = codecs.getincrementaldecoder("utf-8")("strict")
    pending = ""
    line = 1
    for chunk in _chunks(source):
        try:
            text = decoder.decode(chunk) if isinstance(chunk, bytes) else chunk
        except UnicodeDecodeError:
            raise HausJsonError("invalid UTF-8", code="invalid-utf8", line=line, column=len(pending) + 1) from None
        start = 0
        while (end := text.find("\n", start)) >= 0:
            yield pending + text[start:end]
            pending = ""
            start = end + 1
            line += 1
        pending += text[start:]
    try:
        pending += decoder.decode(b"", final=True)
    except UnicodeDecodeError:
        raise HausJsonError(
            "invalid UTF-8 at the end", code="invalid-utf8", line=line, column=len(pending) + 1
        ) from None
    if pending:
        yield pending


def _chunks(source: str | bytes | Readable | Iterable[str | bytes]) -> Iterator[str | bytes]:
    if isinstance(source, str | bytes):
        yield source
    elif isinstance(source, Readable):
        while chunk := source.read(_CHUNK_SIZE):
            yield chunk
    else:
        yield from source


def read_lines(
    source: str | bytes | Readable | Iterable[str | bytes],
    limits: Limits,
    max_depth: int,
    convert: Callable[[Json, int], R],
    *,
    strict: bool = False,
) -> Iterator[R]:
    """Each line of JSON Lines read as JSON, then `convert(json, index)`; syntax errors get the line's number.

    A byte order mark is ignored only at the start of the stream, as in haus streams (spec §16).
    `strict` is as for `read_json`.
    """
    for i, text in enumerate(json_lines(source)):
        # An empty line is no JSON text; a byte order mark after the first line is no whitespace (spec §16).
        if text in ("", "\r"):
            raise HausJsonError(
                "empty line: JSON Lines holds one JSON text per line",
                code="json-syntax",
                line=i + 1,
                column=1,
                expected="a JSON value",
                found="end of line",
            )
        if i > 0 and text.startswith("\ufeff"):
            raise HausJsonError(
                "a byte order mark at the start of a line after the first (only the stream may start with one)",
                code="json-syntax",
                line=i + 1,
                column=1,
                expected="a JSON value",
                found="U+FEFF",
            )
        try:
            yield convert(read_json(text, limits, max_depth, bom=i == 0, strict=strict), i)
        except HausJsonError as e:
            if e.line is None:
                raise
            raise e.with_line(i + 1) from None
