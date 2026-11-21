//! Reading the files imports name (spec §13.3), the same for every package
//! manager: a [`Locator`] says where a package is, and the rules here say
//! whether it may be read. Resolution happens when a schema is loaded, never
//! while data is parsed, and never over the network (§9.2).
//!
//! A package's `package.haus`, `schema.haus` and `package.json` are opened
//! without following links (`O_NOFOLLOW`, and `O_NONBLOCK` so that a FIFO
//! can't block the open); their type and size are checked on the opened
//! file, and they are read from it, so the file checked is the file read.
//! On Windows they are opened with `FILE_FLAG_OPEN_REPARSE_POINT` (the link
//! itself, not its target), after a `symlink_metadata` check, and the type
//! and size are checked on the handle; without a stable way to compare the
//! two files' identities (`MetadataExt::file_index` is unstable), a file
//! replaced between that check and the open is caught only by the handle's
//! own type and size.

use crate::locator::{Locator, duplicate};
use crate::packages::{MANIFEST, MAX_MANIFEST, Manifest, SCHEMA, is_semver, package_dir_of};
use crate::{Error, Result, quote, shown};
use haus::ErrorCode;
use haus::json::Json;
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Read};
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;

/// A schema file's extension, always added to relative imports.
pub(crate) const EXTENSION: &str = ".schema.haus";
/// The largest schema file and `package.json`, in bytes (1 MiB).
pub const MAX_FILE: u64 = 1024 * 1024;

/// Which file is read, and so how (spec §13.3, "Files and limits").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Kind {
    /// A package's `package.haus`: never through a link, at most 64 KiB.
    Manifest,
    /// A package's `schema.haus`: never through a link, at most 1 MiB.
    PackageSchema,
    /// A package's `package.json`: never through a link, at most 1 MiB.
    PackageJson,
    /// A schema file outside packages, read at its real path: at most 1 MiB.
    Schema,
    /// The `package.json` of a project (not a package's): at most 1 MiB.
    ProjectJson,
}

impl Kind {
    fn follows_links(self) -> bool {
        matches!(self, Kind::Schema | Kind::ProjectJson)
    }

    fn limit(self) -> u64 {
        match self {
            Kind::Manifest => MAX_MANIFEST,
            _ => MAX_FILE,
        }
    }
}

/// A file opened and read, or why it wasn't.
#[derive(Debug, Clone)]
pub(crate) enum Opened {
    Missing,
    /// A symbolic link, a directory, a FIFO, …: not read.
    NotRegular,
    /// Its size: more than the limit, so not read.
    TooLarge(u64),
    Failed(String),
    Read(Rc<[u8]>),
}

/// Opens the file at `path` as `kind` says and reads it: a regular file,
/// within the limit, checked on the opened file.
pub(crate) fn open(path: &Path, kind: Kind) -> Opened {
    read(path, kind.follows_links(), kind.limit())
}

/// The most any file is read to: [`FileCache`] reads each file once, to the
/// largest limit, and checks each use's own limit on what it read.
const MAX_READ: u64 = if MAX_FILE > MAX_MANIFEST { MAX_FILE } else { MAX_MANIFEST };

/// Opens the file at `path`, following a link or not, and reads it: a
/// regular file of at most `limit` bytes, checked on the opened file.
fn read(path: &Path, follow: bool, limit: u64) -> Opened {
    #[cfg(test)]
    tests::OPENED.with(|o| o.borrow_mut().push(path.to_owned()));
    #[cfg(not(unix))]
    let before = match if follow { fs::metadata(path) } else { fs::symlink_metadata(path) } {
        Ok(m) if m.is_file() => m,
        Ok(_) => return Opened::NotRegular,
        Err(e) if e.kind() == ErrorKind::NotFound => return Opened::Missing,
        Err(e) => return Opened::Failed(e.to_string()),
    };
    let file = match options(follow).open(path) {
        Ok(file) => file,
        // A link that isn't followed (ELOOP), a directory (on Windows), …
        Err(e) => {
            return match fs::symlink_metadata(path) {
                Ok(m) if !m.is_file() => Opened::NotRegular,
                _ if e.kind() == ErrorKind::NotFound => Opened::Missing,
                _ => Opened::Failed(e.to_string()),
            };
        }
    };
    let meta = match file.metadata() {
        Ok(meta) => meta,
        Err(e) => return Opened::Failed(e.to_string()),
    };
    if !meta.is_file() {
        return Opened::NotRegular;
    }
    #[cfg(not(unix))]
    if meta.len() != before.len() {
        return Opened::NotRegular;
    }
    if meta.len() > limit {
        return Opened::TooLarge(meta.len());
    }
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    match file.take(limit + 1).read_to_end(&mut bytes) {
        Ok(_) if bytes.len() as u64 > limit => Opened::TooLarge(bytes.len() as u64),
        Ok(_) => Opened::Read(bytes.into()),
        Err(e) => Opened::Failed(e.to_string()),
    }
}

/// What a file read for one use is for another, `kind`: too large if it is
/// larger than that use allows.
fn within(opened: Opened, kind: Kind) -> Opened {
    match opened {
        Opened::Read(bytes) if bytes.len() as u64 > kind.limit() => Opened::TooLarge(bytes.len() as u64),
        opened => opened,
    }
}

#[cfg(unix)]
fn options(follow: bool) -> OpenOptions {
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = OpenOptions::new();
    let nofollow = if follow { 0 } else { libc::O_NOFOLLOW };
    options.read(true).custom_flags(libc::O_NONBLOCK | nofollow);
    options
}

#[cfg(windows)]
fn options(follow: bool) -> OpenOptions {
    use std::os::windows::fs::OpenOptionsExt;
    /// The link itself, not what it links to.
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    let mut options = OpenOptions::new();
    options.read(true);
    if !follow {
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    options
}

#[cfg(not(any(unix, windows)))]
fn options(_follow: bool) -> OpenOptions {
    let mut options = OpenOptions::new();
    options.read(true);
    options
}

/// The files one schema reads, each once (spec §13.3), by real path: a file
/// needed in two roles (a `package.json` that is a link to a schema file)
/// is read once, and every use sees the same bytes. Each use still gets its
/// own checks: a package's files are never read through a link, and each
/// kind of file has its own size limit. [`Schema::load`](crate::Schema::load)
/// makes one for each schema; a [`Locator`] reads `package.json` files
/// through it.
#[derive(Debug, Default)]
pub struct FileCache {
    /// By real path; a file that isn't there by the path it was looked for at.
    opened: HashMap<PathBuf, Opened>,
    /// The `package.json` files parsed, by real path: `null` if not valid JSON.
    json: HashMap<PathBuf, Rc<Json>>,
}

impl FileCache {
    pub fn new() -> FileCache {
        FileCache::default()
    }

    pub(crate) fn open(&mut self, path: &Path, kind: Kind) -> Opened {
        self.opened_at(path, kind).1
    }

    /// The file at `path`, read as `kind` says, and the path it is cached by.
    fn opened_at(&mut self, path: &Path, kind: Kind) -> (PathBuf, Opened) {
        // A package's files: the path itself is never a link (checked again on the opened file).
        if !kind.follows_links() {
            match fs::symlink_metadata(path) {
                Ok(m) if m.file_type().is_symlink() => return (path.to_owned(), Opened::NotRegular),
                Err(e) if e.kind() == ErrorKind::NotFound => return (path.to_owned(), Opened::Missing),
                _ => {}
            }
        }
        let key = path.canonicalize().unwrap_or_else(|_| path.to_owned());
        let opened = self.opened.entry(key.clone()).or_insert_with(|| read(path, kind.follows_links(), MAX_READ));
        (key, within(opened.clone(), kind))
    }

    /// A `package.json` (`kind` says whose): None if there is none, JSON
    /// `null` if it isn't valid JSON or, for a project's, isn't a regular file
    /// (it declares nothing and gives no version).
    pub(crate) fn package_json(&mut self, path: &Path, kind: Kind) -> Result<Option<Rc<Json>>> {
        let (key, opened) = self.opened_at(path, kind);
        match opened {
            Opened::Missing => Ok(None),
            // A project's that isn't a regular file (a directory, a broken link) stops the
            // search, as one that isn't valid JSON does: it declares nothing (spec §13.3).
            Opened::NotRegular if kind == Kind::ProjectJson => Ok(Some(Rc::new(Json::Null))),
            Opened::NotRegular => {
                let reason = format!("{} is a symbolic link or not a regular file; it is not read", shown(path));
                Err(Error::new(ErrorCode::PackagePath, reason))
            }
            Opened::TooLarge(size) => Err(too_large(path, size)),
            Opened::Failed(e) => Err(not_found(format!("{}: {e}", shown(path)))),
            Opened::Read(bytes) => {
                let json = self.json.entry(key).or_insert_with(|| {
                    let json = std::str::from_utf8(&bytes).ok().and_then(|text| haus::json::parse(text).ok());
                    Rc::new(json.unwrap_or(Json::Null))
                });
                Ok(Some(json.clone()))
            }
        }
    }

    /// The manifest of the package in `dir` (a real path), and its text.
    pub(crate) fn manifest(&mut self, dir: &Path) -> Result<(Manifest, String)> {
        let path = dir.join(MANIFEST);
        let opened = self.open(&path, Kind::Manifest);
        manifest(dir, opened)
    }

    /// A schema file's text: a package's `schema.haus`, or a file outside
    /// packages at its real path. `missing` says why a missing one is missing.
    pub(crate) fn schema(&mut self, path: &Path, kind: Kind, missing: impl FnOnce() -> String) -> Result<String> {
        match self.open(path, kind) {
            Opened::Read(bytes) => String::from_utf8(bytes.to_vec())
                .map_err(|_| Error::new(ErrorCode::InvalidUtf8, format!("{} is not UTF-8 text", shown(path)))),
            Opened::Missing => Err(not_found(missing())),
            Opened::NotRegular if kind == Kind::PackageSchema => {
                let reason = format!("{} is a symbolic link or not a regular file; it is not read", shown(path));
                Err(Error::new(ErrorCode::PackagePath, reason))
            }
            Opened::NotRegular => Err(not_found(format!("{} is not a regular file", shown(path)))),
            Opened::TooLarge(size) => Err(too_large(path, size)),
            Opened::Failed(e) => Err(not_found(format!("{}: {e}", shown(path)))),
        }
    }
}

/// The manifest at `dir/package.haus`, opened: checked (spec §13.3).
pub(crate) fn manifest(dir: &Path, opened: Opened) -> Result<(Manifest, String)> {
    let path = dir.join(MANIFEST);
    let invalid = |reason: String| Error::at(&path, ErrorCode::PackageManifest, reason);
    match opened {
        Opened::Read(bytes) => {
            let text = String::from_utf8(bytes.to_vec()).map_err(|_| invalid("the manifest is not UTF-8".into()))?;
            let manifest = Manifest::parse(&text).map_err(invalid)?;
            Ok((manifest, text))
        }
        Opened::Missing => Err(not_found(format!("{} is not a schema package: it has no {MANIFEST}", shown(dir)))),
        Opened::NotRegular => {
            let reason =
                format!("the manifest {} is a symbolic link or not a regular file; it is not read", shown(&path));
            Err(Error::new(ErrorCode::PackagePath, reason))
        }
        Opened::TooLarge(size) => Err(invalid(format!("the manifest has {size} bytes, more than 64 KiB"))),
        Opened::Failed(e) => Err(Error::at(&path, ErrorCode::ImportNotFound, e)),
    }
}

/// A schema file an import names, read.
pub(crate) struct Source {
    /// Its real path: two imports reach the same file when it is the same.
    pub path: PathBuf,
    pub text: String,
    /// The package, for a package's `schema.haus`.
    pub package: Option<Found>,
}

/// A package, with its manifest checked.
pub(crate) struct Found {
    pub manifest: Manifest,
    /// Its directory's real path.
    pub dir: PathBuf,
    /// The manifest's text: copies of a package have the same.
    pub manifest_text: String,
}

/// The package `name` for the file at `from` (a real path), found by
/// `packages` (which checks that `from` declares it, `undeclared-package`)
/// and checked: the manifest (`package-manifest`) and its name
/// (`import-not-found`), its version (`package-version`), its files
/// (`package-path`, `file-too-large`), and that a package found in a folder
/// that the package manager has too is the same (`duplicate-package`).
pub(crate) fn package(
    packages: &dyn Locator,
    name: &str,
    from: Option<&Path>,
    files: &mut FileCache,
) -> Result<Source> {
    let location = packages.locate_in(name, from, files)?;
    let source = open_package(&location.dir, name, location.version.as_deref(), files)?;
    if let Some(copy) = &location.same_as {
        let other = open_package(copy, name, None, files)?;
        let (a, b) = (source.package.as_ref().expect("a package"), other.package.as_ref().expect("a package"));
        if a.dir != b.dir && (a.manifest_text != b.manifest_text || source.text != other.text) {
            return Err(duplicate((&a.manifest, &a.dir), (&b.manifest, &b.dir)));
        }
    }
    Ok(source)
}

/// The package in `dir`, which must be called `name`, with `version` from its package manager.
fn open_package(dir: &Path, name: &str, version: Option<&str>, files: &mut FileCache) -> Result<Source> {
    let dir = dir.canonicalize().map_err(|e| not_found(format!("{}: {e}", shown(dir))))?;
    let (manifest, manifest_text) = files.manifest(&dir)?;
    if manifest.name != name {
        let reason = format!("{} names the package {}, not {name}", shown(&dir.join(MANIFEST)), quote(&manifest.name));
        return Err(not_found(reason));
    }
    if let Some(version) = version.filter(|v| *v != manifest.version) {
        let says = quote(&manifest.version);
        let reason = match is_semver(version) {
            true => format!(
                "the package.haus of {name} says version {says}, its package manager {} ({})",
                quote(version),
                shown(&dir)
            ),
            false => format!(
                "the package.haus of {name} says version {says}, and the version its package manager gives \
                 isn't a semantic version ({})",
                shown(&dir)
            ),
        };
        return Err(Error::new(ErrorCode::PackageVersion, reason));
    }
    let path = dir.join(SCHEMA);
    let text = files.schema(&path, Kind::PackageSchema, || {
        format!("{name} has no {SCHEMA} next to its manifest ({})", shown(&dir))
    })?;
    Ok(Source { path, text, package: Some(Found { manifest, dir, manifest_text }) })
}

/// The file `module` (`./common`, `../shared/money`) imports, next to the
/// file at `from` (a real path; None for a schema given as text, which
/// imports no files). A package imports no files, and a file outside a
/// package no file inside one (`package-path`). Each name in the path is
/// spelled as its directory lists it, and the file's real path ends in
/// `.schema.haus` (`import-not-found`, the file not read).
pub(crate) fn file(module: &str, from: Option<&Path>, files: &mut FileCache) -> Result<Source> {
    let Some(from) = from else {
        let reason = "a schema read from text imports no files (load it from its file)";
        return Err(Error::new(ErrorCode::ImportUnavailable, reason));
    };
    // A package is one file: its schema imports other packages by name (spec §13.3).
    if let Some(package) = package_dir_of(from) {
        let name = files.manifest(package).map_or_else(|_| shown(package), |(m, _)| m.name);
        let reason = format!("the schema of {name} can't import files, only packages by name");
        return Err(Error::new(ErrorCode::PackagePath, reason));
    }
    let dir = from.parent().unwrap_or(Path::new("."));
    let relative = format!("{module}{EXTENSION}");
    let path = dir.join(&relative);
    if let Some(name) = misspelled(dir, Path::new(&relative)) {
        let reason = format!(
            "file not found: {} (no {} in its directory: names are spelled as the directory lists them)",
            shown(&path),
            quote(&name)
        );
        return Err(not_found(reason));
    }
    // An application's file doesn't reach into a package: it imports the package by name.
    let real = path.canonicalize().ok();
    if let Some(into) = real.as_deref().and_then(package_dir_of).or_else(|| package_dir_of(&path)) {
        let reason = format!("the file is in the package directory {}: import the package by its name", shown(into));
        return Err(Error::new(ErrorCode::PackagePath, reason));
    }
    let Some(real) = real else {
        return Err(not_found(format!("file not found: {}", shown(&path))));
    };
    if !real.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with(EXTENSION)) {
        let reason = format!(
            "{} is not a schema file: its real path {} doesn't end in {EXTENSION}; it is not read",
            shown(&path),
            shown(&real)
        );
        return Err(not_found(reason));
    }
    let text = files.schema(&real, Kind::Schema, || format!("file not found: {}", shown(&path)))?;
    Ok(Source { text, path: real, package: None })
}

/// The first name in `relative` (from `dir`) that its directory doesn't
/// list byte for byte, if any: on file systems that ignore case or Unicode
/// normalization, `./Billing/common` finds `billing/common.schema.haus`.
fn misspelled(dir: &Path, relative: &Path) -> Option<String> {
    let mut at = dir.to_owned();
    for part in relative.components() {
        match part {
            Component::Normal(name) => {
                // A directory that can't be listed: the file isn't found later.
                let listed = fs::read_dir(&at).ok()?.filter_map(|e| e.ok()).any(|e| e.file_name() == name);
                if !listed {
                    return Some(name.to_string_lossy().into_owned());
                }
                at.push(name);
            }
            Component::ParentDir => at.push(".."),
            _ => {}
        }
    }
    None
}

/// The root schema file at `path`: its real path and text. A package's
/// `schema.haus` is read as one (never through a link).
pub(crate) fn root(path: &Path, files: &mut FileCache) -> Result<(PathBuf, String)> {
    let real = path.canonicalize().map_err(|e| Error::at(path, ErrorCode::ImportNotFound, e))?;
    let kind = match is_package_schema(&real) {
        true => Kind::PackageSchema,
        false => Kind::Schema,
    };
    let text = files.schema(&real, kind, || format!("file not found: {}", shown(path))).map_err(|e| e.in_file(path))?;
    Ok((real, text))
}

/// Whether the file at `path` is a package's `schema.haus`: next to a `package.haus`.
pub(crate) fn is_package_schema(path: &Path) -> bool {
    path.file_name() == Some(SCHEMA.as_ref())
        && path.parent().is_some_and(|dir| fs::symlink_metadata(dir.join(MANIFEST)).is_ok())
}

/// The package whose `schema.haus` is the file at `path` (a real path), if
/// it is one, with its manifest checked.
pub(crate) fn package_of(path: &Path, files: &mut FileCache) -> Result<Option<Found>> {
    let Some(dir) = path.parent().filter(|_| is_package_schema(path)) else {
        return Ok(None);
    };
    let (manifest, manifest_text) = files.manifest(dir)?;
    Ok(Some(Found { manifest, dir: dir.to_owned(), manifest_text }))
}

/// The id of a file outside packages: its path from `base`, `/`-separated,
/// without the extension (`billing/common`, `../shared/money`). Different
/// files have different ids.
pub(crate) fn relative_id(base: &Path, path: &Path) -> String {
    let (base, path): (Vec<Component>, Vec<Component>) = (base.components().collect(), path.components().collect());
    let common = base.iter().zip(&path).take_while(|(a, b)| a == b).count();
    let up = (common..base.len()).map(|_| "..".to_owned());
    let down = path[common..].iter().map(|c| c.as_os_str().to_string_lossy().into_owned());
    let id = up.chain(down).collect::<Vec<_>>().join("/");
    id.strip_suffix(EXTENSION).map(str::to_owned).unwrap_or(id)
}

fn not_found(reason: String) -> Error {
    Error::new(ErrorCode::ImportNotFound, reason)
}

/// `file-too-large`: the file at `path` has `size` bytes.
fn too_large(path: &Path, size: u64) -> Error {
    let reason = format!("{} has {size} bytes, more than 1 MiB; it is not read", shown(path));
    Error::new(ErrorCode::FileTooLarge, reason)
}

#[cfg(test)]
pub(crate) mod tests {
    use std::cell::RefCell;
    use std::path::PathBuf;

    thread_local! {
        /// Every file opened on this thread, in order.
        pub(crate) static OPENED: RefCell<Vec<PathBuf>> = const { RefCell::new(vec![]) };
    }

    /// A file needed in two roles is read once, by its real path (spec
    /// §13.3): `app/package.json` is a link to `app/x.schema.haus`, which
    /// `app/a.schema.haus` imports, and the project's `package.json` is
    /// read for the package it imports too.
    #[cfg(unix)]
    #[test]
    fn a_file_in_two_roles_is_read_once() {
        use crate::{NodeModules, Schema};
        use haus::ErrorCode;
        use std::fs;
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("app");
        fs::create_dir_all(&app).unwrap();
        fs::write(app.join("x.schema.haus"), "type X = Int").unwrap();
        fs::write(app.join("a.schema.haus"), "import ./x (X)\nimport @acme/money (Money)\ntype A = { x: X, m: Money }")
            .unwrap();
        symlink("x.schema.haus", app.join("package.json")).unwrap();
        OPENED.with(|o| o.borrow_mut().clear());
        let e = Schema::load(app.join("a.schema.haus"), &NodeModules).expect_err("x declares no packages");
        // The project's package.json is the schema file's bytes: not JSON, so it declares nothing.
        assert_eq!(e.code(), ErrorCode::UndeclaredPackage, "{e}");
        let x = app.join("x.schema.haus").canonicalize().unwrap();
        let opened = OPENED.with(|o| o.borrow().clone());
        let x_opens = opened.iter().filter(|p| p.canonicalize().ok().as_ref() == Some(&x)).count();
        assert_eq!(x_opens, 1, "{opened:?}");
    }

    /// Each use of a file read once keeps its own checks: a package's files
    /// are never read through a link, and a manifest has its own limit.
    #[cfg(unix)]
    #[test]
    fn each_use_keeps_its_checks() {
        use super::{FileCache, Kind, Opened};
        use std::fs;
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let (file, link) = (dir.path().join("x.schema.haus"), dir.path().join("schema.haus"));
        fs::write(&file, "type X = Int\n".repeat(8000)).unwrap();
        symlink("x.schema.haus", &link).unwrap();
        let mut files = FileCache::new();
        assert!(matches!(files.open(&file, Kind::Schema), Opened::Read(_)));
        assert!(matches!(files.open(&link, Kind::PackageSchema), Opened::NotRegular));
        assert!(matches!(files.open(&file, Kind::Manifest), Opened::TooLarge(104000)));
        assert!(matches!(files.open(&link, Kind::ProjectJson), Opened::Read(_)));
    }
}
