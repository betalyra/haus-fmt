//! The node limit and the writers' limits for values built in code (spec §7
//! "Values written", §11 "Values built in code", §12): constructors check
//! only that a value is valid; every writer checks every limit a value can
//! break. The canonical form and hashing apply none: a `Value` owns its
//! parts, so it can't share them and expand when written.

use haus::json;
use haus::{EncodeError, ErrorCode, Limits, Tag, Value};

fn nodes(max: usize) -> Limits {
    Limits { max_nodes: max, ..Limits::default() }
}

/// The code and place of an error.
fn code(e: EncodeError) -> (ErrorCode, String) {
    (e.code, e.place())
}

/// `[[1, 2], T { a: 3 }]`: 7 values, the record payload of `T` one of them.
fn seven() -> Value {
    let inner = Value::from(vec![Value::from(1), Value::from(2)]);
    let payload = Value::record([("a", Value::from(3))]).unwrap();
    Value::from(vec![inner, Value::variant("T", vec![payload]).unwrap()])
}

/// Every writer of one value built in code, with `limits`: compact,
/// minimised, self-describing JSON, and `Any`'s schema-based JSON.
fn writers(v: &Value, limits: &Limits) -> Vec<Result<String, EncodeError>> {
    vec![
        haus::to_string_with(v, limits),
        haus::to_string_minimised_with(v, limits),
        json::to_haus_json_with(v, limits),
        json::to_string_with(v, limits),
    ]
}

/// `values` written as a stream with `limits`.
fn stream(values: &[&Value], limits: &Limits) -> Result<String, EncodeError> {
    let mut out = Vec::new();
    match haus::stream::encode_with(&mut out, values, limits) {
        Ok(()) => Ok(String::from_utf8(out).unwrap()),
        Err(haus::Error::Encode(e)) => Err(e),
        Err(other) => panic!("{other}"),
    }
}

#[test]
fn writers_count_every_value_written() {
    let v = seven();
    for e in writers(&v, &nodes(6)) {
        assert_eq!(code(e.unwrap_err()), (ErrorCode::TooManyNodes, "$".to_owned()));
    }
    assert!(writers(&v, &nodes(7)).into_iter().all(|w| w.is_ok()));
    // The canonical form, hashing and equality don't count: they can't fail.
    assert_eq!(haus::canonical(&v), "[[1,2],T{a:3}]");
    assert!(haus::equals(&v, &v.clone()));
}

#[test]
fn a_stream_counts_each_value_on_its_own_and_says_which() {
    let (v, one) = (seven(), Value::from(1));
    assert!(stream(&[&v, &v, &v], &nodes(7)).is_ok());
    // Value i of a stream or a file of several values: at `$[i]`.
    assert_eq!(code(stream(&[&one, &v], &nodes(6)).unwrap_err()), (ErrorCode::TooManyNodes, "$[1]".to_owned()));
    let big = Value::number("1e9999").unwrap();
    assert_eq!(code(haus::to_string_all(&[one.clone(), big]).unwrap_err()).1, "$[1]");
    let few = Limits { max_string_length: 1, ..Limits::default() };
    let long = Value::from(vec![Value::String("ab".into())]);
    assert_eq!(code(stream(&[&one, &long], &few).unwrap_err()), (ErrorCode::StringTooLong, "$[1][0]".to_owned()));
    assert_eq!(code(json::to_haus_json_lines(&[one.clone(), Value::number("1e9999").unwrap()]).unwrap_err()).1, "$[1]");
}

#[test]
fn the_default_node_limit_is_64_mi() {
    assert_eq!(Limits::default().max_nodes, 67_108_864);
    // A parsed value is within it: it has fewer values than its text has characters.
    let v = haus::parse("[1, [2, [3]]]").unwrap().remove(0);
    assert!(haus::to_string(&v).is_ok());
}

/// Values beyond one of the writers' limits, with the code each gets.
fn beyond_the_limits() -> Vec<(Value, ErrorCode)> {
    let long = "x".repeat(17);
    let deep = (0..5).fold(Value::Array(vec![]), |v, _| Value::Array(vec![v]));
    // A record payload is the payload's level: `A { b: B { c: [] } }` is 3 deep.
    let payloads = Value::variant(
        "A",
        vec![
            Value::record([(
                "b",
                Value::variant("B", vec![Value::record([("c", Value::Array(vec![]))]).unwrap()]).unwrap(),
            )])
            .unwrap(),
        ],
    )
    .unwrap();
    vec![
        (Value::String(long.clone()), ErrorCode::StringTooLong),
        (Value::Bytes(vec![0; 9]), ErrorCode::StringTooLong),
        (Value::record([(long.as_str(), Value::from(1))]).unwrap(), ErrorCode::KeyTooLong),
        (Value::from(Tag::new(&format!("T{long}")).unwrap()), ErrorCode::TagTooLong),
        (Value::variant(&format!("T{long}"), vec![Value::from(1)]).unwrap(), ErrorCode::TagTooLong),
        (Value::number(&"1".repeat(17)).unwrap(), ErrorCode::NumberTooLong),
        (Value::number("1e100").unwrap(), ErrorCode::ExponentTooLarge),
        (deep, ErrorCode::NestingTooDeep),
        (Value::from(vec![payloads]), ErrorCode::NestingTooDeep),
        (Value::from(vec![Value::from(1); 20]), ErrorCode::TooManyNodes),
    ]
}

#[test]
fn writers_check_every_limit_of_values_built_in_code() {
    let limits = Limits { max_depth: 3, max_number_length: 16, max_exponent: 99, max_string_length: 16, max_nodes: 20 };
    for (v, want) in beyond_the_limits() {
        for (i, written) in writers(&v, &limits).into_iter().enumerate() {
            assert_eq!(written.map_err(|e| e.code).err(), Some(want), "writer {i}: {v:?}");
        }
        assert_eq!(stream(&[&v], &limits).map_err(|e| e.code).err(), Some(want), "stream: {v:?}");
        // The canonical form applies none of them.
        assert!(!haus::canonical(&v).is_empty());
        // Within the default limits, each of them is written.
        if want != ErrorCode::NestingTooDeep {
            assert!(writers(&v, &Limits::default()).into_iter().all(|w| w.is_ok()), "{v:?}");
        }
    }
    // At the limits, every writer takes them.
    let at = Value::from(vec![
        Value::String("x".repeat(16)),
        Value::number("1e99").unwrap(),
        Value::number(&"1".repeat(16)).unwrap(),
        Value::variant("A", vec![Value::record([("k", Value::Array(vec![]))]).unwrap()]).unwrap(),
    ]);
    assert!(writers(&at, &limits).into_iter().all(|w| w.is_ok()));
}

/// Constructors check that a value is valid, never a limit (spec §11): a
/// number of any length or exponent, a string, key or tag of any length.
#[test]
fn constructors_apply_no_limits() {
    let huge = format!("{}.5e-{}", "9".repeat(5000), "9".repeat(30));
    assert_eq!(Value::number(&huge).unwrap().as_number().unwrap().as_str(), huge);
    let hex = format!("0x{}", "f".repeat(2000));
    assert!(Value::number(&hex).is_ok());
    let long = "k".repeat(20_000_000);
    assert!(Tag::new(&format!("T{long}")).is_ok());
    assert!(Value::record([(long.as_str(), Value::from(1))]).is_ok());
    // The writer is what rejects them.
    assert_eq!(haus::to_string(&Value::number(&huge).unwrap()).unwrap_err().code, ErrorCode::NumberTooLong);
    // Their canonical form has no limit.
    assert_eq!(haus::canonical(&Value::number(&huge).unwrap()), huge);
}

#[test]
fn equality_ignores_key_order_at_every_level() {
    let a = haus::parse(r#"{ a: [1, { x: 1, y: Some({ p: "q", r: x"00" }) }], b: T { c: 1, d: 2 } }"#).unwrap();
    let b = haus::parse(r#"{ b: T { d: 2, c: 1 }, a: [1, { y: Some({ r: x"00", p: "q" }), x: 1 }] }"#).unwrap();
    assert!(haus::equals(&a[0], &b[0]) && haus::equals(&b[0], &a[0]));
    for other in ["{ a: [1, { x: 1, y: Some({ p: \"q\", r: x\"01\" }) }], b: T { c: 1, d: 2 } }", "{ a: 1, c: 2 }"] {
        let c = haus::parse(other).unwrap();
        assert!(!haus::equals(&a[0], &c[0]), "{other}");
    }
    // `T { … }` and `T({ … })` are one value; `T { … }` and `T({ … }, 1)` aren't.
    let [x, y, z] = ["T { a: 1 }", "T({ a: 1 })", "T({ a: 1 }, 1)"].map(|t| haus::parse(t).unwrap().remove(0));
    assert!(haus::equals(&x, &y) && !haus::equals(&x, &z));
}
