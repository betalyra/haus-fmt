//! Errors in schemas: where they are and what they say.

use haus_build::{Codec, Packages, generate};

fn error(schema: &str) -> String {
    generate(schema, "test/schema", &[], &Packages::none()).expect_err("an error").to_string()
}

#[test]
fn syntax() {
    assert_eq!(error("type A = { a: String"), "1:21: expected '}', found end of file");
    assert_eq!(error("type A = { a String }"), "1:14: expected ':', found 'String'");
    assert_eq!(error("type a = String"), "1:6: expected a type name, found 'a'");
    assert_eq!(error("type A = closed [ ]"), "1:17: expected '{' or '<' after closed, found '['");
    assert_eq!(error("type A = String\n= Int"), "2:1: expected 'type' or 'import', found '='");
    // Where the comment starts, as in data files (spec §14).
    assert_eq!(error("/* never closed\ntype A = String"), "1:1: unterminated block comment");
}

#[test]
fn rules() {
    assert_eq!(error("type A = { a: String, a: Int }"), "1:23: duplicate field a");
    assert_eq!(error("type A = < X | X >"), "1:16: duplicate tag X");
    assert_eq!(error("type A = closed < >"), "1:17: a closed variant needs at least one tag");
    assert_eq!(error("type A = String\ntype A = Int"), "2:6: A is defined twice");
    assert_eq!(error("type A = Strin"), "1:10: unknown type Strin");
    assert_eq!(
        error("type A = { total: Money }"),
        "1:19: unknown type Money (import it with: import @haus-fmt/money (Money), and install @haus-fmt/money with your package manager)"
    );
    assert_eq!(
        error("type A = { at: LatLng }"),
        "1:16: unknown type LatLng (import it with: import @haus-fmt/geo (LatLng), and install @haus-fmt/geo with your package manager)"
    );
    assert_eq!(error("type A = Array"), "1:10: Array takes 1 argument(s), found 0");
    assert_eq!(error("type A = { a: b }"), "1:15: unknown type parameter b");
}

#[test]
fn spreads() {
    assert_eq!(
        error("type E r = < A | ...r >"),
        "1:21: row parameters (...r) aren't supported; spread a named type instead: ...UserEvent"
    );
    assert_eq!(error("type E = < A >\ntype B = < A | ...E >"), "2:19: duplicate tag A");
    assert_eq!(error("type E = { x: Int }\ntype B = < ...E >"), "2:15: E is not a variant, so it can't be spread here");
    assert_eq!(error("type B = < ...Missing >"), "1:15: unknown type Missing");
    assert_eq!(
        error("type P a = < A a >\ntype B = < ...P >"),
        "2:15: P has parameters (P a); only a type without parameters can be spread"
    );
    assert_eq!(
        error("type A = < X | ...B >\ntype B = < Y | ...A >"),
        "2:6: type B spreads itself (directly or through another type)"
    );
    // An imported std/time type is known, just not a variant.
    assert_eq!(
        error("import std/time (Date)\ntype B = < ...Date >"),
        "2:15: Date is not a variant, so it can't be spread here"
    );
    assert_eq!(error("type B = { ...Array }"), "1:15: Array is not a record, so it can't be spread here");
}

#[test]
fn imports() {
    assert_eq!(
        error("import std/time (Data)"),
        "1:18: std/time has no type Data (it has Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone)"
    );
    assert!(
        error("import @acme/ids (UserId)")
            .starts_with("1:1: can't import @acme/ids: package @acme/ids not found among this crate's dependencies")
    );
}

#[test]
fn codecs() {
    let e = generate(
        "type A = String",
        "test/schema",
        &[Codec { id: "test/schema#B".into(), path: "crate::B".into() }],
        &Packages::none(),
    )
    .unwrap_err();
    assert_eq!(
        e.to_string(),
        "a codec for test/schema#B, but the schema has no such type (it has test/schema#A, and the prelude's)"
    );
    // A codec for a prelude type without parameters is one for a type the schema has (spec §13.4).
    let decimal = [Codec { id: "prelude#Decimal".into(), path: "crate::Big".into() }];
    let code = generate("type A = { n: Decimal, ns: Array Decimal }", "test/schema", &decimal, &Packages::none());
    let code = code.unwrap();
    assert!(code.contains("pub n: <crate::Big as ::haus::Codec>::Target,"), "{code}");
    assert!(code.contains("pub ns: ::std::vec::Vec<<crate::Big as ::haus::Codec>::Target>,"), "{code}");
    for id in ["prelude#Array", "prelude#Nope"] {
        let codec = [Codec { id: id.into(), path: "crate::Big".into() }];
        assert!(generate("type A = Int", "test/schema", &codec, &Packages::none()).is_err(), "{id}");
    }
    // One codec per id.
    let twice = [
        Codec { id: "test/schema#A".into(), path: "crate::A".into() },
        Codec { id: "test/schema#A".into(), path: "crate::B".into() },
    ];
    let e = generate("type A = String", "test/schema", &twice, &Packages::none()).unwrap_err();
    assert_eq!(e.to_string(), "two codecs for test/schema#A: an id has one codec");
    // A mistake of the configuration, not of a schema or data: no code (spec §13.4).
    assert_eq!((e.code(), e.to_json()), (None, None));
}

#[test]
fn a_type_with_a_codec_is_named_after_its_host_type() {
    // Spec §13.4: decoding as the type runs its codec, so its name is the codec's
    // host type, and the type without the codec (the codec's Base) is `<Name>Base`.
    let cents = [Codec { id: "test/schema#Money".into(), path: "crate::Cents".into() }];
    let schema = "type Money = { amount: Decimal }\ntype Order = { total: Money }";
    let code = generate(schema, "test/schema", &cents, &Packages::none()).unwrap();
    assert!(code.contains("pub type Money = ::haus::Coded<crate::Cents>;"), "{code}");
    assert!(code.contains("pub struct MoneyBase {"), "{code}");
    assert!(code.contains("pub total: <crate::Cents as ::haus::Codec>::Target,"), "{code}");
    assert!(code.contains("impl MoneyBase {") && code.contains(r#"= "test/schema#Money";"#), "{code}");
    // Without a codec, the type has its own name.
    let code = generate(schema, "test/schema", &[], &Packages::none()).unwrap();
    assert!(code.contains("pub struct Money {") && !code.contains("MoneyBase"), "{code}");
    // A name the base would take is reported.
    let taken = generate(&format!("{schema}\ntype MoneyBase = String"), "test/schema", &cents, &Packages::none());
    assert_eq!(
        taken.unwrap_err().to_string(),
        "1:6: Money has a codec, so the type without it would be called MoneyBase, which is taken"
    );
}

#[test]
fn attributes() {
    assert_eq!(
        error("type A = { @deprecated(1) x: Int }"),
        "1:12: @deprecated takes at most one argument, a string: @deprecated(\"use email\")"
    );
    assert_eq!(
        error("@deprecated(\"a\", \"b\")\ntype A = Int"),
        "1:1: @deprecated takes at most one argument, a string: @deprecated(\"use email\")"
    );
    assert_eq!(error("type A = { @deprecated @deprecated(\"x\") x: Int }"), "1:24: @deprecated is written twice here");
    assert_eq!(
        error("type A = { @deprecated (\"x\") x: Int }"),
        "1:23: expected '(' right after the attribute's name, without a space, found ' '"
    );
    assert_eq!(
        error("type B = { x: Int }\ntype A = { @deprecated ...B }"),
        "2:12: a spread can't have attributes; the fields or tags of B keep their own"
    );
    assert_eq!(error("type A = < @deprecated() X >"), "1:23: empty parentheses: write @deprecated without them");
    assert_eq!(
        error("type A = < @x(1, ) X | @y(tru) Y >"),
        "1:27: in the arguments of @y: unexpected identifier 'tru': lowercase identifiers can only be record keys"
    );
    assert_eq!(
        error("type A = { @deprecated(\"x\" x: Int }"),
        "1:28: in the arguments of @deprecated: expected ',' between top-level values, found 'x'"
    );
    assert_eq!(
        error("@deprecated\nimport std/time (Date)"),
        "2:1: expected 'type' after the attributes, found 'import'"
    );
}

#[test]
fn prelude_and_recursion() {
    assert_eq!(error("type Any = Int"), "1:6: Any is a prelude type and can't be redefined");
    assert_eq!(error("type Secret a = a"), "1:6: Secret is a prelude type and can't be redefined");
    assert_eq!(error("type A = Any Int"), "1:10: Any takes 0 argument(s), found 1");
    assert_eq!(error("type A = { key: Secret }"), "1:17: Secret takes 1 argument(s), found 0");
    let unguarded = "refers to itself without a record field, array element or variant payload in between";
    assert!(error("type A = B\ntype B = A").starts_with(&format!("1:6: A {unguarded}")));
    assert!(error("type A = Secret A").contains(unguarded));
    assert!(error("type Id a = a\ntype A = Id A").contains(unguarded));
    // Through a payload, a field or an element, recursion is fine.
    for ok in
        ["type A = Maybe A", "type A = { a?: A }", "type A = Array (Secret A)", "type Id a = a\ntype A = Id (Array A)"]
    {
        generate(ok, "test/schema", &[], &Packages::none()).unwrap_or_else(|e| panic!("{ok}: {e}"));
    }
}

#[test]
fn unknown_attributes_are_warnings() {
    let warnings = |schema: &str| -> Vec<String> {
        haus_build::check(schema).unwrap_or_else(|e| panic!("{e}")).iter().map(ToString::to_string).collect()
    };
    assert_eq!(
        warnings("@since(\"1.2\")\ntype A = { @example(1, [True]) n: Int, @deprecated m?: Int }"),
        [
            "1:1: unknown attribute @since: this version of haus ignores it",
            "2:12: unknown attribute @example: this version of haus ignores it"
        ]
    );
    // An unknown attribute may be repeated: a later version may allow that.
    assert_eq!(warnings("type A = < @x @x X >").len(), 2);
    assert_eq!(
        warnings("@deprecated(\"use B\")\ntype A = Int\ntype B = Int\ntype C = { a: A }"),
        ["4:15: A is deprecated: use B"]
    );
    assert!(warnings("type A = Int").is_empty());
}

#[test]
fn a_deprecated_type_used_in_a_spread_type_is_reported_once() {
    let warnings = haus_build::check(
        "@deprecated\ntype Old = Int
type Base = { old: Old }
type A = { ...Base }
type B = { ...Base, b: Int }
\
         type E = < X Old >\ntype F = < ...E | Y >",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let warnings: Vec<String> = warnings.iter().map(ToString::to_string).collect();
    assert_eq!(warnings, ["3:20: Old is deprecated", "6:14: Old is deprecated"]);
}

#[test]
fn a_spread_of_a_deprecated_type_is_a_use() {
    let warnings = haus_build::check(
        "@deprecated(\"use Event\")\ntype OldEvent = < A | B >
type Event = < ...OldEvent | X >
@deprecated
type OldBase = { id: Int }
type Item = { ...OldBase, x: Int }
type Both = closed { ...Item, y: Int }
@deprecated
type Older = { ...OldBase }",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    let warnings: Vec<String> = warnings.iter().map(ToString::to_string).collect();
    // Once where each spread is written: not again where Item is spread, nor inside a deprecated type.
    assert_eq!(warnings, ["3:19: OldEvent is deprecated: use Event", "6:18: OldBase is deprecated"]);
}

#[test]
fn attribute_arguments_may_hold_any_text() {
    // Non-ASCII text in comments and strings inside the parentheses.
    for schema in [
        "@deprecated(/* ä */ \"x\")\ntype A = Int",
        "@deprecated(\"größer\" // ü\n)\ntype A = Int",
        "@deprecated(\"\"\"\n  für ü\\\"\n  \"\"\")\ntype A = Int",
    ] {
        haus_build::check(schema).unwrap_or_else(|e| panic!("{schema:?}: {e}"));
    }
    // Wrong or unterminated, with non-ASCII text: an error, not a panic.
    for schema in [
        "@deprecated(\"\\ü\")\ntype A = Int",
        "@deprecated(/* ä",
        "@deprecated(\"\"\"\nü",
        "@deprecated(\"ü",
        "@deprecated(\"\\ü",
    ] {
        assert!(haus_build::check(schema).is_err(), "{schema:?}");
    }
}

#[test]
fn deprecated_items_get_rust_attributes() {
    let code = generate(
        "@deprecated(\"use Customer\")\ntype Client = { id: Int, @deprecated(\"use email\") mail?: String }\n\
         type Shape = < Circle Float64 | @deprecated Square Float64 >",
        "test/schema",
        &[],
        &Packages::none(),
    )
    .unwrap();
    assert!(code.contains("#[deprecated(note = \"use Customer\")]\n#[derive(Debug, Clone, PartialEq)]\n#[allow(deprecated)]\npub struct Client"), "{code}");
    assert!(
        code.contains(
            "#[deprecated(note = \"use email\")]\n    pub mail: ::std::option::Option<::std::string::String>"
        ),
        "{code}"
    );
    assert!(code.contains("#[deprecated]\n    Square(f64)"), "{code}");
    assert_eq!(code.matches("#[allow(deprecated)]\nimpl").count(), 10, "{code}");
}

#[test]
fn any_and_secret() {
    let code = generate("type A = { key: Secret String, extra: Any }", "test/schema", &[], &Packages::none()).unwrap();
    assert!(code.contains("pub key: ::haus::Secret<::std::string::String>"), "{code}");
    assert!(code.contains("pub extra: ::haus::Value"), "{code}");
    assert!(
        code.contains("::haus::de::secret(\n                        x,\n                        __d,\n                        \"Secret String\","),
        "{code}"
    );
}

#[test]
fn inline_types_in_a_whole_maybe_or_secret_are_named_after_the_definition() {
    // `Maybe` and `Secret` add nothing to the name of an inline type, so as
    // the whole type of a definition they would take the definition's own.
    let text = "type InPlace = Maybe (closed < None | Some Int32 >)\ntype Key = Secret { id: Int }\n\
                type Rec = { note: Maybe { text: String } }";
    let rust = generate(text, "test/schema", &[], &Packages::none()).unwrap();
    for part in [
        "pub type InPlace = ::std::option::Option<InPlaceValue>;",
        "pub enum InPlaceValue {",
        "pub type Key = ::haus::Secret<KeyValue>;",
        "pub struct KeyValue {",
        // Elsewhere, the name of the place.
        "pub note: ::std::option::Option<RecNote>,",
    ] {
        assert!(rust.contains(part), "{part}\n{rust}");
    }
    let roc = haus_build::roc::generate(text, "Schema", "test/schema", &[], &Packages::none()).unwrap();
    for part in ["decode_in_place_item", "decode_key_value", "decode_rec_note_item"] {
        assert!(roc.contains(part), "{part}\n{roc}");
    }
}
