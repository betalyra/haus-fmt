//! The schema conformance suite (test-suite/schema, spec §15), run on the
//! code haus-fmt-build generates for its schemas (see build.rs).
//!
//! Each case is `Ok { type, input, output? }` or `Err { type, input, code, path }`.
//! Ok: decoding `input` with `type` succeeds, and encoding the result gives a
//! value equal to `output` (or `input`). Err: decoding fails with the error
//! code `code` (spec §17) at the place `path` (spec §15, compared as text). Every case runs on each schema twice: as written,
//! and without its attributes, which must not change any result.
//!
//! `invalid/*.schema.haus` must be rejected by haus-fmt-build (spec §14),
//! with the code in `invalid/NAME.error`.

mod suite {
    include!(concat!(env!("OUT_DIR"), "/schema_suite.rs"));
}

use haus::{Value, canonical};
use std::fs;
use std::path::Path;

/// A case: whether it should decode, the type, the input, and the expected output.
struct Case {
    ok: bool,
    ty: String,
    input: Value,
    output: Value,
    /// For an `Err`, the code it fails with.
    code: String,
    /// For an `Err`, where it fails: `$.items[2].price`.
    path: String,
}

impl Case {
    /// A case from its value in a `.cases.haus` file.
    fn parse(v: &Value) -> Result<Case, String> {
        let (ok, fields) = match v {
            Value::Variant { tag, args } if tag == "Ok" || tag == "Err" => match args.as_slice() {
                [fields @ Value::Record(_)] => (tag == "Ok", fields),
                _ => return Err(format!("not a case: {}", canonical(v))),
            },
            _ => return Err(format!("not a case: {}", canonical(v))),
        };
        match (fields.get("type"), fields.get("input")) {
            (Some(Value::String(ty)), Some(input)) => Ok(Case {
                ok,
                ty: ty.clone(),
                input: input.clone(),
                output: fields.get("output").unwrap_or(input).clone(),
                code: match fields.get("code") {
                    Some(Value::String(code)) => code.clone(),
                    _ if ok => String::new(),
                    _ => return Err(format!("an Err case without a code: {}", canonical(v))),
                },
                path: match fields.get("path") {
                    Some(Value::String(path)) => path.clone(),
                    _ if ok => String::new(),
                    _ => return Err(format!("an Err case without a path: {}", canonical(v))),
                },
            }),
            _ => Err(format!("not a case: {}", canonical(v))),
        }
    }

    /// `Ok F64 1.0`.
    fn name(&self) -> String {
        format!("{} {} {}", if self.ok { "Ok" } else { "Err" }, self.ty, canonical(&self.input))
    }

    /// Runs the case on the schema `file` (without its attributes if `bare`):
    /// None if it passes, what went wrong otherwise.
    fn failure(&self, file: &str, bare: bool) -> Option<String> {
        let Some(result) = suite::roundtrip(file, &self.ty, &self.input, bare) else {
            return Some(format!("no type {}", self.ty));
        };
        match (self.ok, result) {
            (true, Ok(encoded)) if canonical(&encoded) == canonical(&self.output) => {
                // The writer takes it too (it checks what it writes).
                haus::ser::write(&encoded).err().map(|e| format!("encoded, but can't be written: {e}"))
            }
            (true, Ok(encoded)) => {
                Some(format!("encoded as {}, expected {}", canonical(&encoded), canonical(&self.output)))
            }
            (true, Err(e)) => Some(format!("failed to decode: {e}")),
            (false, Ok(encoded)) => Some(format!("decoded, expected an error (encoded as {})", canonical(&encoded))),
            (false, Err(e)) if e.code.as_str() != self.code => {
                Some(format!("fails with {} ({e}), expected {}", e.code, self.code))
            }
            (false, Err(e)) if e.place() != self.path => {
                Some(format!("fails at {} ({e}), expected {}", e.place(), self.path))
            }
            (false, Err(_)) => None,
        }
    }
}

#[test]
fn schema_conformance() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/schema");
    assert!(!suite::FILES.is_empty(), "no schemas in {}", dir.display());
    let (count, failures) = suite::FILES.iter().fold((0, vec![]), |(count, mut failures), file| {
        let path = dir.join(format!("{file}.cases.haus"));
        let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let values = haus::parse(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        let cases: Vec<Case> =
            values.iter().map(Case::parse).collect::<Result<_, _>>().unwrap_or_else(|e| panic!("{file}: {e}"));
        for (bare, label) in [(false, ""), (true, " (without attributes)")] {
            failures.extend(cases.iter().filter_map(|c| {
                c.failure(file, bare).map(|why| format!("{file}.cases.haus{label}: {}: {why}", c.name()))
            }));
        }
        (count + cases.len(), failures)
    });
    assert!(failures.is_empty(), "{} of {count} cases failed:\n{}", failures.len(), failures.join("\n"));
}

#[test]
fn invalid_schemas_are_rejected() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/schema/invalid");
    let mut paths: Vec<_> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
        .map(|e| e.unwrap().path())
        .filter(|p| p.to_string_lossy().ends_with(".schema.haus"))
        .collect();
    paths.sort();
    assert!(!paths.is_empty(), "no schemas in {}", dir.display());
    let none = haus_build::Packages::none();
    let failures: Vec<String> = paths
        .iter()
        .flat_map(|path| {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let expected = fs::read_to_string(path.with_extension("").with_extension("error")).unwrap();
            let expected = expected.trim();
            // The generators take text: a file that isn't UTF-8 is rejected when it
            // is read (`invalid-utf8`, checked by haus-fmt-schema's own suite).
            let Ok(text) = String::from_utf8(fs::read(path).unwrap()) else {
                return (expected != "invalid-utf8")
                    .then(|| format!("{name}: not UTF-8, expected {expected}"))
                    .into_iter()
                    .collect::<Vec<_>>();
            };
            let why = |what: &str, result: Result<String, haus_build::Error>| match result {
                Ok(_) => Some(format!("{name} ({what}): accepted")),
                Err(e) if e.code().as_str() != expected => {
                    Some(format!("{name} ({what}): {} ({e}), expected {expected}", e.code()))
                }
                Err(_) => None,
            };
            let rust = why("Rust", haus_build::generate(&text, "suite/invalid", &[], &none));
            let roc = why("Roc", haus_build::roc::generate(&text, "Invalid", "suite/invalid", &[], &none));
            [rust, roc].into_iter().flatten().collect::<Vec<_>>()
        })
        .collect();
    assert!(failures.is_empty(), "invalid schemas:\n{}", failures.join("\n"));
}
