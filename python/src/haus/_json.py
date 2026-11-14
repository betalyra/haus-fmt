"""JSON (spec §16): a strict I-JSON reader that keeps numbers exact, a writer,
and the mappings that need no schema: JSON read as haus (§16.1) and the
lossless form (§16.2). The plain mapping with a type is in `_decode`.

    >>> read_json('{"price": 19.90, "tags": ["a"]}', Limits())
    {'price': JsonNumber(text='19.90'), 'tags': ['a']}
    >>> write_json(lossless(Number("19.90")))
    '{"num":"19.90"}'
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

from ._errors import HausJsonError, PathKey
from ._number import normalize_number, number_limit_issue
from ._parser import Limits
from ._stream import Readable
from ._value import Array, Bytes, Number, Record, String, Value, Variant

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
_PLAIN_RUN = re.compile(r'[^"\\\x00-\x1f\ud800-\udfff]*+')
_HEX4 = re.compile(r"[0-9A-Fa-f]{4}")
_SURROGATE = re.compile(r"[\ud800-\udfff]")
_ESCAPES: Final = {'"': '"', "\\": "\\", "/": "/", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t"}


def json_number(text: str, limits: Limits) -> str | None:
    """The normalized literal (spec §2) of a JSON number `text` (`1E+05` → `1e5`), or None if it isn't one.

    Raises `ValueError` with the reason if it is beyond the limits.
    """
    if not _NUMBER.fullmatch(text):
        return None
    normalized = normalize_number(text, limits)
    if normalized is None:
        raise ValueError(f"number literal longer than {limits.max_number_length} characters")
    if (issue := number_limit_issue(normalized, limits)) is not None:
        raise ValueError(issue)
    return normalized


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

    __slots__ = ("limits", "max_depth", "pos", "text")

    def __init__(self, text: str, limits: Limits, max_depth: int, bom: bool) -> None:
        self.text: str = text
        self.limits: Limits = limits
        self.max_depth: int = max_depth
        self.pos: int = 1 if bom and text.startswith("\ufeff") else 0
        """A leading byte order mark is ignored, as in haus (spec §16), where `bom` allows one."""

    def fail(self, reason: str, pos: int | None = None) -> Never:
        raise HausJsonError.at(self.text, self.pos if pos is None else pos, reason)

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
                    self.fail(f"nesting deeper than {self.max_depth} levels")
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
                        self.fail("unexpected text after the JSON value")
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
                    self.fail(f"expected ',' or '{top.close}'", self.pos - 1)
                value = open_.pop().items

    def member_name(self, container: _Container) -> None:
        """`"name":` in an object; the name must be new."""
        start = self.pos
        if not self.text.startswith('"', start):
            self.fail("expected a member name (a string)")
        key = self.string()
        if key in container.items:
            self.fail(f"duplicate member name {json.dumps(key, ensure_ascii=False)}", start)
        self.skip()
        if not self.text.startswith(":", self.pos):
            self.fail("expected ':' after the member name")
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
                self.fail("unexpected end of the JSON text, expected a value")
            case _:
                self.fail(f"unexpected {json.dumps(c)}, expected a JSON value")

    def number(self) -> JsonNumber:
        m = _NUMBER.match(self.text, self.pos)
        if m is None:
            self.fail("invalid number")
        if len(m[0]) > self.limits.max_number_length:
            self.fail(f"number literal longer than {self.limits.max_number_length} characters")
        try:
            normalized = json_number(m[0], self.limits)
        except ValueError as e:
            self.fail(str(e))
        assert normalized is not None
        self.pos = m.end()
        return JsonNumber(normalized)

    def string(self) -> str:
        text, limit = self.text, self.limits.max_string_length
        start = self.pos
        self.pos += 1
        parts: list[str] = []
        length = 0
        while True:
            m = _PLAIN_RUN.match(text, self.pos)
            assert m is not None
            if m.end() > m.start():
                parts.append(m[0])
                length += m.end() - m.start()
            self.pos = m.end()
            c = text[self.pos] if self.pos < len(text) else ""
            if c == '"':
                self.pos += 1
                break
            if c == "\\":
                parts.append(self.escape())
                length += 1
            elif c == "":
                self.fail("unterminated string", start)
            elif _SURROGATE.match(c):
                self.fail("a lone surrogate (not Unicode text)")
            else:
                self.fail(f"raw control character U+{ord(c):04X} in a string (write it as an escape)")
            if length > limit:
                self.fail(f"string longer than {limit} characters", start)
        if length > limit:
            self.fail(f"string longer than {limit} characters", start)
        return "".join(parts)

    def escape(self) -> str:
        text, at = self.text, self.pos
        c = text[at + 1 : at + 2]
        if c != "u":
            if c not in _ESCAPES:
                self.fail("invalid escape")
            self.pos += 2
            return _ESCAPES[c]
        unit = self.hex4(at + 2)
        if 0xDC00 <= unit <= 0xDFFF:
            self.fail("an unpaired surrogate in a \\u escape")
        if 0xD800 <= unit <= 0xDBFF:
            low = self.hex4(at + 8) if text.startswith("\\u", at + 6) else -1
            if not 0xDC00 <= low <= 0xDFFF:
                self.fail("an unpaired surrogate in a \\u escape")
            self.pos = at + 12
            return chr(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
        self.pos = at + 6
        return chr(unit)

    def hex4(self, pos: int) -> int:
        if not _HEX4.match(self.text, pos):
            self.fail("expected four hex digits after \\u", pos)
        return int(self.text[pos : pos + 4], 16)


def json_text(data: str | bytes) -> str:
    """The text of JSON input: bytes must be UTF-8."""
    if isinstance(data, str):
        return data
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as e:
        valid = data[: e.start].decode("utf-8")
        raise HausJsonError.at(valid, len(valid), "invalid UTF-8") from None


def read_json(data: str | bytes, limits: Limits, max_depth: int | None = None, *, bom: bool = True) -> Json:
    """One JSON text, read strictly: I-JSON (no duplicate names, no lone surrogates) within `limits`.

    Numbers are normalized literals. `max_depth` (objects and arrays) is `limits.max_depth` by default.
    A leading byte order mark is ignored if `bom`: in JSON Lines only at the start of the stream.
    """
    text = json_text(data)
    return _Reader(text, limits, limits.max_depth if max_depth is None else max_depth, bom).document()


def mapped_depth(limits: Limits) -> int:
    """The JSON nesting read for the lossless and plain forms.

    Up to four JSON levels make one haus level (`Tag { … }` is `{"tag": …, "args": [{"rec": {…}}]}`),
    and a number one more (`{"num": …}`). The haus depth is then checked against `limits`.
    """
    return 4 * limits.max_depth + 1


# ── writing JSON text ────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class _Text:
    """Text to write as it is: punctuation between the parts of a container."""

    text: str


def write_json(j: Json) -> str:
    """JSON text on one line, without spaces; strings as UTF-8 (only `"`, `\\` and controls escaped).

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


def _string(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


# ── haus values without a schema (§16.1, §16.2) ─────────────
# Loops rather than comprehensions: one Python frame per level of nesting.

_TRUE, _FALSE, _NONE = Variant("True"), Variant("False"), Variant("None")
_TAG = re.compile(r"[A-Z][A-Za-z0-9_]*")
_HEX_BYTES = re.compile(r"(?:[0-9a-f]{2})*+")
_NORMALIZED = re.compile(r"-?(?:0|[1-9][0-9]*+)(?:\.[0-9]++)?(?:e(?:0|-?[1-9][0-9]*+))?")


def schemaless(j: Json, max_depth: int | None = None, depth: int = 0, path: tuple[PathKey, ...] = ()) -> Value:
    """JSON as a haus value (§16.1): objects are records, `true`/`false`/`null` are `True`/`False`/`None`.

    With `max_depth`, a container at `depth` or deeper is an error (`HausJsonError` with its path);
    without it, the reader has limited the nesting already.
    """
    if isinstance(j, list | dict) and max_depth is not None and depth >= max_depth:
        raise HausJsonError(f"nesting deeper than {max_depth} levels", path=path)
    match j:
        case None:
            return _NONE
        case True:
            return _TRUE
        case False:
            return _FALSE
        case str():
            return String(j)
        case JsonNumber(text):
            return Number(text)
        case list():
            items: list[Value] = []
            for i, x in enumerate(j):
                items.append(schemaless(x, max_depth, depth + 1, (*path, i)))
            return Array(tuple(items))
        case dict():
            fields: dict[str, Value] = {}
            for k, x in j.items():
                fields[k] = schemaless(x, max_depth, depth + 1, (*path, k))
            return Record(fields)


def lossless(v: Value) -> Json:
    """The lossless form of a value (§16.2). The value must be valid (checked with the `Any` type)."""
    match v:
        case String(s):
            return s
        case Number(text):
            return {"num": text}
        case Bytes(data):
            return {"bytes": data.hex()}
        case Array(items):
            return _lossless_items(items)
        case Record(fields):
            out: dict[str, Json] = {}
            for k, x in fields.items():
                out[k] = lossless(x)
            return {"rec": out}
        case Variant(tag, ()):
            return {"tag": tag}
        case Variant(tag, args):
            return {"tag": tag, "args": _lossless_items(args)}


def _lossless_items(items: tuple[Value, ...]) -> list[Json]:
    out: list[Json] = []
    for x in items:
        out.append(lossless(x))
    return out


def from_lossless(j: Json, limits: Limits, depth: int = 0, path: tuple[PathKey, ...] = ()) -> Value:
    """The value whose lossless form (§16.2) is `j`, at nesting `depth`. Raises `HausJsonError` with the path."""
    return _Lossless(limits, path).value(j, depth, ())


class _Lossless:
    __slots__ = ("limits", "prefix")

    def __init__(self, limits: Limits, prefix: tuple[PathKey, ...]) -> None:
        self.limits = limits
        self.prefix = prefix

    def fail(self, reason: str, path: tuple[PathKey, ...]) -> Never:
        raise HausJsonError(reason, path=(*self.prefix, *path))

    def deeper(self, depth: int, path: tuple[PathKey, ...]) -> int:
        """Into a container (record, array or payload): one more level, at most `max_depth`."""
        if depth >= self.limits.max_depth:
            self.fail(f"nesting deeper than {self.limits.max_depth} levels", path)
        return depth + 1

    def value(self, j: Json, depth: int, path: tuple[PathKey, ...]) -> Value:
        match j:
            case str():
                return String(j)
            case list():
                return Array(self.items(j, self.deeper(depth, path), path))
            case dict() if len(j) == 1 and "rec" in j:
                return self.record(j["rec"], depth, path)
            case dict() if len(j) == 1 and isinstance(text := j.get("num"), str):
                if not _NORMALIZED.fullmatch(text):
                    self.fail("expected a normalized number literal in 'num'", (*path, "num"))
                if (issue := number_limit_issue(text, self.limits)) is not None:
                    self.fail(issue, (*path, "num"))
                return Number(text)
            case dict() if len(j) == 1 and isinstance(hex_digits := j.get("bytes"), str):
                if not _HEX_BYTES.fullmatch(hex_digits):
                    self.fail("expected two lowercase hex digits per byte in 'bytes'", (*path, "bytes"))
                return Bytes(bytes.fromhex(hex_digits))
            case dict() if len(j) == 1 and isinstance(tag := j.get("tag"), str):
                return Variant(self.tag(tag, path))
            case dict() if (
                len(j) == 2 and isinstance(tag := j.get("tag"), str) and isinstance(args := j.get("args"), list)
            ):
                tag = self.tag(tag, path)
                args_path = (*path, "args")
                if not args:
                    self.fail("a variant without arguments has no 'args'", args_path)
                match args:
                    case [dict() as only] if len(only) == 1 and "rec" in only:
                        # `Tag { … }` is one level, as in the parser.
                        return Variant(tag, (self.record(only["rec"], depth, (*args_path, 0)),))
                    case _:
                        return Variant(tag, self.items(args, self.deeper(depth, path), args_path))
            case _:
                self.fail(f"expected the lossless form of a haus value, found {describe(j)}", path)

    def items(self, items: list[Json], depth: int, path: tuple[PathKey, ...]) -> tuple[Value, ...]:
        out: list[Value] = []
        for i, x in enumerate(items):
            out.append(self.value(x, depth, (*path, i)))
        return tuple(out)

    def record(self, fields: Json, depth: int, path: tuple[PathKey, ...]) -> Record:
        if not isinstance(fields, dict):
            self.fail(f"expected the fields of a record (an object), found {describe(fields)}", (*path, "rec"))
        d = self.deeper(depth, path)
        out: dict[str, Value] = {}
        for k, x in fields.items():
            out[k] = self.value(x, d, (*path, "rec", k))
        return Record(out)

    def tag(self, tag: str, path: tuple[PathKey, ...]) -> str:
        if not _TAG.fullmatch(tag):
            self.fail("expected a tag ([A-Z][A-Za-z0-9_]*) in 'tag'", (*path, "tag"))
        return tag


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


def json_lines(source: str | bytes | Readable | Iterable[str | bytes], max_line_length: int) -> Iterator[str]:
    """The lines of JSON Lines, without their line feeds, from a text, a file or chunks split anywhere.

    A last line without a line feed is a line too; nothing after the last line feed is not.
    """
    decoder = codecs.getincrementaldecoder("utf-8")("strict")
    pending = ""
    line = 1
    for chunk in _chunks(source):
        try:
            text = decoder.decode(chunk) if isinstance(chunk, bytes) else chunk
        except UnicodeDecodeError:
            raise HausJsonError("invalid UTF-8", line=line, column=len(pending) + 1) from None
        start = 0
        while (end := text.find("\n", start)) >= 0:
            if len(pending) + end - start > max_line_length:
                raise HausJsonError(f"line longer than {max_line_length} characters", line=line, column=1)
            yield pending + text[start:end]
            pending = ""
            start = end + 1
            line += 1
        pending += text[start:]
        if len(pending) > max_line_length:
            raise HausJsonError(f"line longer than {max_line_length} characters", line=line, column=1)
    try:
        pending += decoder.decode(b"", final=True)
    except UnicodeDecodeError:
        raise HausJsonError("invalid UTF-8 at the end", line=line, column=len(pending) + 1) from None
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
    max_line_length: int,
) -> Iterator[R]:
    """Each line of JSON Lines read as JSON, then `convert(json, index)`; syntax errors get the line's number.

    A byte order mark is ignored only at the start of the stream, as in haus streams (spec §16).
    """
    for i, text in enumerate(json_lines(source, max_line_length)):
        try:
            yield convert(read_json(text, limits, max_depth, bom=i == 0), i)
        except HausJsonError as e:
            if e.line is None:
                raise
            raise HausJsonError(e.reason, line=i + 1, column=e.column) from None
