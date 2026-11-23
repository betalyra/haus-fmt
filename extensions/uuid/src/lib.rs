//! `@haus-fmt/uuid`: universally unique identifiers, generated from
//! `schema.haus` (the same file as for every other language).
//!
//! ```
//! let id: haus_uuid::Uuid = haus::from_str(r#"Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57")"#).unwrap();
//! assert_eq!(id.0, "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57");
//! ```
//!
//! The profile `@haus-fmt/uuid/rfc9562` (profiles/rfc9562.md) is a codec
//! (spec §13.4), which an application registers in its build script:
//! [`Rfc9562`] for `Uuid`. It applies wherever a `Uuid` occurs, inside other
//! packages' types too, and gives a [`UuidText`]: the text, checked to be
//! 32 digits `0`–`9`, `a`–`f` in groups 8-4-4-4-12, lowercase only, any
//! version. The text is the UUID's one spelling, so the codec keeps the value.
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
//! assert!(Rfc9562::decode(haus::from_str::<Uuid>(r#"Uuid("0190C7A8-5B6E-7D3F-9A41-6C2E8F1B0D57")"#).unwrap()).is_err());
//! ```

haus::include_schema!("schema");

mod rfc9562;

pub use rfc9562::{Rfc9562, UuidText};
