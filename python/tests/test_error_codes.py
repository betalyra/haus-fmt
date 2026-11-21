"""The error codes (spec §17): the table in `haus._error_codes` is the catalogue
spec/errors.haus, read here with haus itself; every error has a code and its JSON form.

The table is generated from the catalogue. After editing spec/errors.haus, run in python/:

    uv run python tests/test_error_codes.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

import haus
from haus import ERROR_CODES, Array, Record, String, Variant
from haus.schema import HausDecodeError, HausEncodeError, HausSchemaFileError, compile_schema, parse_schema_file

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "python" / "src" / "haus" / "_error_codes.py"
CATEGORIES = {
    "Syntax": "syntax",
    "Limits": "limits",
    "Streams": "streams",
    "SchemaFiles": "schema-files",
    "Imports": "imports",
    "Decoding": "decoding",
    "Json": "json",
    "Hints": "hints",
}


def catalogue() -> list[tuple[str, str, str]]:
    """`(code, category, fix)` of each entry of spec/errors.haus, in order."""
    out: list[tuple[str, str, str]] = []
    for v in haus.parse_all((ROOT / "spec" / "errors.haus").read_text("utf-8")):
        match v:
            case Variant(
                "Code",
                (Record({"code": String(code), "category": Variant(category, ()), "fix": String(fix)}),),
            ):
                out.append((code, CATEGORIES[category], fix))
            case _:
                raise ValueError(f"not a catalogue entry: {haus.canonical(v)}")
    return out


def render(entries: list[tuple[str, str, str]]) -> str:
    """The source of `haus/_error_codes.py` (before `ruff format`)."""
    q = json.dumps
    return "\n".join(
        [
            "# Generated from spec/errors.haus by python/tests/test_error_codes.py. Don't edit:",
            "# edit spec/errors.haus and run `uv run python tests/test_error_codes.py` in python/.",
            "# The fixes are the catalogue's text, kept on one line each.",
            "# ruff: noqa: E501",
            '"""Every error code of spec §17, with its category and the fix reported as the hint."""',
            "",
            "from __future__ import annotations",
            "",
            "from collections.abc import Mapping",
            "from types import MappingProxyType",
            "from typing import Final, Literal, NamedTuple, TypeAlias",
            "",
            "ErrorCategory: TypeAlias = Literal[" + ", ".join(q(c) for c in CATEGORIES.values()) + "]",
            '"""The category of an error code."""',
            "",
            "ErrorCode: TypeAlias = Literal[",
            *(f"    {q(code)}," for code, _, _ in entries),
            "]",
            '"""An error code (spec §17): stable, the same in every binding."""',
            "",
            "",
            "class ErrorInfo(NamedTuple):",
            '    """What the catalogue says about a code."""',
            "",
            "    category: ErrorCategory",
            "    hint: str",
            '    """The usual fix, reported as the hint of an error that knows no better one."""',
            "",
            "",
            "ERROR_CODES: Final[Mapping[ErrorCode, ErrorInfo]] = MappingProxyType(",
            "    {",
            *(
                f"        {q(code)}: ErrorInfo({q(category)}, {q(fix, ensure_ascii=False)}),"
                for code, category, fix in entries
            ),
            "    }",
            ")",
            '"""Every error code (spec §17), in the order of the catalogue."""',
            "",
        ]
    )


def write_table() -> None:
    TABLE.write_text(render(catalogue()), "utf-8")
    subprocess.run([sys.executable, "-m", "ruff", "format", "--quiet", str(TABLE)], check=True)


# ── the table is the catalogue ───────────────────────────────


def test_the_table_is_the_catalogue() -> None:
    """If this fails, run `uv run python tests/test_error_codes.py` to generate the table again."""
    assert [(code, info.category, info.hint) for code, info in ERROR_CODES.items()] == catalogue()


def test_codes_are_kebab_case_and_unique() -> None:
    codes = [code for code, _, _ in catalogue()]
    assert len(set(codes)) == len(codes) > 90
    assert all(haus.is_error_code(c) for c in codes)
    assert not haus.is_error_code("not-a-code")


def suite_codes() -> set[str]:
    suite = ROOT / "test-suite"
    codes = {p.read_text("utf-8").strip() for d in ("invalid", "schema/invalid") for p in (suite / d).glob("*.error")}
    for path in [*(suite / "schema").glob("*.cases.haus"), *(suite / "json").glob("*.cases.haus")]:
        for v in haus.parse_all(path.read_text("utf-8")):
            match v:
                case Variant("Err", (Record({"code": String(code)}),)):
                    codes.add(code)
                case _:
                    pass
    return codes


def test_the_suite_uses_catalogued_codes() -> None:
    codes = suite_codes()
    assert len(codes) > 40
    assert all(haus.is_error_code(c) for c in codes), sorted(c for c in codes if not haus.is_error_code(c))


# ── the JSON form ────────────────────────────────────────────


def test_a_syntax_error_as_json() -> None:
    with pytest.raises(haus.HausSyntaxError) as info:
        haus.parse_all("Heartbeat\n{ at: 1 }")
    e = info.value
    assert (e.code, e.expected, e.found) == ("payload-newline", "','", "'{'")
    assert e.docs == "https://haus-fmt.org/docs/errors#payload-newline"
    assert e.to_json() == {
        "code": "payload-newline",
        "message": "expected ',' between top-level values, found '{'",
        "line": 2,
        "column": 1,
        "expected": "','",
        "found": "'{'",
        "hint": "Put the payload on the same line as Heartbeat, or add a comma if they are two values.",
        "docs": "https://haus-fmt.org/docs/errors#payload-newline",
    }
    assert isinstance(e, haus.HausError)
    assert isinstance(e, ValueError)


def test_a_decoding_error_as_json_has_the_path_and_the_catalogue_fix() -> None:
    schema = compile_schema("type Order = { items: Array { price: Int } }")
    with pytest.raises(HausDecodeError) as info:
        schema["Order"].parse("{ items: [{ price: 1 }, { price: 1.5 }] }")
    assert info.value.to_json() == {
        "code": "not-an-integer",
        "message": "expected Int, found number 1.5",
        "path": "$.items[1].price",
        "expected": "Int",
        "found": "number 1.5",
        "hint": ERROR_CODES["not-an-integer"].hint,
        "docs": "https://haus-fmt.org/docs/errors#not-an-integer",
    }


SHAPES = compile_schema(
    "type Shape = < Circle { r: Float64 } | Point Float64 Float64 | Empty >\n"
    "type Holder = { shape: Shape, flag: Bool, n: Maybe Int }"
)


@pytest.mark.parametrize(
    ("data", "path", "hint"),
    [
        # A record case takes one record: `Circle(1.5)` is the wrong payload, at the variant (spec §15).
        (
            "{ shape: Circle(1.5), flag: True, n: None }",
            "$.shape",
            "Circle takes one argument, a record { r: Float64 }: write `Circle { … }`.",
        ),
        (
            '{ shape: Circle("r"), flag: True, n: None }',
            "$.shape",
            "Circle takes one argument, a record { r: Float64 }: write `Circle { … }`.",
        ),
        (
            "{ shape: Circle, flag: True, n: None }",
            "$.shape",
            "Circle takes one argument, a record { r: Float64 }: write `Circle { … }`.",
        ),
        (
            "{ shape: Point(1), flag: True, n: None }",
            "$.shape",
            "Point takes 2 arguments (Float64, Float64): write `Point(…, …)`.",
        ),
        ("{ shape: Empty(1), flag: True, n: None }", "$.shape", "Empty takes no payload: write `Empty`."),
        ("{ shape: Empty, flag: True(1), n: None }", "$.flag", "True takes no payload: write `True`."),
        ("{ shape: Empty, flag: True, n: Some }", "$.n", "Some takes 1 argument (Int): write `Some(…)`."),
    ],
)
def test_a_wrong_payload_names_the_case(data: str, path: str, hint: str) -> None:
    with pytest.raises(HausDecodeError) as info:
        SHAPES["Holder"].parse(data)
    e = info.value.to_json()
    assert (e["code"], e["path"], e["hint"]) == ("wrong-payload", path, hint)


def test_json_has_only_the_members_that_apply() -> None:
    with pytest.raises(haus.HausJsonError) as info:
        haus.from_haus_json('{"_haus": 1, "_value": {"_num": "01"}}')
    assert info.value.to_json() == {
        "code": "haus-json-number",
        "message": info.value.reason,
        "path": "$._value._num",
        "hint": ERROR_CODES["haus-json-number"].hint,
        "docs": "https://haus-fmt.org/docs/errors#haus-json-number",
    }
    with pytest.raises(haus.HausJsonError) as info:
        haus.import_json("[1,]")
    assert {k: v for k, v in info.value.to_json().items() if k in ("code", "line", "column")} == {
        "code": "json-syntax",
        "line": 1,
        "column": 4,
    }


def test_an_encoding_error_has_a_code() -> None:
    schema = compile_schema("type U = { n: UInt8 }")
    with pytest.raises(HausEncodeError) as info:
        schema["U"].encode({"n": 300})
    assert (info.value.code, info.value.to_json()["path"]) == ("cannot-encode", "$.n")


def test_a_bad_tag_in_an_any_is_invalid_tag() -> None:
    # As in `to_haus` and spec/errors.haus: a tag that isn't [A-Z][A-Za-z0-9_]* in a value built in code.
    schema = compile_schema("type U = { v: Any }")
    for encode in (schema["U"].encode, schema["U"].canonical, schema["U"].to_json):
        with pytest.raises(HausEncodeError) as info:
            encode({"v": Array((Variant("lower"),))})
        assert (info.value.code, info.value.to_json()["path"]) == ("invalid-tag", "$.v[0]")


def test_a_secret_shows_nothing_of_the_value() -> None:
    schema = compile_schema("type Config = { key: Secret Int }")
    with pytest.raises(HausDecodeError) as info:
        schema["Config"].parse('{ key: "sk-12345" }')
    assert info.value.code == "invalid-secret"
    assert "sk-12345" not in json.dumps(info.value.to_json())


def test_schema_file_errors_and_warnings_have_codes() -> None:
    with pytest.raises(HausSchemaFileError) as info:
        parse_schema_file("type A = { at: Date }")
    assert info.value.to_json() | {"message": ""} == {
        "code": "unknown-type",
        "message": "",
        "line": 1,
        "column": 16,
        "hint": "Import it with: import std/time (Date).",
        "docs": "https://haus-fmt.org/docs/errors#unknown-type",
    }
    [warning] = parse_schema_file("@since(2) type A = Int").warnings
    assert (warning.code, warning.to_json()["code"], warning.docs) == (
        "unknown-attribute",
        "unknown-attribute",
        "https://haus-fmt.org/docs/errors#unknown-attribute",
    )


def test_limits_that_cant_be_used_have_a_code() -> None:
    with pytest.raises(haus.HausLimitsError) as info:
        haus.Limits(max_depth=100_000)
    assert info.value.code == "unsupported-depth"
    assert "line" not in info.value.to_json()


def test_codes_of_the_catalogue_examples() -> None:
    """A few examples of spec/errors.haus, one per kind of error."""
    cases = {
        "version-directive": "#haus 2\n{ a: 1 }",
        "null-literal": "{ a: null }",
        "boolean-literal": "[true]",
        "bare-identifier": "{ a: yes }",
        "invalid-number": "+1",
        "unexpected-closer": "[1}",
        "missing-comma": "[1 2]",
        "lone-carriage-return": "/* a\rb */ 1",
        "invalid-unicode-escape": '"\\u0041"',
        "number-too-long": "1" * 1001,
        "exponent-too-large": "1e6145",
        "not-one-value": "",
    }
    for code, text in cases.items():
        with pytest.raises(haus.HausSyntaxError) as info:
            haus.parse(text)
        assert info.value.code == code, text


def code_of(text: str, limits: haus.Limits = haus.DEFAULT_LIMITS) -> str:
    with pytest.raises(haus.HausSyntaxError) as info:
        haus.parse_all(text, limits=limits)
    return info.value.code


def test_number_checks_in_the_reference_order() -> None:
    """The literal, then what follows it, then its length, then its exponent."""
    short = haus.Limits(max_number_length=4, max_exponent=10)
    assert code_of("12345x", short) == "invalid-number"
    assert code_of("1.", short) == "invalid-number"
    assert code_of("1e999", short) == "number-too-long"
    assert code_of("1e11", short) == "exponent-too-large"
    assert code_of("0x" + "f" * 5, short) == "number-too-long"


def test_what_follows_a_value_decides_the_code() -> None:
    assert code_of("Point\n(1, 2)") == "payload-newline"
    assert code_of("[Tag /* c */ { a: 1 }]") == "payload-newline"
    assert code_of("[Tag(1)\n(2)]") == "missing-comma"
    assert code_of("{ a: 1 ]") == "unexpected-closer"
    assert code_of("1 )") == "unexpected-closer"
    assert code_of("{ a: 1 b: 2 }") == "missing-comma"
    assert code_of("[1, 2") == "unclosed-bracket"
    assert code_of(".5") == "invalid-number"
    assert code_of("[,]") == "expected-value"


def test_stream_codes() -> None:
    def code(text: str, reader: haus.StreamReader | None = None) -> str:
        reader = reader or haus.StreamReader()
        with pytest.raises(haus.HausSyntaxError) as info:
            reader.push(text)
            reader.finish()
        return info.value.code

    assert code("1,,") == "expected-value"
    assert code("1, ]") == "expected-value"
    assert code("1 ]") == "unexpected-closer"
    assert code("1, 2", haus.StreamReader(require_terminator=True)) == "stream-truncated"
    assert code("[1, 2, 3]", haus.StreamReader(max_value_length=4)) == "value-too-long"
    assert code("#haus 2\n1,") == "version-directive"
    assert code("1,#haus 2") == "expected-value"  # a directive only starts the input
    assert code("1,\ufeff2") == "expected-value"
    with pytest.raises(haus.HausSyntaxError) as info:
        list(haus.parse_stream([b'"\xff"']))
    assert info.value.code == "invalid-utf8"


def test_decoding_codes() -> None:
    schema = compile_schema(
        """
        import std/time (Date)
        type Level = closed < Low | High >
        type T = { b: Bool, m: Maybe Int, l: Level, d: Date, n: Int8 }
        """
    )

    def code(text: str) -> str:
        with pytest.raises(HausDecodeError) as info:
            schema["T"].parse(text)
        return info.value.code

    ok = {"b": "True", "m": "None", "l": "Low", "d": 'Date("2026-11-15")', "n": "1"}

    def with_(**fields: str) -> str:
        return "{ " + ", ".join(f"{k}: {v}" for k, v in (ok | fields).items()) + " }"

    assert code(with_(b="Yes")) == "unknown-tag"
    assert code(with_(b="True(1)")) == "wrong-payload"
    assert code(with_(b='"true"')) == "type-mismatch"
    assert code(with_(m="Some")) == "wrong-payload"
    assert code(with_(l="Mid")) == "unknown-tag"
    assert code(with_(d='Date("2026-02-30")')) == "invalid-time"
    assert code(with_(d='Time("09:00")')) == "type-mismatch"
    assert code(with_(n="1.0")) == "not-an-integer"
    assert code(with_(n="128")) == "out-of-range"
    assert code("{ b: True }") == "missing-field"


if __name__ == "__main__":
    write_table()
    print(f"{len(catalogue())} codes: wrote {TABLE.relative_to(ROOT)}")
