//! The canonical form, equality and hashing (spec §12): one exact text per
//! value, the same in every binding. Equal values (§2) have identical
//! canonical forms, so [`hash`] is the same whatever the layout, comments,
//! key order or spelling of the document the value came from.
//!
//! ```
//! let v = haus::from_str::<haus::Value>(r#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }"#).unwrap();
//! assert_eq!(haus::canonical(&v), r#"Order{id:255,total:19.90,"x-y":1e5}"#);
//! ```

use crate::Value;
use crate::ser::{key, quote};
use std::fmt::Write;

/// The canonical form of a value (spec §12). Every value has one: an
/// integer of any size is written with all its decimal digits.
pub fn canonical(value: &Value) -> String {
    let mut out = String::new();
    write(value, &mut out);
    out
}

/// Whether two values are equal (spec §2): the same canonical form.
pub fn equals(a: &Value, b: &Value) -> bool {
    canonical(a) == canonical(b)
}

/// Orders values by the bytes of their canonical forms (spec §12): a total
/// order consistent with [`equals`], for sorting and ordered maps. Not
/// numeric order: `10` sorts before `9`.
///
/// ```
/// let mut vs: Vec<haus::Value> = ["9", "10", "\"a\"", "[]"].iter().map(|s| haus::from_str(s).unwrap()).collect();
/// vs.sort_by(haus::compare);
/// assert_eq!(vs.iter().map(haus::canonical).collect::<Vec<_>>(), ["\"a\"", "10", "9", "[]"]);
/// ```
pub fn compare(a: &Value, b: &Value) -> std::cmp::Ordering {
    canonical(a).cmp(&canonical(b))
}

/// The SHA-256 digest of the canonical form, as 64 lowercase hex digits
/// (spec §12). Needs the `hash` feature.
#[cfg(feature = "hash")]
pub fn hash(value: &Value) -> String {
    use sha2::{Digest, Sha256};
    hex(&Sha256::digest(canonical(value).as_bytes()))
}

/// The hash of a list of values, such as a whole file or stream (spec §12):
/// the SHA-256 digest of their canonical forms joined by `,`. A list of one
/// value hashes like the value. Needs the `hash` feature.
///
/// ```
/// let vs = haus::parse("1, \"a\",").unwrap();
/// assert_eq!(haus::hash_all(&vs[..1]), haus::hash(&vs[0]));
/// ```
#[cfg(feature = "hash")]
pub fn hash_all<'a>(values: impl IntoIterator<Item = &'a Value>) -> String {
    let mut hasher = Hasher::new();
    for v in values {
        hasher.add(v);
    }
    hasher.digest()
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

    /// Add the next value.
    pub fn add(&mut self, value: &Value) -> &mut Hasher {
        use sha2::Digest;
        if self.count > 0 {
            self.sha.update(b",");
        }
        self.count += 1;
        self.sha.update(canonical(value).as_bytes());
        self
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

/// `v`'s canonical form, appended to `out`. A stack rather than recursion,
/// so that a value built in code, which may nest deeper than any limit,
/// takes no call stack per level.
fn write(v: &Value, out: &mut String) {
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
    while let Some(next) = todo.pop() {
        match next {
            Next::Text(c) => out.push(c),
            Next::Key(k) => {
                key(k, out);
                out.push(':');
            }
            Next::Value(Value::Number(n)) => out.push_str(n),
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
}
