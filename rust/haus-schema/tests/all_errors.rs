//! Every error (spec §14): after a successful parse every error, each error
//! once (two at one place too), none below a value that failed at its own
//! level, as a multiset; or only the first ([`CheckOptions::first`]); at most
//! MAX_ERRORS errors (hints don't count), saying when it stopped there. A
//! stream is checked item by item, up to a syntax error.

use haus::ErrorCode;
use haus_schema::{CheckOptions, CheckReport, MAX_ERRORS, Schema, Severity};

fn at_first() -> CheckOptions {
    CheckOptions { first: true, ..CheckOptions::default() }
}

fn report(schema: &str, data: &str, options: &CheckOptions) -> CheckReport {
    Schema::parse(schema).unwrap_or_else(|e| panic!("{e}")).check_text_report("Root", data, options)
}

/// The issues as a multiset (sorted) of `severity code path`.
fn set(report: &CheckReport) -> Vec<String> {
    let mut all: Vec<String> =
        report.issues.iter().map(|i| format!("{} {} {}", i.severity, i.code, i.path_string())).collect();
    all.sort();
    all
}

fn strings<const N: usize>(items: [&str; N]) -> Vec<String> {
    let mut all: Vec<String> = items.into_iter().map(str::to_owned).collect();
    all.sort();
    all
}

/// Whether the multiset `small` is in `big`.
fn within(small: &[String], big: &[String]) -> bool {
    small.iter().all(|s| small.iter().filter(|t| *t == s).count() <= big.iter().filter(|t| *t == s).count())
}

const ORDER: &str = "type Line = { sku: String, count: Int }\n\
                     type Root = closed { id: Int, lines: Array Line, note?: String }";
const DATA: &str = r#"{ id: "7", lines: [{ sku: 1, count: 2 }, { count: "x" }], extra: 1 }"#;

#[test]
fn every_error_by_default() {
    let all = report(ORDER, DATA, &CheckOptions::default());
    assert_eq!(
        set(&all),
        strings([
            "error type-mismatch $.id",
            "error type-mismatch $.lines[0].sku",
            "error missing-field $.lines[1]",
            "error type-mismatch $.lines[1].count",
            "error unknown-field $.extra",
        ])
    );
    assert!(!all.stopped && !all.ok());
    // The first error of decoding is one of them, and so is --first's.
    let schema = Schema::parse(ORDER).unwrap();
    let decoded = schema.decode("Root", &haus::parse(DATA).unwrap()[0]).unwrap_err();
    assert!(set(&all).contains(&format!("error {} {}", decoded.code, decoded.path_string())));
    let first = report(ORDER, DATA, &at_first());
    assert_eq!(first.issues.len(), 1);
    assert!(within(&set(&first), &set(&all)));
}

/// The multi-error Data cases added to test-suite/check/cases.haus for
/// spec §14 "Every error" (schema, data, issues as `severity code path`).
const SUITE: &[(&str, &str, &[&str])] = &[
    (
        "type Root = { a: Int, b: String, c: Bool }",
        r#"{ a: "x", b: 1, c: True }"#,
        &["error type-mismatch $.a", "error type-mismatch $.b"],
    ),
    (
        "type Root = closed { a: Int, b: Int }",
        r#"{ a: "x", z: 1 }"#,
        &["error missing-field $", "error type-mismatch $.a", "error unknown-field $.z"],
    ),
    // Each missing field is an error, all at the record.
    ("type Root = { a: Int, b: Int }", "{}", &["error missing-field $", "error missing-field $"]),
    // A positional payload checks every argument.
    ("type Root = closed < P Int String >", r#"P("1", 2)"#, &["error type-mismatch $[0]", "error type-mismatch $[1]"]),
    ("type Root = { items: Array { id: Int } }", r#"{ items: { id: "x" } }"#, &["error type-mismatch $.items"]),
    (
        "type Root = Array Int8",
        r#"[1, 300, "x", -200]"#,
        &["error out-of-range $[1]", "error type-mismatch $[2]", "error out-of-range $[3]"],
    ),
    ("type Root = Map Int", r#"{ a: "x", b: 2, c: "y" }"#, &["error type-mismatch $.a", "error type-mismatch $.c"]),
    ("type Root = closed < A { x: Int } >", r#"B { x: "y" }"#, &["error unknown-tag $"]),
    (
        "type Root = Array (closed < P { x: Int } | Q >)",
        r#"[P { x: "a" }, P { x: 1 }, Q(1), P { x: "b" }]"#,
        &["error type-mismatch $[0].x", "error wrong-payload $[2]", "error type-mismatch $[3].x"],
    ),
    (
        "type Root = { k: Secret { a: Int, b: Int }, n: Int }",
        r#"{ k: { a: "x", b: "y" }, n: "z" }"#,
        &["error invalid-secret $.k", "error type-mismatch $.n"],
    ),
    (
        "type Root = { name: String, n: Int }",
        r#"{ nmae: "a", n: "x" }"#,
        &["error missing-field $", "hint unlisted-field $.nmae", "error type-mismatch $.n"],
    ),
];

#[test]
fn the_suites_every_error_cases() {
    for (schema, data, issues) in SUITE {
        let all = report(schema, data, &CheckOptions::default());
        let mut want: Vec<String> = issues.iter().map(|s| (*s).to_owned()).collect();
        want.sort();
        assert_eq!(set(&all), want, "{schema} / {data}");
        // --first: one error, of the set, with only hints besides.
        let first = report(schema, data, &at_first());
        assert_eq!(first.issues.iter().filter(|i| i.severity == Severity::Error).count(), 1, "{data}");
        assert!(within(&set(&first), &set(&all)), "{data}");
    }
}

#[test]
fn first_keeps_the_hints_before_its_error() {
    let schema = "type Root = { a: Int, b: Int }";
    let first = report(schema, r#"{ zz: 1, a: "x", yy: 2, b: "y" }"#, &at_first());
    assert_eq!(set(&first), strings(["hint unlisted-field $.zz", "error type-mismatch $.a"]));
    // A value without errors has all its hints.
    let first = report(schema, r#"{ zz: 1, a: 1, b: 2, yy: 2 }"#, &at_first());
    assert!(first.ok());
    assert_eq!(first.issues.len(), 2);
}

#[test]
fn a_syntax_error_is_the_only_error() {
    for options in [CheckOptions::default(), at_first()] {
        let r = report(ORDER, r#"{ id: "7", lines: [ }"#, &options);
        assert_eq!(r.issues.len(), 1);
        assert_eq!(r.issues[0].code, ErrorCode::ExpectedValue);
        assert!(r.issues[0].position.is_some());
    }
}

#[test]
fn a_stream_is_checked_item_by_item_up_to_its_syntax_error() {
    let schema = "type Root = Stream String";
    let data = "1,\n\"ok\",\n\"ok\" \"oops\"";
    let all = report(schema, data, &CheckOptions::default());
    assert_eq!(set(&all), strings(["error missing-comma $", "error type-mismatch $[0]"]));
    let syntax = all.issues.iter().find_map(|i| i.syntax()).expect("a syntax error");
    assert_eq!((syntax.line, syntax.column), (3, 6));
    let at = |i: usize| all.issues[i].position.map(|p| (p.line, p.column));
    assert_eq!((at(0), at(1)), (Some((1, 1)), Some((3, 6))));
    // Stopping at the first error: the item's, before the syntax error.
    assert_eq!(set(&report(schema, data, &at_first())), strings(["error type-mismatch $[0]"]));
    // Without errors before it, the syntax error is the first.
    let fine = "\"a\",\n\"ok\" \"oops\"";
    assert_eq!(set(&report(schema, fine, &at_first())), strings(["error missing-comma $"]));
    // A document with a syntax error has that one error.
    let r = report("type Root = Array String", "[1, \"ok\" \"oops\"]", &CheckOptions::default());
    assert_eq!(set(&r), strings(["error missing-comma $"]));
}

#[test]
fn says_when_it_stopped_at_the_cap() {
    let items = |n: usize| format!("[{}]", vec!["\"x\""; n].join(", "));
    let schema = Schema::parse("type Root = Array Int").unwrap();
    let options = CheckOptions::default();
    let exactly = schema.check_text_report("Root", &items(MAX_ERRORS), &options);
    assert_eq!((exactly.issues.len(), exactly.stopped), (MAX_ERRORS, false));
    let more = schema.check_text_report("Root", &items(MAX_ERRORS + 1), &options);
    assert_eq!((more.issues.len(), more.stopped), (MAX_ERRORS, true));
    // From parsed values, without positions.
    let values = haus::parse(&items(MAX_ERRORS + 1)).unwrap();
    let from_values = schema.check_report("Root", &values, &options);
    assert_eq!((from_values.issues.len(), from_values.stopped), (MAX_ERRORS, true));
    assert!(from_values.issues.iter().all(|i| i.position.is_none() && i.severity == Severity::Error));
    // check_text is the same list.
    assert_eq!(schema.check_text("Root", &items(MAX_ERRORS + 1)), more.issues);
}

#[test]
fn the_cap_counts_errors_only() {
    let schema = Schema::parse("type Root = Array { id: Int }").unwrap();
    let items = |n: usize| format!("[{}]", vec!["{ id: 1, a: 1 }"; n].join(", "));
    let hints = schema.check_text_report("Root", &items(MAX_ERRORS * 2), &CheckOptions::default());
    assert_eq!((hints.issues.len(), hints.stopped), (MAX_ERRORS * 2, false));
    assert!(hints.ok());
}

#[test]
fn a_stream_has_one_cap_for_all_its_values() {
    let schema = Schema::parse("type Root = Stream Int").unwrap();
    let mut check = schema.check_stream("Root", &CheckOptions::default()).unwrap();
    let bad = haus::parse("\"x\"").unwrap().remove(0);
    let mut found = 0;
    while !check.done() {
        found += check.check_text(&bad, "\"x\",").len();
    }
    assert_eq!((found, check.stopped()), (MAX_ERRORS, true));
    assert!(check.check(&bad).is_empty(), "nothing after the cap");
    // Each value at its index in the stream, at its place in its text.
    let mut check = schema.check_stream("Root", &CheckOptions::default()).unwrap();
    assert!(check.check(&haus::parse("1").unwrap()[0]).is_empty());
    let issues = check.check_text(&bad, "\n  \"x\",");
    assert_eq!(issues[0].path_string(), "$[1]");
    assert_eq!(issues[0].position.map(|p| (p.line, p.column)), Some((2, 3)));
    // --first: the first error ends the check.
    let mut first = schema.check_stream("Root", &at_first()).unwrap();
    assert_eq!(first.check(&bad).len(), 1);
    assert!(first.done() && !first.stopped());
}

#[test]
fn a_secret_is_one_error_with_first_too() {
    let schema = "type Root = { k: Secret { a: Int, b: Int }, n: Int }";
    let data = r#"{ k: { a: "x", b: "y", c: 1 }, n: "z" }"#;
    assert_eq!(
        set(&report(schema, data, &CheckOptions::default())),
        strings(["error invalid-secret $.k", "error type-mismatch $.n"])
    );
    assert_eq!(set(&report(schema, data, &at_first())), strings(["error invalid-secret $.k"]));
}
