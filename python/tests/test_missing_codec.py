"""`missing-codec` (spec §13.4, "A profile without its codec"): the file's definitions reach a type that an
official profile has a rule for, and no codec is set for its id, so its values are checked for their shape
only."""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path

from haus.schema import Codec, Schema, load_schema

EXTENSIONS = Path(__file__).resolve().parents[2] / "extensions"
PACKAGES = [EXTENSIONS / "money", EXTENSIONS / "geo"]
MONEY = "@haus-fmt/money@1#Money"
CURRENCY = "@haus-fmt/money@1#Currency"
LATLNG = "@haus-fmt/geo@1#LatLng"
BBOX = "@haus-fmt/geo@1#BBox"


class Keep:
    """A codec that keeps the value."""

    def decode(self, value: object, /) -> object:
        return value

    def encode(self, value: object, /) -> object:
        return value


def schema(tmp_path: Path, text: str, codecs: Mapping[str, Codec] | None = None) -> Schema:
    path = tmp_path / "order.schema.haus"
    path.write_text(text, "utf-8")
    return load_schema(path, packages=PACKAGES, codecs=codecs)


def missing(s: Schema) -> list[str]:
    return [w.message.split(" ")[0] for w in s.warnings if w.code == "missing-codec"]


ORDER = """import @haus-fmt/money (Money)
import @haus-fmt/geo (LatLng, BBox)
type Order = { total: Money, at?: Maybe LatLng, area: Array BBox }
"""


def test_each_listed_type_once(tmp_path: Path) -> None:
    s = schema(tmp_path, ORDER)
    # Money reaches Currency, and has no rule of its own; BBox reaches LatLng too: once.
    assert missing(s) == [BBOX, LATLNG, CURRENCY]
    w = s.warnings[2]
    assert w.message == (
        "@haus-fmt/money@1#Currency has profiles (iso), but no codec is set for it: "
        "its values are checked for their shape only"
    )
    assert w.hint.startswith("Add the codec of the profile your application uses")
    # About the codecs, not a place in the file.
    assert (w.line, w.column) == (0, 0)
    assert "line" not in w.to_json() and w.to_json()["code"] == "missing-codec"
    # Only a warning: decoding works as before.
    assert s["Order"].parse("{ total: Money(1, Eur), at: Some(LatLng(91, 0)), area: [] }")["total"] is not None


def test_not_with_its_codec_nor_inside_a_type_with_one(tmp_path: Path) -> None:
    assert missing(schema(tmp_path, ORDER, dict.fromkeys([CURRENCY, LATLNG, BBOX], Keep()))) == []
    # A codec for Money covers its Currency.
    assert missing(schema(tmp_path, ORDER, dict.fromkeys([MONEY, LATLNG, BBOX], Keep()))) == []
    # A codec for BBox covers the LatLngs inside it, not the one of `at`.
    assert missing(schema(tmp_path, ORDER, dict.fromkeys([MONEY, BBOX], Keep()))) == [LATLNG]


def test_only_types_the_files_definitions_reach(tmp_path: Path) -> None:
    # Imported, but no definition uses it.
    assert missing(schema(tmp_path, "import @haus-fmt/geo (LatLng, BBox)\ntype Root = { at: LatLng }\n")) == [LATLNG]
    assert missing(schema(tmp_path, "type Order = { id: Int }")) == []
    # Inside generic types, variants, maps and secrets.
    s = schema(
        tmp_path,
        "import @haus-fmt/money (Currency)\ntype Page a = { items: Array a }\n"
        "type Root = < A (Page (Map (Secret Currency))) | B >\n",
    )
    assert missing(s) == [CURRENCY]


def test_after_the_file_warnings(tmp_path: Path) -> None:
    s = schema(tmp_path, ORDER + "@since(1)\ntype Other = Int\n")
    assert [w.code for w in s.warnings] == ["unknown-attribute"] + ["missing-codec"] * 3
    assert s.file.warnings == s.warnings[:1]
