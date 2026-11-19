## The profile @haus-fmt/geo/wgs84 (../profiles/wgs84.md) as a codec (spec
## §13.4) for `@haus-fmt/geo@1#BBox`: `BBox(LatLng(0, 170), LatLng(10, -170))`
## ↔ `{ sw: { lat: 0, lng: 170 }, ne: { lat: 10, lng: -170 } }`. A box is
## accepted exactly when both corners are (Wgs84) and sw.lat ≤ ne.lat. The
## longitudes aren't ordered: sw.lng > ne.lng crosses the antimeridian.
import HausFmtGeo
import Wgs84

Wgs84BBox := [].{

	## The south-west and north-east corners.
	Target : { sw : Wgs84.Target, ne : Wgs84.Target }

	decode : HausFmtGeo.BBox -> Try(Target, Str)
	decode = |box| match box {
		BBox(sw, ne) => {
			south_west = Wgs84.decode(sw).map_err(|e| "a corner: ${e}")?
			north_east = Wgs84.decode(ne).map_err(|e| "a corner: ${e}")?
			if south_west.lat <= north_east.lat {
				Ok({ sw: south_west, ne: north_east })
			} else {
				Err("the south-west corner (latitude ${south_west.lat.to_str()}) is north of the north-east one (${north_east.lat.to_str()})")
			}
		}
	}

	encode : Target -> HausFmtGeo.BBox
	encode = |{ sw, ne }| BBox(Wgs84.encode(sw), Wgs84.encode(ne))

	## Whether the box crosses the antimeridian: its west edge is east of its east edge.
	crosses_antimeridian : Target -> Bool
	crosses_antimeridian = |{ sw, ne }| sw.lng > ne.lng
}
