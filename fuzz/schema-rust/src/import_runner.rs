//! The Rust runner of the import fuzzer (fuzz/README.md, "Relative
//! imports"): `import_runner FILE` reads lines `ENTRY ROOT` (hex of UTF-8;
//! ROOT `-` for none), loads each entry file with haus-fmt-schema's
//! `Schema::load_with` and no packages, and prints `ok OWN IMPORTED` (type
//! names, sorted, joined by `,`; `-` for none) or `err CODE`.

use haus_schema::{Definition, Options, Schema};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::{env, fs};

fn unhex(hex: &str) -> Vec<u8> {
    let digit = |c: u8| if c.is_ascii_digit() { c - b'0' } else { c - b'a' + 10 };
    hex.as_bytes().chunks(2).map(|p| digit(p[0]) * 16 + digit(p[1])).collect()
}

fn path(hex: &str) -> PathBuf {
    PathBuf::from(String::from_utf8(unhex(hex)).expect("a UTF-8 path"))
}

fn names(ds: &[Definition]) -> String {
    let mut ns: Vec<&str> = ds.iter().map(|d| d.name.as_str()).collect();
    ns.sort_unstable();
    if ns.is_empty() { "-".into() } else { ns.join(",") }
}

fn line(l: &str) -> String {
    let (entry, root) = l.split_once(' ').expect("ENTRY ROOT");
    let root = (root != "-").then(|| path(root));
    let options = Options { root: root.as_deref(), ..Options::default() };
    match Schema::load_with(path(entry), &options) {
        Ok(s) => format!("ok {} {}", names(s.definitions()), names(s.imported())),
        Err(e) => format!("err {}", e.code()),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let file = env::args().nth(1).ok_or("usage: import_runner FILE")?;
    let text = fs::read_to_string(file)?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    for l in text.lines().filter(|l| !l.is_empty()) {
        writeln!(out, "{}", line(l))?;
    }
    Ok(())
}
