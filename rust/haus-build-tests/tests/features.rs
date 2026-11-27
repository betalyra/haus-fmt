//! The code haus-fmt-build generates, for every kind of type (features.schema.haus, next to Cargo.toml).

mod features {
    haus::include_schema!("features");
}

use features::{AppEvent, ByName, Dims, Item, Kind, Login, Person, Scores, Shape, Tree, Vault};
use haus::{DecodeError, Error, Unknown, Value, from_str, to_string};

const ADA: &str = r#"{ name: "Ada", email: Some("ada@example.com"), type: Member { since: Date("1843-01-01") }, createdAt: Instant("2026-11-09T14:30:00Z"), address: { street: "St James's Square", city: "London" }, scores: { maths: 100 }, check: Ok(7), friends: [], shape: Circle(1.5), tree: Node(Leaf, Node(Leaf, Leaf)) }"#;

fn decode_error<T: haus::Decode + std::fmt::Debug>(text: &str) -> DecodeError {
    match from_str::<T>(text) {
        Err(Error::Decode(e)) => e,
        other => panic!("expected a decode error, got {other:?}"),
    }
}

/// `v` written with its secrets revealed (spec §15).
fn revealed(v: &(impl haus::Encode + ?Sized)) -> Result<String, haus::EncodeError> {
    haus::to_string_with(v, haus::Encoder::default().reveal_secrets())
}

#[test]
fn decodes_into_rust_types() {
    let ada: Person = from_str(ADA).unwrap();
    assert_eq!(ada.name, "Ada");
    assert_eq!(ada.nickname, None);
    assert_eq!(ada.email.as_deref(), Some("ada@example.com"));
    assert!(matches!(&ada.r#type, Kind::Member { since } if since.as_str() == "1843-01-01"));
    assert_eq!(ada.created_at.as_str(), "2026-11-09T14:30:00Z");
    assert_eq!(ada.address.city, "London");
    assert_eq!(ada.scores["maths"], 100);
    assert_eq!(ada.check, Ok(7));
    assert_eq!(ada.shape, Shape::Circle(1.5));
    assert_eq!(
        ada.tree,
        Tree::Node(Box::new(Tree::Leaf), Box::new(Tree::Node(Box::new(Tree::Leaf), Box::new(Tree::Leaf))))
    );
}

#[test]
fn encodes_back_to_the_same_text() {
    let ada: Person = from_str(ADA).unwrap();
    assert_eq!(to_string(&ada).unwrap(), ADA);
}

#[test]
fn recursion_and_generics() {
    let with_best = ADA.replace("friends: []", &format!("friends: [{ADA}], best: {ADA}"));
    let ada: Person = from_str(&with_best).unwrap();
    assert_eq!(ada.friends[0].name, "Ada");
    assert_eq!(ada.best.as_ref().map(|b| b.name.as_str()), Some("Ada"));

    let scores: Scores = from_str(r#"{ items: [1, 2, 3], next: "page-2" }"#).unwrap();
    assert_eq!(scores.items.iter().map(haus::Int::to_i128).collect::<Vec<_>>(), [Some(1), Some(2), Some(3)]);
    assert_eq!(scores.next.as_deref(), Some("page-2"));
}

#[test]
fn open_variants_keep_unknown_tags() {
    let shape: Shape = from_str("Triangle(1, 2, 3)").unwrap();
    let three = ["1", "2", "3"].map(|n| Value::number(n).unwrap()).to_vec();
    assert_eq!(shape, Shape::Unknown(Unknown { tag: "Triangle".parse().unwrap(), args: three }));
    assert_eq!(to_string(&shape).unwrap(), "Triangle(1, 2, 3)");
}

#[test]
fn errors_say_where() {
    let unknown = decode_error::<Person>(&ADA.replace("Member { since: Date(\"1843-01-01\") }", "Guest"));
    assert_eq!(unknown.to_string(), ".type: unknown tag Guest; expected one of Admin, Member");

    let date = decode_error::<Person>(&ADA.replace("1843-01-01", "1843-02-30"));
    assert_eq!(
        date.to_string(),
        r#".type(Member).since(Date)[0]: "1843-02-30" is not a valid Date: 1843-02 has no day 30"#
    );

    let range = decode_error::<Person>(&ADA.replace("maths: 100", "maths: 300"));
    assert_eq!(range.to_string(), ".scores.maths: 300 is out of range for Int8 (-128 to 127)");

    let closed = decode_error::<Person>(&ADA.replace("{ name", "{ age: 36, name"));
    assert_eq!(closed.to_string(), ".age: unknown field \"age\" in a closed record");
    assert_eq!((closed.code, closed.place().as_str()), (haus::ErrorCode::UnknownField, "$.age"));

    let missing = decode_error::<Person>(&ADA.replace("name: \"Ada\", ", ""));
    assert_eq!(missing.to_string(), "missing field name");
    assert_eq!(missing.code, haus::ErrorCode::MissingField);
    assert_eq!(unknown.code, haus::ErrorCode::UnknownTag);
    assert_eq!((date.code, date.place().as_str()), (haus::ErrorCode::InvalidTime, "$.type.since[0]"));
    assert_eq!(
        (range.code, range.expected(), range.found()),
        (haus::ErrorCode::OutOfRange, Some("Int8 (-128 to 127)"), Some("300"))
    );

    let deep = decode_error::<Person>(&ADA.replace("Node(Leaf, Leaf)", "Node(Leaf, 1)"));
    assert_eq!(deep.to_string(), ".tree(Node)[1](Node)[1]: expected a variant (Tree), found the number 1");
}

#[test]
fn stream_errors_start_with_the_index_of_the_value() {
    let place = |e: Error| match e {
        Error::Decode(e) => e.place(),
        other => panic!("expected a decode error, got {other:?}"),
    };
    let items = r#"{ id: 0, label: "a" }, { id: 1, label: "b" }, { id: 2, label: "c" }, { id: "3", label: "d" },"#;
    assert_eq!(place(haus::from_str_all::<Item>(items).unwrap_err()), "$[3].id");
    let first_error = haus::stream::decode::<Item, _>(items.as_bytes()).find_map(Result::err).unwrap();
    assert_eq!(place(first_error), "$[3].id");

    let shapes = "Circle(1.0), Circle(2.0), Rect(1.0, 2.0), Rect(1.0, \"2\"),";
    assert_eq!(place(haus::from_str_all::<Shape>(shapes).unwrap_err()), "$[3][1]");
    // Int is a string in schema-based JSON (spec §16.3): the number 3 is the mistake.
    let lines = r#"{"id":"0","label":"a"}
{"id":"1","label":"b"}
{"id":"2","label":"c"}
{"id":3,"label":"d"}
"#;
    assert_eq!(place(haus::json::from_str_all::<Item>(lines).unwrap_err()), "$[3].id");
    let first_error = haus::json::decode::<Item, _>(lines.as_bytes()).find_map(Result::err).unwrap();
    assert_eq!(place(first_error), "$[3].id");
}

#[test]
fn wrong_payloads_are_reported_at_the_variant_with_what_the_tag_takes() {
    // A record case given one value that isn't a record: the payload is wrong, not the value (spec §15).
    let record = decode_error::<Person>(&ADA.replace("Member { since: Date(\"1843-01-01\") }", "Member(1)"));
    assert_eq!((record.code, record.place().as_str()), (haus::ErrorCode::WrongPayload, "$.type"));
    assert_eq!(record.hint(), "Member takes one argument, a record { since: Date }: write `Member { … }`.");
    let positional = decode_error::<Person>(&ADA.replace("Circle(1.5)", "Rect(1.5)"));
    assert_eq!((positional.code, positional.place().as_str()), (haus::ErrorCode::WrongPayload, "$.shape"));
    assert_eq!(positional.hint(), "Rect takes 2 arguments (Float64, Float64): write `Rect(…, …)`.");
    let bare = decode_error::<Tree>("Leaf(1)");
    assert_eq!(bare.hint(), "Leaf takes no payload: write `Leaf`.");
}

#[test]
fn spreads_copy_tags_and_fields() {
    let event: AppEvent = from_str(r#"Failed { reason: "timeout" }"#).unwrap();
    assert!(matches!(&event, AppEvent::Failed { reason } if reason == "timeout"));
    assert!(matches!(from_str::<AppEvent>("Placed { order: 7 }").unwrap(), AppEvent::Placed { .. }));
    // AppEvent is closed, although BaseEvent (which it spreads) is open.
    assert!(from_str::<AppEvent>("Shipped").is_err());

    let item: Item = from_str(r#"{ id: 1, label: "a" }"#).unwrap();
    assert_eq!(item.label, "a");
    assert_eq!(to_string(&item).unwrap(), r#"{ id: 1, label: "a" }"#);
    assert!(from_str::<Item>(r#"{ id: 1, label: "a", extra: 2 }"#).is_err());
}

#[test]
fn secrets_stay_hidden() {
    let text = r#"{ user: "ada", password: "hunter2", pin: 1234, extra: [1, Some { a: 19.90 }] }"#;
    let login: Login = from_str(text).unwrap();
    assert_eq!(login.password.expose(), "hunter2");
    assert_eq!(login.pin.as_ref().map(|p| *p.expose()), Some(1234));
    let debug = format!("{login:?}");
    assert!(debug.contains("password: <redacted>") && !debug.contains("hunter2") && !debug.contains("1234"), "{debug}");
    // Encoding refuses a secret, at its place, unless it reveals secrets:
    // then it writes them in full, and Any as it was.
    let refused = to_string(&login).unwrap_err();
    assert_eq!((refused.code, refused.place().as_str()), (haus::ErrorCode::CannotEncode, "$.password"));
    assert_eq!(revealed(&login).unwrap(), text);

    // Errors name the place and the type, never the value.
    let e = decode_error::<Login>(r#"{ user: "ada", password: 4711 }"#);
    assert_eq!(e.to_string(), ".password: not a valid Secret String (the value is hidden)");
    let e = decode_error::<Login>(r#"{ user: "ada", password: "x", pin: 98765 }"#);
    assert_eq!(e.to_string(), ".pin: not a valid Secret UInt16 (the value is hidden)");
    assert!(!e.to_string().contains("98765"));
}

#[test]
#[allow(deprecated)]
fn deprecated_fields_still_decode() {
    let login: Login = from_str(r#"{ user: "ada", password: "x", name: "Ada" }"#).unwrap();
    assert_eq!(login.name.as_deref(), Some("Ada"));
}

#[test]
#[allow(deprecated)]
fn deprecated_single_tag_variants_still_decode() {
    let legacy: features::Legacy = from_str("Only(7)").unwrap();
    assert_eq!(legacy.0.to_i128(), Some(7));
    assert_eq!(to_string(&legacy).unwrap(), "Only(7)");
}

#[test]
fn raw_values_are_checked_for_their_depth_where_they_are_put() {
    // Any and unknown variants hold a haus::Value: a haus value within the
    // limits it was built with (spec §7); encoding checks where it is put.
    let login = |extra: Value| Login { extra: Some(extra), ..from_str(r#"{ user: "ada", password: "x" }"#).unwrap() };
    let error = |v: &dyn haus::Encode| revealed(v).unwrap_err().to_string();
    let number = |n: &str| Value::number(n).unwrap();

    // Numbers are normalized when they are built, as the parser reads them.
    let numbers = Value::array(vec![number("1E5"), number("0xFF"), number("1_000")]).unwrap();
    assert_eq!(revealed(&login(numbers)).unwrap(), r#"{ user: "ada", password: "x", extra: [1e5, 255, 1000] }"#);
    // What is beyond the limits can't be built.
    assert_eq!(Value::number("1e6145").unwrap_err().code, haus::ErrorCode::ExponentTooLarge);
    // 256 levels as the field of a record: one too many.
    let deep = (0..256).fold(number("1"), |v, _| Value::array(vec![v]).unwrap());
    assert_eq!(
        error(&login(deep)).split_once(": ").map(|(_, why)| why.to_owned()),
        Some("nesting deeper than 256 levels".into())
    );

    // An unknown variant's tag and payload, at its place.
    let deep = (0..256).fold(number("1"), |v, _| Value::array(vec![v]).unwrap());
    let shape = Shape::Unknown(Unknown { tag: "Hexagon".parse().unwrap(), args: vec![number("1"), deep] });
    assert!(error(&shape).ends_with("nesting deeper than 256 levels"), "{}", error(&shape));

    // An encoder for a reader with lower limits: an integer longer than its number limit can't be encoded.
    let small = haus::Encoder::new(&haus::Limits { max_number_length: 20, ..haus::Limits::default() });
    let fits = haus::Int::from(99999999999999999999u128 as i128);
    assert_eq!(haus::to_string_with(&fits, small).unwrap(), "99999999999999999999");
    let big = haus::Int::from(4722366482869645213695i128); // 2^72 - 1
    assert_eq!(haus::to_string(&big).unwrap(), "4722366482869645213695");
    assert_eq!(haus::to_string_with(&big, small).unwrap_err().to_string(), "number literal longer than 20 characters");
}

/// A `Vault` whose secret keys hold `value` under the key `hunter2`.
fn vault(value: Value) -> Vault {
    Vault { owner: "ada".into(), keys: haus::Secret::new([("hunter2".to_owned(), value)].into()) }
}

#[test]
fn secrets_are_refused_unless_revealed_and_errors_inside_name_only_the_secret() {
    let ok = vault(Value::number("1E5").unwrap());
    let refused = to_string(&ok).unwrap_err();
    assert_eq!((refused.code, refused.place()), (haus::ErrorCode::CannotEncode, "$.keys".to_owned()));
    assert!(!refused.to_string().contains("1e5") && !refused.to_string().contains("hunter2"));
    let revealing = haus::Encoder::default().reveal_secrets();
    assert_eq!(haus::to_string_with(&ok, revealing).unwrap(), r#"{ owner: "ada", keys: { hunter2: 1e5 } }"#);
    let hidden = ".keys: not a valid Secret Map Any (the value is hidden)";
    let deep = (0..255).fold(Value::array(vec![]).unwrap(), |v, _| Value::array(vec![v]).unwrap());
    let v = vault(deep);
    for e in [haus::to_string_with(&v, revealing).unwrap_err(), haus::json::to_string_with(&v, revealing).unwrap_err()]
    {
        assert_eq!(e.to_string(), hidden);
    }
    // A Map key longer than the string limit, for a reader with small limits.
    let small = haus::Limits { max_string_length: 5, ..haus::Limits::default() };
    let e = haus::to_string_with(&vault(Value::array(vec![]).unwrap()), haus::Encoder::new(&small).reveal_secrets());
    assert_eq!(e.unwrap_err().to_string(), hidden);
}

/// A tree `depth` nodes deep along the first payload value.
fn deep_tree(depth: usize) -> Tree {
    (0..depth).fold(Tree::Leaf, |t, _| Tree::Node(Box::new(t), Box::new(Tree::Leaf)))
}

/// Dropped node by node: Rust drops a deep `Box` chain recursively.
fn dismantle(mut tree: Tree) {
    while let Tree::Node(first, _) = tree {
        tree = *first;
    }
}

#[test]
fn deep_native_values_fail_at_the_depth_limit() {
    // Each `Node(…, …)` is one level.
    let at_limit = deep_tree(256);
    assert!(to_string(&at_limit).is_ok() && haus::json::to_string(&at_limit).is_ok());
    dismantle(at_limit);
    let deeper = format!("{}: nesting deeper than 256 levels", "(Node)[0]".repeat(256));
    let beyond = deep_tree(257);
    assert_eq!(to_string(&beyond).unwrap_err().to_string(), deeper);
    dismantle(beyond);
    // Far deeper than the call stack takes: the encoder stops at the limit.
    let huge = deep_tree(1_000_000);
    assert_eq!(to_string(&huge).unwrap_err().to_string(), deeper);
    let json = haus::json::to_string(&huge).unwrap_err().to_string();
    assert!(json.ends_with(": nesting deeper than 256 levels"), "{json}");
    dismantle(huge);
}

#[test]
fn generated_keys_and_tags_count_against_the_string_limit() {
    // Written for a reader whose string limit is lower than a tag or key.
    let limits = |n: usize| haus::Encoder::new(&haus::Limits { max_string_length: n, ..haus::Limits::default() });
    let (leaf, tree) = (Tree::Leaf, Tree::Node(Box::new(Tree::Leaf), Box::new(Tree::Leaf)));
    assert!(haus::to_string_with(&leaf, limits(4)).is_ok());
    assert_eq!(haus::to_string_with(&leaf, limits(3)).unwrap_err().to_string(), "tag longer than 3 characters");
    assert_eq!(haus::to_string_with(&tree, limits(3)).unwrap_err().to_string(), "tag longer than 3 characters");
    let item = Item { id: haus::Int::from(1i64), label: String::new() };
    assert!(haus::to_string_with(&item, limits(5)).is_ok());
    assert_eq!(haus::to_string_with(&item, limits(4)).unwrap_err().to_string(), ".label: key longer than 4 characters");

    // Schema-based JSON counts them alike, on the haus value; the form's
    // member names (`_tag`, `values`) don't count.
    fn json<T: haus::ToJson>(x: &T, n: usize) -> Result<String, String> {
        let limits = haus::Limits { max_string_length: n, ..haus::Limits::default() };
        haus::json::to_string_with(x, haus::Encoder::new(&limits)).map_err(|e| e.to_string())
    }
    assert!(json(&leaf, 4).is_ok() && json(&tree, 4).is_ok());
    assert_eq!(json(&leaf, 3).unwrap_err(), "tag longer than 3 characters");
    assert_eq!(json(&tree, 3).unwrap_err(), "tag longer than 3 characters");
    assert!(json(&item, 5).is_ok());
    assert_eq!(json(&item, 4).unwrap_err(), ".label: key longer than 4 characters");
    // A record case whose record is a named type.
    let sized = ByName::Sized(Dims { w: 1, h: None });
    assert!(json(&sized, 5).is_ok());
    assert_eq!(json(&sized, 4).unwrap_err(), "tag longer than 4 characters");
}
