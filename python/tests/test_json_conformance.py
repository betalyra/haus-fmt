"""The JSON conformance suite (test-suite/json, spec §16; format in test-suite/README.md).

Every valid/NAME.json of the parser suite is a lossless case too: the JSON array of the file's values.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import cache
from pathlib import Path

import pytest

import haus
from haus import Array, Record, String, Value, Variant
from haus.schema import HausDecodeError, HausJsonError, Schema, compile_schema

SUITE = Path(__file__).resolve().parents[2] / "test-suite"
JSON_SUITE = SUITE / "json"


@dataclass(frozen=True, slots=True)
class Case:
    kind: str
    """`Ok`, `Read` or `Err`."""
    json: str
    type: str | None = None
    input: Value | None = None
    output: Value | None = None

    @property
    def name(self) -> str:
        return f"{self.kind} {self.type or ''} {self.json}"[:120]


def load(name: str) -> list[Case]:
    """The cases of `json/NAME.cases.haus`: `Ok { type?, input, json, output? }`, `Read { … }`, `Err { … }`."""
    out: list[Case] = []
    for v in haus.parse_all((JSON_SUITE / name).read_text("utf-8")):
        match v:
            case Variant(("Ok" | "Read" | "Err") as kind, (Record(fields),)) if isinstance(j := fields["json"], String):
                t = fields.get("type")
                input_ = fields.get("input")
                out.append(
                    Case(
                        kind,
                        j.value,
                        t.value if isinstance(t, String) else None,
                        input_,
                        fields.get("output", input_),
                    )
                )
            case _:
                raise ValueError(f"not a case: {haus.canonical(v)}")
    assert out, f"no cases in {name}"
    return out


def data(text: str | bytes) -> object:
    """JSON as data, to compare: member order and whitespace don't matter, numbers compare by their text."""

    def number(s: str) -> tuple[str, str]:
        return ("number", s)

    def constant(s: str) -> object:
        raise ValueError(f"not JSON: {s}")

    return json.loads(text, parse_int=number, parse_float=number, parse_constant=constant)


def canonical(v: Value | None) -> str:
    assert v is not None
    return haus.canonical(v)


# ── plain (§16.3) ────────────────────────────────────────────


@cache
def plain_schema() -> Schema:
    return compile_schema((JSON_SUITE / "plain.schema.haus").read_text("utf-8"))


@pytest.mark.parametrize("case", load("plain.cases.haus"), ids=lambda c: c.name)
def test_plain(case: Case) -> None:
    assert case.type is not None
    t = plain_schema()[case.type]
    match case.kind:
        case "Ok":
            assert case.input is not None
            written = t.to_json(t.decode(case.input))
            assert data(written) == data(case.json)
            read = t.from_json(case.json)
            assert canonical(t.encode(read)) == canonical(case.output)
            assert data(t.to_json(read)) == data(case.json)  # round trip (§16.3)
        case "Read":
            assert canonical(t.encode(t.from_json(case.json))) == canonical(case.output)
        case _:
            with pytest.raises((HausDecodeError, HausJsonError)):
                t.from_json(case.json)


# ── lossless (§16.2) ─────────────────────────────────────────


@pytest.mark.parametrize("case", load("lossless.cases.haus"), ids=lambda c: c.name)
def test_lossless(case: Case) -> None:
    if case.kind == "Ok":
        assert case.input is not None
        assert data(haus.to_lossless_json(case.input)) == data(case.json)
        assert haus.equals(haus.from_lossless_json(case.json), case.input)
    else:
        with pytest.raises(HausJsonError):
            haus.from_lossless_json(case.json)


VALID = sorted((SUITE / "valid").glob("*.haus"))


@pytest.mark.parametrize("path", VALID, ids=lambda p: p.stem)
def test_lossless_valid(path: Path) -> None:
    """`valid/NAME.json` is the lossless form of the file's values, in a JSON array."""
    expected = path.with_suffix(".json").read_bytes()
    values = haus.parse_bytes(path.read_bytes())
    file = Array(tuple(values))
    assert data(haus.to_lossless_json(file)) == data(expected)
    assert haus.equals(haus.from_lossless_json(expected), file)
    # As JSON Lines: one value per line.
    lines = "".join(haus.to_lossless_json_lines(values))
    assert lines.count("\n") == len(values)
    read = list(haus.from_lossless_json_lines(lines))
    assert len(read) == len(values)
    assert all(map(haus.equals, read, values))


def test_every_valid_file_has_json() -> None:
    assert VALID
    assert all(p.with_suffix(".json").is_file() for p in VALID)


# ── without a schema (§16.1) ─────────────────────────────────


@pytest.mark.parametrize("case", load("schemaless.cases.haus"), ids=lambda c: c.name)
def test_schemaless(case: Case) -> None:
    if case.kind == "Read":
        assert case.output is not None
        assert haus.equals(haus.from_json(case.json), case.output)
    else:
        with pytest.raises(HausJsonError):
            haus.from_json(case.json)
