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
//! assert_eq!(haus::canonical(&decoded.reveal()), r#"{id:16,tags:["a"]}"#);
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
//! - [`Schema`]: a schema file parsed, its imports resolved (std/time,
//!   relative files, and schema packages found by a [`Locator`]) and checked:
//!   every rule of §13.3 for imports and of §14 for invalid schemas.
//! - [`Schema::decode`] and [`Schema::decode_stream`]: decode a [`haus::Value`]
//!   with a type exactly as §15 says, giving the value an encoder writes back
//!   (floats in their one spelling, `-0` as an integer `0`, fields an open
//!   record ignores left out), or the first error, with its path. The
//!   result is a [`Decoded`]: its secrets print as `<redacted>`, and only
//!   [`Decoded::reveal`] makes it a [`haus::Value`] again, which the
//!   canonical form, the hash and the writers take (spec §15, "Secrets").
//!   [`Schema::encode`] encodes it with the schema, refusing its secrets
//!   unless asked to reveal them ([`EncodeOptions::reveal_secrets`]).
//! - Package rules (packages.md §6, §7): the program's implementations of
//!   the rules of the packages it uses ([`Options::rules`], [`PackageRule`]),
//!   checked when decoding on the value the schema decoded; a schema that
//!   reaches a rule without one is `missing-codec`, unless its package is
//!   taken shape-only ([`Options::shape_only`]). Each package's manifest
//!   `rules` field is checked when it is reached.
//! - [`Schema::check_text`] and [`Schema::check`]: every problem in a data file
//!   (up to 200 errors; hints don't count), with positions, and hints for
//!   fields and tags an open type doesn't list and for deprecated ones: what
//!   `haus check` and editors show. Every error, as a set (spec §14, "Every
//!   error"); [`Schema::check_text_report`] and [`Schema::check_report`] also
//!   stop at the first one if asked ([`CheckOptions::first`]) and say whether
//!   they stopped at the cap. A `Stream` is checked item by item: a syntax
//!   error ends the check after the items before it. [`Schema::check_stream`]
//!   checks a stream's values as they arrive, with one cap for all of them.
//! - [`rules::unchecked_rules`]: the hints of tools that check data without
//!   a program to supply rules (packages.md §7, "Tools").
//! - [`Locator`]: where packages are: [`Explicit`] (packages given by the
//!   user) and [`Packages`] (a Cargo crate's direct dependencies). This
//!   binding never looks in `node_modules` (spec §13.3, "Installed packages").
//! - Relative imports stay inside the build's root ([`Options::root`]: by
//!   default the directory of the schema file loaded), and every file is
//!   read as a regular file, by its real path, without following a link at
//!   its last name and without blocking (spec §13.3, "Files read").
//! - [`syntax`]: the syntax tree of one schema file, and [`packages`]: the
//!   manifest and the rules of package files. haus-fmt-build generates code
//!   from these.

mod check;
mod decoded;
mod files;
mod locate;
mod locator;
pub mod packages;
mod resolve;
pub mod rules;
mod sources;
pub mod syntax;
mod types;

pub use sources::{Folder, Package, PackageText, Sources, read_folder};

pub use check::{
    CheckOptions, CheckReport, EncodeOptions, Issue, MAX_ERRORS, Position, Segment, Severity, StreamCheck,
};
pub use decoded::Decoded;
pub use files::FileCache;
pub use locator::{Explicit, Location, Locator, NoImports, Or};
pub use packages::{Manifest, Packages};
pub use resolve::{Definition, Options, PackageRule, Schema, SchemaFile, SchemaPackage, missing_rule};
pub use types::{Builtin, Case, Deprecation, Field, Instance, InstanceId, Payload, Record, Type, Variant};

// A built schema, its types and its errors are Send and Sync (checked here,
// at compile time): a schema doesn't change once it is built, so threads
// may share one. A FileCache (Rc inside) belongs to one load on one thread.
const _: () = {
    const fn shared<T: Send + Sync>() {}
    shared::<Schema>();
    shared::<SchemaFile>();
    shared::<SchemaPackage>();
    shared::<Definition>();
    shared::<Type>();
    shared::<Instance>();
    shared::<Record>();
    shared::<Variant>();
    shared::<Issue>();
    shared::<CheckReport>();
    shared::<Decoded>();
    shared::<Error>();
    shared::<Manifest>();
    shared::<Packages>();
    shared::<Explicit>();
    shared::<Package>();
    shared::<Sources>();
    shared::<PackageRule>();
    shared::<syntax::File>();
};

use haus::ErrorCode;
use std::env;
use std::fmt::{self, Display};
use std::path::{Path, PathBuf};

/// What went wrong, and where: `src/order.schema.haus:3:5: unknown type Strin`,
/// with its code (spec §17), or a mistake in the configuration of a build,
/// which has none ([`Error::config`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    path: Option<PathBuf>,
    /// Line and column, 1-based.
    position: Option<(usize, usize)>,
    reason: String,
    code: Option<ErrorCode>,
    hint: Option<String>,
}

impl Error {
    /// An error without a place.
    pub fn new(code: ErrorCode, reason: impl Display) -> Error {
        Error { path: None, position: None, reason: reason.to_string(), code: Some(code), hint: None }
    }

    /// A mistake in how a build is configured, not in a schema or data,
    /// so without a code of §17: two codecs for one id (spec §13.4).
    pub fn config(reason: impl Display) -> Error {
        Error { path: None, position: None, reason: reason.to_string(), code: None, hint: None }
    }

    /// An error about the file at `path`.
    pub fn at(path: &Path, code: ErrorCode, reason: impl Display) -> Error {
        Error::new(code, reason).in_file(path)
    }

    /// The same error, in the file at `path`.
    pub fn in_file(self, path: &Path) -> Error {
        Error { path: Some(path.to_owned()), ..self }
    }

    /// The same error, with a fix for this case, better than the code's.
    pub fn with_hint(self, hint: impl Into<String>) -> Error {
        Error { hint: Some(hint.into()), ..self }
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

    /// Which mistake it is (spec §17): `unknown-type`, or for a warning
    /// `unknown-attribute` or `deprecated`. None for a mistake in the
    /// configuration of a build ([`Error::config`]).
    pub fn code(&self) -> Option<ErrorCode> {
        self.code
    }

    /// A concrete fix: the one for this case, or the catalogue's for the code.
    pub fn hint(&self) -> &str {
        self.hint.as_deref().or(self.code.map(|c| c.hint())).unwrap_or_default()
    }

    /// The documentation of the code: `https://haus-fmt.org/docs/errors#<code>`.
    pub fn docs(&self) -> Option<String> {
        self.code.map(|c| c.docs())
    }

    /// The JSON form of spec §17: `{ code, message, line?, column?, hint, docs }`;
    /// None for a mistake in the configuration of a build, which has no code.
    pub fn to_json(&self) -> Option<String> {
        let json = haus::ErrorJson {
            code: self.code?,
            message: &self.reason,
            position: self.position,
            path: None,
            expected: None,
            found: None,
            hint: self.hint(),
        };
        Some(json.write())
    }
}

impl From<syntax::Error> for Error {
    fn from(e: syntax::Error) -> Error {
        // A well-known type that needs its import: `unknown type Date (import it with: import std/time (Date))`.
        let hint = e
            .reason
            .split_once("(import it with: ")
            .and_then(|(_, rest)| rest.strip_suffix(')'))
            .map(|how| format!("Import it with: {how}."))
            .or_else(|| {
                syntax::import_version_hint(&e.reason).filter(|_| e.code == ErrorCode::ImportVersion).map(str::to_owned)
            });
        Error { position: Some((e.line, e.column)), hint, ..Error::new(e.code, e.reason) }
    }
}

impl Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let path = self.path.as_deref().map(plain);
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

/// Text from a file, for a message (spec §9.2): control and bidirectional
/// characters escaped as `\u{…}`, and at most 40 characters, cut with `…`.
pub(crate) fn quote(text: &str) -> String {
    const MAX: usize = 40;
    let pieces: Vec<String> = text.chars().map(escape).collect();
    let length: usize = pieces.iter().map(|p| p.chars().count()).sum();
    if length <= MAX {
        return pieces.concat();
    }
    let mut out = String::new();
    let mut used = 0;
    for piece in pieces {
        let n = piece.chars().count();
        if used + n > MAX - 1 {
            break;
        }
        out.push_str(&piece);
        used += n;
    }
    out + "…"
}

/// A path, for a message: as the platform writes it, with its control and
/// bidirectional characters escaped.
pub(crate) fn shown(path: &Path) -> String {
    plain(path).chars().map(escape).collect()
}

/// A path as people write it. On Windows a real path (`canonicalize`)
/// starts with `\\?\`, which messages leave out, as the other bindings do.
fn plain(path: &Path) -> String {
    let text = path.display().to_string();
    match cfg!(windows) {
        true => without_verbatim(&text),
        false => text,
    }
}

/// A Windows path without the `\\?\` before a drive or a share:
/// `\\?\C:\app` is `C:\app`, `\\?\UNC\host\share` is `\\host\share`. Other
/// paths are kept as they are.
fn without_verbatim(text: &str) -> String {
    let drive = |p: &str| p.as_bytes().get(1) == Some(&b':') && p.starts_with(|c: char| c.is_ascii_alphabetic());
    match text.strip_prefix(r"\\?\") {
        Some(rest) if rest.get(..4).is_some_and(|p| p.eq_ignore_ascii_case(r"UNC\")) => format!(r"\\{}", &rest[4..]),
        Some(rest) if drive(rest) => rest.to_owned(),
        _ => text.to_owned(),
    }
}

/// A character as a message shows it: control and bidirectional ones as `\u{…}`.
/// A character as a message shows it (spec §9): control, bidirectional and
/// line-separator characters as `\u{…}`, in uppercase hex as the canonical
/// form writes them (spec §12).
fn escape(c: char) -> String {
    let bidi = matches!(c, '\u{61c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}');
    match c.is_control() || bidi || matches!(c, '\u{2028}' | '\u{2029}') {
        true => format!("\\u{{{:X}}}", c as u32),
        false => c.to_string(),
    }
}

fn var(key: &str) -> Result<String> {
    let reason = format!("{key} is not set: haus-fmt-build runs in a build script");
    env::var(key).map_err(|_| Error::new(ErrorCode::ImportUnavailable, reason))
}

#[cfg(test)]
mod tests {
    use super::without_verbatim;

    /// Real paths on Windows, as messages show them (tested on every platform).
    #[test]
    fn windows_paths_without_verbatim() {
        let cases = [
            (r"\\?\C:\Users\runneradmin\app\x.schema.haus", r"C:\Users\runneradmin\app\x.schema.haus"),
            (r"\\?\d:\", r"d:\"),
            (r"\\?\UNC\host\share\app", r"\\host\share\app"),
            (r"\\?\unc\host\share", r"\\host\share"),
            // Not a drive or a share: kept.
            (r"\\?\Volume{0b1c}\app", r"\\?\Volume{0b1c}\app"),
            (r"\\?\1:\app", r"\\?\1:\app"),
            (r"\\?\", r"\\?\"),
            // Not verbatim: kept.
            (r"C:\app", r"C:\app"),
            (r"\\host\share\app", r"\\host\share\app"),
            ("/tmp/app", "/tmp/app"),
        ];
        for (path, shown) in cases {
            assert_eq!(without_verbatim(path), shown, "{path}");
        }
    }
}
