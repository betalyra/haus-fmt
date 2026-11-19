"""The schema-file fuzzing runner (fuzz/README.md, "Schema files"):
`schema_check_runner.py FILE` reads lines `HEX` (a schema file's bytes as hex),
reads each with `haus.schema.compile_schema` (std modules only, no resolver),
and prints one line each: `ok`, or `err <line> <column> <code> <reason>`, the
position of the error (`0 0` for none) and its code (spec §17)."""

from __future__ import annotations

import sys
from pathlib import Path

from haus.schema import HausSchemaFileError, compile_schema


def outcome(hex_text: str) -> str:
    try:
        text = bytes.fromhex(hex_text).decode("utf-8")
    except UnicodeDecodeError:
        return "err 0 0 invalid-utf8 invalid UTF-8"
    try:
        compile_schema(text)
    except HausSchemaFileError as e:
        return f"err {e.line} {e.column} {e.code} {e.reason}"
    except RecursionError:
        return "crash RecursionError"
    return "ok"


def main() -> None:
    match sys.argv[1:]:
        case [file]:
            pass
        case _:
            sys.exit("usage: schema_check_runner.py FILE")
    out = sys.stdout
    out.reconfigure(encoding="utf-8", newline="\n", errors="backslashreplace")  # type: ignore[union-attr]
    for line in Path(file).read_text("utf-8").splitlines():
        if line:
            out.write(outcome(line).replace("\n", " ").replace("\r", " ") + "\n")


if __name__ == "__main__":
    main()
