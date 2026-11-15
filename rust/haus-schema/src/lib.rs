//! haus schema files (`.schema.haus`, spec §14), and data checked against
//! them at runtime (spec §15).
//!
//! ```
//! use haus_schema::Schema;
//!
//! let schema = Schema::parse("type Root = { id: Int, tags: Array String }").unwrap();
//! let value = haus::parse(r#"{ id: 0x10, tags: ["a"], note: "ignored" }"#).unwrap().remove(0);
//! // Decoding gives the value a writer writes back (spec §15): `0x10` is `16`,
//! // and the open record drops the field it doesn't list.
//! let decoded = schema.decode("Root", &value).unwrap();
//! assert_eq!(haus::canonical(&decoded), r#"{id:16,tags:["a"]}"#);
//!
//! // Checking reports every problem, with its place in the text, and hints.
//! let issues = schema.check_text("Root", "{\n  id: \"7\",\n  tgs: [],\n}");
//! let shown: Vec<String> = issues
//!     .iter()
//!     .map(|i| {
//!         let at = i.position.unwrap();
//!         format!("{}:{} {} {}", at.line, at.column, i.severity, i)
//!     })
//!     .collect();
//! assert_eq!(shown, [
//!     "1:1 error missing field tags at $",
//!     r#"2:7 error expected Int, found the string "7" at $.id"#,
//!     "3:3 hint tgs is not in the schema; a reader ignores it. Did you mean tags? at $.tgs",
//! ]);
//! ```
//!
//! - [`Schema`]: a schema file parsed, its imports resolved (std/time, schema
//!   packages, relative files, through a [`Resolver`]) and checked: every rule
//!   of §14 for invalid schemas.
//! - [`Schema::decode`] and [`Schema::decode_stream`]: decode a [`haus::Value`]
//!   with a type exactly as §15 says, giving the value an encoder writes back
//!   (floats in their one spelling, `-0` as an integer `0`, fields an open
//!   record ignores left out), or the first error, with its path.
//! - [`Schema::check_text`] and [`Schema::check`]: every problem in a data file
//!   (up to 200), with positions, and hints for fields and tags an open type
//!   doesn't list and for deprecated ones: what `haus check` and editors show.
//! - [`syntax`]: the syntax tree of one schema file, and [`packages`]: schema
//!   packages among a Cargo crate's direct dependencies. haus-fmt-build
//!   generates code from these.

mod check;
mod files;
mod locate;
pub mod packages;
mod resolve;
pub mod syntax;
mod types;

pub use check::{Issue, MAX_ISSUES, Position, SchemaReference, Segment, Severity, schema_reference};
pub use files::{FileResolver, Module, NoImports, Resolver};
pub use packages::Packages;
pub use resolve::{Definition, Options, Schema};
pub use types::{Builtin, Case, Deprecation, Field, Instance, InstanceId, Payload, Record, Type, Variant};

use std::fmt::{self, Display};
use std::path::{Path, PathBuf};
use std::{env, fs};

/// What went wrong, and where: `src/order.schema.haus:3:5: unknown type Strin`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    path: Option<PathBuf>,
    /// Line and column, 1-based.
    position: Option<(usize, usize)>,
    reason: String,
    /// The error's code in the spec's catalogue (spec/errors.haus), once
    /// codes are assigned to schema errors. None for now.
    code: Option<&'static str>,
}

impl Error {
    /// An error without a place.
    pub fn new(reason: impl Display) -> Error {
        Error { path: None, position: None, reason: reason.to_string(), code: None }
    }

    /// An error about the file at `path`.
    pub fn at(path: &Path, reason: impl Display) -> Error {
        Error::new(reason).in_file(path)
    }

    /// The same error, in the file at `path`.
    pub fn in_file(self, path: &Path) -> Error {
        Error { path: Some(path.to_owned()), ..self }
    }

    /// The file it is in, if known.
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Line and column (1-based, columns in code points), if known.
    pub fn position(&self) -> Option<(usize, usize)> {
        self.position
    }

    /// The message, without the place.
    pub fn reason(&self) -> &str {
        &self.reason
    }

    /// The error's code in the spec's catalogue, when it has one.
    pub fn code(&self) -> Option<&'static str> {
        self.code
    }
}

impl From<syntax::Error> for Error {
    fn from(e: syntax::Error) -> Error {
        Error { path: None, position: Some((e.line, e.column)), reason: e.reason, code: None }
    }
}

impl Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let path = self.path.as_ref().map(|p| p.display().to_string());
        let position = self.position.map(|(line, column)| format!("{line}:{column}"));
        match [path, position].into_iter().flatten().collect::<Vec<_>>().join(":") {
            at if at.is_empty() => f.write_str(&self.reason),
            at => write!(f, "{at}: {}", self.reason),
        }
    }
}

impl std::error::Error for Error {}

/// Something a schema allows but probably doesn't mean, with where it is:
/// `3:1: unknown attribute @since: this version of haus ignores it`.
pub type Warning = Error;

type Result<T, E = Error> = std::result::Result<T, E>;

/// Tells Cargo to rerun the build script when `path` changes (only in a build script).
fn rerun_if_changed(path: &Path) {
    if env::var_os("OUT_DIR").is_some() {
        println!("cargo::rerun-if-changed={}", path.display());
    }
}

fn read(path: &Path) -> Result<String> {
    fs::read_to_string(path).map_err(|e| Error::at(path, e))
}

fn var(key: &str) -> Result<String> {
    env::var(key).map_err(|_| Error::new(format!("{key} is not set: haus-fmt-build runs in a build script")))
}
