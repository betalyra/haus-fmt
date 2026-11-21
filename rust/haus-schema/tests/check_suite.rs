//! The checker suite (test-suite/check/cases.haus, test-suite/README.md
//! "Checker suite", spec §14, §15, §16): the warnings of a schema file, and
//! the hints and errors of data checked against a type, in the order of
//! their places.
//!
//! - `Schema { schema, warnings }`: the schema loads, with exactly the
//!   warnings `Warning(code, line, column)`.
//! - `Data { schema, type, data, issues }`: `check_text` gives exactly the
//!   issues `Hint(code, path)` / `Error(code, path)`.

use haus::{Value, canonical};
use haus_schema::{Schema, Severity};
use std::path::Path;

/// A string field of a case.
fn text<'a>(fields: &'a Value, key: &str) -> &'a str {
    match fields.get(key) {
        Some(Value::String(s)) => s,
        _ => panic!("not a case: {}", canonical(fields).unwrap()),
    }
}

/// `Tag(a, b, …)` as `Tag a b …`: strings and numbers as their text.
fn show(v: &Value) -> String {
    let Value::Variant { tag, args } = v else { panic!("not an entry: {}", canonical(v).unwrap()) };
    let args = args.iter().map(|a| match a {
        Value::String(s) | Value::Number(s) => s.clone(),
        other => canonical(other).unwrap(),
    });
    std::iter::once(tag.clone()).chain(args).collect::<Vec<_>>().join(" ")
}

/// The entries of the array field `key`, shown.
fn entries(fields: &Value, key: &str) -> Vec<String> {
    match fields.get(key) {
        Some(Value::Array(items)) => items.iter().map(show).collect(),
        _ => panic!("not a case: {}", canonical(fields).unwrap()),
    }
}

/// The schema's warnings, in the order of their places.
fn warnings(schema: &Schema) -> Vec<String> {
    let mut warnings: Vec<_> = schema.warnings().iter().collect();
    warnings.sort_by_key(|w| w.position());
    warnings
        .iter()
        .map(|w| match w.position() {
            Some((line, column)) => format!("Warning {} {line} {column}", w.code()),
            None => format!("Warning {} (no position: {})", w.code(), w.reason()),
        })
        .collect()
}

/// The issues of checking `data` as `ty`, in the order of their places.
fn issues(schema: &Schema, ty: &str, data: &str) -> Vec<String> {
    let mut issues = schema.check_text(ty, data);
    issues.sort_by_key(|i| i.position.map(|p| (p.line, p.column)));
    issues
        .iter()
        .map(|i| {
            let severity = match i.severity {
                Severity::Hint => "Hint",
                Severity::Error => "Error",
            };
            format!("{severity} {} {}", i.code, i.path_string())
        })
        .collect()
}

#[test]
fn checker_suite() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/check/cases.haus");
    let cases = haus::parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(!cases.is_empty(), "no cases in {}", path.display());
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let Value::Variant { tag, args } = c else { panic!("not a case: {}", canonical(c).unwrap()) };
            let [fields] = args.as_slice() else { panic!("not a case: {}", canonical(c).unwrap()) };
            let source = text(fields, "schema");
            let schema = match Schema::parse(source) {
                Ok(schema) => schema,
                Err(e) => return Some(format!("{tag} {source:?}: the schema doesn't load: {} ({e})", e.code())),
            };
            let (got, want) = match tag.as_str() {
                "Schema" => (warnings(&schema), entries(fields, "warnings")),
                "Data" => (issues(&schema, text(fields, "type"), text(fields, "data")), entries(fields, "issues")),
                _ => panic!("not a case: {}", canonical(c).unwrap()),
            };
            (got != want).then(|| {
                let data = fields.get("data").map(|d| format!(" data {}", canonical(d).unwrap())).unwrap_or_default();
                format!("{tag} {source:?}{data}: got {got:?}, expected {want:?}")
            })
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}
