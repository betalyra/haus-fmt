//! The canonical form, equality and hashing (spec §12): one exact text per
//! value, the same in every binding. Equal values (§2) have identical
//! canonical forms, so [`hash`] is the same whatever the layout, comments,
//! key order or spelling of the document the value came from.
//!
//! ```
//! let v = haus::from_str::<haus::Value>(r#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5 }"#).unwrap();
//! assert_eq!(haus::canonical(&v).unwrap(), r#"Order{id:255,total:19.90,"x-y":1e5}"#);
//! ```
//!
//! Every haus value has a canonical form, so for a parsed value these never
//! fail. A [`Value`] built in code may not be a haus value: a number that
//! isn't a number literal (`"01"`, `"NaN"`: `invalid-number`), a tag that
//! isn't a tag (`invalid-tag`) or a record with a repeated key
//! (`duplicate-key`) has no canonical form, and fails with the writer's
//! error ([`crate::to_string`]), saying where. A number literal that isn't
//! normalized (`"1E+05"`, `"0xFF"`) is normalized as the parser would (`1e5`,
//! `255`), so the value hashes as the one parsed from it. The canonical form
//! has no limits: an integer of any size is written with all its digits.
//!
//! They need no work budget (spec §9.8): a [`Value`] owns its parts, so it
//! can't share them (a DAG) or contain itself, and its canonical form is
//! linear in the memory it takes, whether it was parsed or built in code. A
//! native value whose parts are shared (`Rc`) expands when it is encoded,
//! which the encoder's step budget bounds. Writing takes a stack rather than
//! recursion, so a value built in code may nest any depth.

use crate::ser::{is_tag, key, literal, quote, unique_keys};
use crate::{EncodeError, Segment, Value};
use std::cmp::Ordering;
use std::fmt::Write;

/// The canonical form of a value (spec §12), or the writer's error for a
/// [`Value`] built in code that isn't a haus value (see the module).
///
/// ```
/// use haus::{ErrorCode, Value};
/// assert_eq!(haus::canonical(&Value::Number("1E+05".into())).unwrap(), "1e5");
/// let e = haus::canonical(&Value::Array(vec![Value::Number("01".into())])).unwrap_err();
/// assert_eq!((e.code, e.place()), (ErrorCode::InvalidNumber, "$[0]".to_owned()));
/// ```
pub fn canonical(value: &Value) -> Result<String, EncodeError> {
    let mut out = String::new();
    write(value, &mut out).map_err(|(mut e, at)| {
        let mut path = path_to(value, at);
        path.append(&mut e.path);
        e.path = path;
        e
    })?;
    Ok(out)
}

/// Whether two values are equal (spec §2): the same canonical form. A
/// [`Value`] built in code that has no canonical form (see [`canonical`]) is
/// a value of no haus kind, equal to nothing, not even itself (as a float
/// NaN). `==` compares values as built, without normalizing.
pub fn equals(a: &Value, b: &Value) -> bool {
    matches!((canonical(a), canonical(b)), (Ok(x), Ok(y)) if x == y)
}

/// Orders values by the bytes of their canonical forms (spec §12): a total
/// order consistent with [`equals`], for sorting and ordered maps. Not
/// numeric order: `10` sorts before `9`. Fails as [`canonical`] does, with
/// the error of `a` first.
///
/// ```
/// let mut vs: Vec<haus::Value> = ["9", "10", "\"a\"", "[]"].iter().map(|s| haus::from_str(s).unwrap()).collect();
/// // Parsed values always have a canonical form.
/// vs.sort_by(|a, b| haus::compare(a, b).unwrap());
/// let forms: Result<Vec<_>, _> = vs.iter().map(haus::canonical).collect();
/// assert_eq!(forms.unwrap(), ["\"a\"", "10", "9", "[]"]);
/// ```
pub fn compare(a: &Value, b: &Value) -> Result<Ordering, EncodeError> {
    Ok(canonical(a)?.cmp(&canonical(b)?))
}

/// The SHA-256 digest of the canonical form, as 64 lowercase hex digits
/// (spec §12). Fails as [`canonical`] does. Needs the `hash` feature.
#[cfg(feature = "hash")]
pub fn hash(value: &Value) -> Result<String, EncodeError> {
    use sha2::{Digest, Sha256};
    Ok(hex(&Sha256::digest(canonical(value)?.as_bytes())))
}

/// The hash of a list of values, such as a whole file (spec §12): the
/// SHA-256 digest of their canonical forms joined by `,`. A list of one value
/// hashes like the value. The items of a stream are hashed one by one with
/// [`hash`]. Fails as [`canonical`] does, saying which value: `[3].total: …`.
/// Needs the `hash` feature.
///
/// ```
/// let vs = haus::parse("1, \"a\",").unwrap();
/// assert_eq!(haus::hash_all(&vs[..1]).unwrap(), haus::hash(&vs[0]).unwrap());
/// ```
#[cfg(feature = "hash")]
pub fn hash_all<'a>(values: impl IntoIterator<Item = &'a Value>) -> Result<String, EncodeError> {
    use sha2::{Digest, Sha256};
    let mut sha = Sha256::new();
    for (i, v) in values.into_iter().enumerate() {
        if i > 0 {
            sha.update(b",");
        }
        sha.update(canonical(v).map_err(|e| e.within(Segment::Index(i)))?.as_bytes());
    }
    Ok(hex(&sha.finalize()))
}

#[cfg(feature = "hash")]
fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::with_capacity(64), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}

/// An error, and the value it is about (its path from there is in the error).
type Failed<'a> = (EncodeError, &'a Value);

/// `v`'s canonical form, appended to `out`. A stack rather than recursion,
/// so that a value built in code, which may nest deeper than any limit,
/// takes no call stack per level. An error names the value it is about,
/// whose path [`path_to`] finds only then, so writing keeps no path.
fn write<'a>(v: &'a Value, out: &mut String) -> Result<(), Failed<'a>> {
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
    /// is the order of code points (spec §12). A repeated key is next to its
    /// twin once sorted; the error names the key the writer names.
    fn record<'a>(
        at: &'a Value,
        fields: &'a [(String, Value)],
        out: &mut String,
        todo: &mut Vec<Next<'a>>,
    ) -> Result<(), Failed<'a>> {
        let mut sorted: Vec<&(String, Value)> = fields.iter().collect();
        sorted.sort_by(|a, b| a.0.cmp(&b.0));
        if sorted.windows(2).any(|w| w[0].0 == w[1].0) {
            unique_keys(fields).map_err(|e| (e, at))?;
        }
        out.push('{');
        todo.push(Next::Text('}'));
        for (i, (k, v)) in sorted.into_iter().enumerate().rev() {
            todo.push(Next::Value(v));
            todo.push(Next::Key(k));
            if i > 0 {
                todo.push(Next::Text(','));
            }
        }
        Ok(())
    }
    let mut todo = vec![Next::Value(v)];
    while let Some(next) = todo.pop() {
        match next {
            Next::Text(c) => out.push(c),
            Next::Key(k) => {
                key(k, out);
                out.push(':');
            }
            Next::Value(at @ Value::Number(n)) => out.push_str(&literal(n).map_err(|e| (e, at))?),
            Next::Value(Value::String(s)) => quote(s, out),
            Next::Value(Value::Bytes(b)) => {
                out.push_str("x\"");
                for x in b {
                    let _ = write!(out, "{x:02x}");
                }
                out.push('"');
            }
            Next::Value(Value::Array(items)) => list('[', items, ']', out, &mut todo),
            Next::Value(at @ Value::Record(fields)) => record(at, fields, out, &mut todo)?,
            Next::Value(at @ Value::Variant { tag, args }) => {
                if !is_tag(tag) {
                    return Err((invalid_tag(), at));
                }
                out.push_str(tag);
                match args.as_slice() {
                    [] => {}
                    [payload @ Value::Record(fields)] => record(payload, fields, out, &mut todo)?,
                    _ => list('(', args, ')', out, &mut todo),
                }
            }
        }
    }
    Ok(())
}

/// The writer's error for a tag that isn't a tag name.
fn invalid_tag() -> EncodeError {
    EncodeError::new(crate::ErrorCode::InvalidTag, "not a tag name: A to Z, then letters, digits and _")
}

/// The path from `root` to `target`, one of its parts, as the writer gives
/// it: `.key`, `[i]`, and `(Tag)` before a payload. Without recursion; only
/// for an error.
fn path_to(root: &Value, target: &Value) -> Vec<Segment> {
    /// Part `i` of `v`, and the segments that lead to it.
    fn part(v: &Value, i: usize) -> Option<(Vec<Segment>, &Value)> {
        match v {
            Value::Array(items) => items.get(i).map(|x| (vec![Segment::Index(i)], x)),
            Value::Record(fields) => fields.get(i).map(|(k, x)| (vec![Segment::Field(k.clone())], x)),
            Value::Variant { tag, args } => match args.as_slice() {
                [payload @ Value::Record(_)] => (i == 0).then(|| (vec![Segment::Tag(tag.clone())], payload)),
                _ => args.get(i).map(|x| (vec![Segment::Tag(tag.clone()), Segment::Index(i)], x)),
            },
            _ => None,
        }
    }
    let mut path = Vec::new();
    // The containers being searched: each, the part to look at next, and the
    // length of the path to it.
    let mut stack = vec![(root, 0, 0)];
    while let Some((v, i, _)) = stack.last_mut() {
        let (v, at) = (*v, *i);
        *i += 1;
        if std::ptr::eq(v, target) {
            return path;
        }
        match part(v, at) {
            Some((segments, x)) => {
                let length = path.len();
                path.extend(segments);
                stack.push((x, 0, length));
            }
            None => {
                let (_, _, length) = stack.pop().expect("a container is open");
                path.truncate(length);
            }
        }
    }
    path
}
