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
    let follow = kind.follows_links();
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
    let limit = kind.limit();
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

/// The files one schema reads, each once (spec §13.3): by path and how it
/// is read. [`Schema::load`](crate::Schema::load) makes one for each schema;
/// a [`Locator`] reads `package.json` files through it.
#[derive(Debug, Default)]
pub struct FileCache {
    opened: HashMap<(PathBuf, Kind), Opened>,
    json: HashMap<(PathBuf, Kind), Option<Rc<Json>>>,
}

impl FileCache {
    pub fn new() -> FileCache {
        FileCache::default()
    }

    pub(crate) fn open(&mut self, path: &Path, kind: Kind) -> Opened {
        self.opened.entry((path.to_owned(), kind)).or_insert_with(|| open(path, kind)).clone()
    }

    /// A `package.json` (`kind` says whose): None if there is none (or, for a
    /// project's, it isn't a regular file), JSON `null` if it isn't valid
    /// JSON (it declares nothing and gives no version).
    pub(crate) fn package_json(&mut self, path: &Path, kind: Kind) -> Result<Option<Rc<Json>>> {
        if let Some(json) = self.json.get(&(path.to_owned(), kind)) {
            return Ok(json.clone());
        }
        let json = match self.open(path, kind) {
            Opened::Missing => None,
            Opened::NotRegular if kind == Kind::ProjectJson => None,
            Opened::NotRegular => {
                let reason = format!("{} is a symbolic link or not a regular file; it is not read", shown(path));
                return Err(Error::new(ErrorCode::PackagePath, reason));
            }
            Opened::TooLarge(size) => return Err(too_large(path, size)),
            Opened::Failed(e) => return Err(not_found(format!("{}: {e}", shown(path)))),
            Opened::Read(bytes) => {
                let json = std::str::from_utf8(&bytes).ok().and_then(|text| haus::json::parse(text).ok());
                Some(Rc::new(json.unwrap_or(Json::Null)))
            }
        };
        self.json.insert((path.to_owned(), kind), json.clone());
        Ok(json)
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
            Opened::Read(bytes) => {
                String::from_utf8(bytes.to_vec()).map_err(|_| not_found(format!("{} is not UTF-8 text", shown(path))))
            }
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
