//! The package's rule (packages.md §6): `rfc9562` for `Uuid`
//! (profiles/rfc9562.md), checked by the generated code on every value the
//! schema decodes, before any codec, whatever codecs an application sets.

use haus::{Rule, Value};

use crate::rfc9562::UuidText;

/// The rule `rfc9562` of `@haus-fmt/uuid@1#Uuid`: the text is 32 digits
/// `0`–`9`, `a`–`f` in groups 8-4-4-4-12, joined by hyphens, lowercase only.
///
/// ```
/// use haus::Rule;
/// let check = |text: &str| haus_uuid::rules::Rfc9562::check(&haus::parse_one(text).unwrap());
/// assert!(check(r#"Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57")"#).is_ok());
/// assert!(check(r#"Uuid("0190C7A8-5B6E-7D3F-9A41-6C2E8F1B0D57")"#).is_err());
/// ```
pub struct Rfc9562;

impl Rule for Rfc9562 {
    const ID: &'static str = "@haus-fmt/uuid@1#Uuid";
    const NAME: &'static str = "rfc9562";

    fn check(value: &Value) -> Result<(), String> {
        match value.as_variant() {
            Some((tag, [Value::String(text)])) if tag == "Uuid" => UuidText::new(text).map(drop),
            // It doesn't quote the value, which can be anything.
            _ => Err("not Uuid(\"…\") with a UUID of the rfc9562 rule".to_owned()),
        }
    }
}
