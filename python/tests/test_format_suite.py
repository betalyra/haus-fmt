"""The format suite (test-suite/format/README.md): every input, formatted in the pretty, compact and
minimised layouts, gives the expected files byte for byte, and the output keeps the properties of
spec §11."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict

import pytest

import haus
from haus import Number, Record, Style
from haus._format import _Item, _Printer, _scan  # pyright: ignore[reportPrivateUsage]

SUITE = Path(__file__).resolve().parents[2] / "test-suite"
FORMAT = SUITE / "format"
STYLES: tuple[Style, ...] = ("pretty", "compact", "minimised")


class Options(TypedDict, total=False):
    indent: int
    width: int


@dataclass(frozen=True)
class Case:
    name: str
    input: Path
    expected: Path
    """NAME.pretty, NAME.compact, NAME.minimised and NAME.options are here, with these extensions."""

    def text(self) -> str:
        # Raw bytes: a byte order mark stays, for the parser to skip.
        return self.input.read_bytes().decode("utf-8")

    def options(self) -> Options:
        """NAME.options, a record `{ indent: 4, width: 40 }`, for every layout."""
        file = self.expected.with_suffix(".options")
        if not file.exists():
            return {}
        options = haus.parse(file.read_text("utf-8"))
        assert isinstance(options, Record)
        assert set(options.fields) <= {"indent", "width"}
        found = Options()
        if isinstance(indent := options.fields.get("indent"), Number):
            found["indent"] = int(indent.text)
        if isinstance(width := options.fields.get("width"), Number):
            found["width"] = int(width.text)
        return found

    def output(self, style: Style) -> str:
        return self.expected.with_suffix(f".{style}").read_bytes().decode("utf-8")


def _cases() -> list[Case]:
    found = [
        Case(f"{group}/{path.stem}", path, path.with_suffix(""))
        for group in ("cases", "examples")
        for path in sorted((FORMAT / group).glob("*.haus"))
    ]
    found += [
        Case(f"valid/{path.stem}", path, FORMAT / "valid" / path.stem)
        for path in sorted((SUITE / "valid").glob("*.haus"))
    ]
    assert found, "no cases in test-suite/format"
    return found


CASES = _cases()
ids = [c.name for c in CASES]


def same_values(a: str, b: str) -> bool:
    return [haus.canonical(v) for v in haus.parse_all(a)] == [haus.canonical(v) for v in haus.parse_all(b)]


def without_comments(text: str, options: Options) -> str:
    """The pretty layout of `text` with its comments taken out of the tree."""
    _, items, _ = _scan(text, haus.DEFAULT_LIMITS)

    def strip(item: _Item) -> None:
        item.leading, item.trailing = [], []
        item.node.dangling = []
        for child in item.node.items:
            strip(child)

    for item in items:
        strip(item)
    return _Printer("pretty", options.get("indent", 2), options.get("width", 80)).pretty(items, [])


def trailing_blanks(text: str) -> list[int]:
    """The offsets of the spaces and tabs that end a line outside a comment."""
    spans = _scan(text, haus.DEFAULT_LIMITS)[0].spans
    return [m.start() for m in re.finditer(r"[ \t](?=\n|$)", text) if not any(s <= m.start() < e for s, e in spans)]


def without_blank_lines(text: str) -> str:
    return "\n".join(line for line in text.split("\n") if line)


@pytest.mark.parametrize("style", STYLES)
@pytest.mark.parametrize("case", CASES, ids=ids)
def test_layout(case: Case, style: Style) -> None:
    """The expected file, byte for byte; LF line endings, idempotent, the same values."""
    text, options = case.text(), case.options()
    out = haus.format(text, style=style, **options)
    assert out == case.output(style)
    assert haus.format(case.input.read_bytes(), style=style, **options) == out
    assert "\r" not in out
    assert haus.format(out, style=style, **options) == out
    assert same_values(out, text)
    if style != "pretty":
        assert not re.search("[\\u2028\\u2029]", out)  # raw only in comments, which only pretty keeps


@pytest.mark.parametrize("case", CASES, ids=ids)
def test_minimised_has_no_whitespace_between_tokens(case: Case) -> None:
    out = haus.format(case.text(), style="minimised", **case.options())
    assert not re.search(r"[ \t]", re.sub(r'x?"(?:[^"\\]|\\.)*"', "", out))


@pytest.mark.parametrize("case", CASES, ids=ids)
def test_minimised_as_pretty_is_pretty_without_comments(case: Case) -> None:
    text, options = case.text(), case.options()
    back = haus.format(haus.format(text, style="minimised", **options), **options)
    assert back == haus.format(haus.format(text, style="compact", **options), **options)
    assert without_blank_lines(back) == without_blank_lines(without_comments(text, options))


@pytest.mark.parametrize("case", CASES, ids=ids)
def test_pretty_survives_trimming_trailing_whitespace(case: Case) -> None:
    text = case.text()
    out = haus.format(text, **case.options())
    assert trailing_blanks(out) == []
    assert same_values(re.sub(r"[ \t]+$", "", out, flags=re.MULTILINE), text)


# ── options.cases.haus: the pretty layout's indent and width, 0 and negative (spec §11) ──


@dataclass(frozen=True)
class OptionsCase:
    input: str
    options: Options
    result: str | None
    """The pretty text, or None: the formatter must refuse the options."""


def _options_case(v: haus.Value) -> OptionsCase:
    assert isinstance(v, Record), haus.canonical(v)
    f = v.fields
    options = Options()
    for key in ("indent", "width"):
        if isinstance(n := f.get(key), Number):
            options[key] = int(n.text)
    match f.get("input"), f.get("result"):
        case haus.String(text), haus.Variant("Ok", (haus.String(out),)):
            return OptionsCase(text, options, out)
        case haus.String(text), haus.Variant("Rejected", ()):
            return OptionsCase(text, options, None)
        case _:
            raise AssertionError(f"not a case: {haus.canonical(v)}")


OPTIONS = [_options_case(v) for v in haus.parse_all((FORMAT / "options.cases.haus").read_text("utf-8"))]


def test_the_options_suite_has_cases() -> None:
    assert len(OPTIONS) > 0


@pytest.mark.parametrize("case", OPTIONS, ids=[f"{c.input} {dict(c.options)}" for c in OPTIONS])
def test_options(case: OptionsCase) -> None:
    if case.result is None:
        with pytest.raises(ValueError):
            haus.format(case.input, **case.options)
    else:
        assert haus.format(case.input, **case.options) == case.result
