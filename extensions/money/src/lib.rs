//! `@haus-fmt/money`: exact amounts with a currency, generated from
//! `schema.haus` (the same file as for every other language).
//!
//! ```
//! let m: haus_money::Money = haus::from_str("Money(19.90, EUR)").unwrap();
//! assert_eq!(m.0.as_str(), "19.90");
//! assert_eq!(m.1, haus::AnyTag::Bare("EUR".parse().unwrap()));
//! ```
//!
//! The profile `@haus-fmt/money/iso` (profiles/iso.md) is two codecs (spec
//! §13.4), which an application registers in its build script: [`Iso`] for
//! `Money` and [`IsoCurrency`] for `Currency`. They apply wherever their
//! types occur, inside other packages' types too, and keep the value: the
//! amount is the exact [`haus::Decimal`], the currency a [`CurrencyCode`].
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
//! assert!(Iso::decode(haus::from_str::<Money>("Money(19.90, Eur)").unwrap()).is_err());
//! ```

haus::include_schema!("schema");

mod iso;

pub use iso::{CURRENCY_ID, CurrencyCode, Iso, IsoCurrency, IsoMoney};
