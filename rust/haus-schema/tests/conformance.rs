//! The schema conformance suite (test-suite/schema, spec §14, §15), run on
//! the runtime checker.
//!
//! Each case is `Ok { type, input, output? }` or `Err { type, input }`. Ok:
//! decoding `input` with `type` succeeds, giving a value equal to `output`
//! (or `input`) that the writer takes; checking it finds no error. Err:
//! decoding fails, and checking finds an error. Every case runs on each
//! schema twice: as written, and without its attributes, which must not
//! change any result.
//!
//! `invalid/*.schema.haus` must be rejected (spec §14).

use haus::{Value, canonical};
use haus_schema::{Options, Schema, Severity};
use std::fs;
use std::path::{Path, PathBuf};

/// A case: whether it should decode, the type, the input, and the expected output.
struct Case {
    ok: bool,
    ty: String,
    input: Value,
    output: Value,
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
                ty: ty.clone(),
                input: input.clone(),
                output: fields.get("output").unwrap_or(input).clone(),
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
        match (self.ok, decoded) {
            (true, Ok(out)) if canonical(&out) != canonical(&self.output) => {
                Some(format!("decoded as {}, expected {}", canonical(&out), canonical(&self.output)))
            }
            (true, Ok(out)) => match (haus::ser::write(&out), errors.first()) {
                (Err(e), _) => Some(format!("decoded, but can't be written: {e}")),
                (_, Some(e)) => Some(format!("decodes, but the check reports {e}")),
                _ => None,
            },
            (true, Err(e)) => Some(format!("failed to decode: {e}")),
            (false, Ok(out)) => Some(format!("decoded, expected an error (as {})", canonical(&out))),
            (false, Err(_)) if errors.is_empty() => Some("fails to decode, but the check finds no error".into()),
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
    let accepted: Vec<String> = files(&suite().join("invalid"), ".schema.haus")
        .iter()
        .filter(|path| Schema::parse(&fs::read_to_string(path).unwrap()).is_ok())
        .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert!(accepted.is_empty(), "invalid schemas were accepted:\n{}", accepted.join("\n"));
}
