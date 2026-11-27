//! The haus data model, exactly as written in the source. No schema has been
//! applied: numbers are kept as exact literal text, and variants are generic.
//!
//! Every [`Value`] is a haus value (spec §1) within the limits it was built
//! with (spec §7, §11): its parts are types whose constructors check what
//! they are given, so that a value that exists can always be written, and
//! read back by a reader with those limits. Building is the one step that
//! can fail; writing, the canonical form, hashing, equality and order are
//! total (spec §11, §12).

use crate::keys::{FEW, Keys, first_repeated};
use crate::parser::MAX_SUPPORTED_DEPTH;
use crate::scan::{is_ident, plain_decimal, shown};
use crate::{ErrorCode, Limits, ValueError};
use std::borrow::Borrow;
use std::collections::BTreeMap;
use std::fmt;
use std::ops::Deref;
use std::str::FromStr;

/// A haus value.
///
/// Its parts check what they are given when they are built, with the
/// default limits of spec §7, so that the value is a haus value a reader
/// with the default limits reads back: a [`Text`] or [`ByteString`] within
/// the string limit, a [`Number`] (a number literal, normalized, within the
/// number limits), a [`Tag`] (a tag name), a [`Record`] (each key once) and
/// a [`List`] (the elements of an array or the arguments of a variant), the
/// containers no deeper than the depth limit. Building is the one step that
/// fails ([`ValueError`], with the code of the mistake): a value that exists
/// is written, and has a canonical form, a hash, equality and order, without
/// any error (spec §11, §12).
///
/// ```
/// use haus::{Record, Value};
/// let mut person = Record::new();
/// person.insert("name", "Ada")?;
/// person.insert("born", Value::variant("Date", vec![Value::string("1815-12-10")?])?)?;
/// person.insert("score", Value::number("1E+05")?)?;
/// assert_eq!(haus::ser::write(&Value::from(person)), r#"{ name: "Ada", born: Date("1815-12-10"), score: 1e5 }"#);
/// # Ok::<(), haus::ValueError>(())
/// ```
///
/// Values don't change once they are built (spec §11): the parts of a
/// value are reached through shared references only, so a container's
/// recorded depth always matches its parts, and the safety net of spec §11
/// (`value-changed`, for a value changed after it was built) never fires in
/// Rust. A value built in code nests at most the depth limit (256 by
/// default); one parsed at most the parser's limit, which is at most
/// [`crate::MAX_SUPPORTED_DEPTH`]. Dropping, cloning and comparing with `==`
/// take a heap stack rather than recursion. `==` compares the values as they
/// are: the same kind, text, tag, keys in the same order and equal parts;
/// [`crate::equals`] is haus equality (spec §2), for which key order doesn't
/// matter. `{:?}` shows the first [`crate::DEBUG_DEPTH`] levels, then `…`.
pub enum Value {
    /// A number literal, normalized (spec §2): `19.90`, `-1e10`, `255`.
    Number(Number),
    String(Text),
    /// A byte string, written `x"0b34ff"`.
    Bytes(ByteString),
    Array(List),
    /// Fields in source order, each key once.
    Record(Record),
    /// `args` is empty for a bare tag; `Tag { … }` has one record argument.
    Variant {
        tag: Tag,
        args: List,
    },
}

impl Value {
    /// A number from its literal, normalized as the parser reads it: see
    /// [`Number::new`].
    pub fn number(literal: &str) -> Result<Value, ValueError> {
        Number::new(literal).map(Value::Number)
    }

    /// A string, within the string limit: see [`Text::new`].
    pub fn string(text: impl Into<String>) -> Result<Value, ValueError> {
        Text::new(text).map(Value::String)
    }

    /// A byte string, within the string limit: see [`ByteString::new`].
    pub fn bytes(bytes: impl Into<Vec<u8>>) -> Result<Value, ValueError> {
        ByteString::new(bytes).map(Value::Bytes)
    }

    /// An array of `items`, within the depth limit: see [`List::new`].
    pub fn array(items: Vec<Value>) -> Result<Value, ValueError> {
        List::new(items).map(Value::Array)
    }

    /// A variant: `tag` with `args`, none for a bare tag. Fails if `tag`
    /// isn't a tag name (`invalid-tag`) or the payload is nested deeper than
    /// the depth limit (`nesting-too-deep`).
    ///
    /// ```
    /// let some = haus::Value::variant("Some", vec![1.into()]).unwrap();
    /// assert_eq!(haus::canonical(&some), "Some(1)");
    /// assert!(haus::Value::variant("some", vec![]).is_err());
    /// ```
    pub fn variant(tag: &str, args: Vec<Value>) -> Result<Value, ValueError> {
        let (tag, limits) = (Tag::new(tag)?, Limits::default());
        // `Tag { … }` is as deep as its record, `Tag(…)` one more than its arguments.
        match args_depth(&args) > limits.max_depth {
            true => Err(too_deep(&limits)),
            false => Ok(Value::Variant { tag, args: List::from_checked(args) }),
        }
    }

    /// A record of `fields`, in order: see [`Record::from_fields`].
    pub fn record<K: Into<String>>(fields: impl IntoIterator<Item = (K, Value)>) -> Result<Value, ValueError> {
        Record::from_fields(fields).map(Value::Record)
    }

    /// A field of a record.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.as_record().and_then(|r| r.get(key))
    }

    /// The text of a string.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_number(&self) -> Option<&Number> {
        match self {
            Value::Number(n) => Some(n),
            _ => None,
        }
    }

    pub fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            Value::Bytes(b) => Some(b),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_record(&self) -> Option<&Record> {
        match self {
            Value::Record(r) => Some(r),
            _ => None,
        }
    }

    /// The tag and payload of a variant.
    pub fn as_variant(&self) -> Option<(&Tag, &[Value])> {
        match self {
            Value::Variant { tag, args } => Some((tag, args)),
            _ => None,
        }
    }

    /// How deep the value nests, counted as spec §7 counts values built in
    /// code: each array, record and parenthesized payload is a level, a
    /// record payload (`Tag { … }`) shares its tag's, and a value without
    /// parts (`1`, a bare tag) is at depth 0. Recorded when the containers
    /// are built: it takes no walk.
    ///
    /// ```
    /// let depth = |text: &str| haus::parse_one(text).unwrap().depth();
    /// assert_eq!((depth("1"), depth("[]"), depth("Some { a: 1 }"), depth("Some([])")), (0, 1, 1, 2));
    /// ```
    pub fn depth(&self) -> usize {
        match self {
            Value::Array(items) => items.depth(),
            Value::Record(r) => r.depth(),
            Value::Variant { args, .. } => match args.as_slice() {
                [] => 0,
                [Value::Record(r)] => r.depth(),
                _ => args.depth(),
            },
            _ => 0,
        }
    }

    /// The number of values it is written as (spec §7, "Size"): itself and
    /// every element, field value and argument inside it. Walks the value.
    pub fn size(&self) -> u64 {
        let mut todo = vec![self];
        let mut n = 0u64;
        while let Some(v) = todo.pop() {
            n += 1;
            match v {
                Value::Array(items) | Value::Variant { args: items, .. } => todo.extend(items.iter()),
                Value::Record(r) => todo.extend(r.values()),
                _ => {}
            }
        }
        n
    }

    /// Whether this is an array, record or variant with at least one part.
    fn has_parts(&self) -> bool {
        match self {
            Value::Array(items) | Value::Variant { args: items, .. } => !items.is_empty(),
            Value::Record(r) => !r.is_empty(),
            _ => false,
        }
    }

    /// Moves this value's parts onto `stack`, leaving it without parts.
    fn move_parts(&mut self, stack: &mut Vec<Value>) {
        match self {
            Value::Array(items) | Value::Variant { args: items, .. } => stack.append(&mut items.items),
            Value::Record(r) => {
                r.keys = None;
                stack.extend(r.fields.drain(..).map(|(_, v)| v));
            }
            _ => {}
        }
    }
}

impl From<Number> for Value {
    fn from(n: Number) -> Value {
        Value::Number(n)
    }
}

impl From<Text> for Value {
    fn from(s: Text) -> Value {
        Value::String(s)
    }
}

impl From<ByteString> for Value {
    fn from(b: ByteString) -> Value {
        Value::Bytes(b)
    }
}

/// An array.
impl From<List> for Value {
    fn from(items: List) -> Value {
        Value::Array(items)
    }
}

impl From<Record> for Value {
    fn from(r: Record) -> Value {
        Value::Record(r)
    }
}

/// A bare tag: `None`, `EUR`.
impl From<Tag> for Value {
    fn from(tag: Tag) -> Value {
        Value::Variant { tag, args: List::default() }
    }
}

/// `True` or `False`, as [`crate::Encode`] writes a `bool`.
impl From<bool> for Value {
    fn from(b: bool) -> Value {
        Tag::from_valid(if b { "True" } else { "False" }.to_owned()).into()
    }
}

/// A string, within the string limit ([`Text::new`]).
impl TryFrom<&str> for Value {
    type Error = ValueError;
    fn try_from(s: &str) -> Result<Value, ValueError> {
        Value::string(s)
    }
}

/// A string, within the string limit ([`Text::new`]).
impl TryFrom<String> for Value {
    type Error = ValueError;
    fn try_from(s: String) -> Result<Value, ValueError> {
        Value::string(s)
    }
}

/// A byte string, within the string limit ([`ByteString::new`]).
impl TryFrom<Vec<u8>> for Value {
    type Error = ValueError;
    fn try_from(b: Vec<u8>) -> Result<Value, ValueError> {
        Value::bytes(b)
    }
}

/// An array, within the depth limit ([`List::new`]).
impl TryFrom<Vec<Value>> for Value {
    type Error = ValueError;
    fn try_from(items: Vec<Value>) -> Result<Value, ValueError> {
        Value::array(items)
    }
}

/// What can become a [`Value`], checked as its constructor checks it: what
/// [`Record::insert`] takes. Strings, byte strings and arrays are checked
/// against the default limits; numbers, tags, records and values already are.
pub trait IntoValue {
    fn into_value(self) -> Result<Value, ValueError>;
}

macro_rules! into_value_from {
    ($($t:ty),*) => {$(
        impl IntoValue for $t {
            fn into_value(self) -> Result<Value, ValueError> {
                Ok(self.into())
            }
        }
    )*};
}
into_value_from!(Value, Number, Text, ByteString, List, Record, Tag, bool);
into_value_from!(i8, i16, i32, i64, i128, isize, u8, u16, u32, u64, u128, usize);

macro_rules! into_value_try {
    ($($t:ty),*) => {$(
        impl IntoValue for $t {
            fn into_value(self) -> Result<Value, ValueError> {
                Value::try_from(self)
            }
        }
    )*};
}
into_value_try!(&str, String, Vec<u8>, Vec<Value>);

impl IntoValue for &String {
    fn into_value(self) -> Result<Value, ValueError> {
        Value::string(self.as_str())
    }
}

/// Without recursion: a value nested deeper than one level hands its parts to
/// a stack, which takes theirs in turn, so each part is dropped without parts.
impl Drop for Value {
    fn drop(&mut self) {
        let nested = match self {
            Value::Array(items) | Value::Variant { args: items, .. } => items.iter().any(Value::has_parts),
            Value::Record(r) => r.values().any(Value::has_parts),
            _ => false,
        };
        if !nested {
            return;
        }
        let mut stack = Vec::new();
        self.move_parts(&mut stack);
        while let Some(mut v) = stack.pop() {
            v.move_parts(&mut stack);
        }
    }
}

/// As derived (`Variant { tag: Some, args: [Number(1)] }`), but only the
/// first [`crate::DEBUG_DEPTH`] levels: deeper containers are `…`.
impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&DebugAt(self, 0), f)
    }
}

/// A value at `depth` levels, for `{:?}`.
struct DebugAt<'a>(&'a Value, usize);

impl fmt::Debug for DebugAt<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let DebugAt(v, depth) = *self;
        if depth >= crate::DEBUG_DEPTH && v.has_parts() {
            return f.write_str("…");
        }
        match v {
            Value::Number(n) => f.debug_tuple("Number").field(n).finish(),
            Value::String(s) => f.debug_tuple("String").field(s).finish(),
            Value::Bytes(b) => f.debug_tuple("Bytes").field(b).finish(),
            Value::Array(items) => f.debug_tuple("Array").field(&ItemsAt(items, depth + 1)).finish(),
            Value::Record(r) => f.debug_tuple("Record").field(&FieldsAt(r, depth + 1)).finish(),
            Value::Variant { tag, args } => {
                f.debug_struct("Variant").field("tag", tag).field("args", &ItemsAt(args, depth + 1)).finish()
            }
        }
    }
}

/// Elements or arguments at `depth` levels, for `{:?}`.
struct ItemsAt<'a>(&'a [Value], usize);

impl fmt::Debug for ItemsAt<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_list().entries(self.0.iter().map(|v| DebugAt(v, self.1))).finish()
    }
}

/// Fields whose values are at `depth` levels, for `{:?}`.
struct FieldsAt<'a>(&'a Record, usize);

impl fmt::Debug for FieldsAt<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_map().entries(self.0.fields.iter().map(|(k, v)| (k, DebugAt(v, self.1)))).finish()
    }
}

/// Structural equality without recursion: the same kind, text, tag, keys in
/// the same order and equal parts.
impl PartialEq for Value {
    fn eq(&self, other: &Value) -> bool {
        // Values without parts are compared without a stack.
        match (self, other) {
            (Value::Number(x), Value::Number(y)) => return x == y,
            (Value::String(x), Value::String(y)) => return x == y,
            (Value::Bytes(x), Value::Bytes(y)) => return x == y,
            _ => {}
        }
        let mut todo = vec![(self, other)];
        while let Some((a, b)) = todo.pop() {
            let same = match (a, b) {
                (Value::Number(x), Value::Number(y)) => x == y,
                (Value::String(x), Value::String(y)) => x == y,
                (Value::Bytes(x), Value::Bytes(y)) => x == y,
                (Value::Array(x), Value::Array(y)) => {
                    x.len() == y.len() && {
                        todo.extend(x.iter().zip(y.iter()));
                        true
                    }
                }
                (Value::Record(x), Value::Record(y)) => {
                    x.len() == y.len()
                        && x.iter().zip(y).all(|((k, v), (l, w))| {
                            todo.push((v, w));
                            k == l
                        })
                }
                (Value::Variant { tag: s, args: x }, Value::Variant { tag: t, args: y }) => {
                    s == t && x.len() == y.len() && {
                        todo.extend(x.iter().zip(y.iter()));
                        true
                    }
                }
                _ => false,
            };
            if !same {
                return false;
            }
        }
        true
    }
}

impl Eq for Value {}

/// A copy, without recursion: containers are rebuilt from a stack of the ones
/// being copied, each finished when its last part is.
impl Clone for Value {
    fn clone(&self) -> Value {
        /// A container being copied: its depth, its parts so far, and the ones left.
        enum Frame<'a> {
            Array(u32, Vec<Value>, std::slice::Iter<'a, Value>),
            Variant(&'a Tag, u32, Vec<Value>, std::slice::Iter<'a, Value>),
            Record(u32, Vec<(String, Value)>, std::slice::Iter<'a, (String, Value)>),
        }
        /// A copy of a value without parts, or the frame that copies its parts.
        fn start(v: &Value) -> Result<Value, Frame<'_>> {
            match v {
                Value::Number(n) => Ok(Value::Number(n.clone())),
                Value::String(s) => Ok(Value::String(s.clone())),
                Value::Bytes(b) => Ok(Value::Bytes(b.clone())),
                Value::Array(items) => Err(Frame::Array(items.depth, Vec::with_capacity(items.len()), items.iter())),
                Value::Variant { tag, args } => {
                    Err(Frame::Variant(tag, args.depth, Vec::with_capacity(args.len()), args.iter()))
                }
                Value::Record(r) => Err(Frame::Record(r.depth, Vec::with_capacity(r.len()), r.iter())),
            }
        }
        let mut stack = match start(self) {
            Ok(v) => return v,
            Err(frame) => vec![frame],
        };
        loop {
            let top = stack.last_mut().expect("a frame is open");
            let next = match top {
                Frame::Array(_, _, rest) | Frame::Variant(_, _, _, rest) => rest.next(),
                Frame::Record(_, done, rest) => rest.next().map(|(k, v)| {
                    done.push((k.clone(), Value::Number(Number::from(0))));
                    v
                }),
            };
            let copy = match next {
                Some(part) => match start(part) {
                    Ok(v) => v,
                    Err(frame) => {
                        stack.push(frame);
                        continue;
                    }
                },
                None => match stack.pop().expect("a frame is open") {
                    Frame::Array(depth, done, _) => Value::Array(List { items: done, depth }),
                    Frame::Variant(tag, depth, done, _) => {
                        Value::Variant { tag: tag.clone(), args: List { items: done, depth } }
                    }
                    Frame::Record(depth, done, _) => Value::Record(Record { fields: done, keys: None, depth }),
                },
            };
            // A finished part: the next part of the container below, or the copy.
            match stack.last_mut() {
                None => return copy,
                Some(Frame::Array(_, done, _) | Frame::Variant(_, _, done, _)) => done.push(copy),
                Some(Frame::Record(_, done, _)) => done.last_mut().expect("its key was pushed").1 = copy,
            }
        }
    }
}

// ── limits ────────────────────────────────────────────────────

/// The depth of a variant with the arguments `args` (see [`Value::depth`]).
pub(crate) fn args_depth(args: &[Value]) -> usize {
    match args {
        [] => 0,
        [Value::Record(r)] => r.depth(),
        _ => 1 + args.iter().map(Value::depth).max().unwrap_or(0),
    }
}

/// The error for a container nested deeper than `limits` allow.
fn too_deep(limits: &Limits) -> ValueError {
    ValueError::new(ErrorCode::NestingTooDeep, format!("nesting deeper than {} levels", limits.max_depth))
}

/// Whether this binding supports `limits` (spec §7): an error naming
/// [`crate::MAX_SUPPORTED_DEPTH`] if the depth limit is above it.
fn supported(limits: &Limits) -> Result<(), ValueError> {
    limits.unsupported().map_or(Ok(()), |reason| Err(ValueError::new(ErrorCode::UnsupportedDepth, reason)))
}

/// Whether a string, key or tag (`code` says which) is within the string limit.
pub(crate) fn check_text(s: &str, code: ErrorCode, limits: &Limits) -> Result<(), ValueError> {
    let max = limits.max_string_length;
    if s.len() > max && s.chars().count() > max {
        let what = match code {
            ErrorCode::KeyTooLong => "key",
            ErrorCode::TagTooLong => "tag",
            _ => "string",
        };
        return Err(ValueError::new(code, format!("{what} longer than {max} characters")));
    }
    Ok(())
}

/// Whether a byte string's hex is within the string limit: two characters
/// per byte, also where JSON spells them in base64 (spec §16).
pub(crate) fn check_bytes(b: &[u8], limits: &Limits) -> Result<(), ValueError> {
    if b.len() > limits.max_string_length / 2 {
        let reason = format!("byte string longer than {} characters", limits.max_string_length);
        return Err(ValueError::new(ErrorCode::StringTooLong, reason));
    }
    Ok(())
}

/// Whether a number's normalized literal is within the number limits
/// (spec §7, §11): its length first (`number-too-long`), then its exponent
/// (`exponent-too-large`).
pub(crate) fn check_number(n: &str, limits: &Limits) -> Result<(), ValueError> {
    if n.len() > limits.max_number_length {
        let reason = format!("number literal longer than {} characters", limits.max_number_length);
        return Err(ValueError::new(ErrorCode::NumberTooLong, reason));
    }
    if let Some((_, exp)) = n.split_once('e')
        && limits.exponent_exceeds(exp.trim_start_matches('-'))
    {
        let reason = format!("exponent larger than {}", limits.max_exponent);
        return Err(ValueError::new(ErrorCode::ExponentTooLarge, reason));
    }
    Ok(())
}

/// The limits under which every value that exists was built: the deepest
/// any can be is [`MAX_SUPPORTED_DEPTH`], and no other limit is checked
/// again. For containers built from the parts of an existing value.
pub(crate) fn any() -> Limits {
    Limits {
        max_depth: MAX_SUPPORTED_DEPTH,
        max_number_length: usize::MAX,
        max_exponent: u64::MAX,
        max_string_length: usize::MAX,
        ..Limits::default()
    }
}

// ── strings ───────────────────────────────────────────────────

/// The text of a string: at most the string limit's characters (spec §7).
/// It derefs to its `str`, and compares with one: `text == "Ada"`.
///
/// ```
/// use haus::Text;
/// let t = Text::new("Ada").unwrap();
/// assert!(t == "Ada" && t.len() == 3);
/// let limits = haus::Limits { max_string_length: 2, ..haus::Limits::default() };
/// assert_eq!(Text::with_limits("Ada", &limits).unwrap_err().code, haus::ErrorCode::StringTooLong);
/// ```
#[derive(Clone, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Text(String);

impl Text {
    /// The text `s`, if it has at most 16 Mi characters (`string-too-long`).
    pub fn new(s: impl Into<String>) -> Result<Text, ValueError> {
        Text::with_limits(s, &Limits::default())
    }

    /// The text `s`, within the string limit of `limits`.
    pub fn with_limits(s: impl Into<String>, limits: &Limits) -> Result<Text, ValueError> {
        let s = s.into();
        check_text(&s, ErrorCode::StringTooLong, limits)?;
        Ok(Text(s))
    }

    /// Text checked already (by the parser, or against an encoder's limits).
    pub(crate) fn from_checked(s: String) -> Text {
        Text(s)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

impl Deref for Text {
    type Target = str;
    fn deref(&self) -> &str {
        &self.0
    }
}

impl AsRef<str> for Text {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl Borrow<str> for Text {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Text {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// As a `String`: `"Ada"`.
impl fmt::Debug for Text {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&self.0, f)
    }
}

impl PartialEq<str> for Text {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for Text {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

impl PartialEq<String> for Text {
    fn eq(&self, other: &String) -> bool {
        self.0 == *other
    }
}

impl TryFrom<&str> for Text {
    type Error = ValueError;
    fn try_from(s: &str) -> Result<Text, ValueError> {
        Text::new(s)
    }
}

impl TryFrom<String> for Text {
    type Error = ValueError;
    fn try_from(s: String) -> Result<Text, ValueError> {
        Text::new(s)
    }
}

impl From<Text> for String {
    fn from(t: Text) -> String {
        t.0
    }
}

/// The bytes of a byte string: at most half the string limit, since each
/// byte is written as two hex digits (spec §7). It derefs to its `[u8]`.
#[derive(Clone, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ByteString(Vec<u8>);

impl ByteString {
    /// The bytes `b`, if their hex has at most 16 Mi characters (`string-too-long`).
    pub fn new(b: impl Into<Vec<u8>>) -> Result<ByteString, ValueError> {
        ByteString::with_limits(b, &Limits::default())
    }

    /// The bytes `b`, within the string limit of `limits`.
    pub fn with_limits(b: impl Into<Vec<u8>>, limits: &Limits) -> Result<ByteString, ValueError> {
        let b = b.into();
        check_bytes(&b, limits)?;
        Ok(ByteString(b))
    }

    /// Bytes checked already (by the parser, or against an encoder's limits).
    pub(crate) fn from_checked(b: Vec<u8>) -> ByteString {
        ByteString(b)
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub fn into_vec(self) -> Vec<u8> {
        self.0
    }
}

impl Deref for ByteString {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        &self.0
    }
}

impl AsRef<[u8]> for ByteString {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

/// As a `Vec<u8>`: `[11, 52]`.
impl fmt::Debug for ByteString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&self.0, f)
    }
}

impl PartialEq<[u8]> for ByteString {
    fn eq(&self, other: &[u8]) -> bool {
        self.0 == other
    }
}

impl TryFrom<Vec<u8>> for ByteString {
    type Error = ValueError;
    fn try_from(b: Vec<u8>) -> Result<ByteString, ValueError> {
        ByteString::new(b)
    }
}

impl TryFrom<&[u8]> for ByteString {
    type Error = ValueError;
    fn try_from(b: &[u8]) -> Result<ByteString, ValueError> {
        ByteString::new(b)
    }
}

// ── lists ─────────────────────────────────────────────────────

/// The elements of an array, or the arguments of a variant: values in
/// order, nested at most the depth limit (spec §7). It records its depth,
/// one more than its deepest part's (see [`Value::depth`]), when it is
/// built, and derefs to `[Value]`.
///
/// ```
/// use haus::{List, Value};
/// let mut deep = Value::from(1);
/// for _ in 0..256 {
///     deep = List::new(vec![deep]).unwrap().into();
/// }
/// assert_eq!(deep.depth(), 256);
/// assert_eq!(List::new(vec![deep]).unwrap_err().code, haus::ErrorCode::NestingTooDeep);
/// ```
#[derive(Clone, PartialEq, Eq)]
pub struct List {
    items: Vec<Value>,
    depth: u32,
}

impl List {
    /// The values `items`, if, as an array, they nest at most 256 levels
    /// (`nesting-too-deep`).
    pub fn new(items: Vec<Value>) -> Result<List, ValueError> {
        List::with_limits(items, &Limits::default())
    }

    /// The values `items`, nested within the depth limit of `limits`. Only
    /// the depth is checked: each part was checked when it was built, and
    /// keeps the limits it was built with (spec §7).
    pub fn with_limits(items: Vec<Value>, limits: &Limits) -> Result<List, ValueError> {
        supported(limits)?;
        let list = List::from_checked(items);
        match list.depth() > limits.max_depth {
            true => Err(too_deep(limits)),
            false => Ok(list),
        }
    }

    /// No values: `[]`, or a bare tag's payload.
    pub const fn empty() -> List {
        List { items: Vec::new(), depth: 1 }
    }

    /// Values whose depth was checked already (by the parser, or against an
    /// encoder's limits): the depth is recorded.
    pub(crate) fn from_checked(items: Vec<Value>) -> List {
        let deepest = items.iter().map(Value::depth).max().unwrap_or(0);
        List { items, depth: u32::try_from(deepest + 1).unwrap_or(u32::MAX) }
    }

    /// How deep the values nest as an array: one more than the deepest.
    pub fn depth(&self) -> usize {
        self.depth as usize
    }

    pub fn as_slice(&self) -> &[Value] {
        &self.items
    }

    pub fn into_vec(self) -> Vec<Value> {
        self.items
    }
}

/// No values: `[]`, or a bare tag's payload.
impl Default for List {
    fn default() -> List {
        List::empty()
    }
}

impl Deref for List {
    type Target = [Value];
    fn deref(&self) -> &[Value] {
        &self.items
    }
}

impl AsRef<[Value]> for List {
    fn as_ref(&self) -> &[Value] {
        &self.items
    }
}

/// As a `Vec<Value>`.
impl fmt::Debug for List {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&ItemsAt(&self.items, 1), f)
    }
}

impl TryFrom<Vec<Value>> for List {
    type Error = ValueError;
    fn try_from(items: Vec<Value>) -> Result<List, ValueError> {
        List::new(items)
    }
}

impl IntoIterator for List {
    type Item = Value;
    type IntoIter = std::vec::IntoIter<Value>;
    fn into_iter(self) -> Self::IntoIter {
        self.items.into_iter()
    }
}

impl<'a> IntoIterator for &'a List {
    type Item = &'a Value;
    type IntoIter = std::slice::Iter<'a, Value>;
    fn into_iter(self) -> Self::IntoIter {
        self.items.iter()
    }
}

// ── numbers ───────────────────────────────────────────────────

/// A number: a number literal, normalized as the parser reads it (spec §2),
/// within the number limits on that form (spec §7). Digit separators are
/// removed, the exponent is written `e` with no `+` or leading zeros, and
/// hex and binary literals are decimal integers; the scale stays (`19.90`
/// is not `19.9`).
///
/// ```
/// use haus::Number;
/// assert_eq!(Number::new("1E+05").unwrap(), "1e5");
/// assert_eq!(Number::new("0xFF").unwrap(), "255");
/// assert_eq!(Number::new("1_000.50").unwrap(), "1000.50");
/// assert_eq!(Number::from(-7).as_str(), "-7");
/// assert!(Number::new("01").is_err() && Number::new("NaN").is_err() && Number::new("").is_err());
/// assert_eq!(Number::new(&"9".repeat(1001)).unwrap_err().code, haus::ErrorCode::NumberTooLong);
/// assert_eq!(Number::new("1e9999").unwrap_err().code, haus::ErrorCode::ExponentTooLarge);
/// ```
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Number(String);

impl Number {
    /// The number of a literal (`1E+05`, `0xFF`, `1_000`), normalized
    /// (`1e5`, `255`, `1000`). Fails if `literal` isn't one number literal
    /// (`invalid-number`): `01`, `NaN`, `1.`, ` 1`, the empty text; and if
    /// its normalized literal is beyond the default number limits:
    /// longer than 1000 characters (`number-too-long`), or with an exponent
    /// above 6144 (`exponent-too-large`).
    pub fn new(literal: &str) -> Result<Number, ValueError> {
        Number::with_limits(literal, &Limits::default())
    }

    /// [`Number::new`], within the number limits of `limits`.
    pub fn with_limits(literal: &str, limits: &Limits) -> Result<Number, ValueError> {
        let n = Number::parse(literal)?;
        check_number(&n.0, limits)?;
        Ok(n)
    }

    /// The number of a literal, normalized, whatever its length.
    fn parse(literal: &str) -> Result<Number, ValueError> {
        if plain_decimal(literal.as_bytes()) == Some(literal.len()) || is_normalized(literal) {
            return Ok(Number(literal.to_owned()));
        }
        let any = Limits { max_number_length: usize::MAX, max_exponent: u64::MAX, ..Limits::default() };
        crate::parser::number_literal(literal, &any).ok_or_else(|| {
            ValueError::new(
                ErrorCode::InvalidNumber,
                format!("invalid number '{}': not a number literal", shown(literal)),
            )
        })
    }

    /// A literal the parser normalized, or one made normalized.
    pub(crate) fn from_normalized(text: String) -> Number {
        debug_assert!(is_normalized(&text), "{text:?} is a normalized literal");
        Number(text)
    }

    /// The normalized literal: `1e5`.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

macro_rules! integers {
    ($($t:ty),*) => {$(
        impl From<$t> for Number {
            fn from(n: $t) -> Number {
                Number(n.to_string())
            }
        }
        impl From<$t> for Value {
            fn from(n: $t) -> Value {
                Value::Number(n.into())
            }
        }
    )*};
}
integers!(i8, i16, i32, i64, i128, isize, u8, u16, u32, u64, u128, usize);

impl FromStr for Number {
    type Err = ValueError;
    fn from_str(literal: &str) -> Result<Number, ValueError> {
        Number::new(literal)
    }
}

impl TryFrom<&str> for Number {
    type Error = ValueError;
    fn try_from(literal: &str) -> Result<Number, ValueError> {
        Number::new(literal)
    }
}

/// The normalized literal.
impl Deref for Number {
    type Target = str;
    fn deref(&self) -> &str {
        &self.0
    }
}

impl AsRef<str> for Number {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

/// The normalized literal: `1e5`.
impl fmt::Display for Number {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// The literal, as it is written: `Number(1e5)` in a [`Value`].
impl fmt::Debug for Number {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Whether the normalized literal is `other`, as written (`"1e5"`, not `"1E5"`).
impl PartialEq<str> for Number {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for Number {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

/// Whether `text` is a normalized literal (spec §2), as the parser gives it:
/// `-?(0|[1-9][0-9]*)(.[0-9]+)?(e(0|-?[1-9][0-9]*))?`.
pub(crate) fn is_normalized(text: &str) -> bool {
    fn whole(s: &str) -> bool {
        s == "0" || (s.starts_with(|c: char| ('1'..='9').contains(&c)) && s.bytes().all(|c| c.is_ascii_digit()))
    }
    let (mantissa, exp) = text.split_once('e').map_or((text, None), |(m, e)| (m, Some(e)));
    let mantissa = mantissa.strip_prefix('-').unwrap_or(mantissa);
    let (int, frac) = mantissa.split_once('.').map_or((mantissa, None), |(i, f)| (i, Some(f)));
    whole(int)
        && frac.is_none_or(|f| !f.is_empty() && f.bytes().all(|c| c.is_ascii_digit()))
        && exp.is_none_or(|e| whole(e) || e.strip_prefix('-').is_some_and(|d| d != "0" && whole(d)))
}

// ── tags ──────────────────────────────────────────────────────

/// A tag name: `[A-Z][A-Za-z0-9_]*` (spec §4), within the string limit. It
/// derefs to its `str`, and compares with one: `tag == "None"`.
///
/// ```
/// use haus::Tag;
/// let tag = Tag::new("EUR").unwrap();
/// assert!(tag == "EUR" && tag.len() == 3);
/// assert!(Tag::new("eur").is_err() && Tag::new("E-R").is_err() && Tag::new("").is_err());
/// ```
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Tag(String);

impl Tag {
    /// The tag `name`. Fails if it isn't a tag name (`invalid-tag`, checked
    /// first), or is longer than 16 Mi characters (`tag-too-long`).
    pub fn new(name: &str) -> Result<Tag, ValueError> {
        Tag::with_limits(name, &Limits::default())
    }

    /// [`Tag::new`], within the string limit of `limits`.
    pub fn with_limits(name: &str, limits: &Limits) -> Result<Tag, ValueError> {
        if !is_tag(name) {
            return Err(invalid_tag(name));
        }
        check_text(name, ErrorCode::TagTooLong, limits)?;
        Ok(Tag(name.to_owned()))
    }

    /// A name the parser read, or one known to be a tag name.
    pub(crate) fn from_valid(name: String) -> Tag {
        debug_assert!(is_tag(&name), "{name:?} is a tag name");
        Tag(name)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

/// Whether `name` is a tag name: `[A-Z][A-Za-z0-9_]*`.
pub(crate) fn is_tag(name: &str) -> bool {
    name.as_bytes().first().is_some_and(u8::is_ascii_uppercase) && name.bytes().all(is_ident)
}

fn invalid_tag(name: &str) -> ValueError {
    let reason = format!("invalid tag '{}': a tag is A to Z, then letters, digits and _", shown(name));
    ValueError::new(ErrorCode::InvalidTag, reason)
}

impl FromStr for Tag {
    type Err = ValueError;
    fn from_str(name: &str) -> Result<Tag, ValueError> {
        Tag::new(name)
    }
}

impl TryFrom<&str> for Tag {
    type Error = ValueError;
    fn try_from(name: &str) -> Result<Tag, ValueError> {
        Tag::new(name)
    }
}

impl TryFrom<String> for Tag {
    type Error = ValueError;
    fn try_from(name: String) -> Result<Tag, ValueError> {
        Tag::new(&name)
    }
}

impl Deref for Tag {
    type Target = str;
    fn deref(&self) -> &str {
        &self.0
    }
}

impl AsRef<str> for Tag {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

impl Borrow<str> for Tag {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Tag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// The name, as it is written: `Variant { tag: Some, … }` in a [`Value`].
impl fmt::Debug for Tag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl PartialEq<str> for Tag {
    fn eq(&self, other: &str) -> bool {
        self.0 == other
    }
}

impl PartialEq<&str> for Tag {
    fn eq(&self, other: &&str) -> bool {
        self.0 == *other
    }
}

impl PartialEq<Tag> for str {
    fn eq(&self, other: &Tag) -> bool {
        self == other.0
    }
}

impl PartialEq<Tag> for &str {
    fn eq(&self, other: &Tag) -> bool {
        *self == other.0
    }
}

// ── records ───────────────────────────────────────────────────

/// A record: fields in order, each key once (spec §1), each key within the
/// string limit, the record nested at most the depth limit (spec §7).
///
/// ```
/// use haus::{Record, Value};
/// let mut r = Record::new();
/// r.insert("name", "Ada").unwrap();
/// r.insert("born", 1815).unwrap();
/// assert_eq!(r.get("born"), Some(&Value::from(1815)));
/// assert_eq!(r.keys().collect::<Vec<_>>(), ["name", "born"]);
/// assert!(r.insert("name", "Grace").is_err());
/// assert!(Record::from_fields([("a", Value::from(1)), ("a", Value::from(2))]).is_err());
/// ```
pub struct Record {
    pub(crate) fields: Vec<(String, Value)>,
    /// The keys, chained, once [`Record::insert`] grew the record beyond a
    /// few: each insert then compares its key with a few others only.
    keys: Option<Box<Keys>>,
    /// One more than its deepest field's depth.
    depth: u32,
}

impl Record {
    /// A record without fields.
    pub fn new() -> Record {
        Record { fields: Vec::new(), keys: None, depth: 1 }
    }

    /// A record of `fields`, in order. Fails if a key is there twice
    /// (`duplicate-key`; finding that takes time linear in the keys), is
    /// longer than the string limit (`key-too-long`), or the record nests
    /// deeper than 256 levels (`nesting-too-deep`).
    pub fn from_fields<K: Into<String>>(fields: impl IntoIterator<Item = (K, Value)>) -> Result<Record, ValueError> {
        Record::from_fields_with(fields, &Limits::default())
    }

    /// [`Record::from_fields`], within `limits`: the length of each key and
    /// the depth. The values were checked when they were built.
    pub fn from_fields_with<K: Into<String>>(
        fields: impl IntoIterator<Item = (K, Value)>,
        limits: &Limits,
    ) -> Result<Record, ValueError> {
        supported(limits)?;
        let fields: Vec<(String, Value)> = fields.into_iter().map(|(k, v)| (k.into(), v)).collect();
        if let Some(i) = first_repeated(&fields) {
            return Err(duplicate_key(&fields[i].0));
        }
        fields.iter().try_for_each(|(k, _)| check_text(k, ErrorCode::KeyTooLong, limits))?;
        let record = Record::from_unique(fields);
        match record.depth() > limits.max_depth {
            true => Err(too_deep(limits)),
            false => Ok(record),
        }
    }

    /// Fields whose keys are known to be unique and within the limits, and
    /// whose depth was checked (the parser, an encoder): the depth is recorded.
    pub(crate) fn from_unique(fields: Vec<(String, Value)>) -> Record {
        let deepest = fields.iter().map(|(_, v)| v.depth()).max().unwrap_or(0);
        Record { fields, keys: None, depth: u32::try_from(deepest + 1).unwrap_or(u32::MAX) }
    }

    /// Adds a field after the others. Fails if the record has the key
    /// already (`duplicate-key`), if the key is longer than the string limit
    /// (`key-too-long`), if the value isn't one ([`IntoValue`]), or if the
    /// record would nest deeper than 256 levels (`nesting-too-deep`),
    /// leaving it as it was. It never replaces a field's value. Takes time
    /// linear in the key, not in the record.
    pub fn insert(&mut self, key: impl Into<String>, value: impl IntoValue) -> Result<(), ValueError> {
        let (key, value, limits) = (key.into(), value.into_value()?, Limits::default());
        check_text(&key, ErrorCode::KeyTooLong, &limits)?;
        if value.depth() + 1 > limits.max_depth {
            return Err(too_deep(&limits));
        }
        let new = match &mut self.keys {
            Some(keys) => keys.insert(&self.fields, &key),
            None if self.fields.len() < FEW => !self.fields.iter().any(|(k, _)| *k == key),
            None => {
                let mut keys = Box::new(Keys::of(&self.fields));
                let new = keys.insert(&self.fields, &key);
                self.keys = Some(keys);
                new
            }
        };
        if !new {
            return Err(duplicate_key(&key));
        }
        self.depth = self.depth.max(u32::try_from(value.depth() + 1).unwrap_or(u32::MAX));
        self.fields.push((key, value));
        Ok(())
    }

    /// How deep the record nests: one more than its deepest field.
    pub fn depth(&self) -> usize {
        self.depth as usize
    }

    /// The value of field `key`.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn contains_key(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    pub fn len(&self) -> usize {
        self.fields.len()
    }

    pub fn is_empty(&self) -> bool {
        self.fields.is_empty()
    }

    /// The fields, in order.
    pub fn iter(&self) -> std::slice::Iter<'_, (String, Value)> {
        self.fields.iter()
    }

    /// The keys, in order.
    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.fields.iter().map(|(k, _)| k.as_str())
    }

    /// The values, in order.
    pub fn values(&self) -> impl Iterator<Item = &Value> {
        self.fields.iter().map(|(_, v)| v)
    }

    /// The fields, in order.
    pub fn as_slice(&self) -> &[(String, Value)] {
        &self.fields
    }

    /// The fields, in order.
    pub fn into_fields(mut self) -> Vec<(String, Value)> {
        std::mem::take(&mut self.fields)
    }
}

impl Default for Record {
    fn default() -> Record {
        Record::new()
    }
}

fn duplicate_key(key: &str) -> ValueError {
    ValueError::new(ErrorCode::DuplicateKey, format!("duplicate key '{}'", shown(key)))
}

/// A copy of the fields (the chained keys are made again if needed).
impl Clone for Record {
    fn clone(&self) -> Record {
        Record { fields: self.fields.clone(), keys: None, depth: self.depth }
    }
}

/// The same fields in the same order.
impl PartialEq for Record {
    fn eq(&self, other: &Record) -> bool {
        self.fields == other.fields
    }
}

impl Eq for Record {}

/// The fields, as a map: the first [`crate::DEBUG_DEPTH`] levels (see [`Value`]).
impl fmt::Debug for Record {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&FieldsAt(self, 1), f)
    }
}

impl TryFrom<Vec<(String, Value)>> for Record {
    type Error = ValueError;
    fn try_from(fields: Vec<(String, Value)>) -> Result<Record, ValueError> {
        Record::from_fields(fields)
    }
}

/// The map's entries, in key order: its keys are unique.
impl TryFrom<BTreeMap<String, Value>> for Record {
    type Error = ValueError;
    fn try_from(map: BTreeMap<String, Value>) -> Result<Record, ValueError> {
        Record::from_fields(map)
    }
}

impl IntoIterator for Record {
    type Item = (String, Value);
    type IntoIter = std::vec::IntoIter<(String, Value)>;
    fn into_iter(self) -> Self::IntoIter {
        self.into_fields().into_iter()
    }
}

impl<'a> IntoIterator for &'a Record {
    type Item = &'a (String, Value);
    type IntoIter = std::slice::Iter<'a, (String, Value)>;
    fn into_iter(self) -> Self::IntoIter {
        self.fields.iter()
    }
}
