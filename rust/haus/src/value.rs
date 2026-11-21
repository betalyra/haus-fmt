//! The haus data model, exactly as written in the source. No schema has been
//! applied: numbers are kept as exact literal text, and variants are generic.
//!
//! Every [`Value`] is a haus value (spec §1): its constructors reject what
//! isn't one (spec §11, "Values built in code"). A [`Number`] holds a number
//! literal, normalized; a [`Tag`] is a tag name; a [`Record`] has each key
//! once. So writing a value fails only beyond the writer's limits, and its
//! canonical form, hash, equality and order (spec §12) can't fail.

use crate::keys::{FEW, Keys, first_repeated};
use crate::scan::{is_ident, plain_decimal, shown};
use crate::{ErrorCode, Limits, ValueError};
use std::borrow::Borrow;
use std::collections::BTreeMap;
use std::fmt;
use std::ops::Deref;
use std::str::FromStr;

/// A haus value.
///
/// Build one with the constructors of its parts, which take only haus values:
/// [`Number::new`] and [`Value::number`], [`Tag::new`] and
/// [`Value::variant`], [`Record::insert`], [`Record::from_fields`] and
/// [`Value::record`]; strings, bytes, arrays and integers convert with
/// `From`.
///
/// ```
/// use haus::{Record, Value};
/// let mut person = Record::new();
/// person.insert("name", "Ada")?;
/// person.insert("born", Value::variant("Date", vec!["1815-12-10".into()])?)?;
/// person.insert("score", Value::number("1E+05")?)?;
/// assert_eq!(haus::to_string(&Value::from(person))?, r#"{ name: "Ada", born: Date("1815-12-10"), score: 1e5 }"#);
/// # Ok::<(), Box<dyn std::error::Error>>(())
/// ```
///
/// A value built in code may nest any depth. Dropping, cloning and comparing
/// with `==` take a heap stack rather than recursion, so they need no call
/// stack per level (a parsed value nests at most [`crate::MAX_SUPPORTED_DEPTH`]
/// levels). `==` compares the values as they are: the same kind, text, tag,
/// keys in the same order and equal parts; [`crate::equals`] is haus
/// equality (spec §2), for which key order doesn't matter. `{:?}` recurses,
/// one call per level.
#[derive(Debug)]
pub enum Value {
    /// A number literal, normalized (spec §2): `19.90`, `-1e10`, `255`.
    Number(Number),
    String(String),
    /// A byte string, written `x"0b34ff"`.
    Bytes(Vec<u8>),
    Array(Vec<Value>),
    /// Fields in source order, each key once.
    Record(Record),
    /// `args` is empty for a bare tag; `Tag { … }` has one record argument.
    Variant {
        tag: Tag,
        args: Vec<Value>,
    },
}

impl Value {
    /// A number from its literal, normalized as the parser reads it: see
    /// [`Number::new`].
    pub fn number(literal: &str) -> Result<Value, ValueError> {
        Number::new(literal).map(Value::Number)
    }

    /// A variant: `tag` with `args`, none for a bare tag. Fails if `tag`
    /// isn't a tag name (`invalid-tag`).
    ///
    /// ```
    /// let some = haus::Value::variant("Some", vec![1.into()]).unwrap();
    /// assert_eq!(haus::canonical(&some), "Some(1)");
    /// assert!(haus::Value::variant("some", vec![]).is_err());
    /// ```
    pub fn variant(tag: &str, args: Vec<Value>) -> Result<Value, ValueError> {
        Tag::new(tag).map(|tag| Value::Variant { tag, args })
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
            Value::Array(items) | Value::Variant { args: items, .. } => stack.append(items),
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

impl From<Record> for Value {
    fn from(r: Record) -> Value {
        Value::Record(r)
    }
}

/// A bare tag: `None`, `EUR`.
impl From<Tag> for Value {
    fn from(tag: Tag) -> Value {
        Value::Variant { tag, args: Vec::new() }
    }
}

/// `True` or `False`, as [`crate::Encode`] writes a `bool`.
impl From<bool> for Value {
    fn from(b: bool) -> Value {
        Tag::from_valid(if b { "True" } else { "False" }.to_owned()).into()
    }
}

impl From<&str> for Value {
    fn from(s: &str) -> Value {
        Value::String(s.to_owned())
    }
}

impl From<String> for Value {
    fn from(s: String) -> Value {
        Value::String(s)
    }
}

/// A byte string.
impl From<Vec<u8>> for Value {
    fn from(b: Vec<u8>) -> Value {
        Value::Bytes(b)
    }
}

impl From<Vec<Value>> for Value {
    fn from(items: Vec<Value>) -> Value {
        Value::Array(items)
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
                        todo.extend(x.iter().zip(y));
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
                        todo.extend(x.iter().zip(y));
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
        /// A container being copied: its parts so far, and the ones left.
        enum Frame<'a> {
            Array(Vec<Value>, std::slice::Iter<'a, Value>),
            Variant(&'a Tag, Vec<Value>, std::slice::Iter<'a, Value>),
            Record(Vec<(String, Value)>, std::slice::Iter<'a, (String, Value)>),
        }
        /// A copy of a value without parts, or the frame that copies its parts.
        fn start(v: &Value) -> Result<Value, Frame<'_>> {
            match v {
                Value::Number(n) => Ok(Value::Number(n.clone())),
                Value::String(s) => Ok(Value::String(s.clone())),
                Value::Bytes(b) => Ok(Value::Bytes(b.clone())),
                Value::Array(items) => Err(Frame::Array(Vec::with_capacity(items.len()), items.iter())),
                Value::Variant { tag, args } => Err(Frame::Variant(tag, Vec::with_capacity(args.len()), args.iter())),
                Value::Record(r) => Err(Frame::Record(Vec::with_capacity(r.len()), r.iter())),
            }
        }
        let mut stack = match start(self) {
            Ok(v) => return v,
            Err(frame) => vec![frame],
        };
        loop {
            let top = stack.last_mut().expect("a frame is open");
            let next = match top {
                Frame::Array(_, rest) | Frame::Variant(_, _, rest) => rest.next(),
                Frame::Record(done, rest) => rest.next().map(|(k, v)| {
                    done.push((k.clone(), Value::Array(Vec::new())));
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
                    Frame::Array(done, _) => Value::Array(done),
                    Frame::Variant(tag, done, _) => Value::Variant { tag: tag.clone(), args: done },
                    Frame::Record(done, _) => Value::Record(Record::from_unique(done)),
                },
            };
            // A finished part: the next part of the container below, or the copy.
            match stack.last_mut() {
                None => return copy,
                Some(Frame::Array(done, _) | Frame::Variant(_, done, _)) => done.push(copy),
                Some(Frame::Record(done, _)) => done.last_mut().expect("its key was pushed").1 = copy,
            }
        }
    }
}

// ── numbers ───────────────────────────────────────────────────

/// A number: a number literal, normalized as the parser reads it (spec §2).
/// Digit separators are removed, the exponent is written `e` with no `+` or
/// leading zeros, and hex and binary literals are decimal integers; the
/// scale stays (`19.90` is not `19.9`).
///
/// ```
/// use haus::Number;
/// assert_eq!(Number::new("1E+05").unwrap(), "1e5");
/// assert_eq!(Number::new("0xFF").unwrap(), "255");
/// assert_eq!(Number::new("1_000.50").unwrap(), "1000.50");
/// assert_eq!(Number::from(-7).as_str(), "-7");
/// assert!(Number::new("01").is_err() && Number::new("NaN").is_err() && Number::new("").is_err());
/// ```
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Number(String);

impl Number {
    /// The number of a literal (`1E+05`, `0xFF`, `1_000`), normalized
    /// (`1e5`, `255`, `1000`). Fails if `literal` isn't one number literal
    /// (`invalid-number`): `01`, `NaN`, `1.`, ` 1`, the empty text. There is
    /// no limit on its length or exponent: those are the writer's (spec §7).
    pub fn new(literal: &str) -> Result<Number, ValueError> {
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

/// A tag name: `[A-Z][A-Za-z0-9_]*` (spec §4). It derefs to its `str`, and
/// compares with one: `tag == "None"`.
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
    /// The tag `name`. Fails if it isn't a tag name (`invalid-tag`).
    pub fn new(name: &str) -> Result<Tag, ValueError> {
        match is_tag(name) {
            true => Ok(Tag(name.to_owned())),
            false => Err(invalid_tag(name)),
        }
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
        match is_tag(&name) {
            true => Ok(Tag(name)),
            false => Err(invalid_tag(&name)),
        }
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

/// A record: fields in order, each key once (spec §1).
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
#[derive(Default)]
pub struct Record {
    pub(crate) fields: Vec<(String, Value)>,
    /// The keys, chained, once [`Record::insert`] grew the record beyond a
    /// few: each insert then compares its key with a few others only.
    keys: Option<Box<Keys>>,
}

impl Record {
    /// A record without fields.
    pub fn new() -> Record {
        Record::default()
    }

    /// A record of `fields`, in order. Fails if a key is there twice
    /// (`duplicate-key`); finding that takes time linear in the keys.
    pub fn from_fields<K: Into<String>>(fields: impl IntoIterator<Item = (K, Value)>) -> Result<Record, ValueError> {
        let fields: Vec<(String, Value)> = fields.into_iter().map(|(k, v)| (k.into(), v)).collect();
        match first_repeated(&fields) {
            Some(i) => Err(duplicate_key(&fields[i].0)),
            None => Ok(Record { fields, keys: None }),
        }
    }

    /// Fields whose keys are known to be unique (the parser checked them).
    pub(crate) fn from_unique(fields: Vec<(String, Value)>) -> Record {
        Record { fields, keys: None }
    }

    /// Adds a field after the others. Fails if the record has the key
    /// already (`duplicate-key`), leaving it as it was: it never replaces a
    /// field's value (use [`Record::get_mut`] for that). Takes time linear
    /// in the key, not in the record.
    pub fn insert(&mut self, key: impl Into<String>, value: impl Into<Value>) -> Result<(), ValueError> {
        let key = key.into();
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
        self.fields.push((key, value.into()));
        Ok(())
    }

    /// The value of field `key`.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.fields.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    /// The value of field `key`, to change.
    pub fn get_mut(&mut self, key: &str) -> Option<&mut Value> {
        self.fields.iter_mut().find(|(k, _)| k == key).map(|(_, v)| v)
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

    /// The values, in order, to change.
    pub fn values_mut(&mut self) -> impl Iterator<Item = &mut Value> {
        self.fields.iter_mut().map(|(_, v)| v)
    }

    /// The fields, in order.
    pub fn as_slice(&self) -> &[(String, Value)] {
        &self.fields
    }

    /// The fields, in order.
    pub fn into_fields(self) -> Vec<(String, Value)> {
        self.fields
    }
}

fn duplicate_key(key: &str) -> ValueError {
    ValueError::new(ErrorCode::DuplicateKey, format!("duplicate key '{}'", shown(key)))
}

/// A copy of the fields (the chained keys are made again if needed).
impl Clone for Record {
    fn clone(&self) -> Record {
        Record::from_unique(self.fields.clone())
    }
}

/// The same fields in the same order.
impl PartialEq for Record {
    fn eq(&self, other: &Record) -> bool {
        self.fields == other.fields
    }
}

impl Eq for Record {}

/// `{"name": String("Ada"), …}`.
impl fmt::Debug for Record {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_map().entries(self.fields.iter().map(|(k, v)| (k, v))).finish()
    }
}

impl TryFrom<Vec<(String, Value)>> for Record {
    type Error = ValueError;
    fn try_from(fields: Vec<(String, Value)>) -> Result<Record, ValueError> {
        Record::from_fields(fields)
    }
}

/// The map's entries, in key order: its keys are unique.
impl From<BTreeMap<String, Value>> for Record {
    fn from(map: BTreeMap<String, Value>) -> Record {
        Record::from_unique(map.into_iter().collect())
    }
}

impl IntoIterator for Record {
    type Item = (String, Value);
    type IntoIter = std::vec::IntoIter<(String, Value)>;
    fn into_iter(self) -> Self::IntoIter {
        self.fields.into_iter()
    }
}

impl<'a> IntoIterator for &'a Record {
    type Item = &'a (String, Value);
    type IntoIter = std::slice::Iter<'a, (String, Value)>;
    fn into_iter(self) -> Self::IntoIter {
        self.fields.iter()
    }
}
