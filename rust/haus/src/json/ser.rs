//! Writing Rust values as schema-based JSON (spec §16.3): [`ToJson`] for the
//! prelude types, and the helpers that generated code calls.
//!
//! Lengths are checked here, on the haus value (spec §16 "Limits"), as the
//! haus writer checks them: a string's characters, record keys, map keys and
//! tags as keys and tags, bytes as two characters per byte although base64
//! spells them in fewer or more. What isn't a string of the haus value
//! doesn't count: the member names of the form (`_tag`, `value`), and the
//! strings that hold numbers (`Int`, `Decimal`, `Int64`, `"NaN"`).

use super::{Json, JsonNumber, ToJson, base64};
use crate::de::{AnyTag, Bytes, Decimal, Int, Unknown};
use crate::ser::{check_bytes, check_key, check_length, check_number, check_tag, check_tag_length};
use crate::{Codec, EncodeError, Encoder, ErrorCode, Secret, Segment, Value};
use std::collections::BTreeMap;

type R = Result<Json, EncodeError>;

fn member(name: &str, json: Json) -> (String, Json) {
    (name.to_owned(), json)
}

/// An object from fields in order, leaving out missing optional ones: a
/// record, encoded inside it, whose keys are within the string limit.
pub fn object<'k, const N: usize>(e: Encoder, fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N]) -> R {
    let inner = e.record_level()?;
    fields(inner)
        .into_iter()
        .filter_map(|(k, v)| {
            let field = v?.and_then(|v| check_key(k, inner.limits()).map(|()| member(k, v)));
            Some(field.map_err(|e| e.within(Segment::Field(k.to_owned()))))
        })
        .collect::<Result<_, _>>()
        .map(Json::Object)
}

/// A case with a record payload: `{"_tag": "Circle", "r": 1.5}`.
pub fn tagged_object<'k, const N: usize>(
    tag: &str,
    e: Encoder,
    fields: impl FnOnce(Encoder) -> [(&'k str, Option<R>); N],
) -> R {
    check_tag(tag, e.limits())?;
    match object(e, fields)? {
        Json::Object(members) => {
            Ok(Json::Object([member("_tag", Json::String(tag.to_owned()))].into_iter().chain(members).collect()))
        }
        other => Ok(other),
    }
}

/// A record case whose record is a named type (spec §15: `Box BoxRec`): the
/// record's members beside `"_tag"`, `{"_tag": "Box", "w": 1}`, as for `Box {
/// w: Int32 }`. `record` is the record written with `e`, the tag's encoder.
pub fn record_case(tag: &str, e: Encoder, record: R) -> R {
    check_tag(tag, e.limits())?;
    match record? {
        Json::Object(members) => {
            Ok(Json::Object([member("_tag", Json::String(tag.to_owned()))].into_iter().chain(members).collect()))
        }
        other => Err(EncodeError::new(
            ErrorCode::CannotEncode,
            format!("{tag} takes a record, whose JSON is an object; found {}", super::de::describe(&other)),
        )),
    }
}

/// A case with `N` positional values: `{"_tag": "Empty"}`, `{"_tag": "Wrap",
/// "value": 3}`, `{"_tag": "Point", "values": [1, 2]}`. The values are
/// encoded inside the payload, a level of the haus value.
pub fn tagged<const N: usize>(tag: &str, e: Encoder, values: impl FnOnce(Encoder) -> [R; N]) -> R {
    check_tag(tag, e.limits())?;
    let tag_member = member("_tag", Json::String(tag.to_owned()));
    if N == 0 {
        e.step()?;
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
pub fn tag_name(tag: &str, e: Encoder) -> R {
    e.step()?;
    check_tag(tag, e.limits())?;
    Ok(Json::String(tag.to_owned()))
}

/// A case whose record payload has a field named `_tag` or `_args` (`field`):
/// it has no schema-based form (spec §16.3).
pub fn no_json_form(tag: &str, field: &str) -> R {
    Err(EncodeError::new(ErrorCode::NoJsonForm, no_json_form_reason(tag, field)))
}

pub(crate) fn no_json_form_reason(tag: &str, field: &str) -> String {
    format!("{tag} has a field named {field}, so it has no schema-based JSON form")
}

/// An unknown value: `{"_tag": "Hexagon"}`, with `"_args"`, the arguments'
/// self-describing values (without the envelope), if it has any (spec §16.3).
pub fn unknown(u: &Unknown, e: Encoder) -> R {
    check_tag_length(&u.tag, e.limits())?;
    let tag = member("_tag", Json::String(u.tag.to_string()));
    if u.args.is_empty() {
        e.step()?;
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
            super::haus_json::to_value_at(a, inner.limits(), inner.depth())
                .map_err(|e| e.within(Segment::Index(i)).within(Segment::Field("_args".into())))
        })
        .collect::<Result<_, _>>()?;
    // Checked against the depth limit above, so counting doesn't recurse deeper.
    e.steps(1 + u.args.iter().map(crate::ser::size).sum::<u64>())?;
    Ok(Json::Object(vec![tag, member("_args", Json::Array(args))]))
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
        .map(|(k, v)| {
            let within = |e: EncodeError| e.within(Segment::Field(k.clone()));
            check_key(k, inner.limits()).map_err(within)?;
            Ok((k.clone(), f(v, inner).map_err(within)?))
        })
        .collect::<Result<_, _>>()
        .map(Json::Object)
}

/// `Maybe a`: `null` or `a`, when `a`'s JSON can't be `null` (`nullable` is
/// false); otherwise `{"_tag": "None"}` or `{"_tag": "Some", "value": …}`.
/// `Some` is a level of the haus value either way.
pub fn maybe<T>(m: &Option<T>, e: Encoder, nullable: bool, f: impl FnOnce(&T, Encoder) -> R) -> R {
    match (nullable, m) {
        (false, None) => e.step().map(|()| Json::Null),
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
    f(s.expose(), e)
        .map_err(|_| EncodeError::new(ErrorCode::InvalidSecret, format!("not a valid {what} (the value is hidden)")))
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

/// `Any`: its self-describing value (spec §16.2), without the envelope,
/// checked against the limits.
impl ToJson for Value {
    fn to_json_with(&self, e: Encoder) -> R {
        let json = super::haus_json::to_value_at(self, e.limits(), e.depth())?;
        e.steps(crate::ser::size(self))?;
        Ok(json)
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
            AnyTag::Bare(tag) => unknown(&Unknown::new(tag.clone(), vec![]), e),
            AnyTag::Other(u) => unknown(u, e),
        }
    }
}
/// A string, within the string limit: its characters, not its escapes.
impl ToJson for String {
    fn to_json_with(&self, e: Encoder) -> R {
        self.as_str().to_json_with(e)
    }
}
impl ToJson for str {
    fn to_json_with(&self, e: Encoder) -> R {
        e.step()?;
        check_length(self, e.limits())?;
        Ok(Json::String(self.to_owned()))
    }
}
/// `Bytes`: base64 with padding (RFC 4648 §4), within the string limit as
/// the haus byte string's hex, two characters per byte.
impl ToJson for Bytes {
    fn to_json_with(&self, e: Encoder) -> R {
        e.step()?;
        check_bytes(&self.0, e.limits())?;
        Ok(Json::String(base64::encode(&self.0)))
    }
}
impl ToJson for bool {
    fn to_json_with(&self, e: Encoder) -> R {
        e.step()?;
        Ok(Json::Bool(*self))
    }
}
macro_rules! numbers {
    ($($t:ty),*) => {$(
        impl ToJson for $t {
            fn to_json_with(&self, e: Encoder) -> R {
                e.step()?;
                Ok(Json::Number(JsonNumber::from(*self)))
            }
        }
    )*};
}
numbers!(i8, i16, i32, u8, u16, u32);
/// `Int64` and `UInt64` are strings: many JSON parsers round integers beyond 2⁵³.
macro_rules! strings {
    ($($t:ty),*) => {$(
        impl ToJson for $t {
            fn to_json_with(&self, e: Encoder) -> R {
                e.step()?;
                Ok(Json::String(self.to_string()))
            }
        }
    )*};
}
strings!(i64, u64);
/// `Int`: a string, the decimal integer, within the number limit.
impl ToJson for Int {
    fn to_json_with(&self, e: Encoder) -> R {
        e.step()?;
        check_number(&self.0, e.limits())?;
        Ok(Json::String(self.as_str().to_owned()))
    }
}
/// `Decimal`: a string, the normalized literal (`"19.90"`).
impl ToJson for Decimal {
    fn to_json_with(&self, e: Encoder) -> R {
        e.step()?;
        check_number(&self.0, e.limits())?;
        Ok(Json::String(self.as_str().to_owned()))
    }
}
/// Floats in the spelling of spec §15, or `"NaN"`, `"Infinity"`, `"-Infinity"`.
macro_rules! floats {
    ($($t:ty),*) => {$(
        impl ToJson for $t {
            fn to_json_with(&self, e: Encoder) -> R {
                e.step()?;
                Ok(match self {
                    x if x.is_nan() => Json::String("NaN".into()),
                    x if x.is_infinite() && *x > 0.0 => Json::String("Infinity".into()),
                    x if x.is_infinite() => Json::String("-Infinity".into()),
                    x => Json::Number(JsonNumber::from_valid(crate::float::text(*x))),
                })
            }
        }
    )*};
}
floats!(f32, f64);
/// std/time: the string as written, checked as the haus value
/// `Date("…")`: the tag, and the string inside its payload.
macro_rules! times {
    ($($name:ident),*) => {$(
        impl ToJson for crate::time::$name {
            fn to_json_with(&self, e: Encoder) -> R {
                check_tag(stringify!($name), e.limits())?;
                self.as_str().to_json_with(e.payload()?)
            }
        }
    )*};
}
times!(Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone);
