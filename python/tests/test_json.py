"""JSON (spec §16): the strict reader, the writer, the import, self-describing and schema-based JSON, JSON Lines."""

from __future__ import annotations

import datetime as dt
import json
import math
from decimal import Decimal

import pytest

import haus
from haus import Array, Bytes, HausJsonError, Limits, Number, Record, String, Variant
from haus.schema import (
    DateCodec,
    DecimalCodec,
    HausDecodeError,
    HausEncodeError,
    Nothing,
    Secret,
    Some,
    Tagged,
    Unknown,
    compile_schema,
)

SCHEMA = compile_schema("""
    import std/time (Date)
    type Order = { id: Int, items: Array Item, note?: Maybe String, shape?: Shape }
    type Item = { sku: String, qty: UInt16, price: Decimal }
    type Shape = < Circle { r: Float64 } | Point Float64 Float64 | Wrap Int32 | Empty >
    type Exact = closed < Square closed { side: Float64 } | Dot >
    type Level = closed < Debug | Info >
    type Bits = Bool
    type Tagged = < X { _tag: Int32 } | Y >
    type Args = < X { _args: Int32 } | Y >
    type Config = { name: String, key: Secret String, pins?: Secret (Map Int32) }
    type Hidden = Maybe (Secret (Maybe Int32))
    type Loop = Maybe Loop
    type Ping = Maybe Pong
    type Pong = Maybe Ping
    type List = < Nil | Cons Int32 List >
    type Anything = < >
    type Raw = Any
    type F32 = Float32
    type F64 = Float64
    type Blob = Bytes
    type Big = Int
    type U64 = UInt64
    type Amount = Decimal
    type Day = Date
    type Counts = Map Int32
    type Events = Stream Shape
""")


def data(text: str) -> object:
    """JSON as data, numbers by their text."""
    return json.loads(text, parse_int=lambda s: ("n", s), parse_float=lambda s: ("n", s))


def enveloped(value: str) -> str:
    """A self-describing value's JSON text in its envelope (spec §16.2), as written."""
    return f'{{"_haus":1,"_value":{value}}}'


A = enveloped('"a"')
"""The self-describing JSON of the string "a"."""


# ── the reader ───────────────────────────────────────────────


def test_numbers_keep_their_text() -> None:
    assert haus.import_json("0.1000000000000000000000001") == Number("0.1000000000000000000000001")
    assert haus.import_json("123456789012345678901234567890") == Number("123456789012345678901234567890")
    assert haus.import_json("19.90") == Number("19.90")
    assert haus.import_json("1E+05") == Number("1e5")
    assert haus.import_json("2.5E-007") == Number("2.5e-7")
    assert haus.import_json("1E-0") == Number("1e0")
    assert haus.import_json("1e000") == Number("1e0")
    assert haus.import_json("-0") == Number("-0")


@pytest.mark.parametrize("text", ["01", "-", "1.", ".5", "+1", "1e", "0x10", "Infinity", "-Infinity", "1_000"])
def test_invalid_numbers(text: str) -> None:
    with pytest.raises(HausJsonError):
        haus.import_json(text)


def test_number_limits() -> None:
    assert haus.import_json("9" * 1000) == Number("9" * 1000)
    assert haus.import_json("1e6144") == Number("1e6144")
    assert haus.import_json("1e-6144") == Number("1e-6144")
    with pytest.raises(HausJsonError, match="longer than 1000"):
        haus.import_json("9" * 1001)
    with pytest.raises(HausJsonError, match="exponent"):
        haus.import_json("1e6145")
    with pytest.raises(HausJsonError, match="longer than 10"):
        haus.import_json("12345678901", limits=Limits(max_number_length=10))


def test_nesting_limit() -> None:
    assert haus.import_json("[" * 256 + "]" * 256) is not None
    with pytest.raises(HausJsonError, match="nesting deeper than 256"):
        haus.import_json("[" * 257 + "]" * 257)
    with pytest.raises(HausJsonError, match="nesting deeper than 2"):
        haus.import_json('{"a": [[1]]}', limits=Limits(max_depth=2))
    with pytest.raises(HausJsonError):
        haus.import_json("[" * 100_000)


def test_string_limit() -> None:
    small = Limits(max_string_length=3)
    assert haus.import_json('"abc"', limits=small) == String("abc")
    assert haus.import_json('"\\u00e9\\n\\t"', limits=small) == String("é\n\t")
    with pytest.raises(HausJsonError, match="longer than 3"):
        haus.import_json('"abcd"', limits=small)
    with pytest.raises(HausJsonError, match="longer than 3"):
        haus.import_json('{"abcd": 1}', limits=small)


def test_strings_and_escapes() -> None:
    text = r'"a\"b\\c\/d\b\f\n\r\t\u0041\u00E9\ud83d\uDE00 é 😀"'
    assert haus.import_json(text) == String('a"b\\c/d\b\f\n\r\tAé\U0001f600 é 😀')
    assert haus.import_json('"\u2028\u007f"') == String("\u2028\u007f")  # raw, not escaped


@pytest.mark.parametrize(
    "text",
    [
        r'"\ud83d"',  # a high surrogate alone
        r'"\ude00"',  # a low surrogate alone
        r'"\ud83dA"',  # a high surrogate followed by no low one
        r'"\ud83dx"',
        r'"\x"',
        r'"\u12"',
        '"\x1f"',  # raw control character
        '"tab\tinside"',
        '"\ud83d"',  # a lone surrogate in the text itself
        '"unterminated',
    ],
)
def test_invalid_strings(text: str) -> None:
    with pytest.raises(HausJsonError):
        haus.import_json(text)


@pytest.mark.parametrize(
    "text",
    [
        *["", " ", "[1,]", "[,1]", '{"a":1,}', '{"a" 1}', "{1: 2}", "[1 2]", "1 2", "tru", "nul", "NaN", "'a'"],
        *["1\ufeff", "[\ufeff1]", "\ufeff\ufeff1"],  # a byte order mark only at the start
    ],
)
def test_invalid_json(text: str) -> None:
    with pytest.raises(HausJsonError):
        haus.import_json(text)


def test_whitespace_and_literals() -> None:
    assert haus.import_json(' \t\r\n{ "a" : [ true , false , null ] } \n') == Record(
        {"a": Array((Variant("True"), Variant("False"), Variant("None")))}
    )


def test_duplicate_names_are_rejected() -> None:
    with pytest.raises(HausJsonError, match='duplicate member name "a"') as e:
        haus.import_json('{\n  "a": 1,\n  "a": 2\n}')
    assert (e.value.line, e.value.column) == (3, 3)
    # Escapes don't hide a duplicate.
    with pytest.raises(HausJsonError):
        haus.import_json('{"a": 1, "\\u0061": 2}')


def test_error_positions_count_code_points() -> None:
    with pytest.raises(HausJsonError) as e:
        haus.import_json('["😀", x]')
    assert (e.value.line, e.value.column, e.value.reason) == (1, 7, 'unexpected "x", expected a JSON value')
    assert str(e.value) == 'unexpected "x", expected a JSON value at 1:7'


def test_a_byte_order_mark_is_ignored() -> None:
    assert haus.import_json("\ufeff[1]") == Array((Number("1"),))
    assert haus.import_json(b"\xef\xbb\xbf[1]") == Array((Number("1"),))
    assert haus.from_haus_json("\ufeff" + A) == String("a")
    assert SCHEMA["Big"].from_json('\ufeff"5"') == 5
    with pytest.raises(HausJsonError) as e:
        haus.import_json("\ufeff[x]")
    assert (e.value.line, e.value.column) == (1, 3)  # the mark is a column, as in haus


def test_bytes_input_is_utf8() -> None:
    assert haus.import_json('"é"'.encode()) == String("é")
    with pytest.raises(HausJsonError, match="invalid UTF-8") as e:
        haus.import_json(b'["\xff"]')
    assert (e.value.line, e.value.column) == (1, 3)


# ── self-describing (§16.2) ──────────────────────────────────


def test_self_describing_writes_every_kind() -> None:
    value = haus.parse('{ s: "é\\n", n: 0xFF, b: x"0B34", a: [], t: None, p: Point(1, 2.50), r: Circle { r: 1 } }')
    assert data(haus.to_haus_json(value)) == {
        "_haus": ("n", "1"),
        "_value": {
            "_rec": {
                "s": "é\n",
                "n": {"_num": "255"},
                "b": {"_bytes": "0b34"},
                "a": [],
                "t": {"_tag": "None"},
                "p": {"_tag": "Point", "_args": [{"_num": "1"}, {"_num": "2.50"}]},
                "r": {"_tag": "Circle", "_args": [{"_rec": {"r": {"_num": "1"}}}]},
            }
        },
    }
    assert haus.to_haus_json(String("é\u0000\u001b")) == enveloped('"é\\u0000\\u001b"')


def test_writers_escape_controls_that_change_the_display() -> None:
    """DEL, C1 and bidi controls, and U+2028 and U+2029, are escaped in strings and member names,
    by every writer (spec §16)."""
    text = "a\u007f\u0085\u009f\u202a\u202e\u2066\u2069b\u00a0\u2027\u2028\u2029\u202f"
    escaped = '"a\\u007f\\u0085\\u009f\\u202a\\u202e\\u2066\\u2069b\u00a0\u2027\\u2028\\u2029\u202f"'
    assert haus.to_haus_json(String(text)) == enveloped(escaped)
    assert haus.to_haus_json(Record({text: String("")})) == enveloped(f'{{"_rec":{{{escaped}:""}}}}')
    assert SCHEMA["Counts"].to_json({text: 1}) == f"{{{escaped}:1}}"
    assert list(SCHEMA["Counts"].to_json_lines([{"\u2028": 1}])) == ['{"\\u2028":1}\n']
    assert haus.from_haus_json(enveloped(escaped)) == String(text)


def test_readers_accept_the_line_separators_raw() -> None:
    """U+2028 and U+2029 are escaped when written, and read raw by every reader (spec §16)."""
    raw = '"a\u2028b\u2029"'
    assert haus.from_haus_json(enveloped(raw)) == String("a\u2028b\u2029")
    assert haus.import_json(raw) == String("a\u2028b\u2029")
    assert SCHEMA["Counts"].from_json('{"\u2028": 1}') == {"\u2028": 1}


@pytest.mark.parametrize(
    ("raw", "code"),
    [("\u007f", "control-character"), ("\u0085", "control-character"), ("\u202e", "bidi-control")],
)
def test_only_self_describing_json_rejects_raw_display_controls(raw: str, code: str) -> None:
    """Only haus writes self-describing JSON, and it escapes them; other JSON may hold them raw (spec §16)."""
    for text in (enveloped(f'"a{raw}"'), enveloped(f'{{"_rec":{{"a{raw}":"b"}}}}')):
        with pytest.raises(HausJsonError) as e:
            haus.from_haus_json(text)
        assert e.value.code == code
        assert e.value.line == 1
        with pytest.raises(HausJsonError) as f:
            list(haus.from_haus_json_lines(f"{A}\n{text}\n"))
        assert (f.value.code, f.value.line) == (code, 2)
    assert haus.import_json(f'"a{raw}"') == String(f"a{raw}")
    assert SCHEMA["Raw"].from_json(f'"a{raw}"') == String(f"a{raw}")  # `Any` inside schema-based JSON
    assert SCHEMA["Shape"].from_json(f'{{"_tag": "Star", "_args": ["{raw}"]}}') == Unknown(
        Variant("Star", (String(raw),))
    )


def test_self_describing_envelope() -> None:
    assert haus.to_haus_json(String("a")) == '{"_haus":1,"_value":"a"}'
    assert haus.from_haus_json(' { "_value" : "a" , "_haus" : 1 } ') == String("a")
    for text, code in [
        ('"a"', "haus-json-form"),
        ('{"_rec": {}}', "haus-json-form"),
        ('{"_haus": 1}', "haus-json-form"),
        ('{"_haus": 1, "_value": "a", "_tag": "A"}', "haus-json-form"),
        ('{"_haus": 2, "_value": "a"}', "haus-json-version"),
        ('{"_haus": 1e0, "_value": "a"}', "haus-json-version"),
        ('{"_haus": "1", "_value": "a"}', "haus-json-version"),
        ('{"_haus": null, "_value": "a"}', "haus-json-version"),
        ('{"_haus": 1, "_value": {"_haus": 1, "_value": "a"}}', "haus-json-form"),
    ]:
        with pytest.raises(HausJsonError) as e:
            haus.from_haus_json(text)
        assert (e.value.code, e.value.path) == (code, ()), text


def test_self_describing_round_trip() -> None:
    text = '[{ "x-y": [1.0, -0, 1e-7] }, Tag({ a: x"" }), Two(Some(1), "\\u{1F600}"), {}]'
    value = haus.parse(text)
    assert haus.equals(haus.from_haus_json(haus.to_haus_json(value)), value)


def test_self_describing_rejects_invalid_values_built_in_code() -> None:
    with pytest.raises(HausEncodeError):
        haus.to_haus_json(Variant("lower"))
    with pytest.raises(HausEncodeError):
        haus.to_haus_json(Number("01"))
    with pytest.raises(HausEncodeError):
        haus.to_haus_json(String("\ud800"))
    with pytest.raises(HausEncodeError):
        haus.to_haus_json(Array((Array(()),)), limits=Limits(max_depth=1))
    # Number literals built in code are normalized, as the parser would.
    assert haus.to_haus_json(Number("1E+05")) == enveloped('{"_num":"1e5"}')


@pytest.mark.parametrize(
    "value",
    [
        '{"_num": "1E5"}',  # not normalized
        '{"_num": "1_000"}',
        '{"_num": "0xff"}',
        '{"_num": "+1"}',
        '{"_num": "1e6145"}',
        '{"_bytes": "0b 34"}',
        '{"_bytes": 1}',
        '{"_rec": []}',
        '{"_tag": "T", "_args": {}}',
        '{"_tag": "T", "_args": [1]}',
        '{"_tag": "", "_args": ["a"]}',
        '{"_tag": "T", "x": 1}',
        '{"_tag": "T", "args": ["a"]}',
        '{"_args": ["a"]}',
        '{"_str": "a"}',
        '{"num": "1"}',
        "[1]",
    ],
)
def test_self_describing_rejects(value: str) -> None:
    with pytest.raises(HausJsonError):
        haus.from_haus_json(enveloped(value))


def test_self_describing_errors_have_a_path() -> None:
    """The envelope adds no path segment."""
    with pytest.raises(HausJsonError) as e:
        haus.from_haus_json(enveloped('{"_rec": {"items": [{"_num": "1"}, 2]}}'))
    assert e.value.path == ("_rec", "items", 1)
    assert e.value.line is None
    assert str(e.value) == "expected the self-describing form of a haus value, found number 2 at $._rec.items[1]"


def test_self_describing_depth_is_the_values() -> None:
    """Two JSON levels make one haus level; the haus depth is what is limited."""
    nested = haus.parse("{ a: { b: [T { c: 1 }] } }")
    text = haus.to_haus_json(nested)
    assert haus.equals(haus.from_haus_json(text, limits=Limits(max_depth=4)), nested)
    with pytest.raises(HausJsonError, match="nesting deeper than 3"):
        haus.from_haus_json(text, limits=Limits(max_depth=3))
    deep = "[" * 256 + "]" * 256
    assert haus.from_haus_json(enveloped(deep)) == haus.parse(deep)
    with pytest.raises(HausJsonError):
        haus.from_haus_json(enveloped("[" * 257 + "]" * 257))


def test_deepest_values_at_the_default_limits() -> None:
    """256 levels, the default limit: as many JSON levels as `Tag { … }` needs, without Python's recursion limit."""
    deep = haus.parse("T { a: " * 255 + "[1]" + " }" * 255)
    assert haus.equals(haus.from_haus_json(haus.to_haus_json(deep)), deep)
    t = SCHEMA["List"]
    value: object = Tagged("Nil")
    for i in range(255):
        value = Tagged("Cons", (i, value))
    assert t.from_json(t.to_json(value)) == value
    raw = SCHEMA["Raw"]
    assert haus.equals(raw.from_json(raw.to_json(deep)), deep)


def test_the_string_limit_counts_keys_and_tags_in_values_built_in_code() -> None:
    """Raw values (`Any`) and self-describing JSON check record keys and tags against the string limit (spec §7)."""
    four = Limits(max_string_length=4)
    raw = SCHEMA["Raw"]
    ok = Variant("Abcd", (Record({"abcd": Array(())}),))
    assert raw.encode(ok, limits=four) == ok
    assert haus.to_haus_json(ok, limits=four) == enveloped('{"_tag":"Abcd","_args":[{"_rec":{"abcd":[]}}]}')
    for value, reason in (
        (Record({"abcde": Array(())}), "key longer than 4 characters"),
        (Array((Variant("Abcde"),)), "tag longer than 4 characters"),
        (Variant("Abcde", (Record({"a": Array(())}),)), "tag longer than 4 characters"),
    ):
        with pytest.raises(HausEncodeError, match=reason):
            raw.encode(value, limits=four)
        with pytest.raises(HausEncodeError, match=reason):
            haus.to_haus_json(value, limits=four)
    # In JSON text, member names and tags are JSON strings first: the reader's string limit.
    with pytest.raises(HausJsonError, match="string longer than 4 characters"):
        haus.from_haus_json(enveloped('{"_tag": "Abcde"}'), limits=four)
    with pytest.raises(HausJsonError, match="string longer than 4 characters"):
        haus.import_json('{"abcde": []}', limits=four)


def test_deepest_values_at_the_supported_depth() -> None:
    """512 levels, `MAX_SUPPORTED_DEPTH`, on every path: 2049 JSON levels for `Tag { … }`, from deep in the stack."""
    limits = Limits(max_depth=haus.MAX_SUPPORTED_DEPTH)

    def nested(frames: int) -> None:
        if frames > 0:
            return nested(frames - 1)
        deep = haus.parse("T { a: " * 511 + "[1]" + " }" * 511, limits=limits)
        assert haus.canonical(deep) == "T{a:" * 511 + "[1]" + "}" * 511
        assert haus.equals(haus.from_haus_json(haus.to_haus_json(deep, limits=limits), limits=limits), deep)
        lines = list(haus.to_haus_json_lines([deep], limits=limits))
        assert [haus.canonical(v) for v in haus.from_haus_json_lines(lines[0], limits=limits)] == [haus.canonical(deep)]
        assert haus.equals(
            haus.import_json("[" * 512 + "]" * 512, limits=limits), haus.parse("[" * 512 + "]" * 512, limits=limits)
        )
        raw = SCHEMA["Raw"]
        assert haus.equals(raw.from_json(raw.to_json(deep, limits=limits), limits=limits), deep)
        assert haus.equals(raw.decode(deep, limits=limits), deep)
        t = SCHEMA["List"]
        value: object = Tagged("Nil")
        for i in range(512):
            value = Tagged("Cons", (i, value))
        text = t.canonical(value, limits=limits)
        assert t.parse(text, limits=limits) == value
        assert t.from_json(t.to_json(value, limits=limits), limits=limits) == value
        with pytest.raises(haus.HausSyntaxError, match="deeper than 512"):
            t.parse("Cons(0," + text + ")", limits=limits)
        with pytest.raises(HausEncodeError, match="deeper than 512"):
            t.encode(Tagged("Cons", (0, value)), limits=limits)

    nested(500)


def test_self_describing_integers_within_the_number_limit() -> None:
    """The longest hex literal has a decimal literal within the limit (spec §7); `_num` takes no longer one."""
    value = haus.parse("0x" + "f" * 829)
    assert isinstance(value, Number)
    assert len(value.text) <= 1000
    assert haus.from_haus_json(haus.to_haus_json(value)) == value
    assert haus.from_haus_json(enveloped(f'{{"_num":"{"9" * 1000}"}}')) == Number("9" * 1000)
    with pytest.raises(HausJsonError) as info:
        haus.from_haus_json(enveloped(f'{{"_num":"{"1" + "0" * 1000}"}}'))
    assert info.value.code == "number-too-long"
    # A writer for a reader with a smaller limit has no hex to fall back on.
    with pytest.raises(haus.HausError) as written:
        haus.to_haus_json(Number("1000000000000"), limits=Limits(max_number_length=12))
    assert written.value.code == "number-too-long"


# ── schema-based (§16.3) ─────────────────────────────────────


def test_schema_based_order() -> None:
    t = SCHEMA["Order"]
    order = t.parse("""{
        id: 12345678901234567890,
        items: [{ sku: "A-1", qty: 2, price: 19.90 }],
        note: None,
        shape: Point(1, 2.5),
    }""")
    text = t.to_json(order)
    assert data(text) == {
        "id": "12345678901234567890",
        "items": [{"sku": "A-1", "qty": ("n", "2"), "price": "19.90"}],
        "note": None,
        "shape": {"_tag": "Point", "values": [("n", "1"), ("n", "2.5")]},
    }
    assert t.from_json(text) == order
    assert t.from_json('{"id": "1", "items": []}') == {"id": 1, "items": ()}


def test_schema_based_writes_one_line_without_spaces() -> None:
    assert SCHEMA["Order"].to_json({"id": 1, "items": [], "note": Some("é\n")}) == '{"id":"1","items":[],"note":"é\\n"}'


def test_schema_based_scalars() -> None:
    assert SCHEMA["Blob"].to_json(b"\x0b\x34\xff") == '"CzT/"'
    assert SCHEMA["Blob"].from_json('"CzT/"') == b"\x0b\x34\xff"
    assert SCHEMA["Blob"].from_json('""') == b""
    assert SCHEMA["Big"].to_json(-12) == '"-12"'
    assert SCHEMA["Big"].from_json('"-0"') == 0
    assert SCHEMA["Big"].from_json(f'"-{"9" * 999}"') == 1 - 10**999
    assert SCHEMA["U64"].to_json(2**64 - 1) == '"18446744073709551615"'
    assert SCHEMA["Amount"].to_json("1.5e3") == '"1.5e3"'
    assert SCHEMA["Amount"].from_json('"-0.00"') == "-0.00"
    assert SCHEMA["Day"].to_json("2026-11-13") == '"2026-11-13"'
    assert SCHEMA["Bits"].to_json(True) == "true"
    assert SCHEMA["Level"].to_json(Tagged("Info")) == '"Info"'
    assert SCHEMA["Counts"].to_json({"pt-BR": 2, "": 0}) == '{"pt-BR":2,"":0}'


@pytest.mark.parametrize("text", ['"CzR="', '"CzQ"', '"C zQ="', '"CzQ=\\n"', '"CzQ=="', '"Cz-_"', "11"])
def test_schema_based_bytes_are_strict_base64(text: str) -> None:
    with pytest.raises(HausDecodeError):
        SCHEMA["Blob"].from_json(text)


@pytest.mark.parametrize("text", ['"007"', '"1.0"', '" 1"', '"1 "', '""', '"0x10"', '"1_000"', "1"])
def test_schema_based_integer_strings(text: str) -> None:
    with pytest.raises(HausDecodeError):
        SCHEMA["Big"].from_json(text)


def test_schema_based_integer_strings_within_the_number_limit() -> None:
    # Longer than the limit is too long (spec §16.3), whether or not its hex form would fit; a bounded type
    # checks its range first.
    with pytest.raises(HausDecodeError) as info:
        SCHEMA["Big"].from_json(f'"{"1" + "0" * 1000}"')
    assert info.value.code == "number-too-long"
    with pytest.raises(HausDecodeError) as info:
        SCHEMA["U64"].from_json(f'"{"1" + "0" * 1000}"')
    assert info.value.code == "out-of-range"
    assert SCHEMA["Big"].from_json('"1000000000000"', limits=Limits(max_number_length=13)) == 10**12
    with pytest.raises(HausDecodeError) as info:
        SCHEMA["Big"].from_json('"1000000000000"', limits=Limits(max_number_length=12))
    assert info.value.code == "number-too-long"


@pytest.mark.parametrize("text", ['"1."', '".5"', '"0x10"', '"1_000"', '" 1"', '"NaN"', '""', '"1e6145"'])
def test_schema_based_decimal_strings(text: str) -> None:
    with pytest.raises(HausDecodeError):
        SCHEMA["Amount"].from_json(text)


def test_schema_based_floats() -> None:
    f64, f32 = SCHEMA["F64"], SCHEMA["F32"]
    assert f64.to_json(0.1) == "0.1"
    assert f64.to_json(1e21) == "1e21"
    assert f64.to_json(1.5e-7) == "1.5e-7"
    assert f64.to_json(-0.0) == "-0"
    assert f64.to_json(100) == "100"
    assert f32.to_json(2097152.25) == "2097152.2"
    assert f32.to_json(0.1) == "0.1"
    assert [f64.to_json(x) for x in (math.nan, math.inf, -math.inf)] == ['"NaN"', '"Infinity"', '"-Infinity"']
    assert math.isnan(f64.from_json('"NaN"'))
    assert f64.from_json('"-Infinity"') == -math.inf
    assert math.copysign(1, f64.from_json("-0")) == -1
    assert f64.from_json("1E+2") == 100.0
    assert f32.from_json("16777217") == 16777216.0
    with pytest.raises(HausDecodeError, match="too large for Float32"):
        f32.from_json("3.5e38")
    for text in ['"inf"', '"nan"', '"NegInfinity"', "null", '"1"']:
        with pytest.raises(HausDecodeError):
            f64.from_json(text)


def test_schema_based_maybe() -> None:
    order = SCHEMA["Order"]
    assert order.from_json('{"id": "1", "items": [], "note": null}')["note"] == Nothing()
    assert order.from_json('{"id": "1", "items": [], "note": "x"}')["note"] == Some("x")
    assert "note" not in order.from_json('{"id": "1", "items": []}')


def test_schema_based_maybe_through_a_secret() -> None:
    """`Maybe (Secret (Maybe Int32))`: the secret's JSON can be null, so the outer Maybe is tagged."""
    t = SCHEMA["Hidden"]
    assert t.to_json(Nothing()) == '{"_tag":"None"}'
    assert t.to_json(Some(Secret(Nothing()))) == '{"_tag":"Some","value":null}'
    assert t.to_json(Some(Secret(Some(5)))) == '{"_tag":"Some","value":5}'
    read = t.from_json('{"_tag":"Some","value":5}')
    assert isinstance(read, Some)
    assert read.value.expose() == Some(5)  # pyright: ignore[reportUnknownMemberType]


@pytest.mark.parametrize("name", ["Loop", "Ping", "Pong"])
def test_schema_based_recursive_maybe_is_tagged(name: str) -> None:
    """`type Loop = Maybe Loop`: whether its JSON can be null depends on itself, so every level is tagged."""
    t = SCHEMA[name]
    value = Some(Some(Nothing()))
    text = t.to_json(value)
    assert text == '{"_tag":"Some","value":{"_tag":"Some","value":{"_tag":"None"}}}'
    assert t.from_json(text) == value
    with pytest.raises(HausDecodeError):
        t.from_json("null")


def test_schema_based_variants() -> None:
    shape = SCHEMA["Shape"]
    assert shape.to_json(Tagged("Circle", {"r": 1.5})) == '{"_tag":"Circle","r":1.5}'
    assert shape.to_json(Tagged("Wrap", (3,))) == '{"_tag":"Wrap","value":3}'
    assert shape.to_json(Tagged("Empty")) == '{"_tag":"Empty"}'
    assert shape.from_json('{"r": 1.5, "_tag": "Circle", "extra": [1]}') == Tagged("Circle", {"r": 1.5})
    exact = SCHEMA["Exact"]
    assert exact.to_json(Tagged("Dot")) == '{"_tag":"Dot"}'  # a payload elsewhere: an object
    assert exact.from_json('{"_tag": "Square", "side": 2}') == Tagged("Square", {"side": 2.0})
    for text in [
        '{"_tag": "Square", "side": 2, "x": 1}',  # a closed payload
        '{"_tag": "Hexagon"}',  # a closed variant
        '{"_tag": "Dot", "value": 1}',
    ]:
        with pytest.raises(HausDecodeError):
            exact.from_json(text)
    for text in [
        '{"_tag": "Wrap", "values": [3]}',
        '{"_tag": "Wrap", "value": 3, "x": 1}',
        '{"_tag": "Point", "values": [1, 2], "value": 1}',
        '{"_tag": "Point", "values": {"0": 1}}',
        '{"_tag": "Empty", "value": null}',
        '{"_tag": 1}',
        '{"_tag": null}',
    ]:
        with pytest.raises(HausDecodeError):
            shape.from_json(text)


def test_schema_based_unknown_values() -> None:
    shape = SCHEMA["Shape"]
    unknown = Unknown(Variant("Hexagon", (Number("6"), Record({"a": Bytes(b"\x01")}))))
    text = shape.to_json(unknown)
    assert data(text) == {"_tag": "Hexagon", "_args": [{"_num": "6"}, {"_rec": {"a": {"_bytes": "01"}}}]}
    assert shape.from_json(text) == unknown
    assert shape.from_json('{"_tag": "Star"}') == Unknown(Variant("Star"))
    assert SCHEMA["Anything"].from_json('{"_tag": "EUR"}') == Unknown(Variant("EUR"))
    for text in [
        '{"_tag": "Star", "_args": []}',
        '{"_tag": "Star", "_args": [1]}',  # arguments are self-describing
        '{"_tag": "Star", "_args": "a"}',
        '{"_tag": "Star", "_args": [{"_haus": 1, "_value": "a"}]}',  # without the envelope
        '{"_tag": "star"}',  # not a tag
    ]:
        with pytest.raises(HausDecodeError):
            shape.from_json(text)
    # A newer writer's case: other members are a record payload, read by the import (§16.1).
    assert shape.from_json('{"_tag": "Hexagon", "sides": 6, "tags": [true, null]}') == Unknown(
        Variant("Hexagon", (Record({"sides": Number("6"), "tags": Array((Variant("True"), Variant("None")))}),))
    )
    assert shape.from_json('{"_tag": "Hexagon", "_args": "a", "n": 1}') == Unknown(
        Variant("Hexagon", (Record({"_args": String("a"), "n": Number("1")}),))
    )
    # `args` is an ordinary member.
    assert shape.from_json('{"_tag": "Run", "args": [1, 2]}') == Unknown(
        Variant("Run", (Record({"args": Array((Number("1"), Number("2")))}),))
    )
    with pytest.raises(HausDecodeError, match="nesting deeper than 2") as e:
        shape.from_json('{"_tag": "Hexagon", "a": {"b": [1]}}', limits=Limits(max_depth=2))
    assert e.value.path == ("a", "b")
    with pytest.raises(HausEncodeError, match="write it as Tagged"):
        shape.to_json(Unknown(Variant("Empty")))


def test_schema_based_recursive_variant() -> None:
    t = SCHEMA["List"]
    value = Tagged("Cons", (1, Tagged("Cons", (2, Tagged("Nil")))))
    text = t.to_json(value)
    assert text == '{"_tag":"Cons","values":[1,{"_tag":"Cons","values":[2,{"_tag":"Nil"}]}]}'
    assert t.from_json(text) == value


@pytest.mark.parametrize("name", ["Tagged", "Args"])
def test_schema_based_field_named_tag_or_args_has_no_form(name: str) -> None:
    t = SCHEMA[name]
    key = "_tag" if name == "Tagged" else "_args"
    with pytest.raises(HausEncodeError, match=f'"{key}" has no schema-based JSON form') as e:
        t.to_json(Tagged("X", {key: 1}))
    assert e.value.code == "no-json-form"
    with pytest.raises(HausDecodeError, match=f'"{key}" has no schema-based JSON form') as f:
        t.from_json('{"_tag": "X"}')
    assert f.value.code == "no-json-form"
    assert t.to_json(Tagged("Y")) == '{"_tag":"Y"}'


def test_schema_based_any_is_self_describing_without_the_envelope() -> None:
    raw = SCHEMA["Raw"]
    value = haus.parse("{ a: [1, None] }")
    assert raw.to_json(value) == '{"_rec":{"a":[{"_num":"1"},{"_tag":"None"}]}}'
    assert raw.from_json(raw.to_json(value)) == value
    with pytest.raises(HausDecodeError) as e:
        raw.from_json(haus.to_haus_json(value))
    assert (e.value.code, e.value.path) == ("haus-json-form", ())
    with pytest.raises(HausDecodeError) as f:
        SCHEMA["Order"].from_json('{"id": "1", "items": [], "shape": {"_tag": "Star", "_args": [{"_rec": 1}]}}')
    assert f.value.path == ("shape", "_args", 0, "_rec")


def test_schema_based_secrets_never_leak() -> None:
    config = SCHEMA["Config"]
    value = config.from_json('{"name": "prod", "key": "sk-123", "pins": {"a": 1}}')
    assert value["key"].expose() == "sk-123"
    assert config.to_json(value) == '{"name":"prod","key":"sk-123","pins":{"a":1}}'
    for text in ['{"name": "p", "key": 12345}', '{"name": "p", "key": "k", "pins": {"sk-secret-key": "sk-123"}}']:
        with pytest.raises(HausDecodeError) as e:
            config.from_json(text)
        message = str(e.value)
        assert "12345" not in message and "sk-" not in message
        assert e.value.__context__ is None and e.value.__cause__ is None
    with pytest.raises(HausEncodeError) as f:
        config.to_json({"name": "p", "key": Secret(12345)})
    assert "12345" not in str(f.value) and f.value.__context__ is None
    with pytest.raises(HausEncodeError) as g:
        config.to_json({"name": "p", "key": "sk-123"})
    assert "sk-123" not in str(g.value)


def test_schema_based_error_paths() -> None:
    order = SCHEMA["Order"]
    cases = {
        '{"id": "1", "items": [{"sku": "a", "qty": 1, "price": "1"}, {"sku": "b", "qty": -1, "price": "1"}]}': (
            "items",
            1,
            "qty",
        ),
        '{"id": "1", "items": [], "shape": {"_tag": "Point", "values": [1, "2"]}}': ("shape", "values", 1),
        '{"id": "1", "items": [], "shape": {"_tag": "Wrap", "value": 1.5}}': ("shape", "value"),
        '{"id": "1", "items": [], "note": 5}': ("note",),
    }
    for text, path in cases.items():
        with pytest.raises(HausDecodeError) as e:
            order.from_json(text)
        assert e.value.path == path, text


def test_schema_based_with_codecs() -> None:
    s = compile_schema(
        """
        import std/time (Date)
        type Price = { amount: Decimal, on: Date }
        """,
        codecs={"prelude#Decimal": DecimalCodec(), "std/time#Date": DateCodec()},
    )
    t = s["Price"]
    value = t.from_json('{"amount": "19.90", "on": "2026-11-13"}')
    assert value == {"amount": Decimal("19.90"), "on": dt.date(2026, 11, 13)}
    assert t.to_json(value) == '{"amount":"19.90","on":"2026-11-13"}'


def test_schema_based_limits_and_budget() -> None:
    t = SCHEMA["List"]
    deep = Tagged("Nil")
    for i in range(10):
        deep = Tagged("Cons", (i, deep))
    text = t.to_json(deep)
    assert t.from_json(text, limits=Limits(max_depth=10)) == deep
    with pytest.raises(HausDecodeError, match="nesting deeper than 9"):
        t.from_json(text, limits=Limits(max_depth=9))
    with pytest.raises(HausEncodeError, match="nesting deeper than 9"):
        t.to_json(deep, limits=Limits(max_depth=9))
    with pytest.raises(HausDecodeError, match="budget"):
        t.from_json(text, max_steps=5)
    node: dict[str, list[object]] = {"a": []}
    node["a"].append(node)
    with pytest.raises(HausEncodeError, match="cyclic"):
        compile_schema("type T = { a: Array T }")["T"].to_json(node)


def test_schema_based_json_errors_are_json_errors() -> None:
    with pytest.raises(HausJsonError):
        SCHEMA["Counts"].from_json('{"a": 1, "a": 2}')
    with pytest.raises(HausJsonError):
        SCHEMA["Big"].from_json('"1" "2"')


# ── JSON Lines ───────────────────────────────────────────────


def test_json_lines() -> None:
    events = SCHEMA["Events"]
    values = [Tagged("Circle", {"r": 1.0}), Tagged("Empty"), Unknown(Variant("Star"))]
    lines = list(events.to_json_lines(values))
    assert lines == ['{"_tag":"Circle","r":1}\n', '{"_tag":"Empty"}\n', '{"_tag":"Star"}\n']
    data_ = "".join(lines).encode()
    # Chunks split anywhere, also inside a line.
    assert list(events.from_json_lines(data_[i : i + 3] for i in range(0, len(data_), 3))) == values
    assert list(events.from_json_lines("".join(lines).rstrip("\n"))) == values  # no line feed after the last
    assert list(events.from_json_lines("".join(lines).replace("\n", "\r\n"))) == values


def test_json_lines_errors() -> None:
    events = SCHEMA["Events"]
    with pytest.raises(HausDecodeError) as e:
        list(events.from_json_lines('{"_tag":"Empty"}\n{"_tag":"Wrap","value":"x"}\n'))
    assert e.value.path == (1, "value")
    with pytest.raises(HausJsonError) as f:
        list(events.from_json_lines('{"_tag":"Empty"}\n\n{"_tag":"Empty"}\n'))
    assert f.value.line == 2
    with pytest.raises(HausJsonError) as g:
        list(events.from_json_lines('{"_tag":"Empty"}\n{"_tag" "Empty"}\n'))
    assert (g.value.line, g.value.column) == (2, 9)
    with pytest.raises(HausJsonError, match="line longer than 10"):
        list(events.from_json_lines('{"_tag":"Empty"}\n', max_line_length=10))
    with pytest.raises(HausJsonError, match="invalid UTF-8"):
        list(haus.import_json_lines([b'"\xc3', b'"\n"\xff"\n']))
    with pytest.raises(HausEncodeError) as h:
        list(events.to_json_lines([Tagged("Empty"), Tagged("Nope")]))
    assert h.value.path == (1,)


def test_json_lines_byte_order_mark() -> None:
    """Ignored only at the start of the stream, as in haus streams; at the start of a later line it is an error."""
    events = SCHEMA["Events"]
    assert list(events.from_json_lines([b"\xef\xbb", b'\xbf{"_tag":"Empty"}\n{"_tag":"Empty"}\n'])) == [
        Tagged("Empty"),
        Tagged("Empty"),
    ]
    assert list(haus.import_json_lines("\ufeff1\n2\n")) == [Number("1"), Number("2")]
    assert list(haus.from_haus_json_lines(f"\ufeff{A}\n")) == [String("a")]
    later_lines = {
        events.from_json_lines: '{"_tag":"Empty"}\n\ufeff{"_tag":"Empty"}\n',
        haus.import_json_lines: "1\n\ufeff2\n",
        haus.from_haus_json_lines: f"{A}\n\ufeff{A}\n",
    }
    for read, text in later_lines.items():
        with pytest.raises(HausJsonError) as e:
            list(read(text))
        assert (e.value.line, e.value.column) == (2, 1)
    with pytest.raises(HausJsonError):
        list(haus.import_json_lines("\ufeff\ufeff1\n"))


def test_json_lines_without_a_schema() -> None:
    assert list(haus.import_json_lines(['{"a": 1}\n[tr', "ue]\n"])) == [
        Record({"a": Number("1")}),
        Array((Variant("True"),)),
    ]
    values = haus.parse_all('1, "a", T { x: x"00" },')
    text = "".join(haus.to_haus_json_lines(values))
    assert text == "".join(
        enveloped(v) + "\n" for v in ['{"_num":"1"}', '"a"', '{"_tag":"T","_args":[{"_rec":{"x":{"_bytes":"00"}}}]}']
    )
    assert list(haus.from_haus_json_lines(text)) == values
    # Every line is an envelope of its own; errors carry the line's index first in their path.
    for lines, path in [
        (f"{A}\n{enveloped('1')}\n", (1,)),
        (f'{A}\n"b"\n', (1,)),
        (A + "\n" + enveloped('{"_rec": {"k": 1}}') + "\n", (1, "_rec", "k")),
    ]:
        with pytest.raises(HausJsonError) as e:
            list(haus.from_haus_json_lines(lines))
        assert (e.value.code, e.value.path) == ("haus-json-form", path)
    # A JSON array of values isn't self-describing JSON Lines.
    with pytest.raises(HausJsonError):
        list(haus.from_haus_json_lines('[{"_haus":1,"_value":"a"}]\n'))
