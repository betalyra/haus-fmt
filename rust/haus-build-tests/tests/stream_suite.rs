//! Typed streams (test-suite/stream/typed.cases.haus, test-suite/README.md
//! "Stream suite", spec §15 "Streams"), run on the code haus-fmt-build
//! generates for typed.schema.haus (see build.rs): a `Stream a` type reads
//! the text with `haus::stream::decode::<A>` (which puts the item's index in
//! an error's path), any other type with `haus::from_str`. The runtime
//! checker runs the same cases in haus-schema/tests/stream_suite.rs.
//!
//! - `Ok { type, text, output }`: decoding succeeds, and encoding the decoded
//!   values gives `output` (an array for a stream), compared as values.
//! - `Err { type, text, code, path }`: decoding fails with `code` at `path`.

#[allow(dead_code)]
mod typed {
    include!(concat!(env!("OUT_DIR"), "/suite_stream_typed.rs"));
}

use haus::{Decode, Encode, Value, canonical, equals};
use std::path::{Path, PathBuf};

fn suite(file: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/stream").join(file)
}

/// A decoding error as its code and place (a syntax error's place is its line and column).
fn failed(e: haus::Error) -> (String, String) {
    let place = match &e {
        haus::Error::Decode(d) => d.place(),
        haus::Error::Syntax(s) => format!("{}:{}", s.line, s.column),
        other => other.to_string(),
    };
    (e.code().map(|c| c.to_string()).unwrap_or_default(), place)
}

fn encoded<T: Encode>(x: &T) -> Result<Value, (String, String)> {
    x.encode().map_err(|e| (e.code.to_string(), format!("can't encode it again: {e}")))
}

/// A stream of `T`s, read with the binding's stream decoding, encoded again as an array.
fn stream<T: Decode + Encode>(text: &str) -> Result<Value, (String, String)> {
    let items = haus::stream::decode::<T, _>(text.as_bytes()).collect::<Result<Vec<T>, _>>().map_err(failed)?;
    items.iter().map(encoded).collect::<Result<_, _>>().map(Value::Array)
}

/// One `T`, encoded again.
fn one<T: Decode + Encode>(text: &str) -> Result<Value, (String, String)> {
    encoded(&haus::from_str::<T>(text).map_err(failed)?)
}

/// Decode `text` with the schema's type `ty`.
fn decode(ty: &str, text: &str) -> Result<Value, (String, String)> {
    match ty {
        "Log" => stream::<typed::Entry>(text),
        "Points" => stream::<typed::Point>(text),
        "Entry" => one::<typed::Entry>(text),
        "Level" => one::<typed::Level>(text),
        "Point" => one::<typed::Point>(text),
        _ => panic!("typed.schema.haus has a type {ty} this harness doesn't know"),
    }
}

fn text<'a>(fields: &'a Value, key: &str) -> &'a str {
    match fields.get(key) {
        Some(Value::String(s)) => s,
        _ => panic!("not a case: {}", canonical(fields)),
    }
}

#[test]
fn typed_streams() {
    let cases = haus::parse(&std::fs::read_to_string(suite("typed.cases.haus")).unwrap()).unwrap();
    assert!(!cases.is_empty(), "no cases in typed.cases.haus");
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let Value::Variant { tag, args } = c else { panic!("not a case: {}", canonical(c)) };
            let [fields] = args.as_slice() else { panic!("not a case: {}", canonical(c)) };
            let (ty, source) = (text(fields, "type"), text(fields, "text"));
            let failure = match (tag.as_str(), decode(ty, source)) {
                ("Ok", Ok(value)) => {
                    let output = fields.get("output").unwrap_or_else(|| panic!("not a case: {}", canonical(c)));
                    (!equals(&value, output))
                        .then(|| format!("decoded as {}, expected {}", canonical(&value), canonical(output)))
                }
                ("Ok", Err((code, path))) => Some(format!("fails with {code} at {path}")),
                ("Err", Ok(value)) => Some(format!("decoded as {}", canonical(&value))),
                ("Err", Err(got)) => {
                    let want = (text(fields, "code").to_owned(), text(fields, "path").to_owned());
                    (got != want)
                        .then(|| format!("fails with {} at {}, expected {} at {}", got.0, got.1, want.0, want.1))
                }
                _ => panic!("not a case: {}", canonical(c)),
            };
            failure.map(|why| format!("{tag} {ty} {source:?}: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}
