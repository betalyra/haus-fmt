"""The haus schema package @haus-fmt/geo (`LatLng`, `BBox`), with the codecs of its profile `wgs84`.

    import haus_geo
    from haus import schema

    s = schema.load_schema("trip.schema.haus", packages=[haus_geo.PACKAGE], codecs=haus_geo.wgs84)
    s["Trip"].parse("{ to: LatLng(38.7223, -9.1393) }")  # {'to': Tagged(tag='LatLng', payload=(38.7223, -9.1393))}
    s["Trip"].parse("{ to: LatLng(91, 0) }")  # HausDecodeError: latitude out of range

The profile's rule is `profiles/wgs84.md` in the package directory. The codecs keep the value and the default
host type (spec §13.4): `Tagged("LatLng", (lat, lng))` of floats as decoded, `-0.0` included, the poles and the
antimeridian not normalised. They only reject more.
"""

from __future__ import annotations

from pathlib import Path

from haus.schema import CodecGroup, Tagged

__all__ = ["BBOX", "LAT_LNG", "PACKAGE", "Wgs84BBox", "Wgs84LatLng", "bbox_problem", "lat_lng_problem", "wgs84"]


def _package() -> Path:
    here = Path(__file__).resolve().parent
    # A wheel has the package's files next to this module; a source checkout has them in the extension's directory.
    return here if (here / "package.haus").is_file() else here.parents[2]


PACKAGE: Path = _package()
"""The schema package's directory (`package.haus`, `schema.haus`, `profiles/`): pass it as one of `packages`."""

LAT_LNG = "@haus-fmt/geo@1#LatLng"
BBOX = "@haus-fmt/geo@1#BBox"


def _args(value: object, tag: str) -> tuple[object, ...] | None:
    """The two arguments of `Tag(a, b)` as the schema decodes it, if `value` is one."""
    if isinstance(value, Tagged) and value.tag == tag and isinstance(value.payload, tuple) and len(value.payload) == 2:
        return value.payload
    return None


def _within(x: object, low: float, high: float) -> bool:
    """A float in [low, high]; NaN and the infinities are not."""
    return isinstance(x, float) and low <= x <= high


def lat_lng_problem(point: object) -> str | None:
    """Why the wgs84 profile rejects a `LatLng`, or None: -90 ≤ lat ≤ 90 and -180 ≤ lng ≤ 180."""
    if (p := _args(point, "LatLng")) is None:
        return "not a LatLng"
    lat, lng = p
    if not _within(lat, -90.0, 90.0):
        return f"latitude {lat!r} out of range: the wgs84 profile takes -90 to 90"
    if not _within(lng, -180.0, 180.0):
        return f"longitude {lng!r} out of range: the wgs84 profile takes -180 to 180"
    return None


def bbox_problem(box: object) -> str | None:
    """Why the wgs84 profile rejects a `BBox`, or None: both corners are accepted and `sw.lat` ≤ `ne.lat`.

    The longitudes aren't ordered: `sw.lng` > `ne.lng` crosses the antimeridian.
    """
    if (b := _args(box, "BBox")) is None:
        return "not a BBox"
    sw, ne = b
    if (corner := lat_lng_problem(sw) or lat_lng_problem(ne)) is not None:
        return f"a corner: {corner}"
    assert isinstance(sw, Tagged) and isinstance(ne, Tagged) and isinstance(sw.payload, tuple)
    assert isinstance(ne.payload, tuple)
    sw_lat, ne_lat = sw.payload[0], ne.payload[0]
    assert isinstance(sw_lat, float) and isinstance(ne_lat, float)
    if sw_lat > ne_lat:
        return f"the south-west corner (latitude {sw_lat!r}) is north of the north-east one ({ne_lat!r})"
    return None


class Wgs84LatLng:
    """`LatLng` with the wgs84 profile: the default host type, `Tagged("LatLng", (lat, lng))`, checked."""

    def decode(self, value: object, /) -> object:
        if (why := lat_lng_problem(value)) is not None:
            raise ValueError(why)
        return value

    encode = decode


class Wgs84BBox:
    """`BBox` with the wgs84 profile: the default host type, `Tagged("BBox", (sw, ne))`, checked, corners included."""

    def decode(self, value: object, /) -> object:
        if (why := bbox_problem(value)) is not None:
            raise ValueError(why)
        return value

    encode = decode


wgs84: CodecGroup = CodecGroup({LAT_LNG: Wgs84LatLng(), BBOX: Wgs84BBox()})
"""The profile's codecs, by type id. A group: a schema with only one of the types takes it too."""
