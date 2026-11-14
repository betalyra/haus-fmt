//! JSON (spec §16): the two mappings between haus and JSON, and a strict
//! JSON reader and writer for them.
//!
//! - **Without a schema** (§16.1), [`crate::from_json`] reads any JSON as a
//!   haus [`Value`](crate::Value): `null` is `None`, `true` is `True`, numbers keep their text.
//! - **Lossless** (§16.2), [`crate::to_lossless_json`] and
//!   [`crate::from_lossless_json`] carry every haus value through JSON and back:
//!   `{"num": "19.90"}`, `{"tag": "Some", "args": […]}`.
//! - **Plain** (§16.3), the JSON a JSON consumer expects, needs the schema
//!   type: haus-build implements [`ToJson`] and [`FromJson`] for every type it
//!   generates, and [`to_string`] / [`from_str`] write and read them.
//!
//! ```
//! let ids: Vec<haus::Int> = haus::json::from_str(r#"["1", "123456789012345678901234567890"]"#).unwrap();
//! assert_eq!(ids[1].as_str(), "123456789012345678901234567890");
//! assert_eq!(haus::json::to_string(&Some(1.5f64)).unwrap(), "1.5");
//! assert_eq!(haus::json::to_string(&Some(None::<f64>)).unwrap(), r#"{"_tag":"Some","value":null}"#);
//!
//! let value = haus::parse("Point(1, 2.50)").unwrap().remove(0);
//! let lossless = haus::to_lossless_json(&value).unwrap();
//! assert_eq!(lossless, r#"{"tag":"Point","args":[{"num":"1"},{"num":"2.50"}]}"#);
//! assert_eq!(haus::from_lossless_json(&lossless).unwrap(), value);
//! ```
//!
//! The reader takes RFC 8259 JSON restricted to I-JSON (RFC 7493): UTF-8, no
//! duplicate member names, no unpaired surrogates in `\u` escapes; a leading
//! byte order mark is ignored. Numbers keep their text and are never rounded
//! through a float, except where the type is a float.
//!
//! The limits of spec §7 apply to the haus value that results. A mapping can
//! take several JSON levels for one haus level, so JSON may nest 4·d + 1
//! levels (d is [`Limits::max_depth`]), and the depth of the resulting value
//! is then checked against d. Without a schema, JSON may nest d levels.
//!
//! A stream is JSON Lines (§16): one JSON text per value, each followed by a
//! line feed: [`to_string_all`], [`from_str_all`], [`encode`], [`decode`].
//! Readers accept a missing line feed after the last value and CR LF; a byte
//! order mark is ignored only at the start of the stream.

mod base64;
pub mod de;
mod lossless;
mod read;
pub mod ser;

use crate::error::Position;
use crate::{DecodeError, Encode, EncodeError, Error, Limits, Segment, SyntaxError, Value};
use std::io::{self, BufRead, Read, Write};

pub use lossless::{from_lossless, from_plain, to_lossless};

/// A JSON value. Numbers are kept as their exact text, and objects as their
/// members in order (names are unique in what the reader gives).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Json {
    Null,
    Bool(bool),
    /// The number as written: `19.90`, `-1E+5`.
    Number(String),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    /// A member of an object.
    pub fn get(&self, name: &str) -> Option<&Json> {
        match self {
            Json::Object(members) => members.iter().find(|(k, _)| k == name).map(|(_, v)| v),
            _ => None,
        }
    }
}

/// A Rust type written as plain JSON (spec §16.3). haus-build implements it
/// for the types it generates.
pub trait ToJson {
    /// Whether this type's JSON can be `null`: only a `Maybe` that writes
    /// `None` as `null` (§16.3). A `Maybe` of such a type writes the tagged form.
    const NULLABLE: bool = false;

    /// The plain JSON. Fails only for a value that has none: a [`Value`](crate::Value)
    /// built in code that isn't a valid haus value (the raw value of an `Any`
    /// or an unknown variant), or a record payload with a field named `_tag`.
    fn to_json(&self) -> Result<Json, EncodeError>;
}

/// A Rust type read from plain JSON (spec §16.3). haus-build implements it
/// for the types it generates.
pub trait FromJson: Sized {
    /// As [`ToJson::NULLABLE`].
    const NULLABLE: bool = false;

    fn from_json(json: &Json) -> Result<Self, DecodeError>;
}

// ── reading and writing JSON text ─────────────────────────────

/// Read one JSON text with the default limits.
pub fn parse(text: &str) -> Result<Json, SyntaxError> {
    parse_with(text, &Limits::default())
}

/// Read one JSON text with `limits`: it may nest 4·d + 1 levels (see the module docs).
pub fn parse_with(text: &str, limits: &Limits) -> Result<Json, SyntaxError> {
    read::parse(text, limits, read::max_depth(limits), true)
}

/// Read JSON without a schema (spec §16.1) with `limits`: as [`from_plain`]
/// after reading JSON that nests at most d levels.
pub fn value_from_str_with(text: &str, limits: &Limits) -> Result<Value, Error> {
    Ok(from_plain(&read::parse(text, limits, limits.max_depth, true)?, limits)?)
}

/// Read raw bytes, which must be UTF-8.
pub fn parse_bytes(bytes: &[u8]) -> Result<Json, SyntaxError> {
    match std::str::from_utf8(bytes) {
        Ok(text) => parse(text),
        Err(e) => {
            let valid = std::str::from_utf8(&bytes[..e.valid_up_to()]).unwrap_or_default();
            Err(SyntaxError::at(valid, e.valid_up_to(), "invalid UTF-8"))
        }
    }
}

/// Write JSON on one line, without spaces, for a reader with the default limits.
pub fn write(json: &Json) -> Result<String, EncodeError> {
    write_with(json, &Limits::default())
}

/// Write JSON on one line, for a reader with `limits`. A [`Json`] built in
/// code is checked as it is written: numbers must be JSON numbers within the
/// number limits, strings within the string limit, and the nesting within
/// what the reader takes. These errors say what, not where: the place could
/// be inside a `Secret`.
pub fn write_with(json: &Json, limits: &Limits) -> Result<String, EncodeError> {
    /// What is left to write, last first: a stack rather than recursion, so
    /// that deep nesting takes no call stack.
    enum Next<'a> {
        Value(&'a Json),
        Name(&'a str),
        Text(&'static str),
        Close(char),
    }
    let max = read::max_depth(limits);
    let (mut out, mut depth, mut todo) = (String::new(), 0, vec![Next::Value(json)]);
    while let Some(next) = todo.pop() {
        match next {
            Next::Text(t) => out.push_str(t),
            Next::Name(k) => {
                quote(k, limits, &mut out)?;
                out.push(':');
            }
            Next::Close(c) => {
                out.push(c);
                depth -= 1;
            }
            Next::Value(Json::Null) => out.push_str("null"),
            Next::Value(Json::Bool(b)) => out.push_str(if *b { "true" } else { "false" }),
            Next::Value(Json::Number(n)) => {
                check_number(n, limits).map_err(EncodeError::new)?;
                out.push_str(n);
            }
            Next::Value(Json::String(s)) => quote(s, limits, &mut out)?,
            Next::Value(Json::Array(items)) => {
                if depth >= max {
                    return Err(EncodeError::new(format!("JSON nested deeper than {max} levels")));
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
                    return Err(EncodeError::new(format!("JSON nested deeper than {max} levels")));
                }
                let mut seen = std::collections::HashSet::with_capacity(members.len());
                if !members.iter().all(|(k, _)| seen.insert(k.as_str())) {
                    return Err(EncodeError::new("a member name is used twice in an object"));
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

/// Whether `n` is a JSON number within the number limits.
fn check_number(n: &str, limits: &Limits) -> Result<(), String> {
    if !is_number(n) {
        return Err("not a JSON number".into());
    }
    if n.len() > limits.max_number_length {
        return Err(format!("number literal longer than {} characters", limits.max_number_length));
    }
    match n.split_once(['e', 'E']).map(|(_, e)| e.trim_start_matches(['+', '-']).trim_start_matches('0')) {
        Some(e) if e.len() > 19 || e.parse::<u64>().unwrap_or(0) > limits.max_exponent => {
            Err(format!("exponent larger than {}", limits.max_exponent))
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

/// A JSON string. Only what JSON requires is escaped.
fn quote(s: &str, limits: &Limits, out: &mut String) -> Result<(), EncodeError> {
    let max = limits.max_string_length;
    if s.len() > max && s.chars().count() > max {
        return Err(EncodeError::new(format!("string longer than {max} characters")));
    }
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
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", u32::from(c))),
            c => out.push(c),
        }
    }
    out.push('"');
    Ok(())
}

// ── plain JSON with a type ────────────────────────────────────

/// Read plain JSON (spec §16.3) as a `T`. The value that results must nest at
/// most 256 levels, as a haus value (it is encoded to check that).
pub fn from_str<T: FromJson + Encode>(text: &str) -> Result<T, Error> {
    from_str_with(text, &Limits::default())
}

/// [`from_str`] with `limits`. (An `Any` in it is read with the default limits.)
pub fn from_str_with<T: FromJson + Encode>(text: &str, limits: &Limits) -> Result<T, Error> {
    typed(&parse_with(text, limits)?, limits)
}

/// `json` as a `T` whose haus value is within the depth limit of `limits`.
fn typed<T: FromJson + Encode>(json: &Json, limits: &Limits) -> Result<T, Error> {
    let x = T::from_json(json)?;
    match depth(&x.encode()) > limits.max_depth {
        true => Err(DecodeError::new(format!("nesting deeper than {} levels", limits.max_depth)).into()),
        false => Ok(x),
    }
}

/// How deep a value nests, counted as the haus writer counts it (`Tag { … }`
/// is one level).
fn depth(v: &Value) -> usize {
    let deepest = |items: &[Value]| items.iter().map(depth).max().unwrap_or(0);
    match v {
        Value::Array(items) => 1 + deepest(items),
        Value::Record(fields) => 1 + fields.iter().map(|(_, v)| depth(v)).max().unwrap_or(0),
        Value::Variant { args, .. } => match args.as_slice() {
            [] => 0,
            [record @ Value::Record(_)] => depth(record),
            args => 1 + deepest(args),
        },
        _ => 0,
    }
}

/// Write a value as plain JSON (spec §16.3), on one line.
pub fn to_string<T: ToJson + ?Sized>(value: &T) -> Result<String, EncodeError> {
    to_string_with(value, &Limits::default())
}

/// [`to_string`], for a reader with `limits`.
pub fn to_string_with<T: ToJson + ?Sized>(value: &T, limits: &Limits) -> Result<String, EncodeError> {
    write_with(&value.to_json()?, limits)
}

// ── JSON Lines ────────────────────────────────────────────────

/// Write values as JSON Lines: one JSON text per value, each followed by a
/// line feed. Errors say which value: `[3].total: …`.
pub fn to_string_all<T: ToJson>(values: &[T]) -> Result<String, EncodeError> {
    values
        .iter()
        .enumerate()
        .map(|(i, v)| to_string(v).map(|line| line + "\n").map_err(|e| e.within(Segment::Index(i))))
        .collect()
}

/// Read JSON Lines: every line a JSON text read as a `T`. The last line may
/// end without a line feed, lines may end with CR LF, and a byte order mark
/// is ignored at the start; empty lines are errors. Syntax errors give the
/// line in the whole text, decode errors the value's index.
pub fn from_str_all<T: FromJson + Encode>(text: &str) -> Result<Vec<T>, Error> {
    let text = text.strip_suffix('\n').unwrap_or(text);
    if text.is_empty() {
        return Ok(vec![]);
    }
    text.split('\n').enumerate().map(|(i, line)| line_value(i, line, &Limits::default())).collect()
}

/// Line `i` (0-based) of JSON Lines, as a `T`. Only the first line may start
/// with a byte order mark.
fn line_value<T: FromJson + Encode>(i: usize, line: &str, limits: &Limits) -> Result<T, Error> {
    let at = Position { offset: 0, line: i + 1, column: 1 };
    let json = read::parse(line, limits, read::max_depth(limits), i == 0).map_err(|e| e.from(at))?;
    typed(&json, limits).map_err(|e| match e {
        Error::Decode(e) => Error::Decode(e.index(i)),
        e => e,
    })
}

/// Write `values` as JSON Lines. A value that can't be written stops the
/// output before it, with an error that says which: `[3].total: …`.
pub fn encode<T: ToJson, W: Write>(mut output: W, values: impl IntoIterator<Item = T>) -> Result<(), Error> {
    for (i, v) in values.into_iter().enumerate() {
        let line = to_string(&v).map_err(|e| e.within(Segment::Index(i)))?;
        writeln!(output, "{line}")?;
    }
    Ok(output.flush()?)
}

/// The values of JSON Lines read from `input`, as `T`, one line at a time,
/// as [`from_str_all`] reads them. A line may hold at most 64 Mi characters
/// (spec §7). The iterator ends after the first error.
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
        SyntaxError::at(valid, e.valid_up_to(), "invalid UTF-8").from(at)
    })?;
    if text.len() > max && text.chars().count() > max {
        let e = io::Error::new(io::ErrorKind::InvalidData, format!("line {} is longer than {max} characters", i + 1));
        return Err(e.into());
    }
    line_value(i, text, &Limits::default())
}
