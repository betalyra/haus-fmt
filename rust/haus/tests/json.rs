//! JSON (spec §16): the reader and writer, the prelude types' schema-based
//! JSON, self-describing JSON of values built in code, and the import.

use haus::json::{self, Json, from_str, parse, to_string};
use haus::{Bytes, Decimal, Error, Int, Limits, Secret, Value};
use std::collections::BTreeMap;

fn syntax_error(text: &str) -> String {
    parse(text).unwrap_err().to_string()
}

fn read_error<T: haus::FromJson + haus::Encode + std::fmt::Debug>(json: &str) -> String {
    match from_str::<T>(json) {
        Err(Error::Decode(e)) => e.to_string(),
        other => panic!("expected a decode error, got {other:?}"),
    }
}

#[test]
fn the_reader_takes_i_json() {
    let json = parse(" {\"a\": [1, -0.5e+3, true, false, null, \"\\u00e9\\ud83d\\ude00\\n\\/\"]}\r\n").unwrap();
    let items = [
        Json::Number("1".into()),
        Json::Number("-0.5e+3".into()),
        Json::Bool(true),
        Json::Bool(false),
        Json::Null,
        Json::String("é😀\n/".into()),
    ];
    assert_eq!(json, Json::Object(vec![("a".into(), Json::Array(items.to_vec()))]));
    // Numbers keep their text, however long.
    let digits = "1".repeat(1000);
    assert_eq!(parse(&digits).unwrap(), Json::Number(digits));
    // Noncharacters and raw controls beyond U+001F are fine in JSON, except
    // in self-describing JSON, which only haus writes, escaping them.
    assert_eq!(parse("\"\u{10FFFF}\u{7F}\u{202E}\"").unwrap(), Json::String("\u{10FFFF}\u{7F}\u{202E}".into()));
    let raw = |text: &str| haus::from_haus_json(&format!(r#"{{"_haus": 1, "_value": {text}}}"#));
    assert_eq!(
        raw("\"a\u{85}\"").unwrap_err().to_string(),
        "raw control character U+0085 in a string (escape it) at 1:26"
    );
    assert_eq!(
        raw("{\"_rec\": {\"\u{2066}\": \"x\"}}").unwrap_err().to_string(),
        "raw bidirectional control character U+2066 in a string (escape it) at 1:35"
    );
    assert!(raw("\"\\u0085\\u2066\"").is_ok());
}

#[test]
fn the_reader_rejects_what_i_json_forbids() {
    let cases = [
        (r#"{"a": 1, "a": 2}"#, "duplicate member name \"a\" at 1:10"),
        (r#""\ud83d""#, "unpaired surrogate in a \\u escape at 1:2"),
        (r#""\ude00\ud83d""#, "unpaired surrogate in a \\u escape at 1:2"),
        (r#""\ud83dA""#, "unpaired surrogate in a \\u escape at 1:2"),
        ("\"a\u{1}\"", "raw control character U+0001 in a string (escape it) at 1:3"),
        ("[1,]", "expected a JSON value, found ']' at 1:4"),
        ("{\"a\":1,}", "expected a member name, found '}' at 1:8"),
        ("01", "unexpected '1' after the JSON value at 1:2"),
        ("1.", "invalid number: a digit must follow '.' at 1:1"),
        ("1e", "invalid number: a digit must follow the exponent at 1:1"),
        ("+1", "expected a JSON value, found '+' at 1:1"),
        ("NaN", "expected a JSON value, found 'N' at 1:1"),
        ("'a'", "expected a JSON value, found ''' at 1:1"),
        ("1 2", "unexpected '2' after the JSON value at 1:3"),
        ("", "expected a JSON value, found end of input at 1:1"),
        ("[1", "expected ',' or ']', found end of input at 1:3"),
        (r#""\x""#, "invalid escape: use \\\" \\\\ \\/ \\b \\f \\n \\r \\t or \\uXXXX at 1:2"),
        (r#""\u12""#, "\\u takes four hex digits at 1:2"),
        ("1e6145", "exponent larger than 6144 at 1:1"),
    ];
    for (text, error) in cases {
        assert_eq!(syntax_error(text), error, "{text:?}");
    }
    assert_eq!(syntax_error(&"1".repeat(1001)), "number literal longer than 1000 characters at 1:1");
    assert!(parse("1e6144").is_ok() && parse("1e-0006144").is_ok());
    assert_eq!(json::parse_bytes(b"\"\xff\"").unwrap_err().to_string(), "invalid UTF-8 at 1:2");
    // A byte order mark is ignored at the start, and only there.
    assert_eq!(parse("\u{FEFF}1").unwrap(), Json::Number("1".into()));
    assert_eq!(syntax_error("1\u{FEFF}"), "unexpected '\u{FEFF}' after the JSON value at 1:2");
}

#[test]
fn the_reader_enforces_limits() {
    let limits = Limits { max_depth: 2, max_string_length: 3, ..Limits::default() };
    // JSON may nest 4·d + 1 levels: a mapping can take several JSON levels for one haus level.
    let nested = |n: usize| format!("{}1{}", "[".repeat(n), "]".repeat(n));
    assert!(json::parse_with(&nested(9), &limits).is_ok());
    assert_eq!(json::parse_with(&nested(10), &limits).unwrap_err().reason, "JSON nested deeper than 9 levels");
    // Self-describing JSON one more, for the envelope (whose member names
    // the string limit must leave room for).
    let shallow = Limits { max_depth: 2, ..Limits::default() };
    let enveloped = |n: usize| format!(r#"{{"_haus":1,"_value":{}"a"{}}}"#, "[".repeat(n), "]".repeat(n));
    assert!(json::from_haus_json_with(&enveloped(2), &shallow).is_ok());
    assert_eq!(
        json::from_haus_json_with(&enveloped(10), &shallow).unwrap_err().to_string(),
        "JSON nested deeper than 10 levels at 1:30"
    );
    // Then the haus value that results is checked against d.
    assert_eq!(
        json::from_haus_json_with(&enveloped(9), &shallow).unwrap_err().to_string(),
        "[0][0]: nesting deeper than 2 levels"
    );
    let at_limit = r#"{"_haus":1,"_value":{"_tag":"T","_args":[{"_rec":{"a":{"_rec":{}}}}]}}"#;
    assert_eq!(haus::from_haus_json(at_limit).unwrap(), haus::parse("T { a: {} }").unwrap()[0]);
    let typed: Result<Vec<Vec<Vec<u8>>>, _> = json::from_str_with("[[[1]]]", &limits);
    assert_eq!(typed.unwrap_err().to_string(), "[0][0]: nesting deeper than 2 levels");
    // The import's JSON nests d levels.
    assert!(json::import_json_with("[[1]]", &limits).is_ok());
    assert!(
        json::import_json_with("[[[1]]]", &limits)
            .unwrap_err()
            .to_string()
            .contains("JSON nested deeper than 2 levels")
    );
    assert!(json::parse_with("\"abc\"", &limits).is_ok());
    assert_eq!(json::parse_with("\"abcd\"", &limits).unwrap_err().reason, "string longer than 3 characters");
    // The import's JSON nests as haus does.
    assert!(haus::import_json(&format!("{}1{}", "[".repeat(256), "]".repeat(256))).is_ok());
    let deep = format!("{}1{}", "[".repeat(257), "]".repeat(257));
    assert_eq!(haus::import_json(&deep).unwrap_err().to_string(), "JSON nested deeper than 256 levels at 1:257");
}

#[test]
fn the_writer_checks_what_it_writes() {
    // Besides what JSON requires, DEL, C1 and the bidi controls are escaped.
    let held = "\"\\\n\r\t\u{8}\u{c}\u{1}\u{7F}\u{9F}\u{202A}\u{2069}é\u{A0}\u{200F}";
    let text = json::write(&Json::String(held.into())).unwrap();
    assert_eq!(text, "\"\\\"\\\\\\n\\r\\t\\b\\f\\u0001\\u007f\\u009f\\u202a\\u2069é\u{A0}\u{200F}\"");
    assert_eq!(parse(&text).unwrap(), Json::String(held.into()));
    let named = json::write(&Json::Object(vec![("\u{202E}".into(), Json::Null)])).unwrap();
    assert_eq!(named, r#"{"\u202e":null}"#);
    for bad in ["1.", "01", "+1", "NaN", "0x1", ""] {
        assert_eq!(json::write(&Json::Number(bad.into())).unwrap_err().to_string(), "not a JSON number", "{bad:?}");
    }
    let twice = Json::Object(vec![("a".into(), Json::Null), ("a".into(), Json::Null)]);
    assert_eq!(json::write(&twice).unwrap_err().to_string(), "a member name is used twice in an object");
    assert!(json::write(&(0..1025).fold(Json::Null, |j, _| Json::Array(vec![j]))).is_ok());
    let deep = (0..1026).fold(Json::Null, |j, _| Json::Array(vec![j]));
    assert_eq!(json::write(&deep).unwrap_err().to_string(), "JSON nested deeper than 1025 levels");
}

#[test]
fn scalars() {
    assert_eq!(to_string(&-12i32).unwrap(), "-12");
    assert_eq!(from_str::<u8>("-0").unwrap(), 0);
    assert_eq!(read_error::<i32>("1.0"), "expected a whole number (Int32), found 1.0");
    assert_eq!(read_error::<i32>("2147483648"), "2147483648 is out of range for Int32 (-2147483648 to 2147483647)");
    assert_eq!(read_error::<i32>("\"1\""), "expected a number (Int32), found a string");

    // Int64, UInt64 and Int are strings.
    assert_eq!(to_string(&i64::MIN).unwrap(), "\"-9223372036854775808\"");
    assert_eq!(to_string(&u64::MAX).unwrap(), "\"18446744073709551615\"");
    assert_eq!(from_str::<i64>("\"-0\"").unwrap(), 0);
    assert_eq!(read_error::<u64>("\"-1\""), "-1 is out of range for UInt64 (0 to 18446744073709551615)");
    for bad in ["\"+1\"", "\"1e3\"", "\" 1\"", "\"01\"", "\"\""] {
        assert_eq!(read_error::<Int>(bad), "expected a decimal integer in a string (Int)", "{bad}");
    }
    // Within the number limit as haus writes it: in hex.
    let big = "9".repeat(1200);
    assert_eq!(from_str::<Int>(&format!("\"{big}\"")).unwrap().as_str(), big);

    // Floats in the spelling of spec §15; NaN and the infinities as strings.
    assert_eq!(to_string(&0.1f64).unwrap(), "0.1");
    assert_eq!(to_string(&-0.0f64).unwrap(), "-0");
    assert_eq!(to_string(&1e21f64).unwrap(), "1e21");
    assert_eq!(to_string(&f32::MAX).unwrap(), "3.4028235e38");
    assert_eq!(
        to_string(&[f64::NAN, f64::INFINITY, f64::NEG_INFINITY][..]).unwrap(),
        r#"["NaN","Infinity","-Infinity"]"#
    );
    assert!(from_str::<f64>("\"NaN\"").unwrap().is_nan());
    assert_eq!(from_str::<f32>("16777217").unwrap(), 16777216.0);
    assert_eq!(read_error::<f32>("1e39"), "1e39 is too large for Float32");
    assert_eq!(from_str::<f64>("1e-400").unwrap().to_bits(), 0);
    assert_eq!(from_str::<f64>("-1e-400").unwrap().to_bits(), (-0.0f64).to_bits());

    // Decimal: a string holding a number, kept with its scale.
    let price: Decimal = from_str("\"19.90\"").unwrap();
    assert_eq!(price.as_str(), "19.90");
    assert_eq!(from_str::<Decimal>("\"-1.5E+05\"").unwrap().as_str(), "-1.5e5");
    assert_eq!(to_string(&price).unwrap(), "\"19.90\"");
    for bad in ["\"0xFF\"", "\"1_000\"", "\".5\"", "\"19,90\""] {
        assert_eq!(read_error::<Decimal>(bad), "expected a number in a string (Decimal)", "{bad}");
    }

    // Bytes: base64 with padding.
    assert_eq!(to_string(&Bytes(vec![0xfb, 0xff])).unwrap(), "\"+/8=\"");
    assert_eq!(from_str::<Bytes>("\"+/8=\"").unwrap(), Bytes(vec![0xfb, 0xff]));
    assert_eq!(read_error::<Bytes>("\"-_8=\""), "not base64 with padding (Bytes)");

    assert_eq!(to_string(&true).unwrap(), "true");
    assert_eq!(read_error::<bool>("\"true\""), "expected true or false, found a string");

    // std/time: the string, checked by the profile.
    let day: haus::time::Date = from_str("\"2026-11-13\"").unwrap();
    assert_eq!(to_string(&day).unwrap(), "\"2026-11-13\"");
    assert!(from_str::<haus::time::Date>("\"2026-02-30\"").is_err());
}

#[test]
fn containers() {
    let map: BTreeMap<String, Option<u8>> = from_str(r#"{"b": null, "a": 1}"#).unwrap();
    assert_eq!(to_string(&map).unwrap(), r#"{"a":1,"b":null}"#);
    assert_eq!(read_error::<BTreeMap<String, u8>>(r#"{"a": [1]}"#), ".a: expected a number (UInt8), found an array");
    assert_eq!(read_error::<Vec<u8>>("[1, 300]"), "[1]: 300 is out of range for UInt8 (0 to 255)");

    // Maybe: null when the inner JSON can't be null; tagged otherwise.
    assert_eq!(to_string(&Some(Some(5u8))).unwrap(), r#"{"_tag":"Some","value":5}"#);
    assert_eq!(to_string(&Some(None::<u8>)).unwrap(), r#"{"_tag":"Some","value":null}"#);
    assert_eq!(to_string(&None::<Option<u8>>).unwrap(), r#"{"_tag":"None"}"#);
    // Three levels: the outer Maybe's inner JSON can't be null again.
    type Three = Option<Option<Option<u8>>>;
    let three: [(Three, &str); 4] = [
        (None, "null"),
        (Some(None), r#"{"_tag":"None"}"#),
        (Some(Some(None)), r#"{"_tag":"Some","value":null}"#),
        (Some(Some(Some(5))), r#"{"_tag":"Some","value":5}"#),
    ];
    for (value, json) in three {
        assert_eq!(to_string(&value).unwrap(), json);
        assert_eq!(from_str::<Three>(json).unwrap(), value);
    }
    // Secret and Box don't change the form.
    assert_eq!(to_string(&Some(Secret::new(None::<u8>))).unwrap(), r#"{"_tag":"Some","value":null}"#);
    assert_eq!(read_error::<Option<Option<u8>>>(r#"{"_tag":"Some"}"#), "missing member value");
    assert_eq!(
        read_error::<Option<Option<u8>>>(r#"{"_tag":"Maybe"}"#),
        "._tag: unknown tag Maybe; expected one of None, Some"
    );

    // Result: tagged, with the value.
    let ok: Result<u8, String> = from_str(r#"{"_tag": "Ok", "value": 1}"#).unwrap();
    assert_eq!(ok, Ok(1));
    assert_eq!(to_string(&Err::<u8, _>("no".to_owned())).unwrap(), r#"{"_tag":"Err","value":"no"}"#);
    assert_eq!(
        read_error::<Result<u8, String>>(r#"{"_tag": "Ok", "value": "x"}"#),
        ".value: expected a number (UInt8), found a string"
    );
}

#[test]
fn any_is_its_self_describing_value_without_the_envelope() {
    let v = haus::parse(r#"{ a: [1.50, "x", x"ff", None, Point(1, 2)] }"#).unwrap().remove(0);
    let json = to_string(&v).unwrap();
    assert_eq!(
        json,
        r#"{"_rec":{"a":[{"_num":"1.50"},"x",{"_bytes":"ff"},{"_tag":"None"},{"_tag":"Point","_args":[{"_num":"1"},{"_num":"2"}]}]}}"#
    );
    assert_eq!(from_str::<Value>(&json).unwrap(), v);
    assert_eq!(haus::to_haus_json(&v).unwrap(), format!(r#"{{"_haus":1,"_value":{json}}}"#));
    // An envelope is an object like any other here: not a form of `Any`.
    let e = from_str::<Value>(r#"{"_haus":1,"_value":"x"}"#).unwrap_err();
    assert_eq!(e.code().map(|c| c.as_str()), Some("haus-json-form"));

    let any = haus::AnyTag::Bare("EUR".into());
    assert_eq!(to_string(&any).unwrap(), r#"{"_tag":"EUR"}"#);
    assert_eq!(from_str::<haus::AnyTag>(r#"{"_tag":"EUR"}"#).unwrap(), any);
}

#[test]
fn self_describing_json_checks_values_built_in_code() {
    let error = |v: Value| haus::to_haus_json(&v).unwrap_err().to_string();
    let number = |n: &str| Value::Number(n.into());
    assert_eq!(haus::to_haus_json(&number("1E+05")).unwrap(), r#"{"_haus":1,"_value":{"_num":"1e5"}}"#);
    assert_eq!(haus::to_haus_json(&number("0xFF")).unwrap(), r#"{"_haus":1,"_value":{"_num":"255"}}"#);
    assert_eq!(error(Value::Array(vec![number("1"), number("abc")])), "[1]: not a number literal");
    assert_eq!(
        error(Value::Variant { tag: "x".into(), args: vec![] }),
        "not a tag name: A to Z, then letters, digits and _"
    );
    let twice = Value::Record(vec![("a".into(), number("1")), ("a".into(), number("2"))]);
    assert_eq!(error(twice), ".a: the key is used twice in this record");
    let payload = Value::Variant { tag: "P".into(), args: vec![Value::Record(vec![("x".into(), number("-"))])] };
    assert_eq!(error(payload), "(P).x: not a number literal");
    let deep = (0..257).fold(number("1"), |v, _| Value::Array(vec![v]));
    assert!(error(deep).ends_with("nesting deeper than 256 levels"));

    // A haus integer longer than the number limit (written in hex there) is
    // its decimal literal in self-describing JSON, and reads back.
    let big = haus::parse(&format!("0x{}", "f".repeat(998))).unwrap().remove(0);
    let json = haus::to_haus_json(&big).unwrap();
    assert_eq!(haus::from_haus_json(&json).unwrap(), big);
    assert!(haus::from_haus_json(&format!(r#"{{"_haus":1,"_value":{{"_num":"{}"}}}}"#, "9".repeat(1300))).is_err());
}

#[test]
fn self_describing_json_reads_one_form_per_value() {
    let read = |value: &str| haus::from_haus_json(&format!(r#"{{"_value": {value}, "_haus": 1}}"#));
    let error = |value: &str| read(value).unwrap_err().to_string();
    assert_eq!(error(r#"{"_num": "1E5"}"#), "._num: \"1E5\" is not a normalized number literal");
    assert_eq!(error(r#"{"_num": "1e+5"}"#), "._num: \"1e+5\" is not a normalized number literal");
    assert_eq!(error(r#"{"_num": "1e6145"}"#), "._num: exponent larger than 6144");
    assert_eq!(error(r#"{"_tag": "T", "_args": 1}"#), "._args: expected an array, found the number 1");
    assert_eq!(error(r#"[{"_rec": {"a": 1}}]"#).split(": ").next(), Some("[0]._rec.a"));
    assert!(read(r#"{"_args": [{"_num": "1"}], "_tag": "T"}"#).is_ok());
    // The envelope: exactly `_haus` 1 and `_value`, in any order; errors are at `$`.
    let code = |text: &str| haus::from_haus_json(text).unwrap_err().code().map(|c| c.as_str());
    assert_eq!(code(r#"{"_num": "1"}"#), Some("haus-json-form"));
    assert_eq!(code(r#"{"_haus": 1, "_value": "a", "_x": 1}"#), Some("haus-json-form"));
    assert_eq!(code(r#"{"_haus": 1.0, "_value": "a"}"#), Some("haus-json-version"));
    assert_eq!(
        haus::from_haus_json(r#"{"_haus": 2, "_value": "a"}"#).unwrap_err().to_string(),
        "self-describing JSON version 2; this reader reads version 1"
    );
    assert_eq!(
        haus::from_haus_json(r#""a""#).unwrap_err().to_string(),
        r#"expected self-describing JSON, the envelope {"_haus": 1, "_value": …}, found a string"#
    );
}

#[test]
fn the_import_reads_any_json() {
    let read = |text: &str| haus::canonical(&haus::import_json(text).unwrap());
    assert_eq!(read(r#"{"_tag": "Circle", "r": 1E+0}"#), r#"{_tag:"Circle",r:1e0}"#);
    assert_eq!(read(r#"{"_haus": 1, "_value": {"_num": "1"}}"#), r#"{_haus:1,_value:{_num:"1"}}"#);
    assert_eq!(read("\"\u{7F}\u{202E}\""), "\"\\u{7F}\\u{202E}\"");
}

#[test]
fn json_lines() {
    // A missing line feed after the last value and CR LF are fine.
    let read = |text: &str| json::from_str_all::<u8>(text).map_err(|e| e.to_string());
    assert_eq!(read("1\n2\n"), Ok(vec![1, 2]));
    assert_eq!(read("1\r\n2"), Ok(vec![1, 2]));
    assert_eq!(read(""), Ok(vec![]));
    // A byte order mark only at the start of the stream.
    assert_eq!(read("\u{FEFF}1\n2\n"), Ok(vec![1, 2]));
    assert_eq!(read("1\n\u{FEFF}2\n"), Err("expected a JSON value, found '\u{FEFF}' at 2:1".into()));
    // Empty lines are errors; errors say which line or value.
    assert_eq!(read("1\n\n2\n"), Err("expected a JSON value, found end of input at 2:1".into()));
    assert_eq!(read("1\n300\n"), Err("[1]: 300 is out of range for UInt8 (0 to 255)".into()));

    let decoded: Result<Vec<u8>, _> = json::decode("\u{FEFF}1\r\n2".as_bytes()).collect();
    assert_eq!(decoded.unwrap(), [1, 2]);
    let e = json::decode::<u8, _>("1\n\u{FEFF}2\n".as_bytes()).find_map(Result::err).unwrap();
    assert_eq!(e.to_string(), "expected a JSON value, found '\u{FEFF}' at 2:1");

    // Self-describing lines: a haus stream as JSON Lines, an envelope per line.
    let values = haus::parse("1, Some(\"a\"),").unwrap();
    let lines = json::to_haus_json_lines(&values).unwrap();
    assert_eq!(
        lines,
        "{\"_haus\":1,\"_value\":{\"_num\":\"1\"}}\n{\"_haus\":1,\"_value\":{\"_tag\":\"Some\",\"_args\":[\"a\"]}}\n"
    );
    assert_eq!(json::from_haus_json_lines(&lines).unwrap(), values);
    assert_eq!(json::from_haus_json_lines("").unwrap(), []);
    let e = json::from_haus_json_lines("{\"_haus\":1,\"_value\":\"a\"}\n{\"_haus\":1,\"_value\":1}\n").unwrap_err();
    assert_eq!(
        e.to_string(),
        "[1]: expected a self-describing value: a string, an array, or an object {\"_num\"}, {\"_bytes\"}, {\"_rec\"} or {\"_tag\", \"_args\"?}, found the number 1"
    );
    // As Any, the lines hold no envelope.
    assert_eq!(json::to_string_all(&values).unwrap(), "{\"_num\":\"1\"}\n{\"_tag\":\"Some\",\"_args\":[\"a\"]}\n");
}
