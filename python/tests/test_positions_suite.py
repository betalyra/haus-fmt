"""The positions suite, test-suite/positions/cases.haus (test-suite/README.md, "Error positions"; spec §8).

Each case's whole text (as `parse_all`, or as `parse` for a case with `document: True`) must be
rejected with its code at its line and column.
"""

from __future__ import annotations

from pathlib import Path

import pytest

import haus
from haus import Number, Record, String, Value, Variant

CASES_FILE = Path(__file__).resolve().parents[2] / "test-suite" / "positions" / "cases.haus"


def case(v: Value) -> tuple[str, bool, str]:
    """`text`, whether it is read as a single document, and the error it must be rejected with: `code line:column`."""
    if isinstance(v, Record):
        f = v.fields
        match f.get("text"), f.get("document", Variant("False")), f.get("code"), f.get("line"), f.get("column"):
            case String(text), Variant("True" | "False" as document), String(code), Number(line), Number(column):
                return text, document == "True", f"{code} {line}:{column}"
            case _:
                pass
    raise AssertionError(f"not a case: {haus.canonical(v)}")


CASES = [case(v) for v in haus.parse_all(CASES_FILE.read_text("utf-8"))]


def test_the_suite_has_cases() -> None:
    assert len(CASES) > 0


@pytest.mark.parametrize(("text", "document", "want"), CASES, ids=[repr(t) for t, _, _ in CASES])
def test_position(text: str, document: bool, want: str) -> None:
    try:
        if document:
            haus.parse(text)
        else:
            haus.parse_all(text)
        got = "parsed"
    except haus.HausSyntaxError as e:
        got = f"{e.code} {e.line}:{e.column}"
    assert got == want


@pytest.mark.parametrize(
    ("text", "line", "column"),
    [('"""', 1, 4), ('"""x', 1, 4), ('"""  x', 1, 6), ('["""', 1, 5), ('"""  ', 1, 6), ('"""\r', 1, 4)],
)
def test_block_string_opening_is_after_the_quotes(text: str, line: int, column: int) -> None:
    """At the first character after the opening quotes and their blanks, or the end of the input (spec §8)."""
    with pytest.raises(haus.HausSyntaxError) as e:
        haus.parse_all(text)
    assert (e.value.code, e.value.line, e.value.column) == ("block-string-opening", line, column)
