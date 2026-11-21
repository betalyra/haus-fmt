"""The standard formatter and the value writers (spec §11): a port of go/format.go and go/lines.go.

`format` reformats haus text, keeping comments, blank lines and the spelling of numbers, byte
strings and `"…"` strings. The text is checked by the parser first, so its errors are exactly
the parser's (codes and positions); a second pass over the checked text, walking the parsed
values alongside, finds the comments and line breaks around every entry and builds a syntax
tree (`_Scanner`), which the printer writes in a layout (`_Printer`).

`stringify` and `stringify_all` write values built in code: the same tree, built from the
values (`_Builder`, which checks that they are within the limits), through the same printer.

Both passes and the printer recurse, a few Python frames per level of nesting; `make_room`
raises Python's recursion limit for the depth the limits allow, as the parser does. A
positional payload's width on one line is measured once (`_Node.iw`), so formatting stays
linear in the text.

    >>> import haus
    >>> print(haus.format('{ name: "Ada", // who\\n tags: [0xFF] }'), end="")
    {
      name: "Ada", // who
      tags: [
        0xFF,
      ],
    }
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping, Sequence
from typing import Final, Literal, Never

from ._error_codes import ErrorCode
from ._errors import HausEncodeError, HausSyntaxError, PathKey
from ._number import number_limit_issue
from ._parser import DEFAULT_LIMITS, Limits, Parser, make_room
from ._scan import (
    BIDI,
    BIN_LITERAL,
    BLOCK_BODY,
    DEC_LITERAL,
    HEX_LITERAL,
    IDENT_CHARS,
    LINE_SEPARATORS,
    key_text,
    match_blanks,
    never_fails,
    quote,
)
from ._value import Array, Bytes, Number, Record, String, Value, Variant

Style = Literal["pretty", "compact", "minimised"]
"""The layouts of spec §11:

- `"pretty"`: one entry per line in every non-empty record and array, comments and blank lines kept.
  For people who edit.
- `"compact"`: every top-level item on one line, `{ a: 1, b: [1, 2] }`. Comments are dropped. For logs.
- `"minimised"`: compact without the whitespace between tokens, `{a:1,b:[1,2]}`. Comments are dropped.
  For the wire and storage.
"""

_STYLES: Final = ("pretty", "compact", "minimised")

# ── the syntax tree ──────────────────────────────────────────

# What a node is.
_STRING, _NUMBER, _BYTES, _ARRAY, _RECORD, _VARIANT = range(6)
# How a variant's payload is written.
_BARE, _BRACES, _PARENS = range(3)


class _Comment:
    """A comment as written, a CR LF in it read as LF."""

    __slots__ = ("nl", "text")

    def __init__(self, text: str, nl: int) -> None:
        self.text = text
        self.nl = nl
        """The most line breaks in a row (with only blanks between them) since the previous comment or
        item: 0 if the comment is on that line, 2 or more if a blank line comes before it."""


class _Node:
    """One value of the tree."""

    __slots__ = ("close_nl", "dangling", "form", "items", "iw", "kind", "same_line", "string", "tag", "text")

    def __init__(self, kind: int, text: str | None = None) -> None:
        self.kind = kind
        self.text = text
        """The spelling of a number, byte string or `"…"` string; None for a string written from its value."""
        self.string = ""
        """A string's value."""
        self.tag = ""
        self.form = _BARE
        self.items: list[_Item] = []
        """The fields of a record (also a record payload), elements of an array, arguments of a payload."""
        self.dangling: list[_Comment] = []
        """Comments after the last item, before the closer."""
        self.same_line = False
        """The closer is on the line where the last item ends."""
        self.close_nl = 0
        """Line breaks before the closer, after the last item or comment."""
        self.iw = 0
        """Memo of the width on one line: 0 unknown, -1 never on one line, else the width + 1."""


class _Item:
    """An entry of a container or of the file: a field, an element or an argument, with its comments."""

    __slots__ = ("blank", "key", "leading", "node", "trailing")

    def __init__(self, blank: bool, leading: list[_Comment]) -> None:
        self.blank = blank
        """A blank line directly before it."""
        self.leading = leading
        """Comments on lines of their own above it."""
        self.key: str | None = None
        """A record field's key: written bare when it can be, else quoted with the fewest escapes."""
        self.node = _NODE_UNSET
        self.trailing: list[_Comment] = []
        """Comments after it on its last line."""


_NODE_UNSET: Final = _Node(_STRING)


class _Gap:
    """The comments and line breaks between two items."""

    __slots__ = ("comments", "nl", "run")

    def __init__(self) -> None:
        self.comments: list[_Comment] = []
        self.nl = 0
        """The most line breaks in a row after the last comment (or since the item)."""
        self.run = 0
        """The line breaks in a row so far: a comment or a comma ends a row."""


def _blank_nl(blank: bool) -> int:
    return 2 if blank else 0


def _trailing_count(g: _Gap) -> int:
    """How many of the comments in `g` start on the line of the previous token: those with no line
    break before them, up to the first that spans lines (a comment after it starts on a later line)."""
    n = 0
    for c in g.comments:
        if c.nl != 0:
            break
        n += 1
        if "\n" in c.text:
            break
    return n


def _new_item(prev: _Item | None, g: _Gap) -> _Item:
    """The item after the gap `g`: its comments on the line of `prev` trail `prev`, the others lead the
    new item. Empties `g`."""
    cs = g.comments
    if prev is not None and cs:
        n = _trailing_count(g)
        prev.trailing += cs[:n]
        cs = cs[n:]
    item = _Item(g.nl >= 2, cs)
    g.comments = []
    g.nl = g.run = 0
    return item


def _close_items(prev: _Item | None, g: _Gap, node: _Node) -> None:
    """End a container whose last item is `prev` (None if it has none), with the gap `g` before the
    closer: the comments that dangle at its end, whether the closer is on the last item's line, and
    the line breaks before it."""
    cs = g.comments
    if prev is not None and cs:
        n = _trailing_count(g)
        prev.trailing += cs[:n]
        cs = cs[n:]
    node.dangling = cs
    node.same_line = prev is not None and not cs and g.nl == 0
    node.close_nl = g.nl


def _ends_multiline(cs: list[_Comment]) -> bool:
    """Whether the last of the comments spans lines."""
    return bool(cs) and "\n" in cs[-1].text


def _merge_record_arg(parens: _Node) -> _Node:
    """`Tag({ … })`, a positional payload whose one argument is a record, as `Tag { … }`. The comments
    inside the parentheses but outside the braces move inside the braces (spec §11)."""
    arg = parens.items[0]
    rec = arg.node
    rec.kind, rec.tag, rec.form, rec.iw = _VARIANT, parens.tag, _BRACES, 0
    # Comments before the record lead its first entry. In an empty record a blank line between them
    # and the record goes to the comment after them (pending, if that comment comes from after the record).
    pending = 0
    if arg.leading:
        if rec.items:
            first = rec.items[0]
            if first.leading:
                first.leading[0].nl = max(first.leading[0].nl, _blank_nl(arg.blank))
            else:
                first.blank = first.blank or arg.blank
            first.leading = arg.leading + first.leading
        else:
            if rec.dangling:
                rec.dangling[0].nl = max(rec.dangling[0].nl, _blank_nl(arg.blank))
            else:
                pending = _blank_nl(arg.blank)
            rec.dangling = arg.leading + rec.dangling
    # Comments after the record: on the line of its last entry they trail that entry (unless a
    # comment over several lines already ends that line), otherwise they dangle at its end, after
    # the line breaks before its closing brace (a blank line there stays).
    moved: list[_Comment] = []
    if (
        arg.trailing
        and rec.items
        and not rec.dangling
        and rec.same_line
        and not _ends_multiline(rec.items[-1].trailing)
    ):
        rec.items[-1].trailing += arg.trailing
    else:
        moved += arg.trailing
    moved += parens.dangling
    if moved:
        moved[0].nl = max(moved[0].nl, rec.close_nl, pending)
        rec.dangling = rec.dangling + moved
    return rec


# ── the tree of a checked text ───────────────────────────────

_match_space: Final = never_fails(re.compile(r"[ \t\r\n]*+"))
"""Whitespace (in a checked text, a carriage return is always part of a CR LF)."""
_COMMENT_DELIMITER: Final = re.compile(r"/\*|\*/")
# Where the scanner reads them, a checked text has them: they don't fail there.
_match_quoted: Final = never_fails(re.compile(r'"(?:[^"\\]++|\\.)*+"'))
"""A whole `"…"` string, escapes skipped."""
_match_word: Final = never_fails(re.compile(f"[{IDENT_CHARS}]*+"))
_match_block_body: Final = never_fails(BLOCK_BODY)


class _Scanner:
    """The tree of a text the parser accepted, read with its values: the values say what comes next,
    the text where it ends and what lies between."""

    __slots__ = ("pos", "spans", "src")

    def __init__(self, src: str) -> None:
        self.src = src
        self.pos: int = 0
        self.spans: list[tuple[int, int]] = []
        """Where each comment is: its start and end."""

    def file(self, values: Sequence[Value]) -> tuple[list[_Item], list[_Comment]]:
        """The top-level items and the comments after the last one."""
        src = self.src
        self.pos = 1 if src.startswith("\ufeff") else 0
        g = _Gap()
        self.trivia(g)
        items: list[_Item] = []
        prev: _Item | None = None
        for v in values:
            item = _new_item(prev, g)
            item.node = self.value(v)
            items.append(item)
            prev = item
            self.after_item(g)
        end = _Node(_ARRAY)
        _close_items(prev, g, end)
        return items, end.dangling

    def trivia(self, g: _Gap) -> None:
        """Skip whitespace and comments, recording them in `g`."""
        src = self.src
        pos = self.pos
        while True:
            end = _match_space(src, pos).end()
            if end > pos:
                if breaks := src.count("\n", pos, end):
                    g.run += breaks
                    g.nl = max(g.nl, g.run)
                pos = end
            if src.startswith("//", pos):
                newline = src.find("\n", pos)
                end = len(src) if newline < 0 else newline
                text = src[pos:end]
                if text.endswith("\r"):
                    text = text[:-1]
            elif src.startswith("/*", pos):
                depth = 0
                for m in _COMMENT_DELIMITER.finditer(src, pos):
                    depth += 1 if m[0] == "/*" else -1
                    if depth == 0:
                        end = m.end()
                        break
                text = src[pos:end].replace("\r\n", "\n")
            else:
                self.pos = pos
                return
            g.comments.append(_Comment(text, g.nl))
            g.nl = g.run = 0
            self.spans.append((pos, end))
            pos = end

    def after_item(self, g: _Gap) -> None:
        """What follows an item: comments, maybe a comma, comments."""
        self.trivia(g)
        if self.src.startswith(",", self.pos):
            self.pos += 1
            g.run = 0
            self.trivia(g)

    def value(self, v: Value) -> _Node:
        src = self.src
        pos = self.pos
        t = type(v)
        if t is String:
            assert isinstance(v, String)
            if src.startswith('"""', pos):
                self.pos = _match_block_body(src, pos + 3).end() + 3
                node = _Node(_STRING)
            else:
                self.pos = _match_quoted(src, pos).end()
                node = _Node(_STRING, src[pos : self.pos])
            node.string = v.value
            return node
        if t is Number:
            m = HEX_LITERAL.match(src, pos) or BIN_LITERAL.match(src, pos) or DEC_LITERAL.match(src, pos)
            assert m is not None
            self.pos = m.end()
            return _Node(_NUMBER, m[0])
        if t is Bytes:
            self.pos = src.index('"', pos + 2) + 1
            return _Node(_BYTES, src[pos : self.pos])
        if t is Array:
            assert isinstance(v, Array)
            return self.items(v.items, _Node(_ARRAY))
        if t is Record:
            assert isinstance(v, Record)
            return self.record(v.fields, _Node(_RECORD))
        assert isinstance(v, Variant)
        node = _Node(_VARIANT)
        node.tag = v.tag
        self.pos = pos + len(v.tag)
        if not v.args:
            return node
        self.pos = match_blanks(src, self.pos).end()
        if src.startswith("{", self.pos):
            node.form = _BRACES
            assert isinstance(v.args[0], Record)
            return self.record(v.args[0].fields, node)
        node.form = _PARENS
        node = self.items(v.args, node)
        if len(v.args) == 1 and type(v.args[0]) is Record:
            node = _merge_record_arg(node)
        return node

    def items(self, values: Iterable[Value], node: _Node) -> _Node:
        """The elements of an array or arguments of a payload, from the opening bracket to the closer."""
        self.pos += 1
        g = _Gap()
        self.trivia(g)
        items = node.items
        prev: _Item | None = None
        for v in values:
            item = _new_item(prev, g)
            item.node = self.value(v)
            items.append(item)
            prev = item
            self.after_item(g)
        self.pos += 1
        _close_items(prev, g, node)
        return node

    def record(self, fields: Mapping[str, Value], node: _Node) -> _Node:
        """The fields of a record (also of a record payload), from `{` to `}`."""
        src = self.src
        self.pos += 1
        g = _Gap()
        self.trivia(g)
        items = node.items
        prev: _Item | None = None
        for key, v in fields.items():
            item = _new_item(prev, g)
            item.key = key
            self.pos = (_match_quoted if src.startswith('"', self.pos) else _match_word)(src, self.pos).end()
            self.trivia(g)
            self.pos += 1  # the colon
            g.run = 0
            self.trivia(g)
            # Comments between the key and the value move above the entry, after its blank line.
            if g.comments:
                g.comments[0].nl = max(g.comments[0].nl, _blank_nl(item.blank))
                item.blank = False
                item.leading = item.leading + g.comments
            g = _Gap()
            item.node = self.value(v)
            items.append(item)
            prev = item
            self.after_item(g)
        self.pos += 1
        _close_items(prev, g, node)
        return node


# ── the tree of values built in code ─────────────────────────


class _Builder:
    """The tree of values built in code, checked against every limit a value can break (spec §11): the
    depth (a record payload is one level, an empty container is one too), the length of each string, key,
    tag and byte string, the number limits, and the node limit for each top-level value (`value`). Values
    are haus values by construction, so nothing else is checked."""

    __slots__ = ("limits", "nodes", "path", "root")

    def __init__(self, limits: Limits) -> None:
        self.limits = limits
        self.path: list[PathKey] = []
        self.root: tuple[PathKey, ...] = ()
        """The path of the top-level value being written: where `too-many-nodes` is reported."""
        self.nodes = 0
        """The values written so far for the top-level value."""

    def fail(self, code: ErrorCode, reason: str) -> Never:
        raise HausEncodeError(reason, tuple(self.path), code)

    def value(self, v: Value, root: tuple[PathKey, ...]) -> _Node:
        """The tree of one top-level value, at `root`: its nodes are counted on their own."""
        self.root = root
        self.path = list(root)
        self.nodes = 0
        self.count(1)
        return self.node(v, 0)

    def count(self, n: int) -> None:
        """`n` more values written (spec §7): counted a container's children at a time, before they are built."""
        self.nodes += n
        if self.nodes > self.limits.max_nodes:
            raise HausEncodeError(
                f"more than {self.limits.max_nodes} values to write (parts that share each other are written"
                " each time)",
                self.root,
                "too-many-nodes",
            )

    def enter(self, depth: int) -> None:
        """Start a container at `depth`, one level deeper."""
        if depth + 1 > self.limits.max_depth:
            self.fail("nesting-too-deep", f"nesting deeper than the limit of {self.limits.max_depth}")

    def node(self, v: Value, depth: int) -> _Node:
        match v:
            case String(s):
                if len(s) > self.limits.max_string_length:
                    self.fail("string-too-long", f"string longer than {self.limits.max_string_length} characters")
                node = _Node(_STRING)
                node.string = s
                return node
            case Number(text):
                if (issue := number_limit_issue(text, self.limits)) is not None:
                    self.fail(issue[0], f"{issue[1]}: {len(text)} characters")
                return _Node(_NUMBER, text)
            case Bytes(data):
                if 2 * len(data) > self.limits.max_string_length:
                    self.fail("string-too-long", f"byte string longer than {self.limits.max_string_length} characters")
                return _Node(_BYTES, f'x"{data.hex()}"')
            case Array(items):
                self.enter(depth)
                return self.sequence(items, _Node(_ARRAY), depth)
            case Record(fields):
                self.enter(depth)
                return self.fields(fields, _Node(_RECORD), depth)
            case Variant(tag, args):
                if len(tag) > self.limits.max_string_length:
                    self.fail("tag-too-long", f"tag longer than {self.limits.max_string_length} characters")
                node = _Node(_VARIANT)
                node.tag = tag
                if not args:
                    return node
                self.enter(depth)
                if len(args) == 1 and type(record := args[0]) is Record:
                    # `Tag { … }`: the record is the payload's one level, and one value written.
                    node.form = _BRACES
                    self.count(1)
                    return self.fields(record.fields, node, depth)
                node.form = _PARENS
                return self.sequence(args, node, depth)

    def sequence(self, values: tuple[Value, ...], node: _Node, depth: int) -> _Node:
        self.count(len(values))
        items = node.items
        path = self.path
        for i, v in enumerate(values):
            path.append(i)
            item = _Item(False, [])
            item.node = self.node(v, depth + 1)
            items.append(item)
            path.pop()
        return node

    def fields(self, fields: Mapping[str, Value], node: _Node, depth: int) -> _Node:
        self.count(len(fields))
        items = node.items
        path = self.path
        max_key = self.limits.max_string_length
        for key, v in fields.items():
            if len(key) > max_key:
                self.fail("key-too-long", f"key longer than {max_key} characters")
            path.append(key)
            item = _Item(False, [])
            item.key = key
            item.node = self.node(v, depth + 1)
            items.append(item)
            path.pop()
        return node


# ── the printer ──────────────────────────────────────────────

_BLOCK_ESCAPED: Final = re.compile(f'[\\\\\r\\x00-\\x08\\x0a-\\x1f\\x7f-\\x9f{BIDI}{LINE_SEPARATORS}]|"(?="")')
"""What a block string line can't hold raw: a backslash, a carriage return, controls but the tab,
bidi controls, the line separators, and a quote followed by two more."""
_BLOCK_SHORT: Final = {"\\": "\\\\", "\r": "\\r", '"': '\\"'}


def _block_escape(m: re.Match[str]) -> str:
    c = m[0]
    return _BLOCK_SHORT.get(c) or f"\\u{{{ord(c):X}}}"


def _block_line(line: str) -> str:
    """One content line of a block string: escaped, and its last character too if it is a space or tab,
    so that no line ends in one (spec §11)."""
    line = _BLOCK_ESCAPED.sub(_block_escape, line)
    if line.endswith(" "):
        return line[:-1] + "\\u{20}"
    if line.endswith("\t"):
        return line[:-1] + "\\t"
    return line


def _spelling(text: str) -> str:
    """A scalar as written in the source, with raw U+2028 and U+2029 escaped: no layout writes them raw."""
    if "\u2028" in text or "\u2029" in text:
        return text.replace("\u2028", "\\u{2028}").replace("\u2029", "\\u{2029}")
    return text


class _Printer:
    """Writes a tree in a layout."""

    __slots__ = ("indent", "indents", "minimised", "out", "width")

    def __init__(self, style: Style, indent: int, width: int) -> None:
        self.out: list[str] = []
        self.indent = indent
        self.width = width
        self.minimised = style == "minimised"
        self.indents: list[str] = []

    def lines(self, items: list[_Item]) -> str:
        """Compact and minimised: each top-level item on its line, with a comma after each in a stream."""
        end = ",\n" if len(items) > 1 else "\n"
        for item in items:
            self.compact(item.node)
            self.out.append(end)
        return "".join(self.out)

    def pretty(self, items: list[_Item], dangling: list[_Comment]) -> str:
        stream = len(items) > 1
        first = True
        multiline = False
        for i, item in enumerate(items):
            first = self.leading(item, 0, first, i > 0 and multiline)
            multiline = self.entry(item, 0, stream, measure=stream)
        self.comments(dangling, 0, first)
        return "".join(self.out)

    def pad(self, level: int) -> str:
        """The indentation of `level`."""
        indents = self.indents
        while len(indents) <= level:
            indents.append(" " * (len(indents) * self.indent))
        return indents[level]

    def blank_line(self, blank: bool, first: bool) -> bool:
        """A blank line if one is wanted and this isn't the first thing in its container."""
        if blank and not first:
            self.out.append("\n")
        return False

    def comments(self, cs: list[_Comment], level: int, first: bool) -> bool:
        """Comments on lines of their own."""
        out = self.out
        for c in cs:
            first = self.blank_line(c.nl >= 2, first)
            out += (self.pad(level), c.text, "\n")
        return first

    def leading(self, item: _Item, level: int, first: bool, force: bool) -> bool:
        """The comments above an item and the blank line before it; `force` asks for a blank line
        before whatever comes first."""
        out = self.out
        for i, c in enumerate(item.leading):
            first = self.blank_line(c.nl >= 2 or (force and i == 0), first)
            out += (self.pad(level), c.text, "\n")
        return self.blank_line(item.blank or (force and not item.leading), first)

    def entry(self, item: _Item, level: int, comma: bool, *, measure: bool = False) -> bool:
        """An item on its line(s) in the pretty layout; with `measure`, whether its value took more than one line."""
        out = self.out
        pad = self.pad(level)
        out.append(pad)
        col = len(pad)
        if item.key is not None:
            key = key_text(item.key)
            out += (key, ": ")
            col += len(key) + 2
        start = len(out)
        self.value(item.node, level, col, 1 if comma else 0)
        multiline = measure and any("\n" in s for s in out[start:])
        if comma:
            out.append(",")
        for c in item.trailing:
            out += (" ", c.text)
        out.append("\n")
        return multiline

    def value(self, n: _Node, level: int, col: int, suffix: int) -> None:
        """A value in the pretty layout, starting at column `col` (in code points), with `suffix`
        characters to follow it on its last line."""
        kind = n.kind
        if kind == _STRING and "\n" in n.string:
            self.block_string(n.string, level)
        elif kind == _RECORD:
            self.container("{", "}", n, level)
        elif kind == _ARRAY:
            self.container("[", "]", n, level)
        elif kind == _VARIANT:
            if n.form == _BARE:
                self.out.append(n.tag)
            elif n.form == _BRACES:
                self.out.append(n.tag + " ")
                self.container("{", "}", n, level)
            elif (w := self.inline_width(n)) >= 0 and col + w + suffix <= self.width:
                self.compact(n)
            else:
                self.out.append(n.tag)
                self.container("(", ")", n, level)
        else:
            self.scalar(n)

    def container(self, open_: str, close: str, n: _Node, level: int) -> None:
        """A record, array or payload, one entry per line."""
        out = self.out
        if not n.items and not n.dangling:
            out.append(open_ + close)
            return
        out.append(open_ + "\n")
        first = True
        for item in n.items:
            first = self.leading(item, level + 1, first, False)
            self.entry(item, level + 1, True)
        self.comments(n.dangling, level + 1, first)
        out += (self.pad(level), close)

    def inline_width(self, n: _Node) -> int:
        """The width of a value on one line, as compact writes it, or -1 if pretty never writes it on one
        line: it holds a non-empty record or array, a multi-line string or a comment."""
        if n.iw == 0:
            n.iw = self.measure(n) + 1
        return max(n.iw - 1, -1)

    def measure(self, n: _Node) -> int:
        kind = n.kind
        if kind == _STRING:
            if "\n" in n.string:
                return -1
            return len(quote(n.string) if n.text is None else _spelling(n.text))
        if kind in (_RECORD, _ARRAY):
            return 2 if not n.items and not n.dangling else -1
        if kind == _VARIANT:
            if n.form == _BARE:
                return len(n.tag)
            if n.form == _BRACES:
                return len(n.tag) + 3 if not n.items and not n.dangling else -1
            if n.dangling:
                return -1
            w = len(n.tag) + 2 * len(n.items)
            for item in n.items:
                if item.leading or item.trailing:
                    return -1
                a = self.inline_width(item.node)
                if a < 0:
                    return -1
                w += a
            return w
        assert n.text is not None
        return len(n.text)

    def scalar(self, n: _Node) -> None:
        """A number, byte string or single-line string."""
        self.out.append(quote(n.string) if n.text is None else _spelling(n.text))

    def compact(self, n: _Node) -> None:
        """A value on one line, with the spacing of the compact layout or of the minimised one."""
        kind = n.kind
        if kind == _RECORD:
            self.compact_fields(n)
        elif kind == _ARRAY:
            self.compact_items("[", "]", n)
        elif kind == _VARIANT:
            if n.form == _BARE:
                self.out.append(n.tag)
            elif n.form == _BRACES:
                self.out.append(n.tag if self.minimised else n.tag + " ")
                self.compact_fields(n)
            else:
                self.out.append(n.tag)
                self.compact_items("(", ")", n)
        else:
            self.scalar(n)

    def compact_items(self, open_: str, close: str, n: _Node) -> None:
        out = self.out
        out.append(open_)
        comma = "," if self.minimised else ", "
        for i, item in enumerate(n.items):
            if i:
                out.append(comma)
            self.compact(item.node)
        out.append(close)

    def compact_fields(self, n: _Node) -> None:
        out = self.out
        if not n.items:
            out.append("{}")
            return
        tight = self.minimised
        out.append("{" if tight else "{ ")
        colon = ":" if tight else ": "
        comma = "," if tight else ", "
        for i, item in enumerate(n.items):
            assert item.key is not None
            out += (comma if i else "", key_text(item.key), colon)
            self.compact(item.node)
        out.append("}" if tight else " }")

    def block_string(self, s: str, level: int) -> None:
        """A string with line feeds as a `\"\"\"` block string, its content one level deeper than the entry."""
        out = self.out
        pad = self.pad(level + 1)
        out.append('"""\n')
        for line in s.split("\n"):
            if line:
                out += (pad, _block_line(line))
            out.append("\n")
        out += (pad, '"""')


# ── entry points ─────────────────────────────────────────────


def _options(style: object, indent: object, width: object) -> None:
    if style not in _STYLES:
        raise ValueError(f"style must be 'pretty', 'compact' or 'minimised', not {style!r}")
    for name, n in (("indent", indent), ("width", width)):
        if isinstance(n, bool) or not isinstance(n, int) or n < 0:
            raise ValueError(f"{name} must be a whole number of at least 0, not {n!r}")


def _text(text: str | bytes) -> str:
    """The text of a file given as a `str` or as UTF-8 bytes."""
    if isinstance(text, str):
        return text
    try:
        return text.decode("utf-8")
    except UnicodeDecodeError as e:
        valid = text[: e.start].decode("utf-8")
        raise HausSyntaxError.at(valid, len(valid), "invalid-utf8", "invalid UTF-8") from None


def _scan(text: str | bytes, limits: Limits) -> tuple[_Scanner, list[_Item], list[_Comment]]:
    src = _text(text)
    values = Parser(src, limits).parse_sequence()
    make_room(limits.max_depth)
    scanner = _Scanner(src)
    items, dangling = scanner.file(values)
    return scanner, items, dangling


def format(
    text: str | bytes,
    *,
    style: Style = "pretty",
    indent: int = 2,
    width: int = 80,
    limits: Limits = DEFAULT_LIMITS,
) -> str:
    """Reformat haus text in a standard layout (spec §11): one value, or a stream with a comma after each.

    Numbers, byte strings and `"…"` strings keep their spelling (`0xFF` stays `0xFF`); keys are
    written bare when they can be. The pretty layout keeps comments and blank lines (at most one in
    a row); compact and minimised drop them (see `has_comments` for tools that rewrite files in
    place). Formatting the result again changes nothing, and every layout holds the same values as
    the input. Bytes must be UTF-8.

    `indent` is the number of spaces per level in the pretty layout, and `width` the line width in
    code points (counting the comma after the entry) up to which a positional payload such as
    `Money(7.90, EUR)` stays on one line. Both are taken as given: an indent of 0 doesn't indent, and
    with a width of 0 every payload is broken over lines.

        >>> format('{ "a": 0xFF, b: [1, 2] } // ok', style="compact")
        '{ a: 0xFF, b: [1, 2] }\\n'

    Raises `HausSyntaxError` if `text` isn't valid haus within `limits` (the parser's error, with its
    code and position), and `ValueError` for an unknown style or a negative indent or width.
    """
    _options(style, indent, width)
    _, items, dangling = _scan(text, limits)
    printer = _Printer(style, indent, width)
    return printer.pretty(items, dangling) if style == "pretty" else printer.lines(items)


def has_comments(text: str | bytes, *, limits: Limits = DEFAULT_LIMITS) -> bool:
    """Whether haus text has comments, which the compact and minimised layouts drop.

    A tool that rewrites a file in place in those layouts must refuse when it has comments, unless
    asked to drop them (spec §11). Raises `HausSyntaxError` if `text` isn't valid haus within `limits`.

        >>> has_comments('{ a: "// not one" }'), has_comments("{ a: 1 } // why")
        (False, True)
    """
    return bool(_scan(text, limits)[0].spans)


def stringify_all(
    values: Iterable[Value],
    *,
    style: Style = "pretty",
    indent: int = 2,
    width: int = 80,
    limits: Limits = DEFAULT_LIMITS,
) -> str:
    """Write values as a file (spec §6, §11): one value alone, two or more as a stream with a comma after
    each, and a line break after each; no values, an empty file.

    With no source text, numbers are written normalized and in decimal, byte strings in lowercase hex
    without spaces, and strings with the fewest escapes (in pretty, a string with a line feed as a
    block string). The options are those of `format`.

        >>> from haus import Number, Variant
        >>> stringify_all([Variant("Ping"), Number("1E+05")], style="compact")
        'Ping,\\n1e5,\\n'

    Every value is a haus value (its constructors check it, spec §11), so the only errors are the
    limits of `limits` (spec §7), `haus.HausEncodeError` (a `ValueError`, with the `path` of the value):
    a number longer than the number limit (`number-too-long`) or with a larger exponent
    (`exponent-too-large`); a string or byte string (`string-too-long`), key (`key-too-long`) or tag
    (`tag-too-long`) longer than the string limit; nesting deeper than the depth limit
    (`nesting-too-deep`; a record payload is one level, an empty container is one too); and a value that
    would write more values than `max_nodes` (`too-many-nodes`, at the top-level value: its parts share
    each other, and each place writes them again). The node limit applies to each value on its own.
    """
    _options(style, indent, width)
    vs = list(values)
    make_room(limits.max_depth)
    builder = _Builder(limits)
    items: list[_Item] = []
    for i, v in enumerate(vs):
        item = _Item(False, [])
        item.node = builder.value(v, (i,) if len(vs) > 1 else ())
        items.append(item)
    printer = _Printer(style, indent, width)
    return printer.pretty(items, []) if style == "pretty" else printer.lines(items)


def stringify(
    value: Value,
    *,
    style: Style = "pretty",
    indent: int = 2,
    width: int = 80,
    limits: Limits = DEFAULT_LIMITS,
) -> str:
    """Write one value in a layout (spec §11), without a line break after it.

        >>> from haus import Array, Number, Record, String, Variant
        >>> order = Record({"id": Number("7"), "total": Variant("Money", (Number("44.40"), Variant("EUR")))})
        >>> print(stringify(order))
        {
          id: 7,
          total: Money(44.40, EUR),
        }
        >>> stringify(order, style="minimised")
        '{id:7,total:Money(44.40,EUR)}'

    See `stringify_all` for the options and errors.
    """
    return stringify_all((value,), style=style, indent=indent, width=width, limits=limits)[:-1]
