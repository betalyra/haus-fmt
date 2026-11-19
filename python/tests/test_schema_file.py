"""Schema files (spec §13.3, §14): what the checker accepts, rejects and warns about."""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar

import pytest

from haus import HausError, Variant
from haus.schema import (
    FileResolver,
    HausSchemaFileError,
    PositionalPayload,
    RecordType,
    ResolvedModule,
    Tagged,
    Unknown,
    VariantType,
    compile_schema,
    identify,
    load_schema,
    parse_schema_file,
)

_R = TypeVar("_R")


def rejects(text: str, reason: str, **kwargs: object) -> HausSchemaFileError:
    with pytest.raises(HausSchemaFileError) as e:
        parse_schema_file(text, **kwargs)  # type: ignore[arg-type]
    assert reason in e.value.reason, e.value.reason
    return e.value


@pytest.mark.parametrize(
    ("text", "reason"),
    [
        ("type A = B", "unknown type B"),
        ("type A = Date", "import it with: import std/time (Date)"),
        ("type A = Money", "import @haus-fmt/money (Money)"),
        ("type A = BBox", "import @haus-fmt/geo (BBox)"),
        ("type A = Array", "Array needs 1 argument"),
        ("type A = Array Int Int", "Array needs 1 argument"),
        ("type A = Result Int", "Result needs 2 arguments"),
        ("type A = Int Int", "Int takes no arguments"),
        ("type P a = { x: a }\ntype A = P", "P needs 1 argument (P a)"),
        ("type P a = { x: a }\ntype A = P Int Int", "P needs 1 argument (P a), got 2"),
        ("type A = Int\ntype A = String", "type A is defined twice"),
        ("type Maybe = Int", "Maybe is a prelude type"),
        ("type Stream = Int", "Stream is a prelude type"),
        ("type Bool = Int", "Bool is a prelude type"),
        ("type A = { x: Int, x: String }", "field x appears twice"),
        ("type A = < X | X >", "tag X appears twice"),
        ("type B = { x: Int }\ntype A = { ...B, x: Int }", "field x appears twice (from ...B)"),
        ("type B = < X >\ntype A = < X | ...B >", "tag X appears twice (from ...B)"),
        ("type A = closed < >", "a closed variant needs at least one tag"),
        ("type B = < X >\ntype A = { ...B }", "B is not a record"),
        ("type B = { x: Int }\ntype A = < ...B >", "B is not a variant"),
        ("type B a = { x: a }\ntype A = { ...B }", "only a type without parameters can be spread"),
        ("type B = Stream { x: Int }\ntype A = { ...B }", "B is a Stream and can't be spread"),
        ("type A = { ...Int }", "Int is not a record, so it can't be spread here"),
        ("type A = < ...A >", "type A spreads itself"),
        ("type A = { x: Int, ...r }", "row parameters (...r)"),
        ("type A = { @deprecated(1) x: Int }", "@deprecated takes no argument or one string"),
        ('type A = < @deprecated @deprecated("x") X >', "@deprecated appears twice"),
        ("type A = B\ntype B = A", "refers to itself without a record, array or variant"),
        ("type A = Secret A", "refers to itself without a record, array or variant"),
        ("type A = Secret (Secret A)", "refers to itself without a record, array or variant"),
        ("type L a = < Nil | Cons a (L (Array a)) >", "must refer to itself with its own parameters"),
        ("type L a b = < Nil | Cons a (L b a) >", "must refer to itself with its own parameters"),
        ("type A = { x: b }", "unknown type parameter b"),
        ("type A a a = Int", "parameter a appears twice"),
        ("type A = { s: Stream Int }", "Stream can only be the whole type of a definition"),
        ("type E = Stream Int\ntype A = { e: E }", "E is a Stream"),
        ("type A = { e: E }\ntype E = Stream Int", "E is a Stream"),
        ("type A = Stream", "Stream needs 1 argument"),
        ("type A = { x: _ }", "there is no _"),
        ("type A = {| x: Int |}", "write closed { … }"),
        ("type A = { @deprecated ...B }\ntype B = { x: Int }", "attributes can't be put on a spread"),
        ('type A = { @deprecated ("x") x: Int }', "no space is allowed between @deprecated and '('"),
        ("@deprecated\nimport std/time (Date)", "a type definition after the attribute"),
        ("type A = { x: Int", "expected ',' or '}'"),
        ("type a = Int", "a type name"),
        ("type A = Int /* open", "unterminated block comment"),
        ('type A = { """x""": Int }', "block strings can't be field names"),
        ("type A = { @deprecated(Foo { a: ) x: Int }", "expected a value"),
    ],
)
def test_rejects(text: str, reason: str) -> None:
    rejects(text, reason)


@pytest.mark.parametrize(
    ("text", "code", "at"),
    [
        ('type A = { "x: Int }', "unterminated-string", (1, 12)),
        ("type A = Int /* never closed", "unterminated-comment", (1, 14)),
        ("type A = Int\rtype B = Int", "lone-carriage-return", (1, 13)),
        ("// a\rb\ntype A = Int", "lone-carriage-return", (1, 5)),
        ("// a\x07b\ntype A = Int", "control-character", (1, 5)),
        ("/* a\x7fb */ type A = Int", "control-character", (1, 5)),
        ("// a\x85b\ntype A = Int", "control-character", (1, 5)),
        ("// access\u202e denied\ntype A = Int", "bidi-control", (1, 10)),
        ('type A = { "a\u2066b": Int }', "bidi-control", (1, 14)),
        ('type A = { "a\x07b": Int }', "control-character", (1, 14)),
        ('type A = { "a\nb": Int }', "string-line-break", (1, 14)),
        ('type A = { "a\\x41": Int }', "invalid-escape", (1, 14)),
        ('type A = { "a\\u{D800}": Int }', "invalid-unicode-escape", (1, 14)),
    ],
)
def test_comments_whitespace_and_strings_are_those_of_data_files(text: str, code: str, at: tuple[int, int]) -> None:
    with pytest.raises(HausSchemaFileError) as e:
        parse_schema_file(text)
    assert (e.value.code, (e.value.line, e.value.column)) == (code, at), e.value


def test_quoted_keys_take_every_escape_of_data_strings() -> None:
    s = compile_schema('type A = { "tab\\there": Int, "cr\\r": Int, "\\u{1F600}": Int, "q\\"\\\\": Int }')
    assert s["A"].parse('{ "tab\\there": 1, "cr\\r": 2, "😀": 3, "q\\"\\\\": 4 }') == {
        "tab\there": 1,
        "cr\r": 2,
        "😀": 3,
        'q"\\': 4,
    }


def test_a_schema_file_that_is_not_utf8(tmp_path: Path) -> None:
    path = tmp_path / "a.schema.haus"
    path.write_bytes(b"// \xff\ntype A = Int\n")
    with pytest.raises(HausSchemaFileError) as e:
        load_schema(path)
    assert e.value.code == "invalid-utf8"


def test_error_positions() -> None:
    e = rejects("type A = Int\n\ntype B = { x: Nope }", "unknown type Nope")
    assert (e.line, e.column) == (3, 15)


def _quickly(f: Callable[[], _R], seconds: float = 1.0) -> _R:
    start = time.perf_counter()
    out = f()
    assert time.perf_counter() - start < seconds
    return out


def test_instances_that_double_through_another_definition_are_rejected_before_any_is_made() -> None:
    text = "\n".join(
        [
            "type P a b = { l: a, r: b }",
            "type A a = < X (B (P a a)) | Done >",
            "type B a = < Y (A (P a a)) | Stop >",
            "type Root = A Int",
        ]
    )
    e = _quickly(lambda: rejects(text, "A refers to B, which refers back to A"))
    assert (e.code, e.line, e.column) == ("growing-recursion", 2, 17)


def test_growing_recursion_through_three_definitions() -> None:
    text = "\n".join(
        [
            "type P a b = { l: a, r: b }",
            "type A a = < X (B a) | Done >",
            "type B a = < Y (C a) | Stop >",
            "type C a = < Z (A (P a a)) | End >",
            "type Root = A Int",
        ]
    )
    e = _quickly(lambda: rejects(text, "C refers to A, which refers back to C"))
    assert (e.code, e.line, e.column) == ("growing-recursion", 4, 17)


def test_definitions_that_refer_to_each_other_with_their_own_parameters() -> None:
    s = compile_schema("""
        type GTree a = { value: a, kids: Forest a }
        type Forest a = Array (GTree a)
        type Swap a b = < S (Pair b a) | E >
        type Pair a b = { p: Swap a b, q: Swap b a }
        type Root = GTree (Pair Int String)
    """)
    assert s["Root"].parse("{ value: { p: E, q: E }, kids: [] }") == {
        "value": {"p": Tagged("E"), "q": Tagged("E")},
        "kids": (),
    }


def _chain(step: str, levels: int = 30) -> str:
    """Non-recursive generics, each passing its argument nested in `step` to the one before: 30 levels deep."""
    defs = ["type G0 a = { v: a }", *(f"type G{k} a = G{k - 1} ({step})" for k in range(1, levels))]
    return "\n".join([*defs, f"type Root = G{levels - 1} Int"])


@pytest.mark.parametrize(
    "text",
    [
        "type P a b = { l: a, r: b }\n" + _chain("P a a"),
        _chain("{ l: a, r: a }"),
        _chain("< L a | R a >"),
        "type P a b = { l: a, r: b }\ntype Root = " + "P (" * 30 + "P Int Int" + ") Int" * 30,
    ],
)
def test_arguments_nested_30_levels_deep_compile_quickly(text: str) -> None:
    s = _quickly(lambda: compile_schema(text))
    assert "Root" in s.types


def test_spreads_keep_order_and_their_own_openness() -> None:
    f = parse_schema_file("""
        type UserEvent = < UserCreated { id: Int } | @deprecated UserRenamed { id: Int, to: String } >
        type AppEvent = closed < Start | ...UserEvent | Heartbeat >
        type Base = closed { id: Int }
        type Person = { ...Base, name: String }
    """)
    app = f.instance("AppEvent")
    assert app is not None and isinstance(app.body, VariantType)
    assert [c.tag for c in app.body.cases] == ["Start", "UserCreated", "UserRenamed", "Heartbeat"]
    assert not app.body.open
    assert app.body.cases[2].attributes[0].name == "deprecated"  # a spread copies attributes
    person = f.instance("Person")
    assert person is not None and isinstance(person.body, RecordType)
    assert [x.key for x in person.body.fields] == ["id", "name"] and not person.body.closed


def test_generics_and_result() -> None:
    s = compile_schema("""
        type List a = < Nil | Cons a (List a) >
        type Ints = List Int
        type Out = Result String (List Int)
    """)
    assert "List" not in s.types  # generic types have no decoder of their own
    assert s["Ints"].parse("Cons(1, Nil)") == Tagged("Cons", (1, Tagged("Nil")))
    assert s["Out"].parse("Ok(Nil)") == Tagged("Ok", (Tagged("Nil"),))
    out = s.file.instance("Out")
    assert out is not None and isinstance(out.body, VariantType)
    assert [c.tag for c in out.body.cases] == ["Err", "Ok"] and not out.body.open
    assert isinstance(out.body.cases[0].payload, PositionalPayload)


def test_definitions_have_docs_and_sources() -> None:
    f = parse_schema_file('import std/time (Date)\n\n// A day.\n// Any day.\n@deprecated("old")\ntype Day = Date\n')
    (day,) = f.definitions
    assert day.doc == "A day.\nAny day."
    assert day.source == '// A day.\n// Any day.\n@deprecated("old")\ntype Day = Date'
    assert day.id == "Day"
    assert f.imports == {"Date": "Date"}


# ── warnings ─────────────────────────────────────────────────


def test_warnings() -> None:
    f = parse_schema_file("""@since("1.2")
@deprecated("use Customer")
type Client = { id: Int }
@deprecated
type Old = < A >
type Uses = { client: Client, @example(1) old: Old }
type Spreads = < ...Old | B >
@deprecated
type AlsoOld = { c: Client }
""")
    assert [(w.kind, w.message, w.line, w.column) for w in f.warnings] == [
        (
            "unknown-attribute",
            "unknown attribute @since: this version of haus gives it no meaning (it knows @deprecated)",
            1,
            1,
        ),
        ("deprecated", "Client is deprecated: use Customer", 6, 23),
        (
            "unknown-attribute",
            "unknown attribute @example: this version of haus gives it no meaning (it knows @deprecated)",
            6,
            31,
        ),
        ("deprecated", "Old is deprecated", 6, 48),
        ("deprecated", "Old is deprecated", 7, 21),
    ]
    w = f.warnings[0]
    assert (w.offset, w.end) == (0, len('@since("1.2")'))


def test_a_record_case_with_a_field_tag_or_args_has_no_json_form() -> None:
    text = """type Disc = { _tag: Int32 }
type Alias = Disc
type Page a = { _args: a }
type Shape = < Odd { _tag: Int32 } | Circle Disc | Aliased Alias | Found (Page Int32) | Fine { tag: Int32 } >
type Kept a = < Param a | Inline { _tag: a } >
type Wrapped = < Some2 (Maybe Disc) | Res (Result Int32 Disc) >
"""
    f = parse_schema_file(text)
    assert [(w.code, w.message, w.line, w.column) for w in f.warnings] == [
        ("no-json-form", "Odd has a field named _tag, so it has no schema-based JSON form", 4, 16),
        ("no-json-form", "Circle has a field named _tag, so it has no schema-based JSON form", 4, 38),
        ("no-json-form", "Aliased has a field named _tag, so it has no schema-based JSON form", 4, 52),
        ("no-json-form", "Found has a field named _args, so it has no schema-based JSON form", 4, 68),
        ("no-json-form", "Inline has a field named _tag, so it has no schema-based JSON form", 5, 27),
    ]
    w = f.warnings[0]
    assert (w.end - w.offset, w.hint) == (len("Odd"), "Rename the field, or use self-describing JSON.")
    # Only a warning: the schema is valid, its other cases have JSON, and haus text has the case.
    s = compile_schema(text)
    assert s["Shape"].parse("Odd { _tag: 1 }") == Tagged("Odd", {"_tag": 1})
    assert json.loads(s["Shape"].to_json(Tagged("Fine", {"tag": 1}))) == {"_tag": "Fine", "tag": 1}
    with pytest.raises(HausError) as e:
        s["Shape"].to_json(Tagged("Odd", {"_tag": 1}))
    assert e.value.code == "no-json-form"
    # The cases of imported files are warned about in those files.
    resolver = MemoryResolver({"shapes": (text, None)})
    assert parse_schema_file("import ./shapes (Shape)\ntype Root = Shape", resolver=resolver).warnings == ()


def test_unknown_attributes_are_accepted_as_they_are() -> None:
    s = compile_schema('@x @x(1, "a", [True], { a: Some(1) },) type A = { @y @y n: Int }')
    assert s["A"].parse("{ n: 1 }") == {"n": 1}
    assert len(s.warnings) == 4


# ── imports ──────────────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class MemoryResolver:
    """Files by key; packages as `@org/name` keys."""

    files: dict[str, tuple[str, str | None]]

    def resolve(self, module: str, from_key: str | None) -> ResolvedModule:
        key = module.removeprefix("./")
        if key not in self.files:
            raise LookupError(f"no file {key}")
        text, version = self.files[key]
        id = f"{key}@{version.split('.')[0]}" if version else f"app/{key}"
        return ResolvedModule(key, id, text, version)


GEO = MemoryResolver(
    {
        "@acme/geo": (
            "type Point = { x: Int, y: Int }\ntype Shape = < Circle Int | Square Int >\n"
            "type Box a = { item: a }\ntype Id = String",
            "1.0.0",
        )
    }
)


def test_imports() -> None:
    resolver = MemoryResolver(
        {
            "common": ("type Address = { city: String }\ntype Hidden = Int", None),
            "@haus-fmt/money": ("type Money = < Money Decimal Currency >\ntype Currency = < >", "1.2.0"),
        }
    )
    s = compile_schema(
        "import ./common (Address)\nimport @haus-fmt/money@1 (Money)\ntype Order = { to: Address, total: Money }",
        resolver=resolver,
    )
    assert s["Order"].parse('{ to: { city: "Paris" }, total: Money(1.50, EUR) }') == {
        "to": {"city": "Paris"},
        "total": Tagged("Money", ("1.50", Unknown(Variant("EUR")))),
    }
    assert s.file.imported["Money"].id == "@haus-fmt/money@1#Money"
    assert s.file.imported["Address"].id == "app/common#Address"
    assert s["Address"].id == "app/common#Address"


def test_import_errors() -> None:
    resolver = MemoryResolver(
        {
            "common": ("type Address = { city: String }", None),
            "self": ("import ./self (A)\ntype A = Int", None),
            "a": ("import ./b (B)\ntype A = Int", None),
            "b": ("import ./a (A)\ntype B = Int", None),
            "broken": ("type A = { x: Nope }", None),
            "@acme/ids": ("type Id = String", "3.0.1"),
            "copy": ("type Id = String", "3.0.1"),
        }
    )
    r = {"resolver": resolver}
    rejects("import ./missing (A)", "can't import ./missing: no file missing", **r)
    rejects("import ./common (Street)", "./common has no type Street (it has Address)", **r)
    rejects("import ./common (Address)\nimport ./common (Address)", "Address is imported twice", **r)
    rejects("import ./common (Address, Address)", "Address is imported twice", **r)
    rejects("import ./common (Address)\ntype Address = Int", "type Address is already imported", **r)
    rejects("import ./self (A)", "import cycle", **r)
    rejects("import ./a (A)", "import cycle", **r)
    rejects("import @acme/ids@2 (Id)", "wants major version 2, but version 3.0.1 was found", **r)
    e = rejects("type X = Int\nimport ./broken (A)", "./broken (1:15): unknown type Nope", **r)
    assert (e.line, e.column) == (2, 1)  # at the import, with the place in the imported file
    rejects("import ./common (Address)", "no module resolver")
    rejects("import std/money (Money)", "it is the package @haus-fmt/money")
    rejects("import std/geo (Point)", "unknown standard module std/geo")
    rejects("import std/time (Moment)", "std/time has no type Moment")
    rejects("import std/time (Date)\nimport std/time (Date)", "Date is imported twice")
    rejects("import std/time (Date)\ntype Date = Int", "type Date is already imported")
    rejects("import std/time ()", "expected a type name")
    rejects("import money (Money)", "unknown module money")

    # One package per name: two copies found in different places, or two major versions.
    @dataclass(frozen=True, slots=True)
    class TwoCopies:
        def resolve(self, module: str, from_key: str | None) -> ResolvedModule:
            major = module.removeprefix("./")
            return ResolvedModule(module, f"@acme/ids@{major}", "type Id = String", f"{major}.0.1")

    rejects("import ./3 (Id)\nimport ./3 (Id)", "Id is imported twice", resolver=TwoCopies())
    e = rejects("import ./3 (Id)\nimport ./2 (Id)", "two packages are called @acme/ids", resolver=TwoCopies())
    assert e.code == "duplicate-package" and "3.0.1 (./3) and 2.0.1 (./2)" in e.reason

    # Files outside packages may share an id: they are told apart by their key.
    @dataclass(frozen=True, slots=True)
    class SameIds:
        def resolve(self, module: str, from_key: str | None) -> ResolvedModule:
            return ResolvedModule(module, "common", f"type {module[2:].upper()} = String")

    parse_schema_file("import ./a (A)\nimport ./b (B)", resolver=SameIds())


# ── files and packages ───────────────────────────────────────


@pytest.mark.parametrize(
    ("text", "reason"),
    [
        ("import std/time (Date)\ntype A = < ...Date >", "Date is not a variant, so it can't be spread here"),
        ("import std/time (Date)\ntype A = { ...Date }", "Date is not a record, so it can't be spread here"),
        ("type A = { ...Array }", "Array is not a record, so it can't be spread here"),
        ("import @acme/geo (Point)\ntype A = < ...Point >", "Point is not a variant, so it can't be spread here"),
        ("import @acme/geo (Id)\ntype A = { ...Id }", "Id is not a record, so it can't be spread here"),
        ("import @acme/geo (Box)\ntype A = { ...Box }", "Box has parameters (Box a)"),
    ],
)
def test_spreading_a_known_type_that_cannot_be_spread_says_why(text: str, reason: str) -> None:
    """The error is the spread, not the import: the type is known (spec §14)."""
    e = rejects(text, reason, resolver=GEO)
    assert e.code == "invalid-spread"
    assert (e.line, e.column) == ((2, 15) if "\n" in text else (1, 15))


def test_imported_records_and_variants_can_be_spread() -> None:
    s = compile_schema(
        "import @acme/geo (Point, Shape)\ntype P = { z: Int, ...Point }\ntype S = < Dot | ...Shape >",
        resolver=GEO,
    )
    assert s["P"].parse("{ z: 1, x: 2, y: 3 }") == {"z": 1, "x": 2, "y": 3}
    assert s["S"].parse("Circle(1)") == Tagged("Circle", (1,))
    assert s["S"].parse("Dot") == Tagged("Dot")


def test_a_spread_type_that_is_not_imported_is_unknown() -> None:
    e = rejects("type A = { ...Date }", "unknown type Date; import it with: import std/time (Date)")
    assert e.code == "unknown-type"


def test_load_schema_with_files_and_packages(tmp_path: Path) -> None:
    app = tmp_path / "app"
    (app / "schemas").mkdir(parents=True)
    (app / "pyproject.toml").write_text('[project]\nname = "my-app"\n')
    (app / "schemas" / "common.schema.haus").write_text("type Address = { city: String }\n")
    (app / "schemas" / "order.schema.haus").write_text(
        "import ./common (Address)\nimport @haus-fmt/money@1 (Money)\ntype Root = { to: Address, total: Money }\n"
    )
    money = tmp_path / "vendor" / "money"
    money.mkdir(parents=True)
    (money / "package.haus").write_text('{ name: "@haus-fmt/money", version: "1.0.0" }')
    (money / "schema.haus").write_text("type Money = < Money Decimal String >\n")

    s = load_schema(app / "schemas" / "order.schema.haus", packages={"@haus-fmt/money": money})
    assert s["Root"].id == "my-app/schemas/order#Root"
    assert s.file.imported["Money"].id == "@haus-fmt/money@1#Money"
    assert s.file.imported["Address"].id == "my-app/schemas/common#Address"
    assert s["Root"].parse('{ to: { city: "Paris" }, total: Money(1.50, "EUR") }')["total"] == Tagged(
        "Money", ("1.50", "EUR")
    )
    assert identify(money / "schema.haus") == "@haus-fmt/money@1"

    with pytest.raises(HausSchemaFileError, match="not among the packages"):
        load_schema(app / "schemas" / "order.schema.haus")
    with pytest.raises(HausSchemaFileError, match="names the package @haus-fmt/money, not @haus-fmt/geo"):
        compile_schema(
            "import @haus-fmt/geo (Point)",
            resolver=FileResolver(tmp_path, {"@haus-fmt/geo": money}),
        )
    with pytest.raises(HausSchemaFileError, match="wants major version 2"):
        compile_schema("import @haus-fmt/money@2 (Money)", resolver=FileResolver(tmp_path, {"@haus-fmt/money": money}))
