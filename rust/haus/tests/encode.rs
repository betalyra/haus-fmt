//! Encoding native values (spec §9.8, §15): the depth is checked while the
//! value is traversed, so a value nested far deeper than the limit fails
//! with the encoder's error instead of overflowing the stack; a `Secret` is
//! refused unless the encoder reveals secrets, and an error inside a
//! revealed one is reported at the secret, without anything inside it.
//!
//! A [`Value`] drops without recursion; Rust drops a deeply nested native
//! value recursively, so these tests take one apart in a loop
//! ([`Nest::dismantle`]) rather than dropping it.

use haus::json::{self, Json, ToJson};
use haus::{Encode, EncodeError, Encoder, ErrorCode, Limits, Secret, Value, ser};
use std::collections::BTreeMap;
use std::rc::Rc;

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

/// A native value whose parts are shared (a DAG): each level holds the
/// level below twice, so `levels` levels are 2^(levels + 1) − 1 values when
/// written out.
struct Dag(Vec<Rc<Dag>>);

impl Dag {
    fn new(levels: usize) -> Dag {
        let below = (1..levels).fold(Rc::new(Dag(vec![])), |d, _| Rc::new(Dag(vec![d.clone(), d])));
        Dag(if levels == 0 { vec![] } else { vec![below.clone(), below] })
    }
}

impl Encode for Dag {
    fn encode_with(&self, e: Encoder) -> Result<Value, EncodeError> {
        ser::array(&self.0, e, |d, e| d.encode_with(e))
    }
}

impl ToJson for Dag {
    fn to_json_with(&self, e: Encoder) -> Result<Json, EncodeError> {
        json::ser::array(&self.0, e, |d, e| d.to_json_with(e))
    }
}

/// `n` levels of `[...]` as the error path.
fn path(n: usize) -> String {
    "[0]".repeat(n)
}

/// An encoder with the default limits, but `limits` changed.
fn with(limits: Limits) -> Encoder {
    Encoder::new(&limits)
}

#[test]
fn native_values_at_the_depth_limit_are_written() {
    let nest = Nest::new(256);
    assert_eq!(haus::to_string(&nest).unwrap(), format!("{}{}", "[".repeat(256), "]".repeat(256)));
    assert_eq!(json::to_string(&nest).unwrap(), format!("{}{}", "[".repeat(256), "]".repeat(256)));
    nest.dismantle();

    let small = Limits { max_depth: 3, ..Limits::default() };
    assert_eq!(haus::to_string_with(&Nest::new(3), with(small)).unwrap(), "[[[]]]");
    assert_eq!(json::to_string_with(&Nest::new(3), with(small)).unwrap(), "[[[]]]");
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
    let error = haus::to_string_with(&Nest::new(4), with(small)).unwrap_err();
    assert_eq!(error.to_string(), format!("{}: nesting deeper than 3 levels", path(3)));
    let error = json::to_string_with(&Nest::new(4), with(small)).unwrap_err();
    assert_eq!(error.to_string(), format!("{}: nesting deeper than 3 levels", path(3)));

    // `Some` and payloads are levels too, as the writer counts them: an
    // `Any` holding a value 256 levels deep fits at the top, not inside `Some`.
    let options = (0..256).fold(Value::from(1), |v, _| Value::variant("Some", vec![v]).unwrap());
    assert!(haus::to_string(&options).is_ok());
    let one_more = Some(options.clone());
    assert!(haus::to_string(&one_more).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
    assert!(json::to_string(&one_more).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
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

/// The deepest value there is, of every kind of container.
fn deepest(bottom: &str) -> Value {
    (0..256).fold(Value::number(bottom).unwrap(), |v, i| match i % 3 {
        0 => Value::array(vec![Value::bytes(vec![1]).unwrap(), v]).unwrap(),
        1 => Value::record([("a", v), ("b", Value::string("x").unwrap())]).unwrap(),
        _ => Value::variant("Some", vec![v]).unwrap(),
    })
}

#[test]
fn the_deepest_values_drop_clone_compare_and_write_without_recursion_trouble() {
    // A thread of its own, with the default stack (2 MiB; tests/limits.rs
    // runs every path in 512 KiB in an optimized build).
    std::thread::Builder::new()
        .spawn(|| {
            let deep = deepest("1");
            let copy = deep.clone();
            assert!(copy == deep);
            assert!(deepest("2") != deep, "a difference at the bottom");
            assert!(haus::equals(&copy, &deep));
            assert!(haus::parse_one(&ser::write(&deep)).is_ok());
            assert!(haus::from_haus_json(&haus::to_haus_json(&deep)).is_ok());
            // Encoding a value 256 levels deep as an `Any` inside anything else is one level too deep.
            let arrays = (0..256).fold(Value::from(1), |v, _| Value::array(vec![v]).unwrap());
            assert_eq!(haus::to_string(&vec![arrays]).unwrap_err().code, ErrorCode::NestingTooDeep);
            drop(copy);
            drop(deep);
        })
        .unwrap()
        .join()
        .expect("no stack overflow");
}

/// A record with a key that names the secret, and a value an encoder with
/// [`small`] limits rejects.
fn leaky(bad: Value) -> Value {
    Value::record([("hunter2", bad)]).unwrap()
}

/// Limits a few values exceed: 4 characters, 5 digits, 3 levels.
fn small() -> Limits {
    Limits { max_string_length: 4, max_number_length: 5, max_depth: 3, ..Limits::default() }
}

#[test]
fn secrets_are_refused_unless_revealed() {
    let refused = "a Secret is not written unless the encoder reveals secrets (Encoder::reveal_secrets)";
    let secret = Secret::new(Value::string("sk-123").unwrap());
    let in_a_record: BTreeMap<String, &Secret<Value>> = [("vault".to_owned(), &secret)].into();
    for e in [haus::to_string(&secret).unwrap_err(), json::to_string(&secret).unwrap_err()] {
        assert_eq!((e.code, e.to_string()), (ErrorCode::CannotEncode, refused.to_owned()));
    }
    for e in [haus::to_string(&in_a_record).unwrap_err(), json::to_string(&in_a_record).unwrap_err()] {
        assert_eq!((e.code, e.to_string()), (ErrorCode::CannotEncode, format!(".vault: {refused}")));
        assert!(!e.to_string().contains("sk-123"));
    }
    // Revealed, in full.
    let revealing = Encoder::default().reveal_secrets();
    assert_eq!(haus::to_string_with(&in_a_record, revealing).unwrap(), r#"{ vault: "sk-123" }"#);
    assert_eq!(json::to_string_with(&in_a_record, revealing).unwrap(), r#"{"vault":"sk-123"}"#);
}

/// A secret holding `bad`, which an encoder with [`small`] limits rejects:
/// the error says only that the secret isn't valid, at it.
fn hidden_inside<T: Encode + ToJson>(bad: T) {
    let hidden = "not a valid Secret (the value is hidden)";
    let revealing = Encoder::new(&small()).reveal_secrets();
    let secret = Secret::new(bad);
    let in_a_record: BTreeMap<String, &Secret<T>> = [("safe".to_owned(), &secret)].into();
    for e in
        [haus::to_string_with(&secret, revealing).unwrap_err(), json::to_string_with(&secret, revealing).unwrap_err()]
    {
        assert_eq!((e.code, e.to_string()), (ErrorCode::InvalidSecret, hidden.to_owned()));
    }
    for e in [
        haus::to_string_with(&in_a_record, revealing).unwrap_err(),
        json::to_string_with(&in_a_record, revealing).unwrap_err(),
    ] {
        assert_eq!(e.to_string(), format!(".safe: {hidden}"));
    }
}

#[test]
fn errors_inside_a_secret_name_only_the_secret() {
    let hidden = "not a valid Secret (the value is hidden)";
    let revealing = Encoder::new(&small()).reveal_secrets();
    hidden_inside(haus::Int::from(123456i64));
    hidden_inside("abcde".to_owned());
    // A raw value keeps the lengths it was built with; its depth counts where it is put.
    hidden_inside(leaky(Value::array(vec![Value::array(vec![Value::array(vec![]).unwrap()]).unwrap()]).unwrap()));

    // Native values inside a secret, too: a map key in the path would reveal it.
    let keys: Secret<BTreeMap<String, String>> = Secret::new([("hunter2".to_owned(), "abcde".to_owned())].into());
    let e = haus::to_string_with(&keys, revealing).unwrap_err();
    assert_eq!(e.to_string(), hidden);
    assert!(e.path.is_empty());
    // Outside a secret, the error says where.
    let e = haus::to_string_with(keys.expose(), revealing).unwrap_err();
    assert_eq!(e.to_string(), ".hunter2: key longer than 4 characters");
}

#[test]
fn shared_parts_expand_only_within_the_node_limit() {
    // 2^41 − 1 values written out, from 41 in memory: the encoders stop at
    // the node limit (spec §7, §9.8), one per value made, at `$`.
    let dag = Dag::new(40);
    let budget = |max: usize| Encoder::new(&Limits { max_nodes: max, ..Limits::default() });
    let reason = "more than 100000 values written for one value (a value whose parts are shared expands when written)";
    for e in [dag.encode_with(budget(100_000)).unwrap_err(), dag.to_json_with(budget(100_000)).unwrap_err()] {
        assert_eq!((e.code, e.reason.as_str(), e.place()), (ErrorCode::TooManyNodes, reason, "$".to_owned()));
    }
    assert_eq!(Limits::default().max_nodes, 64 * 1024 * 1024);

    // Exactly as many as values: 2^4 − 1 for three levels.
    assert_eq!(dag_text(3).matches('[').count(), 15);
    assert!(Dag::new(3).encode_with(budget(15)).is_ok() && Dag::new(3).to_json_with(budget(15)).is_ok());
    assert_eq!(Dag::new(3).encode_with(budget(14)).unwrap_err().code, ErrorCode::TooManyNodes);
    assert_eq!(Dag::new(3).to_json_with(budget(14)).unwrap_err().code, ErrorCode::TooManyNodes);
    // Leaves and raw values count too: an array of nine numbers is ten values.
    assert!(vec![1u8; 9].encode_with(budget(10)).is_ok() && vec![1u8; 9].to_json_with(budget(10)).is_ok());
    assert!(vec![1u8; 10].encode_with(budget(10)).is_err() && vec![1u8; 10].to_json_with(budget(10)).is_err());
    let raw = Value::array(vec![Value::from(1); 9]).unwrap();
    assert!(raw.encode_with(budget(10)).is_ok() && raw.to_json_with(budget(10)).is_ok());
    assert_eq!(raw.encode_with(budget(9)).unwrap_err().code, ErrorCode::TooManyNodes);
    assert_eq!(raw.to_json_with(budget(9)).unwrap_err().code, ErrorCode::TooManyNodes);
    // Each encoding has its own count.
    for _ in 0..3 {
        assert!(Dag::new(3).encode_with(budget(15)).is_ok());
    }
    // The encoders apply the limit set for them, each top-level value on its own.
    let fifteen = budget(15);
    for _ in 0..3 {
        assert!(haus::to_string_with(&Dag::new(3), fifteen).is_ok());
    }
    let e = haus::to_string_with(&Dag::new(4), fifteen).unwrap_err();
    assert_eq!((e.code, e.place()), (ErrorCode::TooManyNodes, "$".to_owned()));
    assert_eq!(json::to_string_with(&Dag::new(4), fifteen).unwrap_err().code, ErrorCode::TooManyNodes);
}

/// The compact text of [`Dag::new`]`(levels)`.
fn dag_text(levels: usize) -> String {
    haus::to_string(&Dag::new(levels)).unwrap()
}
