"""The Python runner of the build, import and string-API fuzzers (fuzz/README.md).

`api_runner.py --build FILE`: each line builds a value with the constructors
(spec §11, "Values built in code"; fuzz/src/build.ts has the instructions) and
writes it: `err CODE` if a constructor rejects it, else `ok C H W`, the
canonical form (hex of UTF-8), the hash and the compact writer's text (hex),
each `!CODE` if it fails. Text is hex of generalized UTF-8: a lone surrogate's
three bytes are that surrogate in a `str`.

`api_runner.py --imports FILE`: each line is `ENTRY ROOT` (hex of UTF-8; ROOT
`-` for none), loaded with `haus.schema.load_schema` and no packages: `ok OWN
IMPORTED` (type names, sorted, joined by `,`; `-` for none) or `err CODE`.

`api_runner.py --strings FILE`: each line is `KIND HEX`, a `str` as hex of its
UTF-16 code units, through the APIs that take a `str` (fuzz/src/strings.ts
has the kinds and outcomes).
"""

from __future__ import annotations

import sys
from collections.abc import Callable
from pathlib import Path

import haus
from haus.schema import HausSchemaFileError, compile_schema, load_schema


def text(h: str) -> str:
    return bytes.fromhex(h).decode("utf-8", "surrogatepass")


def code(e: BaseException) -> str:
    c = getattr(e, "code", None)
    if isinstance(c, str):
        return c
    raise e


# ── --build ──────────────────────────────────────────────────


Make = Callable[[], haus.Value]


def build(tokens: list[str], at: int) -> tuple[Make, int]:
    """The value the tokens start with at `at`, to be built, and where the tokens after it start."""
    kind, *parts = tokens[at].split(":")
    at += 1
    if kind == "n":
        literal = text(parts[0])
        return (lambda: haus.Number(literal)), at
    if kind == "s":
        s = text(parts[0])
        return (lambda: haus.String(s)), at
    if kind == "b":
        data = bytes.fromhex(parts[0])
        return (lambda: haus.Bytes(data)), at
    if kind == "a":
        items: list[Make] = []
        for _ in range(int(parts[0])):
            item, at = build(tokens, at)
            items.append(item)
        return (lambda: haus.Array([f() for f in items])), at
    if kind == "r":
        fields: list[tuple[str, Make]] = []
        for _ in range(int(parts[0])):
            key = text(tokens[at].removeprefix("k:"))
            value, at = build(tokens, at + 1)
            fields.append((key, value))
        return (lambda: haus.Record([(k, f()) for k, f in fields])), at
    if kind == "v":
        tag = text(parts[0])
        args: list[Make] = []
        for _ in range(int(parts[1])):
            arg, at = build(tokens, at)
            args.append(arg)
        return (lambda: haus.Variant(tag, [f() for f in args])), at
    raise ValueError(f"bad token {tokens[at - 1]}")


def attempt(f: Callable[[], str]) -> str:
    try:
        return f()
    except haus.HausError as e:
        return "!" + code(e)


def build_line(line: str) -> str:
    make, _ = build(line.split(), 0)
    try:
        v = make()
    except haus.HausError as e:
        return "err " + code(e)
    canon = attempt(lambda: haus.canonical(v).encode("utf-8").hex())
    digest = attempt(lambda: haus.hash(v))
    written = attempt(lambda: haus.stringify(v, style="compact").encode("utf-8").hex())
    return f"ok {canon} {digest} {written}"


# ── --imports ────────────────────────────────────────────────


def import_line(line: str) -> str:
    entry, root = line.split(" ")
    try:
        schema = load_schema(text(entry), root=None if root == "-" else text(root))
    except HausSchemaFileError as e:
        return "err " + code(e)
    own = sorted(d.name for d in schema.file.definitions)
    imported = sorted(schema.file.imported)
    return f"ok {','.join(own) or '-'} {','.join(imported) or '-'}"


# ── --strings ────────────────────────────────────────────────


def utf16(h: str) -> str:
    return bytes.fromhex(h).decode("utf-16-be", "surrogatepass")


def placed(e: BaseException) -> str:
    return f"err {getattr(e, 'line', 0)} {getattr(e, 'column', 0)} {code(e)}"


def write(make: Callable[[], haus.Value]) -> str:
    try:
        v = make()
    except haus.HausError as e:
        return "!" + code(e)

    def one(f: Callable[[], object]) -> str:
        try:
            f()
        except haus.HausError as e:
            return code(e)
        return "ok"

    ops = [lambda: haus.canonical(v), lambda: haus.hash(v), lambda: haus.stringify(v, style="compact")]
    return "/".join(one(f) for f in ops)


def strings_line(line: str) -> str:
    kind, _, h = line.partition(" ")
    s = utf16(h)
    try:
        if kind == "P":
            return "ok " + (",".join(haus.canonical(v).encode("utf-8").hex() for v in haus.parse_all(s)) or "-")
        if kind == "F":
            return "ok " + haus.format(s, style="pretty").encode("utf-8").hex()
        if kind == "S":
            compile_schema(s)
            return "ok"
        if kind == "J":
            try:
                return "ok " + haus.canonical(haus.import_json(s)).encode("utf-8").hex()
            except haus.HausError as e:
                return "err " + code(e)
        if kind == "W":
            parts = [
                write(lambda: haus.String(s)),
                write(lambda: haus.Record([(s, haus.Number("1"))])),
                write(lambda: haus.Variant(s)),
            ]
            return "ok " + " ".join(parts)
    except haus.HausError as e:
        return placed(e)
    raise ValueError(f"bad kind {kind}")


def main() -> None:
    modes = {"--build": build_line, "--imports": import_line, "--strings": strings_line}
    match sys.argv[1:]:
        case [mode, file] if mode in modes:
            one = modes[mode]
        case _:
            sys.exit("usage: api_runner.py --build|--imports|--strings FILE")
    sys.setrecursionlimit(20000)
    out = sys.stdout
    out.reconfigure(encoding="utf-8", newline="\n", errors="backslashreplace")  # type: ignore[union-attr]
    for line in Path(file).read_text("utf-8").splitlines():
        if line:
            try:
                result = one(line)
            except Exception as e:  # any other exception is a finding, reported on its line
                result = f"crash {type(e).__name__}: {e}"
            out.write(result.replace("\n", " ").replace("\r", " ") + "\n")


if __name__ == "__main__":
    main()
