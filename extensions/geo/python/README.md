# haus-fmt-geo

The haus schema package [`@haus-fmt/geo`](https://github.com/betalyra/haus-fmt/tree/main/extensions/geo)
(`LatLng`, `BBox`) for Python, with the codecs of its profile `wgs84`. Imported as `haus_geo`.

```sh
pip install haus-fmt-geo
```

```haus-schema
// trip.schema.haus
import @haus-fmt/geo (LatLng, BBox)
type Trip = { to: LatLng, area: BBox }
```

```python
import haus_geo
from haus import schema

s = schema.load_schema("trip.schema.haus", packages=[haus_geo.PACKAGE], codecs=haus_geo.wgs84)
s["Trip"].parse("{ to: LatLng(38.7223, -9.1393), area: BBox(LatLng(0, 170), LatLng(10, -170)) }")
s["Trip"].parse("{ to: LatLng(91, 0), area: … }")  # HausDecodeError: latitude 91.0 out of range
```

`haus_geo.PACKAGE` is the package's directory (`package.haus`, `schema.haus`, `profiles/`).
`haus_geo.wgs84` is the profile's codecs (a `schema.CodecGroup`; combine groups with `|`): a
`LatLng` is accepted when −90 ≤ lat ≤ 90 and −180 ≤ lng ≤ 180 (NaN and the infinities are not), a
`BBox` when both corners are and `sw.lat` ≤ `ne.lat` (a box with `sw.lng` > `ne.lng` crosses the
antimeridian). The range is checked on the decoded float: `LatLng(90.00000000000000001, 0)` is the
float 90 and accepted. The codecs keep the value and the default host type,
`Tagged("LatLng", (lat, lng))` of floats, `-0.0` included. The rule: [`profiles/wgs84.md`](https://github.com/betalyra/haus-fmt/tree/main/extensions/geo/profiles/wgs84.md).
