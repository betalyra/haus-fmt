//! Writing Rust values as plain JSON (spec §16.3): [`ToJson`] for the
//! prelude types, and the helpers that generated code calls.

use super::{Json, ToJson, base64};
use crate::de::{AnyTag, Bytes, Decimal, Int, Unknown};
use crate::{Codec, EncodeError, Encoder, Secret, Segment, Value};
use std::collections::BTreeMap;

type R = Result<Json, EncodeError>;

fn member(name: &str, json: Json) -> (String, Json) {
    (name.to_owned(), json)
}

/// An object from fields in order, leaving out missing optional ones: a
/// record, encoded inside it.
pub fn object<'k, const N: usize>(e: Encoder, fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N]) -> R {
    fields(e.record_level()?)
        .into_iter()
        .filter_map(|(k, v)| Some(v?.map(|v| member(k, v)).map_err(|e| e.within(Segment::Field(k.to_owned())))))
        .collect::<Result<_, _>>()
        .map(Json::Object)
}

/// A case with a record payload: `{"_tag": "Circle", "r": 1.5}`.
pub fn tagged_object<'k, const N: usize>(
    tag: &str,
    e: Encoder,
    fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N],
) -> R {
    match object(e, fields)? {
        Json::Object(members) => {
            Ok(Json::Object([member("_tag", Json::String(tag.to_owned()))].into_iter().chain(members).collect()))
        }
        other => Ok(other),
    }
}

/// A case with `N` positional values: `{"_tag": "Empty"}`, `{"_tag": "Wrap",
/// "value": 3}`, `{"_tag": "Point", "values": [1, 2]}`. The values are
/// encoded inside the payload, a level of the haus value.
pub fn tagged<const N: usize>(tag: &str, e: Encoder, values: impl FnOnce(Encoder) -> [R; N]) -> R {
    let tag_member = member("_tag", Json::String(tag.to_owned()));
    if N == 0 {
        return Ok(Json::Object(vec![tag_member]));
    }
    let mut values = values(if N == 1 { e.payload()? } else { e.nested()? }).into_iter().enumerate().map(|(i, v)| {
        v.map_err(|e| match N {
            1 => e.within(Segment::Field("value".into())),
            _ => e.within(Segment::Index(i)).within(Segment::Field("values".into())),
        })
    });
    Ok(Json::Object(match N {
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
pub fn unknown(u: &Unknown, e: Encoder) -> R {
    if !crate::ser::is_tag(&u.tag) {
        return Err(EncodeError::new("not a tag name: A to Z, then letters, digits and _"));
    }
    let tag = member("_tag", Json::String(u.tag.clone()));
    if u.args.is_empty() {
        return Ok(Json::Object(vec![tag]));
    }
    // `Tag { … }`: the record is the payload's only level.
    let inner = match u.args.as_slice() {
        [Value::Record(_)] => e,
        _ => e.nested()?,
    };
    let args = u
        .args
        .iter()
        .enumerate()
        .map(|(i, a)| {
            super::lossless::to_lossless_at(a, inner.limits(), inner.depth())
                .map_err(|e| e.within(Segment::Index(i)).within(Segment::Field("args".into())))
        })
        .collect::<Result<_, _>>()?;
    Ok(Json::Object(vec![tag, member("args", Json::Array(args))]))
}

pub fn array<T>(items: &[T], e: Encoder, f: impl Fn(&T, Encoder) -> R) -> R {
    let inner = e.nested()?;
    items
        .iter()
        .enumerate()
        .map(|(i, x)| f(x, inner).map_err(|e| e.within(Segment::Index(i))))
        .collect::<Result<_, _>>()
        .map(Json::Array)
}

pub fn map<T>(m: &BTreeMap<String, T>, e: Encoder, f: impl Fn(&T, Encoder) -> R) -> R {
    let inner = e.record_level()?;
    m.iter()
        .map(|(k, v)| Ok((k.clone(), f(v, inner).map_err(|e| e.within(Segment::Field(k.clone())))?)))
        .collect::<Result<_, _>>()
        .map(Json::Object)
}

/// `Maybe a`: `null` or `a`, when `a`'s JSON can't be `null` (`nullable` is
/// false); otherwise `{"_tag": "None"}` or `{"_tag": "Some", "value": …}`.
/// `Some` is a level of the haus value either way.
pub fn maybe<T>(m: &Option<T>, e: Encoder, nullable: bool, f: impl FnOnce(&T, Encoder) -> R) -> R {
    match (nullable, m) {
        (false, None) => Ok(Json::Null),
        (false, Some(x)) => f(x, e.payload()?),
        (true, None) => tagged("None", e, |_| []),
        (true, Some(x)) => tagged("Some", e, |e| [f(x, e)]),
    }
}

pub fn result<A, E>(
    r: &Result<A, E>,
    e: Encoder,
    ok: impl FnOnce(&A, Encoder) -> R,
    err: impl FnOnce(&E, Encoder) -> R,
) -> R {
    match r {
        Ok(x) => tagged("Ok", e, |e| [ok(x, e)]),
        Err(x) => tagged("Err", e, |e| [err(x, e)]),
    }
}

/// `Secret a`: the value in full (the receiver needs it); an error says
/// only that it isn't a valid `what`, never where in it (spec §15).
pub fn secret<T>(s: &Secret<T>, e: Encoder, what: &str, f: impl FnOnce(&T, Encoder) -> R) -> R {
    f(s.expose(), e).map_err(|_| EncodeError::new(format!("not a valid {what} (the value is hidden)")))
}

/// A type with a codec: back to its base type, then written.
pub fn codec<C: Codec>(x: &C::Target, e: Encoder) -> R
where
    C::Base: ToJson,
{
    C::encode(x).to_json_with(e)
}

impl<T: ToJson + ?Sized> ToJson for &T {
    const NULLABLE: bool = T::NULLABLE;
    fn to_json_with(&self, e: Encoder) -> R {
        (**self).to_json_with(e)
    }
}
impl<T: ToJson> ToJson for Box<T> {
    const NULLABLE: bool = T::NULLABLE;
    fn to_json_with(&self, e: Encoder) -> R {
        (**self).to_json_with(e)
    }
}
impl<T: ToJson> ToJson for Secret<T> {
    const NULLABLE: bool = T::NULLABLE;
    fn to_json_with(&self, e: Encoder) -> R {
        secret(self, e, "Secret", T::to_json_with)
    }
}
impl<T: ToJson> ToJson for Vec<T> {
    fn to_json_with(&self, e: Encoder) -> R {
        array(self, e, T::to_json_with)
    }
}
impl<T: ToJson> ToJson for [T] {
    fn to_json_with(&self, e: Encoder) -> R {
        array(self, e, T::to_json_with)
    }
}
impl<T: ToJson> ToJson for BTreeMap<String, T> {
    fn to_json_with(&self, e: Encoder) -> R {
        map(self, e, T::to_json_with)
    }
}
impl<T: ToJson> ToJson for Option<T> {
    const NULLABLE: bool = !T::NULLABLE;
    fn to_json_with(&self, e: Encoder) -> R {
        maybe(self, e, T::NULLABLE, T::to_json_with)
    }
}
impl<A: ToJson, E: ToJson> ToJson for Result<A, E> {
    fn to_json_with(&self, e: Encoder) -> R {
        result(self, e, A::to_json_with, E::to_json_with)
    }
}

/// `Any`: the lossless form (spec §16.2), checked against the limits.
impl ToJson for Value {
    fn to_json_with(&self, e: Encoder) -> R {
        super::lossless::to_lossless_at(self, e.limits(), e.depth())
    }
}
impl ToJson for Unknown {
    fn to_json_with(&self, e: Encoder) -> R {
        unknown(self, e)
    }
}
impl ToJson for AnyTag {
    fn to_json_with(&self, e: Encoder) -> R {
        match self {
            AnyTag::Bare(tag) => unknown(&Unknown { tag: tag.clone(), args: vec![] }, e),
            AnyTag::Other(u) => unknown(u, e),
        }
    }
}
impl ToJson for String {
    fn to_json_with(&self, _: Encoder) -> R {
        Ok(Json::String(self.clone()))
    }
}
impl ToJson for str {
    fn to_json_with(&self, _: Encoder) -> R {
        Ok(Json::String(self.to_owned()))
    }
}
/// `Bytes`: base64 with padding (RFC 4648 §4).
impl ToJson for Bytes {
    fn to_json_with(&self, _: Encoder) -> R {
        Ok(Json::String(base64::encode(&self.0)))
    }
}
impl ToJson for bool {
    fn to_json_with(&self, _: Encoder) -> R {
        Ok(Json::Bool(*self))
    }
}
macro_rules! numbers {
    ($($t:ty),*) => {$(
        impl ToJson for $t {
            fn to_json_with(&self, _: Encoder) -> R {
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
            fn to_json_with(&self, _: Encoder) -> R {
                Ok(Json::String(self.to_string()))
            }
        }
    )*};
}
strings!(i64, u64);
/// `Int`: a string, the decimal integer.
impl ToJson for Int {
    fn to_json_with(&self, _: Encoder) -> R {
        Ok(Json::String(self.as_str().to_owned()))
    }
}
/// `Decimal`: a string, the normalized literal (`"19.90"`).
impl ToJson for Decimal {
    fn to_json_with(&self, e: Encoder) -> R {
        let n = crate::ser::normalized(self.as_str(), e.limits()).map_err(EncodeError::new)?;
        Ok(Json::String(n.into_owned()))
    }
}
/// Floats in the spelling of spec §15, or `"NaN"`, `"Infinity"`, `"-Infinity"`.
macro_rules! floats {
    ($($t:ty),*) => {$(
        impl ToJson for $t {
            fn to_json_with(&self, _: Encoder) -> R {
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
            fn to_json_with(&self, _: Encoder) -> R {
                Ok(Json::String(self.as_str().to_owned()))
            }
        }
    )*};
}
times!(Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone);
