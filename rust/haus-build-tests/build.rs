//! Generates the Rust types for features.schema.haus, and for every schema of
//! the schema conformance suite (test-suite/schema, spec §15) a module with a
//! `roundtrip` function: decode a value with a type named by a string, then
//! encode the result. Each schema is also compiled without its attributes,
//! as `<name>::bare`, which must give the same results (attributes don't
//! matter, spec §15). tests/schema_conformance.rs runs the cases with both.
//!
//! For the JSON suite (test-suite/json, spec §16.3) it generates the types of
//! plain.schema.haus, with `write` and `read`: a value decoded with a type
//! written as plain JSON, and plain JSON read with a type and encoded.
//! tests/json_conformance.rs runs its cases.

use std::path::{Path, PathBuf};
use std::{env, fs};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    haus_build::Config::new().compile("features.schema.haus")?;

    let suite = Path::new(&env::var("CARGO_MANIFEST_DIR")?).join("../../test-suite/schema");
    println!("cargo::rerun-if-changed={}", suite.display());
    let mut schemas: Vec<PathBuf> = fs::read_dir(&suite)?
        .map(|e| e.map(|e| e.path()))
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter(|p| p.to_string_lossy().ends_with(".schema.haus"))
        .collect();
    schemas.sort();

    let names: Vec<String> = schemas.iter().map(|p| suite_name(p)).collect();
    let modules = schemas
        .iter()
        .zip(&names)
        .map(|(path, name)| {
            // The suite uses attributes this version doesn't define on purpose: no warnings.
            haus_build::Config::new().quiet().compile_as(path, &format!("suite_{name}"))?;
            haus_build::Config::new().quiet().without_attributes().compile_as(path, &format!("suite_{name}_bare"))?;
            Ok(module(name, &fs::read_to_string(path)?))
        })
        .collect::<Result<Vec<_>, Box<dyn std::error::Error>>>()?;
    let code = format!("{}{}", dispatch(&names), modules.concat());
    fs::write(Path::new(&env::var("OUT_DIR")?).join("schema_suite.rs"), code)?;

    let plain = suite.join("../json/plain.schema.haus");
    haus_build::Config::new().compile_as(&plain, "suite_json_plain")?;
    fs::write(Path::new(&env::var("OUT_DIR")?).join("json_suite.rs"), json_module(&fs::read_to_string(&plain)?))?;
    Ok(())
}

/// `pub mod plain { <generated types> pub fn write(…) pub fn read(…) }`.
fn json_module(text: &str) -> String {
    let arms = |f: &str| -> String {
        definitions(text).iter().map(|t| format!("            {t:?} => {f}::<{t}>(x),\n")).collect()
    };
    let (write, read) = (arms("write_as"), arms("read_as"));
    format!(
        r#"/// The types of test-suite/json/plain.schema.haus.
pub mod plain {{
    include!(concat!(env!("OUT_DIR"), "/suite_json_plain.rs"));

    fn write_as<T: ::haus::Decode + ::haus::ToJson>(v: &::haus::Value) -> Result<String, String> {{
        let x = T::decode(v).map_err(|e| format!("can't decode the input: {{e}}"))?;
        ::haus::json::to_string(&x).map_err(|e| format!("can't write it as JSON: {{e}}"))
    }}

    fn read_as<T: ::haus::FromJson + ::haus::Encode>(json: &str) -> Result<::haus::Value, ::haus::Error> {{
        let x = ::haus::json::from_str::<T>(json)?;
        Ok(::haus::Encode::encode(&x)?)
    }}

    /// Decode `x` with the type `ty`, and write the result as plain JSON;
    /// None if there is no such type.
    pub fn write(ty: &str, x: &::haus::Value) -> Option<Result<String, String>> {{
        Some(match ty {{
{write}            _ => return None,
        }})
    }}

    /// Read the plain JSON `x` with the type `ty`, and encode the result;
    /// None if there is no such type.
    pub fn read(ty: &str, x: &str) -> Option<Result<::haus::Value, ::haus::Error>> {{
        Some(match ty {{
{read}            _ => return None,
        }})
    }}
}}
"#
    )
}

/// `numbers` for `numbers.schema.haus`.
fn suite_name(path: &Path) -> String {
    let file = path.file_name().unwrap_or_default().to_string_lossy();
    file.trim_end_matches(".schema.haus").to_owned()
}

/// The names of a schema's non-generic definitions: `type Name = …` at the
/// start of a line, leaving out streams (which have no Rust type).
fn definitions(text: &str) -> Vec<&str> {
    text.lines()
        .filter_map(|line| line.strip_prefix("type "))
        .filter_map(|def| def.split_once('='))
        .filter(|(_, ty)| !ty.trim_start().starts_with("Stream "))
        .map(|(name, _)| name.trim())
        .filter(|name| !name.is_empty() && !name.contains(char::is_whitespace))
        .collect()
}

/// The suite's files, and `roundtrip` by file name.
fn dispatch(names: &[String]) -> String {
    let files = names.iter().map(|n| format!("{n:?}")).collect::<Vec<_>>().join(", ");
    let arms: String = names
        .iter()
        .map(|n| {
            format!("        {n:?} if bare => {n}::bare::roundtrip(ty, v),\n        {n:?} => {n}::roundtrip(ty, v),\n")
        })
        .collect();
    format!(
        r#"/// The suite's schema files: `numbers` for numbers.schema.haus.
pub const FILES: &[&str] = &[{files}];

/// Decode `v` with the type `ty` of the schema `file` (without its attributes
/// if `bare`), then encode the result; None if there is no such type.
pub fn roundtrip(file: &str, ty: &str, v: &::haus::Value, bare: bool) -> Option<Result<::haus::Value, ::haus::DecodeError>> {{
    match file {{
{arms}        _ => None,
    }}
}}

"#
    )
}

/// `pub mod <name> { <generated types> pub fn roundtrip(…) pub mod bare { … } }`.
fn module(name: &str, text: &str) -> String {
    let arms: String = definitions(text)
        .iter()
        .map(|t| format!("            {t:?} => <{t} as ::haus::Decode>::decode(v).and_then(|x| encode(&x)),\n"))
        .collect();
    let roundtrip = format!(
        r#"    /// Encode a decoded value again: an error says so, as a decode error.
    #[allow(dead_code)]
    fn encode<T: ::haus::Encode>(x: &T) -> Result<::haus::Value, ::haus::DecodeError> {{
        ::haus::Encode::encode(x).map_err(|e| ::haus::DecodeError::new(e.code, format!("can't encode it again: {{e}}")))
    }}

    /// Decode `v` with the type `ty`, then encode the result; None if the schema has no such type.
    #[allow(deprecated)]
    pub fn roundtrip(ty: &str, v: &::haus::Value) -> Option<Result<::haus::Value, ::haus::DecodeError>> {{
        Some(match ty {{
{arms}            _ => return None,
        }})
    }}
"#
    );
    format!(
        r#"pub mod {name} {{
    include!(concat!(env!("OUT_DIR"), "/suite_{name}.rs"));

{roundtrip}
    /// The same schema without its attributes.
    pub mod bare {{
        include!(concat!(env!("OUT_DIR"), "/suite_{name}_bare.rs"));

{roundtrip}    }}
}}

"#
    )
}
