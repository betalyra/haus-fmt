//! Decoding values built in code (spec §9.8): a [`Value`] or [`Json`] can be
//! nested far deeper than any parser allows, so decoding checks the depth
//! before each container and fails at the limit with `nesting-too-deep`
//! instead of overflowing the stack, also inside an `Any`.
//!
//! A [`Value`] drops without recursion; Rust drops a deeply nested [`Json`]
//! recursively, so these tests take deep JSON apart in a loop
//! ([`dismantle_json`]) rather than dropping it.

use haus::json::{self, Json};
use haus::{Decode, DecodeError, Decoder, ErrorCode, FromJson, Limits, Unknown, Value, de};

/// A native recursive type: an array of itself.
#[derive(Debug)]
struct Nest(Vec<Nest>);

impl Decode for Nest {
    fn decode_with(v: &Value, d: Decoder) -> Result<Nest, DecodeError> {
        de::array(v, d, Nest::decode_with).map(Nest)
    }
}

impl FromJson for Nest {
    fn from_json_with(j: &Json, d: Decoder) -> Result<Nest, DecodeError> {
        json::de::array(j, d, Nest::from_json_with).map(Nest)
    }
}

/// A native recursive type through `Maybe`: `Some(Some(…))`.
#[derive(Debug)]
struct Chain(Option<Box<Chain>>);

impl Decode for Chain {
    fn decode_with(v: &Value, d: Decoder) -> Result<Chain, DecodeError> {
        de::maybe(v, d, |x, d| Chain::decode_with(x, d).map(Box::new)).map(Chain)
    }
}

/// `n` levels of `wrap` around an empty array.
fn deep(n: usize, wrap: impl Fn(Value) -> Value) -> Value {
    (0..n).fold(Value::Array(vec![]), |v, _| wrap(v))
}

fn array(v: Value) -> Value {
    Value::Array(vec![v])
}

fn some(v: Value) -> Value {
    Value::Variant { tag: "Some".into(), args: vec![v] }
}

fn record(v: Value) -> Value {
    Value::Record(vec![("a".into(), v)])
}

/// `A { a: … }`: a record payload, one level (spec §7).
fn tagged_record(v: Value) -> Value {
    Value::Variant { tag: "A".into(), args: vec![record(v)] }
}

/// A [`Json`] dropped level by level, without recursion.
fn dismantle_json(mut j: Json) {
    while let Json::Array(mut items) = j {
        match items.pop() {
            Some(inner) => j = inner,
            None => break,
        }
    }
}

fn deeper(path: &str) -> String {
    format!("{path}: nesting deeper than 256 levels")
}

#[test]
fn a_value_built_a_million_levels_deep_fails_at_the_depth_limit() {
    // Far deeper than any call stack: decoding stops at the limit.
    let v = deep(1_000_000, array);
    let path = "[0]".repeat(256);
    for e in [Value::decode(&v).unwrap_err(), Nest::decode(&v).unwrap_err(), <Vec<Value>>::decode(&v).unwrap_err()] {
        assert_eq!((e.code, e.to_string()), (ErrorCode::NestingTooDeep, deeper(&path)));
    }
    // Through `Maybe`, as a raw value in a record, and the payload of an unknown tag.
    let chain = deep(1_000_000, some);
    assert_eq!(Chain::decode(&chain).unwrap_err().to_string(), deeper(&"(Some)[0]".repeat(256)));
    let e = Value::decode(&chain).unwrap_err();
    assert_eq!(e.to_string(), deeper(&"(Some)[0]".repeat(256)));
    let Value::Variant { tag, args } = &chain else { unreachable!() };
    let unknown = de::unknown(tag, args, Decoder::default()).unwrap_err();
    assert_eq!(unknown.to_string(), deeper(&"(Some)[0]".repeat(256)));
    let wrapped = Value::Record(vec![("raw".into(), v)]);
    let e = <std::collections::BTreeMap<String, Value>>::decode(&wrapped).unwrap_err();
    assert_eq!(e.to_string(), deeper(&format!(".raw{}", "[0]".repeat(255))));
}

#[test]
fn decoding_counts_levels_as_the_parser_does() {
    for wrap in [array, some, record, tagged_record] {
        // 256 levels around `[]`: the array itself is the 257th.
        let at_limit = deep(255, wrap);
        let text = haus::to_string(&at_limit).unwrap();
        assert!(haus::parse(&text).is_ok());
        assert_eq!(Value::decode(&at_limit).unwrap(), at_limit);
        let one_more = wrap(at_limit);
        assert!(haus::to_string(&one_more).is_err());
        let e = Value::decode(&one_more).unwrap_err();
        assert_eq!(e.code, ErrorCode::NestingTooDeep, "{e}");
    }
    // A configured limit, here 3: `[[[]]]` is fine, `[[[[]]]]` isn't.
    let small = Decoder::new(&Limits { max_depth: 3, ..Limits::default() });
    assert_eq!(Nest::decode_with(&deep(2, array), small).unwrap().0.len(), 1);
    let none = Value::Variant { tag: "None".into(), args: vec![] };
    assert!(Chain::decode_with(&some(none), small).unwrap().0.is_some_and(|inner| inner.0.is_none()));
    let e = Nest::decode_with(&deep(3, array), small).unwrap_err();
    assert_eq!(e.to_string(), "[0][0][0]: nesting deeper than 3 levels");
    let e = Value::decode_with(&deep(3, tagged_record), small).unwrap_err();
    assert_eq!(e.to_string(), "(A).a(A).a(A).a: nesting deeper than 3 levels");
    // A tag's arguments are a level: `Some(…)` at the limit isn't, `None` is.
    let at_zero = Decoder::new(&Limits { max_depth: 0, ..Limits::default() });
    assert!(Option::<u8>::decode_with(&Value::Variant { tag: "None".into(), args: vec![] }, at_zero).is_ok());
    let e = Option::<u8>::decode_with(&some(Value::Number("1".into())), at_zero).unwrap_err();
    assert_eq!(e.code, ErrorCode::NestingTooDeep);
    let date = Value::Variant { tag: "Date".into(), args: vec![Value::String("2026-11-18".into())] };
    assert_eq!(haus::time::Date::decode_with(&date, at_zero).unwrap_err().code, ErrorCode::NestingTooDeep);
    let u = Unknown { tag: "X".into(), args: vec![Value::Number("1".into())] };
    assert!(de::unknown(&u.tag, &u.args, at_zero).is_err() && de::unknown("X", &[], at_zero).is_ok());
}

#[test]
fn json_built_a_million_levels_deep_fails_at_the_depth_limit() {
    let j = (0..1_000_000).fold(Json::Array(vec![]), |j, _| Json::Array(vec![j]));
    let e = Nest::from_json_with(&j, Decoder::default()).unwrap_err();
    assert_eq!(e.to_string(), deeper(&"[0]".repeat(256)));
    assert!(json::import(&j, &Limits::default()).is_err());
    dismantle_json(j);
}
