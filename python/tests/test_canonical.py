"""The canonical form, equality, hashing and order (spec §12)."""

from __future__ import annotations

import hashlib
from collections.abc import Callable
from functools import cmp_to_key
from typing import cast

import pytest

import haus
from haus import Array, Bytes, HausEncodeError, Limits, Number, Record, String, Value, Variant
from haus.schema import compile_schema


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


# ── values built in code: normalized and checked by the constructors (spec §11), so nothing here fails ──


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
def test_numbers_built_in_code_are_normalized(value: Value, text: str) -> None:
    parsed = haus.parse(text, limits=Limits(max_exponent=1 << 20))
    assert haus.canonical(value) == text
    assert value == parsed
    assert haus.equals(value, parsed)
    assert haus.hash(value) == haus.hash(parsed)


def test_built_values_have_a_canonical_form_hash_and_order() -> None:
    v = Record(
        [
            ("b", Array([Number("1"), String("x\u2028y"), Bytes(bytearray(b"\x0b"))])),
            ("a", Variant("Tag", [Record({"z": Number("0b11")})])),
        ]
    )
    assert haus.canonical(v) == '{a:Tag{z:3},b:[1,"x\\u{2028}y",x"0b"]}'
    assert haus.equals(v, haus.parse(haus.canonical(v)))
    assert haus.hash(v) == haus.hash_all([v])
    assert haus.compare(v, v) == 0


@pytest.mark.parametrize(
    ("build", "code"),
    [
        (lambda: Number("01"), "invalid-number"),
        (lambda: Number("NaN"), "invalid-number"),
        (lambda: Number(""), "invalid-number"),
        (lambda: Number("1\x002"), "invalid-number"),
        (lambda: Number(cast("str", 5)), "cannot-encode"),
        (lambda: Number(cast("str", 1.5)), "cannot-encode"),
        (lambda: Number("1\ud800"), "cannot-encode"),
        (lambda: Variant("lower"), "invalid-tag"),
        (lambda: Variant(""), "invalid-tag"),
        (lambda: Variant("A-B"), "invalid-tag"),
        (lambda: Variant("A\ud800"), "cannot-encode"),
        (lambda: Variant(cast("str", None)), "cannot-encode"),
        (lambda: Variant("A", cast("tuple[Value, ...]", (1,))), "cannot-encode"),
        (lambda: Record([("a", Number("1")), ("a", Number("2"))]), "duplicate-key"),
        (lambda: Record({"a\ud800": Number("1")}), "cannot-encode"),
        (lambda: Record([("\udc00", Number("1"))]), "cannot-encode"),
        (lambda: Record(cast("dict[str, Value]", {1: Number("1")})), "cannot-encode"),
        (lambda: Record(cast("dict[str, Value]", {"a": 1})), "cannot-encode"),
        (lambda: Record(cast("list[tuple[str, Value]]", [("a", Number("1"), Number("2"))])), "cannot-encode"),
        (lambda: Record(cast("dict[str, Value]", 5)), "cannot-encode"),
        (lambda: String("x\ud800y"), "cannot-encode"),
        (lambda: String("\udc00"), "cannot-encode"),
        (lambda: String(cast("str", b"x")), "cannot-encode"),
        (lambda: Bytes(cast("bytes", "x")), "cannot-encode"),
        (lambda: Array(cast("tuple[Value, ...]", (object(),))), "cannot-encode"),
        (lambda: Array(cast("tuple[Value, ...]", (Number("1"), "2"))), "cannot-encode"),
        (lambda: Array(cast("tuple[Value, ...]", 5)), "cannot-encode"),
    ],
)
def test_a_constructor_rejects_what_is_no_haus_value(build: Callable[[], Value], code: str) -> None:
    with pytest.raises(HausEncodeError) as e:
        build()
    assert (e.value.code, e.value.path) == (code, ())


def test_constructors_take_any_iterable_and_keep_their_own_copy() -> None:
    items = [Number("1")]
    fields = {"a": Number("1")}
    a, r, v = Array(items), Record(fields), Variant("T", iter(items))
    items.append(Number("2"))
    fields["b"] = Number("2")
    assert (a.items, v.args, dict(r.fields)) == ((Number("1"),), (Number("1"),), {"a": Number("1")})
    assert Record([("a", Number("1"))]) == r == Record({"a": Number("1")})
    assert Bytes(memoryview(b"ab")).data == b"ab"
    assert type(Bytes(bytearray(b"ab")).data) is bytes


def test_a_value_never_changes() -> None:
    r = Record({"a": Number("1")})
    with pytest.raises(TypeError):
        cast("dict[str, Value]", r.fields)["a"] = r  # a read-only view: no record can contain itself
    with pytest.raises(AttributeError):
        r.fields = {}  # type: ignore[misc]
    with pytest.raises(AttributeError):
        Number("1").text = "01"  # type: ignore[misc]
    with pytest.raises(TypeError):

        class _Mine(Number):  # type: ignore[misc]
            pass


def test_a_lone_surrogate_never_hashes_like_its_replacement() -> None:
    with pytest.raises(HausEncodeError):
        String("x\ud800y")
    assert haus.hash(String("x�y")) == hashlib.sha256('"x�y"'.encode()).hexdigest()


def test_a_value_built_in_code_may_nest_any_depth() -> None:
    v: Value = Number("1")
    for _ in range(100_000):
        v = Array((v,))
    assert haus.canonical(v) == "[" * 100_000 + "1" + "]" * 100_000
    assert haus.equals(v, v)


def test_only_the_node_limit_applies() -> None:
    """Spec §12: a value deeper or longer than a writer's limits still has a canonical form."""
    tight = Limits(max_depth=1, max_string_length=1, max_number_length=2, max_exponent=1)
    v = Record({"key": Array((Array((String("long"), Number("1e99"), Variant("Tag"))),))})
    assert haus.canonical(v, limits=tight) == '{key:[["long",1e99,Tag]]}'
    assert haus.hash(v, limits=tight) == haus.hash(v)


def shared(levels: int) -> Value:
    """An array holding the same array twice, `levels` deep: small in memory, 2**(levels + 1) - 1 values written."""
    v: Value = Array(())
    for _ in range(levels):
        v = Array((v, v))
    return v


def deep(levels: int, innermost: str) -> Value:
    """A value built in code `levels` deep: arrays and variants with record payloads, in turn."""
    v: Value = String(innermost)
    for i in range(levels):
        v = Array((v,)) if i % 2 == 0 else Variant("T", (Record({"a": v}),))
    return v


def test_any_depth_has_a_canonical_form_a_hash_and_an_order() -> None:
    """Spec §12: canonical, hash, hash_all, equals and compare work at any depth (no maximum)."""
    a, b, c = deep(100_000, "x"), deep(100_000, "x"), deep(100_000, "y")
    text = haus.canonical(a)
    assert text == "T{a:[" * 50_000 + '"x"' + "]}" * 50_000
    assert haus.hash(a) == haus.hash(b) == haus.hash_all([a])
    assert haus.equals(a, b)
    assert not haus.equals(a, c)
    assert haus.compare(a, b) == 0
    assert haus.compare(a, c) == -1
    assert haus.compare(c, a) == 1


def node_error(f: Callable[[], object]) -> tuple[str, tuple[str | int, ...]]:
    with pytest.raises(HausEncodeError) as e:
        f()
    return e.value.code, e.value.path


def test_the_node_limit_counts_each_place_a_shared_part_is_in() -> None:
    """Spec §7, "Values written": `too-many-nodes`, at the value, above `max_nodes`."""
    seven, six = Limits(max_nodes=7), Limits(max_nodes=6)
    assert haus.canonical(shared(2), limits=seven) == "[[[],[]],[[],[]]]"
    assert node_error(lambda: haus.canonical(shared(2), limits=six)) == ("too-many-nodes", ())
    assert node_error(lambda: haus.hash(shared(2), limits=six)) == ("too-many-nodes", ())
    assert node_error(lambda: haus.equals(shared(2), shared(2), limits=six)) == ("too-many-nodes", ())
    assert node_error(lambda: haus.compare(shared(2), shared(1), limits=six)) == ("too-many-nodes", ())
    # The message says which operand (spec §12).
    with pytest.raises(HausEncodeError, match="second"):
        haus.equals(shared(1), shared(2), limits=six)
    with pytest.raises(HausEncodeError, match="first"):
        haus.compare(shared(2), shared(1), limits=six)
    # Each value of a list on its own, at its index.
    assert haus.hash_all([shared(2), shared(2)], limits=seven) == haus.hash_all([shared(2), shared(2)])
    assert node_error(lambda: haus.hash_all([shared(1), shared(2)], limits=six)) == ("too-many-nodes", (1,))
    # Numbers, written at once, count too; a record payload is one value, its field values more.
    assert node_error(lambda: haus.canonical(Array((Number("1"),) * 7), limits=seven)) == ("too-many-nodes", ())
    payload = Variant("T", (Record({"a": Number("1"), "b": Number("2")}),))
    assert haus.canonical(payload, limits=Limits(max_nodes=4)) == "T{a:1,b:2}"
    assert node_error(lambda: haus.canonical(payload, limits=Limits(max_nodes=3)))[0] == "too-many-nodes"
    assert haus.DEFAULT_LIMITS.max_nodes == 64 * 1024 * 1024


def test_encoders_with_a_schema_have_the_node_limit_too() -> None:
    t = compile_schema("type T = Any")["T"]
    assert t.canonical(shared(2), limits=Limits(max_nodes=7)) == "[[[],[]],[[],[]]]"
    assert node_error(lambda: t.canonical(shared(2), limits=Limits(max_nodes=6))) == ("too-many-nodes", ())
    items = t.encode_all([shared(1), shared(2)], limits=Limits(max_nodes=6))
    assert node_error(lambda: list(items)) == ("too-many-nodes", (1,))


def test_the_json_writer_has_the_node_limit_too() -> None:
    assert haus.to_haus_json(shared(1), limits=Limits(max_nodes=3)) == '{"_haus":1,"_value":[[],[]]}'
    assert node_error(lambda: haus.to_haus_json(shared(2), limits=Limits(max_nodes=6))) == ("too-many-nodes", ())
    lines = haus.to_haus_json_lines([shared(1), shared(2)], limits=Limits(max_nodes=6))
    assert node_error(lambda: list(lines)) == ("too-many-nodes", (1,))
