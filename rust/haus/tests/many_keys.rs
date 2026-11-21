//! Duplicate keys can't make parsing quadratic (spec §7): the checks use
//! `HashSet`/`HashMap` with the standard library's `RandomState` (SipHash
//! with keys random per process), so keys can't be crafted to collide; the
//! parser and the writers chain keys by a cheap hash first, and switch to
//! that one as soon as a chain grows long (`tests/linear.rs` times keys made
//! to collide in the cheap hash). A record or object with many keys parses
//! well within a bound that a list scan or a hash with a known seed would
//! miss by orders of magnitude.

use haus::{ErrorCode, Record, Value};
use std::time::{Duration, Instant};

const N: usize = 100_000;

/// Generous for a debug build on a slow CI machine; a quadratic check of
/// 100 000 keys takes about 5·10⁹ comparisons.
const BOUND: Duration = Duration::from_secs(10);

fn timed<T>(what: &str, f: impl FnOnce() -> T) -> T {
    let start = Instant::now();
    let out = f();
    assert!(start.elapsed() < BOUND, "{what} took {:?}", start.elapsed());
    out
}

/// `k0`, `k1`, …, written by `entry`, then `more`, joined by `,` in `open` … `close`.
fn many(open: &str, close: &str, more: &str, entry: impl Fn(usize) -> String) -> String {
    let entries: Vec<String> = (0..N).map(entry).collect();
    format!("{open}{}{more}{close}", entries.join(","))
}

#[test]
fn a_record_with_many_keys() {
    let text = many("{ ", " }", "", |i| format!("k{i}: {i}"));
    let values = timed("a record", || haus::parse(&text)).unwrap();
    assert!(matches!(&values[..], [Value::Record(fields)] if fields.len() == N));
    let repeated = many("{ ", " }", ", k99999: 0", |i| format!("k{i}: {i}"));
    let e = timed("a record with a repeated key", || haus::parse(&repeated)).unwrap_err();
    assert_eq!(e.code, ErrorCode::DuplicateKey);
}

#[test]
fn a_json_object_with_many_members() {
    let text = many("{", "}", "", |i| format!("\"k{i}\":{i}"));
    let json = timed("a JSON object", || haus::json::parse(&text)).unwrap();
    assert!(matches!(&json, haus::Json::Object(members) if members.len() == N));
    // The import (§16.1) and schema-based JSON (§16.3) read the same object.
    let imported = timed("the import", || haus::import_json(&text)).unwrap();
    assert!(matches!(&imported, Value::Record(fields) if fields.len() == N));
    let map = timed("a Map", || haus::json::from_str::<std::collections::BTreeMap<String, i32>>(&text)).unwrap();
    assert_eq!(map.len(), N);
    let repeated = many("{", "}", ",\"k5\":0", |i| format!("\"k{i}\":{i}"));
    let e = timed("a JSON object with a repeated name", || haus::json::parse(&repeated)).unwrap_err();
    assert_eq!(e.code, ErrorCode::DuplicateKey);
}

#[test]
fn self_describing_json_with_many_keys() {
    let record = many("{\"_rec\":{", "}}", "", |i| format!("\"k{i}\":{{\"_num\":\"{i}\"}}"));
    let text = format!("{{\"_haus\":1,\"_value\":{record}}}");
    let value = timed("self-describing JSON", || haus::from_haus_json(&text)).unwrap();
    assert!(matches!(&value, Value::Record(fields) if fields.len() == N));
    // A record built in code is checked for repeated keys the same way.
    let fields: Vec<(String, Value)> = (0..N).map(|i| (format!("k{i}"), Value::from(i))).collect();
    let record = timed("building", || Record::from_fields(fields.clone())).unwrap();
    let written = timed("writing", || haus::to_string(&Value::Record(record))).unwrap();
    assert!(written.len() > N);
    let mut repeated = fields;
    repeated.push(("k7".into(), Value::from(0)));
    let e = timed("building with a repeated key", || Record::from_fields(repeated)).unwrap_err();
    assert_eq!(e.code, ErrorCode::DuplicateKey);
    // One key at a time too.
    let mut one_by_one = Record::new();
    timed("inserting", || (0..N).try_for_each(|i| one_by_one.insert(format!("k{i}"), i))).unwrap();
    assert_eq!(one_by_one.insert("k7", 0).unwrap_err().code, ErrorCode::DuplicateKey);
}
