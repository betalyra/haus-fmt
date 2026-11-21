//! Typed streams (test-suite/stream/typed.schema.haus and typed.cases.haus,
//! test-suite/README.md "Stream suite", spec §15 "Streams"), on the runtime
//! checker: a `Stream a` type decodes the text's values with
//! `Schema::decode_stream` (which puts the item's index in an error's path),
//! any other type decodes the text's one value (`haus::from_str`, then
//! `Schema::decode`).
//!
//! - `Ok { type, text, output }`: decoding succeeds; the decoded values
//!   (the values an encoder writes) equal `output`, an array for a stream.
//! - `Err { type, text, code, path }`: decoding fails with `code` at `path`.

use haus::{Value, canonical, equals};
use haus_schema::Schema;
use std::path::{Path, PathBuf};

/// The suite's file `file`; `HAUS_STREAM_SUITE` names another directory holding them.
fn suite(file: &str) -> PathBuf {
    std::env::var_os("HAUS_STREAM_SUITE")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/stream"))
        .join(file)
}

fn text<'a>(fields: &'a Value, key: &str) -> &'a str {
    match fields.get(key) {
        Some(Value::String(s)) => s,
        _ => panic!("not a case: {}", canonical(fields)),
    }
}

/// Decode `text` as the type `ty`: the decoded value (an array of the items
/// for a stream), or the error's code and path.
fn decode(schema: &Schema, ty: &str, text: &str) -> Result<Value, (String, String)> {
    let definition = schema.definition(ty).unwrap_or_else(|| panic!("no type {ty}"));
    if schema.instance(definition.template).stream {
        let values = haus::parse(text).map_err(|e| (e.code.to_string(), format!("{}:{}", e.line, e.column)))?;
        let items = schema.decode_stream(ty, &values).map_err(|e| (e.code.to_string(), e.path_string()))?;
        Ok(Value::Array(items))
    } else {
        let value = haus::from_str::<Value>(text).map_err(|e| {
            let place = match &e {
                haus::Error::Decode(d) => d.place(),
                other => format!("{other}"),
            };
            (e.code().map(|c| c.to_string()).unwrap_or_default(), place)
        })?;
        schema.decode(ty, &value).map_err(|e| (e.code.to_string(), e.path_string()))
    }
}

#[test]
fn typed_streams() {
    let schema = Schema::parse(&std::fs::read_to_string(suite("typed.schema.haus")).unwrap()).unwrap();
    let cases = haus::parse(&std::fs::read_to_string(suite("typed.cases.haus")).unwrap()).unwrap();
    assert!(!cases.is_empty(), "no cases in typed.cases.haus");
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let Value::Variant { tag, args } = c else { panic!("not a case: {}", canonical(c)) };
            let [fields] = args.as_slice() else { panic!("not a case: {}", canonical(c)) };
            let (ty, source) = (text(fields, "type"), text(fields, "text"));
            let got = decode(&schema, ty, source);
            let failure = match (tag.as_str(), &got) {
                ("Ok", Ok(value)) => {
                    let output = fields.get("output").unwrap_or_else(|| panic!("not a case: {}", canonical(c)));
                    match haus::ser::write(value) {
                        Err(e) => Some(format!("decoded, but can't be written: {e}")),
                        Ok(_) if !equals(value, output) => {
                            Some(format!("decoded as {}, expected {}", canonical(value), canonical(output)))
                        }
                        Ok(_) => None,
                    }
                }
                ("Ok", Err((code, path))) => Some(format!("fails with {code} at {path}")),
                ("Err", Ok(value)) => Some(format!("decoded as {}", canonical(value))),
                ("Err", Err(got)) => {
                    let want = (text(fields, "code").to_owned(), text(fields, "path").to_owned());
                    (got != &want)
                        .then(|| format!("fails with {} at {}, expected {} at {}", got.0, got.1, want.0, want.1))
                }
                _ => panic!("not a case: {}", canonical(c)),
            };
            failure.map(|why| format!("{tag} {ty} {source:?}: {why}"))
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}
