"""The JSON fuzzing runner (fuzz/README.md, "JSON"): `json_runner.py MODE FILE`
reads one case per line and prints one line each, `ok …` or `err <reason>`:

- `write`: `SUITE TYPE HEX` (haus text): decode with the type, `to_json`: schema-based JSON (spec §16.3);
- `read`: `SUITE TYPE HEX` (JSON bytes): `from_json` with the type, encode: the canonical form;
- `haus-json-write`: `HEX` (haus text): `haus.to_haus_json`, self-describing JSON in its envelope (§16.2);
- `haus-json-read`: `HEX` (JSON bytes): `haus.from_haus_json` (an envelope), the canonical form;
- `import`: `HEX` (JSON bytes): `haus.import_json` (§16.1), the canonical form.

The JSON is given to the binding as bytes. Errors the API documents print as
`err <place> <code> <reason>`: the place in the value (`$.items[2].price`, `$`
for an error in the text) and the code (spec §17; `-` for an input that isn't
one value). Encoding what was read must work, so an encode error there is `crash`."""

from __future__ import annotations

import sys
from pathlib import Path

import haus
from haus.schema import HausDecodeError, HausEncodeError, HausJsonError, Schema, compile_schema, format_path

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
        return f"err $ - not a single value: {e}"
    return values[0] if len(values) == 1 else "err $ - not a single value"


def err(e: haus.HausError) -> str:
    """`err <place> <code> <reason>`: an error in a value at its path, one in JSON or haus text at `$`."""
    path = e.path if isinstance(e, HausDecodeError | HausEncodeError | HausJsonError) else ()
    return f"err {format_path(path)} {e.code} {e.reason}"


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
                    return err(e)
            try:
                read = t.from_json(data)
            except ERRORS as e:
                return err(e)
            try:
                return "ok " + haus.canonical(t.encode(read))
            except HausEncodeError as e:
                return f"crash encoding what was read failed: {e}"
        case "haus-json-write", [hex_text]:
            v = single(bytes.fromhex(hex_text))
            if isinstance(v, str):
                return v
            try:
                return "ok " + haus.to_haus_json(v)
            except ERRORS as e:
                return err(e)
        case (("haus-json-read" | "import"), [hex_text]):
            read_json = haus.from_haus_json if mode == "haus-json-read" else haus.import_json
            try:
                return "ok " + haus.canonical(read_json(bytes.fromhex(hex_text)))
            except ERRORS as e:
                return err(e)
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
