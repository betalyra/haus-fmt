//! The supported depth (spec §7): every recursive path handles values
//! nested [`MAX_SUPPORTED_DEPTH`] levels deep in a thread with a 2 MiB stack
//! (the default of spawned and test threads), in a debug build too, and every
//! function that takes limits rejects a larger depth limit with an error that
//! names the maximum. Record keys and tags count against the string limit,
//! like strings.

use haus::json::{self, Json};
use haus::stream::{Options, Reader};
use haus::{Decode, Decoder, Encode, Encoder, FromJson, Limits, MAX_SUPPORTED_DEPTH, ToJson, Value, ser};

const MAX: usize = MAX_SUPPORTED_DEPTH;

/// Runs `f` in a thread with a 2 MiB stack.
fn in_small_thread(f: impl FnOnce() + Send + 'static) {
    std::thread::Builder::new().stack_size(2 * 1024 * 1024).spawn(f).unwrap().join().unwrap();
}

/// Values `n` levels deep, of every kind of container: arrays, records,
/// positional payloads, and record payloads.
fn deep(n: usize) -> [(String, Value); 4] {
    let one = Value::from(1);
    let array = (0..n).fold(one.clone(), |v, _| Value::Array(vec![v]));
    let record = (0..n).fold(one.clone(), |v, _| Value::record([("a", v)]).unwrap());
    let payload = (0..n).fold(one.clone(), |v, _| Value::variant("A", vec![v]).unwrap());
    let tagged = (0..n).fold(one, |v, _| Value::variant("A", vec![Value::record([("a", v)]).unwrap()]).unwrap());
    [
        (format!("{}1{}", "[".repeat(n), "]".repeat(n)), array),
        (format!("{}1{}", "{ a: ".repeat(n), " }".repeat(n)), record),
        (format!("{}1{}", "A(".repeat(n), ")".repeat(n)), payload),
        (format!("{}1{}", "A { a: ".repeat(n), " }".repeat(n)), tagged),
    ]
}

#[test]
fn every_path_takes_the_supported_depth_in_a_small_thread() {
    in_small_thread(|| {
        let limits = Limits { max_depth: MAX, ..Limits::default() };
        for (text, value) in deep(MAX) {
            assert_eq!(haus::parse_with(&text, &limits).unwrap(), std::slice::from_ref(&value), "{text:.20}");
            let mut reader = Reader::new(Options { limits, ..Options::default() });
            assert_eq!(reader.push(format!("{text},").as_bytes()).unwrap(), std::slice::from_ref(&value));
            assert_eq!(Value::decode(&value).unwrap(), value);
            assert_eq!(value.encode_with(Encoder::new(&limits)).unwrap(), value);
            assert_eq!(haus::to_string_with(&value, &limits).unwrap(), ser::write_with(&value, &limits).unwrap());
            let enveloped = json::to_self_describing(&value, &limits).unwrap();
            assert_eq!(json::from_self_describing(&enveloped, &limits).unwrap(), value);
            let text = json::to_haus_json_with(&value, &limits).unwrap();
            assert_eq!(json::from_haus_json_with(&text, &limits).unwrap(), value);
            // `Any`: the same value, without the envelope.
            let any = enveloped.get("_value").unwrap();
            assert_eq!(&value.to_json_with(Encoder::new(&limits)).unwrap(), any);
            assert_eq!(Value::from_json_with(any, Decoder::new(&limits)).unwrap(), value);
            let text = json::write_with(any, &limits).unwrap();
            assert_eq!(&json::parse_with(&text, &limits).unwrap(), any);
            assert_eq!(json::from_str_with::<Value>(&text, &limits).unwrap(), value);
            assert_eq!(json::to_string_with(&value, &limits).unwrap(), text);
        }
        // The import's JSON nests as haus does.
        let imported = (0..MAX).fold(Json::Null, |j, _| Json::Array(vec![j]));
        let text = json::write_with(&imported, &limits).unwrap();
        assert!(json::import(&imported, &limits).is_ok() && json::import_json_with(&text, &limits).is_ok());
    });
}

#[test]
fn a_deeper_limit_is_rejected_naming_the_maximum() {
    let above = Limits { max_depth: MAX + 1, ..Limits::default() };
    let reason = format!("max_depth {} is more than the supported maximum, {MAX}", MAX + 1);
    let value = Value::Array(vec![]);
    let syntax = |e: haus::SyntaxError| (e.reason, e.line, e.column);
    let at_start = (reason.clone(), 1, 1);
    // Reading haus.
    assert_eq!(syntax(haus::parse_with("[]", &above).unwrap_err()), at_start);
    assert_eq!(syntax(haus::parse_with("", &above).unwrap_err()), at_start);
    let mut reader = Reader::new(Options { limits: above, ..Options::default() });
    assert_eq!(syntax(reader.push(b"").unwrap_err()), at_start);
    assert_eq!(syntax(Reader::new(Options { limits: above, ..Options::default() }).finish().unwrap_err()), at_start);
    let options = Options { limits: above, ..Options::default() };
    let first = haus::stream::values_with(&b"1,"[..], options).next().unwrap();
    assert_eq!(first.unwrap_err().to_string(), format!("{reason} at 1:1"));
    // Writing haus.
    assert_eq!(haus::to_string_with(&value, &above).unwrap_err().to_string(), reason);
    assert_eq!(haus::to_string_with(&1u8, &above).unwrap_err().to_string(), reason);
    assert_eq!(ser::write_with(&Value::from(1), &above).unwrap_err().to_string(), reason);
    assert_eq!(value.encode_with(Encoder::new(&above)).unwrap_err().to_string(), reason);
    assert_eq!(vec![1u8].encode_with(Encoder::new(&above)).unwrap_err().to_string(), reason);
    let e = haus::stream::encode_with(Vec::new(), [&value], &above).unwrap_err();
    assert_eq!(e.to_string(), format!("[0]: {reason}"));
    // JSON.
    assert_eq!(syntax(json::parse_with("[]", &above).unwrap_err()), at_start);
    assert_eq!(json::import_json_with("1", &above).unwrap_err().to_string(), format!("{reason} at 1:1"));
    assert_eq!(json::from_haus_json_with("1", &above).unwrap_err().to_string(), format!("{reason} at 1:1"));
    assert_eq!(json::from_str_with::<Value>("[]", &above).unwrap_err().to_string(), format!("{reason} at 1:1"));
    assert_eq!(json::write_with(&Json::Null, &above).unwrap_err().to_string(), reason);
    assert_eq!(json::to_string_with(&value, &above).unwrap_err().to_string(), reason);
    assert_eq!(json::to_self_describing(&value, &above).unwrap_err().to_string(), reason);
    assert_eq!(json::to_haus_json_with(&value, &above).unwrap_err().to_string(), reason);
    let enveloped = json::to_self_describing(&value, &Limits::default()).unwrap();
    assert_eq!(json::from_self_describing(&enveloped, &above).unwrap_err().to_string(), reason);
    assert_eq!(json::import(&Json::Null, &above).unwrap_err().to_string(), reason);
    assert_eq!(Decoder::new(&above).nested().unwrap_err().to_string(), reason);
    let e = Vec::<u8>::from_json_with(&Json::Array(vec![]), Decoder::new(&above)).unwrap_err();
    assert_eq!(e.to_string(), reason);
    // The maximum itself is fine.
    let max = Limits { max_depth: MAX, ..Limits::default() };
    assert!(haus::parse_with("[]", &max).is_ok() && haus::to_string_with(&value, &max).is_ok());
}

/// A native recursive type: an array of itself, read from plain JSON.
#[derive(Debug)]
struct Nest(Vec<Nest>);

impl FromJson for Nest {
    fn from_json_with(json: &Json, d: Decoder) -> Result<Nest, haus::DecodeError> {
        json::de::array(json, d, Nest::from_json_with).map(Nest)
    }
}

impl Encode for Nest {
    fn encode_with(&self, e: Encoder) -> Result<Value, haus::EncodeError> {
        ser::array(&self.0, e, Nest::encode_with)
    }
}

#[test]
fn json_too_deep_for_a_type_fails_without_overflowing_the_stack() {
    // JSON may nest 4·d + 1 levels, but reading it with a type counts the
    // levels of the haus value, and stops at d instead of recursing on.
    in_small_thread(|| {
        let nested = |n: usize| format!("{}{}", "[".repeat(n), "]".repeat(n));
        let at_max = json::from_str::<Nest>(&nested(MAX)).unwrap();
        assert_eq!(at_max.encode().unwrap(), deep_arrays(MAX));
        let e = json::from_str::<Nest>(&nested(4 * MAX + 1)).unwrap_err();
        assert_eq!(e.to_string(), format!("{}: nesting deeper than {MAX} levels", "[0]".repeat(MAX)));
        let small = Limits { max_depth: 5, ..Limits::default() };
        let e = json::from_str_with::<Nest>(&nested(7), &small).unwrap_err();
        assert_eq!(e.to_string(), "[0][0][0][0][0]: nesting deeper than 5 levels");
    });
}

/// `n` empty arrays, one inside the other.
fn deep_arrays(n: usize) -> Value {
    (1..n).fold(Value::Array(vec![]), |v, _| Value::Array(vec![v]))
}

#[test]
fn keys_and_tags_count_against_the_string_limit() {
    let limits = Limits { max_string_length: 4, ..Limits::default() };
    let error = |text: &str| haus::parse_with(text, &limits).unwrap_err().to_string();
    // At the limit.
    for text in ["{ abcd: 1 }", r#"{ "abcd": 1 }"#, r#"{ "äöüß": 1 }"#, "Abcd", "Abcd(1)", "Abcd { a: 1 }"] {
        assert!(haus::parse_with(text, &limits).is_ok(), "{text}");
    }
    // One over, reported where the key or tag starts.
    assert_eq!(error("{ abcde: 1 }"), "key longer than 4 characters at 1:3");
    // A quoted key is a string.
    assert_eq!(error(r#"{ "abcde": 1 }"#), "string longer than 4 characters at 1:3");
    assert_eq!(error(r#"{ "äöüßa": 1 }"#), "string longer than 4 characters at 1:3");
    assert_eq!(error("{ a: 1, abcde: 1 }"), "key longer than 4 characters at 1:9");
    assert_eq!(error("[Abcde]"), "tag longer than 4 characters at 1:2");
    assert_eq!(error("[1, Abcde(1)]"), "tag longer than 4 characters at 1:5");
    assert_eq!(error("Abcde { a: 1 }"), "tag longer than 4 characters at 1:1");
    // In a stream, at the position in the whole stream.
    let options = Options { limits, ..Options::default() };
    let mut reader = Reader::new(options);
    assert_eq!(reader.push(b"Abcd,\n{ abcd: 1 },\n").unwrap().len(), 2);
    assert_eq!(reader.push(b"{ abcde: 1 },").unwrap_err().to_string(), "key longer than 4 characters at 3:3");
    let mut reader = Reader::new(options);
    assert_eq!(reader.push(b"1,\nAbcde,").unwrap_err().to_string(), "tag longer than 4 characters at 2:1");

    // Values built in code, written or encoded for such a reader.
    let record = |k: &str| Value::record([(k, Value::from(1))]).unwrap();
    let tag = |t: &str| Value::variant(t, vec![]).unwrap();
    for v in [record("abcd"), record("äöüß"), tag("Abcd")] {
        assert!(ser::write_with(&v, &limits).is_ok() && json::to_self_describing(&v, &limits).is_ok(), "{v:?}");
        assert!(v.encode_with(Encoder::new(&limits)).is_ok());
    }
    let write = |v: &Value| ser::write_with(v, &limits).unwrap_err().to_string();
    assert_eq!(write(&record("abcde")), ".abcde: key longer than 4 characters");
    assert_eq!(write(&tag("Abcde")), "tag longer than 4 characters");
    let payload = Value::variant("A", vec![tag("Abcde")]).unwrap();
    assert_eq!(write(&payload), "(A)[0]: tag longer than 4 characters");
    let encoded = tag("Abcde").encode_with(Encoder::new(&limits)).unwrap_err();
    assert_eq!(encoded.to_string(), "tag longer than 4 characters");
    let enveloped = json::to_self_describing(&record("abcde"), &limits).unwrap_err();
    assert_eq!(enveloped.to_string(), ".abcde: key longer than 4 characters");
    // Native values: a tag such as `True` or `None`, and map keys.
    let tiny = Limits { max_string_length: 3, ..Limits::default() };
    assert_eq!(haus::to_string_with(&true, &tiny).unwrap_err().to_string(), "tag longer than 3 characters");
    assert_eq!(haus::to_string_with(&None::<u8>, &tiny).unwrap_err().to_string(), "tag longer than 3 characters");
    let map: std::collections::BTreeMap<String, u8> = [("abcd".to_owned(), 1)].into();
    assert_eq!(haus::to_string_with(&map, &tiny).unwrap_err().to_string(), ".abcd: key longer than 3 characters");

    // JSON read into haus: member names become keys, "_tag" values tags.
    let obj = |members: Vec<(String, Json)>| Json::object(members).unwrap();
    let envelope = |j: Json| obj(vec![("_haus".into(), Json::Number(1.into())), ("_value".into(), j)]);
    let read = |j: Json| json::from_self_describing(&envelope(j), &limits);
    let rec = |k: &str| obj(vec![("_rec".into(), obj(vec![(k.into(), Json::String("x".into()))]))]);
    let tag_json = |t: &str| obj(vec![("_tag".into(), Json::String(t.into()))]);
    assert!(read(rec("abcd")).is_ok() && read(tag_json("Abcd")).is_ok());
    assert_eq!(read(rec("abcde")).unwrap_err().to_string(), "._value._rec.abcde: key longer than 4 characters");
    assert_eq!(read(tag_json("Abcde")).unwrap_err().to_string(), "._value: tag longer than 4 characters");
    let imported = obj(vec![("abcde".into(), Json::Null)]);
    assert_eq!(json::import(&imported, &limits).unwrap_err().to_string(), ".abcde: key longer than 4 characters");
    // The JSON text reader leaves lengths to the forms, which count them on the
    // haus value (spec §16): a member name is a key only where it becomes one.
    assert!(json::parse_with(r#"{"abcde": 1}"#, &limits).is_ok());
    let e = json::import_json_with(r#"{"abcde": 1}"#, &limits).unwrap_err().to_string();
    assert_eq!(e, ".abcde: key longer than 4 characters");
}

#[test]
fn the_hex_digit_limit_follows_from_the_number_limit() {
    // The largest h with 16^h ≤ 10^(n−1) (spec §7).
    let hex = |n: usize| Limits { max_number_length: n, ..Limits::default() }.max_hex_digits();
    for (n, h) in [(0, 0), (1, 0), (2, 0), (3, 1), (13, 9), (20, 15), (1000, 829), (1001, 830), (3000, 2490)] {
        assert_eq!(hex(n), h, "{n}");
    }
    assert_eq!(hex(1_000_000_000), 830_482_022);
    assert_eq!(hex(usize::MAX), 15_319_689_349_413_178_108);
}

#[test]
fn writers_check_every_number_a_decimal_and_an_exponent_too() {
    // What a parser with the same limits reads back (spec §7): not only integers.
    let code = |text: &str, limits: &Limits| {
        let v = Value::number(text).expect("a number literal");
        haus::to_string_with(&v, limits).map_err(|e| e.code.as_str().to_owned())
    };
    let long = format!("1.{}", "0".repeat(2000));
    assert_eq!(code(&long, &Limits::default()), Err("number-too-long".to_owned()));
    assert_eq!(code("1e9999", &Limits::default()), Err("exponent-too-large".to_owned()));
    assert_eq!(code("1e6144", &Limits::default()), Ok("1e6144".to_owned()));
    let wide = Limits { max_number_length: 2002, max_exponent: 9999, ..Limits::default() };
    assert_eq!(code(&long, &wide), Ok(long.clone()));
    assert_eq!(code("1e9999", &wide), Ok("1e9999".to_owned()));
    // The canonical form has no limits (spec §12).
    assert_eq!(haus::canonical(&Value::number(&long).unwrap()), long);
}

#[test]
fn a_hex_literal_has_at_most_829_hex_digits() {
    let error = |text: &str| {
        let e = haus::parse(text).unwrap_err();
        (e.code.as_str(), e.reason, e.column)
    };
    for sign in ["", "-"] {
        // Leading zeros count; separators and the prefix don't.
        for digits in ["f".repeat(829), "0".repeat(829), format!("{}_f", "f".repeat(828))] {
            let text = format!("{sign}0x{digits}");
            let [v] = haus::parse(&text).unwrap().try_into().unwrap();
            // It fits the number limit in decimal.
            assert!(ser::write(&v).unwrap().len() <= 1000, "{text:.20}");
        }
        let text = format!("[1, {sign}0x{}]", "0".repeat(830));
        // At the literal.
        assert_eq!(error(&text), ("number-too-long", "hex literal with more than 829 hex digits".into(), 5));
    }
    // The literal's length is checked first: 830 hex digits with 414 separators are 1246 characters.
    let long = format!("0x{}", vec!["ff"; 415].join("_"));
    assert_eq!(error(&long).1, "number literal longer than 1000 characters");
    // A raised number limit allows more.
    let raised = Limits { max_number_length: 1001, ..Limits::default() };
    assert!(haus::parse_with(&format!("0x{}", "f".repeat(830)), &raised).is_ok());
    // Binary literals need no limit of their own: 998 binary digits fit in decimal.
    assert!(haus::parse(&format!("-0b{}", "1".repeat(997))).is_ok());
}

/// Writers and checks of values built in code count an empty record, array
/// or record payload as a level, as parsing does (spec §7): a value built in
/// code and the same value parsed have the same depth.
#[test]
fn empty_containers_built_in_code_are_levels() {
    let limits = Limits { max_depth: 2, ..Limits::default() };
    // Each needs depth 3 when parsed; `T(U {})` and `{ a: [] }` need 2.
    let too_deep = ["[[[]]]", "{ a: { b: {} } }", "[{ a: [] }]", "T(U(V {}))", "T([[]])", "[T {}, [[]]]"];
    let at_limit = ["[[]]", "{ a: [] }", "T(U {})", "T {}", "[T {}]", "T(U {}, [])"];
    for text in too_deep {
        assert!(haus::parse_with(text, &limits).is_err(), "{text} parses within depth 2");
        let value = haus::parse(text).unwrap().remove(0);
        let code = |e: haus::EncodeError| e.code.as_str();
        assert_eq!(haus::to_string_with(&value, &limits).map_err(code).err(), Some("nesting-too-deep"), "{text}");
        assert_eq!(json::to_haus_json_with(&value, &limits).map_err(code).err(), Some("nesting-too-deep"), "{text}");
        assert_eq!(json::to_string_with(&value, &limits).map_err(code).err(), Some("nesting-too-deep"), "{text}");
        assert_eq!(value.encode_with(Encoder::new(&limits)).map_err(code).err(), Some("nesting-too-deep"), "{text}");
    }
    for text in at_limit {
        assert!(haus::parse_with(text, &limits).is_ok(), "{text} doesn't parse within depth 2");
        let value = haus::parse(text).unwrap().remove(0);
        assert!(haus::to_string_with(&value, &limits).is_ok(), "{text}");
        assert!(json::to_haus_json_with(&value, &limits).is_ok(), "{text}");
        assert!(json::to_string_with(&value, &limits).is_ok(), "{text}");
        assert!(value.encode_with(Encoder::new(&limits)).is_ok(), "{text}");
    }
    // Typed values: an empty Vec is a level too.
    let empty: Vec<Vec<Vec<u8>>> = vec![vec![vec![]]];
    assert_eq!(haus::to_string_with(&empty, &limits).unwrap_err().code.as_str(), "nesting-too-deep");
    assert_eq!(json::to_string_with(&empty, &limits).unwrap_err().code.as_str(), "nesting-too-deep");
    assert!(haus::to_string_with(&vec![Vec::<u8>::new()], &limits).is_ok());
}

/// Messages quote text from the input escaped, then at most 40 characters as
/// shown (spec §9): a long or invisible token can't flood or hide a message.
#[test]
fn messages_quote_tokens_escaped_and_short() {
    let long = "k".repeat(100);
    let reason = |text: &str| haus::parse(text).unwrap_err().reason;
    assert_eq!(reason(&format!("{{ {long}: 1, {long}: 2 }}")), format!("duplicate key '{}…'", "k".repeat(39)));
    assert_eq!(reason(r#"{ "a\u{202E}b": 1, "a\u{202E}b": 2 }"#), r"duplicate key 'a\u{202E}b'");
    let unexpected =
        format!("unexpected identifier '{}…': lowercase identifiers can only be record keys", "k".repeat(39));
    assert_eq!(reason(&format!("[{long}]")), unexpected);
    assert_eq!(reason(&format!("1{long}")), format!("invalid number '1{}…'", "k".repeat(38)));
    assert_eq!(reason(r#""\q""#), r"invalid escape '\q'");
    let e = <i8 as Decode>::decode(&Value::number(&"1".repeat(100)).unwrap()).unwrap_err();
    assert_eq!(e.to_string(), format!("{}… is out of range for Int8 (-128 to 127)", "1".repeat(39)));
    // Constructors quote what they reject the same way.
    assert_eq!(
        Value::number(&long).unwrap_err().reason,
        format!("invalid number '{}…': not a number literal", "k".repeat(39))
    );
    assert_eq!(
        haus::Record::from_fields([(long.as_str(), Value::from(1)), (long.as_str(), Value::from(2))])
            .unwrap_err()
            .reason,
        format!("duplicate key '{}…'", "k".repeat(39))
    );
    assert_eq!(
        Value::variant("A\u{202E}b", vec![]).unwrap_err().reason,
        r"invalid tag 'A\u{202E}b': a tag is A to Z, then letters, digits and _"
    );
}
