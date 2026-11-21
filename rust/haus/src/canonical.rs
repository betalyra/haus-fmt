//! The canonical form, equality and hashing (spec §12): one exact text per
//! value, the same in every binding. Equal values (§2) have identical
//! canonical forms, so [`hash`] is the same whatever the layout, comments,
//! key order or spelling of the document the value came from.
//!
//! ```
//! let v = haus::from_str::<haus::Value>(r#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }"#).unwrap();
//! assert_eq!(haus::canonical(&v), r#"Order{id:255,total:19.90,"x-y":1e5}"#);
//! ```
//!
//! None of them fails: every [`Value`] is a haus value, also one built in
//! code, whose constructors reject what isn't (spec §11, "Values built in
//! code"), and normalize a number literal as the parser does, so
//! `Number::new("1E+05")` hashes as the `1e5` parsed from it. The canonical
//! form has no limits: a value deeper or longer than a writer's limits still
//! has one.
//!
//! Nor do they need the node limit (spec §7): a [`Value`] owns its parts, so
//! it can't share them (a DAG) or contain itself, and its canonical form is
//! linear in the memory it takes, whether it was parsed or built in code. A
//! native value whose parts are shared (`Rc`) expands when it is encoded,
//! which the encoder's node limit bounds. Writing takes a stack rather than
//! recursion, so a value built in code may nest any depth. [`equals`]
//! compares the values themselves, without writing them.

use crate::Value;
use crate::ser::{key, quote};
use std::cmp::Ordering;
use std::fmt::Write;

/// The canonical form of a value (spec §12). Every value has one: an
/// integer of any size is written with all its decimal digits.
///
/// ```
/// use haus::{Number, Value};
/// let v = Value::record([("b", Value::from(Number::new("1E+05")?)), ("a", Value::variant("None", vec![])?)])?;
/// assert_eq!(haus::canonical(&v), "{a:None,b:1e5}");
/// # Ok::<(), haus::ValueError>(())
/// ```
pub fn canonical(value: &Value) -> String {
    let mut out = String::new();
    write(value, &mut out);
    out
}

/// Whether two values are equal (spec §2): numbers by their normalized
/// literals, strings and bytes as they are, records by their keys and
/// values whatever the order of their fields, variants by tag and
/// arguments. That is exactly when their canonical forms are the same; the
/// values are compared as they are, without writing them, so this can't
/// fail and takes no call stack per level.
///
/// ```
/// let [a, b] = ["{ x: 1, y: [0x10] }", "{ y: [16], x: 1 }"].map(|t| haus::parse(t).unwrap().remove(0));
/// assert!(haus::equals(&a, &b));
/// ```
pub fn equals(a: &Value, b: &Value) -> bool {
    let mut todo = vec![(a, b)];
    while let Some((a, b)) = todo.pop() {
        let same = match (a, b) {
            (Value::Number(x), Value::Number(y)) => x == y,
            (Value::String(x), Value::String(y)) => x == y,
            (Value::Bytes(x), Value::Bytes(y)) => x == y,
            (Value::Array(x), Value::Array(y)) => same_items(x, y, &mut todo),
            (Value::Record(x), Value::Record(y)) => same_fields(x.as_slice(), y.as_slice(), &mut todo),
            (Value::Variant { tag: s, args: x }, Value::Variant { tag: t, args: y }) => {
                s == t && same_items(x, y, &mut todo)
            }
            _ => false,
        };
        if !same {
            return false;
        }
    }
    true
}

/// Whether `x` and `y` have as many items: then each pair is left to compare.
fn same_items<'a>(x: &'a [Value], y: &'a [Value], todo: &mut Vec<(&'a Value, &'a Value)>) -> bool {
    x.len() == y.len() && {
        todo.extend(x.iter().zip(y));
        true
    }
}

/// Whether two records have the same keys: then the values of each key are
/// left to compare. Keys are unique, so records whose keys are in another
/// order are compared sorted.
fn same_fields<'a>(x: &'a [(String, Value)], y: &'a [(String, Value)], todo: &mut Vec<(&'a Value, &'a Value)>) -> bool {
    if x.len() != y.len() {
        return false;
    }
    if x.iter().zip(y).all(|((k, _), (l, _))| k == l) {
        todo.extend(x.iter().zip(y).map(|((_, v), (_, w))| (v, w)));
        return true;
    }
    let sorted = |fields: &'a [(String, Value)]| {
        let mut sorted: Vec<&'a (String, Value)> = fields.iter().collect();
        sorted.sort_unstable_by(|a, b| a.0.cmp(&b.0));
        sorted
    };
    let (x, y) = (sorted(x), sorted(y));
    x.iter().zip(&y).all(|((k, v), (l, w))| {
        todo.push((v, w));
        k == l
    })
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
pub fn compare(a: &Value, b: &Value) -> Ordering {
    canonical(a).cmp(&canonical(b))
}

/// The SHA-256 digest of the canonical form, as 64 lowercase hex digits
/// (spec §12). Needs the `hash` feature.
#[cfg(feature = "hash")]
pub fn hash(value: &Value) -> String {
    use sha2::{Digest, Sha256};
    hex(&Sha256::digest(canonical(value).as_bytes()))
}

/// The hash of a list of values, such as a whole file (spec §12): the
/// SHA-256 digest of their canonical forms joined by `,`. A list of one value
/// hashes like the value. The items of a stream are hashed one by one with
/// [`hash`]. Needs the `hash` feature.
///
/// ```
/// let vs = haus::parse("1, \"a\",").unwrap();
/// assert_eq!(haus::hash_all(&vs[..1]), haus::hash(&vs[0]));
/// ```
#[cfg(feature = "hash")]
pub fn hash_all<'a>(values: impl IntoIterator<Item = &'a Value>) -> String {
    use sha2::{Digest, Sha256};
    let mut sha = Sha256::new();
    let mut text = String::new();
    for (i, v) in values.into_iter().enumerate() {
        if i > 0 {
            sha.update(b",");
        }
        text.clear();
        write(v, &mut text);
        sha.update(text.as_bytes());
    }
    hex(&sha.finalize())
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
        sorted.sort_unstable_by(|a, b| a.0.cmp(&b.0));
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
            Next::Value(Value::Number(n)) => out.push_str(n.as_str()),
            Next::Value(Value::String(s)) => quote(s, out),
            Next::Value(Value::Bytes(b)) => {
                out.push_str("x\"");
                for x in b {
                    let _ = write!(out, "{x:02x}");
                }
                out.push('"');
            }
            Next::Value(Value::Array(items)) => list('[', items, ']', out, &mut todo),
            Next::Value(Value::Record(r)) => record(r.as_slice(), out, &mut todo),
            Next::Value(Value::Variant { tag, args }) => {
                out.push_str(tag);
                match args.as_slice() {
                    [] => {}
                    [Value::Record(r)] => record(r.as_slice(), out, &mut todo),
                    _ => list('(', args, ')', out, &mut todo),
                }
            }
        }
    }
}
