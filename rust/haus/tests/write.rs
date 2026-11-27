//! The compact and minimised writers (spec §11) write every value that
//! exists, without limits or errors: a value is within the limits it was
//! built with (spec §7), so every value the parser gives is written again
//! and parses back under the same limits.

use haus::{FormatOptions, Limits, Style, Value, parse_with, ser};

fn roundtrip(text: &str, limits: &Limits) {
    let [value] = parse_with(text, limits).unwrap_or_else(|e| panic!("{text}: {e}")).try_into().unwrap();
    let written = ser::write(&value);
    assert_eq!(parse_with(&written, limits).unwrap(), std::slice::from_ref(&value), "{text}");
    // Minimised: the compact line without the whitespace between tokens, as the formatter writes it.
    let minimised = ser::write_minimised(&value);
    assert_eq!(parse_with(&minimised, limits).unwrap(), [value], "{text}");
    let options = FormatOptions { style: Style::Minimised, limits: *limits, ..FormatOptions::default() };
    assert_eq!(haus::format(&written, &options).unwrap(), minimised.clone() + "\n", "{text}");
}

#[test]
fn minimised_has_no_whitespace_between_tokens() {
    let [value] = haus::parse(r#"Person { name: "Ada Lovelace", tags: [1, Tag {}], at: Point(1, 2), b: x"9F 86" }"#)
        .unwrap()
        .try_into()
        .unwrap();
    assert_eq!(ser::write_minimised(&value), r#"Person{name:"Ada Lovelace",tags:[1,Tag{}],at:Point(1,2),b:x"9f86"}"#);
    assert_eq!(
        ser::write(&value),
        r#"Person { name: "Ada Lovelace", tags: [1, Tag {}], at: Point(1, 2), b: x"9f86" }"#
    );
    assert_eq!(haus::to_string_minimised(&value).unwrap(), ser::write_minimised(&value));
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
    // Parsed with larger limits, written as it is: readers with such limits read it.
    let raised = Limits { max_number_length: 3000, max_exponent: 9000, ..limits };
    for text in ["1".repeat(2500), "0x".to_owned() + &"f".repeat(2490), "1e9000".into()] {
        roundtrip(&text, &raised);
    }
    let lowered = Limits { max_number_length: 20, max_string_length: 4, max_depth: 2, ..limits };
    for text in ["0xFFFFFFFFFFFFFFF", "\"abcd\"", "x\"0102\"", "[[1]]", "A { a: [1] }"] {
        roundtrip(text, &lowered);
    }
}

#[test]
fn numbers_are_written_normalized() {
    for n in ["", "-", "1.", ".5", "01", "1e", "+1", "0x", "1 ", "1 // c", "NaN", "1e5.5"] {
        assert_eq!(Value::number(n).unwrap_err().code, haus::ErrorCode::InvalidNumber, "{n:?}");
    }
    // Numbers are normalized when they are built, and written so.
    for (n, written) in [
        ("1E+05", "1e5"),
        ("1e-0", "1e0"),
        ("-0x0", "-0"),
        ("-0b0", "-0"),
        ("0x0", "0"),
        ("0b101", "5"),
        ("-1_0.5_0", "-10.50"),
    ] {
        assert_eq!(ser::write(&Value::number(n).unwrap()), written, "{n:?}");
    }
}

/// Integers are written in decimal (spec §11): one longer than the number
/// limit can't be built, so whatever exists is written.
#[test]
fn integers_beyond_the_number_limit_are_refused_where_they_are_built() {
    let fits = Value::number(&format!("-{}", "9".repeat(999))).unwrap();
    assert_eq!(ser::write(&fits), format!("-{}", "9".repeat(999)));
    assert_eq!(Value::number(&"9".repeat(1001)).unwrap_err().code, haus::ErrorCode::NumberTooLong);
    // Parsed with a larger limit, it exists, and is written as it is, in every form.
    let raised = Limits { max_number_length: 2000, ..Limits::default() };
    let long = haus::parse_one_with(&"9".repeat(1001), &raised).unwrap();
    assert_eq!(ser::write(&long), "9".repeat(1001));
    assert!(haus::to_haus_json(&long).contains(&"9".repeat(1001)));
    // Encoding it, as an `Any` or an `Int`, applies the encoder's limits (spec §15).
    let too_long = "number literal longer than 1000 characters";
    let int = <haus::Int as haus::Decode>::decode_with(&long, haus::Decoder::new(&raised)).unwrap();
    assert_eq!(haus::json::to_string(&int).unwrap_err().to_string(), too_long);
    assert!(haus::json::to_string_with(&int, haus::Encoder::new(&raised)).is_ok());
}
