//! Codecs (spec §13.4): an application's choice of Rust type for a named
//! haus type, selected by the type's id.
//!
//! ```
//! use haus::{Codec, time::Date};
//!
//! /// std/time#Date as (year, month, day).
//! pub struct Ymd;
//! impl Codec for Ymd {
//!     const ID: &'static str = Date::ID;
//!     type Base = Date;
//!     type Target = (u16, u8, u8);
//!     fn decode(d: Date) -> Result<Self::Target, String> {
//!         let p: Vec<&str> = d.as_str().split('-').collect();
//!         Ok((p[0].parse().unwrap(), p[1].parse().unwrap(), p[2].parse().unwrap()))
//!     }
//!     fn encode(&(y, m, d): &Self::Target) -> Date {
//!         Date::new(format!("{y:04}-{m:02}-{d:02}")).unwrap()
//!     }
//! }
//! ```
//!
//! haus-fmt-build replaces every use of the type `ID` with `Target`, and checks
//! at compile time that the schema has a type with that id.
//!
//! A value decoded *as* the codec's type runs the codec too (spec §13.4): the
//! Rust type to decode with is [`Coded<C>`]. For a type of the application's
//! own schema, haus-fmt-build generates its name as that (`pub type Money =
//! haus::Coded<Cents>`) and the type without the codec, the codec's `Base`, as
//! `MoneyBase`. A package's types are generated in its own crate, without the
//! application's codecs: decode one of them as `Coded<C>`.
//!
//! ```
//! # use haus::{Codec, Coded, time::Date};
//! # pub struct Ymd;
//! # impl Codec for Ymd {
//! #     const ID: &'static str = Date::ID;
//! #     type Base = Date;
//! #     type Target = (u16, u8, u8);
//! #     fn decode(d: Date) -> Result<Self::Target, String> {
//! #         let p: Vec<&str> = d.as_str().split('-').collect();
//! #         Ok((p[0].parse().unwrap(), p[1].parse().unwrap(), p[2].parse().unwrap()))
//! #     }
//! #     fn encode(&(y, m, d): &Self::Target) -> Date { Date::new(format!("{y:04}-{m:02}-{d:02}")).unwrap() }
//! # }
//! let Coded(day) = haus::from_str::<Coded<Ymd>>(r#"Date("2026-11-25")"#).unwrap();
//! assert_eq!(day, (2026, 11, 25));
//! ```

use crate::json::{FromJson, Json, ToJson};
use crate::{Decode, DecodeError, Decoder, Encode, EncodeError, Encoder, Value};
use std::fmt;

pub trait Codec {
    /// The id of the type this codec is for: `@haus-fmt/money@1#Money`, `std/time#Date`.
    const ID: &'static str;
    /// That type, as decoded without the codec.
    type Base: Decode + Encode;
    /// The type the application gets.
    type Target;
    /// Runs after the base type has decoded: may reject more values, never fewer.
    ///
    /// `base` is the value as the schema decoded it, never what the codecs of
    /// its parts made of them (spec §13.4 leaves this to the binding): a
    /// codec for `Money` gets the `Currency` the schema decoded. A package's
    /// rule ([`crate::Rule`]) isn't a codec's job: generated code checks it
    /// before any codec of the type runs. Generated code runs the parts'
    /// codecs first (from the inside out), and the first that rejects gives
    /// the error.
    fn decode(base: Self::Base) -> Result<Self::Target, String>;
    /// Back to the base type: encoding what was decoded gives an equal value.
    fn encode(value: &Self::Target) -> Self::Base;
}

/// A value of the codec `C`'s type, decoded and encoded through the codec:
/// the type to decode a whole value with, so that its type's codec runs
/// (spec §13.4: `CHF` decoded as a `Currency` runs the codec for `Currency`).
/// The generated name of an application's type with a codec is this type.
/// Inside other types, generated code applies the codec itself.
pub struct Coded<C: Codec>(pub C::Target);

impl<C: Codec> Coded<C> {
    /// The codec's value.
    pub fn into_inner(self) -> C::Target {
        self.0
    }
}

impl<C: Codec> fmt::Debug for Coded<C>
where
    C::Target: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Coded").field(&self.0).finish()
    }
}

impl<C: Codec> Clone for Coded<C>
where
    C::Target: Clone,
{
    fn clone(&self) -> Self {
        Coded(self.0.clone())
    }
}

impl<C: Codec> PartialEq for Coded<C>
where
    C::Target: PartialEq,
{
    fn eq(&self, other: &Self) -> bool {
        self.0 == other.0
    }
}

impl<C: Codec> Decode for Coded<C> {
    fn decode_with(v: &Value, d: Decoder) -> Result<Self, DecodeError> {
        crate::de::codec::<C>(v, d).map(Coded)
    }
}

impl<C: Codec> Encode for Coded<C> {
    fn encode_with(&self, e: Encoder) -> Result<Value, EncodeError> {
        crate::ser::codec::<C>(&self.0, e)
    }
}

impl<C: Codec> FromJson for Coded<C>
where
    C::Base: FromJson,
{
    const NULLABLE: bool = <C::Base as FromJson>::NULLABLE;
    fn from_json_with(json: &Json, d: Decoder) -> Result<Self, DecodeError> {
        crate::json::de::codec::<C>(json, d).map(Coded)
    }
}

impl<C: Codec> ToJson for Coded<C>
where
    C::Base: ToJson,
{
    const NULLABLE: bool = <C::Base as ToJson>::NULLABLE;
    fn to_json_with(&self, e: Encoder) -> Result<Json, EncodeError> {
        crate::json::ser::codec::<C>(&self.0, e)
    }
}

/// String equality in a const context (for the generated id checks).
pub const fn same_id(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}
