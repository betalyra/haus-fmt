//! Reading plain JSON (spec §16.3) into Rust types: [`FromJson`] for the
//! prelude types, and the helpers that generated code calls.
//!
//! Errors name the place in the JSON: `.items[2].price`, `.values[1]`. Like
//! decoding haus, reading is linear in the input: objects are indexed once,
//! and a variant's case is chosen by its `"_tag"`.

use super::{FromJson, Json, base64};
use crate::de::{AnyTag, Bytes, Decimal, Int, Unknown};
use crate::{Codec, DecodeError, Limits, Secret, Value};
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

/// `expected <what>, found <json>`.
pub fn mismatch(what: &str, json: &Json) -> DecodeError {
    DecodeError::new(format!("expected {what}, found {}", describe(json)))
}

// ── objects ──────────────────────────────────────────────────

/// An object, indexed by member name once: a record, or the payload of a
/// tag (whose `"_tag"` member is not one of its fields).
pub struct Object<'a> {
    members: &'a [(String, Json)],
    index: HashMap<&'a str, &'a Json>,
    tagged: bool,
}

impl<'a> Object<'a> {
    /// `json` as an object; `what` names the expected type in errors.
    pub fn new(json: &'a Json, what: &str) -> R<Object<'a>> {
        match json {
            Json::Object(members) => {
                Ok(Object { members, index: members.iter().map(|(k, v)| (k.as_str(), v)).collect(), tagged: false })
            }
            _ => Err(mismatch(&format!("an object ({what})"), json)),
        }
    }

    /// The members other than `"_tag"`, if the object is tagged.
    fn fields(&self) -> impl Iterator<Item = &'a str> + '_ {
        self.members.iter().map(|(k, _)| k.as_str()).filter(|k| !self.tagged || *k != "_tag")
    }

    /// A closed record has only the fields listed.
    pub fn closed(&self, known: &[&str]) -> R<()> {
        match self.fields().find(|k| !known.contains(k)) {
            Some(k) => Err(DecodeError::new(format!("unknown member {k:?} in a closed record"))),
            None => Ok(()),
        }
    }

    pub fn required<T>(&self, key: &str, f: impl FnOnce(&Json) -> R<T>) -> R<T> {
        match self.index.get(key) {
            Some(v) => f(v).map_err(|e| e.field(key)),
            None => Err(DecodeError::new(format!("missing member {key}"))),
        }
    }

    /// `key?: T`: the member may be missing (and is then missing in the result).
    pub fn optional<T>(&self, key: &str, f: impl FnOnce(&Json) -> R<T>) -> R<Option<T>> {
        self.index.get(key).map(|v| f(v).map_err(|e| e.field(key))).transpose()
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
            return Err(DecodeError::new(format!("unexpected member {other:?}")));
        }
        let values: Vec<&Json> = match (name, name.and_then(|n| self.index.get(n))) {
            (None, _) => vec![],
            (Some(n), None) => return Err(DecodeError::new(format!("missing member {n}"))),
            (Some("value"), Some(v)) => vec![*v],
            (Some(_), Some(Json::Array(items))) if items.len() == N => items.iter().collect(),
            (Some(n), Some(Json::Array(items))) => {
                return Err(DecodeError::new(format!("expected {N} values, found {}", items.len())).field(n));
            }
            (Some(n), Some(v)) => return Err(mismatch("an array", v).field(n)),
        };
        values.try_into().map_err(|_| DecodeError::new("wrong number of values"))
    }

    /// A tag the variant doesn't list, as an unknown value (spec §16.3): only
    /// `"_tag"` is a tag without arguments; `"_tag"` and `"args"` hold the
    /// arguments in the lossless form; other members are a record payload,
    /// read without a schema (§16.1), so that a newer writer's case
    /// `{"_tag": "Hexagon", "sides": 6}` reads as `Hexagon { sides: 6 }`.
    pub fn unknown(&self, tag: &str) -> R<Unknown> {
        if !crate::ser::is_tag(tag) {
            return Err(DecodeError::new(format!("{tag:?} is not a tag name")).field("_tag"));
        }
        let limits = Limits::default();
        let args = match (self.fields().collect::<Vec<_>>().as_slice(), self.index.get("args")) {
            ([], _) => vec![],
            (["args"], Some(Json::Array(items))) if items.is_empty() => {
                return Err(DecodeError::new(r#"a tag without arguments has no "args""#).field("args"));
            }
            (["args"], Some(Json::Array(items))) => items
                .iter()
                .enumerate()
                .map(|(i, x)| Value::from_json(x).map_err(|e| e.index(i).field("args")))
                .collect::<R<_>>()?,
            (["args"], Some(other)) => return Err(mismatch("an array", other).field("args")),
            _ => {
                let payload = self.members.iter().filter(|(k, _)| k != "_tag").cloned().collect();
                vec![super::from_plain(&Json::Object(payload), &limits)?]
            }
        };
        Ok(Unknown { tag: tag.to_owned(), args })
    }
}

/// A variant's object: its `"_tag"`, and the object, whose other members are its payload.
pub fn variant<'a>(json: &'a Json, what: &str) -> R<(&'a str, Object<'a>)> {
    let object = Object::new(json, what)?;
    match object.index.get("_tag") {
        Some(Json::String(tag)) => Ok((tag, Object { tagged: true, ..object })),
        Some(other) => Err(mismatch("a string", other).field("_tag")),
        None => Err(DecodeError::new(format!(r#"expected an object with "_tag" ({what})"#))),
    }
}

/// Payload value `i` of a case with `N`: `.value`, or `.values[i]` in errors.
pub fn arg<const N: usize, T>(i: usize, json: &Json, f: impl FnOnce(&Json) -> R<T>) -> R<T> {
    f(json).map_err(|e| if N == 1 { e.field("value") } else { e.index(i).field("values") })
}

/// A closed variant whose tags have no payload: the tag as a string.
pub fn tag_name<'a>(json: &'a Json, what: &str) -> R<&'a str> {
    match json {
        Json::String(tag) => Ok(tag),
        _ => Err(mismatch(&format!("a string ({what})"), json)),
    }
}

/// A case whose record payload has a field named `_tag`: it has no plain form (spec §16.3).
pub fn no_plain_form(tag: &str) -> DecodeError {
    DecodeError::new(format!("{tag} has a field named _tag, so it has no plain JSON form"))
}

// ── containers ───────────────────────────────────────────────

/// `Array a`.
pub fn array<T>(json: &Json, f: impl Fn(&Json) -> R<T>) -> R<Vec<T>> {
    match json {
        Json::Array(items) => items.iter().enumerate().map(|(i, x)| f(x).map_err(|e| e.index(i))).collect(),
        _ => Err(mismatch("an array", json)),
    }
}

/// `Map v`: an object used as a dictionary.
pub fn map<T>(json: &Json, f: impl Fn(&Json) -> R<T>) -> R<BTreeMap<String, T>> {
    match json {
        Json::Object(members) => members.iter().map(|(k, x)| Ok((k.clone(), f(x).map_err(|e| e.field(k))?))).collect(),
        _ => Err(mismatch("an object (Map)", json)),
    }
}

/// `Maybe a`: `null` or `a`, when `a`'s JSON can't be `null` (`nullable` is
/// false); otherwise `{"_tag": "None"}` or `{"_tag": "Some", "value": …}`.
pub fn maybe<T>(json: &Json, nullable: bool, f: impl FnOnce(&Json) -> R<T>) -> R<Option<T>> {
    match (nullable, json) {
        (false, Json::Null) => Ok(None),
        (false, _) => f(json).map(Some),
        (true, _) => match variant(json, "Maybe")? {
            ("None", o) => o.args::<0>().map(|[]| None),
            ("Some", o) => {
                let [x] = o.args::<1>()?;
                arg::<1, _>(0, x, f).map(Some)
            }
            (tag, _) => Err(crate::de::unknown_tag(tag, &["None", "Some"]).field("_tag")),
        },
    }
}

/// `Result e a`: `{"_tag": "Ok", "value": …}` or `{"_tag": "Err", "value": …}`.
pub fn result<A, E>(json: &Json, ok: impl FnOnce(&Json) -> R<A>, err: impl FnOnce(&Json) -> R<E>) -> R<Result<A, E>> {
    match variant(json, "Result")? {
        ("Ok", o) => {
            let [x] = o.args::<1>()?;
            arg::<1, _>(0, x, ok).map(Ok)
        }
        ("Err", o) => {
            let [x] = o.args::<1>()?;
            arg::<1, _>(0, x, err).map(Err)
        }
        (tag, _) => Err(crate::de::unknown_tag(tag, &["Ok", "Err"]).field("_tag")),
    }
}

/// `Secret a`: read as `a`, but an error says only that the value isn't a
/// valid `what` (`Secret String`), never what was found or where in it (spec §15).
pub fn secret<T>(json: &Json, what: &str, f: impl FnOnce(&Json) -> R<T>) -> R<Secret<T>> {
    f(json).map(Secret::new).map_err(|_| DecodeError::new(format!("not a valid {what} (the value is hidden)")))
}

/// A type with a codec: its base type first, then the codec (spec §13.4).
pub fn codec<C: Codec>(json: &Json) -> R<C::Target>
where
    C::Base: FromJson,
{
    C::decode(C::Base::from_json(json)?).map_err(DecodeError::new)
}

impl<T: FromJson> FromJson for Vec<T> {
    fn from_json(json: &Json) -> R<Self> {
        array(json, T::from_json)
    }
}
impl<T: FromJson> FromJson for BTreeMap<String, T> {
    fn from_json(json: &Json) -> R<Self> {
        map(json, T::from_json)
    }
}
impl<T: FromJson> FromJson for Option<T> {
    const NULLABLE: bool = !T::NULLABLE;
    fn from_json(json: &Json) -> R<Self> {
        maybe(json, T::NULLABLE, T::from_json)
    }
}
impl<A: FromJson, E: FromJson> FromJson for Result<A, E> {
    fn from_json(json: &Json) -> R<Self> {
        result(json, A::from_json, E::from_json)
    }
}
impl<T: FromJson> FromJson for Box<T> {
    const NULLABLE: bool = T::NULLABLE;
    fn from_json(json: &Json) -> R<Self> {
        T::from_json(json).map(Box::new)
    }
}
impl<T: FromJson> FromJson for Secret<T> {
    const NULLABLE: bool = T::NULLABLE;
    fn from_json(json: &Json) -> R<Self> {
        secret(json, "Secret", T::from_json)
    }
}

// ── scalars ──────────────────────────────────────────────────

/// `Any`: the lossless form (spec §16.2), within the default limits.
impl FromJson for Value {
    fn from_json(json: &Json) -> R<Self> {
        super::from_lossless(json, &Limits::default())
    }
}

/// `< >`: any tag, as an unknown value.
impl FromJson for AnyTag {
    fn from_json(json: &Json) -> R<Self> {
        let (tag, object) = variant(json, "a tag")?;
        let unknown = object.unknown(tag)?;
        Ok(if unknown.args.is_empty() { AnyTag::Bare(unknown.tag) } else { AnyTag::Other(unknown) })
    }
}

impl FromJson for String {
    fn from_json(json: &Json) -> R<Self> {
        match json {
            Json::String(s) => Ok(s.clone()),
            _ => Err(mismatch("a string", json)),
        }
    }
}

/// `Bytes`: base64 with padding (RFC 4648 §4).
impl FromJson for Bytes {
    fn from_json(json: &Json) -> R<Self> {
        let Json::String(text) = json else { return Err(mismatch("a base64 string (Bytes)", json)) };
        let bytes = base64::decode(text).ok_or_else(|| DecodeError::new("not base64 with padding (Bytes)"))?;
        let max = Limits::default().max_string_length / 2;
        if bytes.len() > max {
            return Err(DecodeError::new(format!("more than {max} bytes")));
        }
        Ok(Bytes(bytes))
    }
}

impl FromJson for bool {
    fn from_json(json: &Json) -> R<Self> {
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
            fn from_json(json: &Json) -> R<Self> {
                let Json::Number(text) = json else { return Err(mismatch(concat!("a number (", $name, ")"), json)) };
                let n = integer(text)
                    .ok_or_else(|| DecodeError::new(format!("expected a whole number ({}), found {text}", $name)))?;
                n.parse().map_err(|_| DecodeError::new(format!(
                    "{text} is out of range for {} ({} to {})", $name, <$t>::MIN, <$t>::MAX
                )))
            }
        }
    )*};
}
numbers!(i8 => "Int8", i16 => "Int16", i32 => "Int32", u8 => "UInt8", u16 => "UInt16", u32 => "UInt32");

/// The decimal integer in a JSON string (`Int`, `Int64`, `UInt64`).
fn integer_string<'a>(json: &'a Json, name: &str) -> R<&'a str> {
    match json {
        Json::String(text) => {
            integer(text).ok_or_else(|| DecodeError::new(format!("expected a decimal integer in a string ({name})")))
        }
        _ => Err(mismatch(&format!("a string holding a decimal integer ({name})"), json)),
    }
}

macro_rules! strings {
    ($($t:ty => $name:literal),*) => {$(
        impl FromJson for $t {
            fn from_json(json: &Json) -> R<Self> {
                let n = integer_string(json, $name)?;
                n.parse().map_err(|_| DecodeError::new(format!(
                    "{n} is out of range for {} ({} to {})", $name, <$t>::MIN, <$t>::MAX
                )))
            }
        }
    )*};
}
strings!(i64 => "Int64", u64 => "UInt64");

/// `Int`: a string, the decimal integer of any size (within the number limits).
impl FromJson for Int {
    fn from_json(json: &Json) -> R<Self> {
        let n = integer_string(json, "Int")?;
        crate::ser::normalized(n, &Limits::default()).map_err(DecodeError::new)?;
        Ok(Int(n.to_owned()))
    }
}

/// `Decimal`: a string holding a number (`"19.90"`, `"1E+05"`), kept as its normalized literal.
impl FromJson for Decimal {
    fn from_json(json: &Json) -> R<Self> {
        match json {
            Json::String(text) if super::is_number(text) => {
                let n = super::lossless::normalize_number(text);
                crate::ser::normalized(&n, &Limits::default()).map_err(DecodeError::new)?;
                Ok(Decimal(n))
            }
            Json::String(_) => Err(DecodeError::new("expected a number in a string (Decimal)")),
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
            fn from_json(json: &Json) -> R<Self> {
                match json {
                    Json::Number(text) => match text.parse::<$t>() {
                        Ok(x) if x.is_finite() => Ok(x),
                        Ok(_) => Err(DecodeError::new(format!("{text} is too large for {}", $name))),
                        Err(_) => Err(DecodeError::new(format!("{text} is not a {}", $name))),
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
            fn from_json(json: &Json) -> R<Self> {
                match json {
                    Json::String(s) => crate::time::$name::new(s.as_str()).map_err(DecodeError::new),
                    _ => Err(mismatch(concat!("a string (", stringify!($name), ")"), json)),
                }
            }
        }
    )*};
}
times!(Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone);
