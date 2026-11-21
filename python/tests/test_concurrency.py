"""One schema, its types and codecs, and the inputs shared by many threads doing everything at once.

Each thread must get what one thread alone gets. With the GIL the threads take turns often (the
switch interval is made small); on a free-threaded CPython (3.13t, 3.14t) they run at once.
"""

from __future__ import annotations

import sys
import threading
import time
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

import haus
from haus import _resolve  # pyright: ignore[reportPrivateUsage]
from haus.schema import Codec, DateCodec, DecimalCodec, FileResolver, InstantCodec, Schema, SchemaType, compile_schema

SCHEMA = """
import std/time (Instant, Date)
type Order = { id: Int, total: Decimal, placed: Instant, due?: Date, items: Array Item, status: Status,
  note: Maybe String, tags: Map Int, key: Secret String }
type Item = { sku: String, price: Float64, qty: Int }
type Status = < Open | Shipped Date | Cancelled { reason: String } >
type Orders = Stream Order
"""

TEXT = """// two orders
{ id: 0x10, total: 19.90, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: 0.10, qty: 2 }],
  status: Shipped(Date("2026-01-03")), note: Some("leave at door"), tags: { a: 1, b: 2 }, key: "k1", extra: "x" },
{ id: 17, total: 1, placed: Instant("2026-01-02T03:04:05+01:00"), due: Date("2026-02-01"), items: [],
  status: Cancelled { reason: "late" }, note: None, tags: {}, key: "k2" },
"""

BAD = [
    '{ id: 1, total: 1, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: "0.10", qty: 1 }],'
    ' status: Open, note: None, tags: {}, key: "k" }',
    '{ id: 1, total: 1, placed: Instant("2026-02-30T00:00:00Z"), items: [], status: Open, note: None, tags: {},'
    ' key: "k" }',
    "[1, 2, { a: }]",
    "{ a: 1, a: 2 }",
]

STYLES: list[haus.Style] = ["pretty", "compact", "minimised"]
THREADS = 8
ROUNDS = 2


@pytest.fixture(autouse=True)
def often_switching() -> Iterator[None]:
    """With the GIL, threads switch every few microseconds instead of every 5 ms."""
    before = sys.getswitchinterval()
    sys.setswitchinterval(1e-5)
    yield
    sys.setswitchinterval(before)


def same_everywhere(run: Callable[[], list[str]]) -> list[str]:
    """`run` in many threads at once, started together: each result must be the one of a single run."""
    want = run()
    start = threading.Barrier(THREADS)

    def each(_: int) -> list[list[str]]:
        start.wait()
        return [run() for _ in range(ROUNDS)]

    with ThreadPoolExecutor(THREADS) as pool:
        for results in pool.map(each, range(THREADS)):
            for got in results:
                assert got == want
    return want


def outcome(f: Callable[[], object]) -> str:
    try:
        return repr(f())
    except Exception as e:  # the error is part of the result
        return f"{type(e).__name__}: {e}"


def everything(schema: Schema) -> list[str]:
    order, orders = schema["Order"], schema["Orders"]
    values = haus.parse_all(TEXT)
    reader = haus.StreamReader()
    out = [
        outcome(lambda: len(values)),
        *(r for style in STYLES for r in in_style(values, style)),
        outcome(lambda: haus.has_comments(TEXT)),
        outcome(lambda: [haus.canonical(x) for x in [*reader.push(TEXT.encode()), *reader.finish()]]),
        *(r for v in values for r in of_value(order, values, v)),
        outcome(lambda: list(orders.decode_all(values))),
        outcome(lambda: list(orders.encode_all(orders.decode_all(values)))),
        outcome(lambda: list(orders.parse_stream([TEXT.encode()]))),
        outcome(lambda: list(orders.from_json_lines("".join(orders.to_json_lines(orders.decode_all(values)))))),
    ]
    return out + [r for text in BAD for r in failing(order, text)]


def in_style(values: list[haus.Value], style: haus.Style) -> list[str]:
    return [
        outcome(lambda: haus.format(TEXT, style=style, width=40)),
        outcome(lambda: haus.stringify_all(values, style=style, width=40)),
    ]


def of_value(order: SchemaType, values: list[haus.Value], v: haus.Value) -> list[str]:
    return [
        outcome(lambda: haus.canonical(v)),
        outcome(lambda: haus.hash(v)),
        outcome(lambda: (haus.equals(v, values[0]), haus.compare(v, values[-1]), v == values[0])),
        outcome(lambda: haus.from_haus_json(haus.to_haus_json(v)) == v),
        outcome(lambda: haus.canonical(haus.import_json(haus.to_haus_json(v)))),
        outcome(lambda: order.decode(v)),
        outcome(lambda: haus.canonical(order.encode(order.decode(v)))),
        outcome(lambda: order.canonical(order.decode(v))),
        outcome(lambda: order.to_json(order.decode(v))),
        outcome(lambda: order.from_json(order.to_json(order.decode(v)))),
        *(typed_text(order, v, style) for style in STYLES),
    ]


def typed_text(order: SchemaType, v: haus.Value, style: haus.Style) -> str:
    return outcome(lambda: order.decode(haus.parse(haus.stringify(v, style=style))))


def failing(order: SchemaType, text: str) -> list[str]:
    return [
        outcome(lambda: haus.parse(text)),
        outcome(lambda: haus.format(text)),
        outcome(lambda: order.parse(text)),
    ]


def test_a_shared_schema_and_inputs() -> None:
    schema = compile_schema(SCHEMA)
    results = same_everywhere(lambda: everything(schema))
    assert len(results) > 50
    assert not any(r.startswith("HausDecodeError") for r in results[: -3 * len(BAD)])


def test_a_shared_schema_with_codecs() -> None:
    codecs: dict[str, Codec] = {
        "std/time#Date": DateCodec(),
        "std/time#Instant": InstantCodec(),
        "prelude#Decimal": DecimalCodec(),
    }
    schema = compile_schema(SCHEMA, codecs=codecs)
    same_everywhere(lambda: everything(schema))


def test_schemas_built_at_once() -> None:
    """Building is per call; schemas built by many threads at once decode alike."""
    same_everywhere(lambda: everything(compile_schema(SCHEMA)))


def test_a_shared_resolver_reads_each_file_once(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Threads loading schemas with one new FileResolver: each file is read once, and every schema is the same."""
    for name in ("money", "geo"):
        package = tmp_path / "packages" / name
        package.mkdir(parents=True)
        (package / "package.haus").write_text(f'{{ name: "@acme/{name}", version: "1.0.0" }}', "utf-8")
        (package / "schema.haus").write_text(f"type {name.title()} = < {name.title()} String >\n", "utf-8")
    text = "import @acme/money (Money)\nimport @acme/geo (Geo)\ntype T = { m: Money, g: Geo }"

    def load(resolver: FileResolver) -> str:
        return outcome(lambda: compile_schema(text, resolver=resolver)["T"].parse('{ m: Money("EUR"), g: Geo("x") }'))

    want = load(FileResolver(tmp_path, folders=[tmp_path / "packages"]))
    reads: list[str] = []
    read_file = _resolve._read_file  # pyright: ignore[reportPrivateUsage]

    def slow_read(path: Path, *args: object, **kwargs: object) -> bytes:
        reads.append(str(path))
        time.sleep(0.002)  # a slow disk: the threads meet here
        return read_file(path, *args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(_resolve, "_read_file", slow_read)
    shared = FileResolver(tmp_path, folders=[tmp_path / "packages"])
    start = threading.Barrier(THREADS)

    def each(_: int) -> str:
        start.wait()
        return load(shared)

    with ThreadPoolExecutor(THREADS) as pool:
        assert list(pool.map(each, range(THREADS))) == [want] * THREADS
    assert len(reads) == 4  # two manifests, two schemas
    assert sorted(reads) == sorted(set(reads))
