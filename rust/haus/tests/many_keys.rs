//! Duplicate keys can't make parsing quadratic (spec §7): every check uses
//! `HashSet`/`HashMap` with the standard library's `RandomState` (SipHash
//! with keys random per process), so keys can't be crafted to collide. A
//! record or object with many keys parses well within a bound that a list
//! scan or a hash with a known seed would miss by orders of magnitude.

use haus::{ErrorCode, Value};
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
    // Writing checks a record built in code for repeated keys the same way.
    let fields: Vec<(String, Value)> = (0..N).map(|i| (format!("k{i}"), Value::Number(i.to_string()))).collect();
    let written = timed("writing", || haus::to_string(&Value::Record(fields.clone()))).unwrap();
    assert!(written.len() > N);
    let mut repeated = fields;
    repeated.push(("k7".into(), Value::Number("0".into())));
    let e = timed("writing a repeated key", || haus::to_string(&Value::Record(repeated))).unwrap_err();
    assert_eq!(e.code, ErrorCode::DuplicateKey);
}
