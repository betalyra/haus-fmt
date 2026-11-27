//! The schema conformance suite (test-suite/schema, spec §14, §15), run on
//! the runtime checker.
//!
//! Each case is `Ok { type, input, output? }` or `Err { type, input, code, path }`.
//! Ok: decoding `input` with `type` succeeds, giving a value equal to `output`
//! (or `input`) that the writer takes; checking it finds no error. Err:
//! decoding fails with the error code `code` (spec §17) at the place `path`
//! (spec §15, compared as text), and checking finds an error with that code
//! at that place. Every case runs on each schema twice: as written,
//! and without its attributes, which must not change any result.
//!
//! `invalid/*.schema.haus` must be rejected (spec §14), with the code in
//! `invalid/NAME.error`.

use haus::{Value, canonical};
use haus_schema::{EncodeOptions, NoImports, Options, Schema, Severity};
use std::fs;
use std::path::{Path, PathBuf};

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
    /// For an `Ok`, the places of the secrets in the decoded value: encoding
    /// without revealing secrets fails with `cannot-encode` at one of them.
    secrets: Vec<String>,
}

impl Case {
    /// A case from its value in a `.cases.haus` file.
    fn parse(v: &Value) -> Result<Case, String> {
        let fields = match v {
            Value::Variant { tag, args } if tag == "Ok" || tag == "Err" => match args.as_slice() {
                [fields @ Value::Record(_)] => fields,
                _ => return Err(format!("not a case: {}", canonical(v))),
            },
            _ => return Err(format!("not a case: {}", canonical(v))),
        };
        let ok = matches!(v, Value::Variant { tag, .. } if tag == "Ok");
        match (fields.get("type"), fields.get("input")) {
            (Some(Value::String(ty)), Some(input)) => Ok(Case {
                ok,
                ty: ty.to_string(),
                input: input.clone(),
                output: fields.get("output").unwrap_or(input).clone(),
                code: match fields.get("code") {
                    Some(Value::String(code)) => code.to_string(),
                    _ if ok => String::new(),
                    _ => return Err(format!("an Err case without a code: {}", canonical(v))),
                },
                path: match fields.get("path") {
                    Some(Value::String(path)) => path.to_string(),
                    _ if ok => String::new(),
                    _ => return Err(format!("an Err case without a path: {}", canonical(v))),
                },
                secrets: match fields.get("secrets") {
                    Some(Value::Array(places)) => places.iter().filter_map(|p| p.as_str()).map(str::to_owned).collect(),
                    _ => vec![],
                },
            }),
            _ => Err(format!("not a case: {}", canonical(v))),
        }
    }

    /// `Ok F64 1.0`.
    fn name(&self) -> String {
        format!("{} {} {}", if self.ok { "Ok" } else { "Err" }, self.ty, canonical(&self.input))
    }

    /// Runs the case: None if it passes, what went wrong otherwise.
    fn failure(&self, schema: &Schema) -> Option<String> {
        let decoded = schema.decode(&self.ty, &self.input);
        let errors = schema.check(&self.ty, std::slice::from_ref(&self.input));
        let errors: Vec<_> = errors.iter().filter(|i| i.severity == Severity::Error).collect();
        // Encoded with revealSecrets, compared with the output; then without it (spec §15).
        let reveal = EncodeOptions { reveal_secrets: true, ..EncodeOptions::default() };
        match (self.ok, decoded.as_ref().map(|d| (d, schema.encode_with(&self.ty, d, &reveal)))) {
            (true, Ok((_, Err(e)))) => Some(format!("decoded, but can't be encoded: {e}")),
            (true, Ok((_, Ok(out)))) if canonical(&out) != canonical(&self.output) => {
                Some(format!("encoded as {}, expected {}", canonical(&out), canonical(&self.output)))
            }
            (true, Ok((d, Ok(_)))) => match (schema.encode(&self.ty, d), errors.first()) {
                (_, Some(e)) => Some(format!("decodes, but the check reports {e}")),
                (Ok(_), None) if self.secrets.is_empty() => None,
                (Ok(_), None) => Some(format!("encoded without revealing its secrets at {:?}", self.secrets)),
                (Err(e), None) if self.secrets.is_empty() => Some(format!("can't be encoded: {e}")),
                (Err(e), None) if e.code.as_str() == "cannot-encode" && self.secrets.contains(&e.path_string()) => None,
                (Err(e), None) => Some(format!(
                    "refused with {} at {}, expected a secret at {:?}",
                    e.code,
                    e.path_string(),
                    self.secrets
                )),
            },
            (true, Err(e)) => Some(format!("failed to decode: {e}")),
            (false, Ok((d, _))) => Some(format!("decoded, expected an error (as {d})")),
            (false, Err(_)) if errors.is_empty() => Some("fails to decode, but the check finds no error".into()),
            (false, Err(e)) if e.code.as_str() != self.code => {
                Some(format!("fails with {} ({e}), expected {}", e.code, self.code))
            }
            (false, Err(e)) if e.path_string() != self.path => {
                Some(format!("fails at {} ({e}), expected {}", e.path_string(), self.path))
            }
            (false, Err(_)) if errors.iter().all(|i| i.code.as_str() != self.code || i.path_string() != self.path) => {
                Some(format!("the check reports {}, expected {} at {}", errors[0], self.code, self.path))
            }
            (false, Err(_)) => None,
        }
    }
}

fn suite() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/schema")
}

/// The files in `dir` ending in `suffix`, sorted.
fn files(dir: &Path, suffix: &str) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
        .map(|e| e.unwrap().path())
        .filter(|p| p.to_string_lossy().ends_with(suffix))
        .collect();
    paths.sort();
    assert!(!paths.is_empty(), "no {suffix} files in {}", dir.display());
    paths
}

#[test]
fn schema_conformance() {
    let (mut count, mut failures) = (0, vec![]);
    for path in files(&suite(), ".schema.haus") {
        let name = path.file_name().unwrap().to_string_lossy().replace(".schema.haus", "");
        let text = fs::read_to_string(&path).unwrap();
        let cases_path = path.with_file_name(format!("{name}.cases.haus"));
        let values = haus::parse(&fs::read_to_string(&cases_path).unwrap())
            .unwrap_or_else(|e| panic!("{}: {e}", cases_path.display()));
        let cases: Vec<Case> =
            values.iter().map(Case::parse).collect::<Result<_, _>>().unwrap_or_else(|e| panic!("{name}: {e}"));
        for (without_attributes, label) in [(false, ""), (true, " (without attributes)")] {
            let options = Options { without_attributes, ..Options::default() };
            let schema = Schema::parse_with(&text, &options).unwrap_or_else(|e| panic!("{name}.schema.haus: {e}"));
            failures.extend(cases.iter().filter_map(|c| {
                c.failure(&schema).map(|why| format!("{name}.cases.haus{label}: {}: {why}", c.name()))
            }));
            count += cases.len();
        }
    }
    assert!(failures.is_empty(), "{} of {count} cases failed:\n{}", failures.len(), failures.join("\n"));
    println!("{count} cases passed (each schema with and without its attributes)");
}

#[test]
fn invalid_schemas_are_rejected() {
    let failures: Vec<String> = files(&suite().join("invalid"), ".schema.haus")
        .iter()
        .filter_map(|path| {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            let expected = fs::read_to_string(path.with_extension("").with_extension("error")).unwrap();
            // Read as a file is: invalid UTF-8 is invalid-utf8.
            let parsed = match String::from_utf8(fs::read(path).unwrap()) {
                Ok(text) => Schema::parse(&text),
                Err(_) => Schema::load(path, &NoImports),
            };
            match parsed {
                Ok(_) => Some(format!("{name}: accepted")),
                Err(e) if e.code().map(|c| c.as_str()) != Some(expected.trim()) => {
                    Some(format!("{name}: {:?} ({e}), expected {}", e.code(), expected.trim()))
                }
                Err(_) => None,
            }
        })
        .collect();
    assert!(failures.is_empty(), "invalid schemas:\n{}", failures.join("\n"));
}
