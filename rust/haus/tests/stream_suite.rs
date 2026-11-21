//! The stream suite, test-suite/stream/limits.cases.haus (test-suite/README.md,
//! "Stream suite"): every case read whole, one character at a time, and split
//! in two at every position, with its value limit and strict mode (spec §6, §7);
//! a case with `whole` is parsed whole too (as `parse`, default limits). And
//! test-suite/stream/document.cases.haus: single documents (spec §6), read as
//! `from_str::<Value>`. Typed streams (typed.cases.haus) need a schema: they
//! are in haus-schema/tests/stream_suite.rs.
//! `HAUS_STREAM_SUITE` names another directory holding the suite's files.

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
    /// The values of the text parsed whole, where the case gives them.
    whole: Option<Outcome>,
}

/// `Ok([values])` or `Err("code")`.
fn outcome(v: &Value) -> Option<Outcome> {
    match v {
        Value::Variant { tag, args } => match (tag.as_str(), args.as_slice()) {
            ("Ok", [Value::Array(values)]) => Some(Ok(values.clone())),
            ("Err", [Value::String(code)]) => Some(Err(code.clone())),
            _ => None,
        },
        _ => None,
    }
}

fn case(v: &Value) -> Case {
    let fail = || panic!("not a case: {}", canonical(v).unwrap());
    let (Some(Value::String(text)), Some(Value::Number(max))) = (v.get("text"), v.get("maxValueLength")) else {
        fail()
    };
    let Some(result) = v.get("result").and_then(outcome) else { fail() };
    let whole = v.get("whole").map(|w| outcome(w).unwrap_or_else(|| fail()));
    let strict = matches!(v.get("strict"), Some(Value::Variant { tag, .. }) if tag == "True");
    Case { text: text.clone(), max_value_length: max.parse().unwrap(), strict, result, whole }
}

/// The values of the suite's file `name`.
fn suite_file(name: &str) -> Vec<Value> {
    let dir = std::env::var_os("HAUS_STREAM_SUITE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/stream"));
    let text = std::fs::read_to_string(dir.join(name)).unwrap();
    haus::parse(&text).unwrap()
}

fn cases() -> Vec<Case> {
    suite_file("limits.cases.haus").iter().map(case).collect()
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
    assert_eq!(cases.len(), 24, "the suite's cases");
    let mut failures = Vec::new();
    for c in &cases {
        for (how, chunks) in splits(&c.text) {
            let got = read(c, &chunks);
            if !same(&got, &c.result) {
                let shown = got.map(|vs| vs.iter().map(|v| canonical(v).unwrap()).collect::<Vec<_>>());
                failures.push(format!("{:?} max {} strict {}, {how}: {shown:?}", c.text, c.max_value_length, c.strict));
            }
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

/// The cases with `whole`: parsing the whole text (default limits, so no
/// value limit: it applies to stream readers only) gives these values.
#[test]
fn parsed_whole() {
    let cases: Vec<(Case, Outcome)> = cases().into_iter().filter_map(|c| c.whole.clone().map(|w| (c, w))).collect();
    assert!(!cases.is_empty(), "no cases with `whole`");
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|(c, want)| {
            let got: Outcome = haus::parse(&c.text).map_err(|e| e.code.to_string());
            (!same(&got, want)).then(|| {
                let shown = got.map(|vs| vs.iter().map(|v| canonical(v).unwrap()).collect::<Vec<_>>());
                format!("{:?} parsed whole: {shown:?}", c.text)
            })
        })
        .collect();
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

/// test-suite/stream/document.cases.haus: a single document (spec §6), read
/// as one value, gives `Ok(value)` or fails with `Err("code")`.
#[test]
fn single_documents() {
    let cases = suite_file("document.cases.haus");
    assert!(!cases.is_empty(), "no cases in document.cases.haus");
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let (Some(Value::String(text)), Some(Value::Variant { tag, args })) = (c.get("text"), c.get("result"))
            else {
                panic!("not a case: {}", canonical(c).unwrap())
            };
            let want: Result<Value, String> = match (tag.as_str(), args.as_slice()) {
                ("Ok", [value]) => Ok(value.clone()),
                ("Err", [Value::String(code)]) => Err(code.clone()),
                _ => panic!("not a case: {}", canonical(c).unwrap()),
            };
            let got = haus::from_str::<Value>(text);
            let pass = match (&got, &want) {
                (Ok(a), Ok(b)) => equals(a, b),
                (Err(e), Err(code)) => e.code().map(|c| c.as_str()) == Some(code.as_str()),
                _ => false,
            };
            (!pass).then(|| {
                let shown = got.as_ref().map(|v| canonical(v).unwrap()).map_err(|e| format!("{:?} ({e})", e.code()));
                format!("{text:?}: {shown:?}, expected {:?}", want.as_ref().map(|v| canonical(v).unwrap()))
            })
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}
