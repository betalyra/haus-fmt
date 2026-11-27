//! The limits of values built in code (spec §7 "Size", §11 "Values built in
//! code", §12): checked when a value is built, never when it is used. A
//! `Value` owns its parts, so it can't share them and expand when written:
//! Rust needs no count of its size, and the writers, the canonical form and
//! hashing apply no limit. Encoding objects of the program, which can
//! share parts (an `Rc`), counts them (tests/encode.rs).

use haus::json;
use haus::{EncodeError, Encoder, ErrorCode, Limits, Tag, Value};

/// The code and place of an error.
fn code(e: EncodeError) -> (ErrorCode, String) {
    (e.code, e.place())
}

/// `[[1, 2], T { a: 3 }]`: 7 values, the record payload of `T` one of them.
fn seven() -> Value {
    let inner = Value::array(vec![Value::from(1), Value::from(2)]).unwrap();
    let payload = Value::record([("a", Value::from(3))]).unwrap();
    Value::array(vec![inner, Value::variant("T", vec![payload]).unwrap()]).unwrap()
}

#[test]
fn a_value_has_a_size_and_writers_count_nothing() {
    let v = seven();
    assert_eq!(v.size(), 7);
    // Written whatever node limit the program sets for encoders.
    let one = Encoder::new(&Limits { max_nodes: 1, ..Limits::default() });
    assert_eq!(haus::to_string_with(&v, one).unwrap(), "[[1, 2], T { a: 3 }]");
    assert_eq!(haus::canonical(&v), "[[1,2],T{a:3}]");
    assert!(haus::equals(&v, &v.clone()));
    // As an `Any` inside an encoded object, it counts its size.
    assert_eq!(code(json::to_string_with(&vec![v.clone()], one).unwrap_err()), (ErrorCode::TooManyNodes, "$".into()));
}

#[test]
fn a_stream_says_which_value_an_error_is_in() {
    let few = Encoder::new(&Limits { max_string_length: 1, ..Limits::default() });
    let mut out = Vec::new();
    let e = haus::stream::encode_with(&mut out, [vec!["a".to_owned()], vec!["ab".to_owned()]], few).unwrap_err();
    let haus::Error::Encode(e) = e else { panic!("{e}") };
    assert_eq!(code(e), (ErrorCode::StringTooLong, "$[1][0]".to_owned()));
    assert_eq!(String::from_utf8(out).unwrap(), "[\"a\"],\n");
}

#[test]
fn the_default_node_limit_is_64_mi() {
    assert_eq!(Limits::default().max_nodes, 67_108_864);
}

/// Constructors apply the default limits of spec §7, each with its code.
#[test]
fn constructors_apply_the_default_limits() {
    let huge = format!("{}.5e-{}", "9".repeat(5000), "9".repeat(30));
    assert_eq!(Value::number(&huge).unwrap_err().code, ErrorCode::NumberTooLong);
    assert_eq!(Value::number(&format!("0x{}", "f".repeat(2000))).unwrap_err().code, ErrorCode::NumberTooLong);
    assert_eq!(Value::number("1e9999").unwrap_err().code, ErrorCode::ExponentTooLarge);
    let long = "k".repeat(20_000_000);
    assert_eq!(Tag::new(&format!("T{long}")).unwrap_err().code, ErrorCode::TagTooLong);
    assert_eq!(Value::record([(long.as_str(), Value::from(1))]).unwrap_err().code, ErrorCode::KeyTooLong);
    assert_eq!(Value::string(long).unwrap_err().code, ErrorCode::StringTooLong);
    // A value parsed with larger limits has them, and its canonical form has no limit.
    let raised = Limits { max_number_length: 6000, max_exponent: u64::MAX, ..Limits::default() };
    assert_eq!(haus::canonical(&haus::parse_one_with(&huge, &raised).unwrap()), huge);
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
