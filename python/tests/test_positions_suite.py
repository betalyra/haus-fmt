"""The positions suite, test-suite/positions/cases.haus (test-suite/README.md, "Error positions"; spec §8).

Each case's whole text (as `parse_all`) must be rejected with its code at its line and column.
"""

from __future__ import annotations

from pathlib import Path

import pytest

import haus
from haus import Number, Record, String, Value

CASES_FILE = Path(__file__).resolve().parents[2] / "test-suite" / "positions" / "cases.haus"


def case(v: Value) -> tuple[str, str]:
    """`text`, and the error it must be rejected with: `code line:column`."""
    if isinstance(v, Record):
        f = v.fields
        match f.get("text"), f.get("code"), f.get("line"), f.get("column"):
            case String(text), String(code), Number(line), Number(column):
                return text, f"{code} {line}:{column}"
            case _:
                pass
    raise AssertionError(f"not a case: {haus.canonical(v)}")


CASES = [case(v) for v in haus.parse_all(CASES_FILE.read_text("utf-8"))]


def test_the_suite_has_cases() -> None:
    assert len(CASES) > 0


@pytest.mark.parametrize(("text", "want"), CASES, ids=[repr(t) for t, _ in CASES])
def test_position(text: str, want: str) -> None:
    try:
        haus.parse_all(text)
        got = "parsed"
    except haus.HausSyntaxError as e:
        got = f"{e.code} {e.line}:{e.column}"
    assert got == want
