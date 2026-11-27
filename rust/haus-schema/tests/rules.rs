//! Package rules (packages.md §4, §6, §7), and packages and files as values
//! (§2, §3): a compile takes values only, checks each reached package's
//! `rules` field, and requires an implementation of every rule the schema
//! reaches, unless its package is taken shape-only (`missing-codec`).
//! Decoding checks the rules on the values the schema decoded.

use haus::{ErrorCode, Rule, Value};
use haus_schema::{Options, Package, PackageRule, Schema, Sources, rules};

/// `@acme/codes`: `Code` has the rule `iso`, three capital letters.
struct Iso;

impl Rule for Iso {
    const ID: &'static str = "@acme/codes@1#Code";
    const NAME: &'static str = "iso";
    fn check(value: &Value) -> Result<(), String> {
        match value.as_variant() {
            Some((tag, [])) if tag.len() == 3 && tag.bytes().all(|b| b.is_ascii_uppercase()) => Ok(()),
            _ => Err(format!("{} is not three capital letters", haus::canonical(value))),
        }
    }
}

const CODES: &str =
    "type Code = < >\ntype Label = String\ntype Order = { lines: Array Line }\ntype Line = { code: Code }";

fn codes(manifest_rules: &str) -> Package {
    let manifest = format!("{{ name: \"@acme/codes\", version: \"1.0.0\", rules: {manifest_rules} }}");
    Package::make(&manifest, CODES).unwrap()
}

/// The schema `text` (the file `app.schema.haus`), compiled with `packages`.
fn compile(text: &str, packages: impl IntoIterator<Item = Package>) -> Result<Schema, haus_schema::Error> {
    let sources = Sources::make("app.schema.haus", [("app.schema.haus", text)])?.with_packages(packages)?;
    Schema::compile(&sources)
}

const APP: &str = "import @acme/codes@1 (Code)\ntype Root = { code: Code }";

#[test]
fn a_reached_rule_needs_an_implementation() {
    let e = compile(APP, [codes(r#"{ "Code": "iso" }"#)]).unwrap_err();
    assert_eq!(e.code(), Some(ErrorCode::MissingCodec));
    assert_eq!(
        e.reason(),
        "@acme/codes@1#Code has the rule iso, and this program has no implementation of it: add the package's rule \
         (with_rule), or take the package shape-only (shape_only)"
    );
    // Supplied, or taken shape-only.
    assert!(compile(APP, [codes(r#"{ "Code": "iso" }"#).with_rule::<Iso>()]).is_ok());
    assert!(compile(APP, [codes(r#"{ "Code": "iso" }"#).shape_only()]).is_ok());
}

#[test]
fn only_the_rules_the_schema_reaches_are_required() {
    let rules = r#"{ "Code": "iso", "Label": "short" }"#;
    // Label is reached, Code isn't: only Label's rule is missing.
    let e = compile("import @acme/codes@1 (Label)\ntype Root = { l: Label }", [codes(rules)]).unwrap_err();
    assert!(e.reason().contains("@acme/codes@1#Label") && !e.reason().contains("#Code"), "{e}");
    // Reached through another of the package's types.
    let e = compile("import @acme/codes@1 (Order)\ntype Root = { o: Order }", [codes(r#"{ "Code": "iso" }"#)]);
    assert_eq!(e.unwrap_err().code(), Some(ErrorCode::MissingCodec));
    // Imported but used by no definition: still reached by nothing.
    assert!(compile("import @acme/codes@1 (Code)\ntype Root = Int", [codes(r#"{ "Code": "iso" }"#)]).is_ok());
}

#[test]
fn decoding_checks_the_rule_on_the_value_decoded() {
    let text = "import @acme/codes@1 (Code)\ntype Root = { code: Code, key?: Secret Code }";
    let schema = compile(text, [codes(r#"{ "Code": "iso" }"#).with_rule::<Iso>()]).unwrap();
    let decode = |text: &str| schema.decode("Root", &haus::parse_one(text).unwrap());
    assert!(decode("{ code: EUR }").is_ok());
    let e = decode("{ code: Eur }").unwrap_err();
    assert_eq!((e.code, e.path_string()), (ErrorCode::CodecRejected, "$.code".to_owned()));
    assert_eq!(e.message, "Eur is not three capital letters (the rule iso of @acme/codes@1#Code)");
    // Inside a secret: at the secret, without the value.
    let e = decode("{ code: EUR, key: Eur }").unwrap_err();
    assert_eq!((e.code, e.path_string()), (ErrorCode::InvalidSecret, "$.key".to_owned()));
    assert!(!e.message.contains("Eur"));
    // The checker reports it too, at its place.
    let issues = schema.check_text("Root", "{ code: Usd }");
    assert_eq!(issues.iter().map(|i| i.code).collect::<Vec<_>>(), [ErrorCode::CodecRejected]);
    // Shape-only: not checked.
    let loose = compile(text, [codes(r#"{ "Code": "iso" }"#).shape_only()]).unwrap();
    assert!(loose.decode("Root", &haus::parse_one("{ code: Eur }").unwrap()).is_ok());
}

#[test]
fn encoding_refuses_what_a_rule_rejects_and_secrets() {
    let text = "import @acme/codes@1 (Code)\ntype Root = { code: Code, key?: Secret String }";
    let schema = compile(text, [codes(r#"{ "Code": "iso" }"#).with_rule::<Iso>()]).unwrap();
    let decoded = schema.decode("Root", &haus::parse_one("{ code: EUR, key: \"sk\" }").unwrap()).unwrap();
    let e = schema.encode("Root", &decoded).unwrap_err();
    assert_eq!((e.code, e.path_string()), (ErrorCode::CannotEncode, "$.key".to_owned()));
    let reveal = haus_schema::EncodeOptions { reveal_secrets: true, ..Default::default() };
    let value = schema.encode_with("Root", &decoded, &reveal).unwrap();
    assert_eq!(haus::canonical(&value), r#"{code:EUR,key:"sk"}"#);
    let wrong = haus_schema::Decoded::Value(haus::parse_one("{ code: Eur }").unwrap());
    assert_eq!(schema.encode("Root", &wrong).unwrap_err().code, ErrorCode::CannotEncode);
}

#[test]
fn the_rules_field_is_checked_when_the_package_is_reached() {
    let manifest_error = |rules: &str| {
        let e = compile(APP, [codes(rules).shape_only()]).unwrap_err();
        assert_eq!(e.code(), Some(ErrorCode::PackageManifest), "{rules}: {e}");
        e.reason().to_owned()
    };
    assert!(manifest_error(r#"{ "Kode": "iso" }"#).contains("Kode"));
    assert!(manifest_error(r#""iso""#).contains("@acme/codes"));
    assert!(manifest_error(r#"{ "Code": ["iso"] }"#).contains("Code"));
    assert!(manifest_error(r#"{ "Code": "Iso_4217" }"#).contains("Iso_4217"));
    let generic = Package::make(
        r#"{ name: "@acme/codes", version: "1.0.0", rules: { "Pair": "ordered" } }"#,
        "type Code = < >\ntype Pair a = { a: a }\ntype Log = Stream Code",
    )
    .unwrap();
    let e = compile(APP, [generic]).unwrap_err();
    assert!(e.code() == Some(ErrorCode::PackageManifest) && e.reason().contains("Pair"), "{e}");
    // A package no import reaches is not checked.
    let other = Package::make(r#"{ name: "@acme/other", version: "1.0.0", rules: 1 }"#, "type X = Int").unwrap();
    assert!(compile("type Root = Int", [other]).is_ok());
}

#[test]
fn packages_given_as_values_have_one_name_each() {
    let a = codes(r#"{ "Code": "iso" }"#);
    let changed = Package::make(r#"{ name: "@acme/codes", version: "1.0.0" }"#, "type Code = String").unwrap();
    let sources = Sources::make("app.schema.haus", [("app.schema.haus", APP)]).unwrap().with_package(a.clone());
    let e = sources.unwrap().with_package(changed).unwrap_err();
    assert_eq!(e.code(), Some(ErrorCode::DuplicatePackage));
    // A copy is one package, with the program's choices for both.
    assert!(compile(APP, [a.clone(), a.shape_only()]).is_ok());
}

#[test]
fn files_made_from_data_import_each_other_inside_the_root() {
    let make = |files: &[(&str, &str)]| Sources::make("app.schema.haus", files.iter().copied());
    let sources = make(&[
        ("app.schema.haus", "import ./sub/common (Id)\ntype Root = { id: Id }"),
        ("sub/common.schema.haus", "import ../more (N)\ntype Id = N"),
        ("more.schema.haus", "type N = Int"),
    ])
    .unwrap();
    let schema = Schema::compile(&sources).unwrap();
    assert!(schema.decode("Root", &haus::parse_one("{ id: 1 }").unwrap()).is_ok());
    let e = Schema::compile(&make(&[("app.schema.haus", "import ../up (X)\ntype R = X")]).unwrap()).unwrap_err();
    assert_eq!(e.code(), Some(ErrorCode::ImportOutsideRoot));
    let e = Schema::compile(&make(&[("app.schema.haus", "import ./gone (X)\ntype R = X")]).unwrap()).unwrap_err();
    assert_eq!(e.code(), Some(ErrorCode::ImportNotFound));
    assert_eq!(make(&[("other.schema.haus", "")]).unwrap_err().code(), Some(ErrorCode::ImportNotFound));
}

#[test]
fn tools_point_out_the_rules_they_dont_check() {
    let text = "import std/time (Date)\nimport @acme/codes@1 (Code)\ntype Root = { code: Code, d: Date }";
    let sources = Sources::make("app.schema.haus", [("app.schema.haus", text)])
        .unwrap()
        .with_package(codes(r#"{ "Code": "iso" }"#))
        .unwrap();
    let options = Options { require_rules: false, ..Options::default() };
    let schema = haus_schema::Schema::compile_options(&sources, &options).unwrap();
    let notes = rules::unchecked_rules(text, &schema);
    let shown: Vec<(Option<(usize, usize)>, &str)> = notes.iter().map(|n| (n.position(), n.reason())).collect();
    assert_eq!(shown, [(Some((2, 1)), "the rules of @acme/codes (Code: iso) are not checked here")]);
    assert!(notes.iter().all(|n| n.code() == Some(ErrorCode::MissingCodec)));
    // With the rule built in, nothing to point out.
    let schema = Schema::compile_with(&sources, &[PackageRule::of::<Iso>()]).unwrap();
    assert!(rules::unchecked_rules(text, &schema).is_empty());
}
