//! The stream suite, test-suite/stream/limits.cases.haus (test-suite/README.md,
//! "Stream suite"): every case read whole, one character at a time, and split
//! in two at every position, with its value limit and strict mode (spec §6, §7).
//! `HAUS_STREAM_SUITE` names another directory holding the suite's file.

use haus::stream::{Options, Reader};
use haus::{Value, canonical, equals};
use std::path::PathBuf;

/// The values read, or the code of the error.
type Outcome = Result<Vec<Value>, String>;

struct Case {
    text: String,
    max_value_length: usize,
    strict: bool,
    result: Outcome,
}

fn case(v: &Value) -> Case {
    let fail = || panic!("not a case: {}", canonical(v));
    let (Some(Value::String(text)), Some(Value::Number(max))) = (v.get("text"), v.get("maxValueLength")) else {
        fail()
    };
    let result = match v.get("result") {
        Some(Value::Variant { tag, args }) => match (tag.as_str(), args.as_slice()) {
            ("Ok", [Value::Array(values)]) => Ok(values.clone()),
            ("Err", [Value::String(code)]) => Err(code.clone()),
            _ => fail(),
        },
        _ => fail(),
    };
    let strict = matches!(v.get("strict"), Some(Value::Variant { tag, .. }) if tag == "True");
    Case { text: text.clone(), max_value_length: max.parse().unwrap(), strict, result }
}

fn cases() -> Vec<Case> {
    let dir = std::env::var_os("HAUS_STREAM_SUITE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/stream"));
    let text = std::fs::read_to_string(dir.join("limits.cases.haus")).unwrap();
    haus::parse(&text).unwrap().iter().map(case).collect()
}

fn read(c: &Case, chunks: &[&str]) -> Outcome {
    let options = Options { max_value_length: c.max_value_length, require_terminator: c.strict, ..Options::default() };
    let mut reader = Reader::new(options);
    let mut values = Vec::new();
    for chunk in chunks {
        values.extend(reader.push(chunk.as_bytes()).map_err(|e| e.code.to_string())?);
    }
    values.extend(reader.finish().map_err(|e| e.code.to_string())?);
    Ok(values)
}

/// Whole, one character at a time, and in two pieces split at every character boundary.
fn splits(text: &str) -> Vec<(String, Vec<&str>)> {
    let by_char = text.char_indices().map(|(i, c)| &text[i..i + c.len_utf8()]).collect();
    let mut out = vec![("whole".to_string(), vec![text]), ("by character".to_string(), by_char)];
    out.extend(text.char_indices().map(|(i, _)| (format!("split at byte {i}"), vec![&text[..i], &text[i..]])));
    out
}

fn same(got: &Outcome, want: &Outcome) -> bool {
    match (got, want) {
        (Ok(a), Ok(b)) => a.len() == b.len() && a.iter().zip(b).all(|(x, y)| equals(x, y)),
        (Err(a), Err(b)) => a == b,
        _ => false,
    }
}

#[test]
fn stream_suite() {
    let cases = cases();
    assert_eq!(cases.len(), 19, "the suite's cases");
    let mut failures = Vec::new();
    for c in &cases {
        for (how, chunks) in splits(&c.text) {
            let got = read(c, &chunks);
            if !same(&got, &c.result) {
                let shown = got.map(|vs| vs.iter().map(canonical).collect::<Vec<_>>());
                failures.push(format!("{:?} max {} strict {}, {how}: {shown:?}", c.text, c.max_value_length, c.strict));
            }
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}
