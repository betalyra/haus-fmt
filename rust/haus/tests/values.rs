//! Values built in code (spec §7, §11 "Values built in code", §12;
//! test-suite/README.md "Values built in code"): the constructors build only
//! haus values within the default limits, rejecting anything else with the
//! code of the mistake, and normalize numbers as the parser reads them. A
//! value that exists is written, and has a canonical form, a hash, equality
//! and order, without any error: their signatures have none.
//!
//! What the suite lists and Rust can't express: a string or key with an
//! unpaired surrogate (`cannot-encode`; a Rust `str` is UTF-8), a value
//! whose parts share each other (`too-many-nodes` at a constructor; a
//! [`Value`] owns its parts) and a value changed after it was built
//! (`value-changed`; parts are reached by shared reference only).

use haus::{ByteString, ErrorCode, Limits, List, Number, Record, Tag, Text, Value, canonical};
use std::collections::BTreeMap;

#[test]
fn numbers_are_normalized_when_built() {
    for (literal, normal) in [
        ("1E+05", "1e5"),
        ("1e-0", "1e0"),
        ("-0x0", "-0"),
        ("0b101", "5"),
        ("0xFF", "255"),
        ("1_000.5_0", "1000.50"),
        ("19.90", "19.90"),
        ("-0", "-0"),
    ] {
        let n: Number = literal.parse().unwrap();
        assert_eq!((n.as_str(), n.to_string()), (normal, normal.to_owned()), "{literal}");
        assert_eq!(Number::try_from(literal).unwrap(), n);
    }
    // Native integers, of any size.
    assert_eq!(Number::from(u128::MAX).as_str(), "340282366920938463463374607431768211455");
    assert_eq!(Number::from(i8::MIN), "-128");
    assert_eq!(canonical(&Value::from(-7i64)), "-7");
}

/// The number limits are measured on the normalized literal (spec §11).
#[test]
fn numbers_are_within_the_number_limits_on_their_normalized_form() {
    let code = |literal: &str| Number::new(literal).map(|_| ()).map_err(|e| e.code);
    // 1000 characters is the limit, sign included; 1001 digits are over it.
    assert_eq!(code(&format!("-{}", "9".repeat(999))), Ok(()));
    assert_eq!(code(&"9".repeat(1001)), Err(ErrorCode::NumberTooLong));
    // 600 digits with a `_` between each two: longer than 1000 as written, within it normalized.
    let separated: Vec<String> = (0..600).map(|i| (1 + i % 9).to_string()).collect();
    assert_eq!(code(&separated.join("_")), Ok(()));
    // 840 hex digits: more than 1000 decimal digits.
    assert_eq!(code(&format!("0x{}", "f".repeat(840))), Err(ErrorCode::NumberTooLong));
    assert_eq!(code("1e6144"), Ok(()));
    assert_eq!(code("1e6145"), Err(ErrorCode::ExponentTooLarge));
    assert_eq!(code("1e-99999999999999999999"), Err(ErrorCode::ExponentTooLarge));
    // An exponent past u64 is still a literal (fuzz round C, F3), beyond the limit.
    assert_eq!(code("3E70955681357760880162"), Err(ErrorCode::ExponentTooLarge));
    // With larger limits, larger numbers.
    let any = Limits { max_number_length: 5000, max_exponent: u64::MAX, ..Limits::default() };
    assert_eq!(Number::with_limits("1e99999999999999999999", &any).unwrap(), "1e99999999999999999999");
}

#[test]
fn tags_are_tag_names() {
    for name in ["A", "None", "EUR", "Point3D", "A_b_9"] {
        let tag = Tag::new(name).unwrap();
        assert!(tag == name && *name == tag && tag.as_str() == name, "{name}");
        assert_eq!(Tag::try_from(name.to_owned()).unwrap(), tag);
    }
    for name in ["a", "", "_A", "9A", "A-B", "A B", "Ä", "A\u{0}"] {
        let e = Tag::new(name).unwrap_err();
        assert_eq!(e.code, ErrorCode::InvalidTag, "{name:?}");
        assert_eq!(name.parse::<Tag>().unwrap_err(), e);
    }
}

/// Spec §7: 16 Mi characters for a string, a key and a tag; a byte string's
/// hex counts two characters per byte.
#[test]
fn strings_keys_and_tags_are_within_the_string_limit() {
    const MAX: usize = 16 * 1024 * 1024;
    assert!(Text::new("x".repeat(MAX)).is_ok());
    assert_eq!(Text::new("x".repeat(MAX + 1)).unwrap_err().code, ErrorCode::StringTooLong);
    assert_eq!(Value::string("x".repeat(MAX + 1)).unwrap_err().code, ErrorCode::StringTooLong);
    // Characters, not bytes: 16 Mi two-byte characters fit.
    assert!(Text::new("ä".repeat(MAX)).is_ok());
    assert!(ByteString::new(vec![0u8; MAX / 2]).is_ok());
    assert_eq!(ByteString::new(vec![0u8; MAX / 2 + 1]).unwrap_err().code, ErrorCode::StringTooLong);
    let long_key = "k".repeat(MAX + 1);
    assert_eq!(Record::new().insert(long_key.as_str(), 1).unwrap_err().code, ErrorCode::KeyTooLong);
    assert_eq!(Value::record([(long_key, Value::from(1))]).unwrap_err().code, ErrorCode::KeyTooLong);
    assert_eq!(Tag::new(&format!("T{}", "a".repeat(MAX))).unwrap_err().code, ErrorCode::TagTooLong);
    // A tag that breaks the tag rule is invalid-tag, whatever its length.
    assert_eq!(Tag::new(&"a".repeat(MAX + 1)).unwrap_err().code, ErrorCode::InvalidTag);
    // Smaller limits.
    let small = Limits { max_string_length: 3, ..Limits::default() };
    assert_eq!(Text::with_limits("abcd", &small).unwrap_err().code, ErrorCode::StringTooLong);
    assert!(Text::with_limits("äöü", &small).is_ok());
}

/// 256 levels, counted as spec §7 counts values built in code: a record
/// payload shares its tag's level.
#[test]
fn containers_are_within_the_depth_limit() {
    let nested = |levels: usize, wrap: &dyn Fn(Value) -> Result<Value, haus::ValueError>| {
        (0..levels).try_fold(Value::from(1), |v, _| wrap(v))
    };
    let array = |v| Value::array(vec![v]);
    let record = |v| Value::record([("a", v)]);
    let payload = |v| Value::variant("T", vec![v]);
    let record_payload = |v| Value::variant("T", vec![Value::record([("a", v)])?]);
    for wrap in [&array as &dyn Fn(Value) -> _, &record, &payload, &record_payload] {
        let at_limit = nested(256, wrap).unwrap();
        assert_eq!(at_limit.depth(), 256);
        assert_eq!(wrap(at_limit).unwrap_err().code, ErrorCode::NestingTooDeep);
    }
    // Inserting into a record checks the depth too, and leaves it as it was.
    let mut r = Record::new();
    let deep = nested(256, &array).unwrap();
    assert_eq!(r.insert("a", deep).unwrap_err().code, ErrorCode::NestingTooDeep);
    assert!(r.is_empty());
    // An empty container is a level.
    assert_eq!((Value::array(vec![]).unwrap().depth(), Value::from(Tag::new("T").unwrap()).depth()), (1, 0));
    // With a lower limit.
    let three = Limits { max_depth: 3, ..Limits::default() };
    let two = List::with_limits(vec![Value::array(vec![]).unwrap()], &three).unwrap();
    assert_eq!(List::with_limits(vec![two.clone().into(), Value::array(vec![]).unwrap()], &three).unwrap().depth(), 3);
    assert_eq!(
        List::with_limits(vec![Value::array(vec![two.into()]).unwrap()], &three).unwrap_err().code,
        ErrorCode::NestingTooDeep
    );
}

#[test]
fn records_have_each_key_once() {
    // A record grows one key at a time, past the few keys compared directly.
    let mut r = Record::new();
    for i in 0..1000 {
        r.insert(format!("k{i}"), i).unwrap();
    }
    for i in [0, 31, 32, 33, 999] {
        let e = r.insert(format!("k{i}"), 0).unwrap_err();
        assert_eq!((e.code, e.reason), (ErrorCode::DuplicateKey, format!("duplicate key 'k{i}'")));
    }
    assert_eq!(r.len(), 1000);
    assert_eq!(r.get("k500"), Some(&Value::from(500)));
    assert_eq!(r.keys().take(3).collect::<Vec<_>>(), ["k0", "k1", "k2"]);
    // A copy, and a record from fields, grow the same way.
    let mut copy = r.clone();
    assert!(copy == r && copy.insert("k7", 0).is_err() && copy.insert("new", 0).is_ok());
    let mut built = Record::from_fields(r.clone()).unwrap();
    assert!(built.insert("k999", 0).is_err() && built.insert("k1000", 0).is_ok());
    // A map's keys are unique already.
    let map = BTreeMap::from([("b".to_owned(), Value::from(1)), ("a".to_owned(), Value::from(2))]);
    assert_eq!(canonical(&Value::from(Record::try_from(map).unwrap())), "{a:2,b:1}");
    let fields: Vec<(String, Value)> = Record::try_from(vec![("x".to_owned(), Value::from(1))]).unwrap().into_fields();
    assert_eq!(fields, [("x".to_owned(), Value::from(1))]);
}

#[test]
fn values_convert_from_native_values() -> Result<(), haus::ValueError> {
    let v = Value::array(vec![
        Value::from(1u8),
        Value::try_from("s")?,
        Value::try_from(String::from("t"))?,
        Value::try_from(vec![0x0bu8, 0xff])?,
        Value::from(false),
        Value::from(Tag::new("None")?),
        Value::variant("Some", vec![Value::from(2)])?,
        Value::record([("a", Value::from(1))])?,
    ])?;
    assert_eq!(canonical(&v), r#"[1,"s","t",x"0bff",False,None,Some(2),{a:1}]"#);
    let items = v.as_array().unwrap();
    assert_eq!(items[1].as_str(), Some("s"));
    assert_eq!(items[0].as_number().map(Number::as_str), Some("1"));
    assert_eq!(items[3].as_bytes(), Some(&[0x0b, 0xff][..]));
    assert_eq!(items[6].as_variant().map(|(tag, args)| (tag.as_str(), args.len())), Some(("Some", 1)));
    assert_eq!(items[7].as_record().and_then(|r| r.get("a")), items[7].get("a"));
    // `{:?}` shows numbers and tags as they are written.
    assert_eq!(format!("{:?}", items[6]), "Variant { tag: Some, args: [Number(2)] }");
    assert_eq!(format!("{:?}", items[7]), r#"Record({"a": Number(1)})"#);
    // Records take what converts, checked.
    let mut r = Record::new();
    r.insert("name", "Ada")?;
    r.insert("tags", vec![Value::from(1)])?;
    assert_eq!(canonical(&r.into()), "{name:\"Ada\",tags:[1]}");
    Ok(())
}

#[test]
fn constructor_errors_have_the_form_of_spec_17() {
    let e = Value::number("01").unwrap_err();
    assert_eq!(e.docs(), "https://haus-fmt.org/docs/errors#invalid-number");
    assert_eq!(e.hint(), ErrorCode::InvalidNumber.hint());
    assert!(
        e.to_json().starts_with(r#"{"code":"invalid-number","message":"invalid number '01': not a number literal""#)
    );
    // Into the other errors, at the root of the value.
    let encode: haus::EncodeError = e.clone().into();
    assert_eq!((encode.code, encode.place()), (ErrorCode::InvalidNumber, "$".to_owned()));
    assert_eq!(haus::Error::from(e).code(), Some(ErrorCode::InvalidNumber));
}

/// A value at every default limit is written, and read back by a reader
/// with the default limits; writing, the canonical form, hashing, equality
/// and order give a result, never an error (their signatures have none).
#[test]
fn a_value_at_every_limit_is_written_and_read_back() {
    let integer = Value::number(&format!("-{}", "9".repeat(999))).unwrap();
    let exponent = Value::number("1e-6144").unwrap();
    let deep = (0..255).fold(Value::array(vec![integer.clone(), exponent.clone()]).unwrap(), |v, i| match i % 2 {
        0 => Value::record([("a", v)]).unwrap(),
        _ => Value::variant("T", vec![v, Value::from(1)]).unwrap(),
    });
    assert_eq!(deep.depth(), 256);
    for v in [integer, exponent, deep] {
        let (compact, minimised): (String, String) = (haus::ser::write(&v), haus::ser::write_minimised(&v));
        let json: String = haus::to_haus_json(&v);
        assert!(haus::equals(&haus::parse_one(&compact).unwrap(), &v));
        assert!(haus::equals(&haus::parse_one(&minimised).unwrap(), &v));
        assert!(haus::equals(&haus::from_haus_json(&json).unwrap(), &v));
        let canonical: String = canonical(&v);
        assert!(haus::equals(&haus::parse_one(&canonical).unwrap(), &v));
        let same: bool = haus::equals(&v, &v.clone());
        let order: std::cmp::Ordering = haus::compare(&v, &v);
        assert!(same && order.is_eq());
        #[cfg(feature = "hash")]
        {
            let hash: String = haus::hash(&v);
            assert_eq!(hash.len(), 64);
        }
    }
}

/// Runs `f` in a thread with a 512 KiB stack (a secondary thread's default on macOS).
fn in_512_kib_thread(f: impl FnOnce() + Send + 'static) {
    std::thread::Builder::new().stack_size(512 * 1024).spawn(f).unwrap().join().unwrap();
}

/// The host's hooks on a value at the deepest depth the binding supports
/// (spec §7) don't overflow a small stack: dropping, cloning, `==` and
/// `{:?}`, which shows the first `DEBUG_DEPTH` levels; nor do the writers.
#[test]
fn the_deepest_values_drop_clone_compare_print_and_write_in_a_small_thread() {
    in_512_kib_thread(|| {
        let deep = |n: usize| {
            (0..n).fold(Value::from(1), |v, i| match i % 3 {
                0 => Value::array(vec![v]).unwrap(),
                1 => Value::record([("a", v)]).unwrap(),
                _ => Value::variant("A", vec![v]).unwrap(),
            })
        };
        let (a, b) = (deep(haus::MAX_SUPPORTED_DEPTH), deep(haus::MAX_SUPPORTED_DEPTH));
        let copy = a.clone();
        assert!(copy == a && a == b && a != deep(haus::MAX_SUPPORTED_DEPTH - 1));
        let shown = format!("{a:?}");
        assert!(shown.contains('…') && shown.len() < 10_000, "{shown:.100}");
        assert!(format!("{a:#?}").contains('…'));
        assert!(haus::ser::write(&a).len() > haus::MAX_SUPPORTED_DEPTH);
        assert!(haus::to_haus_json(&a).len() > haus::MAX_SUPPORTED_DEPTH);
        drop((a, b, copy));
    });
}

#[test]
fn a_million_levels_of_json_drop_clone_compare_and_print_in_a_small_thread() {
    use haus::json::Json;
    in_512_kib_thread(|| {
        let deep = |n: usize| {
            (0..n).fold(Json::Null, |j, i| match i % 2 {
                0 => Json::Array(vec![j]),
                _ => Json::object([("a", j)]).unwrap(),
            })
        };
        let (a, b) = (deep(1_000_000), deep(1_000_000));
        let copy = a.clone();
        assert!(copy == a && a == b && a != deep(999_999));
        assert!(format!("{a:?}").contains('…') && format!("{a:#?}").contains('…'));
        drop((a, b, copy));
    });
}

/// `{:?}` shows the first `DEBUG_DEPTH` levels as derived, then `…`.
#[test]
fn debug_output_is_cut_at_debug_depth() {
    let wrap = |v| Value::array(vec![v]).unwrap();
    let deep = (0..haus::DEBUG_DEPTH + 1).fold(Value::from(1), |v, _| wrap(v));
    let shown = format!("{deep:?}");
    let opened = "Array([".repeat(haus::DEBUG_DEPTH);
    assert_eq!(shown, format!("{opened}…{}", "])".repeat(haus::DEBUG_DEPTH)));
    // Within the depth, as derived.
    let shallow = (0..haus::DEBUG_DEPTH).fold(Value::from(1), |v, _| wrap(v));
    assert!(!format!("{shallow:?}").contains('…'));
}
