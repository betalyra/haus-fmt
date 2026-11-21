"""The schema conformance suite (test-suite/schema, spec §14, §15; format in test-suite/README.md)."""

from __future__ import annotations

from dataclasses import dataclass
from functools import cache
from pathlib import Path

import pytest

import haus
from haus import Record, String, Value, Variant
from haus.schema import (
    HausDecodeError,
    HausSchemaFileError,
    Schema,
    compile_schema,
    format_path,
    load_schema,
    without_attributes,
)

SUITE = Path(__file__).resolve().parents[2] / "test-suite" / "schema"
SUITES = sorted(p.name.removesuffix(".schema.haus") for p in SUITE.glob("*.schema.haus"))


@dataclass(frozen=True, slots=True)
class Case:
    ok: bool
    type: str
    input: Value
    output: Value
    code: str | None
    """`Err`: the error code (spec §17) decoding must fail with."""
    path: str | None
    """`Err`: the place of the error (spec §15) as text, `$.items[2].price`."""

    @property
    def name(self) -> str:
        return f"{'Ok' if self.ok else 'Err'} {self.type} {haus.canonical(self.input)}"[:120]


def schema_cases(text: str) -> list[Case]:
    """`Ok { type, input, output? }` and `Err { type, input, code, path }`."""
    out: list[Case] = []
    for v in haus.parse_all(text):
        match v:
            case Variant(("Ok" | "Err") as tag, (Record(fields),)) if isinstance(t := fields.get("type"), String):
                value = fields["input"]
                code = fields.get("code")
                code_text = code.value if isinstance(code, String) else None
                path = fields.get("path")
                path_text = path.value if isinstance(path, String) else None
                assert (tag == "Err") == (code_text is not None), f"an Err case has a code: {haus.canonical(v)}"
                assert (tag == "Err") == (path_text is not None), f"an Err case has a path: {haus.canonical(v)}"
                out.append(Case(tag == "Ok", t.value, value, fields.get("output", value), code_text, path_text))
            case _:
                raise ValueError(f"not a case: {haus.canonical(v)}")
    return out


def run(schema: Schema, case: Case) -> None:
    t = schema[case.type]
    if case.ok:
        assert haus.canonical(t.encode(t.decode(case.input))) == haus.canonical(case.output)
    else:
        with pytest.raises(HausDecodeError) as e:
            t.decode(case.input)
        assert e.value.code == case.code, e.value.reason
        assert format_path(e.value.path) == case.path, e.value.reason


CASES = [
    pytest.param(suite, case, id=f"{suite}: {case.name}")
    for suite in SUITES
    for case in schema_cases((SUITE / f"{suite}.cases.haus").read_text("utf-8"))
]


@cache
def compiled(suite: str, *, stripped: bool = False) -> Schema:
    text = (SUITE / f"{suite}.schema.haus").read_text("utf-8")
    return compile_schema(without_attributes(text) if stripped else text)


def test_every_suite_has_cases() -> None:
    assert SUITES
    assert all((SUITE / f"{s}.cases.haus").is_file() for s in SUITES)


@pytest.mark.parametrize(("suite", "case"), CASES)
def test_case(suite: str, case: Case) -> None:
    run(compiled(suite), case)


@pytest.mark.parametrize(("suite", "case"), CASES)
def test_case_without_attributes(suite: str, case: Case) -> None:
    """Attributes don't matter (spec §15): the same result without them."""
    run(compiled(suite, stripped=True), case)


@pytest.mark.parametrize("suite", SUITES)
def test_stripping_removes_every_attribute(suite: str) -> None:
    text = (SUITE / f"{suite}.schema.haus").read_text("utf-8")
    stripped = without_attributes(text)
    assert without_attributes(stripped) == stripped
    assert "@" not in stripped
    assert len(stripped) == len(text)
    if suite == "attributes":
        assert stripped != text
        assert compile_schema(stripped).warnings == ()


# Each invalid schema, with a piece of the reason it must be rejected for.
INVALID = {
    "any-arity": "Any takes no arguments",
    "attribute-bom": "expected a value, found '\ufeff'",
    "attribute-on-spread": "attributes can't be put on a spread",
    "attribute-space": "no space is allowed between @deprecated and '('",
    "attribute-unclosed": "expected ',' or ')' in the attribute's arguments",
    "attribute-version-directive": "expected a value, found '#'",
    "bidi-in-comment": "raw bidirectional control character U+202E in comment",
    "bidi-in-key": "raw bidirectional control character U+2066",
    "closed-empty-variant": "a closed variant needs at least one tag",
    "control-in-comment": "raw control character U+0007",
    "control-in-key": "raw control character U+0007",
    "deprecated-number": "@deprecated takes no argument or one string",
    "deprecated-twice": "@deprecated appears twice",
    "deprecated-two-args": "@deprecated takes no argument or one string",
    "duplicate-field": "field x appears twice",
    "duplicate-import": "Date is imported twice",
    "duplicate-tag-spread": "tag X appears twice (from ...B)",
    "duplicate-type": "type A is defined twice",
    "growing-array": "L passes its parameter a to itself inside a bigger type: instances could grow",
    "growing-mutual-recursion": "A passes its parameter a to B inside a bigger type, and it comes back (A → B → A)",
    "growing-self-recursion": "T passes its parameter a to itself inside a bigger type: instances could grow",
    "growing-swap": "S passes its parameter a to itself inside a bigger type, and it comes back (S → S → S)",
    "growing-three-cycle": "B passes its parameter b to C inside a bigger type, and it comes back (B → C → A → B)",
    "import-empty-version": "expected a major version after '@'",
    "import-full-version": "an import names only the major version (@haus-fmt/money@1)",
    "import-leading-zero": "a major version has no leading zeros (@haus-fmt/money@1)",
    "import-minor": "an import names only the major version (@haus-fmt/money@1)",
    "import-no-names": "expected a type name",
    "import-not-a-version": "expected a major version after '@'",
    "import-package-uppercase": "a package name is @org/name in lowercase",
    "import-space": "expected a module like std/time, @org/name or ./file",
    "import-unknown-type": "std/time has no type Moment",
    "invalid-escape-in-key": "invalid escape '\\x'",
    "invalid-utf8": "is not UTF-8",
    "key-line-break": "line break in string",
    "lone-carriage-return": "carriage return without a line feed",
    "misplaced-stream": "Stream can only be the whole type of a definition",
    "param-underscore": "must start with a lowercase letter",
    "parens-too-deep": "types nested deeper than 128 levels",
    "record-comment-comma": "expected a field name, ...Name or '}', found ','",
    "record-lone-comma": "expected a field name, ...Name or '}', found ','",
    "redefine-any": "Any is a prelude type and can't be redefined",
    "redefine-secret": "Secret is a prelude type and can't be redefined",
    "row-parameter": "row parameters (...r) aren't supported",
    "secret-arity": "Secret needs 1 argument",
    "secret-recursion": "type A refers to itself without a record, array or variant in between",
    "spread-cycle": "spreads itself",
    "spread-cycle-nested": "spreads itself",
    "spread-variant-into-record": "V is not a record, so it can't be spread here",
    "std-type-without-import": "unknown type Date; import it with: import std/time (Date)",
    "stray-quote-in-key": "expected ':', found '\"'",
    "stray-slash": "unexpected '/'",
    "stream-arity": "Stream needs 1 argument",
    "stream-arity-nested": "Stream needs 1 argument",
    "unguarded-recursion": "refers to itself without a record, array or variant in between",
    "unguarded-unused-generic": "type Q refers to itself without a record, array or variant in between",
    "unknown-type": "unknown type Foo",
    "unterminated-comment": "unterminated block comment",
    "unterminated-string": "unterminated string",
    "variant-trailing-bar": "expected a tag or ...Name after '|'",
    "wrong-arity-generic": "P needs 1 argument (P a), got 2",
}


def test_every_invalid_schema_has_a_reason() -> None:
    assert sorted(INVALID) == sorted(p.name.removesuffix(".schema.haus") for p in (SUITE / "invalid").glob("*.haus"))


@pytest.mark.parametrize(("name", "reason"), sorted(INVALID.items()))
def test_invalid_schema(name: str, reason: str) -> None:
    path = SUITE / "invalid" / f"{name}.schema.haus"
    with pytest.raises(HausSchemaFileError) as e:
        try:
            text = path.read_bytes().decode("utf-8")
        except UnicodeDecodeError:
            load_schema(path)  # read as a file is: invalid UTF-8 is invalid-utf8
        else:
            compile_schema(text)
    assert reason in e.value.reason
    assert e.value.code == (SUITE / "invalid" / f"{name}.error").read_text("utf-8").strip()
