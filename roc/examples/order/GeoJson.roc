## A codec (spec §13.4) for `@haus-fmt/geo@1#LatLng`, in GeoJSON order:
## `LatLng(38.7223, -9.1393)` ↔ `(-9.1393, 38.7223)`. The swap happens here, once.
import geo.HausFmtGeo

GeoJson := [].{
	## (longitude, latitude)
	Target : (F64, F64)

	decode : HausFmtGeo.LatLng -> Try(Target, Str)
	decode = |point| match point {
		LatLng(lat, lng) => Ok((lng, lat))
	}

	encode : Target -> HausFmtGeo.LatLng
	encode = |(lng, lat)| LatLng(lat, lng)
}
