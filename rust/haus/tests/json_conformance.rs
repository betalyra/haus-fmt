//! The JSON suite without a type (test-suite/json, spec §16.1 and §16.2), and
//! every `valid/NAME.jsonl` of the conformance suite as a self-describing
//! case. Schema-based JSON, which needs generated types, is in
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

/// Why `result` isn't a failure with the `code` of the case `fields` (spec
/// §17), at its `path` in the JSON if it gives one (spec §16.3 "Places"), if it isn't.
fn rejected(result: Result<Value, haus::Error>, fields: &Value) -> Option<String> {
    let code = text(fields, "code");
    let path = fields.get("path").map(|_| text(fields, "path"));
    match result {
        Ok(v) => Some(format!("read as {}", canonical(&v))),
        Err(e) if e.code().map(|c| c.as_str()) != Some(code.as_str()) => {
            Some(format!("{:?} ({e}), expected {code}", e.code()))
        }
        Err(e) => match (path, place(&e)) {
            (Some(path), place) if place.as_deref() != Some(path.as_str()) => {
                Some(format!("at {place:?} ({e}), expected {path}"))
            }
            _ => None,
        },
    }
}

/// The place of an error in a value (spec §17 `path`); None for an error in text.
fn place(e: &haus::Error) -> Option<String> {
    match e {
        haus::Error::Decode(e) => Some(e.place()),
        haus::Error::Encode(e) => Some(e.place()),
        _ => None,
    }
}

/// `Ok { input, json }`: writing `input` gives `json`, reading `json` gives
/// `input`. `Err { json, code, path? }`: reading `json` fails with `code`, at `path`.
#[test]
fn self_describing() {
    let failures: Vec<String> = cases("self-describing.cases.haus")
        .iter()
        .filter_map(|(tag, fields)| {
            let json = text(fields, "json");
            let failure = match (tag.as_str(), fields.get("input")) {
                ("Ok", Some(input)) => match haus::to_haus_json(input) {
                    Err(e) => Some(format!("can't write the input: {e}")),
                    Ok(written) if !same_json(&written, &json) => Some(format!("written as {written}")),
                    Ok(_) => match haus::from_haus_json(&json) {
                        Ok(v) if haus::equals(&v, input) => None,
                        Ok(v) => Some(format!("read as {}", canonical(&v))),
                        Err(e) => Some(format!("can't read it: {e}")),
                    },
                },
                ("Err", None) => rejected(haus::from_haus_json(&json), fields),
                _ => panic!("not a case: {}", canonical(fields)),
            };
            failure.map(|why| format!("{tag} {json}: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "self-describing cases failed:\n{}", failures.join("\n"));
}

/// `Read { json, output }`: importing `json` gives `output`.
/// `Err { json, code }`: importing `json` fails with `code`.
#[test]
fn import() {
    let failures: Vec<String> = cases("import.cases.haus")
        .iter()
        .filter_map(|(tag, fields)| {
            let json = text(fields, "json");
            let failure = match (tag.as_str(), fields.get("output")) {
                ("Read", Some(output)) => match haus::import_json(&json) {
                    Ok(v) if haus::equals(&v, output) => None,
                    Ok(v) => Some(format!("read as {}", canonical(&v))),
                    Err(e) => Some(format!("can't read it: {e}")),
                },
                ("Err", None) => rejected(haus::import_json(&json), fields),
                _ => panic!("not a case: {}", canonical(fields)),
            };
            failure.map(|why| format!("{tag} {json}: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "import cases failed:\n{}", failures.join("\n"));
}

/// `Ok { json, output }`: reading `json` as self-describing JSON Lines gives
/// the values `output`. `Err { json, code, path? }`: reading fails with
/// `code`, at `path` (which starts with the line's index) if it gives one.
#[test]
fn json_lines() {
    let failures: Vec<String> = cases("lines.cases.haus")
        .iter()
        .filter_map(|(tag, fields)| {
            let json = text(fields, "json");
            let read = haus::json::from_haus_json_lines(&json);
            let failure = match (tag.as_str(), fields.get("output")) {
                ("Ok", Some(Value::Array(output))) => match read {
                    Ok(v) if v.len() == output.len() && v.iter().zip(output).all(|(a, b)| haus::equals(a, b)) => None,
                    Ok(v) => Some(format!("read as {}", canonical(&Value::Array(v)))),
                    Err(e) => Some(format!("can't read it: {:?} ({e})", e.code())),
                },
                ("Err", None) => rejected(read.map(Value::Array), fields),
                _ => panic!("not a case: {}", canonical(fields)),
            };
            failure.map(|why| format!("{tag} {json:?}: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "JSON Lines cases failed:\n{}", failures.join("\n"));
}

/// Every `valid/NAME.jsonl` is the file's values as self-describing JSON
/// Lines, an envelope per value: writing them gives it (line by line, as
/// data), and reading it gives them back.
#[test]
fn valid_files_are_self_describing_cases() {
    // `sorted` and `==` on `Json` recurse once per JSON level, and
    // valid/depth-limit.jsonl has more than 500. A 2 MiB test thread holds
    // about 1000 in a debug build on macOS; a bigger stack leaves room on
    // every platform.
    std::thread::Builder::new()
        .stack_size(64 << 20)
        .spawn(compare_valid_files)
        .unwrap()
        .join()
        .unwrap_or_else(|e| std::panic::resume_unwind(e));
}

fn compare_valid_files() {
    let mut paths: Vec<_> = fs::read_dir(suite("valid"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "haus"))
        .collect();
    paths.sort();
    assert!(!paths.is_empty());
    let lines = |text: &str| text.lines().map(str::to_owned).collect::<Vec<_>>();
    let failures: Vec<String> = paths
        .iter()
        .filter_map(|path| {
            let name = path.file_stem().unwrap().to_string_lossy().into_owned();
            let values = haus::parse_bytes(&fs::read(path).unwrap()).unwrap();
            let expected = fs::read_to_string(path.with_extension("jsonl")).unwrap();
            let failure = match haus::json::to_haus_json_lines(&values) {
                Err(e) => Some(format!("can't write it: {e}")),
                Ok(written)
                    if lines(&written).len() != lines(&expected).len()
                        || !lines(&written).iter().zip(lines(&expected)).all(|(a, b)| same_json(a, &b)) =>
                {
                    Some(format!("written as {written}"))
                }
                Ok(_) => match haus::json::from_haus_json_lines(&expected) {
                    Ok(v) if v.len() == values.len() && v.iter().zip(&values).all(|(a, b)| haus::equals(a, b)) => None,
                    Ok(v) => Some(format!("read as {}", canonical(&Value::Array(v)))),
                    Err(e) => Some(format!("can't read it: {e}")),
                },
            };
            failure.map(|why| format!("{name}.jsonl: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "valid/*.jsonl as self-describing cases failed:\n{}", failures.join("\n"));
}
