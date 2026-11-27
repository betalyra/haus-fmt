//! The canonical form, equality and hashing (spec §12): the same cases as
//! the TypeScript binding (typescript/packages/haus/test/canonical.test.ts).

use haus::{ErrorCode, Limits, Number, Record, Tag, Value, canonical, equals};

fn parse(src: &str) -> Value {
    haus::from_str(src).unwrap()
}

fn c(src: &str) -> String {
    canonical(&parse(src))
}

/// `src`'s one value, read with a number limit of 2000: an integer longer
/// than the default limit.
fn parse_long(src: &str) -> Value {
    let limits = Limits { max_number_length: 3000, ..Limits::default() };
    haus::parse_with(src, &limits).unwrap().remove(0)
}

#[test]
fn writes_the_spec_example() {
    assert_eq!(
        c(r#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5, p: Point(1, 2) }"#),
        r#"Order{id:255,p:Point(1,2),total:19.90,"x-y":1e5}"#
    );
}

#[test]
fn ignores_layout_comments_order_and_spelling() {
    let a = parse(r#"{ b: [1_000, 0b11], /* c */ a: Tag({ x: x"0B 34" }) }"#);
    let b = parse(r#"{a:Tag{x:x"0b34"},b:[1000,3]}"#);
    assert_eq!(canonical(&a), r#"{a:Tag{x:x"0b34"},b:[1000,3]}"#);
    assert!(equals(&a, &b));
}

#[test]
fn keeps_what_equality_tells_apart() {
    assert!(!equals(&parse("1.0"), &parse("1")));
    assert!(!equals(&parse("{}"), &parse("{ x: None }")));
    assert!(!equals(&parse(r#""caf\u{E9}""#), &parse(r#""cafe\u{301}""#)));
    assert!(!equals(&parse("-0"), &parse("0")));
    // Hex and binary keep the sign of zero, as decimal does (spec §2).
    assert!(equals(&parse("-0x0"), &parse("-0")));
    assert!(equals(&parse("-0b0_0"), &parse("-0")));
    assert!(!equals(&parse("-0x0"), &parse("0")));
    assert_eq!(c("[-0x0, -0b0, 0x0, -0x00]"), "[-0,-0,0,-0]");
}

#[test]
fn escapes_only_what_it_must() {
    assert_eq!(c(r#""tab\tquote\" \u{41} \u{1b} \u{202e} café 😀""#), r#""tab\tquote\" A \u{1B} \u{202E} café 😀""#);
    assert_eq!(c("\"\"\"\n  two\n  lines\n  \"\"\""), r#""two\nlines""#);
    // Line and paragraph separators: accepted raw, always written as escapes.
    assert_eq!(c("\"a\u{2028}b\u{2029}c\""), r#""a\u{2028}b\u{2029}c""#);
    assert_eq!(c(r#"{ "\u{2028}": "\u{2029}" }"#), r#"{"\u{2028}":"\u{2029}"}"#);
}

#[test]
fn sorts_keys_by_code_point() {
    assert_eq!(c(r#"{ "😀": 1, "�": 2, a: 3, "Z": 4 }"#), r#"{"Z":4,a:3,"�":2,"😀":1}"#);
}

#[test]
fn writes_a_single_record_payload_as_tag_braces() {
    assert_eq!(c("[None, Some(1), Circle({ r: 1 }), Pair({ a: 1 }, 2)]"), "[None,Some(1),Circle{r:1},Pair({a:1},2)]");
}

#[test]
fn writes_a_huge_hex_integer_in_decimal() {
    // The most hex digits a literal may have (829, spec §7): its decimal form fits the number limit.
    let big = format!("-0x{}", "f".repeat(829));
    let text = c(&big);
    assert!(text.starts_with("-") && text[1..].bytes().all(|d| d.is_ascii_digit()), "{text}");
    assert_eq!(text.len(), 1000);
    assert_eq!(parse(&text), parse(&big));
    // and the compact writer does the same (spec §11), so its output parses again
    assert_eq!(haus::ser::write(&parse(&big)), text);
}

#[test]
fn writes_an_integer_of_any_size_with_all_its_digits() {
    let huge = "9".repeat(1300);
    assert_eq!(canonical(&parse_long(&huge)), huge);
    assert_eq!(
        canonical(&parse_long(&format!("[1, Pair(2, {{ b: -{huge} }})]"))),
        format!("[1,Pair(2,{{b:-{huge}}})]")
    );
    let built = Number::with_limits(&"1".repeat(100_000), &Limits { max_number_length: 100_000, ..Limits::default() });
    assert_eq!(canonical(&built.unwrap().into()), "1".repeat(100_000));
}

#[test]
fn compare_orders_by_the_canonical_bytes() {
    let mut vs: Vec<Value> = ["9", "10", "[]", "\"\u{FFFD}\"", "\"😀\"", "{ b: 1, a: 2 }", "Some(1)", "-1"]
        .iter()
        .map(|s| parse(s))
        .collect();
    vs.sort_by(haus::compare);
    let got: Vec<String> = vs.iter().map(canonical).collect();
    assert_eq!(got, ["\"\u{FFFD}\"", "\"😀\"", "-1", "10", "9", "Some(1)", "[]", "{a:2,b:1}"]);
    assert_eq!(haus::compare(&parse("{ b: 1, a: 2 }"), &parse("{ a: 2, b: 1 }")), std::cmp::Ordering::Equal);
    assert_eq!(haus::compare(&parse("1.0"), &parse("1")), std::cmp::Ordering::Greater);
}

#[cfg(feature = "hash")]
#[test]
fn hash_is_sha256_of_the_canonical_form() {
    assert_eq!(haus::hash(&parse("{ a: 1 }")), "f09a9231c12685ac5f0b6f0b06c9154f13dc3a5b3548db5142c19bde1383f261");
    assert_eq!(
        haus::hash(&parse(r#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5, p: Point(1, 2) }"#)),
        "d324549b0e26394cc4f2a1fc7ac2647179da2d244c66763381c9cb63dbf8a104"
    );
    assert_eq!(haus::hash(&parse("{ x: 1, y: [2] }")), haus::hash(&parse("{ y: [ 2, ], x: 1 }")));
}

#[cfg(feature = "hash")]
#[test]
fn hashes_an_integer_of_any_size() {
    let huge = parse_long(&"9".repeat(1300));
    assert_eq!(haus::hash(&huge).len(), 64);
    assert_ne!(haus::hash(&huge), haus::hash(&parse_long(&"9".repeat(1299))));
}

fn num(text: &str) -> Value {
    Value::number(text).unwrap()
}

/// What isn't a haus value can't be built (spec §11, "Values built in
/// code"): the constructors reject it with the code of the mistake, so the
/// canonical form, equality, order and hash never fail for it (spec §12).
#[test]
fn values_that_are_not_haus_values_cannot_be_built() {
    for text in ["01", "NaN", "", "1e", "1.", " 1", "1 ", "+1", "0x", "1__0", "--1"] {
        let e = Number::new(text).unwrap_err();
        assert_eq!(e.code, ErrorCode::InvalidNumber, "{text:?}");
        assert_eq!(Value::number(text).unwrap_err(), e);
    }
    assert_eq!(Number::new("01").unwrap_err().to_string(), "invalid number '01': not a number literal");
    for name in ["lower", "", "A-B", "1A", "Ä", "_A"] {
        assert_eq!(Tag::new(name).unwrap_err().code, ErrorCode::InvalidTag, "{name:?}");
        assert_eq!(Value::variant(name, vec![]).unwrap_err().code, ErrorCode::InvalidTag, "{name:?}");
    }
    let twice = Record::from_fields([("a", num("1")), ("b", num("2")), ("a", num("3"))]).unwrap_err();
    assert_eq!((twice.code, twice.to_string()), (ErrorCode::DuplicateKey, "duplicate key 'a'".to_owned()));
    assert_eq!(Value::record([("x", num("1")), ("x", num("1"))]).unwrap_err().code, ErrorCode::DuplicateKey);
    let mut r = Record::new();
    r.insert("pt-BR", 1).unwrap();
    assert_eq!(r.insert("pt-BR", 2).unwrap_err().code, ErrorCode::DuplicateKey);
    assert_eq!(r.len(), 1, "a failed insert leaves the record as it was");
}

/// Every value built in code has a canonical form, the one of the value
/// parsed from its text.
#[test]
fn values_built_in_code_have_a_canonical_form() {
    let boxed = Value::variant("Box", vec![Value::record([("y", num("1E+05"))]).unwrap()]).unwrap();
    let array = Value::array(vec![Value::from(true), Value::string("s").unwrap()]).unwrap();
    let v = Value::record([("z", num("1")), ("a", boxed), ("b", array)]);
    let v = v.unwrap();
    let parsed = parse(r#"{ b: [True, "s"], z: 1, a: Box { y: 1e+05 } }"#);
    assert_eq!(canonical(&v), r#"{a:Box{y:1e5},b:[True,"s"],z:1}"#);
    assert!(equals(&v, &parsed) && equals(&v, &v));
    assert_eq!(haus::compare(&v, &parsed), std::cmp::Ordering::Equal);
    #[cfg(feature = "hash")]
    {
        assert_eq!(haus::hash(&v), haus::hash(&parsed));
        assert_eq!(
            haus::hash_all([&v, &num("1")]),
            haus::hash_all(&haus::parse("{ a: Box { y: 1e5 }, b: [True, \"s\"], z: 1 }, 1").unwrap())
        );
    }
}

/// A number literal that isn't normalized is normalized when it is built, as
/// the parser does: the value hashes as the one parsed from its text (spec §2).
#[test]
fn number_literals_built_in_code_are_normalized() {
    for (built, normal) in
        [("1e+05", "1e5"), ("1E5", "1e5"), ("0xFF", "255"), ("-0x0", "-0"), ("1_000", "1000"), ("1.50e-007", "1.50e-7")]
    {
        assert_eq!(Number::new(built).unwrap(), normal, "{built}");
        assert_eq!(canonical(&num(built)), normal, "{built}");
        assert!(equals(&num(built), &parse(normal)), "{built}");
        #[cfg(feature = "hash")]
        assert_eq!(haus::hash(&num(built)), haus::hash(&parse(built)), "{built}");
    }
    // No limit applies to the canonical form: a number parsed with larger
    // limits has all its digits there.
    let long = format!("1{}e+0", "0".repeat(2000));
    assert_eq!(canonical(&parse_long(&long)), format!("1{}e0", "0".repeat(2000)));
    // Built in code, it is beyond the number limit (spec §11).
    assert_eq!(Number::new(&long).unwrap_err().code, haus::ErrorCode::NumberTooLong);
}

/// A value built in code `levels` deep: arrays and variants with record payloads, in turn.
fn deep(levels: usize, innermost: &str) -> Value {
    (0..levels).fold(Value::string(innermost).unwrap(), |v, i| match i % 2 {
        0 => Value::array(vec![v]).unwrap(),
        _ => Value::variant("T", vec![Value::record([("a", v)]).unwrap()]).unwrap(),
    })
}

/// Spec §12: the canonical form, hashing, equality and order work at the
/// deepest a value can be (256 levels, which constructors allow and no
/// value exceeds), without a call stack per level (on a test thread's small
/// stack).
#[test]
fn any_depth() {
    let (a, b, c) = (deep(256, "x"), deep(256, "x"), deep(256, "y"));
    assert_eq!(a.depth(), 256);
    assert_eq!(canonical(&a), format!("{}\"x\"{}", "T{a:[".repeat(128), "]}".repeat(128)));
    assert!(equals(&a, &b));
    assert!(!equals(&a, &c));
    assert_eq!(haus::compare(&a, &b), std::cmp::Ordering::Equal);
    assert_eq!(haus::compare(&a, &c), std::cmp::Ordering::Less);
    #[cfg(feature = "hash")]
    {
        assert_eq!(haus::hash(&a), haus::hash(&b));
        assert_eq!(haus::hash_all([&a]), haus::hash(&a));
        assert_ne!(haus::hash(&a), haus::hash(&c));
    }
}
