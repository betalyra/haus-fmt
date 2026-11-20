"""The parser, the canonical writer and the decoder take time linear in the input (spec §7, §9.8),
as go/linear_test.go checks for Go: a duplicate-key check that scans a list, rereading the text
from every error, or copying a container at every level would make crafted inputs quadratic.

Each case runs at n and at 4n; linear time grows about 4x, quadratic 16x, and the test asks for
less than 8x. The best of a few runs of each counts, and a busy machine gets a few more tries.
"""

from __future__ import annotations

import time
from collections.abc import Callable

import pytest

import haus
from haus import Limits, Record, String, Value, Variant
from haus.schema import compile_schema

RUNS = 5
TRIES = 4
DEEP = Limits(max_depth=haus.MAX_SUPPORTED_DEPTH)


def fastest(f: Callable[[], object]) -> float:
    best = float("inf")
    for _ in range(RUNS):
        start = time.perf_counter()
        f()
        best = min(best, time.perf_counter() - start)
    return best


def assert_linear(n: int, work: Callable[[int], Callable[[], object]]) -> None:
    small, large = work(n), work(4 * n)
    ratio = 0.0
    for _ in range(TRIES):
        ratio = fastest(large) / max(fastest(small), 1e-6)
        if ratio < 8:
            return
    pytest.fail(f"4x the input took {ratio:.1f}x the time")


def joined(n: int, open_: str, close: str, entry: Callable[[int], str]) -> str:
    return open_ + ", ".join(map(entry, range(n))) + close


def parsing(text: str, limits: Limits = haus.DEFAULT_LIMITS) -> Callable[[], object]:
    return lambda: haus.parse_all(text, limits=limits)


def failing(text: str) -> Callable[[], object]:
    """Text that is valid up to its very end: the error is found after the whole text is read twice."""

    def run() -> None:
        with pytest.raises(haus.HausSyntaxError):
            haus.parse_all(text)

    return run


PARSE_CASES: dict[str, tuple[int, Callable[[int], str], Limits]] = {
    "many keys": (5_000, lambda n: joined(n, "{ ", " }", lambda i: f"k{i}: {i}"), haus.DEFAULT_LIMITS),
    "keys alike": (5_000, lambda n: joined(n, "{ ", " }", lambda i: f"{'a' * 40}{i:08}: 1"), haus.DEFAULT_LIMITS),
    "many small records": (
        2_000,
        lambda n: joined(n, "[", "]", lambda i: f'{{ a: {i}, b: "x", c: None, d: Some([1, 2]) }}'),
        haus.DEFAULT_LIMITS,
    ),
    "long string": (50_000, lambda n: '"' + "abc\\n\\u{1F600}é" * (n // 10) + '"', haus.DEFAULT_LIMITS),
    "deep nesting": (100, lambda n: "[" * n + "]" * n, DEEP),
    "deep payloads": (100, lambda n: "Some(" * n + "1" + ")" * n, DEEP),
    "many short values": (10_000, lambda n: joined(n, "[", "]", lambda i: str(i % 10)), haus.DEFAULT_LIMITS),
    "comments": (2_000, lambda n: joined(n, "[", "]", lambda i: f"/* {i} */ {i} // x\n"), haus.DEFAULT_LIMITS),
}


@pytest.mark.parametrize("name", PARSE_CASES)
def test_parse_is_linear(name: str) -> None:
    n, text, limits = PARSE_CASES[name]
    assert_linear(n, lambda n: parsing(text(n), limits))


ERROR_CASES: dict[str, Callable[[int], str]] = {
    "unclosed": lambda n: joined(n, "[", "", lambda i: f'{{ a: {i}, b: "x" }}'),
    "duplicate key at the end": lambda n: joined(n, "{ ", ", k0: 1 }", lambda i: f"k{i}: {i}"),
}


@pytest.mark.parametrize("name", ERROR_CASES)
def test_errors_are_found_in_linear_time(name: str) -> None:
    assert_linear(2_000, lambda n: failing(ERROR_CASES[name](n)))


def test_canonical_is_linear() -> None:
    def record(n: int) -> Value:
        return Record({f"key {i}": String("a\tb") for i in range(n)})

    def nested(n: int) -> Value:
        v: Value = haus.Array(())
        for _ in range(n):
            v = Variant("Some", (haus.Array((v,)),))
        return v

    assert_linear(5_000, lambda n: (lambda v: lambda: haus.canonical(v))(record(n)))
    assert_linear(1_000, lambda n: (lambda v: lambda: haus.canonical(v))(nested(n)))


def test_decode_is_linear() -> None:
    s = compile_schema("type T = Array { a: Int, b: String, c: Maybe (Array Float64) }")

    def text(n: int) -> str:
        return joined(n, "[", "]", lambda i: f'{{ a: {i}, b: "x{i}", c: Some([1.5, {i}]) }}')

    assert_linear(1_000, lambda n: (lambda t: lambda: s["T"].parse(t))(text(n)))
