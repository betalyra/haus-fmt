"""Scanning haus text: the character classes of spec §4 and §8, by name, and the compiled patterns
the parser and the canonical writer match with.

Runs of ordinary characters are matched with regular expressions, so Python code only runs at
delimiters, escapes and errors. Every pattern is linear: the possessive quantifiers (`*+`, `++`)
never give back input. The `*+` patterns (`WHITESPACE`, `BLANKS`, the `…_RUN`s) also match the
empty string, so they never fail: `never_fails` types their `match` so.
"""

from __future__ import annotations

import re
import string
from collections.abc import Callable
from typing import Final, cast

# ── character classes (inside `[…]`) ─────────────────────────

CONTROLS: Final = r"\x00-\x1f\x7f-\x9f"
"""C0 controls, DEL and C1 controls: never raw in a string (spec §4)."""
CONTROLS_BUT_TAB: Final = r"\x00-\x08\x0a-\x1f\x7f-\x9f"
"""Controls a block string line can't hold raw: a tab it can."""
COMMENT_CONTROLS: Final = r"\x00-\x08\x0b-\x1f\x7f-\x9f"
"""Controls a comment can't hold raw: a tab and a line feed it can (a carriage return only before a line feed)."""
BIDI: Final = r"\u202a-\u202e\u2066-\u2069"
"""Bidirectional controls: never raw, outside escapes ("Trojan Source", spec §4)."""
LINE_SEPARATORS: Final = r"\u2028\u2029"
"""U+2028 and U+2029, at which some software splits lines: writers escape them (spec §11)."""
IDENT_CHARS: Final = r"A-Za-z0-9_"

# ── trivia ───────────────────────────────────────────────────

WHITESPACE: Final = re.compile(r"[ \t\n]*+")
BLANKS: Final = re.compile(r"[ \t]*+")
"""Spaces and tabs: between a tag and its payload, which must be on the same line (spec §5)."""
SEPARATOR: Final = re.compile(r"[ \t\n]*+(,?)[ \t\n]*+")
"""What follows an item: whitespace, maybe a comma (group 1), whitespace."""
TRIVIA_START: Final = frozenset("\r/")
"""What can follow whitespace and still be trivia (or a trivia error): CR LF and comments."""
COMMENT_SUSPECT: Final = re.compile(f"[{COMMENT_CONTROLS}{BIDI}]")
COMMENT_DELIMITER: Final = re.compile(r"/\*|\*/")

# ── words ────────────────────────────────────────────────────

IDENT_REST: Final = re.compile(f"[{IDENT_CHARS}]*+")
IDENT_OR_DOT: Final = re.compile(f"[{IDENT_CHARS}.]*+")
TAG_WORD: Final = re.compile(f"[A-Z][{IDENT_CHARS}]*+")
BARE_KEY: Final = re.compile(f"[a-z_][{IDENT_CHARS}]*")
"""A key written without quotes (with `fullmatch`)."""
TAG: Final = re.compile(f"[A-Z][{IDENT_CHARS}]*")
"""A tag (with `fullmatch`)."""
KEY_START: Final = frozenset(string.ascii_lowercase + "_")
TAG_START: Final = frozenset(string.ascii_uppercase)

# ── numbers ──────────────────────────────────────────────────

NUMBER_START: Final = frozenset("-" + string.digits)
HEX_DIGITS: Final = frozenset(string.hexdigits)
HEX_LITERAL: Final = re.compile(r"-?0x([0-9A-Fa-f](?:_?[0-9A-Fa-f])*+)")
BIN_LITERAL: Final = re.compile(r"-?0b([01](?:_?[01])*+)")
DEC_LITERAL: Final = re.compile(r"-?(?:0|[1-9](?:_?[0-9])*+)(?:\.[0-9](?:_?[0-9])*+)?(?:[eE][+-]?[0-9](?:_?[0-9])*+)?")
LITERAL_EXPONENT: Final = re.compile(r"[eE][+-]?([0-9_]++)$")

# ── strings ──────────────────────────────────────────────────

STRING_RUN: Final = re.compile(f'[^"\\\\{CONTROLS}{BIDI}]*+')
"""Characters a `"…"` string may hold raw: no quote, backslash, control or bidi character."""
BLOCK_RUN: Final = re.compile(f"[^\\\\{CONTROLS_BUT_TAB}{BIDI}]*+")
"""Block string lines also hold tabs and quotes raw."""
BLOCK_BODY: Final = re.compile(r'(?:[^\\"]++|\\.|"(?!""))*+', re.DOTALL)
"""Everything up to the closing `\"\"\"`, skipping escaped characters."""
UNICODE_ESCAPE: Final = re.compile(r"\{([0-9A-Fa-f]{1,6})\}")
BYTES_RUN: Final = re.compile(r"(?:[0-9A-Fa-f]{2}|[ \t])*+")
SIMPLE_ESCAPES: Final = {'"': '"', "\\": "\\", "n": "\n", "r": "\r", "t": "\t"}

# ── the common forms, whole: what the parser's loop for valid text reads in one match ──
#
# Plain strings (no escapes), plain decimals (no separators or exponent: their own normalized
# form, spec §2), bare and plain quoted keys, tags without a payload.

_PLAIN_STRING: Final = f'"(?!"")([^"\\\\{CONTROLS}{BIDI}]*+)"'
_DECIMAL: Final = r"-?(?:0|[1-9][0-9]*+)(?:\.[0-9]++)?"
_NOT_A_WORD: Final = f"(?![{IDENT_CHARS}.])"
_KEY: Final = f"(?:([a-z_][{IDENT_CHARS}]*+)|{_PLAIN_STRING})"
_COLON: Final = r"[ \t\n]*+:[ \t\n]*+"
_SCALAR: Final = f"(?:{_PLAIN_STRING}|({_DECIMAL}){_NOT_A_WORD}|([A-Z][{IDENT_CHARS}]*+)(?![ \\t]*+[({{]))"
_AFTER_ITEM: Final = r"[ \t\n]*+(,?)[ \t\n]*+"

PLAIN_STRING: Final = re.compile(_PLAIN_STRING)
"""A whole `"…"` string without escapes (not the start of a `\"\"\"` block string): its text is group 1."""
PLAIN_NUMBER: Final = re.compile(_DECIMAL + _NOT_A_WORD)
KEY_COLON: Final = re.compile(_KEY + _COLON)
"""A bare key (group 1) or plain quoted key (2), its colon and the whitespace around it."""
SCALAR_ITEM: Final = re.compile(_SCALAR + _AFTER_ITEM)
"""An array or payload item that is a plain string (group 1), plain decimal (2) or tag without a
payload (3), and what follows it: whitespace, maybe a comma (4), whitespace."""
SCALAR_FIELD: Final = re.compile(_KEY + _COLON + _SCALAR + _AFTER_ITEM)
"""A record field with a key as in `KEY_COLON` (groups 1, 2), a value as in `SCALAR_ITEM` (3, 4, 5)
and what follows it (6)."""
RUN_STOP: Final = frozenset("}])/\r")
"""After an item and its comma, what ends a run: the container's end (or a wrong one), or trivia."""
DECIMAL_ARRAY: Final = re.compile(rf"\[[ \t\n]*+({_DECIMAL}(?:[ \t\n]*+,[ \t\n]*+{_DECIMAL})*+)[ \t\n]*+,?[ \t\n]*+\]")
"""A whole array of plain decimals (group 1: them and the commas between them): vectors, coordinates."""

ESCAPED: Final = re.compile(f'["\\\\{CONTROLS}{LINE_SEPARATORS}{BIDI}]')
"""What a written string can't hold raw (spec §11, §12): quote, backslash, controls, bidi controls
and the line and paragraph separators."""
SHORT_ESCAPES: Final = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t"}


Matcher = Callable[[str, int], "re.Match[str]"]
"""`pattern.match` of a pattern that matches wherever it starts (it may match the empty string)."""


def never_fails(pattern: re.Pattern[str]) -> Matcher:
    """`pattern.match`, typed as never failing: for the `*+` patterns, and `TAG_WORD` at a `TAG_START`."""
    return cast(Matcher, pattern.match)


match_whitespace: Final = never_fails(WHITESPACE)
match_blanks: Final = never_fails(BLANKS)
match_separator: Final = never_fails(SEPARATOR)
match_tag_word: Final = never_fails(TAG_WORD)


def is_bidi(c: str) -> bool:
    """Raw bidirectional controls aren't allowed outside escapes ("Trojan Source", spec §4)."""
    return "\u202a" <= c <= "\u202e" or "\u2066" <= c <= "\u2069"


def _escape(m: re.Match[str]) -> str:
    c = m[0]
    return SHORT_ESCAPES.get(c) or f"\\u{{{ord(c):X}}}"


def quote(s: str) -> str:
    """A `"…"` string with the minimal escapes; the rest as `\\u{…}` in uppercase hex (spec §12)."""
    if ESCAPED.search(s) is None:
        return f'"{s}"'
    return '"' + ESCAPED.sub(_escape, s) + '"'


_UNSAFE: Final = re.compile(f"[{CONTROLS}\\u061c\\u200e\\u200f{LINE_SEPARATORS}{BIDI}\\ud800-\\udfff]")
"""What a message never shows raw (spec §9.2): control and bidirectional characters, which a terminal or a
log would act on, the line and paragraph separators, and lone surrogates, which no output can encode."""
MAX_QUOTED: Final = 40
"""Text quoted from a file is at most 40 characters long in a message, as shown (spec §9.2)."""


def _shown(m: re.Match[str]) -> str:
    return f"\\u{{{ord(m[0]):X}}}"


def escape_for_message(text: str) -> str:
    r"""`text` with control and bidirectional characters escaped as `\u{…}`, for a message (spec §9.2).

    >>> escape_for_message("a\x1b[31mb\u202e")
    'a\\u{1B}[31mb\\u{202E}'
    """
    return _UNSAFE.sub(_shown, text)


def quote_for_message(text: str, most: int = MAX_QUOTED) -> str:
    """Text from a file (a token, a key, a name, a version) as a message shows it (spec §9.2): escaped,
    then at most `most` characters, a longer text cut between characters (never inside an escape) and
    marked with `…`, which counts.

    >>> quote_for_message("x" * 50)
    'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx…'
    """
    escaped = escape_for_message(text)
    if len(escaped) <= most:
        return escaped
    out: list[str] = []
    size = 0
    for piece in map(escape_for_message, text[:most]):
        if size + len(piece) > most - 1:
            break
        out.append(piece)
        size += len(piece)
    return "".join(out) + "…"


def key_text(k: str) -> str:
    """A record key as written: bare if it can be, else quoted."""
    return k if BARE_KEY.fullmatch(k) else quote(k)
