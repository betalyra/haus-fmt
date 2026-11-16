"""The public API, limits, error positions and the Python-specific edge cases."""

from __future__ import annotations

import sys
from collections.abc import Callable
from decimal import Decimal
from typing import TypeVar

import pytest

import haus
from haus import Array, Bytes, Limits, Number, Record, String, Variant
from haus._parser import max_hex_digits

T = TypeVar("T")


def error(text: str, limits: Limits = haus.DEFAULT_LIMITS) -> haus.HausSyntaxError:
    with pytest.raises(haus.HausSyntaxError) as info:
        haus.parse_all(text, limits=limits)
    return info.value


def test_parse_reads_one_value() -> None:
    assert haus.parse('{ name: "Ada", tags: [A, B(1)] }') == Record(
        {"name": String("Ada"), "tags": Array((Variant("A"), Variant("B", (Number("1"),))))}
    )


def test_parse_rejects_a_stream() -> None:
    with pytest.raises(haus.HausSyntaxError, match="expected exactly one value, found 2"):
        haus.parse("1, 2")
    with pytest.raises(haus.HausSyntaxError, match="found 0"):
        haus.parse("// nothing")


def test_equality_follows_the_spec() -> None:
    assert haus.parse("{ a: 1, b: 2 }") == haus.parse("{ b: 2, a: 1 }")
    assert haus.parse("Tag { a: 1 }") == haus.parse("Tag({ a: 1 })")
    assert haus.parse("0xFF") == haus.parse("255")
    assert haus.parse("1E+05") == Number("1e5")
    assert haus.parse("1.0") != haus.parse("1")
    assert haus.parse('x"0B 34"') == Bytes(b"\x0b\x34")


def test_numbers_convert_exactly() -> None:
    assert haus.parse("1_000").to_int() == 1000  # type: ignore[union-attr]
    assert str(Number("19.90").to_decimal()) == "19.90"
    with pytest.raises(ValueError):
        Number("1e5").to_int()


def test_columns_count_code_points() -> None:
    e = error('{ "😀": 1, x: ? }')
    assert (e.line, e.column, e.offset) == (1, 14, 13)
    assert str(e) == "expected a value, found '?' at 1:14"


def test_invalid_utf8_is_located() -> None:
    with pytest.raises(haus.HausSyntaxError) as info:
        haus.parse_bytes(b'[1,\n "\xc3\x28"]')
    assert (info.value.reason, info.value.line, info.value.column) == ("invalid UTF-8", 2, 3)


def test_byte_order_mark_only_at_the_start() -> None:
    assert haus.parse_bytes(b"\xef\xbb\xbf1") == [Number("1")]
    assert error("1,\ufeff2").reason == "expected a value, found '\ufeff'"


def test_limits_are_configurable() -> None:
    assert error("[[[1]]]", Limits(max_depth=2)).reason == "nesting deeper than 2 levels"
    assert error("12345", Limits(max_number_length=4)).reason == "number literal longer than 4 characters"
    assert error("1e11", Limits(max_exponent=10)).reason == "exponent larger than 10"
    assert error('"abcd"', Limits(max_string_length=3)).reason == "string longer than 3 characters"
    assert error('x"0102 0304"', Limits(max_string_length=8)).reason == "byte string longer than 8 characters"


def test_the_string_limit_counts_keys_and_tags() -> None:
    """A record key or tag of exactly the limit is accepted, one more is an error at its start (spec §7)."""
    four = Limits(max_string_length=4)
    assert haus.parse("{ abcd: Abcd, a: Abcd(1), b: Abcd { c: 1 } }", limits=four) is not None
    e = error("{ a: 1,\n  abcde: 1 }", four)
    assert (e.reason, e.line, e.column) == ("key longer than 4 characters", 2, 3)
    for text, column in (("Abcde", 1), ("[1, Abcde(1)]", 5), ("{ a: Abcde { b: 1 } }", 6)):
        e = error(text, four)
        assert (e.reason, e.column) == ("tag longer than 4 characters", column)
    # A quoted key is a string: the string error, at its quote.
    e = error('{ "abcde": 1 }', four)
    assert (e.reason, e.column) == ("string longer than 4 characters", 3)


def test_the_string_limit_counts_keys_and_tags_in_streams() -> None:
    four = Limits(max_string_length=4)
    assert len(list(haus.parse_stream(["{ abcd: Abcd },\n"], limits=four))) == 1
    with pytest.raises(haus.HausSyntaxError) as info:
        list(haus.parse_stream(["1,\n{ ab", "cde: 1 },"], limits=four))
    assert (info.value.reason, info.value.line, info.value.column) == ("key longer than 4 characters", 2, 3)
    with pytest.raises(haus.HausSyntaxError) as info:
        list(haus.parse_stream(["1,\n2,\n  Abcde,"], limits=four))
    assert (info.value.reason, info.value.line, info.value.column) == ("tag longer than 4 characters", 3, 3)


def test_max_depth_is_at_most_the_supported_depth() -> None:
    assert haus.MAX_SUPPORTED_DEPTH == 512
    assert Limits(max_depth=512).max_depth == 512
    with pytest.raises(ValueError, match=r"^max_depth 513 is above 512, the deepest nesting this binding supports"):
        Limits(max_depth=513)
    for bad in (-1, 1.5, True):
        with pytest.raises(ValueError, match="max_depth must be a whole number from 0 to 512"):
            Limits(max_depth=bad)  # type: ignore[arg-type]


def nested_call(frames: int, f: Callable[[], T]) -> T:
    """`f()`, called `frames` Python frames deeper than here."""
    return f() if frames == 0 else nested_call(frames - 1, f)


def test_the_supported_depth_fits_however_deep_the_caller_is() -> None:
    """Python's recursion limit is raised as needed: 512 levels parse even from 900 frames deep."""
    deepest = "A(" * 128 + "{ a: [" * 192 + "1" + "] }" * 192 + ")" * 128
    assert nested_call(900, lambda: haus.parse(deepest, limits=Limits(max_depth=512))) is not None
    stream = list(nested_call(900, lambda: haus.parse_stream([deepest + ","], limits=Limits(max_depth=512))))
    assert len(stream) == 1


def test_recursion_limit_is_a_syntax_error(monkeypatch: pytest.MonkeyPatch) -> None:
    """Should the stack still run out, the error is a syntax error, not a crash."""

    def no_room(max_depth: int) -> None:
        pass

    monkeypatch.setattr("haus._parser.make_room", no_room)
    old = sys.getrecursionlimit()
    sys.setrecursionlimit(200)
    try:
        e = error("[" * 300 + "]" * 300, Limits(max_depth=512))
    finally:
        sys.setrecursionlimit(old)
    assert "recursion limit" in e.reason


def test_huge_hex_beyond_cpython_digit_limit() -> None:
    # 4000 hex digits are about 4800 decimal digits: more than CPython's int-to-str limit.
    value = haus.parse("0x" + "f" * 4000, limits=Limits(max_number_length=5000))
    assert isinstance(value, Number)
    assert value.text == str(Decimal(16**4000 - 1))


def test_a_hex_literal_has_at_most_829_hex_digits() -> None:
    # The largest h with 16**h <= 10**999 (spec §7): every integer that parses fits 1000 characters in decimal.
    for sign in ("", "-"):
        value = haus.parse(sign + "0x" + "f" * 829)
        assert isinstance(value, Number)
        assert value.text == sign + str(16**829 - 1)
        assert len(value.text) <= 1000
        e = error(sign + "0x" + "f" * 830)
        assert (e.code, e.reason, e.column) == ("number-too-long", "hex literal with more than 829 hex digits", 1)
    # Leading zeros count, `_` separators don't.
    assert error("0x" + "0" * 830).code == "number-too-long"
    separated = "0x" + "_".join(["f" * 100] * 8 + ["f" * 29])  # 829 digits, 8 separators
    assert haus.parse(separated) == haus.parse("0x" + "f" * 829)
    # Binary literals need no limit of their own: 998 binary digits are 301 decimal ones.
    assert isinstance(haus.parse("0b" + "1" * 998), Number)


def test_the_hex_digit_limit_follows_the_number_limit() -> None:
    assert [max_hex_digits(n) for n in (1, 2, 3, 12, 1000, 2000)] == [0, 0, 1, 9, 829, 1660]
    for n in range(1, 1500):
        h = max_hex_digits(n)
        assert 16**h <= 10 ** (n - 1) < 16 ** (h + 1)
    assert isinstance(haus.parse("0x" + "f" * 9, limits=Limits(max_number_length=12)), Number)
    assert error("0x" + "f" * 10, Limits(max_number_length=12)).code == "number-too-long"
    assert error("0x" + "f" * 10, Limits(max_number_length=12)).reason == "hex literal with more than 9 hex digits"


def test_huge_exponent_is_checked_without_converting() -> None:
    e = error("1e" + "9" * 5000, Limits(max_number_length=6000))
    assert e.reason == "exponent larger than 6144"
