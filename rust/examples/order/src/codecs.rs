//! Codecs: the application chooses Rust types for named haus types. Each one
//! decodes the type's base value first, so the schema's rules always run (and
//! a package's rule, money's iso, before any codec), and encodes back to it,
//! so the haus text never changes (spec §13.4).

use haus::{AnyTag, Codec, Decimal, Tag, time};
use haus_geo::LatLng;
use haus_money::Money;

/// Integer cents, as payment APIs want them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Amount {
    pub cents: i128,
    /// An ISO 4217 code: three letters A–Z, a tag.
    pub currency: Tag,
}

/// `Money(44.40, EUR)` ↔ `Amount { cents: 4440, currency: "EUR" }`. The
/// currency passed money's iso rule already; more than 2 decimal places is
/// an error of this codec's: a codec may reject more than the rule.
pub struct Cents;

impl Codec for Cents {
    const ID: &'static str = Money::ID;
    type Base = Money;
    type Target = Amount;

    fn decode(Money(amount, currency): Money) -> Result<Amount, String> {
        let cents = amount.scaled(2).ok_or_else(|| format!("{} has more than 2 decimal places", amount.as_str()))?;
        // The rule took only a tag without payload.
        let AnyTag::Bare(currency) = currency else { return Err(format!("{currency} is not a currency")) };
        Ok(Amount { cents, currency })
    }

    fn encode(amount: &Amount) -> Money {
        Money(Decimal::from_scaled(amount.cents, 2), AnyTag::Bare(amount.currency.clone()))
    }
}

/// GeoJSON order: `LatLng(38.7223, -9.1393)` ↔ `[-9.1393, 38.7223]`. The swap happens here, once.
pub struct GeoJson;

impl Codec for GeoJson {
    const ID: &'static str = LatLng::ID;
    type Base = LatLng;
    type Target = [f64; 2];

    fn decode(LatLng(lat, lng): LatLng) -> Result<[f64; 2], String> {
        Ok([lng, lat])
    }

    fn encode(&[lng, lat]: &[f64; 2]) -> LatLng {
        LatLng(lat, lng)
    }
}

/// std/time types take codecs too: `Date("2026-11-09")` ↔ `jiff::civil::Date`.
pub struct JiffDate;

impl Codec for JiffDate {
    const ID: &'static str = time::Date::ID;
    type Base = time::Date;
    type Target = jiff::civil::Date;

    fn decode(date: time::Date) -> Result<jiff::civil::Date, String> {
        // std/time's checks already ran: this can't fail for a valid Date.
        date.as_str().parse().map_err(|e: jiff::Error| e.to_string())
    }

    fn encode(date: &jiff::civil::Date) -> time::Date {
        time::Date::new(date.to_string()).expect("jiff writes YYYY-MM-DD")
    }
}
