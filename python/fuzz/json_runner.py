"""The JSON fuzzing runner (fuzz/README.md, "JSON"): `json_runner.py MODE FILE`
reads one case per line and prints one line each, `ok …` or `err <reason>`:

- `write`: `SUITE TYPE HEX` (haus text): decode with the type, `to_json` (spec §16.3);
- `read`: `SUITE TYPE HEX` (JSON bytes): `from_json` with the type, encode: the canonical form;
- `lossless-write`: `HEX` (haus text): `haus.to_lossless_json` (§16.2);
- `lossless-read`: `HEX` (JSON bytes): `haus.from_lossless_json`, the canonical form;
- `schemaless`: `HEX` (JSON bytes): `haus.from_json` (§16.1), the canonical form.

The JSON is given to the binding as bytes. Errors the API documents print as
`err`; encoding what was read must work, so an encode error there is `crash`."""

from __future__ import annotations

import sys
from pathlib import Path

import haus
from haus.schema import HausDecodeError, HausEncodeError, HausJsonError, Schema, compile_schema

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIRS = (
    ROOT / "test-suite" / "schema",
    ROOT / "fuzz" / "schema",
    ROOT / "test-suite" / "json",
    ROOT / "fuzz" / "json",
)
ERRORS = (HausDecodeError, HausEncodeError, HausJsonError, haus.HausSyntaxError)


def schemas() -> dict[str, Schema]:
    """Every schema file of the fuzzer, by suite name."""
    return {
        p.name.removesuffix(".schema.haus"): compile_schema(p.read_text("utf-8"))
        for d in SCHEMA_DIRS
        for p in sorted(d.glob("*.schema.haus"))
    }


def single(data: bytes) -> haus.Value | str:
    try:
        values = haus.parse_bytes(data)
    except haus.HausSyntaxError as e:
        return f"err not a single value: {e}"
    return values[0] if len(values) == 1 else "err not a single value"


def outcome(compiled: dict[str, Schema], mode: str, line: str) -> str:
    parts = line.split(" ")
    match mode, parts:
        case (("write" | "read"), [suite, type_name, hex_text]):
            schema = compiled.get(suite)
            if schema is None or type_name not in schema:
                return f"crash no type {suite}.{type_name}"
            t = schema[type_name]
            data = bytes.fromhex(hex_text)
            if mode == "write":
                v = single(data)
                if isinstance(v, str):
                    return v
                try:
                    return "ok " + t.to_json(t.decode(v))
                except ERRORS as e:
                    return f"err {e}"
            try:
                read = t.from_json(data)
            except ERRORS as e:
                return f"err {e}"
            try:
                return "ok " + haus.canonical(t.encode(read))
            except HausEncodeError as e:
                return f"crash encoding what was read failed: {e}"
        case "lossless-write", [hex_text]:
            v = single(bytes.fromhex(hex_text))
            if isinstance(v, str):
                return v
            try:
                return "ok " + haus.to_lossless_json(v)
            except ERRORS as e:
                return f"err {e}"
        case (("lossless-read" | "schemaless"), [hex_text]):
            read_json = haus.from_lossless_json if mode == "lossless-read" else haus.from_json
            try:
                return "ok " + haus.canonical(read_json(bytes.fromhex(hex_text)))
            except ERRORS as e:
                return f"err {e}"
        case _:
            return f"crash bad line for {mode}"


def main() -> None:
    match sys.argv[1:]:
        case [mode, file]:
            pass
        case _:
            sys.exit("usage: json_runner.py MODE FILE")
    compiled = schemas()
    out = sys.stdout
    out.reconfigure(encoding="utf-8", newline="\n", errors="backslashreplace")  # type: ignore[union-attr]
    for line in Path(file).read_text("utf-8").splitlines():
        if line:
            try:
                result = outcome(compiled, mode, line)
            except RecursionError:
                result = "crash RecursionError"
            out.write(result.replace("\n", "\\n").replace("\r", "\\r") + "\n")


if __name__ == "__main__":
    main()
