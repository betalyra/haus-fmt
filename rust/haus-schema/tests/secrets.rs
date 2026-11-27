//! Secrets decoded with a schema (spec §15, "Secrets"): the generic decoder's
//! result hides them, and only an explicit call reveals them.

use haus::{Value, canonical};
use haus_schema::{Decoded, Schema};

const SCHEMA: &str = r#"
type Root = {
  user: String,
  key: Secret String,
  keys: Array (Secret String),
  vault: Map (Secret Int),
  backup: Maybe (Secret Bytes),
  login: Login,
  pair: Pair,
  plain: { n: Int },
}
type Login = < Password { hash: Secret String } | Token (Secret String) | Anonymous >
type Pair = closed < Pair String (Secret { pin: Int }) >
"#;

const DATA: &str = r#"{ user: "ada", key: "sk-123", keys: ["k-one", "k-two"], vault: { a: 4711, b: 4712 },
  backup: Some(x"c0ffee"), login: Password { hash: "h-secret" }, pair: Pair("visible", { pin: 9876 }), plain: { n: 1 } }"#;

/// Every secret of DATA, as its text shows it.
const SECRETS: [&str; 9] = ["sk-123", "k-one", "k-two", "4711", "4712", "c0ffee", "h-secret", "9876", "pin"];

fn decode(data: &str) -> (Schema, Decoded) {
    let schema = Schema::parse(SCHEMA).unwrap_or_else(|e| panic!("{e}"));
    let decoded = schema.decode("Root", &haus::parse_one(data).unwrap()).unwrap_or_else(|e| panic!("{e}"));
    (schema, decoded)
}

#[test]
fn a_secret_never_shows() {
    let (_, decoded) = decode(DATA);
    let (debug, display, pretty) = (format!("{decoded:?}"), decoded.to_string(), format!("{decoded:#?}"));
    for secret in SECRETS {
        for shown in [&debug, &display, &pretty] {
            assert!(!shown.contains(secret), "{secret} in {shown}");
        }
    }
    assert!(display.contains(r#"user:"ada""#) && display.contains(r#""visible""#), "{display}");
    assert_eq!(display.matches("<redacted>").count(), 8, "{display}");
    assert!(decoded.has_secret() && decoded.as_value().is_none());
    // The parts without a secret are plain values.
    let Decoded::Record(fields) = &decoded else { panic!("{decoded:?}") };
    let plain = fields.iter().find(|(k, _)| k == "plain").map(|(_, x)| x.as_value());
    assert_eq!(plain, Some(Some(&haus::parse_one("{ n: 1 }").unwrap())));
}

#[test]
fn revealing_and_encoding_give_the_secrets_in_full() {
    let (schema, decoded) = decode(DATA);
    let expected = canonical(&haus::parse_one(DATA).unwrap());
    assert_eq!(canonical(&decoded.clone().reveal()), expected);
    // Decode, then encode with the schema: refused, unless secrets are revealed;
    // then the same value, secrets and all.
    let refused = schema.encode("Root", &decoded).unwrap_err();
    assert_eq!(refused.code, haus::ErrorCode::CannotEncode);
    assert!(!refused.to_string().contains("secret-"), "{refused}");
    let reveal = haus_schema::EncodeOptions { reveal_secrets: true, ..Default::default() };
    let encoded = schema.encode_with("Root", &decoded, &reveal).unwrap();
    assert_eq!(canonical(&encoded), expected);
    assert_eq!(schema.decode("Root", &encoded).unwrap(), decoded);
    // The other cases of the variant.
    let token = DATA.replace(r#"Password { hash: "h-secret" }"#, r#"Token("t-secret")"#);
    let (_, decoded) = decode(&token);
    assert!(!format!("{decoded:?}{decoded}").contains("t-secret"));
    let encoded = schema.encode_with("Root", &decoded, &reveal).unwrap();
    assert_eq!(canonical(&encoded), canonical(&haus::parse_one(&token).unwrap()));
}

#[test]
fn a_value_without_secrets_is_a_plain_value() {
    let schema = Schema::parse("type Root = { id: Int, tags: Array String }").unwrap();
    let decoded = schema.decode("Root", &haus::parse_one(r#"{ id: 0x10, tags: ["a"] }"#).unwrap()).unwrap();
    assert!(!decoded.has_secret());
    assert_eq!(decoded.as_value().map(canonical).as_deref(), Some(r#"{id:16,tags:["a"]}"#));
    assert_eq!(decoded.to_string(), r#"{id:16,tags:["a"]}"#);
}

#[test]
fn a_whole_secret_and_secrets_in_secrets() {
    let schema = Schema::parse("type Root = Secret { inner: Secret String }").unwrap();
    let value = haus::parse_one(r#"{ inner: "deep" }"#).unwrap();
    let decoded = schema.decode("Root", &value).unwrap();
    assert!(matches!(decoded, Decoded::Secret(_)));
    assert_eq!((format!("{decoded:?}"), decoded.to_string()), ("Secret(<redacted>)".into(), "<redacted>".into()));
    assert_eq!(decoded.reveal(), value);
    // In a stream, each value on its own.
    let schema = Schema::parse("type Key = Secret String\ntype Root = Stream Key").unwrap();
    let values: Vec<Value> = haus::parse(r#""a1", "b2""#).unwrap();
    let decoded = schema.decode_stream("Root", &values).unwrap();
    assert_eq!(decoded.iter().map(ToString::to_string).collect::<Vec<_>>(), ["<redacted>", "<redacted>"]);
    assert_eq!(decoded.into_iter().map(Decoded::reveal).collect::<Vec<_>>(), values);
}
