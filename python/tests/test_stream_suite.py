"""The stream suite, test-suite/stream (test-suite/README.md, "Stream suite").

Each case of limits.cases.haus is read whole, one character at a time, and split
in two at every position, with the value limit and strict mode of the case (spec
§6, §7); a case with `whole` also parses whole. document.cases.haus checks single
documents (`parse`), typed.cases.haus streams decoded with a type (spec §15).
`HAUS_STREAM_SUITE` names another directory holding the suite's files.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import pytest

import haus
from haus import Array, Number, Record, String, Value, Variant
from haus.schema import HausDecodeError, compile_schema, format_path

SUITE = Path(os.environ.get("HAUS_STREAM_SUITE", Path(__file__).resolve().parents[2] / "test-suite" / "stream"))


@dataclass(frozen=True, slots=True)
class Case:
    text: str
    max_value_length: int
    strict: bool
    result: tuple[Value, ...] | str
    """The values read, or the code of the error, with its place (`code at line:column`) where the case gives one."""


def case(v: Value) -> Case:
    if isinstance(v, Record):
        f = v.fields
        # `line` and `column`, both or neither: where the error is, for every split.
        match f.get("line"), f.get("column"):
            case Number(line), Number(column):
                at = f" at {line}:{column}"
            case None, None:
                at = ""
            case _:
                raise AssertionError(f"line without column: {haus.canonical(v)}")
        match f.get("text"), f.get("maxValueLength"), f.get("result"):
            case String(text), Number(limit), Variant("Ok", (Array(values),)) if not at:
                return Case(text, int(limit), f.get("strict") == Variant("True"), values)
            case String(text), Number(limit), Variant("Err", (String(code),)):
                return Case(text, int(limit), f.get("strict") == Variant("True"), code + at)
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


def placed(c: Case) -> bool:
    """Whether the case gives where its error is."""
    return isinstance(c.result, str) and " at " in c.result


def read(c: Case, chunks: list[str]) -> tuple[Value, ...] | str:
    """The values read, or the error's code (with its place if the case gives one)."""
    reader = haus.StreamReader(max_value_length=c.max_value_length, require_terminator=c.strict)
    values: list[Value] = []
    try:
        for chunk in chunks:
            values += reader.push(chunk)
        values += reader.finish()
    except haus.HausSyntaxError as e:
        return f"{e.code} at {e.line}:{e.column}" if placed(c) else e.code
    return tuple(values)


def same(got: tuple[Value, ...] | str, want: tuple[Value, ...] | str) -> bool:
    if isinstance(got, str) or isinstance(want, str):
        return got == want
    return len(got) == len(want) and all(haus.equals(a, b) for a, b in zip(got, want, strict=True))


def test_the_suite_has_all_its_cases() -> None:
    assert len(CASES) == 32


def test_the_suite_has_cases_with_a_place() -> None:
    assert any(placed(c) for c in CASES)


@pytest.mark.parametrize(
    "c", CASES, ids=lambda c: f"{c.text!r} max {c.max_value_length}{' strict' if c.strict else ''}"
)
def test_stream_case(c: Case) -> None:
    failures = [f"{how}: {got!r}" for how, chunks in splits(c.text) if not same(got := read(c, chunks), c.result)]
    assert failures == []


# ── whole: parsing the whole text doesn't apply the value limit (spec §7) ──


def whole(v: Value) -> tuple[str, tuple[Value, ...]] | None:
    """`text` and the values of `whole: Ok([values])`, for a case that has one."""
    if not isinstance(v, Record) or "whole" not in v.fields:
        return None
    match v.fields.get("text"), v.fields["whole"]:
        case String(text), Variant("Ok", (Array(values),)):
            return text, values
        case _:
            raise AssertionError(f"not a case: {haus.canonical(v)}")


WHOLES = [w for v in haus.parse_all((SUITE / "limits.cases.haus").read_text("utf-8")) if (w := whole(v)) is not None]


def test_the_suite_has_whole_cases() -> None:
    assert len(WHOLES) > 0


@pytest.mark.parametrize(("text", "values"), WHOLES, ids=[repr(t) for t, _ in WHOLES])
def test_whole(text: str, values: tuple[Value, ...]) -> None:
    assert [haus.canonical(v) for v in haus.parse_all(text)] == [haus.canonical(v) for v in values]


# ── single documents (spec §6) ──


def document(v: Value) -> tuple[str, str]:
    """`text`, and the result as `Ok <canonical>` or `Err <code>`."""
    if isinstance(v, Record):
        match v.fields.get("text"), v.fields.get("result"):
            case String(text), Variant("Ok", (value,)):
                return text, f"Ok {haus.canonical(value)}"
            case String(text), Variant("Err", (String(code),)):
                return text, f"Err {code}"
            case _:
                pass
    raise AssertionError(f"not a case: {haus.canonical(v)}")


DOCUMENTS = [document(v) for v in haus.parse_all((SUITE / "document.cases.haus").read_text("utf-8"))]


def test_the_suite_has_documents() -> None:
    assert len(DOCUMENTS) > 0


@pytest.mark.parametrize(("text", "want"), DOCUMENTS, ids=[repr(t) for t, _ in DOCUMENTS])
def test_document(text: str, want: str) -> None:
    try:
        got = f"Ok {haus.canonical(haus.parse(text))}"
    except haus.HausSyntaxError as e:
        got = f"Err {e.code}"
    assert got == want


# ── streams decoded with a type (spec §15, "Streams") ──


def typed(v: Value) -> tuple[str, str, str]:
    """`type`, `text`, and the result as `Ok <canonical output>` or `Err <code> <path>`."""
    match v:
        case Variant("Ok", (Record(f),)):
            match f.get("type"), f.get("text"), f.get("output"):
                case String(t), String(text), output if output is not None:
                    return t, text, f"Ok {haus.canonical(output)}"
                case _:
                    pass
        case Variant("Err", (Record(f),)):
            match f.get("type"), f.get("text"), f.get("code"), f.get("path"):
                case String(t), String(text), String(code), String(path):
                    return t, text, f"Err {code} {path}"
                case _:
                    pass
        case _:
            pass
    raise AssertionError(f"not a case: {haus.canonical(v)}")


TYPED_SCHEMA = compile_schema((SUITE / "typed.schema.haus").read_text("utf-8"))
TYPED = [typed(v) for v in haus.parse_all((SUITE / "typed.cases.haus").read_text("utf-8"))]


def test_the_suite_has_typed_cases() -> None:
    assert len(TYPED) > 0


@pytest.mark.parametrize(("type_", "text", "want"), TYPED, ids=[f"{t} {x!r}" for t, x, _ in TYPED])
def test_typed(type_: str, text: str, want: str) -> None:
    t = TYPED_SCHEMA[type_]
    try:
        if t.stream:
            # The binding's stream decoding gives the item's index in the path.
            got = f"Ok {haus.canonical(Array(tuple(t.encode(x) for x in t.parse_stream([text]))))}"
        else:
            got = f"Ok {haus.canonical(t.encode(t.parse(text)))}"
    except HausDecodeError as e:
        got = f"Err {e.code} {format_path(e.path)}"
    except haus.HausSyntaxError as e:
        got = f"Err {e.code} -"
    assert got == want
