"""The JSON conformance suite (test-suite/json, spec §16; format in test-suite/README.md).

Every valid/NAME.jsonl of the parser suite is a self-describing case too: JSON Lines, one
envelope per value of the file.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import cache
from pathlib import Path

import pytest

import haus
from haus import Record, String, Value, Variant
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
    code: str | None = None
    """`Err`: the error code (spec §17) reading must fail with."""

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
                code = fields.get("code")
                assert (kind == "Err") == isinstance(code, String), f"an Err case has a code: {haus.canonical(v)}"
                out.append(
                    Case(
                        kind,
                        j.value,
                        t.value if isinstance(t, String) else None,
                        input_,
                        fields.get("output", input_),
                        code.value if isinstance(code, String) else None,
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


# ── schema-based (§16.3) ─────────────────────────────────────


@cache
def schema_based() -> Schema:
    return compile_schema((JSON_SUITE / "schema-based.schema.haus").read_text("utf-8"))


@pytest.mark.parametrize("case", load("schema-based.cases.haus"), ids=lambda c: c.name)
def test_schema_based(case: Case) -> None:
    assert case.type is not None
    t = schema_based()[case.type]
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
            with pytest.raises((HausDecodeError, HausJsonError)) as e:
                t.from_json(case.json)
            assert e.value.code == case.code, e.value.reason


# ── self-describing (§16.2) ──────────────────────────────────


@pytest.mark.parametrize("case", load("self-describing.cases.haus"), ids=lambda c: c.name)
def test_self_describing(case: Case) -> None:
    if case.kind == "Ok":
        assert case.input is not None
        assert data(haus.to_haus_json(case.input)) == data(case.json)
        assert haus.equals(haus.from_haus_json(case.json), case.input)
    else:
        with pytest.raises(HausJsonError) as e:
            haus.from_haus_json(case.json)
        assert e.value.code == case.code, e.value.reason


VALID = sorted((SUITE / "valid").glob("*.haus"))


@pytest.mark.parametrize("path", VALID, ids=lambda p: p.stem)
def test_self_describing_valid(path: Path) -> None:
    """`valid/NAME.jsonl` is the self-describing JSON of the file's values, one envelope per line."""
    expected = path.with_suffix(".jsonl").read_bytes()
    values = haus.parse_bytes(path.read_bytes())
    lines = expected.splitlines()
    assert len(lines) == len(values)
    for line, value in zip(lines, values, strict=True):
        assert data(haus.to_haus_json(value)) == data(line)
        assert haus.equals(haus.from_haus_json(line), value)
    written = "".join(haus.to_haus_json_lines(values))
    assert [data(line) for line in written.splitlines()] == [data(line) for line in lines]
    read = list(haus.from_haus_json_lines(expected))
    assert len(read) == len(values)
    assert all(map(haus.equals, read, values))


def test_every_valid_file_has_json_lines() -> None:
    assert VALID
    assert all(p.with_suffix(".jsonl").is_file() for p in VALID)


# ── the JSON import (§16.1) ──────────────────────────────────


@pytest.mark.parametrize("case", load("import.cases.haus"), ids=lambda c: c.name)
def test_import(case: Case) -> None:
    if case.kind == "Read":
        assert case.output is not None
        assert haus.equals(haus.import_json(case.json), case.output)
    else:
        with pytest.raises(HausJsonError) as e:
            haus.import_json(case.json)
        assert e.value.code == case.code, e.value.reason
