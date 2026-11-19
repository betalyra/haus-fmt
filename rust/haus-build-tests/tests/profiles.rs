//! The official profiles' codecs (spec §13.3, §13.4): `haus_money::Iso`,
//! `haus_money::IsoCurrency`, `haus_geo::Wgs84` and `haus_geo::Wgs84BBox`.
//!
//! Every test vector of extensions/*/profiles/*.vectors.haus, and the codecs
//! in an application (travel.schema.haus) whose package (packages/travel)
//! uses the official packages: they apply inside that package's types too.

/// travel.schema.haus with the profiles' codecs (see build.rs).
mod travel {
    haus::include_schema!("travel");
}

use haus::{Codec, Value};
use haus_geo::{Bounds, Point, Wgs84, Wgs84BBox};
use haus_money::{CurrencyCode, Iso, IsoCurrency, IsoMoney};

// ── the vectors ──

const MONEY: &str = include_str!("../../../extensions/money/profiles/iso.vectors.haus");
const GEO: &str = include_str!("../../../extensions/geo/profiles/wgs84.vectors.haus");

/// A test vector: `Accept { type, value, output?, note? }` or `Reject { type, value, note? }`.
#[derive(Debug)]
struct Vector {
    accept: bool,
    ty: String,
    value: String,
    output: Option<String>,
}

fn vectors(text: &str) -> Vec<Vector> {
    let string = |v: &Value, key: &str| match v.get(key) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    };
    haus::parse(text)
        .expect("the vectors parse")
        .into_iter()
        .map(|v| match v {
            Value::Variant { tag, args } if (tag == "Accept" || tag == "Reject") && args.len() == 1 => Vector {
                accept: tag == "Accept",
                ty: string(&args[0], "type").expect("a type"),
                value: string(&args[0], "value").expect("a value"),
                output: string(&args[0], "output"),
            },
            other => panic!("not a vector: {other:?}"),
        })
        .collect()
}

/// `text` decoded with the schema alone, in the one spelling of its type (spec §15).
fn normal<C: Codec>(text: &str) -> Result<String, String> {
    let base: C::Base = haus::from_str(text).map_err(|e| format!("the schema rejects it: {e}"))?;
    haus::to_string(&base).map_err(|e| e.to_string())
}

/// Checks a vector with the codec `C`, as generated code runs it (`haus::de::codec`).
fn check<C: Codec>(v: &Vector) -> Result<(), String>
where
    C::Target: PartialEq + std::fmt::Debug,
{
    // Every vector is valid under the schema: what the codec rejects, the profile rejects.
    let written = normal::<C>(&v.value)?;
    let value = &haus::parse(&v.value).map_err(|e| e.to_string())?[0];
    let decoded = haus::de::codec::<C>(value, haus::Decoder::default());
    match (v.accept, decoded) {
        (false, Err(e)) if e.code == haus::ErrorCode::TypeMismatch => Ok(()),
        (false, Err(e)) => Err(format!("rejected with {:?}: {e}", e.code)),
        (false, Ok(x)) => Err(format!("accepted: {x:?}")),
        (true, Err(e)) => Err(format!("rejected: {e}")),
        (true, Ok(x)) => {
            let encoded = haus::to_string(&C::encode(&x)).map_err(|e| e.to_string())?;
            let want = normal::<C>(v.output.as_deref().unwrap_or(&v.value))?;
            if encoded != want {
                return Err(format!("encoded as {encoded}, expected {want}"));
            }
            // The codec changes no value: it writes what the schema alone decodes.
            if encoded != written {
                return Err(format!("encoded as {encoded}, but the schema alone writes {written}"));
            }
            // Decode, encode, decode is decode.
            let again =
                haus::de::codec::<C>(&haus::parse(&encoded).map_err(|e| e.to_string())?[0], haus::Decoder::default())
                    .map_err(|e| format!("{encoded} doesn't decode again: {e}"))?;
            if again != x {
                return Err(format!("{encoded} decodes again as {again:?}, not {x:?}"));
            }
            Ok(())
        }
    }
}

fn run(text: &str, check: impl Fn(&Vector) -> Result<(), String>) -> (usize, usize) {
    let vectors = vectors(text);
    let failures: Vec<String> = vectors
        .iter()
        .filter_map(|v| {
            check(v).err().map(|e| format!("{} {} {}: {e}", if v.accept { "Accept" } else { "Reject" }, v.ty, v.value))
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} vectors fail:\n{}", failures.len(), vectors.len(), failures.join("\n"));
    let accepted = vectors.iter().filter(|v| v.accept).count();
    (accepted, vectors.len() - accepted)
}

#[test]
fn the_iso_vectors() {
    let (accepted, rejected) = run(MONEY, |v| match v.ty.as_str() {
        "Money" => check::<Iso>(v),
        "Currency" => check::<IsoCurrency>(v),
        other => Err(format!("no codec for {other}")),
    });
    assert!(accepted > 0 && rejected > 0, "{accepted} accepted, {rejected} rejected");
}

#[test]
fn the_wgs84_vectors() {
    let (accepted, rejected) = run(GEO, |v| match v.ty.as_str() {
        "LatLng" => check::<Wgs84>(v),
        "BBox" => check::<Wgs84BBox>(v),
        other => Err(format!("no codec for {other}")),
    });
    assert!(accepted > 0 && rejected > 0, "{accepted} accepted, {rejected} rejected");
}

// ── the codecs inside another package's types (the codec closure) ──

const TRAVEL: &str = r#"{ trips: [{ fare: Money(12.50, EUR), area: BBox(LatLng(0, 170), LatLng(10, -170)), stops: [LatLng(-0, 0), LatLng(38.7223, -9.1393)], legs: [Walk, Ride { fare: Money(3.10, EUR), from: LatLng(38.7, -9.1), to: LatLng(38.8, -9.2) }, Tip(CHF)] }], traveller: { name: "Ada" }, budget: Money(100.00, USD) }"#;

/// `x` has the type `T` (a compile-time check of type identity).
fn is<T>(_: &T) {}

fn code(text: &str) -> CurrencyCode {
    text.parse().unwrap()
}

#[test]
fn the_profiles_codecs_apply_inside_another_packages_types() {
    let travel: travel::Travel = haus::from_str(TRAVEL).unwrap();
    // In the application's own type.
    is::<IsoMoney>(&travel.budget);
    assert_eq!((travel.budget.amount.as_str(), travel.budget.currency), ("100.00", code("USD")));
    // In @haus-test/travel's types, which the application's code copies: fields, arrays, payloads.
    let trip: &travel::haus_test_travel::Trip = &travel.trips[0];
    is::<IsoMoney>(&trip.fare);
    is::<Bounds>(&trip.area);
    is::<Vec<Point>>(&trip.stops);
    assert_eq!(trip.fare.amount.as_str(), "12.50");
    assert!(trip.area.crosses_antimeridian());
    assert!(trip.stops[0].lat().is_sign_negative(), "-0 is kept");
    use travel::haus_test_travel::Leg;
    assert!(
        matches!(&trip.legs[1], Leg::Ride { fare, from, .. } if fare.amount.as_str() == "3.10" && from.lat() == 38.7)
    );
    assert!(matches!(&trip.legs[2], Leg::Tip(c) if *c == code("CHF")));
    // The package's types without the codecs' types are its crate's.
    is::<haus_test_travel::Traveller>(&travel.traveller);
    assert_eq!(travel::haus_test_travel::Trip::ID, "@haus-test/travel@1#Trip");

    // Encoded back to the same text.
    assert_eq!(haus::to_string(&travel).unwrap(), TRAVEL);
    let json = haus::json::to_string(&travel).unwrap();
    assert_eq!(haus::json::from_str::<travel::Travel>(&json).unwrap(), travel);
}

#[test]
fn the_profiles_reject_inside_another_packages_types() {
    let place = |from: &str, to: &str| {
        let text = TRAVEL.replacen(from, to, 1);
        assert_ne!(text, TRAVEL, "{from}");
        match haus::from_str::<travel::Travel>(&text) {
            Err(haus::Error::Decode(e)) => {
                assert_eq!(e.code, haus::ErrorCode::TypeMismatch, "{e}");
                e.place()
            }
            other => panic!("{to}: {other:?}"),
        }
    };
    assert_eq!(place("Money(3.10, EUR)", "Money(3.10, Eur)"), "$.trips[0].legs[1].fare");
    assert_eq!(place("Tip(CHF)", "Tip(CHFR)"), "$.trips[0].legs[2][0]");
    assert_eq!(place("LatLng(-0, 0)", "LatLng(-0, 181)"), "$.trips[0].stops[0]");
    assert_eq!(place("LatLng(38.8, -9.2)", "LatLng(NaN, -9.2)"), "$.trips[0].legs[1].to");
    assert_eq!(place("LatLng(10, -170)", "LatLng(-10, -170)"), "$.trips[0].area");
    assert_eq!(place("Money(100.00, USD)", "Money(100.00, US)"), "$.budget");
}
