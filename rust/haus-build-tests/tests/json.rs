//! Plain JSON (spec §16.3) of the code haus-build generates (features.schema.haus).

mod features {
    haus::include_schema!("features");
}

use features::{AppEvent, Clash, Kind, Login, Nulls, Person, Scores, Shape, Tree};
use haus::json::{from_str, to_string};
use haus::{Error, Unknown, Value};

const ADA: &str = r#"{ name: "Ada", email: Some("ada@example.com"), type: Member { since: Date("1843-01-01") }, createdAt: Instant("2026-11-09T14:30:00Z"), address: { street: "St James's Square", city: "London" }, scores: { maths: 100 }, check: Ok(7), avatar: x"0b34", friends: [], shape: Circle(1.5), tree: Node(Leaf, Node(Leaf, Leaf)) }"#;

const ADA_JSON: &str = r#"{"name":"Ada","email":"ada@example.com","type":{"_tag":"Member","since":"1843-01-01"},"createdAt":"2026-11-09T14:30:00Z","address":{"street":"St James's Square","city":"London"},"scores":{"maths":100},"check":{"_tag":"Ok","value":7},"avatar":"CzQ=","friends":[],"shape":{"_tag":"Circle","value":1.5},"tree":{"_tag":"Node","values":[{"_tag":"Leaf"},{"_tag":"Node","values":[{"_tag":"Leaf"},{"_tag":"Leaf"}]}]}}"#;

fn read_error<T: haus::FromJson + haus::Encode + std::fmt::Debug>(json: &str) -> String {
    match from_str::<T>(json) {
        Err(Error::Decode(e)) => e.to_string(),
        other => panic!("expected a decode error, got {other:?}"),
    }
}

#[test]
fn writes_and_reads_plain_json() {
    let ada: Person = haus::from_str(ADA).unwrap();
    assert_eq!(to_string(&ada).unwrap(), ADA_JSON);
    assert_eq!(from_str::<Person>(ADA_JSON).unwrap(), ada);
    // Member order doesn't matter, and a missing optional field stays missing.
    let reordered = r#"{"tree":{"_tag":"Leaf"},"shape":{"_tag":"Rect","values":[1,2]},"friends":[],"check":{"_tag":"Err","value":"no"},"scores":{},"address":{"city":"Paris","street":"x"},"createdAt":"2026-11-09T14:30:00Z","type":{"_tag":"Admin"},"email":null,"name":"Bob"}"#;
    let bob: Person = from_str(reordered).unwrap();
    assert_eq!((bob.email, bob.nickname, bob.r#type), (None, None, Kind::Admin));
    assert_eq!(bob.check, Err("no".into()));
    assert_eq!(bob.shape, Shape::Rect(1.0, 2.0));
}

#[test]
fn generics_and_integers() {
    // Int is a string: many JSON parsers round integers beyond 2^53.
    let scores: Scores = from_str(r#"{"items":["1","-12","123456789012345678901234567890"]}"#).unwrap();
    assert_eq!(scores.items[2].as_str(), "123456789012345678901234567890");
    assert_eq!(to_string(&scores).unwrap(), r#"{"items":["1","-12","123456789012345678901234567890"]}"#);
    assert_eq!(
        read_error::<Scores>(r#"{"items":[1]}"#),
        ".items[0]: expected a string holding a decimal integer (Int), found the number 1"
    );
    assert_eq!(read_error::<Scores>(r#"{"items":["01"]}"#), ".items[0]: expected a decimal integer in a string (Int)");
}

#[test]
fn variants() {
    // A closed variant is a string only if none of its tags has a payload.
    // Kind is closed, but Member has a payload: every tag is an object.
    assert_eq!(to_string(&Kind::Admin).unwrap(), r#"{"_tag":"Admin"}"#);
    assert_eq!(from_str::<Kind>(r#"{"_tag":"Admin"}"#).unwrap(), Kind::Admin);
    assert!(from_str::<Kind>(r#""Admin""#).is_err());
    assert_eq!(to_string(&AppEvent::Ping).unwrap(), r#"{"_tag":"Ping"}"#);
    assert_eq!(
        read_error::<AppEvent>(r#"{"_tag":"Shipped"}"#),
        "._tag: unknown tag Shipped; expected one of Ping, Failed, Placed"
    );

    // Recursion through payloads.
    let tree: Tree = from_str(r#"{"_tag":"Node","values":[{"_tag":"Leaf"},{"_tag":"Leaf"}]}"#).unwrap();
    assert_eq!(tree, Tree::Node(Box::new(Tree::Leaf), Box::new(Tree::Leaf)));
    assert_eq!(
        read_error::<Tree>(r#"{"_tag":"Node","values":[{"_tag":"Leaf"}]}"#),
        ".values: expected 2 values, found 1"
    );
    assert_eq!(read_error::<Tree>(r#"{"_tag":"Leaf","value":1}"#), "unexpected member \"value\"");

    // Unknown tags of an open variant: the arguments in the lossless form.
    let hexagon = Shape::Unknown(Unknown { tag: "Hexagon".into(), args: vec![Value::Number("1".into())] });
    let json = r#"{"_tag":"Hexagon","args":[{"num":"1"}]}"#;
    assert_eq!(to_string(&hexagon).unwrap(), json);
    assert_eq!(from_str::<Shape>(json).unwrap(), hexagon);
    assert_eq!(read_error::<Shape>(r#"{"_tag":"Hexagon","args":[1]}"#).split_once(':').unwrap().0, ".args[0]");
    // A newer writer's case with a record payload: its other members read without a schema.
    let newer = from_str::<Shape>(r#"{"_tag":"Hexagon","side":1,"open":true}"#).unwrap();
    assert_eq!(haus::to_string(&newer).unwrap(), "Hexagon { side: 1, open: True }");
    assert_eq!(
        to_string(&newer).unwrap(),
        r#"{"_tag":"Hexagon","args":[{"rec":{"side":{"num":"1"},"open":{"tag":"True"}}}]}"#
    );
    assert_eq!(read_error::<Shape>(r#"{"_tag":"hexagon"}"#), "._tag: \"hexagon\" is not a tag name");
}

#[test]
fn maybe_is_null_only_when_its_inner_json_cant_be() {
    let nulls = |direct, nested, named| Nulls {
        direct: features::Holder { held: direct },
        nested: features::Holder { held: nested },
        named,
    };
    let cases = [
        (
            nulls(None, None, None),
            r#"{"direct":{"held":null},"nested":{"held":{"_tag":"None"}},"named":{"_tag":"None"}}"#,
        ),
        (
            nulls(Some(1), Some(None), Some(None)),
            r#"{"direct":{"held":1},"nested":{"held":{"_tag":"Some","value":null}},"named":{"_tag":"Some","value":null}}"#,
        ),
        (
            nulls(Some(1), Some(Some(2)), Some(Some(3))),
            r#"{"direct":{"held":1},"nested":{"held":{"_tag":"Some","value":2}},"named":{"_tag":"Some","value":3}}"#,
        ),
    ];
    for (value, json) in cases {
        assert_eq!(to_string(&value).unwrap(), json);
        assert_eq!(from_str::<Nulls>(json).unwrap(), value);
    }
    assert!(from_str::<Nulls>(r#"{"direct":{"held":null},"nested":{"held":null},"named":null}"#).is_err());
}

#[test]
fn a_tag_field_in_a_record_payload_has_no_plain_form() {
    let clash = Clash::Tagged { _tag: "x".into() };
    let why = "Tagged has a field named _tag, so it has no plain JSON form";
    assert_eq!(to_string(&clash).unwrap_err().to_string(), why);
    assert_eq!(read_error::<Clash>(r#"{"_tag":"Tagged"}"#), why);
    // The other tags are fine.
    assert_eq!(to_string(&Clash::Fine(1)).unwrap(), r#"{"_tag":"Fine","value":1}"#);
}

#[test]
fn secrets_stay_hidden() {
    let login: Login =
        haus::from_str(r#"{ user: "ada", password: "hunter2", pin: 1234, extra: [1, Some { a: 19.90 }] }"#).unwrap();
    let json = r#"{"user":"ada","password":"hunter2","pin":1234,"extra":[{"num":"1"},{"tag":"Some","args":[{"rec":{"a":{"num":"19.90"}}}]}]}"#;
    // Written in full; Any in the lossless form.
    assert_eq!(to_string(&login).unwrap(), json);
    assert_eq!(from_str::<Login>(json).unwrap(), login);

    // Errors name the place and the type, never the value.
    let e = read_error::<Login>(r#"{"user":"ada","password":4711}"#);
    assert_eq!(e, ".password: not a valid Secret String (the value is hidden)");
    let e = read_error::<Login>(r#"{"user":"ada","password":"x","pin":98765}"#);
    assert_eq!(e, ".pin: not a valid Secret UInt16 (the value is hidden)");
    let e = read_error::<haus::Secret<std::collections::BTreeMap<String, u8>>>(r#"{"hunter2": 300}"#);
    assert!(!e.contains("hunter2") && !e.contains("300"), "{e}");
}

#[test]
fn json_lines() {
    let shapes = vec![Shape::Circle(1.0), Shape::Rect(2.0, 0.5)];
    let lines = haus::json::to_string_all(&shapes).unwrap();
    assert_eq!(lines, "{\"_tag\":\"Circle\",\"value\":1}\n{\"_tag\":\"Rect\",\"values\":[2,0.5]}\n");
    assert_eq!(haus::json::from_str_all::<Shape>(&lines).unwrap(), shapes);

    let mut out = Vec::new();
    haus::json::encode(&mut out, &shapes).unwrap();
    assert_eq!(String::from_utf8(out).unwrap(), lines);
    let read: Vec<Shape> = haus::json::decode(lines.as_bytes()).collect::<Result<_, _>>().unwrap();
    assert_eq!(read, shapes);

    // Errors say which line or value.
    let bad = "{\"_tag\":\"Circle\",\"value\":1}\n{\"_tag\":\"Circle\",\"value\":\"x\"}\n";
    let e = haus::json::from_str_all::<Shape>(bad).unwrap_err().to_string();
    assert_eq!(e, "[1].value: expected a number, \"NaN\", \"Infinity\" or \"-Infinity\" (Float64), found a string");
    let e = haus::json::decode::<Shape, _>("{\"_tag\":\"Circle\",\"value\":1}\n{oops}\n".as_bytes())
        .find_map(Result::err)
        .unwrap();
    assert_eq!(e.to_string(), "expected a member name, found 'o' at 2:2");
}
