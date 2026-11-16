//! The schema fuzzer's runner for haus-fmt-schema's runtime checker
//! (fuzz/README.md): `check_runner FILE` reads lines `SUITE TYPE HEX` (a
//! value's haus text as hex-encoded UTF-8), decodes the value with the type
//! of the schema file `SUITE` (test-suite/schema or fuzz/schema) by
//! `Schema::decode`, and prints one line each: `ok <canonical form>` of the
//! decoded value (the value an encoder writes back, spec §15), or
//! `err <place> <code> <reason>`, the place as `$.items[2].price` and the code
//! of spec §17 (`-` for none).

use haus_schema::Schema;
use std::collections::HashMap;
use std::io::{BufWriter, Write};
use std::path::Path;
use std::{env, fs};

fn unhex(hex: &str) -> Vec<u8> {
    let digit = |c: u8| if c.is_ascii_digit() { c - b'0' } else { c - b'a' + 10 };
    hex.as_bytes().chunks(2).map(|p| digit(p[0]) * 16 + digit(p[1])).collect()
}

/// The schema files of the fuzzer, by suite name; one that doesn't load is its error.
fn schemas() -> Result<HashMap<String, Result<Schema, String>>, Box<dyn std::error::Error>> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut out = HashMap::new();
    for dir in [root.join("../../test-suite/schema"), root.join("../schema")] {
        for entry in fs::read_dir(dir)? {
            let path = entry?.path();
            let file = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
            if let Some(name) = file.strip_suffix(".schema.haus") {
                out.insert(name.to_owned(), Schema::parse(&fs::read_to_string(&path)?).map_err(|e| e.to_string()));
            }
        }
    }
    Ok(out)
}

fn one_line(s: &str) -> String {
    s.replace(['\n', '\r'], " ")
}

fn line(schemas: &HashMap<String, Result<Schema, String>>, text: &str) -> String {
    let parts: Vec<&str> = text.split(' ').collect();
    let [suite, ty, hex] = parts.as_slice() else { return "err $ - bad line".into() };
    let schema = match schemas.get(*suite) {
        None => return format!("crash no schema {suite}"),
        Some(Err(e)) => return format!("err $ - the schema is rejected: {}", one_line(e)),
        Some(Ok(schema)) => schema,
    };
    if schema.definition(ty).is_none() {
        return format!("crash no type {suite}.{ty}");
    }
    let value = match haus::parse_bytes(&unhex(hex)) {
        Ok(mut vs) if vs.len() == 1 => vs.remove(0),
        _ => return "err $ - not a single value".into(),
    };
    match schema.decode(ty, &value) {
        Ok(decoded) => match haus::canonical(&decoded) {
            Ok(text) => format!("ok {text}"),
            Err(e) => format!("err {} {} {}", e.place(), e.code, one_line(&e.reason)),
        },
        Err(e) => format!("err {} {} {}", e.path_string(), e.code, one_line(&e.message)),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let file = env::args().nth(1).ok_or("usage: check_runner FILE")?;
    let schemas = schemas()?;
    let text = fs::read_to_string(file)?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    for l in text.lines().filter(|l| !l.is_empty()) {
        writeln!(out, "{}", line(&schemas, l))?;
    }
    Ok(())
}
