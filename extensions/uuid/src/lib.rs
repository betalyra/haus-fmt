//! `@haus-fmt/uuid`: universally unique identifiers, generated from
//! `schema.haus` (the same file as for every other language).
//!
//! ```
//! let id: haus_uuid::Uuid = haus::from_str(r#"Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57")"#).unwrap();
//! assert_eq!(id.0, "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57");
//! ```
//!
//! **The rule.** The package gives `Uuid` the rule `rfc9562` (its
//! manifest's `rules`, profiles/rfc9562.md): 32 digits `0`–`9`, `a`–`f` in
//! groups 8-4-4-4-12, lowercase only, any version. The generated code checks
//! it on every value of the type the schema decodes, before any codec,
//! whatever codecs an application sets ([`rules::Rfc9562`], packages.md §6).
//!
//! ```
//! let e = haus::from_str::<haus_uuid::Uuid>(r#"Uuid("0190C7A8-5B6E-7D3F-9A41-6C2E8F1B0D57")"#).unwrap_err();
//! assert_eq!(e.code(), Some(haus::ErrorCode::CodecRejected));
//! ```
//!
//! **The codec** [`Rfc9562`] gives a [`UuidText`], which an application
//! registers in its build script. It applies wherever a `Uuid` occurs,
//! inside other packages' types too. The text is the UUID's one spelling,
//! so the codec keeps the value.
//!
//! ```ignore
//! // build.rs
//! haus_build::Config::new()
//!     .codec("@haus-fmt/uuid@1#Uuid", "haus_uuid::Rfc9562")
//!     .compile("app.schema.haus")
//! ```
//!
//! ```
//! use haus::Codec;
//! use haus_uuid::{Rfc9562, Uuid};
//!
//! let id = Rfc9562::decode(haus::from_str::<Uuid>(r#"Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57")"#).unwrap()).unwrap();
//! assert_eq!(id.as_str(), "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57");
//! ```
//!
//! [`MANIFEST`] and [`SCHEMA`] are the package's files, for a program that
//! compiles schemas at run time (`haus_schema::Package::make`).

haus::include_schema!("schema");

mod rfc9562;
pub mod rules;

pub use rfc9562::{Rfc9562, UuidText};

/// The package's manifest, `package.haus`.
pub const MANIFEST: &str = include_str!("../package.haus");
/// The package's schema, `schema.haus`.
pub const SCHEMA: &str = include_str!("../schema.haus");
