//! `@haus-fmt/geo`: points and boxes on the earth, generated from
//! `schema.haus` (the same file as for every other language).
//!
//! ```
//! let lisbon: haus_geo::LatLng = haus::from_str("LatLng(38.7223, -9.1393)").unwrap();
//! assert_eq!((lisbon.0, lisbon.1), (38.7223, -9.1393));
//! ```
//!
//! **The rules.** The package gives `LatLng` and `BBox` the rule `wgs84`
//! (its manifest's `rules`, profiles/wgs84.md). The generated code checks it
//! on every value of the types the schema decodes, before any codec,
//! whatever codecs an application sets ([`rules::Wgs84`],
//! [`rules::Wgs84BBox`], packages.md §6).
//!
//! ```
//! let e = haus::from_str::<haus_geo::LatLng>("LatLng(91, 0)").unwrap_err();
//! assert_eq!(e.code(), Some(haus::ErrorCode::CodecRejected));
//! ```
//!
//! **The codecs** choose Rust types (spec §13.4), which an application
//! registers in its build script: [`Wgs84`] for `LatLng` and [`Wgs84BBox`]
//! for `BBox`. They apply wherever their types occur, inside other
//! packages' types too, and keep the value: the floats as decoded, `-0`
//! included.
//!
//! ```ignore
//! // build.rs
//! haus_build::Config::new()
//!     .codec("@haus-fmt/geo@1#LatLng", "haus_geo::Wgs84")
//!     .codec("@haus-fmt/geo@1#BBox", "haus_geo::Wgs84BBox")
//!     .compile("app.schema.haus")
//! ```
//!
//! ```
//! use haus::Codec;
//! use haus_geo::{LatLng, Wgs84};
//!
//! let lisbon = Wgs84::decode(haus::from_str::<LatLng>("LatLng(38.7223, -9.1393)").unwrap()).unwrap();
//! assert_eq!((lisbon.lat(), lisbon.lng()), (38.7223, -9.1393));
//! ```
//!
//! [`MANIFEST`] and [`SCHEMA`] are the package's files, for a program that
//! compiles schemas at run time (`haus_schema::Package::make`).

haus::include_schema!("schema");

pub mod rules;
mod wgs84;

pub use wgs84::{Bounds, Point, Wgs84, Wgs84BBox};

/// The package's manifest, `package.haus`.
pub const MANIFEST: &str = include_str!("../package.haus");
/// The package's schema, `schema.haus`.
pub const SCHEMA: &str = include_str!("../schema.haus");
