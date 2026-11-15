//! The catalogue's examples (spec/errors.haus, spec §17) of schema files
//! (`Schema`), of decoding (`Decode`) and of checking (`Check`): each has its
//! entry's code. haus-fmt checks the examples of syntax and lossless JSON.

use haus::Value;
use haus_schema::Schema;
use std::path::Path;

fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    match v.get(key) {
        Some(Value::String(s)) => s,
        _ => panic!("spec/errors.haus: no string {key}"),
    }
}

/// The codes an example gives, or None for one this crate doesn't run.
fn codes(example: &Value) -> Option<Vec<String>> {
    let Value::Variant { tag, args } = example else { panic!("an example is a tag") };
    let [arg] = args.as_slice() else { panic!("an example has one argument") };
    let schema = |s: &str| Schema::parse(s).unwrap_or_else(|e| panic!("{s:?}: {e}"));
    let value = |s: &str| haus::parse(s).unwrap_or_else(|e| panic!("{s:?}: {e}")).remove(0);
    Some(match tag.as_str() {
        "Schema" => {
            let Value::String(s) = arg else { panic!("a Schema example is a string") };
            match Schema::parse(s) {
                Err(e) => vec![e.code().to_string()],
                Ok(schema) => schema.warnings().iter().map(|w| w.code().to_string()).collect(),
            }
        }
        "Decode" => match schema(text(arg, "schema")).decode("Root", &value(text(arg, "data"))) {
            Err(e) => vec![e.code.to_string()],
            Ok(_) => vec!["no error".into()],
        },
        "Check" => schema(text(arg, "schema"))
            .check_text("Root", text(arg, "data"))
            .iter()
            .map(|i| i.code.to_string())
            .collect(),
        _ => return None,
    })
}

#[test]
fn examples_have_their_codes() {
    let source = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/errors.haus")).unwrap();
    let mut checked = 0;
    for entry in haus::parse(&source).unwrap() {
        let Value::Variant { args, .. } = &entry else { panic!("an entry is Code {{ … }}") };
        let fields = &args[0];
        let code = text(fields, "code");
        let Some(found) = codes(fields.get("example").unwrap()) else { continue };
        assert!(found.iter().any(|c| c == code), "{code}: the example gives {found:?}");
        checked += 1;
    }
    assert!(checked > 30, "{checked} examples");
}

#[test]
fn errors_have_hints_and_a_json_form() {
    let e = Schema::parse("type A = { at: Date }").unwrap_err();
    assert_eq!(e.code(), haus::ErrorCode::UnknownType);
    assert_eq!(e.hint(), "Import it with: import std/time (Date).");
    assert_eq!(
        e.to_json(),
        concat!(
            r#"{"code":"unknown-type","message":"unknown type Date (import it with: import std/time (Date))","#,
            r#""line":1,"column":16,"hint":"Import it with: import std/time (Date).","#,
            r#""docs":"https://haus-fmt.org/docs/errors#unknown-type"}"#
        )
    );
    let schema = Schema::parse("type Root = { qty: Int }").unwrap();
    let issue = &schema.check_text("Root", "{ qty: 1.5 }")[0];
    assert_eq!(issue.code, haus::ErrorCode::NotAnInteger);
    assert!(issue.to_json().starts_with(r#"{"code":"not-an-integer","message":"#), "{}", issue.to_json());
    assert!(issue.to_json().contains(r#""line":1,"column":8,"path":"$.qty""#), "{}", issue.to_json());
}
