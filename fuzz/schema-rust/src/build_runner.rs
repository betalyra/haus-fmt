//! The Rust runner of the build fuzzer (fuzz/README.md, "Values built in
//! code"): `build_runner FILE` reads lines of instructions (fuzz/src/build.ts),
//! builds each value with the constructors (spec §11) and writes it: `err
//! CODE` if a constructor rejects it, else `ok C H W`, the canonical form (hex
//! of UTF-8), the hash and the compact writer's text (hex), each `!CODE` if
//! it fails. Rust strings are UTF-8: a string, key or tag with a lone
//! surrogate can't be held, and its line is `na`.

use haus::{Value, ValueError};
use std::io::{BufWriter, Write};
use std::{env, fs};

fn unhex(hex: &str) -> Vec<u8> {
    let digit = |c: u8| if c.is_ascii_digit() { c - b'0' } else { c - b'a' + 10 };
    hex.as_bytes().chunks(2).map(|p| digit(p[0]) * 16 + digit(p[1])).collect()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Why a line gives no value: a constructor's error, or text Rust can't hold.
enum Fail {
    Value(ValueError),
    NotUtf8,
}

impl From<ValueError> for Fail {
    fn from(e: ValueError) -> Fail {
        Fail::Value(e)
    }
}

fn text(h: &str) -> Result<String, Fail> {
    String::from_utf8(unhex(h)).map_err(|_| Fail::NotUtf8)
}

/// The value the tokens start with, built with the constructors.
fn build<'a>(tokens: &mut impl Iterator<Item = &'a str>) -> Result<Value, Fail> {
    let token = tokens.next().expect("a value");
    let parts: Vec<&str> = token.split(':').collect();
    let count = |s: &str| s.parse::<usize>().expect("a count");
    // Every part is built (and every token read) before a mistake is reported.
    match parts[0] {
        "n" => Ok(Value::number(&text(parts[1])?)?),
        "s" => Ok(Value::String(text(parts[1])?)),
        "b" => Ok(Value::Bytes(unhex(parts[1]))),
        "a" => {
            let items: Vec<Result<Value, Fail>> = (0..count(parts[1])).map(|_| build(tokens)).collect();
            Ok(Value::Array(items.into_iter().collect::<Result<_, _>>()?))
        }
        "r" => {
            let fields: Vec<(Result<String, Fail>, Result<Value, Fail>)> = (0..count(parts[1]))
                .map(|_| {
                    let key = text(tokens.next().expect("a key").trim_start_matches("k:"));
                    (key, build(tokens))
                })
                .collect();
            let fields = fields.into_iter().map(|(k, v)| Ok((k?, v?))).collect::<Result<Vec<_>, Fail>>()?;
            Ok(Value::record(fields)?)
        }
        "v" => {
            let args: Vec<Result<Value, Fail>> = (0..count(parts[2])).map(|_| build(tokens)).collect();
            let tag = text(parts[1])?;
            Ok(Value::variant(&tag, args.into_iter().collect::<Result<_, _>>()?)?)
        }
        other => panic!("bad token {other}"),
    }
}

fn line(l: &str) -> String {
    // Text Rust can't hold anywhere in the value: the case isn't one for Rust.
    let texts = l.split(' ').filter(|t| ["n:", "s:", "k:", "v:"].iter().any(|p| t.starts_with(p)));
    if texts.filter_map(|t| t.split(':').nth(1)).any(|h| String::from_utf8(unhex(h)).is_err()) {
        return "na".into();
    }
    let v = match build(&mut l.split(' ').filter(|t| !t.is_empty())) {
        Ok(v) => v,
        Err(Fail::NotUtf8) => return "na".into(),
        Err(Fail::Value(e)) => return format!("err {}", e.code),
    };
    // canonical and hash can't fail for a value built with the constructors (spec §12): Rust's values share no parts.
    let written = match haus::to_string(&v) {
        Ok(s) => hex(s.as_bytes()),
        Err(e) => format!("!{}", e.code),
    };
    format!("ok {} {} {written}", hex(haus::canonical(&v).as_bytes()), haus::hash(&v))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let file = env::args().nth(1).ok_or("usage: build_runner FILE")?;
    let text = fs::read_to_string(file)?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    for l in text.lines().filter(|l| !l.is_empty()) {
        writeln!(out, "{}", line(l))?;
    }
    Ok(())
}
