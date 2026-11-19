# Profile `@haus-fmt/geo/wgs84`, version 1

The rule of this profile (spec §13.3, "Profiles"). The test vectors in
[`wgs84.vectors.haus`](wgs84.vectors.haus) are examples of it; where they
disagree with this text, the vectors are wrong.

Points and boxes on the earth, in degrees of the WGS 84 datum, latitude first.
The rule is stated on the values the schema decoded (spec §15): a `Float64`
is the float the literal rounds to, never the literal itself.

## `LatLng(lat, lng)`

A codec implementing this profile accepts a `LatLng` exactly when:

- `lat` is a float with −90 ≤ `lat` ≤ 90, and
- `lng` is a float with −180 ≤ `lng` ≤ 180.

So:

- `NaN`, `Infinity` and `NegInfinity` are rejected in either position.
- The range is checked on the decoded float. `LatLng(90.00000000000000001, 0)`
  decodes to the float 90 and is accepted; it encodes back as `LatLng(90, 0)`.
- Negative zero is accepted and kept: `LatLng(-0, 0)` encodes back as
  `LatLng(-0, 0)`. The codec doesn't change the value.
- The poles and the antimeridian are not normalised: `LatLng(90, 10)` and
  `LatLng(90, 20)` are different values, and so are longitudes −180 and 180.

## `BBox(sw, ne)`

A box from its south-west corner `sw` to its north-east corner `ne`. A codec
accepts a `BBox` exactly when:

- both corners are accepted as `LatLng` (above), and
- `sw.lat` ≤ `ne.lat`, compared as numbers (`-0` equals `0`).

The longitudes are not ordered: a box with `sw.lng` > `ne.lng` crosses the
antimeridian, as in GeoJSON (RFC 7946 §5.2). `BBox(LatLng(0, 170),
LatLng(10, -170))` is the box 20 degrees wide around longitude 180.

Longitudes −180 and 180 are different values and are never compared with
each other: `BBox(LatLng(0, 180), LatLng(10, -180))` has `sw.lng` > `ne.lng`,
so it crosses the antimeridian, with zero width.

## Encoding

A codec writes back exactly the floats it decoded, in the spelling of spec
§15 ("Floats"), so a value it accepted encodes to the same value.

A value that breaks the rule is a decoding error with the code
`type-mismatch`, at the value's place (spec §15). A codec checks the rule when
encoding too: a host value that breaks it is not written (`cannot-encode`).
