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
use crate::ser::{is_normalized, is_tag, normalized};
use crate::{DecodeError, EncodeError, Limits, Segment, Value};
use std::collections::HashSet;
use std::fmt::Write as _;

/// The lossless form of a value. A [`Value`] built in code is checked as the
/// haus writer checks it: number literals (normalized: `1E5` is written
/// `1e5`), tag names, unique keys, and the limits.
pub fn to_lossless(value: &Value, limits: &Limits) -> Result<Json, EncodeError> {
    to_lossless_at(value, limits, 0)
}

/// [`to_lossless`] for a value inside `depth` containers.
pub(crate) fn to_lossless_at(value: &Value, limits: &Limits, depth: usize) -> Result<Json, EncodeError> {
    Writer { limits }.value(value, depth)
}

/// A value from its lossless form, and from nothing else.
pub fn from_lossless(json: &Json, limits: &Limits) -> Result<Value, DecodeError> {
    Reader { limits }.value(json, 0)
}

/// Any JSON read without a schema (spec §16.1): an object as a record, an
/// array as an array, a string as a string, a number as a number with its
/// literal normalized (`1E+05` is `1e5`), `true` / `false` as `True` /
/// `False`, and `null` as `None`. The result nests at most `limits.max_depth`.
pub fn from_plain(json: &Json, limits: &Limits) -> Result<Value, DecodeError> {
    fn go(json: &Json, depth: usize, max: usize) -> Result<Value, DecodeError> {
        let open = || match depth >= max {
            true => Err(DecodeError::new(format!("nesting deeper than {max} levels"))),
            false => Ok(depth + 1),
        };
        Ok(match json {
            Json::Null => tag("None"),
            Json::Bool(true) => tag("True"),
            Json::Bool(false) => tag("False"),
            Json::Number(n) => Value::Number(normalize_number(n)),
            Json::String(s) => Value::String(s.clone()),
            Json::Array(items) => {
                let depth = open()?;
                Value::Array(
                    items
                        .iter()
                        .enumerate()
                        .map(|(i, x)| go(x, depth, max).map_err(|e| e.index(i)))
                        .collect::<Result<_, _>>()?,
                )
            }
            Json::Object(members) => {
                let depth = open()?;
                Value::Record(
                    members
                        .iter()
                        .map(|(k, v)| Ok((k.clone(), go(v, depth, max).map_err(|e| e.field(k))?)))
                        .collect::<Result<_, _>>()?,
                )
            }
        })
    }
    go(json, 0, limits.max_depth)
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
    /// `value`, inside `depth` containers (counted as the haus writer counts them).
    fn value(&self, value: &Value, depth: usize) -> W {
        let object = |name: &str, json: Json| Json::Object(vec![(name.to_owned(), json)]);
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
            Value::Array(items) => Json::Array(self.items(items, depth)?),
            Value::Record(fields) => object("rec", self.record(fields, depth)?),
            Value::Variant { tag, args } => {
                if !is_tag(tag) {
                    return Err(EncodeError::new("not a tag name: A to Z, then letters, digits and _"));
                }
                let tag_json = ("tag".to_owned(), Json::String(tag.clone()));
                let within = |e: EncodeError| e.within(Segment::Tag(tag.clone()));
                match args.as_slice() {
                    [] => Json::Object(vec![tag_json]),
                    // `Tag { … }`: the record is the payload's only level.
                    [Value::Record(fields)] => {
                        let rec = object("rec", self.record(fields, depth).map_err(within)?);
                        Json::Object(vec![tag_json, ("args".to_owned(), Json::Array(vec![rec]))])
                    }
                    args => {
                        let args = self.items(args, depth).map_err(within)?;
                        Json::Object(vec![tag_json, ("args".to_owned(), Json::Array(args))])
                    }
                }
            }
        })
    }

    fn open(&self, depth: usize) -> Result<usize, EncodeError> {
        match depth >= self.limits.max_depth {
            true => Err(EncodeError::new(format!("nesting deeper than {} levels", self.limits.max_depth))),
            false => Ok(depth + 1),
        }
    }

    fn items(&self, items: &[Value], depth: usize) -> Result<Vec<Json>, EncodeError> {
        let depth = self.open(depth)?;
        items.iter().enumerate().map(|(i, x)| self.value(x, depth).map_err(|e| e.within(Segment::Index(i)))).collect()
    }

    fn record(&self, fields: &[(String, Value)], depth: usize) -> W {
        let depth = self.open(depth)?;
        let mut seen = HashSet::with_capacity(fields.len());
        fields
            .iter()
            .map(|(k, v)| {
                let within = |e: EncodeError| e.within(Segment::Field(k.clone()));
                if !seen.insert(k.as_str()) {
                    return Err(within(EncodeError::new("the key is used twice in this record")));
                }
                Ok((k.clone(), self.value(v, depth).map_err(within)?))
            })
            .collect::<Result<_, _>>()
            .map(Json::Object)
    }
}

struct Reader<'a> {
    limits: &'a Limits,
}

type R = Result<Value, DecodeError>;

const FORMS: &str =
    r#"a lossless value: a string, an array, or an object {"num"}, {"bytes"}, {"rec"} or {"tag", "args"?}"#;

impl Reader<'_> {
    fn value(&self, json: &Json, depth: usize) -> R {
        match json {
            Json::String(s) => Ok(Value::String(s.clone())),
            Json::Array(items) => self.items(items, depth).map(Value::Array),
            Json::Object(members) => match members.as_slice() {
                [(k, v)] if k == "num" => self.number(v).map_err(|e| e.field("num")),
                [(k, v)] if k == "bytes" => bytes(v).map_err(|e| e.field("bytes")),
                [(k, v)] if k == "rec" => self.record(v, depth).map_err(|e| e.field("rec")),
                [(k, v)] if k == "tag" => Ok(Value::Variant { tag: tag_name(v)?, args: vec![] }),
                [(k1, v1), (k2, v2)] if k1 == "tag" && k2 == "args" => self.variant(v1, v2, depth),
                [(k1, v1), (k2, v2)] if k1 == "args" && k2 == "tag" => self.variant(v2, v1, depth),
                _ => Err(mismatch(json)),
            },
            _ => Err(mismatch(json)),
        }
    }

    fn open(&self, depth: usize) -> Result<usize, DecodeError> {
        match depth >= self.limits.max_depth {
            true => Err(DecodeError::new(format!("nesting deeper than {} levels", self.limits.max_depth))),
            false => Ok(depth + 1),
        }
    }

    fn items(&self, items: &[Json], depth: usize) -> Result<Vec<Value>, DecodeError> {
        let depth = self.open(depth)?;
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
        let depth = self.open(depth)?;
        // The reader already rejects duplicate names; a Json built in code may repeat one.
        let mut seen = HashSet::with_capacity(members.len());
        members
            .iter()
            .map(|(k, v)| match seen.insert(k.as_str()) {
                true => Ok((k.clone(), self.value(v, depth).map_err(|e| e.field(k))?)),
                false => Err(DecodeError::new(format!("the key {k:?} is used twice"))),
            })
            .collect::<Result<_, _>>()
            .map(Value::Record)
    }

    fn variant(&self, tag: &Json, args: &Json, depth: usize) -> R {
        let tag = tag_name(tag)?;
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

/// `"Circle"`: a tag name.
fn tag_name(json: &Json) -> Result<String, DecodeError> {
    match json {
        Json::String(t) if is_tag(t) => Ok(t.clone()),
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
