"""The codecs of the profile @haus-fmt/geo/wgs84: its vectors (profiles/wgs84.vectors.haus) and its edge cases."""

from __future__ import annotations

import math
from collections.abc import Mapping
from typing import cast

import haus
import pytest
from haus import schema
from haus.schema import HausDecodeError, HausEncodeError, Tagged

import haus_geo

BASE = schema.load_schema(haus_geo.PACKAGE / "schema.haus")
CODED = schema.load_schema(haus_geo.PACKAGE / "schema.haus", codecs=haus_geo.wgs84)

_VECTOR = schema.compile_schema("""
    type Vector = closed <
      Accept { type: String, value: String, output?: String, note?: String }
      | Reject { type: String, value: String, note?: String }
    >
""")["Vector"]
VECTORS = [
    cast(Tagged, _VECTOR.decode(v))
    for v in haus.parse_all((haus_geo.PACKAGE / "profiles/wgs84.vectors.haus").read_text())
]


def _fields(v: Tagged) -> Mapping[str, str]:
    return cast(Mapping[str, str], v.payload)


def _name(v: Tagged) -> str:
    return f"{v.tag} {_fields(v)['type']} {_fields(v)['value']}"


def _normal(type: str, text: str) -> str:
    """The value's canonical text, decoded with the schema alone (spec §15): `38.80` is the float 38.8."""
    return BASE[type].canonical(BASE[type].parse(text))


def test_the_vectors_are_read() -> None:
    assert {v.tag for v in VECTORS} == {"Accept", "Reject"}


@pytest.mark.parametrize("vector", VECTORS, ids=_name)
def test_vector(vector: Tagged) -> None:
    f = _fields(vector)
    coded, base = CODED[f["type"]], BASE[f["type"]]
    base.parse(f["value"])  # valid under the schema: what the codec rejects, the profile rejects
    if vector.tag == "Reject":
        with pytest.raises(HausDecodeError):
            coded.parse(f["value"])
        return
    decoded = coded.parse(f["value"])
    encoded = coded.canonical(decoded)
    assert encoded == _normal(f["type"], f.get("output", f["value"]))
    # The codec changes no value: it writes what the schema alone decodes; decode, encode, decode is decode.
    assert encoded == _normal(f["type"], f["value"])
    assert coded.parse(encoded) == decoded


TRIP = schema.compile_schema(
    "import @haus-fmt/geo (LatLng, BBox)\ntype Trip = { to: LatLng, area: BBox }",
    resolver=schema.FileResolver(".", [haus_geo.PACKAGE]),
    codecs=haus_geo.wgs84,
)["Trip"]


def _at(point: str, area: str = "BBox(LatLng(0, 0), LatLng(1, 1))") -> str:
    return f"{{ to: {point}, area: {area} }}"


ACCEPTED = [
    # Rounding: checked on the decoded float.
    (_at("LatLng(90.00000000000000001, 0)"), _at("LatLng(90, 0)")),
    (_at("LatLng(-90.00000000000000001, 180.00000000000000001)"), _at("LatLng(-90, 180)")),
    # Negative zero is kept, in either position and in a box.
    (_at("LatLng(-0, -0)"), None),
    (_at("LatLng(0, 0)", "BBox(LatLng(-0, -0), LatLng(0, 0))"), None),
    # The poles and the antimeridian are not normalised.
    (_at("LatLng(90, 10)"), None),
    (_at("LatLng(0, -180)"), None),
    (_at("LatLng(0, 180)"), None),
    # Boxes across the antimeridian, and from -180 to 180.
    (_at("LatLng(0, 0)", "BBox(LatLng(0, 170), LatLng(10, -170))"), None),
    (_at("LatLng(0, 0)", "BBox(LatLng(-10, 180), LatLng(10, -180))"), None),
    (_at("LatLng(0, 0)", "BBox(LatLng(-90, -180), LatLng(90, 180))"), None),
]

REJECTED = [
    _at("LatLng(90.0000000000001, 0)"),
    _at("LatLng(0, -180.0000000000001)"),
    _at("LatLng(Infinity, 0)"),
    _at("LatLng(NegInfinity, 0)"),
    _at("LatLng(0, Infinity)"),
    _at("LatLng(0, NegInfinity)"),
    _at("LatLng(NaN, NaN)"),
    _at("LatLng(0, 0)", "BBox(LatLng(1, 0), LatLng(-1, 0))"),
    _at("LatLng(0, 0)", "BBox(LatLng(0, 0), LatLng(10, 181))"),
    _at("LatLng(0, 0)", "BBox(LatLng(NaN, 0), LatLng(10, 0))"),
]


@pytest.mark.parametrize(("text", "output"), ACCEPTED)
def test_edge_cases_accepted(text: str, output: str | None) -> None:
    assert TRIP.canonical(TRIP.parse(text)) == TRIP.canonical(TRIP.parse(output or text))
    assert haus.equals(TRIP.encode(TRIP.parse(text)), TRIP.encode(TRIP.parse(output or text)))


def test_negative_zero_is_kept() -> None:
    trip = cast(Mapping[str, Tagged], TRIP.parse(_at("LatLng(-0, 0)")))
    lat = cast(tuple[float, float], trip["to"].payload)[0]
    assert lat == 0.0 and math.copysign(1.0, lat) == -1.0
    assert TRIP.canonical(trip) == "{area:BBox(LatLng(0,0),LatLng(1,1)),to:LatLng(-0,0)}"


@pytest.mark.parametrize("text", REJECTED)
def test_edge_cases_rejected(text: str) -> None:
    with pytest.raises(HausDecodeError):
        TRIP.parse(text)


def test_messages() -> None:
    with pytest.raises(HausDecodeError, match=r"latitude 91\.0 out of range"):
        TRIP.parse(_at("LatLng(91, 0)"))
    with pytest.raises(HausDecodeError, match="south-west corner"):
        TRIP.parse(_at("LatLng(0, 0)", "BBox(LatLng(1, 0), LatLng(-1, 0))"))


def test_it_checks_what_it_encodes() -> None:
    south, north = Tagged("LatLng", (0.0, 0.0)), Tagged("LatLng", (1.0, 1.0))
    with pytest.raises(HausEncodeError):
        TRIP.encode({"to": Tagged("LatLng", (math.inf, 0.0)), "area": Tagged("BBox", (south, north))})
    with pytest.raises(HausEncodeError):
        TRIP.encode({"to": south, "area": Tagged("BBox", (north, south))})


def test_json_goes_through_the_codecs() -> None:
    with pytest.raises(HausDecodeError, match=r"latitude 91\.0 out of range"):
        TRIP.from_json(
            '{"to": {"_tag": "LatLng", "values": [91, 0]}, "area": {"_tag": "BBox", "values": '
            '[{"_tag": "LatLng", "values": [0, 0]}, {"_tag": "LatLng", "values": [1, 1]}]}}'
        )


def test_a_group_takes_schemas_with_some_of_its_types() -> None:
    point = schema.compile_schema(
        "import @haus-fmt/geo (LatLng)\ntype P = { at: LatLng }",
        resolver=schema.FileResolver(".", [haus_geo.PACKAGE]),
        codecs=haus_geo.wgs84,
    )["P"]
    with pytest.raises(HausDecodeError):
        point.parse("{ at: LatLng(0, 200) }")
