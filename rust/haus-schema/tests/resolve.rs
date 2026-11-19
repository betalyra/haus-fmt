//! Schema files with their imports (spec §13.3, §14), and what decoding
//! gives (spec §15) beyond the conformance suite.

use haus::{Value, canonical};
use haus_schema::{Explicit, Options, Schema};
use std::path::{Path, PathBuf};

fn fixture(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(path)
}

fn resolver() -> Explicit {
    Explicit::new().package(fixture("acme-ids")).unwrap()
}

fn error(schema: &str) -> String {
    Schema::parse(schema).expect_err("an error").to_string()
}

fn value(text: &str) -> Value {
    haus::parse(text).unwrap_or_else(|e| panic!("{e}")).remove(0)
}

/// The decoded value, canonical, or the error.
fn decode(schema: &Schema, ty: &str, text: &str) -> String {
    match schema.decode(ty, &value(text)) {
        Ok(v) => canonical(&v),
        Err(e) => format!("error: {e}"),
    }
}

#[test]
fn imports_files_and_packages() {
    let schema = Schema::load(fixture("app.schema.haus"), &resolver()).unwrap_or_else(|e| panic!("{e}"));
    let ok = r#"{ user: UserId(7), home: { street: "Main", at: Point(1, 2.50) }, since: Date("2026-11-13"), label: { tag: "x", value: "y" } }"#;
    assert_eq!(
        decode(&schema, "Root", ok),
        r#"{home:{at:Point(1,2.5),street:"Main"},label:{tag:"x",value:"y"},since:Date("2026-11-13"),user:UserId(7)}"#
    );
    let wrong = r#"{ user: UserId(7), home: { street: "Main", at: Point(1, "2") }, since: Date("2026-11-13"), label: { tag: "x", value: 1 } }"#;
    assert_eq!(decode(&schema, "Root", wrong), r#"error: expected Float64, found the string "2" at $.home.at[1]"#);

    // Ids come from the manifest (spec §13.3).
    let ids: Vec<&str> = schema.imported().iter().map(|d| d.id.as_str()).collect();
    assert!(ids.contains(&"@acme/ids@1#UserId") && ids.contains(&"common#Address"), "{ids:?}");
    assert_eq!(schema.definition("Address").unwrap().doc, "A postal address.");
}

#[test]
fn import_errors() {
    let load = |text: &str| {
        let path = fixture("app.schema.haus");
        let options = Options { packages: &resolver(), path: Some(&path), ..Options::default() };
        Schema::parse_with(text, &options).expect_err("an error").to_string()
    };
    assert_eq!(
        load("import @acme/ids@2 (UserId)"),
        "1:1: @acme/ids@2 wants major version 2, but version 1.2.0 was found"
    );
    assert_eq!(
        load("import @acme/ids (Nope)"),
        "1:19: @acme/ids has no type Nope (it has UserId, Tagged, IdEvent, Base)"
    );
    assert_eq!(load("import ./common (Address)\nimport ./common (Address)"), "2:18: Address is imported twice");
    assert_eq!(load("import ./common (Address)\ntype Address = Int"), "2:6: type Address is already imported");
    assert!(load("import ./missing (A)").starts_with("1:1: can't import ./missing: file not found: "));
    assert_eq!(
        load("import @acme/other (A)"),
        "1:1: can't import @acme/other: package @acme/other is not among the packages given"
    );
    assert_eq!(
        Schema::load(fixture("cycle-a.schema.haus"), &resolver()).unwrap_err().reason(),
        "./cycle-b (1:1): import cycle: ./cycle-a imports this file again"
    );
    // An error inside an imported file is reported at the import, with its place in that file.
    assert_eq!(
        Schema::load(fixture("uses-broken.schema.haus"), &resolver()).unwrap_err().reason(),
        "./broken (1:20): unknown type Strin"
    );
    assert_eq!(
        error("import @acme/ids (UserId)"),
        "1:1: can't import @acme/ids: no package locator (only std modules and files can be imported here)"
    );
    assert_eq!(
        error("import std/money (Money)"),
        "1:1: std/money is no longer a standard module; it is the package @haus-fmt/money: import @haus-fmt/money (Money)"
    );
    assert_eq!(
        error("import std/time (Data)"),
        "1:18: std/time has no type Data (it has Date, Time, DateTime, Instant, ZonedDateTime, Duration, YearMonth, TimeZone)"
    );
}

#[test]
fn spreads_of_imported_types() {
    let parse = |text: &str| Schema::parse_with(text, &Options { packages: &resolver(), ..Options::default() });
    let schema = parse(
        "import @acme/ids (IdEvent, Base)
         type Event = closed < ...IdEvent | Ping >
         type Alias = Base
         type Person = closed { ...Alias, name: String }
         type Root = { e: Event, p: Person }",
    )
    .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(
        decode(&schema, "Root", r#"{ e: Created { id: 1 }, p: { id: 2, name: "Ada" } }"#),
        r#"{e:Created{id:1},p:{id:2,name:"Ada"}}"#
    );
    assert_eq!(
        decode(&schema, "Root", r#"{ e: Other, p: { id: 2, name: "Ada" } }"#).split(" at ").next(),
        Some("error: Other is not allowed here: expected one of Created, Deleted, Ping.")
    );
    assert_eq!(
        decode(&schema, "Root", r#"{ e: Ping, p: { id: 2, name: "Ada", x: 1 } }"#),
        "error: x is not a field of this closed record. at $.p.x"
    );
    // A copied tag keeps its attributes (spec §14).
    let hints: Vec<String> = schema
        .check_text("Root", r#"{ e: Deleted { id: 1 }, p: { id: 2, name: "Ada" } }"#)
        .iter()
        .map(|i| i.message.clone())
        .collect();
    assert_eq!(hints, ["Deleted is deprecated"]);

    let error = |text: &str| parse(text).expect_err("an error").to_string();
    assert_eq!(error("import @acme/ids (IdEvent)\ntype E = < Created | ...IdEvent >"), "2:25: duplicate tag Created");
    assert_eq!(
        error("import @acme/ids (Base)\ntype E = < ...Base >"),
        "2:15: Base is not a variant, so it can't be spread here"
    );
    assert_eq!(
        error("import @acme/ids (Tagged)\ntype E = { ...Tagged }"),
        "2:15: Tagged has parameters (Tagged a); only a type without parameters can be spread"
    );
}

#[test]
fn spreads_of_types_that_are_not_records_or_variants() {
    // A std/time type that is imported is known: the error is the spread, not the name.
    assert_eq!(
        error("import std/time (Date)\ntype T = < A | ...Date >"),
        "2:19: Date is not a variant, so it can't be spread here"
    );
    assert_eq!(
        error("import std/time (Date)\ntype T = { a: Int, ...Date }"),
        "2:23: Date is not a record, so it can't be spread here"
    );
    assert_eq!(error("type T = { ...Maybe }"), "1:15: Maybe is not a record, so it can't be spread here");
    assert_eq!(error("type T = { ...Array }"), "1:15: Array is not a record, so it can't be spread here");
    assert_eq!(error("type T = < ...Int >"), "1:15: Int is not a variant, so it can't be spread here");
    // Through an alias, the alias is what isn't one.
    assert_eq!(error("type R = Int\ntype T = { ...R }"), "2:15: R is not a record, so it can't be spread here");
    assert_eq!(
        error("import std/time (Date)\ntype D = Date\ntype T = < ...D >"),
        "3:15: D is not a variant, so it can't be spread here"
    );
    // Not imported: unknown, with how to import it.
    assert_eq!(error("type T = { ...Date }"), "1:15: unknown type Date (import it with: import std/time (Date))");
}

#[test]
fn rules_about_names_and_types() {
    assert_eq!(error("type A = Strin"), "1:10: unknown type Strin");
    assert_eq!(
        error("type A = { total: Money }"),
        "1:19: unknown type Money (import it with: import @haus-fmt/money (Money), and install @haus-fmt/money with your package manager)"
    );
    assert_eq!(error("type A = { at: Date }"), "1:16: unknown type Date (import it with: import std/time (Date))");
    assert_eq!(error("type A = Array"), "1:10: Array takes 1 argument(s), found 0");
    assert_eq!(error("type P a = { x: a }\ntype A = P"), "2:10: P takes 1 argument(s), found 0");
    assert_eq!(error("type A = Int String"), "1:10: Int takes 0 argument(s), found 1");
    assert_eq!(error("type A = { a: b }"), "1:15: unknown type parameter b");
    assert_eq!(
        error("type E = Stream Int\ntype A = { e: E }"),
        "2:15: E is a Stream; a stream can only be the whole file, not part of a type"
    );
    assert_eq!(error("type A = Array (Stream Int)"), "1:17: Stream is only allowed as the whole type of a definition");
    assert_eq!(
        error("type T a = < Leaf a | Node (T (Array a)) >"),
        "1:29: T must refer to itself with its own parameters (T a); other arguments could grow without bound"
    );
}

#[test]
fn generic_and_recursive_types() {
    let schema = Schema::parse(
        "type List a = < Nil | Cons a (List a) >
         type Pair a b = { first: a, second: b }
         type Root = Pair (List Int) (Maybe (List String))",
    )
    .unwrap();
    assert_eq!(decode(&schema, "Root", "{ first: Cons(1, Nil), second: None }"), "{first:Cons(1,Nil),second:None}");
    assert_eq!(
        decode(&schema, "Root", r#"{ first: Cons(1, Nil), second: Some(Cons(2, Nil)) }"#),
        r#"error: expected String, found the number 2 at $.second[0][0]"#
    );
    assert_eq!(decode(&schema, "List", "Nil"), "error: List needs arguments, so it can't describe a whole file at $");
}

/// Parses `schema`, which must fail fast (well under a second) with growing-recursion: the code, position and message.
fn growing(schema: &str) -> ((usize, usize), String) {
    let start = std::time::Instant::now();
    let e = Schema::parse(schema).expect_err("an error");
    assert!(start.elapsed() < std::time::Duration::from_secs(1), "took {:?}", start.elapsed());
    assert_eq!(e.code(), haus::ErrorCode::GrowingRecursion, "{e}");
    (e.position().expect("a position"), e.reason().to_string())
}

#[test]
fn instances_that_double_through_another_definition_are_rejected_before_any_is_made() {
    let (at, reason) = growing(
        "type P a b = { l: a, r: b }
type A a = < X (B (P a a)) | Done >
type B a = < Y (A (P a a)) | Stop >
type Root = A Int",
    );
    assert_eq!(at, (2, 17));
    assert!(reason.starts_with("A refers to B, which refers back to A"), "{reason}");
    // Through three definitions, with the growing argument only on the way back.
    let (at, reason) = growing(
        "type P a b = { l: a, r: b }
type A a = < X (B a) | Done >
type B a = < Y (C a) | Stop >
type C a = < Z (A (P a a)) | End >
type Root = A Int",
    );
    assert_eq!(at, (4, 17));
    assert!(reason.starts_with("C refers to A, which refers back to C"), "{reason}");
}

#[test]
fn definitions_that_refer_to_each_other_with_their_own_parameters() {
    let schema = Schema::parse(
        "type GTree a = { value: a, kids: Forest a }
         type Forest a = Array (GTree a)
         type Swap a b = < S (Pair b a) | E >
         type Pair a b = { p: Swap a b, q: Swap b a }
         type Root = GTree (Pair Int String)",
    )
    .unwrap();
    assert_eq!(decode(&schema, "Root", "{ value: { p: E, q: E }, kids: [] }"), "{kids:[],value:{p:E,q:E}}");
}

#[test]
fn arguments_nested_30_levels_deep_compile_quickly() {
    let chain = |step: &str| {
        let defs = (1..30).map(|k| format!("type G{k} a = G{} ({step})", k - 1));
        std::iter::once("type G0 a = { v: a }".to_string())
            .chain(defs)
            .chain(["type Root = G29 Int".to_string()])
            .collect::<Vec<_>>()
            .join("\n")
    };
    let nested =
        format!("type P a b = {{ l: a, r: b }}\ntype Root = {}P Int Int{}", "P (".repeat(30), ") Int".repeat(30));
    for schema in [
        format!("type P a b = {{ l: a, r: b }}\n{}", chain("P a a")),
        chain("{ l: a, r: a }"),
        chain("< L a | R a >"),
        nested,
    ] {
        let start = std::time::Instant::now();
        let schema = Schema::parse(&schema).unwrap_or_else(|e| panic!("{e}"));
        assert!(start.elapsed() < std::time::Duration::from_secs(1), "took {:?}", start.elapsed());
        // Messages describe the deep arguments shortly.
        let e = decode(&schema, "Root", "1");
        assert!(e.starts_with("error: expected ") && e.len() < 300, "{e}");
    }
}

/// The code and position of the error parsing `schema`.
fn code_at(schema: &str) -> (String, (usize, usize)) {
    let e = Schema::parse(schema).expect_err("an error");
    (e.code().as_str().to_string(), e.position().expect("a position"))
}

#[test]
fn comments_whitespace_and_strings_are_those_of_data_files() {
    for (schema, code, at) in [
        ("type A = { \"x: Int }", "unterminated-string", (1, 12)),
        ("type A = Int /* never closed", "unterminated-comment", (1, 14)),
        ("type A = Int\rtype B = Int", "lone-carriage-return", (1, 13)),
        ("// a\rb\ntype A = Int", "lone-carriage-return", (1, 5)),
        ("// a\u{7}b\ntype A = Int", "control-character", (1, 5)),
        ("/* a\u{7f}b */ type A = Int", "control-character", (1, 5)),
        ("// a\u{85}b\ntype A = Int", "control-character", (1, 5)),
        ("// access\u{202e} denied\ntype A = Int", "bidi-control", (1, 10)),
        ("type A = { \"a\u{2066}b\": Int }", "bidi-control", (1, 14)),
        ("type A = { \"a\u{7}b\": Int }", "control-character", (1, 14)),
        ("type A = { \"a\nb\": Int }", "string-line-break", (1, 14)),
        (r#"type A = { "a\x41": Int }"#, "invalid-escape", (1, 14)),
        (r#"type A = { "a\u{D800}": Int }"#, "invalid-unicode-escape", (1, 14)),
        // In an attribute's arguments, the data parser's own errors.
        ("@deprecated(\"a\u{7}b\")\ntype A = Int", "control-character", (1, 15)),
    ] {
        assert_eq!(code_at(schema), (code.to_string(), at), "{schema:?}");
    }
    // A byte order mark at the start, CRLF line breaks and tabs in comments are fine.
    Schema::parse("\u{feff}// a\tb\r\ntype A = Int\r\n").unwrap();
}

#[test]
fn quoted_keys_take_every_escape_of_data_strings() {
    let schema =
        Schema::parse(r#"type A = closed { "tab\there": Int, "cr\r": Int, "\u{1F600}": Int, "q\"\\": Int }"#).unwrap();
    assert_eq!(
        decode(&schema, "A", "{ \"tab\\there\": 1, \"cr\\r\": 2, \"\u{1F600}\": 3, \"q\\\"\\\\\": 4 }"),
        r#"{"cr\r":2,"q\"\\":4,"tab\there":1,"😀":3}"#
    );
}

#[test]
fn a_schema_file_that_is_not_utf8() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("a.schema.haus");
    std::fs::write(&path, b"// \xff\ntype A = Int\n").unwrap();
    let e = Schema::load(&path, &haus_schema::NoImports).expect_err("an error");
    assert_eq!(e.code(), haus::ErrorCode::InvalidUtf8, "{e}");
}

#[test]
fn decoding_gives_what_an_encoder_writes() {
    let schema = Schema::parse(
        "type Root = { i: Int, u: UInt8, f: Float64, g: Float32, d: Decimal, r: Result String Int, any: Any, s: Secret String }",
    )
    .unwrap();
    assert_eq!(
        decode(
            &schema,
            "Root",
            r#"{ i: -0, u: 0xFF, f: 0.10, g: 2097152.25, d: 19.90, r: Ok(1_000), any: [1E5, Foo { a: 1 }], s: "pw" }"#
        ),
        r#"{any:[1e5,Foo{a:1}],d:19.90,f:0.1,g:2097152.2,i:0,r:Ok(1000),s:"pw",u:255}"#
    );
    assert_eq!(
        decode(&schema, "Root", r#"{ i: 1, u: 1, f: 1e400, g: 1, d: 1, r: Ok(1), any: 1, s: "x" }"#),
        "error: 1e400 is too large for Float64 at $.f"
    );
}

#[test]
fn streams_decode_each_value() {
    let schema = Schema::parse("type Event = { n: Int }\ntype Root = Stream Event").unwrap();
    let values = haus::parse(r#"{ n: 1 }, { n: 2, x: 0 }, { n: "3" }"#).unwrap();
    assert_eq!(
        schema.decode_stream("Root", &values).unwrap_err().to_string(),
        r#"expected Int, found the string "3" at $[2].n"#
    );
    let out = schema.decode_stream("Root", &values[..2]).unwrap();
    assert_eq!(out.iter().map(canonical).collect::<Vec<_>>(), ["{n:1}", "{n:2}"]);
}

#[test]
fn deep_values_built_in_code_and_the_limits() {
    let schema = Schema::parse("type Root = Any").unwrap();
    let deep = (0..300).fold(Value::Number("1".into()), |v, _| Value::Array(vec![v]));
    assert_eq!(schema.decode("Root", &deep).unwrap_err().message, "value nested deeper than 256 levels");
    // A recursive type: limited only by the depth (spec §9.9).
    let schema = Schema::parse("type Root = < Nil | Cons Int Root >").unwrap();
    let list = (0..255).fold(Value::Variant { tag: "Nil".into(), args: vec![] }, |v, i| Value::Variant {
        tag: "Cons".into(),
        args: vec![Value::Number(i.to_string()), v],
    });
    assert!(schema.decode("Root", &list).is_ok());
}

#[test]
fn warnings_of_the_schema() {
    let schema =
        Schema::parse("@since(2) type A = Int\n@deprecated(\"use C\") type B = Int\ntype C = { b: B }").unwrap();
    let warnings: Vec<String> = schema.warnings().iter().map(ToString::to_string).collect();
    assert_eq!(
        warnings,
        ["1:1: unknown attribute @since: this version of haus ignores it", "3:15: B is deprecated: use C"]
    );
    assert_eq!(schema.definition("B").unwrap().deprecated.as_ref().unwrap().note("B"), "B is deprecated: use C");
}

#[test]
fn package_names_and_manifests() {
    use haus::ErrorCode;
    use haus_schema::Manifest;
    // Imports name packages in lowercase (spec §13.3, grammar.ebnf).
    for module in
        ["@Acme/x", "@acme/X", "@acme", "@acme/x/y", "@-acme/x", "@acme/.x", "@acme/x~y", "@acme/node_modules"]
    {
        let e = Schema::parse(&format!("import {module} (A)\ntype R = A")).expect_err(module);
        assert_eq!(e.code(), ErrorCode::UnknownModule, "{module}: {e}");
    }
    for module in ["@acme/x.y.z_1-2", "@0/9@1", "@acme/node_modules2"] {
        let e = Schema::parse(&format!("import {module} (A)\ntype R = A")).expect_err(module);
        assert_eq!(e.code(), ErrorCode::ImportUnavailable, "{module}: {e}");
    }
    let manifest = |name: &str, version: &str| Manifest::parse(&format!("{{ name: {name:?}, version: {version:?} }}"));
    for version in ["0.0.0", "1.2.3", "1.0.0-rc.1", "1.0.0-0.x-y", "1.0.0+build.05", "10.20.30-alpha+001"] {
        assert!(manifest("@a/b", version).is_ok(), "{version}");
    }
    for version in ["1", "1.0", "v1.0.0", "01.0.0", "1.0.0-", "1.0.0-01", "1.0.0+", "1.0.0-a..b", " 1.0.0"] {
        assert!(manifest("@a/b", version).unwrap_err().contains("is not a semantic version"), "{version}");
    }
    let long = format!("@{}/{}", "a".repeat(100), "b".repeat(112));
    assert!(manifest(&long, "1.0.0").is_ok(), "{} characters", long.len());
    for name in ["@a/B", "a/b", "@a", "@a/b/c", "@./b", "@a/~b", "@a/b~c", "@node_modules/b", &format!("{long}c")] {
        assert!(manifest(name, "1.0.0").unwrap_err().contains("is not a package name"), "{name}");
    }
    assert!(Manifest::parse("{ name: \"@a/b\" }").unwrap_err().contains("needs a string field version"));
    assert!(Manifest::parse("{ name: \"@a/b\", version: \"1.0.0\" }, {}").unwrap_err().contains("one record"));
    let big = format!("{{ name: \"@a/b\", version: \"1.0.0\", x: \"{}\" }}", "x".repeat(64 * 1024));
    assert!(Manifest::parse(&big).unwrap_err().contains("more than 64 KiB"));
}

#[test]
fn files_outside_packages_have_ids_from_their_paths() {
    let dir = tempfile::tempdir().unwrap();
    let write = |path: &str, text: &str| {
        let path = dir.path().join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    };
    write("shop/billing/common.schema.haus", "type Iban = String");
    write("shop/shipping/common.schema.haus", "type Address = { street: String }");
    write("shared/money.schema.haus", "type Money = Decimal");
    write(
        "shop/app.schema.haus",
        "import ./billing/common (Iban)\nimport ./shipping/common (Address)\nimport ../shared/money (Money)\ntype Root = { iban: Iban, to: Address, total: Money }",
    );
    let path = dir.path().join("shop/app.schema.haus");
    let ids = |options: &Options| {
        let schema = Schema::load_with(&path, options).unwrap_or_else(|e| panic!("{e}"));
        let mut ids: Vec<String> = schema.definitions().iter().chain(schema.imported()).map(|d| d.id.clone()).collect();
        ids.sort();
        ids
    };
    assert_eq!(
        ids(&Options::default()),
        ["../shared/money#Money", "app#Root", "billing/common#Iban", "shipping/common#Address"]
    );
    let project = dir.path().join("shop");
    assert_eq!(
        ids(&Options { project: Some(("shop", &project)), ..Options::default() }),
        ["shop/../shared/money#Money", "shop/app#Root", "shop/billing/common#Iban", "shop/shipping/common#Address"]
    );
}

/// The payload of `tag` in the variant `ty`: "record", "named", "positional" or "none".
fn payload_kind(schema: &Schema, ty: &str, tag: &str) -> &'static str {
    let def = schema.definition(ty).unwrap_or_else(|| panic!("no type {ty}"));
    let haus_schema::Type::Variant(v) = schema.resolve(&schema.instance(def.template).body) else {
        panic!("{ty} is not a variant")
    };
    match v.case(tag).map(|c| &c.payload) {
        Some(haus_schema::Payload::Record(_)) => "record",
        Some(haus_schema::Payload::Named(_)) => "named",
        Some(haus_schema::Payload::Positional(_)) => "positional",
        Some(haus_schema::Payload::None) => "none",
        None => panic!("{ty} has no tag {tag}"),
    }
}

#[test]
fn record_cases_by_name() {
    // Spec §15: one argument whose type is a record, however it is written.
    let schema = Schema::parse(
        "type R = { w: Int }\ntype A = R\ntype Id a = a\ntype Page a = { items: Array a }\n\
         type Gen a = < Box a >\ntype GenR = Gen R\ntype Wrap a = < Box (Id a) >\ntype WrapR = Wrap R\n\
         type T = < Inline { w: Int } | Paren ({ w: Int }) | Name R | Alias A | Applied (Page Int) | Through (Id R) \
         | Res (Result String R) | Many (Maybe R) | Secretly (Secret R) | Num Int | Two R R >\n\
         type Res = Result String R",
    )
    .unwrap();
    for (tag, kind) in [
        ("Inline", "record"),
        ("Paren", "record"),
        ("Name", "named"),
        ("Alias", "named"),
        ("Applied", "named"),
        ("Through", "named"),
        ("Res", "positional"),
        ("Many", "positional"),
        ("Secretly", "positional"),
        ("Num", "positional"),
        ("Two", "positional"),
    ] {
        assert_eq!(payload_kind(&schema, "T", tag), kind, "{tag}");
    }
    // A type parameter is never a record, even where its argument is one.
    assert_eq!(payload_kind(&schema, "GenR", "Box"), "positional");
    assert_eq!(payload_kind(&schema, "WrapR", "Box"), "positional");
    assert_eq!(payload_kind(&schema, "Res", "Ok"), "positional");
    // Decoding: the same values as inline, and anything but one record is the wrong payload.
    assert_eq!(decode(&schema, "T", "Name({ w: 1, x: 2 })"), "Name{w:1}");
    for text in ["Name(1)", "Name(1, 2)", "Name", "Alias(1)", "Applied([])"] {
        assert!(
            decode(&schema, "T", text).contains("takes one argument, a record"),
            "{text}: {}",
            decode(&schema, "T", text)
        );
    }
    assert!(decode(&schema, "GenR", "Box(1)").starts_with("error"));
    assert_eq!(decode(&schema, "GenR", "Box { w: 1 }"), "Box{w:1}");
}

/// The payload of `tag` in the variant of field `key` of the record `ty`.
fn field_payload_kind(schema: &Schema, ty: &str, key: &str, tag: &str) -> &'static str {
    let def = schema.definition(ty).unwrap_or_else(|| panic!("no type {ty}"));
    let haus_schema::Type::Record(r) = schema.resolve(&schema.instance(def.template).body) else {
        panic!("{ty} is not a record")
    };
    let haus_schema::Type::Variant(v) = schema.resolve(&r.field(key).expect("no such field").ty) else {
        panic!("{ty}.{key} is not a variant")
    };
    match v.case(tag).map(|c| &c.payload) {
        Some(haus_schema::Payload::Named(_)) => "named",
        Some(haus_schema::Payload::Positional(_)) => "positional",
        _ => "other",
    }
}

#[test]
fn record_cases_are_decided_where_they_are_written() {
    // An inline variant in the argument of a generic type, written in a generic
    // definition: its parameter stays one (test-suite/json, InnerRec), also behind
    // a name, while the same variant written without parameters has a record case.
    let schema = Schema::parse(
        "type R = { w: Int }\ntype Id a = a\ntype Holder v = { item: v }\n\
         type Inner a = Holder (< X a >)\ntype InnerRec = Inner R\n\
         type Through a = Holder (< X (Id a) >)\ntype ThroughRec = Through R\n\
         type Direct = Holder (< X (Id R) >)",
    )
    .unwrap();
    assert_eq!(field_payload_kind(&schema, "InnerRec", "item", "X"), "positional");
    assert_eq!(field_payload_kind(&schema, "ThroughRec", "item", "X"), "positional");
    assert_eq!(field_payload_kind(&schema, "Direct", "item", "X"), "named");
    // In either order: the two are different types.
    let schema = Schema::parse(
        "type R = { w: Int }\ntype Id a = a\ntype Holder v = { item: v }\n\
         type Direct = Holder (< X (Id R) >)\ntype Through a = Holder (< X (Id a) >)\ntype ThroughRec = Through R",
    )
    .unwrap();
    assert_eq!(field_payload_kind(&schema, "ThroughRec", "item", "X"), "positional");
    assert_eq!(field_payload_kind(&schema, "Direct", "item", "X"), "named");
}

#[test]
fn record_cases_without_a_json_form_are_warned_about() {
    // Spec §16.3: a record case with a field `_tag` or `_args` has no
    // schema-based JSON form. The schema is valid; checkers warn at the case.
    let schema = Schema::parse(
        "type R = { _tag: String }\ntype A = R\ntype Page a = { _args: Array a, n: Int }\n\
         type Gen a = < Box a >\ntype Base = { _args: Int }\n\
         type T = < Inline { x: Int, _tag: String } | Name R | Alias A | Applied (Page Int) | Spread { ...Base } \
         | Fine { tag: String } | Res (Result String R) | Param (Gen R) >\n\
         type U = < ...T | Own >\n\
         type Nested = { a: Array (Maybe < Deep { _args: Int } >), r: Result < E ({ _tag: Int }) > Int }\n\
         type Events = Stream < Ev { _tag: Int } >",
    )
    .unwrap();
    let warnings: Vec<String> = schema.warnings().iter().map(|w| format!("{} {}", w.code().as_str(), w)).collect();
    assert_eq!(
        warnings,
        [
            "no-json-form 6:12: Inline has a field named _tag, so it has no schema-based JSON form",
            "no-json-form 6:46: Name has a field named _tag, so it has no schema-based JSON form",
            "no-json-form 6:55: Alias has a field named _tag, so it has no schema-based JSON form",
            "no-json-form 6:65: Applied has a field named _args, so it has no schema-based JSON form",
            "no-json-form 6:86: Spread has a field named _args, so it has no schema-based JSON form",
            "no-json-form 8:35: Deep has a field named _args, so it has no schema-based JSON form",
            "no-json-form 8:71: E has a field named _tag, so it has no schema-based JSON form",
            "no-json-form 9:24: Ev has a field named _tag, so it has no schema-based JSON form",
        ]
    );
    // Converters still fail only on values of these cases.
    assert!(schema.decode("T", &value("Fine { tag: \"x\" }")).is_ok());
}

#[test]
fn record_cases_without_a_json_form_through_imports() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("b.schema.haus"), "type Tagged = { _tag: String }").unwrap();
    let root = dir.path().join("a.schema.haus");
    std::fs::write(&root, "import ./b (Tagged)\ntype V = < T Tagged | U { ...Tagged } >").unwrap();
    let schema = Schema::load(&root, &haus_schema::NoImports).unwrap_or_else(|e| panic!("{e}"));
    let warnings: Vec<String> = schema.warnings().iter().map(ToString::to_string).collect();
    assert_eq!(
        warnings,
        [
            "2:12: T has a field named _tag, so it has no schema-based JSON form",
            "2:23: U has a field named _tag, so it has no schema-based JSON form",
        ]
    );
    // The imported file has no case: nothing to point out there.
    assert!(schema.files()[1].warnings().is_empty());
}
