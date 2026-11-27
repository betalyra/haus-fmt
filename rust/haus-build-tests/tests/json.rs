//! Schema-based JSON (spec §16.3) of the code haus-fmt-build generates (features.schema.haus).

mod features {
    haus::include_schema!("features");
}

use features::{
    AppEvent, ByAlias, ByName, Clash, ClashByName, Dims, Generic, Inline, Kind, Login, Nulls, Person, Scores, Shape,
    TagField, Tree, Wrapper,
};
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
fn writes_and_reads_schema_based_json() {
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
        "unknown tag Shipped; expected one of Ping, Failed, Placed"
    );

    // Recursion through payloads.
    let tree: Tree = from_str(r#"{"_tag":"Node","values":[{"_tag":"Leaf"},{"_tag":"Leaf"}]}"#).unwrap();
    assert_eq!(tree, Tree::Node(Box::new(Tree::Leaf), Box::new(Tree::Leaf)));
    assert_eq!(
        read_error::<Tree>(r#"{"_tag":"Node","values":[{"_tag":"Leaf"}]}"#),
        "expected 2 values in \"values\", found 1"
    );
    assert_eq!(read_error::<Tree>(r#"{"_tag":"Leaf","value":1}"#), ".value: unexpected member \"value\"");

    // Unknown tags of an open variant: the arguments' self-describing values.
    let hexagon = Shape::Unknown(Unknown { tag: "Hexagon".parse().unwrap(), args: vec![Value::from(1)] });
    let json = r#"{"_tag":"Hexagon","_args":[{"_num":"1"}]}"#;
    assert_eq!(to_string(&hexagon).unwrap(), json);
    assert_eq!(from_str::<Shape>(json).unwrap(), hexagon);
    assert_eq!(read_error::<Shape>(r#"{"_tag":"Hexagon","_args":[1]}"#).split_once(':').unwrap().0, "._args[0]");
    // A newer writer's case with a record payload: its other members read by the import.
    let newer = from_str::<Shape>(r#"{"_tag":"Hexagon","side":1,"open":true}"#).unwrap();
    assert_eq!(haus::to_string(&newer).unwrap(), "Hexagon { side: 1, open: True }");
    assert_eq!(
        to_string(&newer).unwrap(),
        r#"{"_tag":"Hexagon","_args":[{"_rec":{"side":{"_num":"1"},"open":{"_tag":"True"}}}]}"#
    );
    // `args` is a member like any other.
    let run = from_str::<Shape>(r#"{"_tag":"Run","args":["a"]}"#).unwrap();
    assert_eq!(haus::to_string(&run).unwrap(), r#"Run { args: ["a"] }"#);
    assert_eq!(
        read_error::<Shape>(r#"{"_tag":"hexagon"}"#),
        "\"hexagon\" is not a tag name (A to Z, then letters, digits and _)"
    );
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
fn a_tag_or_args_field_in_a_record_payload_has_no_schema_based_form() {
    let clash = Clash::Tagged { _tag: "x".into() };
    let why = "Tagged has a field named _tag, so it has no schema-based JSON form";
    assert_eq!(to_string(&clash).unwrap_err().to_string(), why);
    assert_eq!(read_error::<Clash>(r#"{"_tag":"Tagged"}"#), why);
    let listed = Clash::Listed { _args: vec![1] };
    let why = "Listed has a field named _args, so it has no schema-based JSON form";
    assert_eq!(to_string(&listed).unwrap_err().to_string(), why);
    assert_eq!(read_error::<Clash>(r#"{"_tag":"Listed","_args":[1]}"#), why);
    // The other tags are fine.
    assert_eq!(to_string(&Clash::Fine(1)).unwrap(), r#"{"_tag":"Fine","value":1}"#);
}

/// Decodes `text` as `T`, writes it as schema-based JSON, reads that back and
/// encodes it: the JSON, and the haus value it reads back as.
fn json_of<T: haus::Decode + haus::Encode + haus::ToJson + haus::FromJson>(
    text: &str,
) -> Result<(String, Value), String> {
    let x: T = haus::from_str(text).map_err(|e| e.to_string())?;
    let json = to_string(&x).map_err(|e| e.to_string())?;
    let back = from_str::<T>(&json).map_err(|e| e.to_string())?;
    Ok((json, haus::Encode::encode(&back).map_err(|e| e.to_string())?))
}

#[test]
fn a_record_case_is_the_same_inline_and_by_name() {
    // Spec §15: `Sized { … }`, `Sized Dims`, `Sized DimsAlias2` (an alias
    // chain), `Seal (Id Sealed)` and `Held (Wrapper Int32)` (applied generic
    // types) are the same record case: the same haus values, the same JSON.
    let values = ["Sized { w: 1 }", "Sized { w: 1, h: 2 }", "Seal { id: 3 }", "Held { inner: 4 }", "Other(5)"];
    for text in values {
        let inline = json_of::<Inline>(text).unwrap();
        assert_eq!(json_of::<ByName>(text).unwrap(), inline, "{text}");
        assert_eq!(json_of::<ByAlias>(text).unwrap(), inline, "{text}");
        assert_eq!(inline.1, haus::from_str::<Value>(text).unwrap(), "{text}");
    }
    let (json, _) = json_of::<ByName>("Sized { w: 1, h: 2 }").unwrap();
    assert_eq!(json, r#"{"_tag":"Sized","w":1,"h":2}"#);
    // Rust keeps each form: a struct-like case inline, a tuple case by name.
    assert_eq!(haus::from_str::<ByName>("Held { inner: 4 }").unwrap(), ByName::Held(Wrapper { inner: 4 }));
    assert_eq!(haus::from_str::<ByAlias>("Sized { w: 1 }").unwrap(), ByAlias::Sized(Dims { w: 1, h: None }));
    // Reading: other members are ignored by an open record and an error in a closed one, as inline.
    let open = r#"{"_tag":"Sized","w":1,"x":2}"#;
    assert_eq!(from_str::<ByName>(open).unwrap(), ByName::Sized(Dims { w: 1, h: None }));
    let closed = r#"{"_tag":"Seal","id":1,"x":2}"#;
    for e in [read_error::<Inline>(closed), read_error::<ByName>(closed), read_error::<ByAlias>(closed)] {
        assert!(e.contains("unknown member \"x\""), "{e}");
    }
    let missing = r#"{"_tag":"Sized","value":{"w":1}}"#;
    for e in [read_error::<Inline>(missing), read_error::<ByName>(missing), read_error::<ByAlias>(missing)] {
        assert!(e.contains("missing member w"), "{e}");
    }
    // Decoding haus: any payload but one record is wrong, as for `Sized { … }`.
    for text in ["Sized(1)", "Sized(1, 2)", "Sized"] {
        let codes = [
            haus::from_str::<Inline>(text).unwrap_err(),
            haus::from_str::<ByName>(text).unwrap_err(),
            haus::from_str::<ByAlias>(text).unwrap_err(),
        ]
        .map(|e| e.code());
        assert_eq!(codes, [Some(haus::ErrorCode::WrongPayload); 3], "{text}");
    }
    // A type parameter is never a record case, even where its argument is a record.
    let (json, _) = json_of::<Generic<Dims>>("Sized { w: 1 }").unwrap();
    assert_eq!(json, r#"{"_tag":"Sized","value":{"w":1}}"#);
    // A record by name with a field named _tag has no schema-based form either.
    let clash = ClashByName::Tagged(TagField { _tag: "x".into() });
    let why = "Tagged has a field named _tag, so it has no schema-based JSON form";
    assert_eq!(to_string(&clash).unwrap_err().to_string(), why);
    assert_eq!(read_error::<ClashByName>(r#"{"_tag":"Tagged"}"#), why);
}

#[test]
fn secrets_stay_hidden() {
    let login: Login =
        haus::from_str(r#"{ user: "ada", password: "hunter2", pin: 1234, extra: [1, Some { a: 19.90 }] }"#).unwrap();
    let json = r#"{"user":"ada","password":"hunter2","pin":1234,"extra":[{"_num":"1"},{"_tag":"Some","_args":[{"_rec":{"a":{"_num":"19.90"}}}]}]}"#;
    // Refused unless secrets are revealed, at the secret (spec §15); then
    // written in full; Any as its self-describing value, without the envelope.
    assert_eq!(to_string(&login).unwrap_err().place(), "$.password");
    let reveal = haus::Encoder::default().reveal_secrets();
    assert_eq!(haus::json::to_string_with(&login, reveal).unwrap(), json);
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
