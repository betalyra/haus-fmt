//! Generates the Rust types of every schema the fuzzers use (test-suite/schema,
//! fuzz/schema, test-suite/json and fuzz/json), and `roundtrip(suite, type, value)`:
//! decode a value with a type named by a string, then encode the result. For
//! the JSON fuzzer, `write(suite, type, value)` (decode, then write plain JSON)
//! and `read(suite, type, text)` (read plain JSON, then encode).

use std::path::{Path, PathBuf};
use std::{env, fs};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR")?);
    let dirs = [manifest.join("../../test-suite/schema"), manifest.join("../schema"), manifest.join("../../test-suite/json"), manifest.join("../json")];
    let mut schemas: Vec<(String, PathBuf)> = Vec::new();
    for dir in &dirs {
        println!("cargo::rerun-if-changed={}", dir.display());
        for entry in fs::read_dir(dir)? {
            let path = entry?.path();
            let file = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
            if let Some(name) = file.strip_suffix(".schema.haus") {
                schemas.push((name.to_owned(), path));
            }
        }
    }
    schemas.sort();
    let mut code = String::from("/// Decode `v` with `ty` of the schema `suite`, then encode the result; None if there is no such type.\n");
    code += "#[allow(dead_code)]\npub fn roundtrip(suite: &str, ty: &str, v: &::haus::Value) -> Option<Result<::haus::Value, ::haus::DecodeError>> {\n    match suite {\n";
    for (name, _) in &schemas {
        code += &format!("        {name:?} => {name}::roundtrip(ty, v),\n");
    }
    code += "        _ => None,\n    }\n}\n\n";
    code += "/// Decode `v` with `ty` of the schema `suite`, and write the result as plain JSON; None if there is no such type.\n";
    code += "#[allow(dead_code)]\npub fn write(suite: &str, ty: &str, v: &::haus::Value) -> Option<Result<String, String>> {\n    match suite {\n";
    for (name, _) in &schemas {
        code += &format!("        {name:?} => {name}::write(ty, v),\n");
    }
    code += "        _ => None,\n    }\n}\n\n";
    code += "/// Read the plain JSON `text` with `ty` of the schema `suite`, and encode the result; None if there is no such type.\n";
    code += "#[allow(dead_code)]\npub fn read(suite: &str, ty: &str, text: &str) -> Option<Result<::haus::Value, String>> {\n    match suite {\n";
    for (name, _) in &schemas {
        code += &format!("        {name:?} => {name}::read(ty, text),\n");
    }
    code += "        _ => None,\n    }\n}\n\n";
    for (name, path) in &schemas {
        haus_build::Config::new().quiet().compile_as(path, &format!("suite_{name}"))?;
        code += &module(name, &fs::read_to_string(path)?);
    }
    fs::write(Path::new(&env::var("OUT_DIR")?).join("schemas.rs"), code)?;
    Ok(())
}

/// The names of a schema's non-generic definitions: `type Name = …` at the
/// start of a line, leaving out streams.
fn definitions(text: &str) -> Vec<&str> {
    text.lines()
        .filter_map(|line| line.strip_prefix("type "))
        .filter_map(|def| def.split_once('='))
        .filter(|(_, ty)| !ty.trim_start().starts_with("Stream "))
        .map(|(name, _)| name.trim())
        .filter(|name| !name.is_empty() && !name.contains(char::is_whitespace))
        .collect()
}

fn module(name: &str, text: &str) -> String {
    let defs = definitions(text);
    let arms: String = defs
        .iter()
        .map(|t| format!("            {t:?} => <{t} as ::haus::Decode>::decode(v).and_then(|x| encode(&x)),\n"))
        .collect();
    let write_arms: String = defs.iter().map(|t| format!("            {t:?} => write_as::<{t}>(v),\n")).collect();
    let read_arms: String = defs.iter().map(|t| format!("            {t:?} => read_as::<{t}>(text),\n")).collect();
    format!(
        r#"#[allow(deprecated, dead_code, clippy::all)]
pub mod {name} {{
    include!(concat!(env!("OUT_DIR"), "/suite_{name}.rs"));

    pub fn roundtrip(ty: &str, v: &::haus::Value) -> Option<Result<::haus::Value, ::haus::DecodeError>> {{
        Some(match ty {{
{arms}            _ => return None,
        }})
    }}

    fn write_as<T: ::haus::Decode + ::haus::ToJson>(v: &::haus::Value) -> Result<String, String> {{
        let x = T::decode(v).map_err(|e| format!("can't decode: {{e}}"))?;
        ::haus::json::to_string(&x).map_err(|e| format!("can't write it as JSON: {{e}}"))
    }}

    fn read_as<T: ::haus::FromJson + ::haus::Encode>(text: &str) -> Result<::haus::Value, String> {{
        let x = ::haus::json::from_str::<T>(text).map_err(|e| e.to_string())?;
        ::haus::Encode::encode(&x).map_err(|e| e.to_string())
    }}

    fn encode<T: ::haus::Encode>(x: &T) -> Result<::haus::Value, ::haus::DecodeError> {{
        ::haus::Encode::encode(x).map_err(|e| ::haus::DecodeError::new(e.code, format!("can't encode it again: {{e}}")))
    }}

    pub fn write(ty: &str, v: &::haus::Value) -> Option<Result<String, String>> {{
        Some(match ty {{
{write_arms}            _ => return None,
        }})
    }}

    pub fn read(ty: &str, text: &str) -> Option<Result<::haus::Value, String>> {{
        Some(match ty {{
{read_arms}            _ => return None,
        }})
    }}
}}

"#
    )
}
