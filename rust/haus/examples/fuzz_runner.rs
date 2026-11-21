//! The fuzzing runner (fuzz/README.md): `fuzz_runner [--stream] DIR N` parses
//! DIR/00000.haus … DIR/{N-1}.haus and prints one line each:
//! `ok <values>` in the test-suite JSON encoding, or `err <line> <column> <code> <reason>`
//! (the error code of spec §17).
//! With `--stream`, each file goes through the stream reader in chunks
//! (see `chunks`); with `--canonical`, `ok` is followed by the canonical form
//! of each value (spec §12) as a JSON array of strings.
//!
//! The formatter fuzzer (`main.ts --format`) uses two more modes:
//! `--format STYLE [--indent N] [--width N] DIR N` formats each file in the
//! layout STYLE (`pretty`, `compact` or `minimised`) and prints `ok` and the
//! output as a JSON string; `--write STYLE DIR N` parses each file and writes
//! every value with the value writer, `haus::to_string` (`compact`) or
//! `haus::to_string_minimised` (`minimised`), and the values as a stream with
//! `haus::to_string_all` (`compact`; `null` for `minimised`, which has no
//! stream writer), and prints `ok {"values": [<line>, …], "stream": …}`. An
//! encoding error is `err 0 0 <code> <reason>`.

use haus::Value;
use serde_json::{Map, Value as Json, json};
use std::io::{BufWriter, Write};
use std::{env, fs};

fn canonical(v: &Value) -> Json {
    match v {
        Value::String(s) => json!(s),
        Value::Number(n) => json!({ "num": n.as_str() }),
        Value::Bytes(b) => json!({ "bytes": b.iter().map(|x| format!("{x:02x}")).collect::<String>() }),
        Value::Array(items) => Json::Array(items.iter().map(canonical).collect()),
        Value::Record(fields) => {
            json!({ "rec": fields.iter().map(|(k, v)| (k.clone(), canonical(v))).collect::<Map<_, _>>() })
        }
        Value::Variant { tag, args } if args.is_empty() => json!({ "tag": tag.as_str() }),
        Value::Variant { tag, args } => {
            json!({ "tag": tag.as_str(), "args": args.iter().map(canonical).collect::<Vec<_>>() })
        }
    }
}

fn line(result: Result<Vec<Value>, haus::SyntaxError>) -> String {
    match result {
        Ok(values) => format!("ok {}", Json::Array(values.iter().map(canonical).collect())),
        Err(e) => format!("err {} {} {} {}", e.line, e.column, e.code, e.reason.replace(['\n', '\r'], " ")),
    }
}

/// The chunks of case `i`, the same in every runner: chunk k has size
/// SIZES[(i + k) % 7], so cuts fall inside escapes, comments and UTF-8 sequences.
fn chunks(bytes: &[u8], i: usize) -> Vec<&[u8]> {
    const SIZES: [usize; 7] = [1, 2, 3, 5, 8, 13, 64];
    let mut out = Vec::new();
    let (mut at, mut k) = (0, 0);
    while at < bytes.len() {
        let end = (at + SIZES[(i + k) % 7]).min(bytes.len());
        out.push(&bytes[at..end]);
        at = end;
        k += 1;
    }
    out
}

fn streamed(bytes: &[u8], i: usize) -> Result<Vec<Value>, haus::SyntaxError> {
    let mut reader = haus::stream::Reader::default();
    let mut values = Vec::new();
    for chunk in chunks(bytes, i) {
        values.extend(reader.push(chunk)?);
    }
    values.extend(reader.finish()?);
    Ok(values)
}

/// With `--canonical`: the canonical form of each value (spec §12), as JSON strings.
fn canonical_line(result: Result<Vec<Value>, haus::SyntaxError>) -> String {
    match result {
        Ok(values) => format!("ok {}", Json::Array(values.iter().map(|v| json!(haus::canonical(v))).collect())),
        Err(e) => line(Err(e)),
    }
}

/// With `--format`: the file in the layout of `options`, as a JSON string.
fn format_line(bytes: &[u8], options: &haus::FormatOptions) -> String {
    let formatted =
        std::str::from_utf8(bytes).map_err(|_| ()).and_then(|text| haus::format(text, options).map_err(|_| ()));
    match formatted {
        Ok(out) => format!("ok {}", json!(out)),
        // The parser's error: run it for its position and code.
        Err(()) => line(haus::parse_bytes(bytes)),
    }
}

/// With `--write`: every value through the value writer, and the values
/// through the stream writer, as JSON strings.
fn write_line(bytes: &[u8], style: haus::Style) -> String {
    let values = match haus::parse_bytes(bytes) {
        Ok(values) => values,
        Err(e) => return line(Err(e)),
    };
    let minimised = style == haus::Style::Minimised;
    let written = || -> Result<Json, haus::EncodeError> {
        let lines = values
            .iter()
            .map(|v| if minimised { haus::to_string_minimised(v) } else { haus::to_string(v) })
            .collect::<Result<Vec<_>, _>>()?;
        let stream = if minimised { None } else { Some(haus::to_string_all(&values)?) };
        Ok(json!({ "values": lines, "stream": stream }))
    };
    match written() {
        Ok(out) => format!("ok {out}"),
        Err(e) => format!("err 0 0 {} {}", e.code, e.to_string().replace(['\n', '\r'], " ")),
    }
}

fn style(name: &str) -> haus::Style {
    match name {
        "pretty" => haus::Style::Pretty,
        "compact" => haus::Style::Compact,
        "minimised" => haus::Style::Minimised,
        _ => panic!("unknown style {name}: pretty, compact or minimised"),
    }
}

enum Mode {
    Parse,
    Stream,
    Canonical,
    Format(haus::FormatOptions),
    Write(haus::Style),
}

const USAGE: &str =
    "usage: fuzz_runner [--stream | --canonical | --format STYLE [--indent N] [--width N] | --write STYLE] DIR N";

fn main() {
    let mut args: Vec<String> = env::args().skip(1).collect();
    assert!(args.len() >= 2, "{USAGE}");
    let n: usize = args.pop().expect("N").parse().expect("N");
    let dir = args.pop().expect("DIR");
    let mode = match args.as_slice() {
        [] => Mode::Parse,
        [flag] if flag == "--stream" => Mode::Stream,
        [flag] if flag == "--canonical" => Mode::Canonical,
        [flag, name] if flag == "--write" => Mode::Write(style(name)),
        [flag, name, rest @ ..] if flag == "--format" => {
            let mut options = haus::FormatOptions { style: style(name), ..Default::default() };
            for pair in rest.chunks(2) {
                match pair {
                    [k, v] if k == "--indent" => options.indent = v.parse().expect("--indent N"),
                    [k, v] if k == "--width" => options.width = v.parse().expect("--width N"),
                    _ => panic!("{USAGE}"),
                }
            }
            Mode::Format(options)
        }
        _ => panic!("{USAGE}"),
    };
    let mut out = BufWriter::new(std::io::stdout().lock());
    for i in 0..n {
        let bytes = fs::read(format!("{dir}/{i:05}.haus")).expect("read case");
        let result = match &mode {
            Mode::Stream => line(streamed(&bytes, i)),
            Mode::Canonical => canonical_line(haus::parse_bytes(&bytes)),
            Mode::Parse => line(haus::parse_bytes(&bytes)),
            Mode::Format(options) => format_line(&bytes, options),
            Mode::Write(style) => write_line(&bytes, *style),
        };
        writeln!(out, "{result}").unwrap();
    }
}
