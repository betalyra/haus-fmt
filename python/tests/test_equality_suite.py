"""The equality suite, test-suite/equality/cases.haus (test-suite/README.md, "Equality and order"; spec §2, §12).

`equals` and `compare`, both ways: `equals(b, a)` is `equal` too, and `compare(b, a)` has the opposite sign.
"""

from __future__ import annotations

from pathlib import Path

import pytest

import haus
from haus import Number, Record, Value, Variant

CASES_FILE = Path(__file__).resolve().parents[2] / "test-suite" / "equality" / "cases.haus"


def case(v: Value) -> tuple[Value, Value, bool, int]:
    """`a`, `b`, `equal` and `order`."""
    if isinstance(v, Record):
        f = v.fields
        match f.get("a"), f.get("b"), f.get("equal"), f.get("order"):
            case a, b, Variant(("True" | "False") as equal, ()), Number(order) if a is not None and b is not None:
                return a, b, equal == "True", int(order)
            case _:
                pass
    raise AssertionError(f"not a case: {haus.canonical(v)}")


CASES = [case(v) for v in haus.parse_all(CASES_FILE.read_text("utf-8"))]


def sign(n: int) -> int:
    return (n > 0) - (n < 0)


def test_the_suite_has_cases() -> None:
    assert len(CASES) > 0


@pytest.mark.parametrize(
    ("a", "b", "equal", "order"), CASES, ids=[f"{haus.canonical(a)} {haus.canonical(b)}" for a, b, _, _ in CASES]
)
def test_equality(a: Value, b: Value, equal: bool, order: int) -> None:
    got = [haus.equals(a, b), haus.equals(b, a), sign(haus.compare(a, b)), sign(haus.compare(b, a))]
    assert got == [equal, equal, order, -order]
