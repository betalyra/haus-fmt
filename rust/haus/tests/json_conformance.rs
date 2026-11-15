//! The JSON suite without a type (test-suite/json, spec §16.1 and §16.2), and
//! every `valid/NAME.json` of the conformance suite as a lossless case.
//! The plain mapping, which needs generated types, is in
//! haus-build-tests/tests/json_conformance.rs.

use haus::{Json, Value, canonical};
use std::fs;
use std::path::{Path, PathBuf};

fn suite(path: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite").join(path)
}

/// JSON with every object's members sorted, to compare as data.
fn sorted(json: Json) -> Json {
    match json {
        Json::Array(items) => Json::Array(items.into_iter().map(sorted).collect()),
        Json::Object(members) => {
            let mut members: Vec<_> = members.into_iter().map(|(k, v)| (k, sorted(v))).collect();
            members.sort_by(|a, b| a.0.cmp(&b.0));
            Json::Object(members)
        }
        other => other,
    }
}

/// Whether two JSON texts are the same data: member order and whitespace
/// don't matter, numbers compare by their text.
fn same_json(a: &str, b: &str) -> bool {
    let parse = |t: &str| haus::json::parse(t).map(sorted).unwrap_or_else(|e| panic!("{t}: {e}"));
    parse(a) == parse(b)
}

/// The cases of `json/<file>`: (tag, fields).
fn cases(file: &str) -> Vec<(String, Value)> {
    let path = suite("json").join(file);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let values = haus::parse(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    assert!(!values.is_empty(), "no cases in {}", path.display());
    values
        .into_iter()
        .map(|v| match v {
            Value::Variant { tag, mut args } if args.len() == 1 => (tag, args.remove(0)),
            v => panic!("{file}: not a case: {}", canonical(&v)),
        })
        .collect()
}

fn text(fields: &Value, key: &str) -> String {
    match fields.get(key) {
        Some(Value::String(s)) => s.clone(),
        _ => panic!("not a case: {}", canonical(fields)),
    }
}

/// Why `result` isn't a failure with `code` (spec §17), if it isn't.
fn rejected(result: Result<Value, haus::Error>, code: &str) -> Option<String> {
    match result {
        Ok(v) => Some(format!("read as {}", canonical(&v))),
        Err(e) if e.code().map(|c| c.as_str()) != Some(code) => Some(format!("{:?} ({e}), expected {code}", e.code())),
        Err(_) => None,
    }
}

/// `Ok { input, json }`: writing `input` gives `json`, reading `json` gives
/// `input`. `Err { json, code }`: reading `json` fails with `code`.
#[test]
fn lossless() {
    let failures: Vec<String> = cases("lossless.cases.haus")
        .iter()
        .filter_map(|(tag, fields)| {
            let json = text(fields, "json");
            let failure = match (tag.as_str(), fields.get("input")) {
                ("Ok", Some(input)) => match haus::to_lossless_json(input) {
                    Err(e) => Some(format!("can't write the input: {e}")),
                    Ok(written) if !same_json(&written, &json) => Some(format!("written as {written}")),
                    Ok(_) => match haus::from_lossless_json(&json) {
                        Ok(v) if haus::equals(&v, input) => None,
                        Ok(v) => Some(format!("read as {}", canonical(&v))),
                        Err(e) => Some(format!("can't read it: {e}")),
                    },
                },
                ("Err", None) => rejected(haus::from_lossless_json(&json), &text(fields, "code")),
                _ => panic!("not a case: {}", canonical(fields)),
            };
            failure.map(|why| format!("{tag} {json}: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "lossless cases failed:\n{}", failures.join("\n"));
}

/// `Read { json, output }`: reading `json` without a schema gives `output`.
/// `Err { json, code }`: reading `json` fails with `code`.
#[test]
fn without_a_schema() {
    let failures: Vec<String> = cases("schemaless.cases.haus")
        .iter()
        .filter_map(|(tag, fields)| {
            let json = text(fields, "json");
            let failure = match (tag.as_str(), fields.get("output")) {
                ("Read", Some(output)) => match haus::from_json(&json) {
                    Ok(v) if haus::equals(&v, output) => None,
                    Ok(v) => Some(format!("read as {}", canonical(&v))),
                    Err(e) => Some(format!("can't read it: {e}")),
                },
                ("Err", None) => rejected(haus::from_json(&json), &text(fields, "code")),
                _ => panic!("not a case: {}", canonical(fields)),
            };
            failure.map(|why| format!("{tag} {json}: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "cases without a schema failed:\n{}", failures.join("\n"));
}

/// Every `valid/NAME.json` is the lossless form of the file's values, as an
/// array: writing them gives it, and reading it gives them back.
#[test]
fn valid_files_are_lossless_cases() {
    let mut paths: Vec<_> = fs::read_dir(suite("valid"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "haus"))
        .collect();
    paths.sort();
    assert!(!paths.is_empty());
    let failures: Vec<String> = paths
        .iter()
        .filter_map(|path| {
            let name = path.file_stem().unwrap().to_string_lossy().into_owned();
            let values = Value::Array(haus::parse_bytes(&fs::read(path).unwrap()).unwrap());
            let expected = fs::read_to_string(path.with_extension("json")).unwrap();
            let failure = match haus::to_lossless_json(&values) {
                Err(e) => Some(format!("can't write it: {e}")),
                Ok(written) if !same_json(&written, &expected) => Some(format!("written as {written}")),
                Ok(_) => match haus::from_lossless_json(&expected) {
                    Ok(v) if haus::equals(&v, &values) => None,
                    Ok(v) => Some(format!("read as {}", canonical(&v))),
                    Err(e) => Some(format!("can't read it: {e}")),
                },
            };
            failure.map(|why| format!("{name}.json: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "valid/*.json as lossless cases failed:\n{}", failures.join("\n"));
}
