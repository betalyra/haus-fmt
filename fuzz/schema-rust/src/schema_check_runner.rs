//! The Rust runner of the schema-file fuzzer (fuzz/README.md, "Schema
//! files"): `schema_check_runner FILE` reads lines `HEX` (a schema file's
//! bytes as hex), reads each with haus-fmt-schema's `Schema::parse` (std
//! modules only, no packages or files), and prints one line each: `ok`, or
//! `err <line> <column> <code> <reason>`, the position of the error (`0 0`
//! for none) and its code (spec §17).

use haus_schema::Schema;
use std::io::{BufWriter, Write};
use std::{env, fs};

fn unhex(hex: &str) -> Vec<u8> {
    let digit = |c: u8| if c.is_ascii_digit() { c - b'0' } else { c - b'a' + 10 };
    hex.as_bytes().chunks(2).map(|p| digit(p[0]) * 16 + digit(p[1])).collect()
}

fn line(hex: &str) -> String {
    let Ok(text) = String::from_utf8(unhex(hex)) else { return "err 0 0 invalid-utf8 invalid UTF-8".into() };
    match Schema::parse(&text) {
        Ok(_) => "ok".into(),
        Err(e) => {
            let (line, column) = e.position().unwrap_or((0, 0));
            format!("err {line} {column} {} {}", e.code(), e.reason().replace(['\n', '\r'], " "))
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let file = env::args().nth(1).ok_or("usage: schema_check_runner FILE")?;
    let text = fs::read_to_string(file)?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    for l in text.lines().filter(|l| !l.is_empty()) {
        writeln!(out, "{}", line(l))?;
    }
    Ok(())
}
