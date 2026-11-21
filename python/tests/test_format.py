"""The formatter and the value writers (spec §11) beyond the format suite: options, errors, comments,
and values built in code."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

import haus
from haus import Array, Bytes, Limits, Number, Record, String, Style, Value, Variant
from haus.schema import HausEncodeError

SUITE = Path(__file__).resolve().parents[2] / "test-suite"
STYLES: tuple[Style, ...] = ("pretty", "compact", "minimised")
INVALID = sorted((SUITE / "invalid").glob("*.haus"))
VALID = sorted((SUITE / "valid").glob("*.haus"))


def error(f: Any, *args: Any, **kwargs: Any) -> haus.HausSyntaxError:
    with pytest.raises(haus.HausSyntaxError) as e:
        f(*args, **kwargs)
    return e.value


@pytest.mark.parametrize("path", INVALID, ids=lambda p: p.stem)
def test_errors_are_the_parsers(path: Path) -> None:
    """Invalid text: the parser's error, with its code and position, in every layout."""
    data = path.read_bytes()
    expected = error(haus.parse_bytes, data)
    for style in STYLES:
        e = error(haus.format, data, style=style)
        assert (e.code, e.line, e.column, e.reason) == (expected.code, expected.line, expected.column, expected.reason)
    e = error(haus.has_comments, data)
    assert (e.code, e.line, e.column) == (expected.code, expected.line, expected.column)


def test_limits_apply() -> None:
    assert error(haus.format, "[[1]]", limits=Limits(max_depth=1)).code == "nesting-too-deep"
    assert error(haus.format, "12345", style="compact", limits=Limits(max_number_length=4)).code == "number-too-long"
    deep = "[" * haus.MAX_SUPPORTED_DEPTH + "]" * haus.MAX_SUPPORTED_DEPTH
    out = haus.format(deep, indent=0, limits=Limits(max_depth=haus.MAX_SUPPORTED_DEPTH))
    assert out.count("\n") == 2 * haus.MAX_SUPPORTED_DEPTH - 1
    assert haus.format(deep, style="minimised", limits=Limits(max_depth=haus.MAX_SUPPORTED_DEPTH)) == deep + "\n"


def test_indent_and_width_are_taken_as_given() -> None:
    """An indent of 0 doesn't indent; with a width of 0 nothing fits on a line."""
    text = "{ a: [1], m: Money(7.90, EUR) }"
    assert haus.format(text, indent=0) == "{\na: [\n1,\n],\nm: Money(7.90, EUR),\n}\n"
    assert haus.format(text, width=0) == "{\n  a: [\n    1,\n  ],\n  m: Money(\n    7.90,\n    EUR,\n  ),\n}\n"
    assert haus.format("Point(1, 2)", indent=0, width=0) == "Point(\n1,\n2,\n)\n"
    assert haus.stringify(Variant("A", (Variant("B"),)), indent=0, width=0) == "A(\nB,\n)"


def test_width_counts_code_points_and_the_comma() -> None:
    assert haus.format('[P(1, "😀")]', width=12) == '[\n  P(1, "😀"),\n]\n'
    assert haus.format('[P(1, "😀")]', width=11) == '[\n  P(\n    1,\n    "😀",\n  ),\n]\n'
    assert haus.format('P(1, "😀")', width=9) == 'P(1, "😀")\n'  # a single item has no comma


@pytest.mark.parametrize(
    ("options", "message"),
    [
        ({"style": "pretty-ish"}, "style must be"),
        ({"indent": -1}, "indent must be"),
        ({"width": -1}, "width must be"),
        ({"indent": True}, "indent must be"),
        ({"width": 1.5}, "width must be"),
        ({"indent": 1.5}, "indent must be"),
        ({"indent": -2, "width": 40}, "indent must be"),
    ],
)
def test_options_are_checked(options: dict[str, Any], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        haus.format("1", **options)
    with pytest.raises(ValueError, match=message):
        haus.stringify(Number("1"), **options)


def test_bytes_must_be_utf8() -> None:
    expected = error(haus.parse_bytes, b'{ a: "\xff" }')
    e = error(haus.format, b'{ a: "\xff" }')
    assert (e.code, e.line, e.column) == (expected.code, expected.line, expected.column) == ("invalid-utf8", 1, 7)
    assert haus.format(b"\xef\xbb\xbf{ a: 1 }", style="compact") == "{ a: 1 }\n"  # the byte order mark is skipped


def test_comments() -> None:
    text = """\
// above
{
  a: 1, // after a
  /* between */ b /* key */ : /* colon */ 2,

  // at the end
}
"""
    assert (
        haus.format(text)
        == """\
// above
{
  a: 1, // after a
  /* between */
  /* key */
  /* colon */
  b: 2,

  // at the end
}
"""
    )
    assert haus.format(text, style="compact") == "{ a: 1, b: 2 }\n"
    assert haus.has_comments(text)
    assert not haus.has_comments('{ a: "// not a comment", b: x"00" }')
    assert haus.has_comments("/* only a comment */")
    assert haus.format("/* only a comment */") == "/* only a comment */\n"
    assert haus.format("/* only a comment */", style="compact") == ""
    assert haus.format("") == haus.format("  \n\n") == ""


def test_record_payload_in_parentheses() -> None:
    """`Tag({ … })` is written `Tag { … }`; comments between the brackets move inside the braces."""
    text = "Tag( // why\n{ a: 1 } // after\n)"
    assert haus.format(text) == "Tag {\n  // why\n  a: 1, // after\n}\n"
    assert haus.format(text, style="minimised") == "Tag{a:1}\n"


def test_spellings() -> None:
    text = '{ "n": 0xFF, b: x"0B 34", s: "\\u{41}\\n", t: """\n  one\n  two \n  """, "x-y": 1_000 }'
    assert haus.format(text, style="minimised") == '{n:0xFF,b:x"0B 34",s:"\\u{41}\\n",t:"one\\ntwo ","x-y":1_000}\n'
    assert haus.format(text) == (
        '{\n  n: 0xFF,\n  b: x"0B 34",\n  s: """\n    A\n\n    """,\n  t: """\n    one\n    two\\u{20}\n    """,\n'
        '  "x-y": 1_000,\n}\n'
    )


def test_streams() -> None:
    text = "{ a: 1 }, B, C(1)\n// end"
    assert haus.format(text) == "{\n  a: 1,\n},\n\nB,\nC(1),\n// end\n"
    assert haus.format(text, style="compact") == "{ a: 1 },\nB,\nC(1),\n"
    assert haus.format("A,", style="compact") == "A\n"


# ── values built in code ─────────────────────────────────────


@pytest.mark.parametrize("path", VALID, ids=lambda p: p.stem)
def test_written_values_read_back(path: Path) -> None:
    """Every layout writes the values of the suite as text that reads back as them, and is formatted."""
    values = haus.parse_bytes(path.read_bytes())
    canonical = [haus.canonical(v) for v in values]
    for style in STYLES:
        for indent, width in ((2, 80), (0, 0), (4, 20)):
            out = haus.stringify_all(values, style=style, indent=indent, width=width)
            assert [haus.canonical(v) for v in haus.parse_all(out)] == canonical
            assert haus.format(out, style=style, indent=indent, width=width) == out
            assert [haus.stringify(v, style=style, indent=indent, width=width) for v in values] == [
                haus.stringify_all([v], style=style, indent=indent, width=width)[:-1] for v in values
            ]


def test_written_values() -> None:
    order = Record(
        {
            "id": Number("7"),
            "note": String("line\nnext "),
            "data": Bytes(b"\x0b\x34"),
            "x-y": Variant("Point", (Number("1E+05"), Number("0xFF"))),
            "tags": Array(()),
            "p": Variant("P", (Record({}),)),
        }
    )
    assert haus.stringify(order, style="compact") == (
        '{ id: 7, note: "line\\nnext ", data: x"0b34", "x-y": Point(1e5, 255), tags: [], p: P {} }'
    )
    assert haus.stringify(order, style="minimised") == (
        '{id:7,note:"line\\nnext ",data:x"0b34","x-y":Point(1e5,255),tags:[],p:P{}}'
    )
    assert haus.stringify(order) == (
        '{\n  id: 7,\n  note: """\n    line\n    next\\u{20}\n    """,\n  data: x"0b34",\n'
        '  "x-y": Point(1e5, 255),\n  tags: [],\n  p: P {},\n}'
    )
    assert haus.stringify_all([]) == ""
    assert haus.stringify_all([Variant("A"), Array((Number("1"),))]) == "A,\n[\n  1,\n],\n"
    assert haus.stringify_all(iter([Variant("A")]), style="compact") == "A\n"


def encode_error(values: list[Any], limits: Limits = haus.DEFAULT_LIMITS) -> HausEncodeError:
    with pytest.raises(HausEncodeError) as e:
        haus.stringify_all(values, limits=limits)
    for style in ("compact", "minimised"):
        with pytest.raises(HausEncodeError) as again:
            haus.stringify_all(values, style=style, limits=limits)
        assert (again.value.code, again.value.path) == (e.value.code, e.value.path)
    return e.value


def test_values_outside_the_limits() -> None:
    # Values are haus values by construction (spec §11): what fails is the limits.
    def fails(value: Any, code: str, path: tuple[str | int, ...] = (), limits: Limits = haus.DEFAULT_LIMITS) -> None:
        e = encode_error([value], limits)
        assert (e.code, e.path) == (code, path), e.reason

    fails(Array((Number("1" * 1001),)), "number-too-long", (0,))
    fails(Number("1e7000"), "exponent-too-large")
    fails(Array((Array(()),)), "nesting-too-deep", (0,), Limits(max_depth=1))
    fails(Variant("T", (Record({"a": Array(())}),)), "nesting-too-deep", ("a",), Limits(max_depth=1))
    assert haus.stringify(Variant("T", (Record({}),)), limits=Limits(max_depth=1)) == "T {}"
    # In a stream, the path starts with the value's index.
    e = encode_error([Variant("A"), Number("1e7000")])
    assert (e.code, e.path) == ("exponent-too-large", (1,))


def test_writers_check_the_string_key_and_tag_lengths() -> None:
    """Spec §11: in code points, as the parser counts them; a byte string as its hex digits."""
    short = Limits(max_string_length=3)

    def fails(value: Any, code: str, path: tuple[str | int, ...] = ()) -> None:
        e = encode_error([value], short)
        assert (e.code, e.path) == (code, path), e.reason

    fails(Array((String("abcd"),)), "string-too-long", (0,))
    fails(Record({"abcd": Number("1")}), "key-too-long")
    fails(Record({"a": Variant("Abcd")}), "tag-too-long", ("a",))
    fails(Variant("T", (Bytes(b"ab"),)), "string-too-long", (0,))
    # An emoji is one character, also where a language stores it as two units.
    within = Array((String("😀😀😀"), Bytes(b"a"), Variant("Abc"), Record({"abc": String("")})))
    assert haus.stringify(within, style="minimised", limits=short) == '["😀😀😀",x"61",Abc,{abc:""}]'


def shared(levels: int) -> Value:
    """An array holding the same array twice, `levels` deep: small in memory, 2**(levels + 1) - 1 values written."""
    v: Value = Array(())
    for _ in range(levels):
        v = Array((v, v))
    return v


def test_writers_count_each_place_a_shared_part_is_in() -> None:
    """Spec §7, "Values written": the value, and every element, field value and argument, each as often
    as it is written; at most `max_nodes` for each top-level value, else `too-many-nodes` at it."""
    assert haus.stringify(shared(2), style="minimised", limits=Limits(max_nodes=7)) == "[[[],[]],[[],[]]]"
    e = encode_error([shared(2)], Limits(max_nodes=6))
    assert (e.code, e.path) == ("too-many-nodes", ())
    # A record payload is an argument: `T { a: 1 }` writes three values.
    payload = Variant("T", (Record({"a": Number("1")}),))
    assert haus.stringify(payload, style="compact", limits=Limits(max_nodes=3)) == "T { a: 1 }"
    assert encode_error([payload], Limits(max_nodes=2)).code == "too-many-nodes"
    # Each top-level value on its own, at its index in a stream.
    assert haus.stringify_all([shared(2), shared(2)], style="minimised", limits=Limits(max_nodes=7))
    e = encode_error([Number("1"), shared(3)], Limits(max_nodes=7))
    assert (e.code, e.path) == ("too-many-nodes", (1,))
    # The default is 64 Mi values.
    assert haus.DEFAULT_LIMITS.max_nodes == 64 * 1024 * 1024
