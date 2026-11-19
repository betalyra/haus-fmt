//! Reading schema-based JSON (spec §16.3) into Rust types: [`FromJson`] for the
//! prelude types, and the helpers that generated code calls.
//!
//! Errors name the place in the JSON: `.items[2].price`, `.values[1]`. Like
//! decoding haus, reading is linear in the input: objects are indexed once,
//! and a variant's case is chosen by its `"_tag"`.

use super::{FromJson, Json, base64};
use crate::de::{AnyTag, Bytes, Decimal, Int, Unknown};
use crate::{Codec, DecodeError, Decoder, EncodeError, ErrorCode as Code, Secret, Value};
use std::collections::{BTreeMap, HashMap};

type R<T> = Result<T, DecodeError>;

/// What a JSON value is, for messages: `a string`, `the number 1.5`.
/// Never the content of a string.
pub fn describe(json: &Json) -> String {
    match json {
        Json::Null => "null".into(),
        Json::Bool(b) => b.to_string(),
        Json::Number(n) => format!("the number {n}"),
        Json::String(_) => "a string".into(),
        Json::Array(_) => "an array".into(),
        Json::Object(_) => "an object".into(),
    }
}

/// `expected <what>, found <json>`: JSON of another kind (`type-mismatch`).
pub fn mismatch(what: &str, json: &Json) -> DecodeError {
    let found = describe(json);
    DecodeError::new(Code::TypeMismatch, format!("expected {what}, found {found}")).with_expected_found(what, found)
}

/// A number literal read from JSON that the limits don't take, or that isn't one.
fn number_error(e: EncodeError) -> DecodeError {
    match e.code {
        Code::CannotEncode => e.into_decode().with_code(Code::InvalidNumber),
        _ => e.into_decode(),
    }
}

// ── objects ──────────────────────────────────────────────────

/// An object, indexed by member name once: a record, or the payload of a
/// tag (whose `"_tag"` member is not one of its fields).
pub struct Object<'a> {
    members: &'a [(String, Json)],
    index: HashMap<&'a str, &'a Json>,
    /// A variant's object: its payload is a level, inside it.
    tagged: bool,
    /// A tag's object (a variant's, or the record of a record case read
    /// from one): `"_tag"` is not one of its members.
    in_tag: bool,
    /// Where the object is: for a record, inside it, where its fields are
    /// read; for a tag, outside it (its payload is a level).
    d: Decoder,
}

impl<'a> Object<'a> {
    /// `json` as a record, at `d`; `what` names the expected type in errors.
    pub fn new(json: &'a Json, d: Decoder, what: &str) -> R<Object<'a>> {
        let object = Object::any(json, d, what)?;
        Ok(Object { d: d.nested()?, in_tag: d.is_in_tag(), ..object })
    }

    /// `json` as an object, at `d`.
    fn any(json: &'a Json, d: Decoder, what: &str) -> R<Object<'a>> {
        match json {
            Json::Object(members) => {
                let index = members.iter().map(|(k, v)| (k.as_str(), v)).collect();
                Ok(Object { members, index, tagged: false, in_tag: false, d })
            }
            _ => Err(mismatch(&format!("an object ({what})"), json)),
        }
    }

    /// Where the fields or values are read: inside the record, or inside a
    /// tag's payload.
    pub fn inner(&self) -> R<Decoder> {
        if self.tagged { self.d.nested() } else { Ok(self.d) }
    }

    /// The members other than `"_tag"`, if the object is a tag's.
    fn fields(&self) -> impl Iterator<Item = &'a str> + '_ {
        self.members.iter().map(|(k, _)| k.as_str()).filter(|k| !self.in_tag || *k != "_tag")
    }

    /// A closed record has only the fields listed.
    pub fn closed(&self, known: &[&str]) -> R<()> {
        match self.fields().find(|k| !known.contains(k)) {
            // At the member, as when decoding (spec §17).
            Some(k) => {
                Err(DecodeError::new(Code::UnknownField, format!("unknown member {k:?} in a closed record")).field(k))
            }
            None => Ok(()),
        }
    }

    pub fn required<T>(&self, key: &str, f: impl FnOnce(&Json, Decoder) -> R<T>) -> R<T> {
        match self.index.get(key) {
            Some(v) => f(v, self.inner()?).map_err(|e| e.field(key)),
            None => Err(DecodeError::new(Code::MissingField, format!("missing member {key}"))
                .with_expected_found(format!("the member \"{key}\""), "none")),
        }
    }

    /// `key?: T`: the member may be missing (and is then missing in the result).
    pub fn optional<T>(&self, key: &str, f: impl FnOnce(&Json, Decoder) -> R<T>) -> R<Option<T>> {
        self.index.get(key).map(|v| f(v, self.inner()?).map_err(|e| e.field(key))).transpose()
    }

    /// The payload values of a positional case with `N` values: none, `"value"`
    /// for one, `"values"` (an array of `N`) for more. Nothing else may be there.
    pub fn args<const N: usize>(&self) -> R<[&'a Json; N]> {
        let name = match N {
            0 => None,
            1 => Some("value"),
            _ => Some("values"),
        };
        if let Some(other) = self.fields().find(|k| Some(*k) != name) {
            // At the member, as an unknown field of a closed record is (spec §15).
            return Err(DecodeError::new(Code::UnexpectedMember, format!("unexpected member {other:?}")).field(other));
        }
        let values: Vec<&Json> = match (name, name.and_then(|n| self.index.get(n))) {
            (None, _) => vec![],
            (Some(n), None) => {
                let e = DecodeError::new(Code::MissingMember, format!("missing member {n}"));
                return Err(e.with_expected(format!("\"{n}\"")));
            }
            (Some("value"), Some(v)) => vec![*v],
            (Some(_), Some(Json::Array(items))) if items.len() == N => items.iter().collect(),
            // A wrong payload is at the variant (spec §15, §16.3).
            (Some(n), Some(Json::Array(items))) => {
                let reason = format!("expected {N} values in \"{n}\", found {}", items.len());
                return Err(DecodeError::new(Code::WrongPayload, reason));
            }
            (Some(n), Some(v)) => {
                return Err(mismatch(&format!("an array of {N} values (\"{n}\")"), v).with_code(Code::WrongPayload));
            }
        };
        values.try_into().map_err(|_| DecodeError::new(Code::WrongPayload, "wrong number of values"))
    }

    /// A tag the variant doesn't list, as an unknown value (spec §16.3): only
    /// `"_tag"` is a tag without arguments; `"_tag"` and `"_args"` hold the
    /// arguments as self-describing values (§16.2, without the envelope);
    /// with other members, all of them are a record payload, read by the
    /// import (§16.1), so that a newer writer's case `{"_tag": "Hexagon",
    /// "sides": 6}` reads as `Hexagon { sides: 6 }`.
    pub fn unknown(&self, tag: &str) -> R<Unknown> {
        crate::ser::check_tag(tag, self.d.limits()).map_err(EncodeError::into_decode)?;
        let args = match (self.fields().collect::<Vec<_>>().as_slice(), self.index.get("_args")) {
            ([], _) => vec![],
            (["_args"], Some(Json::Array(items))) if !items.is_empty() => {
                // `Tag { … }`: the record is the payload's only level, as in self-describing JSON.
                let inner = match items.as_slice() {
                    [Json::Object(m)] if super::haus_json::is_record(m) => self.d,
                    _ => self.d.nested()?,
                };
                let read = |(i, x)| Value::from_json_with(x, inner).map_err(|e| e.index(i).field("_args"));
                items.iter().enumerate().map(read).collect::<R<_>>()?
            }
            (["_args"], Some(args)) => return Err(super::haus_json::bad_args(args)),
            _ => {
                let payload = self.members.iter().filter(|(k, _)| k != "_tag").cloned().collect();
                let (limits, depth) = (self.d.limits(), self.d.depth());
                vec![super::import::import_at(&Json::Object(payload), limits, depth)?]
            }
        };
        Ok(Unknown { tag: tag.to_owned(), args })
    }
}

/// A variant's object at `d`: its `"_tag"`, and the object, whose other
/// members are its payload. A `"_tag"` that isn't a string holding a tag
/// name is `invalid-tag` (spec §16.3), at the variant, as an unknown tag is.
pub fn variant<'a>(json: &'a Json, d: Decoder, what: &str) -> R<(&'a str, Object<'a>)> {
    let object = Object::any(json, d, what)?;
    match object.index.get("_tag") {
        Some(Json::String(tag)) if crate::ser::is_tag(tag) => {
            Ok((tag, Object { tagged: true, in_tag: true, ..object }))
        }
        Some(other) => Err(super::haus_json::tag_name(other, d.limits())
            .err()
            .unwrap_or_else(|| DecodeError::new(Code::InvalidTag, r#"expected a tag name in "_tag""#))),
        None => {
            let e = DecodeError::new(Code::MissingMember, format!(r#"expected an object with "_tag" ({what})"#));
            Err(e.with_expected(r#""_tag""#))
        }
    }
}

/// Payload value `i` of a case with `N`, read at `d` (inside the payload):
/// `.value`, or `.values[i]` in errors.
pub fn arg<const N: usize, T>(i: usize, json: &Json, d: Decoder, f: impl FnOnce(&Json, Decoder) -> R<T>) -> R<T> {
    f(json, d).map_err(|e| if N == 1 { e.field("value") } else { e.index(i).field("values") })
}

/// The record of a record case whose record is a named type (spec §15: `Box
/// BoxRec` with `type BoxRec = { w: Int32 }`), at `d`: read from the tag's
/// object `json`, whose members other than `"_tag"` are its fields, as for
/// `Box { w: Int32 }`.
pub fn record_case<T>(json: &Json, d: Decoder, f: impl FnOnce(&Json, Decoder) -> R<T>) -> R<T> {
    f(json, d.in_tag())
}

/// A closed variant whose tags have no payload: the tag as a string. A
/// string that isn't a tag name is `invalid-tag`, as in `"_tag"` (spec §16.3).
pub fn tag_name<'a>(json: &'a Json, what: &str) -> R<&'a str> {
    match json {
        Json::String(tag) if crate::ser::is_tag(tag) => Ok(tag),
        Json::String(_) => {
            let found = describe(json);
            let reason = format!("{found} is not a tag name (A to Z, then letters, digits and _); expected {what}");
            Err(DecodeError::new(Code::InvalidTag, reason).with_expected_found(what, found))
        }
        _ => Err(mismatch(&format!("a string ({what})"), json)),
    }
}

/// A case whose record payload has a field named `_tag` or `_args` (`field`):
/// it has no schema-based form (spec §16.3).
pub fn no_json_form(tag: &str, field: &str) -> DecodeError {
    DecodeError::new(Code::NoJsonForm, super::ser::no_json_form_reason(tag, field))
}

// ── containers ───────────────────────────────────────────────

/// `Array a`, at `d`.
pub fn array<T>(json: &Json, d: Decoder, f: impl Fn(&Json, Decoder) -> R<T>) -> R<Vec<T>> {
    match json {
        Json::Array(items) => {
            let inner = d.nested()?;
            items.iter().enumerate().map(|(i, x)| f(x, inner).map_err(|e| e.index(i))).collect()
        }
        _ => Err(mismatch("an array", json)),
    }
}

/// `Map v`, at `d`: an object used as a dictionary, whose member names are
/// the map's keys, within the string limit.
pub fn map<T>(json: &Json, d: Decoder, f: impl Fn(&Json, Decoder) -> R<T>) -> R<BTreeMap<String, T>> {
    match json {
        Json::Object(members) => {
            let inner = d.nested()?;
            members
                .iter()
                .map(|(k, x)| {
                    super::import::key(k, d.limits())?;
                    Ok((k.clone(), f(x, inner).map_err(|e| e.field(k))?))
                })
                .collect()
        }
        _ => Err(mismatch("an object (Map)", json)),
    }
}

/// `Maybe a`, at `d`: `null` or `a`, when `a`'s JSON can't be `null`
/// (`nullable` is false); otherwise `{"_tag": "None"}` or `{"_tag": "Some",
/// "value": …}`. `Some` is a level of the haus value either way.
pub fn maybe<T>(json: &Json, d: Decoder, nullable: bool, f: impl FnOnce(&Json, Decoder) -> R<T>) -> R<Option<T>> {
    match (nullable, json) {
        (false, Json::Null) => Ok(None),
        (false, _) => f(json, d.nested()?).map(Some),
        (true, _) => match variant(json, d, "Maybe")? {
            ("None", o) => o.args::<0>().map(|[]| None),
            ("Some", o) => {
                let [x] = o.args::<1>()?;
                arg::<1, _>(0, x, o.inner()?, f).map(Some)
            }
            (tag, _) => Err(crate::de::unknown_tag(tag, &["None", "Some"])),
        },
    }
}

/// `Result e a`, at `d`: `{"_tag": "Ok", "value": …}` or `{"_tag": "Err", "value": …}`.
pub fn result<A, E>(
    json: &Json,
    d: Decoder,
    ok: impl FnOnce(&Json, Decoder) -> R<A>,
    err: impl FnOnce(&Json, Decoder) -> R<E>,
) -> R<Result<A, E>> {
    match variant(json, d, "Result")? {
        ("Ok", o) => {
            let [x] = o.args::<1>()?;
            arg::<1, _>(0, x, o.inner()?, ok).map(Ok)
        }
        ("Err", o) => {
            let [x] = o.args::<1>()?;
            arg::<1, _>(0, x, o.inner()?, err).map(Err)
        }
        (tag, _) => Err(crate::de::unknown_tag(tag, &["Ok", "Err"])),
    }
}

/// `Secret a`: read as `a`, but an error says only that the value isn't a
/// valid `what` (`Secret String`), never what was found or where in it (spec §15).
pub fn secret<T>(json: &Json, d: Decoder, what: &str, f: impl FnOnce(&Json, Decoder) -> R<T>) -> R<Secret<T>> {
    f(json, d).map(Secret::new).map_err(|_| crate::de::hidden(what))
}

/// A type with a codec: its base type first, then the codec (spec §13.4).
pub fn codec<C: Codec>(json: &Json, d: Decoder) -> R<C::Target>
where
    C::Base: FromJson,
{
    C::decode(C::Base::from_json_with(json, d)?).map_err(|reason| DecodeError::new(Code::TypeMismatch, reason))
}

/// [`codec`] for a type that contains other codecs' types, which run first
/// (see [`crate::de::codec_inside_out`]).
pub fn codec_inside_out<C: Codec, Inner: FromJson>(json: &Json, d: Decoder) -> R<C::Target>
where
    C::Base: FromJson,
{
    Inner::from_json_with(json, d)?;
    codec::<C>(json, d)
}

impl<T: FromJson> FromJson for Vec<T> {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        array(json, d, T::from_json_with)
    }
}
impl<T: FromJson> FromJson for BTreeMap<String, T> {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        map(json, d, T::from_json_with)
    }
}
impl<T: FromJson> FromJson for Option<T> {
    const NULLABLE: bool = !T::NULLABLE;
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        maybe(json, d, T::NULLABLE, T::from_json_with)
    }
}
impl<A: FromJson, E: FromJson> FromJson for Result<A, E> {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        result(json, d, A::from_json_with, E::from_json_with)
    }
}
impl<T: FromJson> FromJson for Box<T> {
    const NULLABLE: bool = T::NULLABLE;
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        T::from_json_with(json, d).map(Box::new)
    }
}
impl<T: FromJson> FromJson for Secret<T> {
    const NULLABLE: bool = T::NULLABLE;
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        secret(json, d, "Secret", T::from_json_with)
    }
}

// ── scalars ──────────────────────────────────────────────────

/// `Any`: its self-describing value (spec §16.2), without the envelope,
/// within the limits.
impl FromJson for Value {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        super::haus_json::from_value_at(json, d.limits(), d.depth())
    }
}

/// `< >`: any tag, as an unknown value.
impl FromJson for AnyTag {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        let (tag, object) = variant(json, d, "a tag")?;
        let unknown = object.unknown(tag)?;
        Ok(if unknown.args.is_empty() { AnyTag::Bare(unknown.tag) } else { AnyTag::Other(unknown) })
    }
}

/// A string, within the string limit: its characters after escapes are read (spec §16).
impl FromJson for String {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        match json {
            Json::String(s) => {
                crate::ser::check_length(s, d.limits()).map_err(EncodeError::into_decode)?;
                Ok(s.clone())
            }
            _ => Err(mismatch("a string", json)),
        }
    }
}

/// `Bytes`: base64 with padding (RFC 4648 §4), within the string limit as
/// the haus byte string's hex: two characters per byte (spec §16).
impl FromJson for Bytes {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        let Json::String(text) = json else { return Err(mismatch("a base64 string (Bytes)", json)) };
        let bytes = base64::decode(text)
            .ok_or_else(|| DecodeError::new(Code::InvalidBase64, "not base64 with padding (Bytes)"))?;
        crate::ser::check_bytes(&bytes, d.limits()).map_err(EncodeError::into_decode)?;
        Ok(Bytes(bytes))
    }
}

impl FromJson for bool {
    fn from_json_with(json: &Json, _: Decoder) -> R<Self> {
        match json {
            Json::Bool(b) => Ok(*b),
            _ => Err(mismatch("true or false", json)),
        }
    }
}

/// The decimal integer of `text` (`-?(0|[1-9][0-9]*)`), `-0` as `0`; None otherwise.
fn integer(text: &str) -> Option<&str> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    let canonical = digits == "0" || (digits.starts_with(|c: char| ('1'..='9').contains(&c)));
    (canonical && digits.bytes().all(|c| c.is_ascii_digit())).then_some(if digits == "0" { digits } else { text })
}

/// Integers that fit a float exactly: a JSON number, whole by its spelling.
macro_rules! numbers {
    ($($t:ty => $name:literal),*) => {$(
        impl FromJson for $t {
            fn from_json_with(json: &Json, _: Decoder) -> R<Self> {
                let Json::Number(text) = json else { return Err(mismatch(concat!("a number (", $name, ")"), json)) };
                let n = integer(text).ok_or_else(|| {
                    DecodeError::new(Code::NotAnInteger, format!("expected a whole number ({}), found {text}", $name))
                        .with_expected_found($name, text.as_str())
                })?;
                n.parse().map_err(|_| out_of_range(text, $name, <$t>::MIN, <$t>::MAX))
            }
        }
    )*};
}
numbers!(i8 => "Int8", i16 => "Int16", i32 => "Int32", u8 => "UInt8", u16 => "UInt16", u32 => "UInt32");

/// `text` is out of `name`'s range, `min` to `max`.
fn out_of_range(text: &str, name: &str, min: impl std::fmt::Display, max: impl std::fmt::Display) -> DecodeError {
    let range = format!("{name} ({min} to {max})");
    DecodeError::new(Code::OutOfRange, format!("{text} is out of range for {range}")).with_expected_found(range, text)
}

/// The decimal integer in a JSON string (`Int`, `Int64`, `UInt64`).
fn integer_string<'a>(json: &'a Json, name: &str) -> R<&'a str> {
    match json {
        Json::String(text) => integer(text).ok_or_else(|| {
            let code = if super::is_number(text) { Code::NotAnInteger } else { Code::InvalidNumber };
            DecodeError::new(code, format!("expected a decimal integer in a string ({name})"))
        }),
        _ => Err(mismatch(&format!("a string holding a decimal integer ({name})"), json)),
    }
}

macro_rules! strings {
    ($($t:ty => $name:literal),*) => {$(
        impl FromJson for $t {
            fn from_json_with(json: &Json, _: Decoder) -> R<Self> {
                let n = integer_string(json, $name)?;
                n.parse().map_err(|_| out_of_range(n, $name, <$t>::MIN, <$t>::MAX))
            }
        }
    )*};
}
strings!(i64 => "Int64", u64 => "UInt64");

/// `Int`: a string, the decimal integer of any size (within the number limits).
impl FromJson for Int {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        let n = integer_string(json, "Int")?;
        crate::ser::normalized(n, d.limits()).map_err(number_error)?;
        Ok(Int(n.to_owned()))
    }
}

/// `Decimal`: a string holding a number (`"19.90"`, `"1E+05"`), kept as its normalized literal.
impl FromJson for Decimal {
    fn from_json_with(json: &Json, d: Decoder) -> R<Self> {
        match json {
            Json::String(text) if super::is_number(text) => {
                let n = super::import::normalize_number(text);
                crate::ser::normalized(&n, d.limits()).map_err(number_error)?;
                Ok(Decimal(n))
            }
            Json::String(_) => Err(DecodeError::new(Code::InvalidNumber, "expected a number in a string (Decimal)")),
            _ => Err(mismatch("a string holding a number (Decimal)", json)),
        }
    }
}

/// `Float32` and `Float64`: a number rounded to the type (spec §15), or the
/// strings `"NaN"`, `"Infinity"` and `"-Infinity"`. A number too large for
/// the type is an error.
macro_rules! floats {
    ($($t:ty => $name:literal),*) => {$(
        impl FromJson for $t {
            fn from_json_with(json: &Json, _: Decoder) -> R<Self> {
                match json {
                    Json::Number(text) => match text.parse::<$t>() {
                        Ok(x) if x.is_finite() => Ok(x),
                        Ok(_) => Err(DecodeError::new(Code::OutOfRange, format!("{text} is too large for {}", $name))
                            .with_expected_found($name, text.as_str())),
                        Err(_) => Err(DecodeError::new(Code::TypeMismatch, format!("{text} is not a {}", $name))),
                    },
                    Json::String(s) if s == "NaN" => Ok(<$t>::NAN),
                    Json::String(s) if s == "Infinity" => Ok(<$t>::INFINITY),
                    Json::String(s) if s == "-Infinity" => Ok(<$t>::NEG_INFINITY),
                    _ => Err(mismatch(concat!("a number, \"NaN\", \"Infinity\" or \"-Infinity\" (", $name, ")"), json)),
                }
            }
        }
    )*};
}
floats!(f32 => "Float32", f64 => "Float64");

/// std/time: the string as written, checked by the profile.
macro_rules! times {
    ($($name:ident),*) => {$(
        impl FromJson for crate::time::$name {
            fn from_json_with(json: &Json, _: Decoder) -> R<Self> {
                match json {
                    Json::String(s) => {
                        crate::time::$name::new(s.as_str()).map_err(|e| DecodeError::new(Code::InvalidTime, e))
                    }
                    _ => Err(mismatch(concat!("a string (", stringify!($name), ")"), json)),
                }
            }
        }
    )*};
}
times!(Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone);
