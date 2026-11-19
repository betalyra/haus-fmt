"""The profile fuzzing runner (fuzz/README.md, "Profiles"): `profile_runner.py FILE`
reads lines `TYPE HEX` (a value's haus text as hex-encoded UTF-8), decodes the
value with the type of its package's schema and the codecs of the official
profile (haus_money.iso for Money and Currency, haus_geo.wgs84 for LatLng and
BBox), encodes the result, and prints one line each: `ok <canonical form>` or
`err <place> <code> <reason>` (`-` for an input that isn't one value). Encoding
what was decoded must work, so an encode error is printed as `crash …`."""

from __future__ import annotations

import sys
from importlib import import_module
from pathlib import Path

import haus
from haus import schema
from haus.schema import CodecGroup, HausDecodeError, HausEncodeError, SchemaType, format_path

ROOT = Path(__file__).resolve().parents[2]


def package(name: str, codecs: str) -> tuple[Path, CodecGroup]:
    """An extension's Python package (haus_money, haus_geo), from the checkout: its directory, its codecs."""
    sys.path.insert(0, str(ROOT / "extensions" / name.removeprefix("haus_") / "python" / "src"))
    module = import_module(name)
    return module.PACKAGE, getattr(module, codecs)


def schemas() -> dict[str, SchemaType]:
    """Each type with a profile, from its package's schema file with the profile's codecs."""
    money_dir, iso = package("haus_money", "iso")
    geo_dir, wgs84 = package("haus_geo", "wgs84")
    money = schema.load_schema(money_dir / "schema.haus", codecs=iso)
    geo = schema.load_schema(geo_dir / "schema.haus", codecs=wgs84)
    return {"Money": money["Money"], "Currency": money["Currency"], "LatLng": geo["LatLng"], "BBox": geo["BBox"]}


def outcome(types: dict[str, SchemaType], line: str) -> str:
    type_name, _, hex_text = line.partition(" ")
    t = types.get(type_name)
    if t is None:
        return f"crash no type {type_name}"
    try:
        values = haus.parse_bytes(bytes.fromhex(hex_text))
    except haus.HausSyntaxError as e:
        return f"err $ - not a single value: {e}"
    if len(values) != 1:
        return "err $ - not a single value"
    try:
        decoded = t.decode(values[0])
    except HausDecodeError as e:
        return f"err {format_path(e.path)} {e.code} {e.reason}"
    try:
        return "ok " + haus.canonical(t.encode(decoded))
    except HausEncodeError as e:
        return f"crash encoding failed: {e}"


def main() -> None:
    match sys.argv[1:]:
        case [file]:
            pass
        case _:
            sys.exit("usage: profile_runner.py FILE")
    types = schemas()
    out = sys.stdout
    out.reconfigure(encoding="utf-8", newline="\n")  # type: ignore[union-attr]
    for line in Path(file).read_text("utf-8").splitlines():
        if line:
            out.write(outcome(types, line).replace("\n", " ").replace("\r", " ") + "\n")


if __name__ == "__main__":
    main()
