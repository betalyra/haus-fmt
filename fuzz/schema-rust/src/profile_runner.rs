//! The Rust runner of the profile fuzzer (fuzz/README.md, "Profiles"):
//! `profile_runner FILE` reads lines `TYPE HEX` (a value's haus text as
//! hex-encoded UTF-8), decodes the value with the codec of the official
//! profile for the type, as generated code runs a codec (`haus::de::codec`):
//! `haus_money::Iso` for `Money`, `haus_money::IsoCurrency` for `Currency`,
//! `haus_geo::Wgs84` for `LatLng`, `haus_geo::Wgs84BBox` for `BBox`. It
//! encodes the result and prints one line each: `ok <canonical form>` or
//! `err <place> <code> <reason>`, the place as `$[1]` and the code of spec
//! §17 (`-` for none).

use haus::{Codec, Encode};
use std::io::{BufWriter, Write};
use std::{env, fs};

fn unhex(hex: &str) -> Vec<u8> {
    let digit = |c: u8| if c.is_ascii_digit() { c - b'0' } else { c - b'a' + 10 };
    hex.as_bytes().chunks(2).map(|p| digit(p[0]) * 16 + digit(p[1])).collect()
}

fn one_line(s: &str) -> String {
    s.replace(['\n', '\r'], " ")
}

/// Decode with the codec `C`, encode what it decoded.
fn run<C: Codec>(v: &haus::Value) -> String {
    match haus::de::codec::<C>(v, haus::Decoder::default()) {
        Ok(x) => match C::encode(&x).encode() {
            Ok(encoded) => format!("ok {}", haus::canonical(&encoded)),
            Err(e) => format!("crash encoding failed: {}", one_line(&e.to_string())),
        },
        Err(e) => format!("err {} {} {}", e.place(), e.code, one_line(&e.to_string())),
    }
}

fn line(text: &str) -> String {
    let Some((ty, hex)) = text.split_once(' ') else { return "err $ - bad line".into() };
    let value = match haus::parse_bytes(&unhex(hex)) {
        Ok(mut vs) if vs.len() == 1 => vs.remove(0),
        _ => return "err $ - not a single value".into(),
    };
    match ty {
        "Money" => run::<haus_money::Iso>(&value),
        "Currency" => run::<haus_money::IsoCurrency>(&value),
        "LatLng" => run::<haus_geo::Wgs84>(&value),
        "BBox" => run::<haus_geo::Wgs84BBox>(&value),
        _ => format!("crash no type {ty}"),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let file = env::args().nth(1).ok_or("usage: profile_runner FILE")?;
    let text = fs::read_to_string(file)?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    for l in text.lines().filter(|l| !l.is_empty()) {
        writeln!(out, "{}", line(l))?;
    }
    Ok(())
}
