//! Values built in code (spec §11, "Values built in code"): the constructors
//! build only haus values, rejecting anything else with the code of the
//! mistake, and normalize numbers as the parser reads them.

use haus::{ErrorCode, Number, Record, Tag, Value, canonical};
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
    // No limits: a longer number than any reader takes is a number.
    let long = Number::new(&format!("0x{}", "f".repeat(2000))).unwrap();
    assert!(long.len() > 2000 && long.bytes().all(|d| d.is_ascii_digit()));
    assert_eq!(Number::new("1e99999999999999999999").unwrap(), "1e99999999999999999999");
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
    // Values change in place; keys don't.
    *r.get_mut("k1").unwrap() = Value::from("one");
    r.values_mut().for_each(|v| *v = Value::from(true));
    assert_eq!(r.get("k1"), Some(&Value::from(true)));
    // A map's keys are unique already.
    let map = BTreeMap::from([("b".to_owned(), Value::from(1)), ("a".to_owned(), Value::from(2))]);
    assert_eq!(canonical(&Value::from(Record::from(map))), "{a:2,b:1}");
    let fields: Vec<(String, Value)> = Record::try_from(vec![("x".to_owned(), Value::from(1))]).unwrap().into_fields();
    assert_eq!(fields, [("x".to_owned(), Value::from(1))]);
}

#[test]
fn values_convert_from_native_values() {
    let v = Value::from(vec![
        Value::from(1u8),
        Value::from("s"),
        Value::from(String::from("t")),
        Value::from(vec![0x0bu8, 0xff]),
        Value::from(false),
        Value::from(Tag::new("None").unwrap()),
        Value::variant("Some", vec![Value::from(2)]).unwrap(),
        Value::record([("a", Value::from(1))]).unwrap(),
    ]);
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

/// Runs `f` in a thread with a 512 KiB stack (a secondary thread's default on macOS).
fn in_512_kib_thread(f: impl FnOnce() + Send + 'static) {
    std::thread::Builder::new().stack_size(512 * 1024).spawn(f).unwrap().join().unwrap();
}

/// The host's hooks on a value built in code of any depth (spec §7) don't
/// overflow a small stack: dropping, cloning, `==` and `{:?}`, which shows
/// the first `DEBUG_DEPTH` levels.
#[test]
fn a_million_levels_drop_clone_compare_and_print_in_a_small_thread() {
    in_512_kib_thread(|| {
        let deep = |n: usize| {
            (0..n).fold(Value::from(1), |v, i| match i % 3 {
                0 => Value::Array(vec![v]),
                1 => Value::record([("a", v)]).unwrap(),
                _ => Value::variant("A", vec![v]).unwrap(),
            })
        };
        let (a, b) = (deep(1_000_000), deep(1_000_000));
        let copy = a.clone();
        assert!(copy == a && a == b && a != deep(999_999));
        let shown = format!("{a:?}");
        assert!(shown.contains('…') && shown.len() < 10_000, "{shown:.100}");
        assert!(format!("{a:#?}").contains('…'));
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
    let deep = (0..haus::DEBUG_DEPTH + 1).fold(Value::from(1), |v, _| Value::Array(vec![v]));
    let shown = format!("{deep:?}");
    let opened = "Array([".repeat(haus::DEBUG_DEPTH);
    assert_eq!(shown, format!("{opened}…{}", "])".repeat(haus::DEBUG_DEPTH)));
    // Within the depth, as derived.
    let shallow = (0..haus::DEBUG_DEPTH).fold(Value::from(1), |v, _| Value::Array(vec![v]));
    assert!(!format!("{shallow:?}").contains('…'));
}
