//! The checker suite (test-suite/check/cases.haus, test-suite/README.md
//! "Checker suite", spec §14, §15, §16): the warnings of a schema file, and
//! the hints and errors of data checked against a type, compared as
//! multisets of (code, place): no order, each as often as listed.
//!
//! - `Schema { schema, warnings }`: the schema loads, with exactly the
//!   warnings `Warning(code, line, column)`.
//! - `Data { schema, type, data, issues, first? }`: checking the text
//!   (`check_text_report`, stopping at the first error with `first: True`)
//!   gives exactly the issues `Hint(code, path)` / `Error(code, path)`, and
//!   `Syntax(code, line, column)` for a syntax or limit error of the text.

use haus::{Value, canonical};
use haus_schema::{CheckOptions, Schema, Severity};
use std::path::Path;

/// A string field of a case.
fn text<'a>(fields: &'a Value, key: &str) -> &'a str {
    match fields.get(key) {
        Some(Value::String(s)) => s,
        _ => panic!("not a case: {}", canonical(fields)),
    }
}

/// `Tag(a, b, …)` as `Tag a b …`: strings and numbers as their text.
fn show(v: &Value) -> String {
    let Value::Variant { tag, args } = v else { panic!("not an entry: {}", canonical(v)) };
    let args = args.iter().map(|a| match a {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        other => canonical(other),
    });
    std::iter::once(tag.to_string()).chain(args).collect::<Vec<_>>().join(" ")
}

/// The entries of the array field `key`, shown, as a multiset (sorted).
fn entries(fields: &Value, key: &str) -> Vec<String> {
    match fields.get(key) {
        Some(Value::Array(items)) => sorted(items.iter().map(show).collect()),
        _ => panic!("not a case: {}", canonical(fields)),
    }
}

fn sorted(mut v: Vec<String>) -> Vec<String> {
    v.sort();
    v
}

/// The schema's warnings, as a multiset.
fn warnings(schema: &Schema) -> Vec<String> {
    sorted(
        schema
            .warnings()
            .iter()
            .map(|w| {
                let code = w.code().expect("a warning has a code");
                match w.position() {
                    Some((line, column)) => format!("Warning {code} {line} {column}"),
                    None => format!("Warning {code} (no position: {})", w.reason()),
                }
            })
            .collect(),
    )
}

/// The issues of checking `data` as `ty`, as a multiset.
fn issues(schema: &Schema, ty: &str, data: &str, first: bool) -> Vec<String> {
    let report = schema.check_text_report(ty, data, &CheckOptions { first, ..CheckOptions::default() });
    sorted(
        report
            .issues
            .iter()
            .map(|i| match (i.syntax(), i.severity) {
                (Some(e), _) => format!("Syntax {} {} {}", e.code, e.line, e.column),
                (None, Severity::Hint) => format!("Hint {} {}", i.code, i.path_string()),
                (None, Severity::Error) => format!("Error {} {}", i.code, i.path_string()),
            })
            .collect(),
    )
}

#[test]
fn checker_suite() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/check/cases.haus");
    let cases = haus::parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(!cases.is_empty(), "no cases in {}", path.display());
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let Value::Variant { tag, args } = c else { panic!("not a case: {}", canonical(c)) };
            let [fields] = args.as_slice() else { panic!("not a case: {}", canonical(c)) };
            let source = text(fields, "schema");
            let schema = match Schema::parse(source) {
                Ok(schema) => schema,
                Err(e) => return Some(format!("{tag} {source:?}: the schema doesn't load: {:?} ({e})", e.code())),
            };
            let first = matches!(fields.get("first"), Some(Value::Variant { tag, .. }) if tag == "True");
            let (got, want) = match tag.as_str() {
                "Schema" => (warnings(&schema), entries(fields, "warnings")),
                "Data" => {
                    (issues(&schema, text(fields, "type"), text(fields, "data"), first), entries(fields, "issues"))
                }
                _ => panic!("not a case: {}", canonical(c)),
            };
            (got != want).then(|| {
                let data = fields.get("data").map(|d| format!(" data {}", canonical(d))).unwrap_or_default();
                format!("{tag} {source:?}{data}: got {got:?}, expected {want:?}")
            })
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}
