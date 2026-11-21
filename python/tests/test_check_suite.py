"""The checker suite, test-suite/check/cases.haus (test-suite/README.md, "Checker suite"; spec §14, §15, §16).

`Schema { schema, warnings }`: the schema loads, and its warnings, in the order of their places, are
exactly `warnings`, each `Warning(code, line, column)`.

`Data { schema, type, data, issues }` cases are not run: the Python binding has no data checker
(decoding stops at the first error and reports no hints, so there is nothing to compare the
`Hint(code, path)` and `Error(code, path)` lists with).
"""

from __future__ import annotations

from pathlib import Path

import pytest

import haus
from haus import Array, Number, Record, String, Value, Variant
from haus.schema import compile_schema

CASES_FILE = Path(__file__).resolve().parents[2] / "test-suite" / "check" / "cases.haus"
ALL = haus.parse_all(CASES_FILE.read_text("utf-8"))


def warning(v: Value) -> tuple[str, int, int]:
    match v:
        case Variant("Warning", (String(code), Number(line), Number(column))):
            return code, int(line), int(column)
        case _:
            raise AssertionError(f"not a warning: {haus.canonical(v)}")


def schema_case(v: Value) -> tuple[str, list[tuple[str, int, int]]] | None:
    """`schema` and its `warnings`, for a `Schema` case; None for a `Data` case."""
    match v:
        case Variant("Schema", (Record(f),)):
            match f.get("schema"), f.get("warnings"):
                case String(schema), Array(warnings):
                    return schema, [warning(w) for w in warnings]
                case _:
                    pass
        case Variant("Data", (Record(),)):
            return None
        case _:
            pass
    raise AssertionError(f"not a case: {haus.canonical(v)}")


SCHEMA_CASES = [c for v in ALL if (c := schema_case(v)) is not None]


def test_the_suite_has_cases() -> None:
    assert len(ALL) > 0
    assert len(SCHEMA_CASES) > 0


@pytest.mark.parametrize(("schema", "want"), SCHEMA_CASES, ids=[repr(s) for s, _ in SCHEMA_CASES])
def test_schema_warnings(schema: str, want: list[tuple[str, int, int]]) -> None:
    warnings = sorted(compile_schema(schema).warnings, key=lambda w: w.offset)
    assert [(w.code, w.line, w.column) for w in warnings] == want
