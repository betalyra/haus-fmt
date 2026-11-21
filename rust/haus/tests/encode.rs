//! Encoding native values (spec §9.8, §15): the depth is checked while the
//! value is traversed, so a value nested far deeper than the limit fails
//! with the writer's error instead of overflowing the stack, and an error
//! inside a `Secret` is reported at the secret, without anything inside it.
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

#[test]
fn very_deep_values_built_in_code_have_a_canonical_form() {
    // The canonical form takes no call stack per level: it has no limit (spec §12).
    let deep = (0..1_000_000).fold(Value::Array(vec![]), |v, _| Value::Array(vec![v]));
    let text = haus::canonical(&deep);
    assert_eq!(text.len(), 2 * 1_000_001);
    assert!(text.starts_with("[[[") && text.ends_with("]]]"));
    assert!(haus::equals(&deep, &deep));
    // Encoding it stops at the limit, as the writer does.
    assert!(haus::to_string(&deep).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
    assert!(haus::to_haus_json(&deep).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
    assert!(json::to_string(&deep).unwrap_err().to_string().ends_with("nesting deeper than 256 levels"));
}

/// A [`Value`] built in code a million levels deep, of every kind of container.
fn very_deep(bottom: &str) -> Value {
    (0..1_000_000).fold(Value::number(bottom).unwrap(), |v, i| match i % 3 {
        0 => Value::Array(vec![Value::Bytes(vec![1]), v]),
        1 => Value::record([("a", v), ("b", Value::String("x".into()))]).unwrap(),
        _ => Value::variant("Some", vec![v]).unwrap(),
    })
}

#[test]
fn very_deep_values_built_in_code_drop_clone_and_compare_without_recursion() {
    // A thread of its own, with the default stack (2 MiB): far too small to
    // take a million levels by recursion.
    std::thread::spawn(|| {
        let deep = very_deep("1");
        let copy = deep.clone();
        assert!(copy == deep);
        assert!(very_deep("2") != deep, "a difference at the bottom");
        assert!(haus::equals(&copy, &deep));
        drop(copy);
        drop(deep);
    })
    .join()
    .expect("no stack overflow");
}

/// A record with a key that names the secret, and a value the writer rejects.
fn leaky(bad: Value) -> Value {
    Value::record([("hunter2", bad)]).unwrap()
}

#[test]
fn errors_inside_a_secret_name_only_the_secret() {
    let hidden = "not a valid Secret (the value is hidden)";
    let bad_values = [
        leaky(Value::number("1e6145").unwrap()),
        leaky(Value::number(&"1".repeat(1001)).unwrap()),
        leaky(Value::String("x".repeat(16 * 1024 * 1024 + 1))),
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

#[test]
fn shared_parts_expand_only_within_the_step_budget() {
    // 2^41 − 1 values written out, from 41 in memory: the encoders stop at
    // the budget (spec §9.8), one step per value made.
    let dag = Dag::new(40);
    let budget = |max: u64| Encoder::default().with_max_steps(max);
    let reason = "encode budget of 100000 steps exceeded (a value whose parts are shared expands when written)";
    let e = dag.encode_with(budget(100_000)).unwrap_err();
    assert_eq!((e.code, e.reason.as_str()), (ErrorCode::StepBudget, reason));
    assert!(e.to_string().starts_with("[0][0][0]") && e.to_string().ends_with(reason), "{e}");
    let e = dag.to_json_with(budget(100_000)).unwrap_err();
    assert_eq!((e.code, e.reason.as_str()), (ErrorCode::StepBudget, reason));
    assert_eq!(Encoder::default().max_steps(), ser::DEFAULT_MAX_STEPS);
    assert_eq!(ser::DEFAULT_MAX_STEPS, 16 * 1024 * 1024);

    // Exactly as many steps as values: 2^4 − 1 for three levels.
    assert_eq!(dag_text(3).matches('[').count(), 15);
    assert!(Dag::new(3).encode_with(budget(15)).is_ok() && Dag::new(3).to_json_with(budget(15)).is_ok());
    assert_eq!(Dag::new(3).encode_with(budget(14)).unwrap_err().code, ErrorCode::StepBudget);
    assert_eq!(Dag::new(3).to_json_with(budget(14)).unwrap_err().code, ErrorCode::StepBudget);
    // Leaves and raw values count too: an array of nine numbers is ten values.
    assert!(vec![1u8; 9].encode_with(budget(10)).is_ok() && vec![1u8; 9].to_json_with(budget(10)).is_ok());
    assert!(vec![1u8; 10].encode_with(budget(10)).is_err() && vec![1u8; 10].to_json_with(budget(10)).is_err());
    let raw = Value::Array(vec![Value::from(1); 9]);
    assert!(raw.encode_with(budget(10)).is_ok() && raw.to_json_with(budget(10)).is_ok());
    assert_eq!(raw.encode_with(budget(9)).unwrap_err().code, ErrorCode::StepBudget);
    assert_eq!(raw.to_json_with(budget(9)).unwrap_err().code, ErrorCode::StepBudget);
    // Each encoding has its own budget.
    for _ in 0..3 {
        assert!(Dag::new(3).encode_with(budget(15)).is_ok());
    }
}

/// The compact text of [`Dag::new`]`(levels)`.
fn dag_text(levels: usize) -> String {
    haus::to_string(&Dag::new(levels)).unwrap()
}
