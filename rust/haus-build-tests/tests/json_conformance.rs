//! The schema-based JSON suite (test-suite/json/schema-based.cases.haus, spec
//! §16.3), run on the code haus-fmt-build generates for
//! schema-based.schema.haus (see build.rs).
//!
//! - `Ok { type, input, json, output? }`: decoding `input` with `type` and
//!   writing the result gives `json`, and reading `json` gives a value that
//!   encodes to `output` (or `input`).
//! - `Read { type, json, output }`: reading `json` gives `output`.
//! - `Err { type, json, code, path? }`: reading `json` fails with the error
//!   code `code` (spec §17), at `path` in the JSON if the case gives one
//!   (spec §16.3 "Places").
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
fn sorted(mut json: Json) -> Json {
    match &mut json {
        Json::Array(items) => Json::Array(std::mem::take(items).into_iter().map(sorted).collect()),
        Json::Object(members) => {
            let mut members: Vec<_> = std::mem::take(members).into_iter().map(|(k, v)| (k, sorted(v))).collect();
            members.sort_by(|a, b| a.0.cmp(&b.0));
            Json::object(members).expect("names are unique")
        }
        _ => json,
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
    /// For an `Err`, the code it fails with.
    code: Option<String>,
    /// For an `Err`, the place in the JSON it fails at, if the case gives one.
    path: Option<String>,
    /// For an `Ok`, the places of its secrets (spec §15, "Encoding a secret").
    secrets: Vec<String>,
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
            Some(Value::String(s)) => Ok(s.to_string()),
            _ => Err(not_a_case()),
        };
        let secrets = match fields.get("secrets") {
            Some(Value::Array(places)) => places.iter().filter_map(|p| p.as_str()).map(str::to_owned).collect(),
            _ => vec![],
        };
        Ok(Case {
            kind,
            ty: text("type")?,
            json: text("json")?,
            input: fields.get("input").cloned(),
            output: fields.get("output").cloned(),
            code: text("code").ok(),
            path: text("path").ok(),
            secrets,
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
        let read = || suite::schema_based::read(&self.ty, &self.json).ok_or_else(|| format!("no type {}", self.ty));
        let expect_read = |expected: &Value| match read() {
            Ok(Ok(v)) if canonical(&v) == canonical(expected) => None,
            Ok(Ok(v)) => Some(format!("read as {}, expected {}", canonical(&v), canonical(expected))),
            Ok(Err(e)) => Some(format!("can't read the JSON: {e}")),
            Err(e) => Some(e),
        };
        match (&self.kind, &self.input, &self.output) {
            (Kind::Ok, Some(input), output) => {
                let (written, refused) = match suite::schema_based::write(&self.ty, input) {
                    None => return Some(format!("no type {}", self.ty)),
                    Some(Err(e)) => return Some(e),
                    Some(Ok(written)) => written,
                };
                // Without revealSecrets: refused at one of its secrets, or written as with it.
                let secrets = &self.secrets;
                match refused {
                    None if !secrets.is_empty() => return Some(format!("written without revealing {secrets:?}")),
                    Some((code, place)) if secrets.is_empty() || code != haus::ErrorCode::CannotEncode => {
                        return Some(format!("can't be written without revealSecrets: {code} at {place}"));
                    }
                    Some((_, place)) if !secrets.contains(&place) => {
                        return Some(format!("refused at {place}, expected a secret at {secrets:?}"));
                    }
                    _ => {}
                }
                match same_json(&written, &self.json) {
                    Ok(true) => expect_read(output.as_ref().unwrap_or(input)),
                    Ok(false) => Some(format!("written as {written}")),
                    Err(e) => Some(e),
                }
            }
            (Kind::Read, _, Some(output)) => expect_read(output),
            (Kind::Err, None, None) => match read() {
                Ok(Ok(v)) => Some(format!("read as {}, expected an error", canonical(&v))),
                Ok(Err(e)) if e.code().map(|c| c.as_str()) != self.code.as_deref() => {
                    Some(format!("fails with {:?} ({e}), expected {:?}", e.code(), self.code))
                }
                Ok(Err(e)) => match (&self.path, place(&e)) {
                    (Some(path), place) if place.as_deref() != Some(path.as_str()) => {
                        Some(format!("fails at {place:?} ({e}), expected {path}"))
                    }
                    _ => None,
                },
                Err(e) => Some(e),
            },
            _ => Some("not a well-formed case".into()),
        }
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

#[test]
fn schema_based_json_conformance() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/json/schema-based.cases.haus");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let values = haus::parse(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let cases: Vec<Case> = values.iter().map(Case::parse).collect::<Result<_, _>>().unwrap();
    assert!(!cases.is_empty(), "no cases in {}", path.display());
    let failures: Vec<String> =
        cases.iter().filter_map(|c| c.failure().map(|why| format!("{}: {why}", c.name()))).collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}
