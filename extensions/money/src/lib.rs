//! `@haus-fmt/money`: exact amounts with a currency, generated from
//! `schema.haus` (the same file as for every other language).
//!
//! ```
//! let m: haus_money::Money = haus::from_str("Money(19.90, EUR)").unwrap();
//! assert_eq!(m.0.as_str(), "19.90");
//! assert_eq!(m.1, haus::AnyTag::Bare("EUR".parse().unwrap()));
//! ```
//!
//! **The rule.** The package gives `Currency` the rule `iso` (its manifest's
//! `rules`, profiles/iso.md): three letters `A`–`Z`. The generated code
//! checks it on every value of the type the schema decodes, before any
//! codec, whatever codecs an application sets ([`rules::Iso`], packages.md
//! §6), so `Money(19.90, Bitcoin)` is `codec-rejected` everywhere. An
//! application that wants another definition takes the package shape-only
//! (`haus_build::Config::shape_only("@haus-fmt/money")`), or defines a type
//! of its own.
//!
//! ```
//! let e = haus::from_str::<haus_money::Money>("Money(19.90, Eur)").unwrap_err();
//! assert_eq!(e.code(), Some(haus::ErrorCode::CodecRejected));
//! ```
//!
//! **The codecs** choose Rust types (spec §13.4), which an application
//! registers in its build script: [`Iso`] for `Money` and [`IsoCurrency`]
//! for `Currency`. They apply wherever their types occur, inside other
//! packages' types too, and keep the value: the amount is the exact
//! [`haus::Decimal`], the currency a [`CurrencyCode`].
//!
//! ```ignore
//! // build.rs
//! haus_build::Config::new()
//!     .codec("@haus-fmt/money@1#Money", "haus_money::Iso")
//!     .codec("@haus-fmt/money@1#Currency", "haus_money::IsoCurrency")
//!     .compile("app.schema.haus")
//! ```
//!
//! ```
//! use haus::Codec;
//! use haus_money::{Iso, Money};
//!
//! let money = Iso::decode(haus::from_str::<Money>("Money(19.90, EUR)").unwrap()).unwrap();
//! assert_eq!((money.amount.as_str(), money.currency.as_str()), ("19.90", "EUR"));
//! ```
//!
//! [`MANIFEST`] and [`SCHEMA`] are the package's files, for a program that
//! compiles schemas at run time (`haus_schema::Package::make`).

haus::include_schema!("schema");

mod iso;
pub mod rules;

pub use iso::{CURRENCY_ID, CurrencyCode, Iso, IsoCurrency, IsoMoney};

/// The package's manifest, `package.haus`.
pub const MANIFEST: &str = include_str!("../package.haus");
/// The package's schema, `schema.haus`.
pub const SCHEMA: &str = include_str!("../schema.haus");
