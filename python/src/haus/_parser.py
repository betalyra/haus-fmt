"""The haus parser: recursive descent over one complete text (spec §1 to §8).

A port of typescript/packages/haus/src/parser.ts, with the same error
messages. Runs of ordinary characters are matched with regular expressions,
so the Python loop only runs at delimiters, escapes and errors. Every pattern
is linear: the possessive quantifiers (`*+`, `++`) never give back input.

Each nesting level costs two or three Python frames (`_value` → `_record` /
`_list` → `_value`; the `_items` generator is suspended, not on the stack,
while an item is parsed). `make_room` raises Python's recursion limit, when
needed, for the configured depth (at most `MAX_SUPPORTED_DEPTH`).
"""

from __future__ import annotations

import functools
import inspect
import re
import string
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from decimal import Context, Decimal
from typing import Final, Literal, Never, cast

from ._error_codes import ErrorCode
from ._errors import HausLimitsError, HausSyntaxError
from ._value import Array, Bytes, Number, Record, String, Value, Variant

MAX_SUPPORTED_DEPTH: Final = 512
"""The deepest nesting this binding supports (spec §7): 512 levels.

The parser, the decoders and encoders and the JSON mappings recurse, a few Python
frames per level, and raise Python's recursion limit as needed for the configured
depth (`make_room`). A `max_depth` above this is rejected when the `Limits` are made.
"""


@dataclass(frozen=True, slots=True, kw_only=True)
class Limits:
    """Resource limits, enforced while parsing (spec §7).

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

    def __post_init__(self) -> None:
        depth = cast("object", self.max_depth)  # whatever the caller passed
        if isinstance(depth, bool) or not isinstance(depth, int) or depth < 0:
            raise HausLimitsError(f"max_depth must be a whole number from 0 to {MAX_SUPPORTED_DEPTH}, not {depth!r}")
        if depth > MAX_SUPPORTED_DEPTH:
            raise HausLimitsError(
                f"max_depth {depth} is above {MAX_SUPPORTED_DEPTH}, the deepest nesting this binding supports (spec §7)"
            )


DEFAULT_LIMITS = Limits()


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
    """
    depth = 0
    frame = inspect.currentframe()
    while frame is not None:
        depth += 1
        frame = frame.f_back
    need = depth + _FRAMES_PER_LEVEL * max_depth + _SLACK
    if sys.getrecursionlimit() < need:
        sys.setrecursionlimit(need)


_WHITESPACE = re.compile(r"[ \t\n]*+")
_BLANKS = re.compile(r"[ \t]*+")
_IDENT = re.compile(r"[A-Za-z0-9_]*+")
_IDENT_OR_DOT = re.compile(r"[A-Za-z0-9_.]*+")

_HEX = re.compile(r"-?0x([0-9A-Fa-f](?:_?[0-9A-Fa-f])*+)")
_BIN = re.compile(r"-?0b([01](?:_?[01])*+)")
_DEC = re.compile(r"-?(?:0|[1-9](?:_?[0-9])*+)(?:\.[0-9](?:_?[0-9])*+)?(?:[eE][+-]?[0-9](?:_?[0-9])*+)?")
_EXPONENT = re.compile(r"[eE][+-]?([0-9_]++)$")

# Characters a string may hold raw: no quote, backslash, control or bidi character.
_STRING_RUN = re.compile(r'[^"\\\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]*+')
# Block string lines also allow tabs and quotes.
_BLOCK_RUN = re.compile(r"[^\\\x00-\x08\x0a-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]*+")
# Everything up to the closing `"""`, skipping escaped characters.
_BLOCK_BODY = re.compile(r'(?:[^\\"]++|\\.|"(?!""))*+', re.DOTALL)
_BLANK_LINE = re.compile(r"[ \t]*+")
_UNICODE_ESCAPE = re.compile(r"\{([0-9A-Fa-f]{1,6})\}")
_BYTES_RUN = re.compile(r"(?:[0-9A-Fa-f]{2}|[ \t])*+")

# Not allowed raw in comments: controls (tab and LF are fine; CR only before LF) and bidi.
_COMMENT_SUSPECT = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]")
_COMMENT_DELIMITER = re.compile(r"/\*|\*/")

_NUMBER_START = frozenset("-" + string.digits)
_TAG_START = frozenset(string.ascii_uppercase)
_KEY_START = frozenset(string.ascii_lowercase + "_")
_HEX_DIGITS = frozenset(string.hexdigits)
_SIMPLE_ESCAPES = {'"': '"', "\\": "\\", "n": "\n", "r": "\r", "t": "\t"}
_BOOLEAN: tuple[ErrorCode, str] = ("boolean-literal", " (booleans are the variants True / False)")
# A lowercase word where a value should be: its code, and what the message adds.
_WORDS: dict[str, tuple[ErrorCode, str]] = {
    "true": _BOOLEAN,
    "false": _BOOLEAN,
    "null": ("null-literal", " (use the variant None)"),
}
_TRIVIA_START = frozenset("\r/")  # what can follow whitespace and still be trivia (or a trivia error)
_CLOSERS = frozenset("}])")


def _run(pattern: re.Pattern[str], src: str, pos: int, end: int = sys.maxsize) -> re.Match[str]:
    """Match one of the `*+` patterns above. They also match the empty string, so they never fail."""
    m = pattern.match(src, pos, end)
    assert m is not None
    return m


def _is_bidi(c: str) -> bool:
    """Raw bidirectional controls aren't allowed outside escapes ("Trojan Source", spec §4)."""
    return "\u202a" <= c <= "\u202e" or "\u2066" <= c <= "\u2069"


def _code(c: str) -> str:
    return f"U+{ord(c):04X}"


def _raw_character(c: str, where: str) -> tuple[ErrorCode, str]:
    """The code and message for a raw control or bidi character inside a string."""
    escape = f"\\u{{{ord(c):04X}}}"
    if _is_bidi(c):
        return "bidi-control", f"raw bidirectional control character {_code(c)} (write it as {escape})"
    return "control-character", f"raw control character {_code(c)} {where} (write it as {escape})"


def _describe(c: str) -> str:
    match c:
        case "":
            return "end of input"
        case "\n":
            return "line break"
        case _:
            return f"'{c}'"


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
        """A whole file: zero or more comma-separated values (spec §6)."""
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
        if self._peek() not in _NUMBER_START:
            return None
        try:
            number = self._number()
        except HausSyntaxError:
            return None
        return number.text if self._eof() else None

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
                return Array(self._list("[", "]"))
            case '"' if self.src.startswith('"""', self.pos):
                return self._block_string()
            case '"':
                return String(self._string())
            case "x" if self.src.startswith('"', self.pos + 1):
                return self._bytes()
            case c if c in _NUMBER_START:
                return self._number()
            case c if c in _TAG_START:
                return self._variant()
            case c if c in _KEY_START:
                word = self._ident()
                code, more = _WORDS.get(word, ("bare-identifier", ""))
                self._fail(
                    code,
                    f"unexpected identifier '{word}': lowercase identifiers can only be record keys{more}",
                    self.pos - len(word),
                    expected="a value",
                    found=f"'{word}'",
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
            self._skip_trivia()
            if (c := self._peek()) != ":":
                found = _describe(c)
                self._fail(
                    "missing-colon", f"expected ':' after key '{key}', found {found}", expected="':'", found=found
                )
            self.pos += 1
            self._skip_trivia()
            value = self._value()
            if key in fields:
                self._fail("duplicate-key", f"duplicate key '{key}'", key_pos)
            fields[key] = self.last = value
        return Record(fields)

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
            case c if c in _KEY_START:
                return self._checked_word(self._ident(), "key")
            case c if c in _TAG_START:
                word = self._ident()
                self._fail(
                    "uppercase-key",
                    f"record keys must start with a lowercase letter or '_'; quote it: \"{word}\"",
                    self.pos - len(word),
                    hint=f'Quote the key: "{word}".',
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
        self.pos = _run(_BLANKS, self.src, after_tag).end()
        match self._peek():
            case "(":
                paren = self.pos
                if not (args := self._list("(", ")")):
                    self._fail(
                        "empty-payload",
                        f"empty payload: write '{tag}' without parentheses",
                        paren,
                        hint=f"Write {tag} without parentheses.",
                    )
                return Variant(tag, args)
            case "{":
                return Variant(tag, (self._record(),))
            case _:
                self.pos = after_tag
                return Variant(tag)

    # ── numbers ────────────────────────────────────────────────

    def _number(self) -> Number:
        """The literal, then what follows it, then the limits, as the reference does: a literal
        that runs into a letter is invalid however long it is. Converted only within the limits."""
        start = self.pos
        src = self.src
        radix = m = None
        for pattern, base in ((_HEX, 16), (_BIN, 2)):
            if m := pattern.match(src, start):
                radix = base
                break
        else:
            if not (m := _DEC.match(src, start)):
                self._fail("invalid-number", "invalid number", start)
        end = m.end()
        if (after := _run(_IDENT_OR_DOT, src, end).end()) > end:
            self._fail("invalid-number", f"invalid number '{src[start:after]}'", start)
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
            return Number(("-" if src[start] == "-" else "") + _decimal_text(n))
        if (e := _EXPONENT.search(m[0])) and _exceeds(e[1], self.limits.max_exponent):
            self._fail("exponent-too-large", f"exponent larger than {self.limits.max_exponent}", start)
        return Number(_normalize_exponent(m[0].replace("_", "").replace("E", "e")))

    # ── bytes ──────────────────────────────────────────────────

    def _bytes(self) -> Bytes:
        """`x"0b34 ff"`: two hex digits per byte; spaces and tabs between bytes."""
        start = self.pos
        body = start + 2  # after x"
        end = _run(_BYTES_RUN, self.src, body).end()
        # The limit counts up to the last whole byte read, as in the reference.
        limit = self.limits.max_string_length
        if end - body > limit and len(self.src[body:end].rstrip(" \t")) > limit:
            self._fail("string-too-long", f"byte string longer than {limit} characters", start)
        match self.src[end : end + 1]:
            case '"':
                pass
            case "":
                self._fail("unterminated-bytes", "unterminated byte string", start)
            case c if c in _HEX_DIGITS and end + 1 == len(self.src):
                # A digit at the end of the input: unterminated, reported at the start (like the reference).
                self._fail("unterminated-bytes", "unterminated byte string", start)
            case "\r" | "\n":
                self._fail("bytes-not-hex", 'line break in byte string (keep x"…" on one line)', end)
            case c if c in _HEX_DIGITS:
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
        return Bytes(bytes.fromhex(self.src[body:end]))

    # ── strings ────────────────────────────────────────────────

    def _string(self) -> str:
        """A `"…"` string, decoded."""
        start = self.pos
        src = self.src
        pos = start + 1
        out: list[str] = []
        while True:
            m = _run(_STRING_RUN, src, pos)
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
            case e if e in _SIMPLE_ESCAPES:
                return _SIMPLE_ESCAPES[e], at + 2
            case "u":
                if not (m := _UNICODE_ESCAPE.match(self.src, at + 2)):
                    self._fail("invalid-unicode-escape", "invalid unicode escape: expected \\u{1-6 hex digits}", at)
                cp = int(m[1], 16)
                if cp > 0x10FFFF or 0xD800 <= cp <= 0xDFFF:
                    self._fail("invalid-unicode-escape", f"\\u{{{m[1]}}} is not a Unicode scalar value", at)
                return chr(cp), m.end()
            case e:
                self._fail("invalid-escape", f"invalid escape '\\{e}'", at)

    def _block_string(self) -> String:
        start = self.pos
        src = self.src
        self.pos = _run(_BLANKS, src, start + 3).end()
        if src.startswith("\r\n", self.pos):
            self.pos += 2
        elif src.startswith("\n", self.pos):
            self.pos += 1
        else:
            self._fail(
                "block-string-opening",
                'opening """ must be followed by a line break',
                start if self._eof() else self.pos,
            )

        content = self.pos
        close = _run(_BLOCK_BODY, src, content).end()
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
        if not _BLANK_LINE.fullmatch(indent):
            self._fail("block-string-closing", 'closing """ must be on its own line', close)

        out: list[str] = []
        for line_start, line_end in lines:
            if src.startswith(indent, line_start, line_end):
                out.append(self._block_line(line_start + len(indent), line_end))
            elif _BLANK_LINE.fullmatch(src, line_start, line_end):
                out.append("")
            else:
                self._fail("block-string-indent", 'line is indented less than the closing """', line_start)
        self.pos = close + 3
        return String(self._checked("\n".join(out), start))

    def _block_line(self, start: int, end: int) -> str:
        """One block string line without its indentation, escapes decoded."""
        src = self.src
        out: list[str] = []
        pos = start
        while True:
            m = _run(_BLOCK_RUN, src, pos, end)
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
            self.pos = _run(_WHITESPACE, src, self.pos).end()
            if src[self.pos : self.pos + 1] not in _TRIVIA_START:
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
        for m in _COMMENT_DELIMITER.finditer(self.src, start):
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
        for m in _COMMENT_SUSPECT.finditer(self.src, start, end):
            i = m.start()
            match m[0]:
                case "\r" if self.src.startswith("\n", i + 1):
                    continue
                case "\r":
                    self._fail(
                        "lone-carriage-return", "carriage return without a line feed (line breaks are LF or CRLF)", i
                    )
                case c if _is_bidi(c):
                    self._fail("bidi-control", f"raw bidirectional control character {_code(c)} in comment", i)
                case c:
                    self._fail("control-character", f"raw control character {_code(c)} in comment", i)

    # ── helpers ────────────────────────────────────────────────

    def _ident(self) -> str:
        start = self.pos
        self.pos = _run(_IDENT, self.src, start).end()
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
            self._fail(
                "payload-newline",
                reason,
                expected="','",
                found=found,
                hint=f"Put the payload on the same line as {previous.tag}, or add a comma if they are two values.",
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
