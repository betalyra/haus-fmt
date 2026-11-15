//! Schema files with their imports (spec §13.3, §14), and what decoding
//! gives (spec §15) beyond the conformance suite.

use haus::{Value, canonical};
use haus_schema::{FileResolver, Options, Schema};
use std::path::{Path, PathBuf};

fn fixture(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(path)
}

fn resolver() -> FileResolver {
    FileResolver::new().package("@acme/ids", fixture("acme-ids"))
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
        let key = fixture("app.schema.haus").display().to_string();
        let options = Options { resolver: &resolver(), key: Some(&key), ..Options::default() };
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
    assert!(load("import @acme/other (A)").starts_with("1:1: can't import @acme/other: package not found"));
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
        "1:1: can't import @acme/ids: no module resolver (only std modules can be imported here)"
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
    let parse = |text: &str| Schema::parse_with(text, &Options { resolver: &resolver(), ..Options::default() });
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
