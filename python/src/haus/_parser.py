"""The haus parser: recursive descent over one complete text (spec §1 to §8).

A port of typescript/packages/haus/src/parser.ts, with the same error
messages. Runs of ordinary characters are matched with regular expressions
(`_scan`), so the Python loop only runs at delimiters, escapes and errors.
Every pattern is linear: the possessive quantifiers (`*+`, `++`) never give
back input.

Valid text is read first by a loop for valid text (`_read_valid`): no
recursion, the common forms whole (a plain string, a plain decimal, a
`key: value,` field, an array of numbers) in one match each. Anything it
doesn't read, every error included, is read again from the start by
recursive descent, which has every check and message: an invalid text is
read at most twice, so parsing stays linear.

Recursive descent costs two or three Python frames per nesting level
(`_value` → `_record` / `_list` → `_value`; the `_items` generator is
suspended, not on the stack, while an item is parsed). `make_room` raises
Python's recursion limit, when needed, for the configured depth (at most
`MAX_SUPPORTED_DEPTH`).
"""

from __future__ import annotations

import functools
import inspect
import re
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from decimal import Context, Decimal
from typing import Any, Final, Literal, Never, cast

from ._error_codes import ErrorCode
from ._errors import UNPAIRED_SURROGATE, HausLimitsError, HausSyntaxError, unpaired_surrogate
from ._scan import (
    BIN_LITERAL,
    BLANKS,
    BLOCK_BODY,
    BLOCK_RUN,
    BYTES_RUN,
    COMMENT_DELIMITER,
    COMMENT_SUSPECT,
    DEC_LITERAL,
    DECIMAL_ARRAY,
    HEX_DIGITS,
    HEX_LITERAL,
    IDENT_OR_DOT,
    IDENT_REST,
    KEY_COLON,
    KEY_START,
    LITERAL_EXPONENT,
    NUMBER_START,
    PLAIN_NUMBER,
    PLAIN_STRING,
    RUN_STOP,
    SCALAR_FIELD,
    SCALAR_ITEM,
    SIMPLE_ESCAPES,
    STRING_RUN,
    TAG_START,
    TRIVIA_START,
    UNICODE_ESCAPE,
    WHITESPACE,
    is_bidi,
    match_blanks,
    match_separator,
    match_tag_word,
    match_whitespace,
    quote_for_message,
)
from ._value import (
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

MAX_SUPPORTED_DEPTH: Final = 512
"""The deepest nesting this binding supports (spec §7): 512 levels.

The parser, the decoders and encoders and the JSON mappings recurse, a few Python
frames per level, and raise Python's recursion limit as needed for the configured
depth (`make_room`). A `max_depth` above this is rejected when the `Limits` are made.
"""


@dataclass(frozen=True, slots=True, kw_only=True)
class Limits:
    """Resource limits, enforced while parsing (spec §7), and by the writers of values (spec §11).

    Writers of values built in code apply every limit; the canonical form and hashing only `max_nodes`.

    Raises `HausLimitsError` (a `ValueError`, code `unsupported-depth`) for a `max_depth` above
    `MAX_SUPPORTED_DEPTH` (512), or not a whole number.
    """

    max_depth: int = 256
    """Nesting depth of records, arrays and payloads: at most `MAX_SUPPORTED_DEPTH` (512)."""
    max_number_length: int = 1000
    """Characters in one number literal, including sign, separators and exponent."""
    max_exponent: int = 6144
    """Largest absolute exponent: 6144 allows `1e6144` but not `1e6145`."""
    max_string_length: int = 16 * 1024 * 1024
    """Characters in one decoded string, record key or tag, or between the quotes of a byte string."""
    max_nodes: int = 64 * 1024 * 1024
    """Values written for one top-level value (spec §7, "Values written"): the value and every element,
    field value and argument inside it, each as often as it is written. Applied by the writers of values,
    the canonical form and hashing (`too-many-nodes`), never by the parser: a value built in code whose
    parts share each other would otherwise expand without bound when written."""

    def __post_init__(self) -> None:
        depth = cast("object", self.max_depth)  # whatever the caller passed
        if isinstance(depth, bool) or not isinstance(depth, int) or depth < 0:
            raise HausLimitsError(f"max_depth must be a whole number from 0 to {MAX_SUPPORTED_DEPTH}, not {depth!r}")
        if depth > MAX_SUPPORTED_DEPTH:
            raise HausLimitsError(
                f"max_depth {depth} is above {MAX_SUPPORTED_DEPTH}, the deepest nesting this binding supports (spec §7)"
            )


DEFAULT_LIMITS = Limits()

UNLIMITED = Limits(max_number_length=1 << 62, max_exponent=1 << 62)
"""Limits that let `normalize_number` read any literal: for `Number`, which has none (spec §11).
A parser with these very limits reads an exponent of any size, also beyond `max_exponent`."""


_PRECISE = Context(prec=60)
_LOG16_10 = _PRECISE.divide(Decimal(10).ln(_PRECISE), Decimal(16).ln(_PRECISE))
"""log16(10) to 60 digits: (n - 1) times it is within 1e-38 of the exact product for any practical n."""
_MARGIN = Decimal("1e-30")


@functools.cache
def max_hex_digits(max_number_length: int) -> int:
    """The most hex digits in one hex literal for the number limit n (spec §7): 829 for 1000.

    The largest h with 16**h <= 10**(n - 1), so that every integer that parses has a decimal
    form, sign included, of at most n characters. Exact, once per limit: floor((n - 1) * log16(10)) to
    60 digits, checked with integer powers only when that lands next to a whole number.
    """
    if max_number_length < 1:
        return 0
    x = _PRECISE.multiply(max_number_length - 1, _LOG16_10)
    h = int(x)
    fraction = _PRECISE.subtract(x, h)
    if fraction > _MARGIN and _PRECISE.subtract(1, fraction) > _MARGIN:
        return h
    bound = 10 ** (max_number_length - 1)
    while h > 0 and 1 << (4 * h) > bound:
        h -= 1
    while 1 << (4 * (h + 1)) <= bound:
        h += 1
    return h


_FRAMES_PER_LEVEL: Final = 6
"""Python frames per level of nesting, with room to spare: the deepest path takes four."""
_SLACK: Final = 100


def make_room(max_depth: int) -> None:
    """Raise Python's recursion limit, if needed, so that `max_depth` levels fit above the caller.

    The parser, the decoders and the JSON mappings recurse a few frames per level: Python's
    default limit of 1000 frames holds neither 512 levels nor, called from deep inside an
    application, the default 256. The limit is only ever raised, never lowered.

    The limit is process-wide (`sys.setrecursionlimit`): it stays raised for the whole
    application, at most a few thousand frames above the caller for `MAX_SUPPORTED_DEPTH`.
    Python frames don't use the thread's C stack on CPython 3.11 and later, and haus's own
    recursive paths are tested at the maximum depth on a thread with a 512 KiB stack
    (tests/test_canonical.py); other code that recurses through C (a container's `repr`, say)
    on a thread with a small stack can overflow it before reaching a raised limit.
    """
    depth = 0
    frame = inspect.currentframe()
    while frame is not None:
        depth += 1
        frame = frame.f_back
    need = depth + _FRAMES_PER_LEVEL * max_depth + _SLACK
    if sys.getrecursionlimit() < need:
        sys.setrecursionlimit(need)


_BOOLEAN: tuple[ErrorCode, str] = ("boolean-literal", " (booleans are the variants True / False)")
# A lowercase word where a value should be: its code, and what the message adds.
_WORDS: dict[str, tuple[ErrorCode, str]] = {
    "true": _BOOLEAN,
    "false": _BOOLEAN,
    "null": ("null-literal", " (use the variant None)"),
}
_CLOSERS = frozenset("}])")
_RADIX: Final[dict[re.Pattern[str], int]] = {HEX_LITERAL: 16, BIN_LITERAL: 2}
"""The base of the integer literals that aren't decimal, by their pattern."""
_PAYLOAD_CLOSERS: Final = {"(": ")", "{": "}"}
"""What closes a payload, by what opens it."""


class _Reread(Exception):
    """The loop for valid text met something it doesn't read: recursive descent reads the text again."""


def _run(pattern: re.Pattern[str], src: str, pos: int, end: int = sys.maxsize) -> re.Match[str]:
    """Match one of the `*+` patterns above. They also match the empty string, so they never fail."""
    m = pattern.match(src, pos, end)
    assert m is not None
    return m


def _code(c: str) -> str:
    return f"U+{ord(c):04X}"


def _raw_character(c: str, where: str) -> tuple[ErrorCode, str]:
    """The code and message for a raw control or bidi character inside a string."""
    escape = f"\\u{{{ord(c):04X}}}"
    if is_bidi(c):
        return "bidi-control", f"raw bidirectional control character {_code(c)} (write it as {escape})"
    return "control-character", f"raw control character {_code(c)} {where} (write it as {escape})"


def _describe(c: str) -> str:
    match c:
        case "":
            return "end of input"
        case "\n":
            return "line break"
        case _:
            return f"'{quote_for_message(c)}'"


def _decimal_text(n: int) -> str:
    """`str(n)` without CPython's 4300-digit limit on int-to-text conversion."""
    return str(Decimal(n))


def _normalize_exponent(text: str) -> str:
    """The exponent of a decimal literal as its value (spec §2): `1e+05` is `1e5`, `1e-0` is `1e0`."""
    mantissa, e, exponent = text.partition("e")
    if not e:
        return text
    digits = exponent.lstrip("+-").lstrip("0") or "0"
    sign = "-" if exponent.startswith("-") and digits != "0" else ""
    return f"{mantissa}e{sign}{digits}"


def _exceeds(digits: str, limit: int) -> bool:
    """Whether the decimal `digits` (maybe with `_`) are larger than `limit`, without a huge `int`."""
    significant = digits.replace("_", "").lstrip("0")
    return len(significant) > len(str(limit)) or (significant != "" and int(significant) > limit)


class Parser:
    """Recursive-descent parser over one complete text."""

    __slots__ = ("depth", "directive", "last", "limits", "pos", "src")

    def __init__(self, src: str, limits: Limits = DEFAULT_LIMITS, *, directive: bool = True) -> None:
        """`directive`: the text starts the input, so `#haus` there is a version directive (spec §10)."""
        self.src = src
        self.limits = limits
        self.directive = directive
        self.pos = 0
        self.depth = 0
        self.last: Value | None = None
        """The value just parsed in a list, record or file: what decides the error when no comma follows."""

    def parse_sequence(self) -> list[Value]:
        """A whole file: zero or more comma-separated values (spec §6).

        Valid text is read by `_read_valid`, without recursion. Anything else is read again from the
        start by recursive descent, which reports the error: it has every check and message.

        A `str` can hold a lone surrogate, which UTF-8 can't: text with one is `invalid-utf8` at the
        first, before anything else, as bytes that aren't UTF-8 are (spec §4).
        """
        if (at := unpaired_surrogate(self.src)) is not None:
            self._fail("invalid-utf8", UNPAIRED_SURROGATE, at)
        try:
            return self._read_valid()
        except (_Reread, HausSyntaxError, IndexError):
            self.pos = self.depth = 0
        make_room(self.limits.max_depth)
        try:
            return self._sequence()
        except RecursionError:
            self._fail(
                "nesting-too-deep",
                f"nesting too deep for Python's recursion limit ({sys.getrecursionlimit()}); "
                "lower max_depth or raise the limit with sys.setrecursionlimit",
            )

    def value_at(self, pos: int) -> tuple[Value, int]:
        """One value starting exactly at `pos` (no whitespace before it), and the position after it.

        For text that embeds haus values, such as the arguments of a schema attribute.
        """
        self.pos = pos
        return self._value(), self.pos

    def trivia_end(self, pos: int) -> int:
        """Whitespace and comments from `pos`, as between values: the position after them.

        Schema files have the same (spec §14); a `/` that starts no comment is left for the caller.
        """
        self.pos = pos
        self._skip_space()
        return self.pos

    def number_literal(self) -> str | None:
        """The normalized literal if the whole text is one number literal within the limits, else None."""
        if self._peek() not in NUMBER_START:
            return None
        try:
            number = self._number()
        except HausSyntaxError:
            return None
        return number.text if self._eof() else None

    # ── valid text, without recursion ──────────────────────────

    def _read_valid(self) -> list[Value]:
        """The values of a file, read in one loop with a stack of the open containers.

        It reads the common forms itself (bare keys, plain strings and decimals, tags and
        brackets; runs of such items in one match each) and calls the recursive reader's methods
        for the rest (escapes, block strings, other numbers, byte strings, quoted keys, comments).
        At anything that isn't valid, or that a limit refuses, it raises `_Reread`, a
        `HausSyntaxError` or, at the end of the text, an `IndexError`: then `parse_sequence` reads
        the text again by recursive descent.
        """
        src = self.src
        end = len(src)
        limits = self.limits
        max_depth = limits.max_depth
        max_string = limits.max_string_length
        max_number = limits.max_number_length
        # No word or string of a text that short can be over the string limit: runs needn't check.
        runs = end <= max_string
        whitespace = match_whitespace
        separator = match_separator
        key_colon = KEY_COLON.match
        plain_string = PLAIN_STRING.match
        plain_number = PLAIN_NUMBER.match
        decimal_array = DECIMAL_ARRAY.match
        tag_word = match_tag_word
        blanks = match_blanks
        trivia_start = TRIVIA_START
        number_start = NUMBER_START
        tag_start = TAG_START

        pos = 1 if src.startswith("\ufeff") else 0
        if self.directive and src.startswith("#haus", pos):
            raise _Reread
        values: list[Value] = []
        # The open containers, innermost last: [closer, items (a dict for records), tag, the pending key].
        stack: list[list[Any]] = []
        # What starts at pos inside the innermost container: a record's next key, or an array's or payload's next item.
        key_next = item_next = False
        pos = whitespace(src, pos).end()
        if pos < end and src[pos] in trivia_start:
            pos = self._trivia_end(pos)
        while pos < end:
            v: Value | None = None
            if key_next:
                key_next = False
                if runs:
                    v, pos = self._scalar_fields(pos, stack[-1])
                if v is None:
                    # ── a record key and its colon ──
                    if (m := key_colon(src, pos)) is not None and len(key := m[1] or m[2]) <= max_string:
                        pos = m.end()
                    else:
                        key, pos = self._key_and_colon(pos)
                    if src[pos] in trivia_start:
                        pos = self._trivia_end(pos)
                    stack[-1][3] = key
            elif item_next:
                item_next = False
                if runs:
                    v, pos = self._scalar_items(pos, stack[-1][1])
            if v is None:
                # ── a value at pos ──
                c = src[pos]
                closer = ""
                tag: str | None = None
                if c == '"':
                    if (m := plain_string(src, pos)) is not None and len(s := m[1]) <= max_string:
                        v = string_unchecked(s)
                        pos = m.end()
                    else:
                        self.pos = pos
                        v = self._block_string() if src.startswith('"""', pos) else string_unchecked(self._string())
                        pos = self.pos
                elif c in number_start:
                    if (m := plain_number(src, pos)) is not None and m.end() - pos <= max_number:
                        v = number_unchecked(m[0])
                        pos = m.end()
                    else:
                        self.pos = pos
                        v = self._number()
                        pos = self.pos
                elif c in tag_start:
                    m = tag_word(src, pos)
                    if len(tag := m[0]) > max_string:
                        raise _Reread
                    pos = m.end()
                    payload = blanks(src, pos).end()
                    if closer := _PAYLOAD_CLOSERS.get(src[payload : payload + 1], ""):
                        pos = payload
                    else:
                        v = variant_unchecked(tag)
                elif c == "{":
                    closer = "}"
                elif c == "[":
                    if (m := decimal_array(src, pos)) is not None:
                        numbers = m[1].split(",")
                        if len(stack) >= max_depth or (len(m[1]) > max_number and max(map(len, numbers)) > max_number):
                            raise _Reread
                        v = array_unchecked(tuple(map(number_unchecked, map(str.strip, numbers))))
                        pos = m.end()
                    else:
                        closer = "]"
                elif c == "x" and src.startswith('"', pos + 1):
                    self.pos = pos
                    v = self._bytes()
                    pos = self.pos
                else:
                    raise _Reread
                if closer:
                    # ── a container opens: its first item next, or its end ──
                    if len(stack) >= max_depth:
                        raise _Reread
                    pos = whitespace(src, pos + 1).end()
                    if src[pos] in trivia_start:
                        pos = self._trivia_end(pos)
                    if src[pos] != closer:
                        stack.append([closer, {} if closer == "}" else [], tag, None])
                        key_next = closer == "}"
                        item_next = not key_next
                        continue
                    if closer == ")":
                        raise _Reread  # an empty payload
                    pos += 1
                    v = (
                        array_unchecked(())
                        if closer == "]"
                        else record_unchecked({})
                        if tag is None
                        else variant_unchecked(tag, (record_unchecked({}),))
                    )
            # ── a value v ends at pos: an item of the innermost container, or a top-level value ──
            while stack:
                frame = stack[-1]
                closer, items = frame[0], frame[1]
                if closer == "}":
                    if (key := frame[3]) in items:
                        raise _Reread  # a duplicate key
                    items[key] = v
                else:
                    items.append(v)
                m = separator(src, pos)
                comma = m[1]
                if (c := src[m.end()]) in trivia_start:
                    pos, comma = self._separator_end(pos)
                    c = src[pos]
                else:
                    pos = m.end()
                if c != closer:
                    if not comma:
                        raise _Reread
                    key_next = closer == "}"
                    item_next = not key_next
                    break  # the next item
                pos += 1
                stack.pop()
                if closer == "]":
                    v = array_unchecked(tuple(items))
                elif closer == ")":
                    v = variant_unchecked(frame[2], tuple(items))
                elif (tag := frame[2]) is None:
                    v = record_unchecked(items)
                else:
                    v = variant_unchecked(tag, (record_unchecked(items),))
            else:
                assert v is not None  # every way to here reads a value
                values.append(v)
                m = separator(src, pos)
                comma = m[1]
                if m.end() < end and src[m.end()] in trivia_start:
                    pos, comma = self._separator_end(pos)
                else:
                    pos = m.end()
                if pos < end and not comma:
                    raise _Reread
        if stack:
            raise _Reread
        return values

    def _scalar_fields(self, pos: int, frame: list[Any]) -> tuple[Value | None, int]:
        """A run of record fields `key: scalar,` at `pos`, in one match each, into the frame's record.

        Scalars are plain strings, plain decimals and tags without a payload. The run's last field,
        the one not followed by a comma and another key, is not stored: its value and the position
        after it are returned (its key in the frame), for the loop to finish as any other item.
        None, and where the run stopped, when the next field isn't a scalar field (it starts there).
        """
        src = self.src
        items: dict[str, Value] = frame[1]
        field = SCALAR_FIELD.match
        max_number = self.limits.max_number_length
        while (m := field(src, pos)) is not None:
            key = m[1] or m[2]
            if (s := m[3]) is not None:
                v: Value = string_unchecked(s)
                value_end = m.end(3) + 1
            elif (n := m[4]) is not None:
                if len(n) > max_number:
                    raise _Reread
                v = number_unchecked(n)
                value_end = m.end(4)
            else:
                v = variant_unchecked(m[5])
                value_end = m.end(5)
            pos = m.end()
            if not m[6] or src[pos] in RUN_STOP:
                frame[3] = key
                return v, value_end
            if key in items:
                raise _Reread  # a duplicate key
            items[key] = v
        return None, pos

    def _scalar_items(self, pos: int, items: list[Value]) -> tuple[Value | None, int]:
        """A run of array or payload items `scalar,` at `pos`, as `_scalar_fields` reads fields."""
        src = self.src
        item = SCALAR_ITEM.match
        max_number = self.limits.max_number_length
        while (m := item(src, pos)) is not None:
            if (s := m[1]) is not None:
                v: Value = string_unchecked(s)
                value_end = m.end(1) + 1
            elif (n := m[2]) is not None:
                if len(n) > max_number:
                    raise _Reread
                v = number_unchecked(n)
                value_end = m.end(2)
            else:
                v = variant_unchecked(m[3])
                value_end = m.end(3)
            pos = m.end()
            if not m[4] or src[pos] in RUN_STOP:
                return v, value_end
            items.append(v)
        return None, pos

    def _key_and_colon(self, pos: int) -> tuple[str, int]:
        """A record key that isn't a bare or plain quoted key, or that has comments around its colon,
        and the position after the colon."""
        self.pos = pos
        key = self._key()
        pos = self._trivia_end(self.pos)
        if self.src[pos] != ":":
            raise _Reread
        return key, self._trivia_end(pos + 1)

    def _separator_end(self, pos: int) -> tuple[int, bool]:
        """What follows a value at `pos` when it has comments: the position after the trivia, a comma
        and the trivia after it, and whether there was a comma."""
        pos = self._trivia_end(pos)
        if not self.src.startswith(",", pos):
            return pos, False
        return self._trivia_end(pos + 1), True

    def _trivia_end(self, pos: int) -> int:
        """Whitespace and comments from `pos` (errors as the recursive reader has them): the position after them."""
        self.pos = pos
        self._skip_trivia()
        return self.pos

    def _sequence(self) -> list[Value]:
        if self.src.startswith("\ufeff"):
            self.pos = 1
        if self.directive and self.src.startswith("#haus", self.pos):
            self._fail(
                "version-directive",
                "this file starts with a #haus version directive: it needs a newer version of haus",
            )
        values: list[Value] = []
        self._skip_trivia()
        while not self._eof():
            values.append(self._value())
            self._skip_trivia()
            if self._eof():
                break
            if self._peek() != ",":
                self._fail_separator(values[-1], "expected ',' between top-level values")
            self.pos += 1
            self._skip_trivia()
        return values

    # ── values ─────────────────────────────────────────────────

    def _value(self) -> Value:
        match self._peek():
            case "{":
                return self._record()
            case "[":
                return array_unchecked(self._list("[", "]"))
            case '"' if self.src.startswith('"""', self.pos):
                return self._block_string()
            case '"':
                return string_unchecked(self._string())
            case "x" if self.src.startswith('"', self.pos + 1):
                return self._bytes()
            case c if c in NUMBER_START:
                return self._number()
            case c if c in TAG_START:
                return self._variant()
            case c if c in KEY_START:
                word = self._ident()
                code, more = _WORDS.get(word, ("bare-identifier", ""))
                shown = quote_for_message(word)
                self._fail(
                    code,
                    f"unexpected identifier '{shown}': lowercase identifiers can only be record keys{more}",
                    self.pos - len(word),
                    expected="a value",
                    found=f"'{shown}'",
                )
            case c:
                # `+1` and `.5`: a number written the way other languages allow.
                self._fail(
                    "invalid-number" if c in ("+", ".") else "expected-value",
                    f"expected a value, found {_describe(c)}",
                    expected="a value",
                    found=_describe(c),
                )

    def _items(self, open_: str, close: str) -> Iterator[None]:
        """Walk `open item, item, … close` (trailing comma allowed), one nesting level deeper.

        Yields at the start of each item; the caller parses it, and sets `last` to it, before resuming.
        """
        start = self.pos
        self.depth += 1
        if self.depth > self.limits.max_depth:
            self._fail("nesting-too-deep", f"nesting deeper than {self.limits.max_depth} levels")
        self.pos += 1
        self._skip_trivia()
        while (c := self._peek()) != close:
            if c == "":
                self._unclosed(open_, close, start)
            yield
            item = self.last
            self._skip_trivia()
            match self._peek():
                case ",":
                    self.pos += 1
                    self._skip_trivia()
                case c if c == close:
                    pass
                case "":
                    self._unclosed(open_, close, start)
                case _:
                    assert item is not None
                    self._fail_separator(item, f"expected ',' or '{close}'", close)
        self.pos += 1
        self.depth -= 1

    def _record(self) -> Record:
        fields: dict[str, Value] = {}
        for _ in self._items("{", "}"):
            key_pos = self.pos
            key = self._key()
            # At the second key's name, before its colon and value (spec §8).
            if key in fields:
                self._fail("duplicate-key", f"duplicate key '{quote_for_message(key)}'", key_pos)
            self._skip_trivia()
            if (c := self._peek()) != ":":
                found = _describe(c)
                self._fail(
                    "missing-colon",
                    f"expected ':' after key '{quote_for_message(key)}', found {found}",
                    expected="':'",
                    found=found,
                )
            self.pos += 1
            self._skip_trivia()
            fields[key] = self.last = self._value()
        return record_unchecked(fields)

    def _list(self, open_: str, close: str) -> tuple[Value, ...]:
        # A plain loop, not a comprehension: on Python 3.11 a comprehension is one more frame per level.
        items: list[Value] = []
        for _ in self._items(open_, close):
            self.last = item = self._value()
            items.append(item)
        return tuple(items)

    def _key(self) -> str:
        match self._peek():
            case '"' if self.src.startswith('"""', self.pos):
                self._fail("block-string-key", "block strings can't be record keys")
            case '"':
                return self._string()
            case c if c in KEY_START:
                return self._checked_word(self._ident(), "key")
            case c if c in TAG_START:
                word = self._ident()
                shown = quote_for_message(word)
                self._fail(
                    "uppercase-key",
                    f"record keys must start with a lowercase letter or '_'; quote it: \"{shown}\"",
                    self.pos - len(word),
                    hint=f'Quote the key: "{shown}".',
                )
            case c:
                found = _describe(c)
                self._fail(
                    "expected-key", f"expected a record key, found {found}", expected="a record key", found=found
                )

    def _variant(self) -> Variant:
        tag = self._checked_word(self._ident(), "tag")
        after_tag = self.pos
        # The payload must follow on the same line: only spaces and tabs in between.
        # Otherwise `Heartbeat⏎{ a: 1 }` with a forgotten comma would silently
        # become one variant with a payload (spec §5).
        self.pos = _run(BLANKS, self.src, after_tag).end()
        match self._peek():
            case "(":
                paren = self.pos
                if not (args := self._list("(", ")")):
                    self._fail(
                        "empty-payload",
                        f"empty payload: write '{quote_for_message(tag)}' without parentheses",
                        paren,
                        hint=f"Write {quote_for_message(tag)} without parentheses.",
                    )
                return variant_unchecked(tag, args)
            case "{":
                return variant_unchecked(tag, (self._record(),))
            case _:
                self.pos = after_tag
                return variant_unchecked(tag)

    # ── numbers ────────────────────────────────────────────────

    def _number(self) -> Number:
        """The literal, then what follows it, then the limits, as the reference does: a literal
        that runs into a letter is invalid however long it is. Converted only within the limits."""
        start = self.pos
        src = self.src
        m = HEX_LITERAL.match(src, start) or BIN_LITERAL.match(src, start) or DEC_LITERAL.match(src, start)
        if m is None:
            raise HausSyntaxError.at(src, start, "invalid-number", "invalid number")
        radix = _RADIX.get(m.re)
        end = m.end()
        if (after := _run(IDENT_OR_DOT, src, end).end()) > end:
            self._fail("invalid-number", f"invalid number '{quote_for_message(src[start:after])}'", start)
        if end - start > self.limits.max_number_length:
            self._fail(
                "number-too-long", f"number literal longer than {self.limits.max_number_length} characters", start
            )
        # Hex digits beyond the limit's would make an integer longer than the limit in decimal (spec §7).
        if radix == 16 and len(m[1]) - m[1].count("_") > (most := max_hex_digits(self.limits.max_number_length)):
            self._fail("number-too-long", f"hex literal with more than {most} hex digits", start)
        self.pos = end
        if radix is not None:
            n = int(m[1].replace("_", ""), radix)
            # The sign stays, also on zero: `-0x0` is `-0`, as `-0` is (spec §2).
            return number_unchecked(("-" if src[start] == "-" else "") + _decimal_text(n))
        e = LITERAL_EXPONENT.search(m[0])
        if e and self.limits is not UNLIMITED and _exceeds(e[1], self.limits.max_exponent):
            self._fail("exponent-too-large", f"exponent larger than {self.limits.max_exponent}", start)
        return number_unchecked(_normalize_exponent(m[0].replace("_", "").replace("E", "e")))

    # ── bytes ──────────────────────────────────────────────────

    def _bytes(self) -> Bytes:
        """`x"0b34 ff"`: two hex digits per byte; spaces and tabs between bytes."""
        start = self.pos
        body = start + 2  # after x"
        end = _run(BYTES_RUN, self.src, body).end()
        # The limit counts up to the last whole byte read, as in the reference.
        limit = self.limits.max_string_length
        if end - body > limit and len(self.src[body:end].rstrip(" \t")) > limit:
            self._fail("string-too-long", f"byte string longer than {limit} characters", start)
        match self.src[end : end + 1]:
            case '"':
                pass
            case "":
                self._fail("unterminated-bytes", "unterminated byte string", start)
            case c if c in HEX_DIGITS and end + 1 == len(self.src):
                # A digit at the end of the input: unterminated, reported at the start (like the reference).
                self._fail("unterminated-bytes", "unterminated byte string", start)
            case "\r" | "\n":
                self._fail("bytes-not-hex", 'line break in byte string (keep x"…" on one line)', end)
            case c if c in HEX_DIGITS:
                self._fail(
                    "bytes-odd-digits",
                    "a byte needs two hex digits (an odd number of digits, or a space inside a byte)",
                    end,
                )
            case c:
                self._fail(
                    "bytes-not-hex", f"invalid character {_describe(c)} in byte string (expected hex digits)", end
                )
        self.pos = end + 1
        return bytes_unchecked(bytes.fromhex(self.src[body:end]))

    # ── strings ────────────────────────────────────────────────

    def _string(self) -> str:
        """A `"…"` string, decoded."""
        start = self.pos
        src = self.src
        pos = start + 1
        out: list[str] = []
        while True:
            m = _run(STRING_RUN, src, pos)
            out.append(m[0])
            pos = m.end()
            match src[pos : pos + 1]:
                case '"':
                    break
                case "\\":
                    text, pos = self._escape(pos)
                    out.append(text)
                case "":
                    self._fail("unterminated-string", "unterminated string", start)
                case "\n":
                    self._fail("string-line-break", 'line break in string (use \\n or a """ block string)', pos)
                case "\t":
                    self._fail("control-character", "raw tab in string (use \\t)", pos)
                case c:
                    self._fail(*_raw_character(c, "in string"), pos)
        self.pos = pos + 1
        return self._checked("".join(out), start)

    def _escape(self, at: int) -> tuple[str, int]:
        """At a backslash: the escaped text and the position after the escape."""
        match self.src[at + 1 : at + 2]:
            case e if e in SIMPLE_ESCAPES:
                return SIMPLE_ESCAPES[e], at + 2
            case "u":
                if not (m := UNICODE_ESCAPE.match(self.src, at + 2)):
                    self._fail("invalid-unicode-escape", "invalid unicode escape: expected \\u{1-6 hex digits}", at)
                cp = int(m[1], 16)
                if cp > 0x10FFFF or 0xD800 <= cp <= 0xDFFF:
                    self._fail("invalid-unicode-escape", f"\\u{{{m[1]}}} is not a Unicode scalar value", at)
                return chr(cp), m.end()
            case e:
                self._fail("invalid-escape", f"invalid escape '\\{quote_for_message(e)}'", at)

    def _block_string(self) -> String:
        start = self.pos
        src = self.src
        self.pos = _run(BLANKS, src, start + 3).end()
        if src.startswith("\r\n", self.pos):
            self.pos += 2
        elif src.startswith("\n", self.pos):
            self.pos += 1
        else:
            # At the first character after the quotes and their blanks, or the end of the input (spec §8).
            self._fail("block-string-opening", 'opening """ must be followed by a line break', self.pos)

        content = self.pos
        close = _run(BLOCK_BODY, src, content).end()
        if not src.startswith('"""', close):
            self._fail("unterminated-block-string", "unterminated block string", start)

        # Split into lines (LF or CRLF), as (start, end) positions in the source.
        lines: list[tuple[int, int]] = []
        at = content
        while (newline := src.find("\n", at, close)) >= 0:
            end = newline - 1 if newline > at and src[newline - 1] == "\r" else newline
            lines.append((at, end))
            at = newline + 1
        indent = src[at:close]
        if not BLANKS.fullmatch(indent):
            self._fail("block-string-closing", 'closing """ must be on its own line', close)

        out: list[str] = []
        for line_start, line_end in lines:
            if src.startswith(indent, line_start, line_end):
                out.append(self._block_line(line_start + len(indent), line_end))
            elif BLANKS.fullmatch(src, line_start, line_end):
                out.append("")
            else:
                self._fail("block-string-indent", 'line is indented less than the closing """', line_start)
        self.pos = close + 3
        return string_unchecked(self._checked("\n".join(out), start))

    def _block_line(self, start: int, end: int) -> str:
        """One block string line without its indentation, escapes decoded."""
        src = self.src
        out: list[str] = []
        pos = start
        while True:
            m = _run(BLOCK_RUN, src, pos, end)
            out.append(m[0])
            pos = m.end()
            if pos >= end:
                return "".join(out)
            if src[pos] != "\\":
                self._fail(*_raw_character(src[pos], "in block string"), pos)
            text, pos = self._escape(pos)
            out.append(text)

    def _checked_word(self, word: str, what: Literal["key", "tag"]) -> str:
        """A record key or tag just read (spec §7: the string limit counts them too); the error is at its start."""
        if len(word) > self.limits.max_string_length:
            self._fail(
                "key-too-long" if what == "key" else "tag-too-long",
                f"{what} longer than {self.limits.max_string_length} characters",
                self.pos - len(word),
            )
        return word

    def _checked(self, s: str, start: int) -> str:
        if len(s) > self.limits.max_string_length:
            self._fail("string-too-long", f"string longer than {self.limits.max_string_length} characters", start)
        return s

    # ── trivia ─────────────────────────────────────────────────

    def _skip_trivia(self) -> None:
        self._skip_space()
        if self.src.startswith("/", self.pos):
            self._fail("stray-slash", "unexpected '/' (comments are // or /* */)")

    def _skip_space(self) -> None:
        """Whitespace and comments, up to anything else (a `/` that starts no comment included)."""
        src = self.src
        while True:
            self.pos = _run(WHITESPACE, src, self.pos).end()
            if src[self.pos : self.pos + 1] not in TRIVIA_START:
                return
            match src[self.pos : self.pos + 2]:
                case "\r\n":
                    self.pos += 2
                case "//":
                    newline = src.find("\n", self.pos)
                    end = len(src) if newline < 0 else newline
                    self._check_comment(self.pos, end)
                    self.pos = end
                case "/*":
                    self._skip_block_comment()
                case next_two if next_two.startswith("\r"):
                    self._fail(
                        "lone-carriage-return", "carriage return without a line feed (line breaks are LF or CRLF)"
                    )
                case _:
                    return

    def _skip_block_comment(self) -> None:
        """`/* … */`, which nest."""
        start = self.pos
        depth = 0
        for m in COMMENT_DELIMITER.finditer(self.src, start):
            depth += 1 if m[0] == "/*" else -1
            if depth == 0:
                self._check_comment(start, m.end())
                self.pos = m.end()
                return
        self._fail("unterminated-comment", "unterminated block comment", start)

    def _check_comment(self, start: int, end: int) -> None:
        """Comments are where "Trojan Source" attacks hide reordered text, and where
        control characters (ESC, CSI, NUL) can rewrite what a terminal shows.
        Allowed: tab, and in block comments line breaks (CR only before LF)."""
        for m in COMMENT_SUSPECT.finditer(self.src, start, end):
            i = m.start()
            match m[0]:
                case "\r" if self.src.startswith("\n", i + 1):
                    continue
                case "\r":
                    self._fail(
                        "lone-carriage-return", "carriage return without a line feed (line breaks are LF or CRLF)", i
                    )
                case c if is_bidi(c):
                    self._fail("bidi-control", f"raw bidirectional control character {_code(c)} in comment", i)
                case c:
                    self._fail("control-character", f"raw control character {_code(c)} in comment", i)

    # ── helpers ────────────────────────────────────────────────

    def _ident(self) -> str:
        start = self.pos
        self.pos = _run(IDENT_REST, self.src, start).end()
        return self.src[start : self.pos]

    def _peek(self) -> str:
        """The next character, or "" at the end."""
        return self.src[self.pos : self.pos + 1]

    def _eof(self) -> bool:
        return self.pos >= len(self.src)

    def _unclosed(self, open_: str, close: str, start: int) -> Never:
        self._fail("unclosed-bracket", f"unclosed '{open_}'", start, expected=f"'{close}'")

    def _fail_separator(self, previous: Value, message: str, close: str | None = None) -> Never:
        """After `previous`, something other than a comma (or the closing bracket `close`).

        Which mistake it is: a payload `(…)` or `{…}` on a line after its tag (the tag took
        no payload, so anything between them was a line break or a comment), a closing
        bracket of the wrong kind, or a missing comma.
        """
        c = self._peek()
        found = _describe(c)
        reason = f"{message}, found {found}"
        if c in ("(", "{") and isinstance(previous, Variant) and not previous.args:
            tag = quote_for_message(previous.tag)
            self._fail(
                "payload-newline",
                reason,
                expected="','",
                found=found,
                hint=f"Put the payload on the same line as {tag}, or add a comma if they are two values.",
            )
        if c in _CLOSERS:
            self._fail(
                "unexpected-closer", reason, expected="','" if close is None else f"',' or '{close}'", found=found
            )
        self._fail("missing-comma", reason, expected="','", found=found)

    def _fail(
        self,
        code: ErrorCode,
        reason: str,
        at: int | None = None,
        *,
        hint: str | None = None,
        expected: str | None = None,
        found: str | None = None,
    ) -> Never:
        pos = self.pos if at is None else at
        raise HausSyntaxError.at(self.src, pos, code, reason, hint=hint, expected=expected, found=found)
