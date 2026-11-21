//! The profile `@haus-fmt/geo/wgs84` (profiles/wgs84.md) as codecs (spec §13.4).

use haus::Codec;

use crate::{BBox, LatLng};

/// A point the wgs84 profile accepts: −90 ≤ lat ≤ 90 and −180 ≤ lng ≤ 180,
/// in degrees. It keeps the floats as decoded: `-0` stays `-0`, and the
/// poles and the antimeridian are not normalised.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point {
    lat: f64,
    lng: f64,
}

impl Point {
    /// The point at `lat`, `lng`; an error if either is out of range, NaN or infinite.
    pub fn new(lat: f64, lng: f64) -> Result<Point, String> {
        if !(-90.0..=90.0).contains(&lat) {
            Err(format!(
                "latitude {} out of range: the wgs84 profile takes -90 to 90",
                haus::for_message(&lat.to_string())
            ))
        } else if !(-180.0..=180.0).contains(&lng) {
            Err(format!(
                "longitude {} out of range: the wgs84 profile takes -180 to 180",
                haus::for_message(&lng.to_string())
            ))
        } else {
            Ok(Point { lat, lng })
        }
    }

    /// The latitude, in degrees north.
    pub fn lat(&self) -> f64 {
        self.lat
    }

    /// The longitude, in degrees east.
    pub fn lng(&self) -> f64 {
        self.lng
    }
}

impl TryFrom<LatLng> for Point {
    type Error = String;
    fn try_from(LatLng(lat, lng): LatLng) -> Result<Point, String> {
        Point::new(lat, lng)
    }
}

impl From<Point> for LatLng {
    fn from(p: Point) -> LatLng {
        LatLng(p.lat, p.lng)
    }
}

/// A box the wgs84 profile accepts, from its south-west corner to its
/// north-east one: both corners are [`Point`]s and `sw.lat` ≤ `ne.lat`. The
/// longitudes aren't ordered: `sw.lng` > `ne.lng` crosses the antimeridian.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    sw: Point,
    ne: Point,
}

impl Bounds {
    /// The box from `sw` to `ne`; an error if `sw` is north of `ne`.
    pub fn new(sw: Point, ne: Point) -> Result<Bounds, String> {
        if sw.lat <= ne.lat {
            Ok(Bounds { sw, ne })
        } else {
            Err(format!("the south-west corner (latitude {}) is north of the north-east one ({})", sw.lat, ne.lat))
        }
    }

    /// The south-west corner.
    pub fn sw(&self) -> Point {
        self.sw
    }

    /// The north-east corner.
    pub fn ne(&self) -> Point {
        self.ne
    }

    /// Whether the box crosses the antimeridian: its west edge is east of its east edge.
    pub fn crosses_antimeridian(&self) -> bool {
        self.sw.lng > self.ne.lng
    }
}

impl TryFrom<BBox> for Bounds {
    type Error = String;
    fn try_from(BBox(sw, ne): BBox) -> Result<Bounds, String> {
        let corner = |p: LatLng| Point::try_from(p).map_err(|e| format!("a corner: {e}"));
        Bounds::new(corner(sw)?, corner(ne)?)
    }
}

impl From<Bounds> for BBox {
    fn from(b: Bounds) -> BBox {
        BBox(b.sw.into(), b.ne.into())
    }
}

/// The wgs84 profile's codec for `@haus-fmt/geo@1#LatLng`: `LatLng(38.7223, -9.1393)` ↔ [`Point`].
pub struct Wgs84;

impl Codec for Wgs84 {
    const ID: &'static str = LatLng::ID;
    type Base = LatLng;
    type Target = Point;

    fn decode(point: LatLng) -> Result<Point, String> {
        point.try_into()
    }

    fn encode(point: &Point) -> LatLng {
        (*point).into()
    }
}

/// The wgs84 profile's codec for `@haus-fmt/geo@1#BBox`: `BBox(LatLng(…), LatLng(…))` ↔ [`Bounds`].
/// It checks the corners too, so it needs no [`Wgs84`] for them.
pub struct Wgs84BBox;

impl Codec for Wgs84BBox {
    const ID: &'static str = BBox::ID;
    type Base = BBox;
    type Target = Bounds;

    fn decode(bbox: BBox) -> Result<Bounds, String> {
        bbox.try_into()
    }

    fn encode(bounds: &Bounds) -> BBox {
        (*bounds).into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn point(text: &str) -> Result<Point, String> {
        Wgs84::decode(haus::from_str(text).map_err(|e| e.to_string())?)
    }

    fn bounds(text: &str) -> Result<Bounds, String> {
        Wgs84BBox::decode(haus::from_str(text).map_err(|e| e.to_string())?)
    }

    fn encode(p: &Point) -> String {
        haus::to_string(&Wgs84::encode(p)).unwrap()
    }

    #[test]
    fn the_range_is_checked_on_the_decoded_float() {
        // Rounds to 90 (and to 180): accepted, and written back as the float it is.
        let p = point("LatLng(90.00000000000000001, 180.00000000000000001)").unwrap();
        assert_eq!((p.lat(), p.lng()), (90.0, 180.0));
        assert_eq!(encode(&p), "LatLng(90, 180)");
        let p = point("LatLng(-90.00000000000000001, -180.00000000000000001)").unwrap();
        assert_eq!(encode(&p), "LatLng(-90, -180)");
        // The next float above 90 is not.
        assert!(point("LatLng(90.00000000000002, 0)").is_err());
        assert!(point(&format!("LatLng({}, 0)", f64::from_bits(90f64.to_bits() + 1))).is_err());
        assert!(point(&format!("LatLng(0, {})", f64::from_bits(180f64.to_bits() + 1))).is_err());
    }

    #[test]
    fn negative_zero_is_kept() {
        let p = point("LatLng(-0, -0)").unwrap();
        assert!(p.lat().is_sign_negative() && p.lng().is_sign_negative());
        assert_eq!(encode(&p), "LatLng(-0, -0)");
        let p = point("LatLng(0, 0)").unwrap();
        assert!(p.lat().is_sign_positive());
        assert_eq!(encode(&p), "LatLng(0, 0)");
    }

    #[test]
    fn nan_and_the_infinities_are_rejected() {
        for bad in ["NaN", "Infinity", "NegInfinity"] {
            assert!(point(&format!("LatLng({bad}, 0)")).unwrap_err().contains("latitude"), "{bad}");
            assert!(point(&format!("LatLng(0, {bad})")).unwrap_err().contains("longitude"), "{bad}");
        }
        assert!(Point::new(f64::NAN, 0.0).is_err());
        assert!(Point::new(0.0, f64::INFINITY).is_err());
        assert!(Point::new(f64::NEG_INFINITY, 0.0).is_err());
    }

    #[test]
    fn poles_and_the_antimeridian_are_not_normalised() {
        assert_ne!(point("LatLng(90, 10)").unwrap(), point("LatLng(90, 20)").unwrap());
        assert_eq!(encode(&point("LatLng(0, -180)").unwrap()), "LatLng(0, -180)");
        assert_eq!(encode(&point("LatLng(0, 180)").unwrap()), "LatLng(0, 180)");
    }

    #[test]
    fn a_box_may_cross_the_antimeridian() {
        let b = bounds("BBox(LatLng(0, 170), LatLng(10, -170))").unwrap();
        assert!(b.crosses_antimeridian());
        assert_eq!(haus::to_string(&Wgs84BBox::encode(&b)).unwrap(), "BBox(LatLng(0, 170), LatLng(10, -170))");
        assert!(!bounds("BBox(LatLng(0, -170), LatLng(10, 170))").unwrap().crosses_antimeridian());
        // The longitudes are never compared for acceptance, -180 and 180 included.
        assert!(bounds("BBox(LatLng(0, 180), LatLng(10, -180))").is_ok());
    }

    #[test]
    fn the_latitudes_are_ordered() {
        assert!(bounds("BBox(LatLng(5, 5), LatLng(5, 5))").is_ok());
        assert!(bounds("BBox(LatLng(-0, 0), LatLng(0, 0))").is_ok());
        assert!(bounds("BBox(LatLng(0, 0), LatLng(-0, 0))").is_ok(), "-0 = 0: not south of it");
        let e = bounds("BBox(LatLng(10, 0), LatLng(0, 1))").unwrap_err();
        assert!(e.contains("north of the north-east"), "{e}");
        let e = bounds("BBox(LatLng(0, 0), LatLng(91, 1))").unwrap_err();
        assert!(e.starts_with("a corner: latitude 91"), "{e}");
        assert!(bounds("BBox(LatLng(NaN, 0), LatLng(1, 1))").is_err());
    }
}
