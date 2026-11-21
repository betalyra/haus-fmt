"""The fuzzing runner (fuzz/README.md): `runner.py [--stream | --canonical] DIR N`
parses DIR/00000.haus … DIR/{N-1}.haus and prints one line each: `ok <values>`
in the test-suite JSON encoding, or `err <line> <column> <code> <reason>` (the
error code of spec §17).
With `--stream`, each file goes through the stream reader in chunks (see
`chunks`); with `--canonical`, `ok` is followed by the canonical form of each
value (spec §12) as a JSON array of strings.

The formatter fuzzer's modes (`main.ts --format`):

- `--format STYLE --indent N --width N`: `ok` and `haus.format`'s output as a JSON string;
- `--write STYLE --indent N --width N`: `ok {"values": [...], "file": ...}`, each value written
  alone by `haus.stringify` and all of them by `haus.stringify_all`, as JSON strings; a value
  that can't be written is `err 0 0 <code> <reason>`."""

from __future__ import annotations

import json
import sys
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any, cast

import haus
from haus import Array, Bytes, Number, Record, String, Value, Variant
from haus.schema import HausEncodeError


def suite_json(v: Value) -> object:
    match v:
        case String(s):
            return s
        case Number(text):
            return {"num": text}
        case Bytes(data):
            return {"bytes": data.hex()}
        case Array(items):
            return [suite_json(x) for x in items]
        case Record(fields):
            return {"rec": {k: suite_json(x) for k, x in fields.items()}}
        case Variant(tag, ()):
            return {"tag": tag}
        case Variant(tag, args):
            return {"tag": tag, "args": [suite_json(x) for x in args]}


def chunks(data: bytes, i: int) -> Iterator[bytes]:
    """The chunks of case `i`, the same in every runner: chunk k has size
    SIZES[(i + k) % 7], so cuts fall inside escapes, comments and UTF-8 sequences."""
    sizes = [1, 2, 3, 5, 8, 13, 64]
    at = k = 0
    while at < len(data):
        end = at + sizes[(i + k) % 7]
        yield data[at:end]
        at, k = end, k + 1


def syntax_error(e: haus.HausSyntaxError) -> str:
    return f"err {e.line} {e.column} {e.code} {e.reason.replace(chr(10), ' ')}"


def line(read: Callable[[], list[Value]], encode: Callable[[Value], object] = suite_json) -> str:
    try:
        values = read()
    except haus.HausSyntaxError as e:
        return syntax_error(e)
    return "ok " + json.dumps([encode(v) for v in values], separators=(",", ":"))


def formatted(data: bytes, options: dict[str, Any]) -> str:
    try:
        return "ok " + json.dumps(haus.format(data, **options))
    except haus.HausSyntaxError as e:
        return syntax_error(e)


def written(data: bytes, options: dict[str, Any]) -> str:
    try:
        values = haus.parse_bytes(data)
    except haus.HausSyntaxError as e:
        return syntax_error(e)
    try:
        each = [haus.stringify(v, **options) for v in values]
        file = haus.stringify_all(values, **options)
    except HausEncodeError as e:
        return f"err 0 0 {e.code} {e.reason.replace(chr(10), ' ')}"
    return "ok " + json.dumps({"values": each, "file": file})


def run(mode: str, data: bytes, i: int, options: dict[str, Any]) -> str:
    match mode:
        case "--stream":
            return line(lambda: list(haus.parse_stream(chunks(data, i))))
        case "--canonical":
            return line(lambda: haus.parse_bytes(data), haus.canonical)
        case "--format":
            return formatted(data, options)
        case "--write":
            return written(data, options)
        case _:
            return line(lambda: haus.parse_bytes(data))


USAGE = (
    "usage: runner.py [--stream | --canonical | --format STYLE --indent N --width N"
    " | --write STYLE --indent N --width N] DIR N"
)


def main() -> None:
    options: dict[str, Any] = {}
    match sys.argv[1:]:
        case [("--stream" | "--canonical") as mode, directory, count]:
            pass
        case [("--format" | "--write") as mode, style, "--indent", indent, "--width", width, directory, count]:
            options = {"style": cast(haus.Style, style), "indent": int(indent), "width": int(width)}
        case [directory, count]:
            mode = ""
        case _:
            sys.exit(USAGE)
    out = sys.stdout
    out.reconfigure(encoding="utf-8", newline="\n")  # type: ignore[union-attr]
    for i in range(int(count)):
        out.write(run(mode, (Path(directory) / f"{i:05}.haus").read_bytes(), i, options) + "\n")


if __name__ == "__main__":
    main()
