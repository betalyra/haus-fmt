//! The haus data format.
//!
//! Without a schema, [`parse`] reads any haus text into [`Value`]s:
//!
//! ```
//! let values = haus::parse(r#"{ name: "Ada", born: Date("1815-12-10") }"#).unwrap();
//! assert_eq!(values[0].get("name"), Some(&haus::Value::String("Ada".into())));
//! ```
//!
//! That's a parser in the sense of spec §13.1: it reads the syntax and knows
//! no types. `Date("2026-02-30")` is just a tag with a string.
//!
//! With a schema, `haus-fmt-build` generates Rust types that implement [`Decode`]
//! and [`Encode`], and [`from_str`] / [`to_string`] check every rule of the
//! schema: closed records and variants, integer ranges, the std/time profile.
//! Writing checks the value too, since a [`Value`] built in code (the raw
//! value of an `Any`, say) may not be one a reader takes:
//!
//! ```
//! let fine = haus::Value::Number("1E5".into());
//! assert_eq!(haus::to_string(&fine).unwrap(), "1e5");
//! let wrong = haus::Value::Number("abc".into());
//! assert_eq!(haus::to_string(&wrong).unwrap_err().to_string(), "not a number literal");
//! ```
//!
//! [`json`] maps haus to JSON and back (spec §16): [`from_json`] reads any
//! JSON, [`to_lossless_json`] / [`from_lossless_json`] carry every value
//! unchanged, and generated types implement [`ToJson`] / [`FromJson`] for
//! the plain JSON of their type.
//!
//! [`format()`] writes a file in the standard layout (spec §11), keeping
//! comments and blank lines: the same text as the TypeScript formatter.

mod canonical;
mod codec;
pub mod de;
mod error;
#[rustfmt::skip]
mod error_codes;
mod float;
mod formatter;
pub mod json;
mod parser;
mod secret;
pub mod ser;
pub mod stream;
pub mod time;
mod value;

#[cfg(feature = "hash")]
pub use canonical::{Hasher, hash, hash_all};
pub use canonical::{canonical, compare, equals};
pub use codec::{Codec, same_id};
pub use de::{AnyTag, Bytes, Decimal, Decode, Decoder, Int, Unknown};
pub use error::{DecodeError, EncodeError, Error, ErrorCategory, ErrorCode, ErrorJson, Segment, SyntaxError};
pub use formatter::{FormatOptions, Style, format};
pub use json::{FromJson, Json, ToJson};
pub use parser::{Limits, MAX_SUPPORTED_DEPTH, parse_with};
pub use secret::Secret;
pub use ser::{Encode, Encoder};
pub use value::Value;

/// Include the Rust types haus-fmt-build generated for a schema:
/// `haus::include_schema!("order")` for `order.schema.haus`.
#[macro_export]
macro_rules! include_schema {
    ($name:literal) => {
        include!(concat!(env!("OUT_DIR"), "/", $name, ".rs"));
    };
}

/// Parse a file: zero or more top-level values, separated by commas.
pub fn parse(src: &str) -> Result<Vec<Value>, SyntaxError> {
    parse_with(src, &Limits::default())
}

/// Parse raw bytes, which must be UTF-8.
pub fn parse_bytes(src: &[u8]) -> Result<Vec<Value>, SyntaxError> {
    match std::str::from_utf8(src) {
        Ok(s) => parse(s),
        Err(e) => {
            let valid = std::str::from_utf8(&src[..e.valid_up_to()]).unwrap_or_default();
            Err(SyntaxError::at(valid, e.valid_up_to(), ErrorCode::InvalidUtf8, "invalid UTF-8"))
        }
    }
}

/// Read a file holding one value of type `T`.
pub fn from_str<T: Decode>(src: &str) -> Result<T, Error> {
    match parse(src)?.as_slice() {
        [v] => Ok(T::decode(v)?),
        vs => Err(DecodeError::new(ErrorCode::NotOneValue, format!("expected one value, found {}", vs.len()))
            .with_expected_found("one value", format!("{} values", vs.len()))
            .into()),
    }
}

/// Read a stream: every top-level value as a `T`.
pub fn from_str_all<T: Decode>(src: &str) -> Result<Vec<T>, Error> {
    parse(src)?.iter().enumerate().map(|(i, v)| T::decode(v).map_err(|e| e.index(i).into())).collect()
}

/// Write one value on one line (the compact layout, spec §11). Fails if the
/// value isn't one a reader with the default limits takes: one nested deeper
/// than the depth limit (checked while encoding, so a deep native value fails
/// at the limit), or a [`Value`] built in code that isn't valid, such as the
/// raw value of an `Any` or an unknown variant (spec §9.8): see
/// [`ser::write_with`]. An error inside a [`Secret`] names only the secret.
pub fn to_string<T: Encode + ?Sized>(value: &T) -> Result<String, EncodeError> {
    to_string_with(value, &Limits::default())
}

/// [`to_string`], for a reader with `limits`: the value must be within them,
/// and integers longer than its number limit are written in hex.
pub fn to_string_with<T: Encode + ?Sized>(value: &T, limits: &Limits) -> Result<String, EncodeError> {
    ser::write_with(&value.encode_with(Encoder::new(limits))?, limits)
}

/// Write a stream: one value per line, each followed by `,`. Errors say which value: `[3].total: …`.
pub fn to_string_all<T: Encode>(values: &[T]) -> Result<String, EncodeError> {
    values
        .iter()
        .enumerate()
        .map(|(i, v)| to_string(v).map(|line| line + ",\n").map_err(|e| e.within(Segment::Index(i))))
        .collect()
}

/// Read JSON without a schema (spec §16.1): an object as a record, an array
/// as an array, a string as a string, a number as a number (its literal
/// normalized: `1E+05` is `1e5`), `true` / `false` as `True` / `False`, and
/// `null` as `None`.
///
/// ```
/// let v = haus::from_json(r#"{"total": 19.90, "paid": true, "note": null}"#).unwrap();
/// assert_eq!(haus::canonical(&v), "{note:None,paid:True,total:19.90}");
/// ```
pub fn from_json(text: &str) -> Result<Value, Error> {
    json::value_from_str_with(text, &Limits::default())
}

/// Write a value in the lossless JSON form (spec §16.2): `19.90` is
/// `{"num":"19.90"}`, `Some(1)` is `{"tag":"Some","args":[{"num":"1"}]}`.
/// Fails, saying where, for a [`Value`] built in code that isn't a valid
/// haus value within the limits.
pub fn to_lossless_json(value: &Value) -> Result<String, EncodeError> {
    json::to_string(value)
}

/// Read the lossless JSON form (spec §16.2), and nothing else: a bare number,
/// `true`, `false`, `null` and objects with other members are errors.
pub fn from_lossless_json(text: &str) -> Result<Value, Error> {
    json::from_str(text)
}
