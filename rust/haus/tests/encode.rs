//! Encoding native values (spec §9.8, §15): the depth is checked while the
//! value is traversed, so a value nested far deeper than the limit fails
//! with the writer's error instead of overflowing the stack, and an error
//! inside a `Secret` is reported at the secret, without anything inside it.
//!
//! Rust drops a deeply nested value recursively, so these tests take deep
//! values apart in a loop ([`Nest::dismantle`], [`dismantle`]) rather than
//! dropping them.

use haus::json::{self, Json, ToJson};
use haus::{Encode, EncodeError, Encoder, Limits, Secret, Value, ser};
use std::collections::BTreeMap;

/// A native recursive type: an array of itself.
struct Nest(Vec<Nest>);

impl Nest {
    /// `depth` (at least 1) arrays, one inside the other.
    fn new(depth: usize) -> Nest {
        (1..depth).fold(Nest(vec![]), |inner, _| Nest(vec![inner]))
    }

    /// Dropped level by level, without recursion.
    fn dismantle(mut self) {
        while let Some(inner) = self.0.pop() {
            self = inner;
        }
    }
}

impl Encode for Nest {
    fn encode_with(&self, e: Encoder) -> Result<Value, EncodeError> {
        ser::array(&self.0, e, Nest::encode_with)
    }
}

impl ToJson for Nest {
    fn to_json_with(&self, e: Encoder) -> Result<Json, EncodeError> {
        json::ser::array(&self.0, e, Nest::to_json_with)
    }
}

/// A [`Value`] dropped level by level, without recursion.
fn dismantle(mut v: Value) {
    while let Value::Array(mut items) | Value::Variant { args: mut items, .. } = v {
        match items.pop() {
            Some(inner) => v = inner,
            None => break,
        }
    }
}

/// `n` levels of `[...]` as the error path.
fn path(n: usize) -> String {
    "[0]".repeat(n)
}

#[test]
fn native_values_at_the_depth_limit_are_written() {
    let nest = Nest::new(256);
    assert_eq!(haus::to_string(&nest).unwrap(), format!("{}{}", "[".repeat(256), "]".repeat(256)));
    assert_eq!(json::to_string(&nest).unwrap(), format!("{}{}", "[".repeat(256), "]".repeat(256)));
    nest.dismantle();

    let small = Limits { max_depth: 3, ..Limits::default() };
    assert_eq!(haus::to_string_with(&Nest::new(3), &small).unwrap(), "[[[]]]");
    assert_eq!(json::to_string_with(&Nest::new(3), &small).unwrap(), "[[[]]]");
}

#[test]
fn native_values_beyond_the_depth_limit_fail_at_the_limit() {
    let deeper = format!("{}: nesting deeper than 256 levels", path(256));
    let nest = Nest::new(257);
    assert_eq!(haus::to_string(&nest).unwrap_err().to_string(), deeper);
    assert_eq!(json::to_string(&nest).unwrap_err().to_string(), deeper);
    assert_eq!(nest.encode().unwrap_err().to_string(), deeper);
    nest.dismantle();

    let small = Limits { max_depth: 3, ..Limits::default() };
    let error = haus::to_string_with(&Nest::new(4), &small).unwrap_err();
    assert_eq!(error.to_string(), format!("{}: nesting deeper than 3 levels", path(3)));
    let error = json::to_string_with(&Nest::new(4), &small).unwrap_err();
    assert_eq!(error.to_string(), format!("{}: nesting deeper than 3 levels", path(3)));

    // `Some` and payloads are levels too, as the writer counts them.
    let options = (0..256).fold(Value::Number("1".into()), |v, _| Value::Variant { tag: "Some".into(), args: vec![v] });
    assert!(haus::to_string(&options).is_ok());
    let one_more = Some(options.clone());
    assert!(haus::to_string(&one_more).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
    assert!(json::to_string(&one_more).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
    dismantle(options);
    if let Some(v) = one_more {
        dismantle(v);
    }
}

#[test]
fn very_deep_native_values_fail_without_overflowing_the_stack() {
    // Far deeper than any call stack: the encoder stops at the limit.
    let nest = Nest::new(1_000_000);
    let deeper = format!("{}: nesting deeper than 256 levels", path(256));
    assert_eq!(haus::to_string(&nest).unwrap_err().to_string(), deeper);
    assert_eq!(json::to_string(&nest).unwrap_err().to_string(), deeper);
    let mut out = Vec::new();
    assert!(haus::stream::encode(&mut out, [&nest]).is_err());
    nest.dismantle();
}

#[test]
fn very_deep_values_built_in_code_have_a_canonical_form() {
    // The canonical form takes no call stack per level: it has no limit (spec §12).
    let deep = (0..1_000_000).fold(Value::Array(vec![]), |v, _| Value::Array(vec![v]));
    let text = haus::canonical(&deep).unwrap();
    assert_eq!(text.len(), 2 * 1_000_001);
    assert!(text.starts_with("[[[") && text.ends_with("]]]"));
    assert!(haus::equals(&deep, &deep));
    // Encoding it stops at the limit, as the writer does.
    assert!(haus::to_string(&deep).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
    assert!(haus::to_haus_json(&deep).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
    assert!(json::to_string(&deep).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
    dismantle(deep);
}

/// A record with a key that names the secret, and a value the writer rejects.
fn leaky(bad: Value) -> Value {
    Value::Record(vec![("hunter2".into(), bad)])
}

#[test]
fn errors_inside_a_secret_name_only_the_secret() {
    let hidden = "not a valid Secret (the value is hidden)";
    let bad_values = [
        leaky(Value::Number("abc".into())),
        leaky(Value::Number("1e6145".into())),
        leaky(Value::Variant { tag: "lower".into(), args: vec![] }),
        Value::Record(vec![("hunter2".into(), Value::Array(vec![])), ("hunter2".into(), Value::Array(vec![]))]),
        leaky((0..300).fold(Value::Array(vec![]), |v, _| Value::Array(vec![v]))),
    ];
    for bad in bad_values {
        let secret = Secret::new(bad);
        let in_a_record: BTreeMap<String, &Secret<Value>> = [("vault".to_owned(), &secret)].into();
        for e in [haus::to_string(&secret).unwrap_err(), json::to_string(&secret).unwrap_err()] {
            assert_eq!(e.to_string(), hidden);
        }
        for e in [haus::to_string(&in_a_record).unwrap_err(), json::to_string(&in_a_record).unwrap_err()] {
            assert_eq!(e.to_string(), format!(".vault: {hidden}"));
        }
        dismantle(secret.into_inner());
    }

    // Native values inside a secret, too: a map key in the path would reveal it.
    let small = Limits { max_string_length: 4, ..Limits::default() };
    let keys: Secret<BTreeMap<String, String>> = Secret::new([("hunter2".to_owned(), "abcde".to_owned())].into());
    let e = haus::to_string_with(&keys, &small).unwrap_err();
    assert_eq!(e.to_string(), hidden);
    assert!(e.path.is_empty());
    // Outside a secret, the error says where.
    let e = haus::to_string_with(keys.expose(), &small).unwrap_err();
    assert_eq!(e.to_string(), ".hunter2: key longer than 4 characters");
}
