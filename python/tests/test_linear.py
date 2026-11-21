"""The parser, the canonical writer and the decoder take time linear in the input (spec §7, §9.8),
as go/linear_test.go checks for Go: a duplicate-key check that scans a list, rereading the text
from every error, or copying a container at every level would make crafted inputs quadratic.

Each case runs at n and at 4n; linear time grows about 4x, quadratic 16x, and the test asks for
less than 8x. The best of a few runs of each counts, and a busy machine gets a few more tries.
"""

from __future__ import annotations

import gc
import time
from collections.abc import Callable

import pytest

import haus
from haus import Limits, Record, String, Value, Variant
from haus.schema import compile_schema

RUNS = 5
TRIES = 4
MIN_RUN = 0.020
"""The shortest time one measured run lasts, in seconds."""
DEEP = Limits(max_depth=haus.MAX_SUPPORTED_DEPTH)


def fastest(f: Callable[[], object]) -> float:
    """The shortest time per call of `f` over `RUNS` runs, with the garbage collector off as `timeit`
    has it: a collection during a run costs time for every object alive, not for the work being timed.

    Each run starts after a collection, and repeats the call until it lasts at least `MIN_RUN`: a clock
    that ticks coarsely (Windows) would measure a fast call as 0 and make any ratio huge.
    """
    best = float("inf")
    collecting = gc.isenabled()
    gc.disable()
    try:
        for _ in range(RUNS):
            gc.collect()
            calls, start = 0, time.perf_counter()
            while calls == 0 or time.perf_counter() - start < MIN_RUN:
                f()
                calls += 1
            best = min(best, (time.perf_counter() - start) / calls)
    finally:
        if collecting:
            gc.enable()
    return best


def assert_linear(n: int, work: Callable[[int], Callable[[], object]]) -> None:
    small, large = work(n), work(4 * n)
    # Warm up both sizes: caches (of key texts, compiled patterns) are filled before anything is timed.
    small()
    large()
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


FORMAT_CASES: dict[str, tuple[int, Callable[[int], str]]] = {
    "many keys": (5_000, lambda n: joined(n, "{ ", " }", lambda i: f'k{i}: "v{i}"')),
    "long line": (20_000, lambda n: joined(n, "[", "]", lambda i: str(i % 10))),
    "long string": (50_000, lambda n: '"' + "abc\\n\\u{1F600}é" * (n // 10) + '"'),
    "wide payload": (5_000, lambda n: joined(n, "P(", ")", lambda i: f"Q({i}, R)")),
    "deep nesting": (100, lambda n: "[" * n + "]" * n),
    "deep payloads": (100, lambda n: "Some(" * n + "1" + ")" * n),
    "deep record payloads": (60, lambda n: "T({ a: " * n + "1" + " })" * n),  # two levels each
    "many comments": (2_000, lambda n: joined(n, "[", "]", lambda i: f"/* {i} */ {i} // x\n\n")),
    "stream": (5_000, lambda n: "".join(f"{{ a: [{i}] }},\n" for i in range(n))),
    "long comments": (100, lambda n: "// " + "x" * (100 * n) + "\n/* " + "y\n" * (10 * n) + "*/ 1"),
}


@pytest.mark.parametrize("style", ["pretty", "compact", "minimised"])
@pytest.mark.parametrize("name", FORMAT_CASES)
def test_format_is_linear(name: str, style: haus.Style) -> None:
    """Formatting text takes time linear in the text. The pretty layout indents nothing here: with
    indentation, the text of deep nesting is itself quadratic in the depth."""
    n, text = FORMAT_CASES[name]

    def work(n: int) -> Callable[[], object]:
        t = text(n)
        return lambda: haus.format(t, style=style, indent=0, limits=DEEP)

    assert_linear(n, work)


@pytest.mark.parametrize("style", ["pretty", "compact", "minimised"])
def test_writing_is_linear(style: haus.Style) -> None:
    def record(n: int) -> Value:
        return Record({f"key {i}": String("a\tb") for i in range(n)})

    def nested(n: int) -> Value:
        v: Value = Variant("Leaf", (haus.Number("1"),))
        for i in range(n):
            v = Variant("Some", (haus.Array((v,)), haus.Number(str(i))))
        return v

    def writing(v: Value) -> Callable[[], object]:
        return lambda: haus.stringify(v, style=style, indent=0, limits=DEEP)

    assert_linear(5_000, lambda n: writing(record(n)))
    assert_linear(60, lambda n: writing(nested(n)))  # two levels each
