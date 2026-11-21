"""The canonical form, equality, hashing and order (spec §12)."""

from __future__ import annotations

import hashlib
from collections.abc import Callable
from functools import cmp_to_key
from typing import cast

import pytest

import haus
from haus import Array, Limits, Number, Record, String, Value, Variant
from haus.schema import HausEncodeError


def c(text: str) -> str:
    return haus.canonical(haus.parse(text))


def test_writes_the_spec_example() -> None:
    assert c('Order { total: 19.90, id: 0xFF, "x-y": 1e+5, p: Point(1, 2) }') == (
        'Order{id:255,p:Point(1,2),total:19.90,"x-y":1e5}'
    )


def test_ignores_layout_comments_key_order_and_spelling() -> None:
    a = haus.parse('{ b: [1_000, 0b11], /* c */ a: Tag({ x: x"0B 34" }) }')
    b = haus.parse('{a:Tag{x:x"0b34"},b:[1000,3]}')
    assert haus.canonical(a) == '{a:Tag{x:x"0b34"},b:[1000,3]}'
    assert haus.equals(a, b)


def test_keeps_what_section_2_tells_apart() -> None:
    assert not haus.equals(haus.parse("1.0"), haus.parse("1"))
    assert not haus.equals(haus.parse("{}"), haus.parse("{ x: None }"))
    assert not haus.equals(haus.parse('"caf\\u{E9}"'), haus.parse('"cafe\\u{301}"'))
    assert not haus.equals(haus.parse("-0"), haus.parse("0"))


def test_keeps_the_sign_of_a_hex_or_binary_zero() -> None:
    # -0x0 is -0, as -0 is (spec §2).
    assert [v.text for v in haus.parse_all("-0x0, -0b0, -0x0_0, 0x0, -0") if isinstance(v, Number)] == [
        "-0",
        "-0",
        "-0",
        "0",
        "-0",
    ]
    assert haus.equals(haus.parse("-0x0"), haus.parse("-0"))
    assert not haus.equals(haus.parse("-0x0"), haus.parse("0"))
    assert c("[-0x0, -0b0, 0x0]") == "[-0,-0,0]"
    assert haus.hash(haus.parse("-0x0")) == haus.hash(haus.parse("-0"))


def test_escapes_only_what_it_must() -> None:
    assert c('"tab\\tquote\\" \\u{41} \\u{1b} \\u{202e} café 😀"') == '"tab\\tquote\\" A \\u{1B} \\u{202E} café 😀"'
    assert c('"""\n  two\n  lines\n  """') == '"two\\nlines"'
    assert c('"\\u{7f}\\u{9f}\\u{a0}\\r\\\\"') == '"\\u{7F}\\u{9F}\xa0\\r\\\\"'


def test_escapes_the_line_and_paragraph_separators() -> None:
    # U+2028 and U+2029 are escaped, as some software splits lines at them; their neighbours are not.
    assert c('"a\u2028b\u2029c"') == '"a\\u{2028}b\\u{2029}c"'
    assert c('"\\u{2027}\\u{2028}\\u{2029}\\u{202F}"') == '"\u2027\\u{2028}\\u{2029}\u202f"'
    assert c('{ "\u2028": 1 }') == '{"\\u{2028}":1}'
    assert haus.parse(c('"\u2028\u2029"')) == String("\u2028\u2029")


def test_sorts_keys_by_code_point() -> None:
    # U+FFFD sorts before U+1F600 by code point (as UTF-16 units it's the other way round).
    assert c('{ "😀": 1, "�": 2, a: 3, "Z": 4 }') == '{"Z":4,a:3,"�":2,"😀":1}'


def test_quotes_keys_that_are_not_identifiers() -> None:
    assert c('{ "a-b": 1, "": 2, "_x9": 3, "9": 4 }') == '{"":2,"9":4,_x9:3,"a-b":1}'


def test_writes_a_single_record_payload_as_tag_braces() -> None:
    assert c("[None, Some(1), Circle({ r: 1 }), Pair({ a: 1 }, 2)]") == "[None,Some(1),Circle{r:1},Pair({a:1},2)]"


def test_writes_a_huge_hex_integer_in_decimal() -> None:
    big = "0x" + "f" * 829  # the most hex digits the default number limit takes
    assert c(big) == str(16**829 - 1)
    assert c("-" + big) == str(1 - 16**829)
    assert len(c("-" + big)) <= 1000


def test_writes_every_integer_in_decimal_whatever_its_length() -> None:
    # Every value has a canonical form (spec §12): an integer of any size is written with all its digits.
    assert haus.canonical(Number("1" + "0" * 1000)) == "1" + "0" * 1000
    assert haus.canonical(Number("1." + "0" * 1000)) == "1." + "0" * 1000
    huge = "-" + "9" * 5000  # built in code, past int's str limit
    assert haus.canonical(Number(huge)) == huge


def test_a_1300_digit_integer_has_a_decimal_canonical_form_and_hash() -> None:
    # Only a parser with a raised number limit, or code, makes one; the reader's limits don't matter.
    digits = "1" + "0" * 1299
    parsed = haus.parse(digits, limits=haus.Limits(max_number_length=2000))
    built = Record({"a": Number(digits)})
    assert haus.canonical(parsed) == digits
    assert haus.canonical(built) == "{a:" + digits + "}"
    want = hashlib.sha256(digits.encode()).hexdigest()
    hashers: list[Callable[[haus.Value], str]] = [
        haus.hash,
        lambda v: haus.hash_all([v]),
    ]
    for h in hashers:
        assert h(parsed) == want
    assert haus.equals(parsed, Number(digits))
    assert not haus.equals(parsed, Number("0"))
    assert haus.compare(parsed, Number("2")) == -1


def test_parses_back_to_the_same_value() -> None:
    v = Record({"s": String('"\n\u202e'), "n": Number("19.90")})
    assert haus.parse(haus.canonical(v)) == v


def test_compare_orders_by_the_bytes_of_the_canonical_forms() -> None:
    vs = haus.parse_all('9, 10, [], "�", "😀", { b: 1, a: 2 }, { a: 2, b: 1 }, Some(1), -1')
    assert [haus.canonical(v) for v in sorted(vs, key=cmp_to_key(haus.compare))] == [
        '"�"',
        '"😀"',
        "-1",
        "10",
        "9",
        "Some(1)",
        "[]",
        "{a:2,b:1}",
        "{a:2,b:1}",
    ]
    assert haus.compare(vs[5], vs[6]) == 0
    assert haus.compare(haus.parse("1.0"), haus.parse("1")) == 1
    assert haus.compare(haus.parse("1"), haus.parse("1.0")) == -1


def test_hash_is_sha256_of_the_canonical_form() -> None:
    assert haus.hash(haus.parse("{ a: 1 }")) == "f09a9231c12685ac5f0b6f0b06c9154f13dc3a5b3548db5142c19bde1383f261"
    assert (
        haus.hash(haus.parse('Order { total: 19.90, id: 0xFF, "x-y": 1e+5, p: Point(1, 2) }'))
        == "d324549b0e26394cc4f2a1fc7ac2647179da2d244c66763381c9cb63dbf8a104"
    )


def test_hash_is_the_same_for_equal_values() -> None:
    a, b = haus.parse_all("{ x: 1, y: [2] }, { y: [ 2, ], x: 1 }")
    assert haus.hash(a) == haus.hash(b)


# ── values built in code: checked as `stringify` checks them, without its limits ──


@pytest.mark.parametrize(
    ("value", "text"),
    [
        (Number("1e+05"), "1e5"),
        (Number("1E5"), "1e5"),
        (Number("0xFF"), "255"),
        (Number("-0x0"), "-0"),
        (Number("1_000"), "1000"),
        (Array((Number("1"), Number("1e+05"))), "[1,1e5]"),
        (Number("1e99999"), "1e99999"),  # beyond the writer's exponent limit: the canonical form has none
    ],
)
def test_normalizes_numbers_built_in_code(value: Value, text: str) -> None:
    parsed = haus.parse(text, limits=Limits(max_exponent=1 << 20))
    assert haus.canonical(value) == text
    assert haus.equals(value, parsed)
    assert haus.hash(value) == haus.hash(parsed)


@pytest.mark.parametrize(
    ("value", "code", "path"),
    [
        (Number("01"), "invalid-number", ()),
        (Number("NaN"), "invalid-number", ()),
        (Number(""), "invalid-number", ()),
        (Number("1\x002"), "invalid-number", ()),
        (Record({"b": Number("1"), "a": Array((Number("1"), Number("01")))}), "invalid-number", ("a", 1)),
        (Variant("lower"), "invalid-tag", ()),
        (Variant("A", (Number("1"), Variant("b"))), "invalid-tag", (1,)),
        (String("x\ud800y"), "cannot-encode", ()),
        (Variant("A", (Record({"x": String("\udc00")}),)), "cannot-encode", ("x",)),
        (Record({"a\ud800": Number("1")}), "cannot-encode", ()),
        (Record(cast("dict[str, Value]", {1: Number("1")})), "cannot-encode", ()),
        (Array(cast("tuple[Value, ...]", (1,))), "cannot-encode", (0,)),
    ],
)
def test_a_value_built_in_code_without_a_text_has_the_writers_error(
    value: Value, code: str, path: tuple[str | int, ...]
) -> None:
    calls: list[Callable[[Value], object]] = [
        haus.canonical,
        haus.hash,
        lambda v: haus.equals(v, v),
        lambda v: haus.compare(v, v),
    ]
    for f in calls:
        with pytest.raises(HausEncodeError) as e:
            f(value)
        assert (e.value.code, e.value.path) == (code, path)
    with pytest.raises(HausEncodeError) as w:
        haus.stringify(value)
    assert w.value.code == code
    with pytest.raises(HausEncodeError) as a:
        haus.hash_all([Number("1"), value])
    assert (a.value.code, a.value.path) == (code, (1, *path))


def test_a_lone_surrogate_never_hashes_like_its_replacement() -> None:
    with pytest.raises(HausEncodeError):
        haus.hash(String("x\ud800y"))
    assert haus.hash(String("x�y")) == hashlib.sha256('"x�y"'.encode()).hexdigest()


def test_a_value_that_contains_itself_is_cyclic() -> None:
    fields: dict[str, Value] = {}
    r = Record(fields)
    fields["a"] = Array((r,))
    with pytest.raises(HausEncodeError) as e:
        haus.canonical(r)
    assert (e.value.code, e.value.path) == ("cyclic-value", ("a", 0))


def test_a_value_built_in_code_may_nest_any_depth() -> None:
    v: Value = Number("1")
    for _ in range(100_000):
        v = Array((v,))
    assert haus.canonical(v) == "[" * 100_000 + "1" + "]" * 100_000
    bad: Value = Number("01")
    for _ in range(10_000):
        bad = Variant("T", (bad, Number("2")))
    with pytest.raises(HausEncodeError) as e:
        haus.canonical(bad)
    assert (e.value.code, e.value.path) == ("invalid-number", (0,) * 10_000)
