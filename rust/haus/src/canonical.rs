//! The canonical form, equality and hashing (spec §12): one exact text per
//! value, the same in every binding. Equal values (§2) have identical
//! canonical forms, so [`hash`] is the same whatever the layout, comments,
//! key order or spelling of the document the value came from.
//!
//! ```
//! let v = haus::from_str::<haus::Value>(r#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }"#).unwrap();
//! assert_eq!(haus::canonical(&v).unwrap(), r#"Order{id:255,total:19.90,"x-y":1e5}"#);
//! ```

use crate::ser::{key, number_text, quote};
use crate::{EncodeError, ErrorCode, Segment, Value};
use std::fmt::Write;

/// An integer whose decimal form is longer than this is written in hex in
/// the canonical form, and one whose hex form is longer too has none (spec
/// §12). A constant of the canonical form, not the number limit of §7: it
/// stays 1000 if the default limits grow.
const DECIMAL_MAX: usize = 1000;

/// The canonical form of a value (spec §12). An integer longer than 1000
/// characters in decimal and in hex, which only a value built in code or
/// parsed with a larger number limit can hold, has none: an [`EncodeError`]
/// (`number-too-long`) at its path.
pub fn canonical(value: &Value) -> Result<String, EncodeError> {
    let mut out = String::new();
    match write(value, &mut out) {
        None => Ok(out),
        Some(n) => Err(no_canonical_form(value, n)),
    }
}

/// Whether two values are equal (spec §2): the same canonical form. A
/// number without one compares by its hex form, which is as unique.
pub fn equals(a: &Value, b: &Value) -> bool {
    text(a) == text(b)
}

/// Orders values by the bytes of their canonical forms (spec §12): a total
/// order consistent with [`equals`], for sorting and ordered maps. Not
/// numeric order: `10` sorts before `9`.
///
/// ```
/// let mut vs: Vec<haus::Value> = ["9", "10", "\"a\"", "[]"].iter().map(|s| haus::from_str(s).unwrap()).collect();
/// vs.sort_by(haus::compare);
/// assert_eq!(vs.iter().map(|v| haus::canonical(v).unwrap()).collect::<Vec<_>>(), ["\"a\"", "10", "9", "[]"]);
/// ```
pub fn compare(a: &Value, b: &Value) -> std::cmp::Ordering {
    text(a).cmp(&text(b))
}

/// The SHA-256 digest of the canonical form, as 64 lowercase hex digits
/// (spec §12). An error (`number-too-long`) where [`canonical`] is one.
/// Needs the `hash` feature.
#[cfg(feature = "hash")]
pub fn hash(value: &Value) -> Result<String, EncodeError> {
    use sha2::{Digest, Sha256};
    Ok(hex(&Sha256::digest(canonical(value)?.as_bytes())))
}

/// The hash of a list of values, such as a whole file or stream (spec §12):
/// the SHA-256 digest of their canonical forms joined by `,`. A list of one
/// value hashes like the value. An error (`number-too-long`) at the first
/// value without a canonical form, with the path inside that value. Needs
/// the `hash` feature.
///
/// ```
/// let vs = haus::parse("1, \"a\",").unwrap();
/// assert_eq!(haus::hash_all(&vs[..1]), haus::hash(&vs[0]));
/// ```
#[cfg(feature = "hash")]
pub fn hash_all<'a>(values: impl IntoIterator<Item = &'a Value>) -> Result<String, EncodeError> {
    let hasher = values.into_iter().try_fold(Hasher::new(), |mut hasher, v| {
        hasher.add(v)?;
        Ok::<_, EncodeError>(hasher)
    })?;
    Ok(hasher.digest())
}

/// Hashes a list of values as it grows, e.g. a stream while it is read (spec
/// §12): [`Hasher::digest`] gives [`hash_all`] of the values added so far, at
/// any time. Memory stays bounded by the largest value. Needs the `hash` feature.
#[cfg(feature = "hash")]
#[derive(Clone, Default)]
pub struct Hasher {
    sha: sha2::Sha256,
    count: usize,
}

#[cfg(feature = "hash")]
impl Hasher {
    pub fn new() -> Hasher {
        Hasher::default()
    }

    /// Add the next value, or the error (`number-too-long`) of [`canonical`]
    /// if it has no canonical form; the hasher is then as it was.
    pub fn add(&mut self, value: &Value) -> Result<&mut Hasher, EncodeError> {
        use sha2::Digest;
        let text = canonical(value)?;
        if self.count > 0 {
            self.sha.update(b",");
        }
        self.count += 1;
        self.sha.update(text.as_bytes());
        Ok(self)
    }

    /// [`hash_all`] of the values added so far, as 64 lowercase hex digits.
    pub fn digest(&self) -> String {
        use sha2::Digest;
        hex(&self.sha.clone().finalize())
    }
}

#[cfg(feature = "hash")]
fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::with_capacity(64), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}

/// The canonical form, where a number without one is written in hex all
/// the same: the text equality and order compare.
fn text(value: &Value) -> String {
    let mut out = String::new();
    write(value, &mut out);
    out
}

/// The `number-too-long` error for the number `n` inside `root`.
fn no_canonical_form(root: &Value, n: &Value) -> EncodeError {
    let reason = format!("an integer longer than {DECIMAL_MAX} characters in hex too has no canonical form");
    let mut e = EncodeError::new(ErrorCode::NumberTooLong, reason);
    e.path = path_to(root, n);
    e
}

/// Where `target` is inside `root`, outermost first: searched only for an
/// error, so that the writer needn't track paths. The segments are the
/// writer's (spec §17): a tag's payload is `(Tag)`, then its index or field.
fn path_to(root: &Value, target: &Value) -> Vec<Segment> {
    // Every value met, with its parent's index and the steps from there.
    let mut met: Vec<(&Value, usize, Vec<Segment>)> = vec![(root, 0, Vec::new())];
    let mut i = 0;
    while let Some(&(v, ..)) = met.get(i) {
        if std::ptr::eq(v, target) {
            let mut steps = Vec::new();
            while i > 0 {
                let (_, parent, step) = &met[i];
                steps.extend(step.iter().rev().cloned());
                i = *parent;
            }
            steps.reverse();
            return steps;
        }
        let tagged = |tag: &str, s: Segment| vec![Segment::Tag(tag.to_owned()), s];
        match v {
            Value::Array(items) => met.extend(items.iter().enumerate().map(|(j, x)| (x, i, vec![Segment::Index(j)]))),
            Value::Record(fields) => met.extend(fields.iter().map(|(k, x)| (x, i, vec![Segment::Field(k.clone())]))),
            Value::Variant { tag, args } => match args.as_slice() {
                [Value::Record(fields)] => {
                    met.extend(fields.iter().map(|(k, x)| (x, i, tagged(tag, Segment::Field(k.clone())))))
                }
                _ => met.extend(args.iter().enumerate().map(|(j, x)| (x, i, tagged(tag, Segment::Index(j))))),
            },
            _ => {}
        }
        i += 1;
    }
    Vec::new()
}

/// `v`'s canonical form, appended to `out`, and the first number that has
/// none (written in hex all the same). A stack rather than recursion, so
/// that a value built in code, which may nest deeper than any limit, takes
/// no call stack per level.
fn write<'a>(v: &'a Value, out: &mut String) -> Option<&'a Value> {
    /// What is left to write, last first.
    enum Next<'a> {
        Value(&'a Value),
        Key(&'a str),
        Text(char),
    }
    /// `items` between `open` and `close`, separated by `,`.
    fn list<'a>(open: char, items: &'a [Value], close: char, out: &mut String, todo: &mut Vec<Next<'a>>) {
        out.push(open);
        todo.push(Next::Text(close));
        for (i, x) in items.iter().enumerate().rev() {
            todo.push(Next::Value(x));
            if i > 0 {
                todo.push(Next::Text(','));
            }
        }
    }
    /// Fields sorted by key. `str`'s order is the order of UTF-8 bytes, which
    /// is the order of code points (spec §12).
    fn record<'a>(fields: &'a [(String, Value)], out: &mut String, todo: &mut Vec<Next<'a>>) {
        let mut sorted: Vec<&(String, Value)> = fields.iter().collect();
        sorted.sort_by(|a, b| a.0.cmp(&b.0));
        out.push('{');
        todo.push(Next::Text('}'));
        for (i, (k, v)) in sorted.into_iter().enumerate().rev() {
            todo.push(Next::Value(v));
            todo.push(Next::Key(k));
            if i > 0 {
                todo.push(Next::Text(','));
            }
        }
    }
    let mut todo = vec![Next::Value(v)];
    let mut too_long = None;
    while let Some(next) = todo.pop() {
        match next {
            Next::Text(c) => out.push(c),
            Next::Key(k) => {
                key(k, out);
                out.push(':');
            }
            Next::Value(number @ Value::Number(n)) => {
                let text = number_text(n, DECIMAL_MAX);
                if text.len() > DECIMAL_MAX {
                    too_long = too_long.or(Some(number));
                }
                out.push_str(&text);
            }
            Next::Value(Value::String(s)) => quote(s, out),
            Next::Value(Value::Bytes(b)) => {
                out.push_str("x\"");
                for x in b {
                    let _ = write!(out, "{x:02x}");
                }
                out.push('"');
            }
            Next::Value(Value::Array(items)) => list('[', items, ']', out, &mut todo),
            Next::Value(Value::Record(fields)) => record(fields, out, &mut todo),
            Next::Value(Value::Variant { tag, args }) => {
                out.push_str(tag);
                match args.as_slice() {
                    [] => {}
                    [Value::Record(fields)] => record(fields, out, &mut todo),
                    _ => list('(', args, ')', out, &mut todo),
                }
            }
        }
    }
    too_long
}
