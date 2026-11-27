//! The package's rules (packages.md §6): `wgs84` for `LatLng` and `BBox`
//! (profiles/wgs84.md), checked by the generated code on every value the
//! schema decodes, before any codec, whatever codecs an application sets.

use haus::{Rule, Value};

use crate::wgs84::{Bounds, Point};

/// The rule `wgs84` of `@haus-fmt/geo@1#LatLng`: −90 ≤ lat ≤ 90 and
/// −180 ≤ lng ≤ 180, in degrees (NaN and the infinities are out of range).
///
/// ```
/// use haus::Rule;
/// let check = |text: &str| haus_geo::rules::Wgs84::check(&haus::parse_one(text).unwrap());
/// assert!(check("LatLng(38.7223, -9.1393)").is_ok());
/// assert!(check("LatLng(91, 0)").is_err() && check("LatLng(NaN, 0)").is_err());
/// ```
pub struct Wgs84;

impl Rule for Wgs84 {
    const ID: &'static str = "@haus-fmt/geo@1#LatLng";
    const NAME: &'static str = "wgs84";

    fn check(value: &Value) -> Result<(), String> {
        point(value).map(drop)
    }
}

/// The rule `wgs84` of `@haus-fmt/geo@1#BBox`: both corners are points of
/// the rule, the south-west one not north of the north-east one.
pub struct Wgs84BBox;

impl Rule for Wgs84BBox {
    const ID: &'static str = "@haus-fmt/geo@1#BBox";
    const NAME: &'static str = "wgs84";

    fn check(value: &Value) -> Result<(), String> {
        match value.as_variant() {
            Some((tag, [sw, ne])) if tag == "BBox" => {
                let corner = |p: &Value| point(p).map_err(|e| format!("a corner: {e}"));
                Bounds::new(corner(sw)?, corner(ne)?).map(drop)
            }
            _ => Err(unexpected("BBox(LatLng(…), LatLng(…))", value)),
        }
    }
}

/// A `LatLng` as the schema decoded it, as a point of the rule.
fn point(value: &Value) -> Result<Point, String> {
    match value.as_variant() {
        Some((tag, [lat, lng])) if tag == "LatLng" => Point::new(float(lat)?, float(lng)?),
        _ => Err(unexpected("LatLng(lat, lng)", value)),
    }
}

/// A `Float64` as the schema decoded it: a number, or `NaN`, `Infinity`, `NegInfinity`.
fn float(value: &Value) -> Result<f64, String> {
    match value {
        Value::Number(n) => n.parse().map_err(|_| unexpected("a Float64", value)),
        _ => match value.as_variant() {
            Some((tag, [])) if tag == "NaN" => Ok(f64::NAN),
            Some((tag, [])) if tag == "Infinity" => Ok(f64::INFINITY),
            Some((tag, [])) if tag == "NegInfinity" => Ok(f64::NEG_INFINITY),
            _ => Err(unexpected("a Float64", value)),
        },
    }
}

/// The message for a value of another shape than `expected`: the rule rejects it.
fn unexpected(expected: &str, value: &Value) -> String {
    format!("{} is not {expected}", haus::for_message(&haus::canonical(value)))
}
