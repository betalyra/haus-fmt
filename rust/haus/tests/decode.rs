//! Decoding with a depth limit (spec §9.8): decoding checks the depth before
//! each container and fails at the limit with `nesting-too-deep` instead of
//! recursing on, also inside an `Any`. A [`Json`] built in code can nest
//! far deeper than any parser allows; it drops without recursion.

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

type Built = Result<Value, haus::ValueError>;

/// `n` levels of `wrap` around an empty array.
fn deep(n: usize, wrap: impl Fn(Value) -> Built) -> Value {
    (0..n).fold(Value::array(vec![]).unwrap(), |v, _| wrap(v).unwrap())
}

fn array(v: Value) -> Built {
    Value::array(vec![v])
}

fn some(v: Value) -> Built {
    Value::variant("Some", vec![v])
}

fn record(v: Value) -> Built {
    Value::record([("a", v)])
}

fn tagged_record(v: Value) -> Built {
    Value::variant("A", vec![record(v)?])
}

/// A decoder whose depth limit is `n`.
fn at_most(n: usize) -> Decoder {
    Decoder::new(&Limits { max_depth: n, ..Limits::default() })
}

#[test]
fn a_value_deeper_than_the_decoders_limit_fails_at_the_limit() {
    // The deepest value there is, decoded with a lower limit: decoding stops at it.
    let v = deep(255, array);
    let deeper = |path: &str| format!("{path}: nesting deeper than 100 levels");
    let low = at_most(100);
    for e in [
        Value::decode_with(&v, low).unwrap_err(),
        Nest::decode_with(&v, low).unwrap_err(),
        <Vec<Value>>::decode_with(&v, low).unwrap_err(),
    ] {
        assert_eq!((e.code, e.to_string()), (ErrorCode::NestingTooDeep, deeper(&"[0]".repeat(100))));
    }
    // Through `Maybe`, as a raw value in a record, and the payload of an unknown tag.
    let chain = deep(255, some);
    assert_eq!(Chain::decode_with(&chain, low).unwrap_err().to_string(), deeper(&"(Some)[0]".repeat(100)));
    let e = Value::decode_with(&chain, low).unwrap_err();
    assert_eq!(e.to_string(), deeper(&"(Some)[0]".repeat(100)));
    let Value::Variant { tag, args } = &chain else { unreachable!() };
    let unknown = de::unknown(tag, args, low).unwrap_err();
    assert_eq!(unknown.to_string(), deeper(&"(Some)[0]".repeat(100)));
    let wrapped = Value::record([("raw", deep(200, array))]).unwrap();
    let e = <std::collections::BTreeMap<String, Value>>::decode_with(&wrapped, low).unwrap_err();
    assert_eq!(e.to_string(), deeper(&format!(".raw{}", "[0]".repeat(99))));
}

#[test]
fn decoding_counts_levels_as_the_parser_does() {
    for wrap in [array, some, record, tagged_record] {
        // 256 levels around `[]`: the array itself is the 257th, refused where it is built.
        let at_limit = deep(255, wrap);
        assert!(haus::parse(&haus::ser::write(&at_limit)).is_ok());
        assert_eq!(Value::decode(&at_limit).unwrap(), at_limit);
        assert_eq!(wrap(at_limit.clone()).unwrap_err().code, ErrorCode::NestingTooDeep);
        let e = Value::decode_with(&at_limit, at_most(255)).unwrap_err();
        assert_eq!(e.code, ErrorCode::NestingTooDeep, "{e}");
    }
    // A configured limit, here 3: `[[[]]]` is fine, `[[[[]]]]` isn't.
    let small = at_most(3);
    assert_eq!(Nest::decode_with(&deep(2, array), small).unwrap().0.len(), 1);
    let none = Value::variant("None", vec![]).unwrap();
    assert!(Chain::decode_with(&some(none).unwrap(), small).unwrap().0.is_some_and(|inner| inner.0.is_none()));
    let e = Nest::decode_with(&deep(3, array), small).unwrap_err();
    assert_eq!(e.to_string(), "[0][0][0]: nesting deeper than 3 levels");
    let e = Value::decode_with(&deep(3, tagged_record), small).unwrap_err();
    assert_eq!(e.to_string(), "(A).a(A).a(A).a: nesting deeper than 3 levels");
    // A tag's arguments are a level: `Some(…)` at the limit isn't, `None` is.
    let at_zero = at_most(0);
    assert!(Option::<u8>::decode_with(&Value::variant("None", vec![]).unwrap(), at_zero).is_ok());
    let e = Option::<u8>::decode_with(&some(Value::from(1)).unwrap(), at_zero).unwrap_err();
    assert_eq!(e.code, ErrorCode::NestingTooDeep);
    let date = Value::variant("Date", vec![Value::string("2026-11-18").unwrap()]).unwrap();
    assert_eq!(haus::time::Date::decode_with(&date, at_zero).unwrap_err().code, ErrorCode::NestingTooDeep);
    let u = Unknown { tag: "X".parse().unwrap(), args: vec![Value::from(1)] };
    assert!(de::unknown(&u.tag, &u.args, at_zero).is_err() && de::unknown("X", &[], at_zero).is_ok());
}

#[test]
fn json_built_a_million_levels_deep_fails_at_the_depth_limit() {
    let j = (0..1_000_000).fold(Json::Array(vec![]), |j, _| Json::Array(vec![j]));
    let e = Nest::from_json_with(&j, Decoder::default()).unwrap_err();
    assert_eq!(e.to_string(), format!("{}: nesting deeper than 256 levels", "[0]".repeat(256)));
    assert!(json::import(&j, &Limits::default()).is_err());
}
