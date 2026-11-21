//! JSON (spec §16): the three forms that connect haus and JSON, and a strict
//! JSON reader and writer for them.
//!
//! - **Schema-based JSON** (§16.3), the JSON a JSON consumer expects, needs
//!   the schema type: haus-fmt-build implements [`ToJson`] and [`FromJson`]
//!   for every type it generates, and [`to_string`] / [`from_str`] write and
//!   read them.
//! - **Self-describing JSON** (§16.2), [`crate::to_haus_json`] and
//!   [`crate::from_haus_json`], carries every haus value through JSON and
//!   back, without a schema: `{"_haus": 1, "_value": {"_num": "19.90"}}`.
//! - **JSON import** (§16.1), [`crate::import_json`], reads any JSON as a
//!   haus [`Value`], without a schema: `null` is `None`, `true`
//!   is `True`, numbers keep their text. It only reads.
//!
//! The caller says which form it reads; the data never decides. To the
//! schema-based reader and the import, an envelope is an object like any other.
//!
//! ```
//! let ids: Vec<haus::Int> = haus::json::from_str(r#"["1", "123456789012345678901234567890"]"#).unwrap();
//! assert_eq!(ids[1].as_str(), "123456789012345678901234567890");
//! assert_eq!(haus::json::to_string(&Some(1.5f64)).unwrap(), "1.5");
//! assert_eq!(haus::json::to_string(&Some(None::<f64>)).unwrap(), r#"{"_tag":"Some","value":null}"#);
//!
//! let value = haus::parse("Point(1, 2.50)").unwrap().remove(0);
//! let json = haus::to_haus_json(&value).unwrap();
//! assert_eq!(json, r#"{"_haus":1,"_value":{"_tag":"Point","_args":[{"_num":"1"},{"_num":"2.50"}]}}"#);
//! assert_eq!(haus::from_haus_json(&json).unwrap(), value);
//! ```
//!
//! The reader takes RFC 8259 JSON restricted to I-JSON (RFC 7493): UTF-8, no
//! duplicate member names, no unpaired surrogates in `\u` escapes; a leading
//! byte order mark is ignored. Numbers keep their text and are never rounded
//! through a float, except where the type is a float. Self-describing JSON
//! may not hold raw DEL, C1 or bidi controls in strings and member names;
//! the other forms accept them. Writers escape them, and every character
//! below U+0020.
//!
//! The limits of spec §7 apply to the haus value that results. A form can
//! take several JSON levels for one haus level, so schema-based JSON may nest
//! 4·d + 1 levels (d is [`Limits::max_depth`]), self-describing JSON one more
//! for its envelope, and the depth of the resulting value is then checked
//! against d. The import's JSON may nest d levels.
//!
//! A stream is JSON Lines (§16): one JSON text per value, each followed by a
//! line feed: [`to_string_all`], [`from_str_all`], [`encode`], [`decode`]
//! for schema-based JSON, [`to_haus_json_lines`] and
//! [`from_haus_json_lines`] for self-describing JSON, an envelope per line.
//! Readers accept a missing line feed after the last value and CR LF; a byte
//! order mark is ignored only at the start of the stream.

mod base64;
pub mod de;
mod haus_json;
mod import;
mod read;
pub mod ser;

use crate::error::Position;
use crate::keys::{FEW, Keys, first_repeated};
use crate::{
    DecodeError, Decoder, Encode, EncodeError, Encoder, Error, ErrorCode, Limits, SyntaxError, Value, ValueError,
};
use read::Form;
use std::io::{BufRead, Read, Write};

pub use haus_json::{from_self_describing, to_self_describing};
pub use import::import;

/// A JSON value. Numbers are kept as their exact text, and objects as their
/// members in order, each name once (I-JSON, RFC 7493).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Json {
    Null,
    Bool(bool),
    /// The number as written: `19.90`, `-1E+5`.
    Number(JsonNumber),
    String(String),
    Array(Vec<Json>),
    Object(JsonObject),
}

impl Json {
    /// An object of `members`, in order: see [`JsonObject::from_members`].
    pub fn object<K: Into<String>>(members: impl IntoIterator<Item = (K, Json)>) -> Result<Json, ValueError> {
        JsonObject::from_members(members).map(Json::Object)
    }

    /// A member of an object.
    pub fn get(&self, name: &str) -> Option<&Json> {
        match self {
            Json::Object(members) => members.get(name),
            _ => None,
        }
    }
}

/// A JSON object: members in order, each name once (I-JSON, RFC 7493, as
/// spec §16 reads JSON). Its constructors reject a name given twice
/// (`duplicate-key`), as [`crate::Record`]'s reject a key given twice, so
/// writing an object never meets one. It derefs to its members.
///
/// ```
/// use haus::json::{Json, JsonObject};
/// let mut o = JsonObject::new();
/// o.insert("a", Json::Null).unwrap();
/// assert!(o.insert("a", Json::Bool(true)).is_err());
/// assert_eq!(o.get("a"), Some(&Json::Null));
/// assert!(Json::object([("b", Json::Null), ("b", Json::Null)]).is_err());
/// ```
#[derive(Default)]
pub struct JsonObject {
    members: Vec<(String, Json)>,
    /// The names, chained, once [`JsonObject::insert`] grew the object
    /// beyond a few: each insert then compares its name with a few others only.
    names: Option<Box<Keys>>,
}

impl JsonObject {
    /// An object without members.
    pub fn new() -> JsonObject {
        JsonObject::default()
    }

    /// An object of `members`, in order. Fails if a name is there twice
    /// (`duplicate-key`); finding that takes time linear in the names.
    pub fn from_members<K: Into<String>>(
        members: impl IntoIterator<Item = (K, Json)>,
    ) -> Result<JsonObject, ValueError> {
        let members: Vec<(String, Json)> = members.into_iter().map(|(k, v)| (k.into(), v)).collect();
        match first_repeated(&members) {
            Some(i) => Err(duplicate_name(&members[i].0)),
            None => Ok(JsonObject { members, names: None }),
        }
    }

    /// Members whose names are known to be unique.
    pub(crate) fn from_unique(members: Vec<(String, Json)>) -> JsonObject {
        JsonObject { members, names: None }
    }

    /// Adds a member after the others. Fails if the object has the name
    /// already (`duplicate-key`), leaving it as it was. Takes time linear
    /// in the name, not in the object.
    pub fn insert(&mut self, name: impl Into<String>, value: Json) -> Result<(), ValueError> {
        let name = name.into();
        let new = match &mut self.names {
            Some(names) => names.insert(&self.members, &name),
            None if self.members.len() < FEW => !self.members.iter().any(|(k, _)| *k == name),
            None => {
                let mut names = Box::new(Keys::of(&self.members));
                let new = names.insert(&self.members, &name);
                self.names = Some(names);
                new
            }
        };
        if !new {
            return Err(duplicate_name(&name));
        }
        self.members.push((name, value));
        Ok(())
    }

    /// The value of member `name`.
    pub fn get(&self, name: &str) -> Option<&Json> {
        self.members.iter().find(|(k, _)| k == name).map(|(_, v)| v)
    }

    /// The members, in order.
    pub fn as_slice(&self) -> &[(String, Json)] {
        &self.members
    }

    /// The members, in order.
    pub fn into_members(self) -> Vec<(String, Json)> {
        self.members
    }
}

fn duplicate_name(name: &str) -> ValueError {
    ValueError::new(ErrorCode::DuplicateKey, format!("duplicate member name \"{}\"", crate::scan::shown(name)))
}

/// The members, in order.
impl std::ops::Deref for JsonObject {
    type Target = [(String, Json)];
    fn deref(&self) -> &[(String, Json)] {
        &self.members
    }
}

/// A copy of the members (the chained names are made again if needed).
impl Clone for JsonObject {
    fn clone(&self) -> JsonObject {
        JsonObject::from_unique(self.members.clone())
    }
}

/// The same members in the same order.
impl PartialEq for JsonObject {
    fn eq(&self, other: &JsonObject) -> bool {
        self.members == other.members
    }
}

impl Eq for JsonObject {}

impl std::fmt::Debug for JsonObject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_map().entries(self.members.iter().map(|(k, v)| (k, v))).finish()
    }
}

impl TryFrom<Vec<(String, Json)>> for JsonObject {
    type Error = ValueError;
    fn try_from(members: Vec<(String, Json)>) -> Result<JsonObject, ValueError> {
        JsonObject::from_members(members)
    }
}

impl IntoIterator for JsonObject {
    type Item = (String, Json);
    type IntoIter = std::vec::IntoIter<(String, Json)>;
    fn into_iter(self) -> Self::IntoIter {
        self.members.into_iter()
    }
}

impl<'a> IntoIterator for &'a JsonObject {
    type Item = &'a (String, Json);
    type IntoIter = std::slice::Iter<'a, (String, Json)>;
    fn into_iter(self) -> Self::IntoIter {
        self.members.iter()
    }
}

/// A JSON number, as written: `19.90`, `-1E+5` (RFC 8259,
/// `-?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?`). It derefs to its text.
///
/// ```
/// use haus::json::JsonNumber;
/// assert_eq!(JsonNumber::new("-1E+5").unwrap(), "-1E+5");
/// assert!(JsonNumber::new("01").is_err() && JsonNumber::new("0x1F").is_err() && JsonNumber::new("NaN").is_err());
/// ```
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct JsonNumber(String);

impl JsonNumber {
    /// The number `text`. Fails if it isn't a JSON number (`invalid-number`).
    /// There is no limit on its length or exponent: those are the writer's.
    pub fn new(text: &str) -> Result<JsonNumber, ValueError> {
        match is_number(text) {
            true => Ok(JsonNumber(text.to_owned())),
            false => {
                let reason = format!("invalid number '{}': not a JSON number", crate::scan::shown(text));
                Err(ValueError::new(ErrorCode::InvalidNumber, reason))
            }
        }
    }

    /// Text the reader or a writer knows is a JSON number.
    pub(crate) fn from_valid(text: String) -> JsonNumber {
        debug_assert!(is_number(&text), "{text:?} is a JSON number");
        JsonNumber(text)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

macro_rules! integers {
    ($($t:ty),*) => {$(
        impl From<$t> for JsonNumber {
            fn from(n: $t) -> JsonNumber {
                JsonNumber(n.to_string())
            }
        }
    )*};
}
integers!(i8, i16, i32, i64, i128, isize, u8, u16, u32, u64, u128, usize);

impl std::str::FromStr for JsonNumber {
    type Err = ValueError;
    fn from_str(text: &str) -> Result<JsonNumber, ValueError> {
        JsonNumber::new(text)
    }
}

impl TryFrom<&str> for JsonNumber {
    type Error = ValueError;
    fn try_from(text: &str) -> Result<JsonNumber, ValueError> {
        JsonNumber::new(text)
    }
}

impl std::ops::Deref for JsonNumber {
    type Target = str;
    fn deref(&self) -> &str {
        &self.0
    }
}

impl AsRef<str> for JsonNumber {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for JsonNumber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// The text, as it is written: `Number(-1E+5)` in a [`Json`].
impl std::fmt::Debug for JsonNumber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl PartialEq<str> for JsonNumber {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for JsonNumber {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

/// A Rust type written as schema-based JSON (spec §16.3). haus-fmt-build implements it
/// for the types it generates.
pub trait ToJson {
    /// Whether this type's JSON can be `null`: only a `Maybe` that writes
    /// `None` as `null` (§16.3). A `Maybe` of such a type writes the tagged form.
    const NULLABLE: bool = false;

    /// The schema-based JSON, for a reader with `e`'s limits, at `e`'s depth. Fails
    /// only for a value that has none: one nested deeper than the depth limit
    /// as a haus value (checked before each container, so a deep value fails
    /// instead of recursing on), a number, string, key or tag beyond its
    /// limit (in the raw value of an `Any` or an unknown variant, say), or a
    /// record payload with a field named `_tag` or `_args`. An error inside
    /// a `Secret` is reported at the secret (spec §15).
    fn to_json_with(&self, e: Encoder) -> Result<Json, EncodeError>;

    /// The schema-based JSON, for a reader with the default limits.
    fn to_json(&self) -> Result<Json, EncodeError> {
        self.to_json_with(Encoder::default())
    }
}

/// A Rust type read from schema-based JSON (spec §16.3). haus-fmt-build implements it
/// for the types it generates.
pub trait FromJson: Sized {
    /// As [`ToJson::NULLABLE`].
    const NULLABLE: bool = false;

    /// The value of `json`, for a reader with `d`'s limits, at `d`'s depth.
    /// Each container counts as a level of the haus value (a record, an
    /// array, a payload), checked before it is read, so that JSON nested
    /// deeper than the depth limit fails instead of recursing on. The
    /// value's depth is checked again when it is encoded: [`from_str`]
    /// does that.
    fn from_json_with(json: &Json, d: Decoder) -> Result<Self, DecodeError>;

    /// The value of `json`, for a reader with the default limits.
    fn from_json(json: &Json) -> Result<Self, DecodeError> {
        Self::from_json_with(json, Decoder::default())
    }
}

// ── reading and writing JSON text ─────────────────────────────

/// Read one JSON text with the default limits.
pub fn parse(text: &str) -> Result<Json, SyntaxError> {
    parse_with(text, &Limits::default())
}

/// Read one JSON text with `limits`, as the schema-based reader reads it:
/// it may nest 4·d + 1 levels (see the module docs).
pub fn parse_with(text: &str, limits: &Limits) -> Result<Json, SyntaxError> {
    read::parse(text, limits, Form::SchemaBased, true)
}

/// Read raw bytes, which must be UTF-8.
pub fn parse_bytes(bytes: &[u8]) -> Result<Json, SyntaxError> {
    match std::str::from_utf8(bytes) {
        Ok(text) => parse(text),
        Err(e) => {
            let valid = std::str::from_utf8(&bytes[..e.valid_up_to()]).unwrap_or_default();
            Err(SyntaxError::at(valid, e.valid_up_to(), ErrorCode::InvalidUtf8, "invalid UTF-8"))
        }
    }
}

/// Write JSON on one line, without spaces, for a reader with the default limits.
pub fn write(json: &Json) -> Result<String, EncodeError> {
    write_with(json, &Limits::default())
}

/// Write JSON on one line, for a reader with `limits`. A [`Json`] built in
/// code is checked as it is written: numbers must be within the number
/// limits, an object may have each member name once, and the nesting must
/// be within what the reader takes. These errors
/// say what, not where: the place could be inside a `Secret`. Lengths count
/// on the haus value, not on the JSON (spec §16 "Limits"), so the forms check
/// them where they build the JSON, as the readers do: a string's characters,
/// keys and tags, bytes as two characters per byte, in hex or base64.
pub fn write_with(json: &Json, limits: &Limits) -> Result<String, EncodeError> {
    write_form(json, limits, Form::SchemaBased)
}

/// [`write_with`], for a reader of `form`: it nests as deep as that reader takes.
fn write_form(json: &Json, limits: &Limits, form: Form) -> Result<String, EncodeError> {
    /// What is left to write, last first: a stack rather than recursion, so
    /// that deep nesting takes no call stack.
    enum Next<'a> {
        Value(&'a Json),
        Name(&'a str),
        Text(&'static str),
        Close(char),
    }
    crate::ser::supported(limits)?;
    let max = form.max_depth(limits);
    let (mut out, mut depth, mut todo) = (String::new(), 0, vec![Next::Value(json)]);
    while let Some(next) = todo.pop() {
        match next {
            Next::Text(t) => out.push_str(t),
            Next::Name(k) => {
                escape(k, &mut out);
                out.push(':');
            }
            Next::Close(c) => {
                out.push(c);
                depth -= 1;
            }
            Next::Value(Json::Null) => out.push_str("null"),
            Next::Value(Json::Bool(b)) => out.push_str(if *b { "true" } else { "false" }),
            Next::Value(Json::Number(n)) => {
                check_number(n, limits)?;
                out.push_str(n);
            }
            Next::Value(Json::String(s)) => escape(s, &mut out),
            Next::Value(Json::Array(items)) => {
                if depth >= max {
                    return Err(EncodeError::new(
                        ErrorCode::NestingTooDeep,
                        format!("JSON nested deeper than {max} levels"),
                    ));
                }
                depth += 1;
                out.push('[');
                todo.push(Next::Close(']'));
                for (i, x) in items.iter().enumerate().rev() {
                    todo.push(Next::Value(x));
                    if i > 0 {
                        todo.push(Next::Text(","));
                    }
                }
            }
            Next::Value(Json::Object(members)) => {
                if depth >= max {
                    return Err(EncodeError::new(
                        ErrorCode::NestingTooDeep,
                        format!("JSON nested deeper than {max} levels"),
                    ));
                }
                depth += 1;
                out.push('{');
                todo.push(Next::Close('}'));
                for (i, (k, v)) in members.iter().enumerate().rev() {
                    todo.push(Next::Value(v));
                    todo.push(Next::Name(k));
                    if i > 0 {
                        todo.push(Next::Text(","));
                    }
                }
            }
        }
    }
    Ok(out)
}

/// Whether `n` is within the number limits.
fn check_number(n: &JsonNumber, limits: &Limits) -> Result<(), EncodeError> {
    if n.len() > limits.max_number_length {
        let reason = format!("number literal longer than {} characters", limits.max_number_length);
        return Err(EncodeError::new(ErrorCode::NumberTooLong, reason));
    }
    match n.split_once(['e', 'E']).map(|(_, e)| e.trim_start_matches(['+', '-']).trim_start_matches('0')) {
        Some(e) if e.len() > 19 || e.parse::<u64>().unwrap_or(0) > limits.max_exponent => {
            Err(EncodeError::new(ErrorCode::ExponentTooLarge, format!("exponent larger than {}", limits.max_exponent)))
        }
        _ => Ok(()),
    }
}

/// `-?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?`: a JSON number.
pub(crate) fn is_number(n: &str) -> bool {
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit());
    let (mantissa, exp) = n.split_once(['e', 'E']).map_or((n, None), |(m, e)| (m, Some(e)));
    let mantissa = mantissa.strip_prefix('-').unwrap_or(mantissa);
    let (int, frac) = mantissa.split_once('.').map_or((mantissa, None), |(i, f)| (i, Some(f)));
    (int == "0" || (digits(int) && !int.starts_with('0')))
        && frac.is_none_or(digits)
        && exp.is_none_or(|e| digits(e.strip_prefix(['+', '-']).unwrap_or(e)))
}

/// `s` as a JSON string, appended to `out`. Besides what JSON requires, DEL,
/// C1 and the bidi controls are escaped, so that the JSON can't display
/// differently from what it holds, and U+2028 and U+2029, so that JSON Lines
/// can be split at any line break software knows (spec §16).
pub(crate) fn escape(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if crate::scan::is_control(c) || crate::scan::is_bidi(c) || matches!(c, '\u{2028}' | '\u{2029}') => {
                out.push_str(&format!("\\u{:04x}", u32::from(c)));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

// ── schema-based JSON ────────────────────────────────────────

/// Read schema-based JSON (spec §16.3) as a `T`. The value that results must
/// nest at most 256 levels, as a haus value (it is encoded to check that).
pub fn from_str<T: FromJson + Encode>(text: &str) -> Result<T, Error> {
    from_str_with(text, &Limits::default())
}

/// [`from_str`] with `limits`. Fails if `limits.max_depth` is more than
/// [`crate::MAX_SUPPORTED_DEPTH`].
pub fn from_str_with<T: FromJson + Encode>(text: &str, limits: &Limits) -> Result<T, Error> {
    typed(&parse_with(text, limits)?, limits)
}

/// `json` as a `T` whose haus value is within the depth limit of `limits`:
/// it is encoded to check that, and an error encoding it is the error.
fn typed<T: FromJson + Encode>(json: &Json, limits: &Limits) -> Result<T, Error> {
    let x = T::from_json_with(json, Decoder::new(limits))?;
    match x.encode_with(Encoder::new(limits)) {
        Ok(_) => Ok(x),
        Err(e) => Err(e.into_decode().into()),
    }
}

/// Write a value as schema-based JSON (spec §16.3), on one line.
pub fn to_string<T: ToJson + ?Sized>(value: &T) -> Result<String, EncodeError> {
    to_string_with(value, &Limits::default())
}

/// [`to_string`], for a reader with `limits`. Fails if `limits.max_depth`
/// is more than [`crate::MAX_SUPPORTED_DEPTH`].
pub fn to_string_with<T: ToJson + ?Sized>(value: &T, limits: &Limits) -> Result<String, EncodeError> {
    write_with(&value.to_json_with(Encoder::new(limits))?, limits)
}

// ── self-describing JSON and the import ──────────────────────

/// [`crate::to_haus_json`], for a reader with `limits`. Fails if
/// `limits.max_depth` is more than [`crate::MAX_SUPPORTED_DEPTH`].
pub fn to_haus_json_with(value: &Value, limits: &Limits) -> Result<String, EncodeError> {
    write_form(&to_self_describing(value, limits)?, limits, Form::SelfDescribing)
}

/// [`crate::from_haus_json`] with `limits`. Fails if `limits.max_depth` is
/// more than [`crate::MAX_SUPPORTED_DEPTH`].
pub fn from_haus_json_with(text: &str, limits: &Limits) -> Result<Value, Error> {
    Ok(from_self_describing(&read::parse(text, limits, Form::SelfDescribing, true)?, limits)?)
}

/// [`crate::import_json`] with `limits`: the JSON may nest d levels, one per
/// level of the haus value. Fails if `limits.max_depth` is more than
/// [`crate::MAX_SUPPORTED_DEPTH`].
pub fn import_json_with(text: &str, limits: &Limits) -> Result<Value, Error> {
    Ok(import(&read::parse(text, limits, Form::Import, true)?, limits)?)
}

// ── JSON Lines ────────────────────────────────────────────────

/// Write values as schema-based JSON Lines: one JSON text per value, each
/// followed by a line feed. Errors say which value: `[3].total: …`.
pub fn to_string_all<T: ToJson>(values: &[T]) -> Result<String, EncodeError> {
    lines(values, to_string)
}

/// Write values as self-describing JSON Lines: an envelope per value, each
/// followed by a line feed. Errors say which value: `[3].total: …`.
pub fn to_haus_json_lines(values: &[Value]) -> Result<String, EncodeError> {
    lines(values, crate::to_haus_json)
}

/// Each value written by `write`, followed by a line feed.
fn lines<T>(values: &[T], write: impl Fn(&T) -> Result<String, EncodeError>) -> Result<String, EncodeError> {
    values.iter().enumerate().map(|(i, v)| write(v).map(|line| line + "\n").map_err(|e| e.item(i))).collect()
}

/// Read schema-based JSON Lines: every line a JSON text read as a `T`. The
/// last line may end without a line feed, lines may end with CR LF, and a
/// byte order mark is ignored at the start of the stream; empty lines, and a
/// byte order mark at the start of a later line, are errors (`json-syntax`,
/// at the line). Syntax errors give the line in the whole text, decode
/// errors the value's index: `$[3].price`.
pub fn from_str_all<T: FromJson + Encode>(text: &str) -> Result<Vec<T>, Error> {
    read_lines(text, |i, line| typed_line(i, line, &Limits::default()))
}

/// Read self-describing JSON Lines: every line an envelope, read as
/// [`from_str_all`] reads its lines.
pub fn from_haus_json_lines(text: &str) -> Result<Vec<Value>, Error> {
    let limits = Limits::default();
    read_lines(text, |i, line| {
        line_json(i, line, &limits, Form::SelfDescribing, |json| Ok(from_self_describing(json, &limits)?))
    })
}

/// The values of the lines of `text`, each read by `read` with its index.
/// No text, or only a byte order mark, is no values; a lone line feed is an
/// empty line.
fn read_lines<T>(text: &str, read: impl Fn(usize, &str) -> Result<T, Error>) -> Result<Vec<T>, Error> {
    if text.strip_prefix('\u{FEFF}').unwrap_or(text).is_empty() {
        return Ok(vec![]);
    }
    let text = text.strip_suffix('\n').unwrap_or(text);
    text.split('\n').enumerate().map(|(i, line)| read(i, line)).collect()
}

/// Line `i` (0-based) of schema-based JSON Lines, as a `T`.
fn typed_line<T: FromJson + Encode>(i: usize, line: &str, limits: &Limits) -> Result<T, Error> {
    line_json(i, line, limits, Form::SchemaBased, |json| typed(json, limits))
}

/// Line `i` (0-based) of JSON Lines in `form`, read as JSON and then by
/// `read`. Only the first line may start with a byte order mark: an empty
/// line, and a byte order mark at the start of a later line, are
/// `json-syntax` (spec §16 "Streams"). Syntax errors give the line, decode
/// errors the value's index (`$[3].price`).
fn line_json<T>(
    i: usize,
    line: &str,
    limits: &Limits,
    form: Form,
    read: impl FnOnce(&Json) -> Result<T, Error>,
) -> Result<T, Error> {
    let at = Position { offset: 0, line: i + 1, column: 1 };
    let content = if i == 0 { line.strip_prefix('\u{FEFF}').unwrap_or(line) } else { line };
    if content.strip_suffix('\r').unwrap_or(content).is_empty() {
        let reason = format!("JSON Lines: line {} is empty (a line holds one JSON text)", i + 1);
        return Err(SyntaxError::new(ErrorCode::JsonSyntax, reason, at).into());
    }
    if i > 0 && line.starts_with('\u{FEFF}') {
        let reason = format!(
            "JSON Lines: a byte order mark at the start of line {} (only the stream may start with one)",
            i + 1
        );
        return Err(SyntaxError::new(ErrorCode::JsonSyntax, reason, at).into());
    }
    let json = read::parse(line, limits, form, i == 0).map_err(|e| e.from(at))?;
    read(&json).map_err(|e| match e {
        Error::Decode(e) => Error::Decode(e.index(i)),
        e => e,
    })
}

/// Write `values` as schema-based JSON Lines. A value that can't be written
/// stops the output before it, with an error that says which: `[3].total: …`.
pub fn encode<T: ToJson, W: Write>(mut output: W, values: impl IntoIterator<Item = T>) -> Result<(), Error> {
    for (i, v) in values.into_iter().enumerate() {
        let line = to_string(&v).map_err(|e| e.item(i))?;
        writeln!(output, "{line}")?;
    }
    Ok(output.flush()?)
}

/// The values of schema-based JSON Lines read from `input`, as `T`, one line
/// at a time, as [`from_str_all`] reads them. A line may hold at most 64 Mi
/// characters (spec §7). The iterator ends after the first error.
pub fn decode<T: FromJson + Encode, R: BufRead>(input: R) -> impl Iterator<Item = Result<T, Error>> {
    const MAX_LINE: usize = 64 * 1024 * 1024;
    let mut input = Some(input);
    let mut index = 0;
    std::iter::from_fn(move || {
        let reader = input.as_mut()?;
        let mut line = Vec::new();
        let result = match Read::take(reader, 4 * MAX_LINE as u64 + 2).read_until(b'\n', &mut line) {
            Ok(0) => {
                input = None;
                return None;
            }
            Ok(_) => read_line(index, &line, MAX_LINE),
            Err(e) => Err(e.into()),
        };
        index += 1;
        if result.is_err() {
            input = None;
        }
        Some(result)
    })
}

/// One line of JSON Lines (with its line feed, if any), as a `T`.
fn read_line<T: FromJson + Encode>(i: usize, line: &[u8], max: usize) -> Result<T, Error> {
    let line = line.strip_suffix(b"\n").unwrap_or(line);
    let at = Position { offset: 0, line: i + 1, column: 1 };
    let text = std::str::from_utf8(line).map_err(|e| {
        let valid = std::str::from_utf8(&line[..e.valid_up_to()]).unwrap_or_default();
        SyntaxError::at(valid, e.valid_up_to(), ErrorCode::InvalidUtf8, "invalid UTF-8").from(at)
    })?;
    if text.len() > max && text.chars().count() > max {
        let reason = format!("JSON Lines: line {} is longer than {max} characters", i + 1);
        return Err(SyntaxError::new(ErrorCode::ValueTooLong, reason, at).into());
    }
    typed_line(i, text, &Limits::default())
}

// ── depth while decoding ─────────────────────────────────────

/// Whether this binding supports `limits` (spec §7), as a decoding error.
pub(crate) fn decode_supported(limits: &Limits) -> Result<(), DecodeError> {
    limits.unsupported().map_or(Ok(()), |reason| Err(DecodeError::new(ErrorCode::UnsupportedDepth, reason)))
}

/// The depth inside one more container, after `depth`, if `limits` allow it.
pub(crate) fn open(limits: &Limits, depth: usize) -> Result<usize, DecodeError> {
    decode_supported(limits)?;
    match depth >= limits.max_depth {
        true => {
            Err(DecodeError::new(ErrorCode::NestingTooDeep, format!("nesting deeper than {} levels", limits.max_depth)))
        }
        false => Ok(depth + 1),
    }
}
