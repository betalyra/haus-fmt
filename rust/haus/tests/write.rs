//! The compact writer checks what it writes (spec §9.8): every value the
//! parser gives is written again, under the same limits, and parses back.

use haus::{Limits, Value, parse_with, ser};

fn roundtrip(text: &str, limits: &Limits) {
    let [value] = parse_with(text, limits).unwrap_or_else(|e| panic!("{text}: {e}")).try_into().unwrap();
    let written = ser::write_with(&value, limits).unwrap_or_else(|e| panic!("{text}: {e}"));
    assert_eq!(parse_with(&written, limits).unwrap(), [value], "{text}");
}

#[test]
fn writes_every_parsed_value_again() {
    let limits = Limits::default();
    for depth in [1, 255, 256] {
        roundtrip(&format!("{}1{}", "[".repeat(depth), "]".repeat(depth)), &limits);
        roundtrip(&format!("{}{{}}{}", "A { a: ".repeat(depth - 1), " }".repeat(depth - 1)), &limits);
        roundtrip(&format!("{}N{}", "C(1, ".repeat(depth), ")".repeat(depth)), &limits);
    }
    for text in ["0x".to_owned() + &"f".repeat(829), "-0x".to_owned() + &"F".repeat(829), "1e6144".into(), "-0".into()]
    {
        roundtrip(&text, &limits);
    }
    let max = haus::MAX_SUPPORTED_DEPTH;
    let raised = Limits { max_number_length: 3000, max_exponent: 9000, max_depth: max, ..limits };
    for text in
        ["1".repeat(2500), "0x".to_owned() + &"f".repeat(2490), "1e9000".into(), "[".repeat(max) + &"]".repeat(max)]
    {
        roundtrip(&text, &raised);
    }
    let lowered = Limits { max_number_length: 20, max_string_length: 4, max_depth: 2, ..limits };
    for text in ["0xFFFFFFFFFFFFFFF", "\"abcd\"", "x\"0102\"", "[[1]]", "A { a: [1] }"] {
        roundtrip(text, &lowered);
    }
}

#[test]
fn values_beyond_the_limits_are_not_written() {
    let error = |v: &Value, limits: &Limits| ser::write_with(v, limits).unwrap_err().to_string();
    let small = Limits { max_string_length: 4, max_depth: 2, ..Limits::default() };
    assert_eq!(error(&Value::String("abcde".into()), &small), "string longer than 4 characters");
    assert_eq!(ser::write_with(&Value::String("äöüß".into()), &small).as_deref(), Ok("\"äöüß\""));
    assert_eq!(error(&Value::Bytes(vec![1, 2, 3]), &small), "byte string longer than 4 characters");
    let nested = Value::Array(vec![Value::Array(vec![Value::Array(vec![])])]);
    assert_eq!(error(&nested, &small), "[0][0]: nesting deeper than 2 levels");
    let key = Value::Record(vec![("abcde".into(), Value::Number("1".into()))]);
    assert_eq!(error(&key, &small), ".abcde: key longer than 4 characters");
    for n in ["", "-", "1.", ".5", "01", "1e", "+1", "0x", "1 ", "1 // c", "NaN", "1e5.5"] {
        assert_eq!(error(&Value::Number(n.into()), &Limits::default()), "not a number literal", "{n:?}");
    }
    for (n, written) in [
        ("1E+05", "1e5"),
        ("1e-0", "1e0"),
        ("-0x0", "-0"),
        ("-0b0", "-0"),
        ("0x0", "0"),
        ("0b101", "5"),
        ("-1_0.5_0", "-10.50"),
    ] {
        assert_eq!(ser::write(&Value::Number(n.into())).as_deref(), Ok(written), "{n:?}");
    }
}

#[test]
fn integers_longer_than_the_number_limit_are_not_written() {
    // Integers are written in decimal (spec §11): one longer than the limit written for can't be.
    let fits = Value::Number(format!("-{}", "9".repeat(999)));
    let long = Value::Number("9".repeat(1001));
    let too_long = "number literal longer than 1000 characters";
    let raised = Limits { max_number_length: 2000, ..Limits::default() };
    assert_eq!(ser::write(&fits), Ok(format!("-{}", "9".repeat(999))));
    assert_eq!(ser::write(&long).unwrap_err().to_string(), too_long);
    assert_eq!(ser::write_with(&long, &raised), Ok("9".repeat(1001)));
    let in_array = Value::Array(vec![Value::Number("1".into()), long.clone()]);
    let e = haus::to_string(&in_array).unwrap_err();
    assert_eq!((e.code.as_str(), e.place()), ("number-too-long", "$[1]".to_owned()));
    let mut out = Vec::new();
    let e = haus::stream::encode(&mut out, [fits.clone(), long.clone()]).unwrap_err();
    assert_eq!(e.to_string(), format!("[1]: {too_long}"));
    assert_eq!(out, format!("-{},\n", "9".repeat(999)).into_bytes());
    // The JSON writers: self-describing, `Any`, and `Int`.
    assert_eq!(haus::to_haus_json(&long).unwrap_err().to_string(), too_long);
    assert!(haus::json::to_haus_json_with(&long, &raised).is_ok());
    assert_eq!(haus::json::to_string(&long).unwrap_err().to_string(), too_long);
    let int = <haus::Int as haus::Decode>::decode(&long).unwrap();
    assert_eq!(haus::json::to_string(&int).unwrap_err().to_string(), too_long);
}
