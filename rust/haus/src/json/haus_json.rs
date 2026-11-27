//! Self-describing JSON (spec §16.2): every haus value, exactly, without a
//! schema. A text is an envelope, `{"_haus": 1, "_value": …}`, and the value
//! in it is:
//!
//! | haus    | self-describing JSON                               |
//! |---------|----------------------------------------------------|
//! | string  | a string                                           |
//! | array   | an array                                           |
//! | number  | `{"_num": "19.90"}`, the normalized literal        |
//! | bytes   | `{"_bytes": "0b34"}`, lowercase hex                |
//! | record  | `{"_rec": {…}}`                                    |
//! | variant | `{"_tag": "None"}`, `{"_tag": "Some", "_args": […]}` |
//!
//! Inside schema-based JSON (`Any`, unknown values, §16.3) the value appears
//! without the envelope: that is [`to_value`] and [`from_value_at`].

use super::import::key;
use super::{Json, JsonNumber, JsonObject, decode_supported, open};
use crate::ser::{check_length, check_number, check_tag};
use crate::value::{is_normalized, is_tag};
use crate::{ByteString, DecodeError, EncodeError, ErrorCode as Code, Limits, List, Number, Record, Tag, Text, Value};
use std::collections::HashSet;
use std::fmt::Write as _;

/// The version of the form, the envelope's `_haus`.
const VERSION: &str = "1";

/// A value as self-describing JSON, in its envelope. It can't fail: a value
/// that exists is within the limits it was built with (spec §11).
pub fn to_self_describing(value: &Value) -> Json {
    Json::Object(JsonObject::from_unique(vec![
        ("_haus".to_owned(), Json::Number(JsonNumber::from(1u8))),
        ("_value".to_owned(), to_value(value)),
    ]))
}

/// A value from self-describing JSON, and from nothing else: the envelope,
/// with `_haus` 1, around one of the forms. Raw DEL, C1 and bidi controls
/// can't be told from escaped ones in a [`Json`]: the text reader
/// ([`crate::from_haus_json`]) rejects them. Fails if `limits.max_depth` is
/// more than [`crate::MAX_SUPPORTED_DEPTH`].
pub fn from_self_describing(json: &Json, limits: &Limits) -> Result<Value, DecodeError> {
    decode_supported(limits)?;
    // Places are in the JSON read (spec §16.3 "Places"): from the envelope, `$._value…`.
    from_value_at(envelope(json)?, limits, 0).map_err(|e| e.field("_value"))
}

/// The `_value` of an envelope whose `_haus` is 1. A text that isn't an
/// envelope is at the envelope (`$`), a `_haus` other than 1 at the member
/// (`$._haus`).
fn envelope(json: &Json) -> Result<&Json, DecodeError> {
    let (version, value) = match json {
        Json::Object(members) => match members.as_slice() {
            [(a, x), (b, y)] if a == "_haus" && b == "_value" => (x, y),
            [(a, y), (b, x)] if a == "_value" && b == "_haus" => (x, y),
            _ => return Err(not_an_envelope(json)),
        },
        _ => return Err(not_an_envelope(json)),
    };
    match version {
        Json::Number(n) if n == VERSION => Ok(value),
        other => Err(DecodeError::new(
            Code::HausJsonVersion,
            format!("self-describing JSON version {}; this reader reads version 1", describe_version(other)),
        )
        .field("_haus")),
    }
}

fn not_an_envelope(json: &Json) -> DecodeError {
    super::de::mismatch(r#"self-describing JSON, the envelope {"_haus": 1, "_value": …}"#, json)
        .with_code(Code::HausJsonForm)
}

/// `2`, `"1"`: a `_haus` that isn't 1, for messages.
fn describe_version(json: &Json) -> String {
    match json {
        Json::Number(n) => crate::scan::shown(n),
        Json::String(s) if s.len() <= 20 => format!("\"{}\"", crate::scan::shown(s)),
        other => super::de::describe(other),
    }
}

/// The self-describing form of a value, without the envelope. Recurses once
/// per level: a value nests at most [`crate::MAX_SUPPORTED_DEPTH`] levels.
pub(crate) fn to_value(value: &Value) -> Json {
    match value {
        Value::Array(items) => Json::Array(items.iter().map(to_value).collect()),
        Value::Record(r) => object("_rec", record(r.as_slice())),
        Value::Variant { tag, args } => variant(tag, args),
        scalar => leaf(scalar),
    }
}

/// A value from its self-describing form, without the envelope, inside
/// `depth` containers.
pub(crate) fn from_value_at(json: &Json, limits: &Limits, depth: usize) -> Result<Value, DecodeError> {
    decode_supported(limits)?;
    Reader { limits }.value(json, depth)
}

/// Two lowercase hex digits per byte.
fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::with_capacity(2 * bytes.len()), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}

/// A string, number or byte string.
fn leaf(value: &Value) -> Json {
    match value {
        Value::Number(n) => object("_num", Json::String(n.to_string())),
        Value::String(s) => Json::String(s.to_string()),
        Value::Bytes(b) => object("_bytes", Json::String(hex(b))),
        _ => Json::Null,
    }
}

fn variant(tag: &Tag, args: &[Value]) -> Json {
    let tag_json = ("_tag".to_owned(), Json::String(tag.to_string()));
    let args = match args {
        [] => return Json::Object(JsonObject::from_unique(vec![tag_json])),
        // `Tag { … }`: the record is the payload's only level.
        [Value::Record(r)] => vec![object("_rec", record(r.as_slice()))],
        args => args.iter().map(to_value).collect(),
    };
    Json::Object(JsonObject::from_unique(vec![tag_json, ("_args".to_owned(), Json::Array(args))]))
}

fn record(fields: &[(String, Value)]) -> Json {
    Json::Object(JsonObject::from_unique(fields.iter().map(|(k, v)| (k.clone(), to_value(v))).collect()))
}

fn object(name: &str, json: Json) -> Json {
    Json::Object(JsonObject::from_unique(vec![(name.to_owned(), json)]))
}

struct Reader<'a> {
    limits: &'a Limits,
}

type R = Result<Value, DecodeError>;

const FORMS: &str =
    r#"a self-describing value: a string, an array, or an object {"_num"}, {"_bytes"}, {"_rec"} or {"_tag", "_args"?}"#;

impl Reader<'_> {
    /// The value of `json`, inside `depth` containers. The steps that don't
    /// recurse are functions of their own, so that the recursive frames stay
    /// small (see [`crate::MAX_SUPPORTED_DEPTH`]).
    fn value(&self, json: &Json, depth: usize) -> R {
        match json {
            Json::Array(items) => self.items(items, depth).map(|items| Value::Array(List::from_checked(items))),
            Json::Object(members) => match members.as_slice() {
                [(k, v)] if k == "_rec" => self.record(v, depth).map_err(|e| e.field("_rec")),
                [(k1, v1), (k2, v2)] if k1 == "_tag" && k2 == "_args" => self.variant(v1, v2, depth),
                [(k1, v1), (k2, v2)] if k1 == "_args" && k2 == "_tag" => self.variant(v2, v1, depth),
                _ => self.leaf(json),
            },
            _ => self.leaf(json),
        }
    }

    /// A string, number, byte string or tag without arguments.
    fn leaf(&self, json: &Json) -> R {
        match json {
            Json::String(s) => {
                check_length(s, self.limits).map_err(EncodeError::into_decode)?;
                Ok(Value::String(Text::from_checked(s.clone())))
            }
            Json::Object(members) => match members.as_slice() {
                [(k, v)] if k == "_num" => self.number(v).map_err(|e| e.field("_num")),
                [(k, v)] if k == "_bytes" => bytes(v, self.limits).map_err(|e| e.field("_bytes")),
                [(k, v)] if k == "_tag" => Ok(tag_name(v, self.limits)?.into()),
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
            Json::String(n) if is_normalized(n) => {
                let n = Number::from_normalized(n.clone());
                check_number(&n, self.limits).map_err(EncodeError::into_decode)?;
                Ok(Value::Number(n))
            }
            Json::String(n) => Err(DecodeError::new(
                Code::HausJsonNumber,
                format!("\"{}\" is not a normalized number literal", crate::scan::shown(n)),
            )),
            _ => Err(super::de::mismatch("a string", json).with_code(Code::HausJsonNumber)),
        }
    }

    fn record(&self, json: &Json, depth: usize) -> R {
        let Json::Object(members) = json else {
            return Err(super::de::mismatch("an object", json).with_code(Code::HausJsonForm));
        };
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
                false => Err(DecodeError::new(
                    Code::DuplicateKey,
                    format!("the key \"{}\" is used twice", crate::scan::shown(k)),
                )),
            })
            .collect::<Result<_, _>>()
            .map(|fields| Value::Record(Record::from_unique(fields)))
    }

    fn variant(&self, tag: &Json, args: &Json, depth: usize) -> R {
        let tag = tag_name(tag, self.limits)?;
        let args = match args {
            Json::Array(items) if items.is_empty() => return Err(bad_args(args)),
            // `Tag { … }`: the record is the payload's only level, as the writer writes it.
            Json::Array(items) if matches!(items.as_slice(), [Json::Object(m)] if is_record(m)) => {
                vec![self.value(&items[0], depth).map_err(|e| e.index(0).field("_args"))?]
            }
            Json::Array(items) => self.items(items, depth).map_err(|e| e.field("_args"))?,
            _ => return Err(bad_args(args)),
        };
        Ok(Value::Variant { tag, args: List::from_checked(args) })
    }
}

/// `"_args"` that isn't a non-empty array. Kept out of [`Reader::variant`],
/// which recurses: its frame stays small.
#[cold]
#[inline(never)]
pub(crate) fn bad_args(args: &Json) -> DecodeError {
    let e = match args {
        Json::Array(_) => DecodeError::new(Code::HausJsonForm, r#"a tag without arguments has no "_args""#),
        _ => super::de::mismatch("an array", args).with_code(Code::HausJsonForm),
    };
    e.field("_args")
}

/// Whether an object is `{"_rec": …}`: a record, which as the only argument
/// is the payload's only level (`Tag { … }`).
pub(crate) fn is_record(members: &[(String, Json)]) -> bool {
    matches!(members, [(k, _)] if k == "_rec")
}

fn mismatch(json: &Json) -> DecodeError {
    super::de::mismatch(FORMS, json).with_code(Code::HausJsonForm)
}

/// `"Circle"`: a tag name, within the string limit. Errors are at the
/// variant, the object that holds `"_tag"`, as an unknown tag is (spec §15).
pub(crate) fn tag_name(json: &Json, limits: &Limits) -> Result<Tag, DecodeError> {
    match json {
        Json::String(t) if is_tag(t) => match check_tag(t, limits) {
            Ok(()) => Ok(Tag::from_valid(t.clone())),
            Err(e) => Err(e.into_decode()),
        },
        Json::String(t) => {
            let reason =
                format!("\"{}\" is not a tag name (A to Z, then letters, digits and _)", crate::scan::shown(t));
            Err(DecodeError::new(Code::InvalidTag, reason))
        }
        _ => Err(super::de::mismatch(r#"a tag name in a string ("_tag")"#, json).with_code(Code::InvalidTag)),
    }
}

/// `"0b34ff"`: two lowercase hex digits per byte, within the string limit
/// as the haus byte string's hex.
fn bytes(json: &Json, limits: &Limits) -> R {
    let Json::String(text) = json else {
        return Err(super::de::mismatch("a string", json).with_code(Code::HausJsonBytes));
    };
    if text.len() > limits.max_string_length {
        let reason = format!("byte string longer than {} characters", limits.max_string_length);
        return Err(DecodeError::new(Code::StringTooLong, reason));
    }
    let digit = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    let invalid = || DecodeError::new(Code::HausJsonBytes, "expected two lowercase hex digits per byte");
    if !text.len().is_multiple_of(2) {
        return Err(invalid());
    }
    text.as_bytes()
        .chunks(2)
        .map(|pair| Some(digit(pair[0])? * 16 + digit(pair[1])?))
        .collect::<Option<Vec<u8>>>()
        .map(|b| Value::Bytes(ByteString::from_checked(b)))
        .ok_or_else(invalid)
}
