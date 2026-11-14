//! The plain JSON suite (test-suite/json/plain.cases.haus, spec §16.3), run
//! on the code haus-build generates for plain.schema.haus (see build.rs).
//!
//! - `Ok { type, input, json, output? }`: decoding `input` with `type` and
//!   writing the result gives `json`, and reading `json` gives a value that
//!   encodes to `output` (or `input`).
//! - `Read { type, json, output }`: reading `json` gives `output`.
//! - `Err { type, json }`: reading `json` fails.
//!
//! JSON is compared as data: member order and whitespace don't matter, and
//! numbers compare by their text.

mod suite {
    include!(concat!(env!("OUT_DIR"), "/json_suite.rs"));
}

use haus::{Json, Value, canonical};
use std::fs;
use std::path::Path;

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

fn same_json(a: &str, b: &str) -> Result<bool, String> {
    let parse = |t: &str| haus::json::parse(t).map(sorted).map_err(|e| format!("{t}: {e}"));
    Ok(parse(a)? == parse(b)?)
}

enum Kind {
    Ok,
    Read,
    Err,
}

struct Case {
    kind: Kind,
    ty: String,
    json: String,
    input: Option<Value>,
    output: Option<Value>,
}

impl Case {
    fn parse(v: &Value) -> Result<Case, String> {
        let not_a_case = || format!("not a case: {}", canonical(v));
        let Value::Variant { tag, args } = v else { return Err(not_a_case()) };
        let [fields @ Value::Record(_)] = args.as_slice() else { return Err(not_a_case()) };
        let kind = match tag.as_str() {
            "Ok" => Kind::Ok,
            "Read" => Kind::Read,
            "Err" => Kind::Err,
            _ => return Err(not_a_case()),
        };
        let text = |key: &str| match fields.get(key) {
            Some(Value::String(s)) => Ok(s.clone()),
            _ => Err(not_a_case()),
        };
        Ok(Case {
            kind,
            ty: text("type")?,
            json: text("json")?,
            input: fields.get("input").cloned(),
            output: fields.get("output").cloned(),
        })
    }

    fn name(&self) -> String {
        let kind = match self.kind {
            Kind::Ok => "Ok",
            Kind::Read => "Read",
            Kind::Err => "Err",
        };
        format!("{kind} {} {}", self.ty, self.json)
    }

    /// None if the case passes, what went wrong otherwise.
    fn failure(&self) -> Option<String> {
        let read = || suite::plain::read(&self.ty, &self.json).ok_or_else(|| format!("no type {}", self.ty));
        let expect_read = |expected: &Value| match read() {
            Ok(Ok(v)) if canonical(&v) == canonical(expected) => None,
            Ok(Ok(v)) => Some(format!("read as {}, expected {}", canonical(&v), canonical(expected))),
            Ok(Err(e)) => Some(format!("can't read the JSON: {e}")),
            Err(e) => Some(e),
        };
        match (&self.kind, &self.input, &self.output) {
            (Kind::Ok, Some(input), output) => {
                let written = match suite::plain::write(&self.ty, input) {
                    None => return Some(format!("no type {}", self.ty)),
                    Some(Err(e)) => return Some(e),
                    Some(Ok(text)) => text,
                };
                match same_json(&written, &self.json) {
                    Ok(true) => expect_read(output.as_ref().unwrap_or(input)),
                    Ok(false) => Some(format!("written as {written}")),
                    Err(e) => Some(e),
                }
            }
            (Kind::Read, _, Some(output)) => expect_read(output),
            (Kind::Err, None, None) => match read() {
                Ok(Ok(v)) => Some(format!("read as {}, expected an error", canonical(&v))),
                Ok(Err(_)) => None,
                Err(e) => Some(e),
            },
            _ => Some("not a well-formed case".into()),
        }
    }
}

#[test]
fn plain_json_conformance() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/json/plain.cases.haus");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let values = haus::parse(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let cases: Vec<Case> = values.iter().map(Case::parse).collect::<Result<_, _>>().unwrap();
    assert!(!cases.is_empty(), "no cases in {}", path.display());
    let failures: Vec<String> =
        cases.iter().filter_map(|c| c.failure().map(|why| format!("{}: {why}", c.name()))).collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}
