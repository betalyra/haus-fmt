//! The lossless mapping (spec §16.2), and JSON read without a schema (§16.1).
//!
//! | haus    | lossless JSON                                  |
//! |---------|------------------------------------------------|
//! | string  | a string                                       |
//! | array   | an array                                       |
//! | number  | `{"num": "19.90"}`, the normalized literal     |
//! | bytes   | `{"bytes": "0b34"}`, lowercase hex             |
//! | record  | `{"rec": {…}}`                                 |
//! | variant | `{"tag": "None"}`, `{"tag": "Some", "args": […]}` |

use super::Json;
use crate::ser::{check_key, check_tag, is_normalized, is_tag, normalized, supported};
use crate::{DecodeError, EncodeError, Limits, Segment, Value};
use std::collections::HashSet;
use std::fmt::Write as _;

/// The lossless form of a value. A [`Value`] built in code is checked as the
/// haus writer checks it: number literals (normalized: `1E5` is written
/// `1e5`), tag names, unique keys, and the limits. Fails if
/// `limits.max_depth` is more than [`crate::MAX_SUPPORTED_DEPTH`].
pub fn to_lossless(value: &Value, limits: &Limits) -> Result<Json, EncodeError> {
    to_lossless_at(value, limits, 0)
}

/// [`to_lossless`] for a value inside `depth` containers.
pub(crate) fn to_lossless_at(value: &Value, limits: &Limits, depth: usize) -> Result<Json, EncodeError> {
    supported(limits)?;
    Writer { limits }.value(value, depth)
}

/// A value from its lossless form, and from nothing else. Fails if
/// `limits.max_depth` is more than [`crate::MAX_SUPPORTED_DEPTH`].
pub fn from_lossless(json: &Json, limits: &Limits) -> Result<Value, DecodeError> {
    from_lossless_at(json, limits, 0)
}

/// [`from_lossless`] for a value inside `depth` containers.
pub(crate) fn from_lossless_at(json: &Json, limits: &Limits, depth: usize) -> Result<Value, DecodeError> {
    decode_supported(limits)?;
    Reader { limits }.value(json, depth)
}

/// Whether this binding supports `limits` (spec §7), as a decoding error.
pub(crate) fn decode_supported(limits: &Limits) -> Result<(), DecodeError> {
    limits.unsupported().map_or(Ok(()), |reason| Err(DecodeError::new(reason)))
}

/// The depth inside one more container, after `depth`, if `limits` allow it.
pub(crate) fn open(limits: &Limits, depth: usize) -> Result<usize, DecodeError> {
    decode_supported(limits)?;
    match depth >= limits.max_depth {
        true => Err(DecodeError::new(format!("nesting deeper than {} levels", limits.max_depth))),
        false => Ok(depth + 1),
    }
}

/// Any JSON read without a schema (spec §16.1): an object as a record, an
/// array as an array, a string as a string, a number as a number with its
/// literal normalized (`1E+05` is `1e5`), `true` / `false` as `True` /
/// `False`, and `null` as `None`. The result nests at most `limits.max_depth`,
/// and its keys are within the string limit. Fails if `limits.max_depth` is
/// more than [`crate::MAX_SUPPORTED_DEPTH`].
pub fn from_plain(json: &Json, limits: &Limits) -> Result<Value, DecodeError> {
    from_plain_at(json, limits, 0)
}

/// [`from_plain`] for a value inside `depth` containers.
pub(crate) fn from_plain_at(json: &Json, limits: &Limits, depth: usize) -> Result<Value, DecodeError> {
    decode_supported(limits)?;
    Plain { limits }.value(json, depth)
}

/// Reads JSON without a schema. The steps that don't recurse are functions
/// of their own, so that the recursive frames stay small (see
/// [`crate::MAX_SUPPORTED_DEPTH`]).
struct Plain<'a> {
    limits: &'a Limits,
}

impl Plain<'_> {
    fn value(&self, json: &Json, depth: usize) -> R {
        match json {
            Json::Array(items) => self.items(items, depth),
            Json::Object(members) => self.members(members, depth),
            scalar => Ok(plain_scalar(scalar)),
        }
    }

    fn items(&self, items: &[Json], depth: usize) -> R {
        let depth = open(self.limits, depth)?;
        let values = items.iter().enumerate().map(|(i, x)| self.value(x, depth).map_err(|e| e.index(i)));
        values.collect::<Result<_, _>>().map(Value::Array)
    }

    fn members(&self, members: &[(String, Json)], depth: usize) -> R {
        let depth = open(self.limits, depth)?;
        let fields = members.iter().map(|(k, v)| {
            key(k, self.limits)?;
            Ok((k.clone(), self.value(v, depth).map_err(|e| e.field(k))?))
        });
        fields.collect::<Result<_, _>>().map(Value::Record)
    }
}

fn plain_scalar(json: &Json) -> Value {
    match json {
        Json::Bool(true) => tag("True"),
        Json::Bool(false) => tag("False"),
        Json::Number(n) => Value::Number(normalize_number(n)),
        Json::String(s) => Value::String(s.clone()),
        _ => tag("None"),
    }
}

/// A member name as a record key: within the string limit (spec §7).
fn key(k: &str, limits: &Limits) -> Result<(), DecodeError> {
    check_key(k, limits).map_err(|e| DecodeError::new(e.reason).field(k))
}

fn tag(name: &str) -> Value {
    Value::Variant { tag: name.to_owned(), args: vec![] }
}

/// A JSON number as a normalized haus literal: `1E+05` is `1e5`, `1e-0` is `1e0`.
pub(crate) fn normalize_number(n: &str) -> String {
    crate::parser::normalize_exponent(n.replace('E', "e"))
}

/// Two lowercase hex digits per byte.
fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::with_capacity(2 * bytes.len()), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}

struct Writer<'a> {
    limits: &'a Limits,
}

type W = Result<Json, EncodeError>;

impl Writer<'_> {
    /// `value`, inside `depth` containers (counted as the haus writer counts
    /// them). The steps that don't recurse are functions of their own, so
    /// that the recursive frames stay small (see [`crate::MAX_SUPPORTED_DEPTH`]).
    fn value(&self, value: &Value, depth: usize) -> W {
        match value {
            Value::Array(items) => self.items(items, depth).map(Json::Array),
            Value::Record(fields) => self.record(fields, depth).map(|rec| object("rec", rec)),
            Value::Variant { tag, args } => self.variant(tag, args, depth),
            scalar => self.scalar(scalar),
        }
    }

    fn scalar(&self, value: &Value) -> W {
        Ok(match value {
            Value::Number(n) => {
                object("num", Json::String(normalized(n, self.limits).map_err(EncodeError::new)?.into()))
            }
            Value::String(s) => Json::String(s.clone()),
            Value::Bytes(b) => {
                if b.len() > self.limits.max_string_length / 2 {
                    let max = self.limits.max_string_length;
                    return Err(EncodeError::new(format!("byte string longer than {max} characters")));
                }
                object("bytes", Json::String(hex(b)))
            }
            _ => Json::Null,
        })
    }

    fn variant(&self, tag: &str, args: &[Value], depth: usize) -> W {
        check_tag(tag, self.limits)?;
        let tag_json = ("tag".to_owned(), Json::String(tag.to_owned()));
        let args = match args {
            [] => return Ok(Json::Object(vec![tag_json])),
            // `Tag { … }`: the record is the payload's only level.
            [Value::Record(fields)] => self.record(fields, depth).map(|rec| vec![object("rec", rec)]),
            args => self.items(args, depth),
        };
        let args = args.map_err(|e| e.within(Segment::Tag(tag.to_owned())))?;
        Ok(Json::Object(vec![tag_json, ("args".to_owned(), Json::Array(args))]))
    }

    fn items(&self, items: &[Value], depth: usize) -> Result<Vec<Json>, EncodeError> {
        let depth = crate::ser::open(self.limits, depth)?;
        items.iter().enumerate().map(|(i, x)| self.value(x, depth).map_err(|e| e.within(Segment::Index(i)))).collect()
    }

    fn record(&self, fields: &[(String, Value)], depth: usize) -> W {
        let depth = crate::ser::open(self.limits, depth)?;
        crate::ser::unique_keys(fields)?;
        fields
            .iter()
            .map(|(k, v)| {
                let within = |e: EncodeError| e.within(Segment::Field(k.clone()));
                check_key(k, self.limits).map_err(within)?;
                Ok((k.clone(), self.value(v, depth).map_err(within)?))
            })
            .collect::<Result<_, _>>()
            .map(Json::Object)
    }
}

fn object(name: &str, json: Json) -> Json {
    Json::Object(vec![(name.to_owned(), json)])
}

struct Reader<'a> {
    limits: &'a Limits,
}

type R = Result<Value, DecodeError>;

const FORMS: &str =
    r#"a lossless value: a string, an array, or an object {"num"}, {"bytes"}, {"rec"} or {"tag", "args"?}"#;

impl Reader<'_> {
    /// The value of `json`, inside `depth` containers. The steps that don't
    /// recurse are functions of their own, so that the recursive frames stay
    /// small (see [`crate::MAX_SUPPORTED_DEPTH`]).
    fn value(&self, json: &Json, depth: usize) -> R {
        match json {
            Json::Array(items) => self.items(items, depth).map(Value::Array),
            Json::Object(members) => match members.as_slice() {
                [(k, v)] if k == "rec" => self.record(v, depth).map_err(|e| e.field("rec")),
                [(k1, v1), (k2, v2)] if k1 == "tag" && k2 == "args" => self.variant(v1, v2, depth),
                [(k1, v1), (k2, v2)] if k1 == "args" && k2 == "tag" => self.variant(v2, v1, depth),
                _ => self.leaf(json),
            },
            _ => self.leaf(json),
        }
    }

    /// A string, number, byte string or tag without arguments.
    fn leaf(&self, json: &Json) -> R {
        match json {
            Json::String(s) => Ok(Value::String(s.clone())),
            Json::Object(members) => match members.as_slice() {
                [(k, v)] if k == "num" => self.number(v).map_err(|e| e.field("num")),
                [(k, v)] if k == "bytes" => bytes(v).map_err(|e| e.field("bytes")),
                [(k, v)] if k == "tag" => Ok(Value::Variant { tag: tag_name(v, self.limits)?, args: vec![] }),
                _ => Err(mismatch(json)),
            },
            _ => Err(mismatch(json)),
        }
    }

    fn items(&self, items: &[Json], depth: usize) -> Result<Vec<Value>, DecodeError> {
        let depth = open(self.limits, depth)?;
        items.iter().enumerate().map(|(i, x)| self.value(x, depth).map_err(|e| e.index(i))).collect()
    }

    /// `"19.90"`: a normalized literal (spec §2), within the limits.
    fn number(&self, json: &Json) -> R {
        match json {
            Json::String(n) if is_normalized(n) => match normalized(n, self.limits) {
                Ok(_) => Ok(Value::Number(n.clone())),
                Err(why) => Err(DecodeError::new(why)),
            },
            Json::String(n) => Err(DecodeError::new(format!("{n:?} is not a normalized number literal"))),
            _ => Err(super::de::mismatch("a string", json)),
        }
    }

    fn record(&self, json: &Json, depth: usize) -> R {
        let Json::Object(members) = json else { return Err(super::de::mismatch("an object", json)) };
        let depth = open(self.limits, depth)?;
        // The reader already rejects duplicate names; a Json built in code may repeat one.
        let mut seen = HashSet::with_capacity(members.len());
        members
            .iter()
            .map(|(k, v)| match seen.insert(k.as_str()) {
                true => {
                    key(k, self.limits)?;
                    Ok((k.clone(), self.value(v, depth).map_err(|e| e.field(k))?))
                }
                false => Err(DecodeError::new(format!("the key {k:?} is used twice"))),
            })
            .collect::<Result<_, _>>()
            .map(Value::Record)
    }

    fn variant(&self, tag: &Json, args: &Json, depth: usize) -> R {
        let tag = tag_name(tag, self.limits)?;
        let args = match args {
            Json::Array(items) if items.is_empty() => {
                return Err(DecodeError::new(r#"a tag without arguments has no "args""#).field("args"));
            }
            // `Tag { … }`: the record is the payload's only level, as in `to_lossless`.
            Json::Array(items) if matches!(items.as_slice(), [Json::Object(m)] if is_record(m)) => {
                vec![self.value(&items[0], depth).map_err(|e| e.index(0).field("args"))?]
            }
            Json::Array(items) => self.items(items, depth).map_err(|e| e.field("args"))?,
            _ => return Err(super::de::mismatch("an array", args).field("args")),
        };
        Ok(Value::Variant { tag, args })
    }
}

fn is_record(members: &[(String, Json)]) -> bool {
    matches!(members, [(k, _)] if k == "rec")
}

fn mismatch(json: &Json) -> DecodeError {
    super::de::mismatch(FORMS, json)
}

/// `"Circle"`: a tag name, within the string limit.
fn tag_name(json: &Json, limits: &Limits) -> Result<String, DecodeError> {
    match json {
        Json::String(t) if is_tag(t) => match check_tag(t, limits) {
            Ok(()) => Ok(t.clone()),
            Err(e) => Err(DecodeError::new(e.reason).field("tag")),
        },
        Json::String(t) => {
            Err(DecodeError::new(format!("{t:?} is not a tag name (A to Z, then letters, digits and _)")).field("tag"))
        }
        _ => Err(super::de::mismatch("a string", json).field("tag")),
    }
}

/// `"0b34ff"`: two lowercase hex digits per byte.
fn bytes(json: &Json) -> R {
    let Json::String(text) = json else { return Err(super::de::mismatch("a string", json)) };
    let digit = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    let invalid = || DecodeError::new("expected two lowercase hex digits per byte");
    if !text.len().is_multiple_of(2) {
        return Err(invalid());
    }
    text.as_bytes()
        .chunks(2)
        .map(|pair| Some(digit(pair[0])? * 16 + digit(pair[1])?))
        .collect::<Option<Vec<u8>>>()
        .map(Value::Bytes)
        .ok_or_else(invalid)
}
