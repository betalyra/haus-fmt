"""The stream suite, test-suite/stream/limits.cases.haus (test-suite/README.md, "Stream suite").

Each case is read whole, one character at a time, and split in two at every
position, with the value limit and strict mode of the case (spec §6, §7).
`HAUS_STREAM_SUITE` names another directory holding the suite's file.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import pytest

import haus
from haus import Array, Number, Record, String, Value, Variant

SUITE = Path(os.environ.get("HAUS_STREAM_SUITE", Path(__file__).resolve().parents[2] / "test-suite" / "stream"))


@dataclass(frozen=True, slots=True)
class Case:
    text: str
    max_value_length: int
    strict: bool
    result: tuple[Value, ...] | str
    """The values read, or the code of the error."""


def case(v: Value) -> Case:
    if isinstance(v, Record):
        f = v.fields
        match f.get("text"), f.get("maxValueLength"), f.get("result"):
            case String(text), Number(limit), Variant("Ok", (Array(values),)):
                return Case(text, int(limit), f.get("strict") == Variant("True"), values)
            case String(text), Number(limit), Variant("Err", (String(code),)):
                return Case(text, int(limit), f.get("strict") == Variant("True"), code)
            case _:
                pass
    raise AssertionError(f"not a case: {haus.canonical(v)}")


CASES = [case(v) for v in haus.parse_all((SUITE / "limits.cases.haus").read_text("utf-8"))]


def splits(text: str) -> list[tuple[str, list[str]]]:
    """Whole, one character at a time, and in two pieces split at every position."""
    return [
        ("whole", [text]),
        ("by character", list(text)),
        *((f"split at {k}", [text[:k], text[k:]]) for k in range(len(text))),
    ]


def read(c: Case, chunks: list[str]) -> tuple[Value, ...] | str:
    reader = haus.StreamReader(max_value_length=c.max_value_length, require_terminator=c.strict)
    values: list[Value] = []
    try:
        for chunk in chunks:
            values += reader.push(chunk)
        values += reader.finish()
    except haus.HausSyntaxError as e:
        return e.code
    return tuple(values)


def same(got: tuple[Value, ...] | str, want: tuple[Value, ...] | str) -> bool:
    if isinstance(got, str) or isinstance(want, str):
        return got == want
    return len(got) == len(want) and all(haus.equals(a, b) for a, b in zip(got, want, strict=True))


def test_the_suite_has_all_its_cases() -> None:
    assert len(CASES) == 24


@pytest.mark.parametrize(
    "c", CASES, ids=lambda c: f"{c.text!r} max {c.max_value_length}{' strict' if c.strict else ''}"
)
def test_stream_case(c: Case) -> None:
    failures = [f"{how}: {got!r}" for how, chunks in splits(c.text) if not same(got := read(c, chunks), c.result)]
    assert failures == []
