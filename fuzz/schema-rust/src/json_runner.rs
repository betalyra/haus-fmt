//! The Rust runner of the JSON fuzzer (fuzz/README.md): `json_runner MODE FILE`
//! reads one case per line and prints one line each, `ok …` or `err <place> <code> <reason>`
//! (the place in the value, `$` for an error in the text, and the code of spec §17;
//! `-` for an input that isn't one value):
//!
//! - `write`: `SUITE TYPE HEX` (haus text): decode with the type, write plain JSON (spec §16.3);
//! - `read`: `SUITE TYPE HEX` (JSON text): read plain JSON with the type, encode: the canonical form;
//! - `lossless-write`: `HEX` (haus text): `haus::to_lossless_json` (§16.2);
//! - `lossless-read`: `HEX` (JSON text): `haus::from_lossless_json`, the canonical form;
//! - `schemaless`: `HEX` (JSON text): `haus::from_json` (§16.1), the canonical form.

mod schemas {
    include!(concat!(env!("OUT_DIR"), "/schemas.rs"));
}

use std::io::{BufWriter, Write};
use std::{env, fs};

fn unhex(hex: &str) -> Vec<u8> {
    let digit = |c: u8| if c.is_ascii_digit() { c - b'0' } else { c - b'a' + 10 };
    hex.as_bytes().chunks(2).map(|p| digit(p[0]) * 16 + digit(p[1])).collect()
}

fn one_line(s: &str) -> String {
    s.replace('\n', "\\n").replace('\r', "\\r")
}

/// The single haus value of a case, or why it isn't one.
fn single(bytes: &[u8]) -> Result<haus::Value, String> {
    match haus::parse_bytes(bytes) {
        Ok(mut vs) if vs.len() == 1 => Ok(vs.remove(0)),
        _ => Err("err $ - not a single value".into()),
    }
}

fn text(bytes: &[u8]) -> Result<&str, String> {
    std::str::from_utf8(bytes).map_err(|_| "err $ invalid-utf8 invalid UTF-8".to_owned())
}

/// `err <place> <code> <reason>`: an error in a value at its place, one in the text at `$`.
fn err(e: &haus::Error) -> String {
    let (place, code) = match e {
        haus::Error::Decode(d) => (d.place(), d.code.to_string()),
        haus::Error::Encode(d) => (d.place(), d.code.to_string()),
        _ => ("$".to_owned(), e.code().map_or("-".to_owned(), |c| c.to_string())),
    };
    format!("err {place} {code} {}", one_line(&e.to_string()))
}

fn line(mode: &str, line: &str) -> Result<String, String> {
    let parts: Vec<&str> = line.split(' ').collect();
    match (mode, parts.as_slice()) {
        ("write", [suite, ty, hex]) => match schemas::write(suite, ty, &single(&unhex(hex))?) {
            None => Ok(format!("crash no type {suite}.{ty}")),
            Some(Ok(json)) => Ok(format!("ok {json}")),
            Some(Err(e)) => Err(format!("err {}", one_line(&e))),
        },
        ("read", [suite, ty, hex]) => match schemas::read(suite, ty, text(&unhex(hex))?) {
            None => Ok(format!("crash no type {suite}.{ty}")),
            Some(Ok(v)) => Ok(format!("ok {}", haus::canonical(&v))),
            Some(Err(e)) => Err(format!("err {}", one_line(&e))),
        },
        ("lossless-write", [hex]) => match haus::to_lossless_json(&single(&unhex(hex))?) {
            Ok(json) => Ok(format!("ok {json}")),
            Err(e) => Err(format!("err {} {} {}", e.place(), e.code, one_line(&e.to_string()))),
        },
        ("lossless-read", [hex]) => match haus::from_lossless_json(text(&unhex(hex))?) {
            Ok(v) => Ok(format!("ok {}", haus::canonical(&v))),
            Err(e) => Err(err(&e)),
        },
        ("schemaless", [hex]) => match haus::from_json(text(&unhex(hex))?) {
            Ok(v) => Ok(format!("ok {}", haus::canonical(&v))),
            Err(e) => Err(err(&e)),
        },
        _ => Ok(format!("crash bad line for {mode}")),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().skip(1).collect();
    let [mode, file] = args.as_slice() else { return Err("usage: json_runner MODE FILE".into()) };
    let input = fs::read_to_string(file)?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    for l in input.lines().filter(|l| !l.is_empty()) {
        let result = line(mode, l).unwrap_or_else(|e| e);
        writeln!(out, "{result}")?;
    }
    Ok(())
}
