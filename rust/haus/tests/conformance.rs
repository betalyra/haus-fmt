//! The language-neutral conformance suite (test-suite/README.md).

use haus::Value;
use serde_json::{Map, Value as Json, json};
use std::fs;
use std::path::{Path, PathBuf};

fn suite(dir: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite").join(dir)
}

fn cases(dir: &str) -> Vec<PathBuf> {
    let mut files: Vec<_> = fs::read_dir(suite(dir))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "haus"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no cases in test-suite/{dir}");
    files
}

/// A value as self-describing JSON (spec §16.2), the suite's encoding,
/// built here independently of the crate's own writer.
fn suite_json(v: &Value) -> Json {
    match v {
        Value::String(s) => json!(s),
        Value::Number(n) => json!({ "_num": n }),
        Value::Bytes(b) => json!({ "_bytes": b.iter().map(|x| format!("{x:02x}")).collect::<String>() }),
        Value::Array(items) => Json::Array(items.iter().map(suite_json).collect()),
        Value::Record(fields) => {
            json!({ "_rec": fields.iter().map(|(k, v)| (k.clone(), suite_json(v))).collect::<Map<_, _>>() })
        }
        Value::Variant { tag, args } if args.is_empty() => json!({ "_tag": tag }),
        Value::Variant { tag, args } => {
            json!({ "_tag": tag, "_args": args.iter().map(suite_json).collect::<Vec<_>>() })
        }
    }
}

/// The expected results, JSON Lines with an envelope per value;
/// `deep-nesting.jsonl` is deeper than serde_json's default limit.
fn read_json_lines(path: &Path) -> Vec<Json> {
    let text = fs::read_to_string(path).unwrap();
    text.lines()
        .map(|line| {
            let mut de = serde_json::Deserializer::from_str(line);
            de.disable_recursion_limit();
            serde::Deserialize::deserialize(&mut de).unwrap()
        })
        .collect()
}

#[test]
fn valid() {
    let mut failures = Vec::new();
    for path in cases("valid") {
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let expected = read_json_lines(&path.with_extension("jsonl"));
        match haus::parse_bytes(&fs::read(&path).unwrap()) {
            Ok(values) => {
                let actual: Vec<Json> = values.iter().map(|v| json!({ "_haus": 1, "_value": suite_json(v) })).collect();
                if actual != expected {
                    failures.push(format!("{name}: got {}", Json::Array(actual)));
                }
            }
            Err(e) => failures.push(format!("{name}: {e}")),
        }
    }
    assert!(failures.is_empty(), "valid cases failed:\n{}", failures.join("\n"));
}

/// `NAME.canonical`: the canonical form of each value, one per line (spec §12).
#[test]
fn valid_canonical() {
    let mut failures = Vec::new();
    for path in cases("valid") {
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let expected = fs::read_to_string(path.with_extension("canonical")).unwrap();
        let values = haus::parse_bytes(&fs::read(&path).unwrap()).unwrap();
        let actual: String = values.iter().map(|v| haus::canonical(v) + "\n").collect();
        if actual != expected {
            failures.push(format!("{name}: got {actual}"));
        }
    }
    assert!(failures.is_empty(), "canonical forms differ:\n{}", failures.join("\n"));
}

/// `NAME.hash`: `hash_all` of the file's values (spec §12), also hashed while
/// a stream is read, and `hash` of a file's only value.
#[cfg(feature = "hash")]
#[test]
fn valid_hash() {
    let mut failures = Vec::new();
    for path in cases("valid") {
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let expected = fs::read_to_string(path.with_extension("hash")).unwrap().trim().to_owned();
        let values = haus::parse_bytes(&fs::read(&path).unwrap()).unwrap();
        let mut hasher = haus::Hasher::new();
        let streamed: Vec<String> = values.iter().map(|v| hasher.add(v).digest()).collect();
        let actual = haus::hash_all(&values);
        if actual != expected || streamed.last().unwrap_or(&haus::hash_all([])) != &expected {
            failures.push(format!("{name}: got {actual}"));
        }
        if matches!(values.as_slice(), [v] if haus::hash(v) != expected) {
            failures.push(format!("{name}: hash of the only value differs"));
        }
    }
    assert!(failures.is_empty(), "hashes differ:\n{}", failures.join("\n"));
}

/// `NAME.error`: the code it is rejected with (spec §17).
fn expected_code(path: &Path) -> String {
    fs::read_to_string(path.with_extension("error")).unwrap().trim().to_owned()
}

#[test]
fn invalid() {
    let mut failures = Vec::new();
    for path in cases("invalid") {
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let expected = expected_code(&path);
        match haus::parse_bytes(&fs::read(&path).unwrap()) {
            Ok(values) => failures.push(format!("{name}: accepted as {values:?}")),
            Err(e) if e.code.as_str() != expected => {
                failures.push(format!("{name}: {} ({e}), expected {expected}", e.code))
            }
            Err(_) => {}
        }
    }
    assert!(failures.is_empty(), "invalid cases:\n{}", failures.join("\n"));
}
