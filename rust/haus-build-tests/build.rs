//! Generates the Rust types for features.schema.haus, and for every schema of
//! the schema conformance suite (test-suite/schema, spec §15) a module with a
//! `roundtrip` function: decode a value with a type named by a string, then
//! encode the result. Each schema is also compiled without its attributes,
//! as `<name>::bare`, which must give the same results (attributes don't
//! matter, spec §15). tests/schema_conformance.rs runs the cases with both.
//!
//! For the JSON suite (test-suite/json, spec §16.3) it generates the types of
//! schema-based.schema.haus, with `write` and `read`: a value decoded with a
//! type written as schema-based JSON, and schema-based JSON read with a type
//! and encoded.
//! tests/json_conformance.rs runs its cases.
//!
//! For the typed streams of the stream suite (test-suite/stream, spec §15
//! "Streams") it generates the types of typed.schema.haus:
//! tests/stream_suite.rs decodes its cases' texts with them.
//!
//! app/main/order.schema.haus is an application's schema split into files
//! (relative imports, `../`, two common.schema.haus): tests/files.rs uses
//! its types, without and with a codec for a type of an imported file.
//!
//! shop.schema.haus imports schema packages (packages/): tests/packages.rs
//! uses its types, without and with a codec for a type that the packages'
//! types contain (the codec closure, spec §13.4).
//!
//! travel.schema.haus uses a package (packages/travel) that uses the
//! official packages: tests/profiles.rs uses its types with the codecs of
//! their profiles (`haus_money::Iso`, `haus_geo::Wgs84`, …).

use std::path::{Path, PathBuf};
use std::{env, fs};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Its cases without a schema-based JSON form (`_tag`, `_args`) are there on purpose: no warnings.
    haus_build::Config::new().quiet().compile("features.schema.haus")?;
    haus_build::Config::new().compile_as("app/main/order.schema.haus", "app")?;
    haus_build::Config::new()
        .codec("haus-build-tests/app/shared/money#Money", "crate::Cents")
        .compile_as("app/main/order.schema.haus", "app_typed")?;
    haus_build::Config::new().compile_as("shop.schema.haus", "shop")?;
    haus_build::Config::new()
        .codec("@haus-test/money@1#Money", "crate::Cents")
        .compile_as("shop.schema.haus", "shop_typed")?;
    haus_build::Config::new()
        .codec("@haus-fmt/money@1#Money", "haus_money::Iso")
        .codec("@haus-fmt/money@1#Currency", "haus_money::IsoCurrency")
        .codec("@haus-fmt/geo@1#LatLng", "haus_geo::Wgs84")
        .codec("@haus-fmt/geo@1#BBox", "haus_geo::Wgs84BBox")
        .compile_as("travel.schema.haus", "travel")?;

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

    let schema_based = suite.join("../json/schema-based.schema.haus");
    haus_build::Config::new().compile_as(&schema_based, "suite_json_schema_based")?;
    let module = json_module(&fs::read_to_string(&schema_based)?);
    fs::write(Path::new(&env::var("OUT_DIR")?).join("json_suite.rs"), module)?;

    let typed = suite.join("../stream/typed.schema.haus");
    println!("cargo::rerun-if-changed={}", typed.display());
    haus_build::Config::new().compile_as(&typed, "suite_stream_typed")?;
    Ok(())
}

/// `pub mod schema_based { <generated types> pub fn write(…) pub fn read(…) }`.
fn json_module(text: &str) -> String {
    let arms = |f: &str| -> String {
        definitions(text).iter().map(|t| format!("            {t:?} => {f}::<{t}>(x),\n")).collect()
    };
    let (write, read) = (arms("write_as"), arms("read_as"));
    format!(
        r#"/// The types of test-suite/json/schema-based.schema.haus.
pub mod schema_based {{
    include!(concat!(env!("OUT_DIR"), "/suite_json_schema_based.rs"));

    fn write_as<T: ::haus::Decode + ::haus::ToJson>(v: &::haus::Value) -> Result<String, String> {{
        let x = T::decode(v).map_err(|e| format!("can't decode the input: {{e}}"))?;
        ::haus::json::to_string(&x).map_err(|e| format!("can't write it as JSON: {{e}}"))
    }}

    fn read_as<T: ::haus::FromJson + ::haus::Encode>(json: &str) -> Result<::haus::Value, ::haus::Error> {{
        let x = ::haus::json::from_str::<T>(json)?;
        Ok(::haus::Encode::encode(&x)?)
    }}

    /// Decode `x` with the type `ty`, and write the result as schema-based JSON;
    /// None if there is no such type.
    pub fn write(ty: &str, x: &::haus::Value) -> Option<Result<String, String>> {{
        Some(match ty {{
{write}            _ => return None,
        }})
    }}

    /// Read the schema-based JSON `x` with the type `ty`, and encode the result;
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
