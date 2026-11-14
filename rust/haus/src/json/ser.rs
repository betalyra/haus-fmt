//! Writing Rust values as plain JSON (spec §16.3): [`ToJson`] for the
//! prelude types, and the helpers that generated code calls.

use super::{Json, ToJson, base64};
use crate::de::{AnyTag, Bytes, Decimal, Int, Unknown};
use crate::{Codec, EncodeError, Limits, Secret, Segment, Value};
use std::collections::BTreeMap;

type R = Result<Json, EncodeError>;

fn member(name: &str, json: Json) -> (String, Json) {
    (name.to_owned(), json)
}

/// An object from fields in order, leaving out missing optional ones.
pub fn object<const N: usize>(fields: [(&str, Option<R>); N]) -> R {
    fields
        .into_iter()
        .filter_map(|(k, v)| Some(v?.map(|v| member(k, v)).map_err(|e| e.within(Segment::Field(k.to_owned())))))
        .collect::<Result<_, _>>()
        .map(Json::Object)
}

/// A case with a record payload: `{"_tag": "Circle", "r": 1.5}`.
pub fn tagged_object<const N: usize>(tag: &str, fields: [(&str, Option<R>); N]) -> R {
    match object(fields)? {
        Json::Object(members) => {
            Ok(Json::Object([member("_tag", Json::String(tag.to_owned()))].into_iter().chain(members).collect()))
        }
        other => Ok(other),
    }
}

/// A case with `N` positional values: `{"_tag": "Empty"}`, `{"_tag": "Wrap",
/// "value": 3}`, `{"_tag": "Point", "values": [1, 2]}`.
pub fn tagged<const N: usize>(tag: &str, values: [R; N]) -> R {
    let tag_member = member("_tag", Json::String(tag.to_owned()));
    let mut values = values.into_iter().enumerate().map(|(i, v)| {
        v.map_err(|e| match N {
            1 => e.within(Segment::Field("value".into())),
            _ => e.within(Segment::Index(i)).within(Segment::Field("values".into())),
        })
    });
    Ok(Json::Object(match N {
        0 => vec![tag_member],
        1 => vec![tag_member, member("value", values.next().unwrap_or(Ok(Json::Null))?)],
        _ => vec![tag_member, member("values", Json::Array(values.collect::<Result<_, _>>()?))],
    }))
}

/// A closed variant whose tags have no payload: the tag as a string.
pub fn tag_name(tag: &str) -> R {
    Ok(Json::String(tag.to_owned()))
}

/// A case whose record payload has a field named `_tag`: it has no plain form (spec §16.3).
pub fn no_plain_form(tag: &str) -> R {
    Err(EncodeError::new(format!("{tag} has a field named _tag, so it has no plain JSON form")))
}

/// An unknown value: `{"_tag": "Hexagon"}`, with `"args"` in the lossless
/// form if it has any (spec §16.3).
pub fn unknown(u: &Unknown) -> R {
    if !crate::ser::is_tag(&u.tag) {
        return Err(EncodeError::new("not a tag name: A to Z, then letters, digits and _"));
    }
    let tag = member("_tag", Json::String(u.tag.clone()));
    if u.args.is_empty() {
        return Ok(Json::Object(vec![tag]));
    }
    let limits = Limits::default();
    let args = u
        .args
        .iter()
        .enumerate()
        .map(|(i, a)| {
            super::to_lossless(a, &limits)
                .map_err(|e| e.within(Segment::Index(i)).within(Segment::Field("args".into())))
        })
        .collect::<Result<_, _>>()?;
    Ok(Json::Object(vec![tag, member("args", Json::Array(args))]))
}

pub fn array<T>(items: &[T], f: impl Fn(&T) -> R) -> R {
    items
        .iter()
        .enumerate()
        .map(|(i, x)| f(x).map_err(|e| e.within(Segment::Index(i))))
        .collect::<Result<_, _>>()
        .map(Json::Array)
}

pub fn map<T>(m: &BTreeMap<String, T>, f: impl Fn(&T) -> R) -> R {
    m.iter()
        .map(|(k, v)| Ok((k.clone(), f(v).map_err(|e| e.within(Segment::Field(k.clone())))?)))
        .collect::<Result<_, _>>()
        .map(Json::Object)
}

/// `Maybe a`: `null` or `a`, when `a`'s JSON can't be `null` (`nullable` is
/// false); otherwise `{"_tag": "None"}` or `{"_tag": "Some", "value": …}`.
pub fn maybe<T>(m: &Option<T>, nullable: bool, f: impl FnOnce(&T) -> R) -> R {
    match (nullable, m) {
        (false, None) => Ok(Json::Null),
        (false, Some(x)) => f(x),
        (true, None) => tagged("None", []),
        (true, Some(x)) => tagged("Some", [f(x)]),
    }
}

pub fn result<A, E>(r: &Result<A, E>, ok: impl FnOnce(&A) -> R, err: impl FnOnce(&E) -> R) -> R {
    match r {
        Ok(x) => tagged("Ok", [ok(x)]),
        Err(x) => tagged("Err", [err(x)]),
    }
}

/// `Secret a`: the value in full (the receiver needs it); an error says
/// only that it isn't a valid `what`, never where in it (spec §15).
pub fn secret<T>(s: &Secret<T>, what: &str, f: impl FnOnce(&T) -> R) -> R {
    f(s.expose()).map_err(|_| EncodeError::new(format!("not a valid {what} (the value is hidden)")))
}

/// A type with a codec: back to its base type, then written.
pub fn codec<C: Codec>(x: &C::Target) -> R
where
    C::Base: ToJson,
{
    C::encode(x).to_json()
}

impl<T: ToJson + ?Sized> ToJson for &T {
    const NULLABLE: bool = T::NULLABLE;
    fn to_json(&self) -> R {
        (**self).to_json()
    }
}
impl<T: ToJson> ToJson for Box<T> {
    const NULLABLE: bool = T::NULLABLE;
    fn to_json(&self) -> R {
        (**self).to_json()
    }
}
impl<T: ToJson> ToJson for Secret<T> {
    const NULLABLE: bool = T::NULLABLE;
    fn to_json(&self) -> R {
        secret(self, "Secret", T::to_json)
    }
}
impl<T: ToJson> ToJson for Vec<T> {
    fn to_json(&self) -> R {
        array(self, T::to_json)
    }
}
impl<T: ToJson> ToJson for [T] {
    fn to_json(&self) -> R {
        array(self, T::to_json)
    }
}
impl<T: ToJson> ToJson for BTreeMap<String, T> {
    fn to_json(&self) -> R {
        map(self, T::to_json)
    }
}
impl<T: ToJson> ToJson for Option<T> {
    const NULLABLE: bool = !T::NULLABLE;
    fn to_json(&self) -> R {
        maybe(self, T::NULLABLE, T::to_json)
    }
}
impl<A: ToJson, E: ToJson> ToJson for Result<A, E> {
    fn to_json(&self) -> R {
        result(self, A::to_json, E::to_json)
    }
}

/// `Any`: the lossless form (spec §16.2), checked against the default limits.
impl ToJson for Value {
    fn to_json(&self) -> R {
        super::to_lossless(self, &Limits::default())
    }
}
impl ToJson for Unknown {
    fn to_json(&self) -> R {
        unknown(self)
    }
}
impl ToJson for AnyTag {
    fn to_json(&self) -> R {
        match self {
            AnyTag::Bare(tag) => unknown(&Unknown { tag: tag.clone(), args: vec![] }),
            AnyTag::Other(u) => unknown(u),
        }
    }
}
impl ToJson for String {
    fn to_json(&self) -> R {
        Ok(Json::String(self.clone()))
    }
}
impl ToJson for str {
    fn to_json(&self) -> R {
        Ok(Json::String(self.to_owned()))
    }
}
/// `Bytes`: base64 with padding (RFC 4648 §4).
impl ToJson for Bytes {
    fn to_json(&self) -> R {
        Ok(Json::String(base64::encode(&self.0)))
    }
}
impl ToJson for bool {
    fn to_json(&self) -> R {
        Ok(Json::Bool(*self))
    }
}
macro_rules! numbers {
    ($($t:ty),*) => {$(
        impl ToJson for $t {
            fn to_json(&self) -> R {
                Ok(Json::Number(self.to_string()))
            }
        }
    )*};
}
numbers!(i8, i16, i32, u8, u16, u32);
/// `Int64` and `UInt64` are strings: many JSON parsers round integers beyond 2⁵³.
macro_rules! strings {
    ($($t:ty),*) => {$(
        impl ToJson for $t {
            fn to_json(&self) -> R {
                Ok(Json::String(self.to_string()))
            }
        }
    )*};
}
strings!(i64, u64);
/// `Int`: a string, the decimal integer.
impl ToJson for Int {
    fn to_json(&self) -> R {
        Ok(Json::String(self.as_str().to_owned()))
    }
}
/// `Decimal`: a string, the normalized literal (`"19.90"`).
impl ToJson for Decimal {
    fn to_json(&self) -> R {
        let n = crate::ser::normalized(self.as_str(), &Limits::default()).map_err(EncodeError::new)?;
        Ok(Json::String(n.into_owned()))
    }
}
/// Floats in the spelling of spec §15, or `"NaN"`, `"Infinity"`, `"-Infinity"`.
macro_rules! floats {
    ($($t:ty),*) => {$(
        impl ToJson for $t {
            fn to_json(&self) -> R {
                Ok(match self {
                    x if x.is_nan() => Json::String("NaN".into()),
                    x if x.is_infinite() && *x > 0.0 => Json::String("Infinity".into()),
                    x if x.is_infinite() => Json::String("-Infinity".into()),
                    x => Json::Number(crate::float::text(*x)),
                })
            }
        }
    )*};
}
floats!(f32, f64);
/// std/time: the string as written.
macro_rules! times {
    ($($name:ident),*) => {$(
        impl ToJson for crate::time::$name {
            fn to_json(&self) -> R {
                Ok(Json::String(self.as_str().to_owned()))
            }
        }
    )*};
}
times!(Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone);
