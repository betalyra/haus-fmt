//! The haus data format.
//!
//! Without a schema, [`parse`] reads any haus text into [`Value`]s:
//!
//! ```
//! let values = haus::parse(r#"{ name: "Ada", born: Date("1815-12-10") }"#).unwrap();
//! assert_eq!(values[0].get("name"), Some(&haus::Value::string("Ada").unwrap()));
//! ```
//!
//! That's a parser in the sense of spec §13.1: it reads the syntax and knows
//! no types. `Date("2026-02-30")` is just a tag with a string.
//!
//! With a schema, `haus-fmt-build` generates Rust types that implement [`Decode`]
//! and [`Encode`], and [`from_str`] / [`to_string`] check every rule of the
//! schema: closed records and variants, integer ranges, the std/time profile,
//! and the rules of the packages it imports ([`Rule`]).
//!
//! A [`Value`] built in code (the raw value of an `Any`, say) is a haus value
//! too: building is the one step that can fail. Its constructors reject what
//! isn't one and what is beyond the default limits of spec §7, with the code
//! of the mistake ([`ValueError`]), and normalize numbers as the parser reads
//! them. A value that exists is written ([`ser::write`], [`to_haus_json`]),
//! and has a canonical form, a hash, equality and order, without any error
//! (spec §11, §12):
//!
//! ```
//! use haus::{ErrorCode, Value};
//! let fine = Value::number("1E5").unwrap();
//! assert_eq!(haus::ser::write(&fine), "1e5");
//! assert_eq!(Value::number("abc").unwrap_err().code, ErrorCode::InvalidNumber);
//! assert_eq!(Value::number("1e9999").unwrap_err().code, ErrorCode::ExponentTooLarge);
//! assert_eq!(Value::variant("lower", vec![]).unwrap_err().code, ErrorCode::InvalidTag);
//! ```
//!
//! Values don't change once built (spec §11): their parts are reached by
//! shared reference only. So the safety net of spec §11, `value-changed`,
//! which other bindings raise for a value changed after it was built, never
//! arises in Rust, and no function here returns it.
//!
//! Encoding a [`Secret`] is refused (`cannot-encode`, at the secret) unless
//! the encoder reveals secrets ([`Encoder::reveal_secrets`], spec §15).
//!
//! [`json`] connects haus and JSON (spec §16): generated types implement
//! [`ToJson`] / [`FromJson`] for the schema-based JSON of their type,
//! [`to_haus_json`] / [`from_haus_json`] carry every value unchanged as
//! self-describing JSON, and [`import_json`] reads any JSON.
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
mod keys;
mod parser;
mod rule;
mod scan;
mod secret;
pub mod ser;
pub mod stream;
pub mod time;
mod value;

pub use canonical::{canonical, compare, equals};
#[cfg(feature = "hash")]
pub use canonical::{hash, hash_all};
pub use codec::{Codec, Coded, same_id};
pub use de::{AnyTag, Bytes, Decimal, Decode, Decoder, Int, Unknown};
pub use error::{
    DecodeError, EncodeError, Error, ErrorCategory, ErrorCode, ErrorJson, Segment, SyntaxError, ValueError,
};
pub use formatter::{FormatOptions, Style, format, has_comments};
pub use json::{FromJson, Json, ToJson};
pub use parser::{DEBUG_DEPTH, Limits, MAX_SUPPORTED_DEPTH, parse_with};
pub use rule::Rule;
pub use secret::Secret;
pub use ser::{Encode, Encoder};
pub use value::{ByteString, IntoValue, List, Number, Record, Tag, Text, Value};

// Every type a program shares between threads is Send and Sync (checked
// here, at compile time): values, options and limits are plain data, and
// parsing, writing, formatting, the canonical form, hashing and equality
// keep their state in the call. An encoding's step budget is counted in a
// thread-local cell, keyed by the encoding, so encodings on different
// threads never share it.
const _: () = {
    const fn shared<T: Send + Sync>() {}
    shared::<Value>();
    shared::<Number>();
    shared::<Tag>();
    shared::<Text>();
    shared::<ByteString>();
    shared::<List>();
    shared::<Record>();
    shared::<ValueError>();
    shared::<Limits>();
    shared::<FormatOptions>();
    shared::<Style>();
    shared::<Error>();
    shared::<SyntaxError>();
    shared::<DecodeError>();
    shared::<EncodeError>();
    shared::<ErrorCode>();
    shared::<Decoder>();
    shared::<Encoder>();
    shared::<Json>();
    shared::<json::JsonObject>();
    shared::<Int>();
    shared::<Decimal>();
    shared::<Bytes>();
    shared::<Unknown>();
    shared::<AnyTag>();
    shared::<Secret<String>>();
    shared::<stream::Options>();
    shared::<stream::Reader>();
    shared::<stream::Values<std::io::Empty>>();
    shared::<time::Date>();
    shared::<time::Instant>();
};

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

/// Parse a single document: exactly one value, with an optional comma after
/// it (spec §6). An input with no value, or with more than one, is
/// `not-one-value`, reported at the end of the input; any syntax error in it
/// comes first.
///
/// ```
/// assert_eq!(haus::parse_one("1,").unwrap(), haus::Value::from(1));
/// let e = haus::parse_one("1, 2").unwrap_err();
/// assert_eq!((e.code, e.line, e.column), (haus::ErrorCode::NotOneValue, 1, 5));
/// ```
pub fn parse_one(src: &str) -> Result<Value, SyntaxError> {
    parse_one_with(src, &Limits::default())
}

/// [`parse_one`] with the given limits.
pub fn parse_one_with(src: &str, limits: &Limits) -> Result<Value, SyntaxError> {
    let mut values = parse_with(src, limits)?;
    match values.len() {
        1 => Ok(values.swap_remove(0)),
        n => Err(SyntaxError::at(
            src,
            src.len(),
            ErrorCode::NotOneValue,
            format!("expected one value, found {}", if n == 0 { "none".to_owned() } else { n.to_string() }),
        )),
    }
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

/// Text from data as error messages show it (spec §9): control, bidi and
/// line-separator characters as `\u{…}`, then at most 40 characters as
/// shown, a longer text cut and marked with `…`. For the messages of codecs,
/// which quote what they reject as the binding's own messages do.
///
/// ```
/// assert_eq!(haus::for_message("a\u{202E}b"), r"a\u{202E}b");
/// assert_eq!(haus::for_message(&"x".repeat(50)), format!("{}…", "x".repeat(39)));
/// ```
pub fn for_message(text: &str) -> String {
    scan::shown(text)
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

/// Encode a value and write it on one line (the compact layout, spec §11).
/// Encoding fails for a value beyond the default limits (checked as it is
/// encoded, so a deep native value fails at the limit), and for a
/// [`Secret`], which is written only by an encoder that reveals secrets
/// ([`to_string_with`], [`Encoder::reveal_secrets`]); an error inside a
/// secret names only the secret. A [`Value`] is written as it is: writing
/// it can't fail ([`ser::write`]).
pub fn to_string<T: Encode + ?Sized>(value: &T) -> Result<String, EncodeError> {
    to_string_with(value, Encoder::default())
}

/// [`to_string`], encoded with `e`: the limits of the reader it is for
/// (`Encoder::new(&limits)`, integers included, which are written in
/// decimal), and whether secrets are written (`.reveal_secrets()`).
///
/// ```
/// let key = haus::Secret::new("sk-123".to_owned());
/// let e = haus::Encoder::default().reveal_secrets();
/// assert_eq!(haus::to_string_with(&key, e).unwrap(), r#""sk-123""#);
/// ```
pub fn to_string_with<T: Encode + ?Sized>(value: &T, e: Encoder) -> Result<String, EncodeError> {
    match value.as_value() {
        Some(v) => Ok(ser::write(v)),
        None => Ok(ser::write(&value.encode_with(e.restarted())?)),
    }
}

/// Encode a value and write it on one line in the minimised layout (spec
/// §11): the compact layout of [`to_string`] without the whitespace between
/// tokens, for the wire and storage. Fails as [`to_string`] does.
///
/// ```
/// let v = haus::parse(r#"Person { name: "Ada", tags: [1, 2] }"#).unwrap();
/// assert_eq!(haus::to_string_minimised(&v[0]).unwrap(), r#"Person{name:"Ada",tags:[1,2]}"#);
/// ```
pub fn to_string_minimised<T: Encode + ?Sized>(value: &T) -> Result<String, EncodeError> {
    to_string_minimised_with(value, Encoder::default())
}

/// [`to_string_minimised`], encoded with `e` (see [`to_string_with`]).
pub fn to_string_minimised_with<T: Encode + ?Sized>(value: &T, e: Encoder) -> Result<String, EncodeError> {
    match value.as_value() {
        Some(v) => Ok(ser::write_minimised(v)),
        None => Ok(ser::write_minimised(&value.encode_with(e.restarted())?)),
    }
}

/// Write a stream: one value per line, each followed by `,`. Errors say which value: `[3].total: …`.
pub fn to_string_all<T: Encode>(values: &[T]) -> Result<String, EncodeError> {
    values.iter().enumerate().map(|(i, v)| to_string(v).map(|line| line + ",\n").map_err(|e| e.item(i))).collect()
}

/// Read any JSON as a haus value, without a schema (JSON import, spec
/// §16.1): an object as a record, an array as an array, a string as a
/// string, a number as a number (its literal normalized: `1E+05` is `1e5`),
/// `true` / `false` as `True` / `False`, and `null` as `None`. Nothing in the
/// data is special: `_tag` and an envelope are record keys.
///
/// ```
/// let v = haus::import_json(r#"{"total": 19.90, "paid": true, "note": null}"#).unwrap();
/// assert_eq!(haus::canonical(&v), "{note:None,paid:True,total:19.90}");
/// ```
pub fn import_json(text: &str) -> Result<Value, Error> {
    json::import_json_with(text, &Limits::default())
}

/// Write a value as self-describing JSON (spec §16.2), in its envelope:
/// `19.90` is `{"_haus":1,"_value":{"_num":"19.90"}}`, `Some(1)` is
/// `{"_haus":1,"_value":{"_tag":"Some","_args":[{"_num":"1"}]}}`. It can't
/// fail: a value that exists is within the limits it was built with.
pub fn to_haus_json(value: &Value) -> String {
    json::write_unchecked(&json::to_self_describing(value))
}

/// Read self-describing JSON (spec §16.2), and nothing else: a text without
/// the envelope (`haus-json-form`), a `_haus` other than 1
/// (`haus-json-version`), a bare number, `true`, `false`, `null`, objects
/// with other members, and raw DEL, C1 or bidi controls in strings are
/// errors. To read ordinary JSON, use a schema ([`json::from_str`]) or
/// [`import_json`].
///
/// ```
/// let v = haus::from_haus_json(r#"{"_haus": 1, "_value": {"_num": "19.90"}}"#).unwrap();
/// assert_eq!(haus::canonical(&v), "19.90");
/// assert!(haus::from_haus_json(r#"{"_num": "19.90"}"#).is_err());
/// ```
pub fn from_haus_json(text: &str) -> Result<Value, Error> {
    json::from_haus_json_with(text, &Limits::default())
}
