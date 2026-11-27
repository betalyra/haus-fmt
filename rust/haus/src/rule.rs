//! Package rules (packages.md §6): a package's definition of which values of
//! one of its types are values of the type, beyond the schema's shape. The
//! official rules (`@haus-fmt/money`'s `iso`, …) are in their crates.
//!
//! A rule belongs to its type's id, not to a codec: generated code checks
//! it on the value the schema decoded, before any codec of the type runs and
//! whichever codecs the application set, so that no codec can make a value
//! pass it. A value it rejects is `codec-rejected` when decoding and
//! `cannot-encode` when encoding, at the place of the type.
//!
//! ```
//! use haus::{Rule, Value};
//!
//! /// `@acme/codes@1#Code` (`type Code = < >`): three capital letters.
//! pub struct Iso;
//! impl Rule for Iso {
//!     const ID: &'static str = "@acme/codes@1#Code";
//!     const NAME: &'static str = "iso";
//!     fn check(value: &Value) -> Result<(), String> {
//!         match value.as_variant() {
//!             Some((tag, [])) if tag.len() == 3 && tag.bytes().all(|b| b.is_ascii_uppercase()) => Ok(()),
//!             _ => Err("not three capital letters".into()),
//!         }
//!     }
//! }
//! assert!(Iso::check(&haus::parse_one("EUR").unwrap()).is_ok());
//! assert!(Iso::check(&haus::parse_one("Eur").unwrap()).is_err());
//! ```

use crate::Value;

/// The implementation of a package's rule for one type (packages.md §6): a
/// check of the value the schema decoded. A crate that implements a rule
/// names it in its build script (`haus_build::Config::with_rule`), and the
/// generated code checks it wherever the type is decoded or encoded.
pub trait Rule {
    /// The id of the type it is the rule of: `@haus-fmt/money@1#Currency`.
    const ID: &'static str;
    /// The rule's name, as the package's manifest gives it (`rules`): `iso`.
    const NAME: &'static str;
    /// Ok if the rule accepts `value`, the value the schema decoded (spec
    /// §15: the value an encoder writes back); otherwise why not, quoting
    /// what it rejects as error messages do ([`crate::for_message`]). It
    /// must reject any value it doesn't expect, so that a modified copy of
    /// the package's schema can't slip a value past it.
    fn check(value: &Value) -> Result<(), String>;
}
