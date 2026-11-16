//! The canonical form, equality and hashing (spec §12): the same cases as
//! the TypeScript binding (typescript/packages/haus/test/canonical.test.ts).

use haus::{Limits, Value, canonical, equals};

fn parse(src: &str) -> Value {
    haus::from_str(src).unwrap()
}

fn c(src: &str) -> String {
    canonical(&parse(src)).unwrap()
}

/// `src`'s one value, read with a number limit of 2000.
fn parse_long(src: &str) -> Value {
    let limits = Limits { max_number_length: 2000, ..Limits::default() };
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
    assert_eq!(canonical(&a).unwrap(), r#"{a:Tag{x:x"0b34"},b:[1000,3]}"#);
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
fn keeps_a_huge_hex_integer_in_hex() {
    let big = format!("0x{}", "f".repeat(900));
    assert_eq!(c(&big), big);
    // and the compact writer does the same (spec §11), so its output parses again
    assert_eq!(haus::ser::write(&parse(&big)), Ok(big));
}

#[test]
fn switches_to_hex_at_1000_characters_whatever_the_number_limit() {
    assert_eq!(c(&"9".repeat(1000)), "9".repeat(1000));
    let hex = canonical(&parse_long(&"9".repeat(1100))).unwrap();
    assert!(hex.starts_with("0x") && hex.len() <= 1000, "{hex}");
    assert_eq!(parse_long(&hex), parse_long(&"9".repeat(1100)));
}

#[test]
fn has_no_form_for_an_integer_longer_than_1000_characters_in_hex_too() {
    let huge = "9".repeat(1300);
    let e = canonical(&parse_long(&huge)).unwrap_err();
    assert_eq!(e.code, haus::ErrorCode::NumberTooLong);
    assert_eq!(e.reason, "an integer longer than 1000 characters in hex too has no canonical form");
    assert_eq!(e.place(), "$");
    let nested = parse_long(&format!("{{ a: [{huge}] }}"));
    assert_eq!(canonical(&nested).unwrap_err().place(), "$.a[0]");
    let tagged = parse_long(&format!("[1, Pair(2, {{ b: {huge} }})]"));
    assert_eq!(canonical(&tagged).unwrap_err().place(), "$[1][1].b");
    // Equality and order need no canonical form: they compare the hex form, `0x…`.
    assert!(equals(&nested, &nested.clone()));
    assert_eq!(haus::compare(&nested, &parse_long("{ a: [1] }")), std::cmp::Ordering::Less);
}

#[test]
fn compare_orders_by_the_canonical_bytes() {
    let mut vs: Vec<Value> = ["9", "10", "[]", "\"\u{FFFD}\"", "\"😀\"", "{ b: 1, a: 2 }", "Some(1)", "-1"]
        .iter()
        .map(|s| parse(s))
        .collect();
    vs.sort_by(haus::compare);
    let got: Vec<String> = vs.iter().map(|v| canonical(v).unwrap()).collect();
    assert_eq!(got, ["\"\u{FFFD}\"", "\"😀\"", "-1", "10", "9", "Some(1)", "[]", "{a:2,b:1}"]);
    assert_eq!(haus::compare(&parse("{ b: 1, a: 2 }"), &parse("{ a: 2, b: 1 }")), std::cmp::Ordering::Equal);
    assert_eq!(haus::compare(&parse("1.0"), &parse("1")), std::cmp::Ordering::Greater);
}

#[cfg(feature = "hash")]
#[test]
fn hash_is_sha256_of_the_canonical_form() {
    assert_eq!(
        haus::hash(&parse("{ a: 1 }")).unwrap(),
        "f09a9231c12685ac5f0b6f0b06c9154f13dc3a5b3548db5142c19bde1383f261"
    );
    assert_eq!(
        haus::hash(&parse(r#"Order { total: 19.90, id: 0xFF, "x-y": 1e+5, p: Point(1, 2) }"#)).unwrap(),
        "d324549b0e26394cc4f2a1fc7ac2647179da2d244c66763381c9cb63dbf8a104"
    );
    assert_eq!(haus::hash(&parse("{ x: 1, y: [2] }")), haus::hash(&parse("{ y: [ 2, ], x: 1 }")));
}

#[cfg(feature = "hash")]
#[test]
fn hashes_nothing_without_a_canonical_form() {
    let huge = "9".repeat(1300);
    let code = |r: Result<String, haus::EncodeError>| r.map_err(|e| (e.code.as_str(), e.place()));
    assert_eq!(code(haus::hash(&parse_long(&huge))), Err(("number-too-long", "$".to_owned())));
    let nested = parse_long(&format!("{{ a: [{huge}] }}"));
    assert_eq!(code(haus::hash(&nested)), Err(("number-too-long", "$.a[0]".to_owned())));
    let values = [parse("1"), nested.clone()];
    // The path is inside the value, as for `hash` of that value.
    assert_eq!(code(haus::hash_all(&values)), Err(("number-too-long", "$.a[0]".to_owned())));
    // The hasher is as it was before the value it can't add.
    let mut hasher = haus::Hasher::new();
    hasher.add(&values[0]).unwrap();
    assert_eq!(hasher.add(&nested).map(|_| ()).unwrap_err().place(), "$.a[0]");
    assert_eq!(Ok(hasher.digest()), haus::hash(&values[0]));
    // An integer whose hex form fits still has a hash.
    let fits = parse_long(&"9".repeat(1100));
    assert_eq!(haus::hash(&fits).unwrap().len(), 64);
    assert_eq!(haus::hash_all([&fits]), haus::hash(&fits));
}
