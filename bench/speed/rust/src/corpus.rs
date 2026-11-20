//! The corpus `bench convert` exports (bench/size/src/export.ts), read as it
//! is on disk:
//!
//! ```text
//! <out>/<source>/corpus/
//!   index.haus             { source, schema, documents: [{ id, root, file }] }
//!   <source>.schema.haus   the schema; `root` is a type of it
//!   NNNN.haus              document NNNN, minimised haus
//!   NNNN.pretty.haus       the same, pretty
//!   NNNN.json              the same document, minified JSON
//!   all.haus               every document as one haus stream, minimised
//!   all.json               every document as one JSON array, minified
//! ```
//!
//! The sources and their order come from the shared manifest,
//! `bench/sources.haus`.

use crate::{Error, fail};
use haus::Value;
use std::fs;
use std::path::{Path, PathBuf};

/// One document, in the forms that are read.
#[derive(Debug, Clone)]
pub struct Document {
    pub id: String,
    /// The document's type in the schema.
    pub root: String,
    /// Minimised haus (the wire form).
    pub haus: String,
    pub pretty: String,
    /// Minified JSON.
    pub json: String,
}

/// One source's exported corpus.
#[derive(Debug, Clone)]
pub struct Corpus {
    pub source: String,
    pub schema: String,
    pub documents: Vec<Document>,
    /// Every document as one haus stream: each item followed by `,` and a line feed.
    pub all_haus: String,
    /// Every document as one JSON array.
    pub all_json: String,
}

fn read(path: &Path) -> Result<String, Error> {
    fs::read_to_string(path).map_err(|e| Error(format!("{}: {e}", path.display())))
}

/// The one value of a haus file.
fn read_value(path: &Path) -> Result<Value, Error> {
    match haus::parse(&read(path)?).map_err(|e| Error(format!("{}: {e}", path.display())))?.as_slice() {
        [v] => Ok(v.clone()),
        vs => fail(format!("{}: expected one value, found {}", path.display(), vs.len())),
    }
}

fn string<'a>(v: &'a Value, key: &str, path: &Path) -> Result<&'a str, Error> {
    match v.get(key) {
        Some(Value::String(s)) => Ok(s),
        _ => fail(format!("{}: no string {key}", path.display())),
    }
}

fn array<'a>(v: &'a Value, key: &str, path: &Path) -> Result<&'a [Value], Error> {
    match v.get(key) {
        Some(Value::Array(items)) => Ok(items),
        _ => fail(format!("{}: no array {key}", path.display())),
    }
}

/// The names of the corpus sources in the manifest, in its order.
pub fn sources(manifest: &Path) -> Result<Vec<String>, Error> {
    let m = read_value(manifest)?;
    array(&m, "corpus", manifest)?.iter().map(|s| string(s, "name", manifest).map(str::to_owned)).collect()
}

impl Corpus {
    /// The directory of a source's export.
    pub fn dir(out: &Path, source: &str) -> PathBuf {
        out.join(source).join("corpus")
    }

    /// Reads a source's export.
    pub fn load(out: &Path, source: &str) -> Result<Corpus, Error> {
        let dir = Corpus::dir(out, source);
        let index_path = dir.join("index.haus");
        if !index_path.exists() {
            return fail(format!(
                "no corpus for {source} in {}: run `pnpm --filter haus-bench convert` (from typescript/) first",
                dir.display()
            ));
        }
        let index = read_value(&index_path)?;
        let documents = array(&index, "documents", &index_path)?
            .iter()
            .map(|d| {
                let file = string(d, "file", &index_path)?;
                Ok(Document {
                    id: string(d, "id", &index_path)?.to_owned(),
                    root: string(d, "root", &index_path)?.to_owned(),
                    haus: read(&dir.join(format!("{file}.haus")))?,
                    pretty: read(&dir.join(format!("{file}.pretty.haus")))?,
                    json: read(&dir.join(format!("{file}.json")))?,
                })
            })
            .collect::<Result<Vec<_>, Error>>()?;
        Ok(Corpus {
            source: string(&index, "source", &index_path)?.to_owned(),
            schema: read(&dir.join(string(&index, "schema", &index_path)?))?,
            documents,
            all_haus: read(&dir.join("all.haus"))?,
            all_json: read(&dir.join("all.json"))?,
        })
    }
}
