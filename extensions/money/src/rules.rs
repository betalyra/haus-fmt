//! The package's rule (packages.md §6): `iso` for `Currency`
//! (profiles/iso.md), checked by the generated code on every value the
//! schema decodes, before any codec, whatever codecs an application sets.
//! `Money` is covered through its `Currency`.

use haus::{Rule, Value};

use crate::iso::CurrencyCode;

/// The rule `iso` of `@haus-fmt/money@1#Currency`: a tag without payload,
/// three letters `A`–`Z` (whether the code is assigned is not checked).
///
/// ```
/// use haus::Rule;
/// let check = |text: &str| haus_money::rules::Iso::check(&haus::parse_one(text).unwrap());
/// assert!(check("EUR").is_ok() && check("BTC").is_ok());
/// assert!(check("Eur").is_err() && check("EURO").is_err() && check("EUR(1)").is_err());
/// // Inside a Money too: the rule of its Currency.
/// assert!(haus::from_str::<haus_money::Money>("Money(19.90, Bitcoin)").is_err());
/// ```
pub struct Iso;

impl Rule for Iso {
    const ID: &'static str = crate::iso::CURRENCY_ID;
    const NAME: &'static str = "iso";

    fn check(value: &Value) -> Result<(), String> {
        match value.as_variant() {
            Some((tag, [])) => CurrencyCode::new(tag).map(drop),
            _ => Err(format!(
                "{} is not a currency of the iso rule: a tag of three letters A–Z, without payload",
                haus::for_message(&haus::canonical(value))
            )),
        }
    }
}
