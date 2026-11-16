"""The language-neutral conformance suite (test-suite/README.md)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import haus
from haus import Array, Bytes, Number, Record, String, Value, Variant

SUITE = Path(__file__).resolve().parents[2] / "test-suite"


def cases(kind: str) -> list[Path]:
    files = sorted((SUITE / kind).glob("*.haus"))
    assert files, f"no cases in test-suite/{kind}"
    return files


def self_describing(v: Value) -> object:
    """A value as self-describing JSON (spec §16.2) without the envelope, as data: written here, not by haus."""
    match v:
        case String(s):
            return s
        case Number(text):
            return {"_num": text}
        case Bytes(data):
            return {"_bytes": data.hex()}
        case Array(items):
            return [self_describing(x) for x in items]
        case Record(fields):
            return {"_rec": {k: self_describing(x) for k, x in fields.items()}}
        case Variant(tag, ()):
            return {"_tag": tag}
        case Variant(tag, args):
            return {"_tag": tag, "_args": [self_describing(x) for x in args]}


@pytest.mark.parametrize("path", cases("valid"), ids=lambda p: p.stem)
def test_valid(path: Path) -> None:
    """`NAME.jsonl`: one self-describing JSON envelope per value of the file."""
    lines = path.with_suffix(".jsonl").read_text(encoding="utf-8").splitlines()
    expected = [json.loads(line) for line in lines]
    values = haus.parse_bytes(path.read_bytes())
    assert [{"_haus": 1, "_value": self_describing(v)} for v in values] == expected


def expected_code(path: Path) -> str:
    """`NAME.error`: the error code (spec §17) the file must be rejected with."""
    return path.with_suffix(".error").read_text("utf-8").strip()


@pytest.mark.parametrize("path", cases("invalid"), ids=lambda p: p.stem)
def test_invalid(path: Path) -> None:
    with pytest.raises(haus.HausSyntaxError) as e:
        haus.parse_bytes(path.read_bytes())
    assert e.value.code == expected_code(path), e.value.reason


@pytest.mark.parametrize("path", cases("valid"), ids=lambda p: p.stem)
def test_canonical(path: Path) -> None:
    """`NAME.canonical`: the canonical form (spec §12) of each value, one per line."""
    expected = path.with_suffix(".canonical").read_bytes().decode("utf-8")
    assert "".join(haus.canonical(v) + "\n" for v in haus.parse_bytes(path.read_bytes())) == expected


@pytest.mark.parametrize("path", cases("valid"), ids=lambda p: p.stem)
def test_hash_all(path: Path) -> None:
    """`NAME.hash`: `hash_all` of the file's values (spec §12), also while a stream is read."""
    expected = path.with_suffix(".hash").read_text(encoding="utf-8").strip()
    data = path.read_bytes()
    values = haus.parse_bytes(data)
    assert haus.hash_all(values) == expected
    hasher = haus.Hasher()
    for v in haus.parse_stream(data[i : i + 3] for i in range(0, len(data), 3)):
        hasher.add(v)
    assert hasher.digest() == expected
    if len(values) == 1:
        assert haus.hash(values[0]) == expected
