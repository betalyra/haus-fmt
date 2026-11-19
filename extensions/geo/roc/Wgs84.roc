## The profile @haus-fmt/geo/wgs84 (../profiles/wgs84.md) as a codec (spec
## §13.4) for `@haus-fmt/geo@1#LatLng`: `LatLng(38.7223, -9.1393)` ↔
## `{ lat: 38.7223, lng: -9.1393 }`. A point is accepted exactly when
## −90 ≤ lat ≤ 90 and −180 ≤ lng ≤ 180 (so not NaN or an infinity). The
## floats are kept as decoded: `-0` stays `-0`, and the poles and the
## antimeridian are not normalised.
import HausFmtGeo

Wgs84 := [].{

	## Degrees north and east.
	Target : { lat : F64, lng : F64 }

	decode : HausFmtGeo.LatLng -> Try(Target, Str)
	decode = |lat_lng| match lat_lng {
		LatLng(lat, lng) => point(lat, lng)
	}

	encode : Target -> HausFmtGeo.LatLng
	encode = |{ lat, lng }| LatLng(lat, lng)

	## The point at `lat`, `lng`, if the profile accepts it.
	point : F64, F64 -> Try(Target, Str)
	point = |lat, lng|
		if !(lat >= -90.0 and lat <= 90.0) {
			Err("latitude ${lat.to_str()} out of range: the wgs84 profile takes -90 to 90")
		} else if !(lng >= -180.0 and lng <= 180.0) {
			Err("longitude ${lng.to_str()} out of range: the wgs84 profile takes -180 to 180")
		} else {
			Ok({ lat, lng })
		}
}
