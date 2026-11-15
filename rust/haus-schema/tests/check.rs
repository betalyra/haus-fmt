//! Diagnostics of data checked against a schema: the cases of the TypeScript
//! checker's tests (typescript/packages/haus/test/check.test.ts), with the
//! same messages and places.

use haus_schema::{FileResolver, Schema, schema_reference};
use std::fs;
use std::path::{Path, PathBuf};

fn repo(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").join(path)
}

/// Issues as "severity text-at-location: message".
fn issues(schema: &str, data: &str, ty: &str) -> Vec<String> {
    let schema = Schema::parse(schema).unwrap_or_else(|e| panic!("{e}"));
    schema
        .check_text(ty, data)
        .iter()
        .map(|i| {
            let span = i.span.clone().expect("a span");
            format!("{} {}: {}", i.severity, &data[span], i.message)
        })
        .collect()
}

#[test]
fn accepts_the_examples() {
    let resolver = FileResolver::new().package("@haus-fmt/money", repo("extensions/money"));
    for name in ["thread", "syntax-tour"] {
        let schema =
            Schema::load(repo(&format!("examples/{name}.schema.haus")), &resolver).unwrap_or_else(|e| panic!("{e}"));
        let data = fs::read_to_string(repo(&format!("examples/{name}.haus"))).unwrap();
        let errors: Vec<String> = schema
            .check_text("Root", &data)
            .iter()
            .filter(|i| i.severity == haus_schema::Severity::Error)
            .map(ToString::to_string)
            .collect();
        assert_eq!(errors, Vec::<String>::new(), "{name}");
    }
}

#[test]
fn reports_errors_at_the_wrong_value() {
    let schema = r#"
      import std/time (Date)
      type Status = closed < Pending | Shipped { tracking: String } >
      type Root = { id: Int, qty: UInt8, day: Date, status: Status, tags: Array String }"#;
    assert_eq!(
        issues(schema, r#"{ id: "7", qty: 300, day: Date("2026-02-30"), status: Shiped, tags: ["a", 1] }"#, "Root"),
        [
            r#"error "7": expected Int, found the string "7""#,
            "error 300: 300 is out of range for UInt8 (0 to 255)",
            r#"error "2026-02-30": "2026-02-30" is not a valid Date: 2026-02 has no day 30"#,
            "error Shiped: Shiped is not allowed here: expected one of Pending, Shipped. Did you mean Shipped?",
            "error 1: expected String, found the number 1",
        ]
    );
    assert_eq!(issues(schema, "{ id: 1 }", "Root")[0], "error {: missing fields qty, day, status, tags");
}

#[test]
fn open_types_unknown_fields_and_tags_are_hints_closed_ones_are_errors() {
    let schema = "
      type Line = { product: String, quantity?: UInt8 }
      type Strict = closed { product: String }
      type Theme = < Light | Dark >
      type Root = { line: Line, strict: Strict, theme: Theme }";
    assert_eq!(
        issues(
            schema,
            r#"{ line: { product: "a", quantiy: 2 }, strict: { product: "b", extra: 1 }, theme: Sepia }"#,
            "Root"
        ),
        [
            "hint quantiy: quantiy is not in the schema; a reader ignores it. Did you mean quantity?",
            "error extra: extra is not a field of this closed record.",
            "hint Sepia: Sepia is not in the schema; a reader keeps it as an unknown value.",
        ]
    );
}

#[test]
fn any_tag_variants_give_no_hint_for_the_tags_they_hold() {
    let schema = "
      type Currency = < >
      type Root = { currency: Currency }";
    assert_eq!(issues(schema, "{ currency: EUR }", "Root"), Vec::<String>::new());
}

#[test]
fn streams_positional_payloads_maybe_and_recursion() {
    let schema = "
      type Point = closed < Point Float64 Float64 >
      type Tree = closed < Node { value: Int, children: Array Tree } >
      type Item = { at: Point, tree: Tree, nick: Maybe String }
      type Root = Stream Item";
    let data = "{ at: Point(1, 2), tree: Node { value: 1, children: [] }, nick: None },\n{ at: Point(1), tree: Node { value: 1, children: [Node { value: \"x\", children: [] }] }, nick: \"n\" },";
    assert_eq!(
        issues(schema, data, "Root"),
        [
            "error Point(1): Point takes 2 arguments (Float64, Float64), found 1",
            r#"error "x": expected Int, found the string "x""#,
            r#"error "n": expected None or Some(…) (Maybe String), found the string "n""#,
        ]
    );
}

// Beyond the TypeScript cases: what the CLI prints.

#[test]
fn deprecated_fields_and_tags_are_hints() {
    let schema = r#"
      type Shape = < Circle { r: Float64 } | @deprecated("use Rect") Square { side: Float64 } >
      type Root = { @deprecated("use email") mail?: String, email?: String, shape: Shape }"#;
    assert_eq!(
        issues(schema, r#"{ mail: "a@b", shape: Square { side: 1 } }"#, "Root"),
        ["hint mail: mail is deprecated: use email", "hint Square: Square is deprecated: use Rect"]
    );
}

#[test]
fn secrets_are_never_shown() {
    let schema = r#"
      type Root = { key: Secret { token: String }, pin: Secret UInt16 }"#;
    let data = r#"{ key: { tokn: "hunter2" }, pin: 123456 }"#;
    let schema = Schema::parse(schema).unwrap();
    let found = schema.check_text("Root", data);
    let shown: Vec<String> =
        found.iter().map(|i| format!("{} {}: {i}", i.severity, &data[i.span.clone().unwrap()])).collect();
    assert_eq!(
        shown,
        [
            r#"error { tokn: "hunter2" }: expected a record (a Secret: the value is not shown) at $.key"#,
            "error 123456: expected UInt16 (a Secret: the value is not shown) at $.pin",
        ]
    );
    let e = schema.decode("Root", &haus::parse(data).unwrap()[0]).unwrap_err();
    assert_eq!(e.to_string(), "expected a record (a Secret: the value is not shown) at $.key");
}

#[test]
fn positions_paths_and_syntax_errors() {
    let schema = Schema::parse("type Root = { items: Array { price: Decimal } }").unwrap();
    let found = schema.check_text("Root", "{ items: [\n  { price: 1 },\n  { price: \"2\" },\n] }");
    let at = found[0].position.unwrap();
    assert_eq!(
        (at.line, at.column, found[0].to_string().as_str()),
        (3, 12, r#"expected Decimal, found the string "2" at $.items[1].price"#)
    );

    let found = schema.check_text("Root", "{ items: [ }");
    let at = found[0].position.unwrap();
    assert_eq!((at.line, at.column, found[0].message.as_str()), (1, 12, "expected a value, found '}'"));

    assert_eq!(
        schema.check_text("Root", "{ items: [] }, { items: [] }")[0].message,
        "expected one value (Root is not a Stream), found 2"
    );
    assert_eq!(schema.check_text("Order", "{}")[0].message, "the schema has no type Order");
}

#[test]
fn many_problems_are_reported_up_to_a_limit() {
    let schema = Schema::parse("type Root = Array Int").unwrap();
    let data = format!("[{}]", vec!["\"x\""; 500].join(", "));
    assert_eq!(schema.check_text("Root", &data).len(), haus_schema::MAX_ISSUES);
}

#[test]
fn schema_reference_reads_the_comment_at_the_top() {
    let text = "// An order.\n// schema: ./api.schema.haus#Order\n{ id: 1 }";
    let r = schema_reference(text).unwrap();
    assert_eq!((r.path.as_str(), r.type_name.as_str()), ("./api.schema.haus", "Order"));
    assert_eq!(&text[r.span], "./api.schema.haus#Order");
    assert_eq!(schema_reference("// schema: x.schema.haus\n{}").map(|r| r.type_name), Some("Root".into()));
    assert_eq!(schema_reference("{}\n// schema: x.schema.haus"), None);
}
