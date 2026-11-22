//! Reading the files imports name (spec §13.3), the same for every package
//! manager: a [`Locator`] says where a package is, and the rules here say
//! whether it may be read. Resolution happens when a schema is loaded, never
//! while data is parsed, and never over the network (§9.2).
//!
//! Every file a build reads (the entry file, the files of relative imports,
//! a package's `package.haus`, `schema.haus` and `package.json`) is a regular
//! file, opened by its real path or in a real directory without following a
//! link at its last name (`O_NOFOLLOW`), without blocking (`O_NONBLOCK`, so
//! that a FIFO can't block the open) and without becoming a controlling
//! terminal (`O_NOCTTY`). Its type, size, device and inode are checked on
//! the opened file against what `lstat` saw, and it is read from that file,
//! so the file checked is the file read (spec §13.3, "Files read").
//! On Windows files are opened with `FILE_FLAG_OPEN_REPARSE_POINT` (the
//! link itself, not its target), after a `symlink_metadata` check, and the
//! type and size are checked on the handle; without a stable way to compare
//! the two files' identities (`MetadataExt::file_index` is unstable), a file
//! replaced between that check and the open is caught only by the handle's
//! own type and size.
//!
//! The names a build looks up itself (`package.haus`, `schema.haus`,
//! `package.json`) and every name of a relative import's path match only an
//! entry their directory lists with that spelling, also on file systems that
//! ignore case; a directory that can't be listed lists nothing (spec §13.3,
//! "Spelling").
//!
//! Only the entry file and the `root` option are resolved to real paths
//! (`canonicalize`), once, at the start, and package directories, which may
//! be links. A relative import follows no link: it is walked down name by
//! name from the importing file's real directory, each name listed with
//! that spelling and none a symbolic link (`symlink_metadata`), so the path
//! reached is a real path and its root check is on the text.

use crate::locator::{Locator, duplicate};
use crate::packages::{MANIFEST, MAX_MANIFEST, Manifest, SCHEMA, has_manifest, is_semver};
use crate::{Error, Result, quote, shown};
use haus::ErrorCode;
use haus::json::Json;
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs::{self, Metadata, OpenOptions};
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
    /// A package's `package.haus`: at most 64 KiB, its name spelled exactly.
    Manifest,
    /// A package's `schema.haus`: at most 1 MiB, its name spelled exactly.
    PackageSchema,
    /// A package's `package.json`: at most 1 MiB, its name spelled exactly.
    PackageJson,
    /// A schema file outside packages, read at its real path: at most 1 MiB.
    Schema,
}

impl Kind {
    fn limit(self) -> u64 {
        match self {
            Kind::Manifest => MAX_MANIFEST,
            _ => MAX_FILE,
        }
    }

    /// Whether its name is one the build looks up itself, which its
    /// directory must list with that spelling (spec §13.3, "Spelling").
    fn named(self) -> bool {
        self != Kind::Schema
    }
}

/// A file opened and read, or why it wasn't.
#[derive(Debug, Clone)]
pub(crate) enum Opened {
    /// Not there, or not listed by its directory with that spelling.
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
    match unlisted(path, kind) {
        true => Opened::Missing,
        false => read(path, kind.limit()),
    }
}

/// Whether `path` is a name the build looks up itself (`kind`) that its
/// directory doesn't list with that spelling.
fn unlisted(path: &Path, kind: Kind) -> bool {
    kind.named() && !path.parent().zip(path.file_name()).is_some_and(|(dir, name)| listed(dir, name))
}

/// Whether the directory `dir` lists `name`, byte for byte. A directory
/// that can't be listed lists nothing: it can't show how a name is spelled
/// (spec §13.3, "Spelling").
pub(crate) fn listed(dir: &Path, name: &OsStr) -> bool {
    fs::read_dir(dir).is_ok_and(|entries| entries.filter_map(|e| e.ok()).any(|e| e.file_name() == name))
}

/// The most any file is read to: [`FileCache`] reads each file once, to the
/// largest limit, and checks each use's own limit on what it read.
const MAX_READ: u64 = if MAX_FILE > MAX_MANIFEST { MAX_FILE } else { MAX_MANIFEST };

/// Opens the file at `path` without following a link at its last name, and
/// reads it: a regular file of at most `limit` bytes, the same file `lstat`
/// saw, checked on the opened file (spec §13.3, "Files read").
fn read(path: &Path, limit: u64) -> Opened {
    #[cfg(test)]
    tests::OPENED.with(|o| o.borrow_mut().push(path.to_owned()));
    let before = match fs::symlink_metadata(path) {
        Ok(m) if m.is_file() => m,
        // A link, a directory, a FIFO, a device: never opened.
        Ok(_) => return Opened::NotRegular,
        Err(e) if e.kind() == ErrorKind::NotFound => return Opened::Missing,
        Err(e) => return Opened::Failed(e.to_string()),
    };
    let file = match options().open(path) {
        Ok(file) => file,
        // Replaced by a link (ELOOP) or by something else since the check, …
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
    if !meta.is_file() || !same_file(&before, &meta) {
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

/// Whether the file opened (`after`) is the one checked before (`before`):
/// the same device and inode.
#[cfg(unix)]
fn same_file(before: &Metadata, after: &Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    before.dev() == after.dev() && before.ino() == after.ino()
}

/// Whether the file opened (`after`) is the one checked before (`before`):
/// without a stable file index, the same size.
#[cfg(not(unix))]
fn same_file(before: &Metadata, after: &Metadata) -> bool {
    before.len() == after.len()
}

#[cfg(unix)]
fn options() -> OpenOptions {
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = OpenOptions::new();
    options.read(true).custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_NOCTTY);
    options
}

#[cfg(windows)]
fn options() -> OpenOptions {
    use std::os::windows::fs::OpenOptionsExt;
    /// The link itself, not what it links to.
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    let mut options = OpenOptions::new();
    options.read(true).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    options
}

#[cfg(not(any(unix, windows)))]
fn options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.read(true);
    options
}

/// What a file read for one use is for another, `kind`: too large if it is
/// larger than that use allows.
fn within(opened: Opened, kind: Kind) -> Opened {
    match opened {
        Opened::Read(bytes) if bytes.len() as u64 > kind.limit() => Opened::TooLarge(bytes.len() as u64),
        opened => opened,
    }
}

/// The files one schema reads, each once (spec §13.3), by real path: every
/// use of a file sees the same bytes. Each use still gets its own checks: a
/// package's files are spelled exactly, and each kind of file has its own
/// size limit. [`Schema::load`](crate::Schema::load) makes one for each
/// schema, with the build's root, which messages show paths relative to; a
/// [`Locator`] reads `package.json` files through it.
#[derive(Debug, Default)]
pub struct FileCache {
    /// By real path; a file that isn't there by the path it was looked for at.
    opened: HashMap<PathBuf, Opened>,
    /// The `package.json` files parsed, by real path: `null` if not valid JSON.
    json: HashMap<PathBuf, Rc<Json>>,
    /// The real path of the build's root (spec §13.3, "The root"), if known.
    root: Option<PathBuf>,
}

impl FileCache {
    pub fn new() -> FileCache {
        FileCache::default()
    }

    /// The real path of the build's root, if known.
    pub(crate) fn root(&self) -> Option<&Path> {
        self.root.as_deref()
    }

    pub(crate) fn set_root(&mut self, root: PathBuf) {
        self.root = Some(root);
    }

    /// A path, for a message: relative to the build's root if it is known
    /// (`common.schema.haus`, `../vendor/x`), so that messages don't show
    /// the directories above it (spec §13.3, "The root").
    pub(crate) fn shown(&self, path: &Path) -> String {
        match &self.root {
            Some(root) if path.is_absolute() => shown(&relative(root, path)),
            _ => shown(path),
        }
    }

    pub(crate) fn open(&mut self, path: &Path, kind: Kind) -> Opened {
        self.opened_at(path, kind).1
    }

    /// The file at `path`, read as `kind` says, and the path it is cached by.
    fn opened_at(&mut self, path: &Path, kind: Kind) -> (PathBuf, Opened) {
        if unlisted(path, kind) {
            return (path.to_owned(), Opened::Missing);
        }
        // Never through a link at its last name (checked again on the opened file).
        match fs::symlink_metadata(path) {
            Ok(m) if !m.is_file() => return (path.to_owned(), Opened::NotRegular),
            Err(e) if e.kind() == ErrorKind::NotFound => return (path.to_owned(), Opened::Missing),
            _ => {}
        }
        let key = path.canonicalize().unwrap_or_else(|_| path.to_owned());
        let opened = self.opened.entry(key.clone()).or_insert_with(|| read(path, MAX_READ));
        (key, within(opened.clone(), kind))
    }

    /// A package's `package.json`: None if there is none, JSON `null` if it
    /// isn't valid JSON (it declares nothing and gives no version).
    pub(crate) fn package_json(&mut self, path: &Path) -> Result<Option<Rc<Json>>> {
        let (key, opened) = self.opened_at(path, Kind::PackageJson);
        match opened {
            Opened::Missing => Ok(None),
            Opened::NotRegular => {
                let reason = format!("{} is a symbolic link or not a regular file; it is not read", self.shown(path));
                Err(Error::new(ErrorCode::PackagePath, reason))
            }
            Opened::TooLarge(size) => Err(too_large(&self.shown(path), size)),
            Opened::Failed(e) => Err(not_found(format!("{}: {e}", self.shown(path)))),
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
        let opened = self.open(&dir.join(MANIFEST), Kind::Manifest);
        manifest(dir, &self.shown(dir), opened)
    }

    /// A schema file's text: a package's `schema.haus`, or a file outside
    /// packages at its real path. `missing` says why a missing one is missing.
    pub(crate) fn schema(&mut self, path: &Path, kind: Kind, missing: impl FnOnce() -> String) -> Result<String> {
        match self.open(path, kind) {
            Opened::Read(bytes) => String::from_utf8(bytes.to_vec())
                .map_err(|_| Error::new(ErrorCode::InvalidUtf8, format!("{} is not UTF-8 text", self.shown(path)))),
            Opened::Missing => Err(not_found(missing())),
            Opened::NotRegular if kind == Kind::PackageSchema => {
                let reason = format!("{} is a symbolic link or not a regular file; it is not read", self.shown(path));
                Err(Error::new(ErrorCode::PackagePath, reason))
            }
            Opened::NotRegular => Err(not_found(format!("{} is not a regular file; it is not read", self.shown(path)))),
            Opened::TooLarge(size) => Err(too_large(&self.shown(path), size)),
            Opened::Failed(e) => Err(not_found(format!("{}: {e}", self.shown(path)))),
        }
    }
}

/// `path` relative to the directory `base` (both absolute): `x`,
/// `sub/x`, `../vendor/x`, or `.` for `base` itself.
pub(crate) fn relative(base: &Path, path: &Path) -> PathBuf {
    let (base, path): (Vec<Component>, Vec<Component>) = (base.components().collect(), path.components().collect());
    let common = base.iter().zip(&path).take_while(|(a, b)| a == b).count();
    let up = (common..base.len()).map(|_| Component::ParentDir);
    let relative: PathBuf = up.chain(path[common..].iter().copied()).collect();
    match relative.as_os_str().is_empty() {
        true => PathBuf::from("."),
        false => relative,
    }
}

/// The manifest at `dir/package.haus` (`dir` shown as `shown_dir`), opened: checked (spec §13.3).
pub(crate) fn manifest(dir: &Path, shown_dir: &str, opened: Opened) -> Result<(Manifest, String)> {
    let path = dir.join(MANIFEST);
    let invalid = |reason: String| Error::at(&path, ErrorCode::PackageManifest, reason);
    match opened {
        Opened::Read(bytes) => {
            let text = String::from_utf8(bytes.to_vec()).map_err(|_| invalid("the manifest is not UTF-8".into()))?;
            let manifest = Manifest::parse(&text).map_err(invalid)?;
            Ok((manifest, text))
        }
        Opened::Missing => Err(not_found(format!("{shown_dir} is not a schema package: it has no {MANIFEST}"))),
        Opened::NotRegular => {
            let reason = format!(
                "the manifest {}{MANIFEST} is a symbolic link or not a regular file; it is not read",
                with_separator(shown_dir)
            );
            Err(Error::new(ErrorCode::PackagePath, reason))
        }
        Opened::TooLarge(size) => Err(invalid(format!("the manifest has {size} bytes, more than 64 KiB"))),
        Opened::Failed(e) => Err(Error::at(&path, ErrorCode::ImportNotFound, e)),
    }
}

/// A directory as shown, with a separator after it, to put a name after.
fn with_separator(dir: &str) -> String {
    match dir.ends_with(std::path::MAIN_SEPARATOR) {
        true => dir.to_owned(),
        false => format!("{dir}{}", std::path::MAIN_SEPARATOR),
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
            return Err(duplicate((&a.manifest, &files.shown(&a.dir)), (&b.manifest, &files.shown(&b.dir))));
        }
    }
    Ok(source)
}

/// The package in `dir`, which must be called `name`, with `version` from its package manager.
fn open_package(dir: &Path, name: &str, version: Option<&str>, files: &mut FileCache) -> Result<Source> {
    let dir = dir.canonicalize().map_err(|e| not_found(format!("{}: {e}", files.shown(dir))))?;
    let (manifest, manifest_text) = files.manifest(&dir)?;
    if manifest.name != name {
        let reason =
            format!("{} names the package {}, not {name}", files.shown(&dir.join(MANIFEST)), quote(&manifest.name));
        return Err(not_found(reason));
    }
    if let Some(version) = version.filter(|v| *v != manifest.version) {
        let says = quote(&manifest.version);
        let reason = match is_semver(version) {
            true => format!(
                "the package.haus of {name} says version {says}, its package manager {} ({})",
                quote(version),
                files.shown(&dir)
            ),
            false => format!(
                "the package.haus of {name} says version {says}, and the version its package manager gives \
                 isn't a semantic version ({})",
                files.shown(&dir)
            ),
        };
        return Err(Error::new(ErrorCode::PackageVersion, reason));
    }
    let path = dir.join(SCHEMA);
    let shown_dir = files.shown(&dir);
    let text = files
        .schema(&path, Kind::PackageSchema, || format!("{name} has no {SCHEMA} next to its manifest ({shown_dir})"))?;
    Ok(Source { path, text, package: Some(Found { manifest, dir, manifest_text }) })
}

/// The file `module` (`./common`, `../shared/money`, a path of grammar
/// `path`, checked when the importing file was parsed) imports, next to the
/// file at `from` (a real path; None for a schema given as text, which
/// imports no files), checked in the order of spec §13.3 ("Resolution"):
///
/// - a package imports no files (`package-path`): `package` is the name of
///   the package whose `schema.haus` the importing file was read as, if it
///   was (what is above it on the disk doesn't matter: an application's file
///   may sit in a package's directory);
/// - its `..` names don't go above the build's root (`import-outside-root`),
///   checked on the text, before anything is looked at;
/// - the walk down its names from the importing file's real directory: each
///   name listed by its directory with that spelling, and none a symbolic
///   link, checked without following it (`import-not-found`; nothing behind
///   a link is looked at); so the path reached has no links, and is inside
///   the root;
/// - the directories from the file's up to the root, the root included,
///   aren't a package's (`package-path`), and can be listed to check that
///   (`import-not-found`);
/// - it is a regular file (`import-not-found`), within its limit.
///
/// A file rejected by these checks is not read.
pub(crate) fn file(module: &str, from: Option<&Path>, package: Option<&str>, files: &mut FileCache) -> Result<Source> {
    let Some(from) = from else {
        let reason = "a schema read from text imports no files (load it from its file)";
        return Err(Error::new(ErrorCode::ImportUnavailable, reason));
    };
    // A package is one file: its schema imports other packages by name (spec §13.3).
    if let Some(name) = package {
        let reason = format!("the schema of {name} can't import files, only packages by name");
        return Err(Error::new(ErrorCode::PackagePath, reason));
    }
    // `..` only at the start (grammar `path`): from the real directory of the
    // importing file, going up is the same on the text and on the file system.
    let names: Vec<&str> = module.split('/').filter(|n| *n != ".").collect();
    let up = names.iter().take_while(|n| **n == "..").count();
    let start = from.parent().and_then(|dir| dir.ancestors().nth(up));
    let root = files.root().map(Path::to_owned);
    let above = match (&root, start) {
        (Some(root), Some(start)) => !start.starts_with(root),
        (Some(_), None) => true,
        (None, _) => false,
    };
    if above {
        let reason = "its .. names go above the build's root; nothing there is looked at";
        return Err(Error::new(ErrorCode::ImportOutsideRoot, reason).with_hint(ROOT_HINT));
    }
    let Some(start) = start else {
        return Err(not_found(format!("file not found: {}", quote(module))));
    };
    let mut down: Vec<String> = names[up..].iter().map(|n| (*n).to_owned()).collect();
    if let Some(last) = down.last_mut() {
        last.push_str(EXTENSION);
    }
    let path = walk(start, &down, files)?;
    // An application's file doesn't reach into a package: it imports the package by name.
    in_package(&path, root.as_deref(), files)?;
    let shown_path = files.shown(&path);
    let text = files.schema(&path, Kind::Schema, || format!("file not found: {shown_path}"))?;
    Ok(Source { text, path, package: None })
}

/// The hint for `import-outside-root`.
const ROOT_HINT: &str = "Give the build a root option that contains both files (the directory of the schema file \
                         it starts from is the root by default), or import a schema package by its name.";

/// The names `dir` lists; None if it can't be listed, or not to the end.
fn list(dir: &Path) -> Option<Vec<std::ffi::OsString>> {
    fs::read_dir(dir).ok()?.map(|e| e.map(|e| e.file_name()).ok()).collect()
}

/// Whether `lstat` saw a symbolic link (on Windows, any reparse point: a junction too).
fn is_link(meta: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        /// `FILE_ATTRIBUTE_REPARSE_POINT`.
        const REPARSE_POINT: u32 = 0x400;
        if meta.file_attributes() & REPARSE_POINT != 0 {
            return true;
        }
    }
    meta.file_type().is_symlink()
}

/// The path `names` lead to from the real directory `dir`, walked down one
/// name at a time (spec §13.3, "Resolution"): each name listed by its
/// directory byte for byte (on file systems that ignore case or Unicode
/// normalization, `./Billing/common` doesn't find
/// `billing/common.schema.haus`; a directory that can't be listed lists
/// nothing), and none a symbolic link, checked without following it, so
/// nothing behind a link is looked at; each name but the last a directory.
/// The path reached has no links: it is a real path.
fn walk(dir: &Path, names: &[String], files: &FileCache) -> Result<PathBuf> {
    let wanted = names.iter().fold(dir.to_owned(), |path, name| path.join(name));
    let mut at = dir.to_owned();
    for (i, name) in names.iter().enumerate() {
        let Some(listed) = list(&at) else {
            return Err(not_found(format!(
                "file not found: {} ({} can't be listed, so how the name in it is spelled can't be checked)",
                files.shown(&wanted),
                files.shown(&at)
            )));
        };
        if !listed.iter().any(|n| n == name.as_str()) {
            return Err(not_found(format!(
                "file not found: {} (no {} in its directory: names are spelled as the directory lists them)",
                files.shown(&wanted),
                quote(name)
            )));
        }
        at.push(name);
        let meta = fs::symlink_metadata(&at)
            .map_err(|e| not_found(format!("file not found: {}: {e}", files.shown(&wanted))))?;
        if is_link(&meta) {
            return Err(not_found(format!(
                "{} is a symbolic link: a relative import follows no link, and nothing behind it is read",
                quote(name)
            )));
        }
        if i + 1 < names.len() && !meta.is_dir() {
            return Err(not_found(format!(
                "file not found: {} ({} is not a directory)",
                files.shown(&wanted),
                quote(name)
            )));
        }
    }
    Ok(at)
}

/// Fails if the file at `path` (a real path) is in a package's directory
/// (spec §13.3, "Imports"): the directories from its own up to the build's
/// `root`, the root included, each a package's when it lists `package.haus`.
/// One that can't be listed can't show whether it is a package's: the import
/// fails (`import-not-found`), never passes as one outside a package.
fn in_package(path: &Path, root: Option<&Path>, files: &FileCache) -> Result<()> {
    for dir in path.ancestors().skip(1).take_while(|d| root.is_none_or(|root| d.starts_with(root))) {
        let Some(names) = list(dir) else {
            return Err(not_found(format!(
                "whether {} is a package's directory can't be checked (it can't be listed); it is not read",
                files.shown(dir)
            )));
        };
        if names.iter().any(|n| n == MANIFEST) {
            let reason =
                format!("the file is in the package directory {}: import the package by its name", files.shown(dir));
            return Err(Error::new(ErrorCode::PackagePath, reason));
        }
    }
    Ok(())
}

/// The root schema file at `path` (the entry file): its real path and text.
/// A package's `schema.haus` is read as one.
pub(crate) fn root(path: &Path, files: &mut FileCache) -> Result<(PathBuf, String)> {
    let real = path.canonicalize().map_err(|e| Error::at(path, ErrorCode::ImportNotFound, e))?;
    let kind = match is_package_schema(&real) {
        true => Kind::PackageSchema,
        false => Kind::Schema,
    };
    let text = files.schema(&real, kind, || format!("file not found: {}", shown(path))).map_err(|e| e.in_file(path))?;
    Ok((real, text))
}

/// The build's root (spec §13.3, "The root") for the entry file whose real
/// path is `entry`: the real path of `option`, a directory that contains the
/// entry file (`import-outside-root` if it doesn't, `import-not-found` if it
/// isn't there), or by default the directory of `entry`. A relative `option`
/// is relative to the directory of `entry`. Errors have no place.
pub(crate) fn build_root(entry: &Path, option: Option<&Path>) -> Result<PathBuf> {
    let dir = entry.parent().unwrap_or(entry);
    let Some(option) = option else {
        return Ok(dir.to_owned());
    };
    let root = dir.join(option).canonicalize().map_err(|e| {
        Error::new(ErrorCode::ImportNotFound, format!("the root {} given doesn't exist: {e}", shown(option)))
    })?;
    match root.is_dir() && entry.starts_with(&root) {
        true => Ok(root),
        false => {
            let reason = format!(
                "the root {} given doesn't contain the schema file the build starts from, {}",
                shown(option),
                entry.file_name().map_or_else(|| shown(entry), |n| shown(Path::new(n)))
            );
            Err(Error::new(ErrorCode::ImportOutsideRoot, reason).with_hint(ROOT_HINT))
        }
    }
}

/// Whether the file at `path` is a package's `schema.haus`: next to a `package.haus`.
pub(crate) fn is_package_schema(path: &Path) -> bool {
    path.file_name() == Some(SCHEMA.as_ref()) && path.parent().is_some_and(has_manifest)
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
    let id = relative(base, path).components().map(|c| c.as_os_str().to_string_lossy()).collect::<Vec<_>>().join("/");
    id.strip_suffix(EXTENSION).map(str::to_owned).unwrap_or(id)
}

/// The id of a file outside packages, as given or built: one that would
/// have the form of a package's id, `@org/name@N` (a project or an entry
/// file whose name starts with `@`), starts with `./` instead, so that a
/// codec selected for a package's type never applies to a file's (spec
/// §13.3, "Identity").
pub(crate) fn file_id(id: String) -> String {
    match id.starts_with('@') {
        true => format!("./{id}"),
        false => id,
    }
}

fn not_found(reason: String) -> Error {
    Error::new(ErrorCode::ImportNotFound, reason)
}

/// `file-too-large`: the file shown as `path` has `size` bytes.
fn too_large(path: &str, size: u64) -> Error {
    let reason = format!("{path} has {size} bytes, more than 1 MiB; it is not read");
    Error::new(ErrorCode::FileTooLarge, reason)
}

#[cfg(test)]
pub(crate) mod tests {
    use std::cell::RefCell;
    use std::path::{Path, PathBuf};

    thread_local! {
        /// Every file opened on this thread, in order.
        pub(crate) static OPENED: RefCell<Vec<PathBuf>> = const { RefCell::new(vec![]) };
    }

    /// A file imported by two files is read once, by its real path (spec
    /// §13.3): `a` imports `x` and `sub/b`, which imports `x` as `../x`.
    #[test]
    fn a_file_is_read_once() {
        use crate::{NoImports, Schema};
        use std::fs;
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("app");
        fs::create_dir_all(app.join("sub")).unwrap();
        fs::write(app.join("x.schema.haus"), "type X = Int").unwrap();
        fs::write(app.join("sub/b.schema.haus"), "import ../x (X)\ntype B = X").unwrap();
        fs::write(app.join("a.schema.haus"), "import ./x (X)\nimport ./sub/b (B)\ntype A = { x: X, b: B }").unwrap();
        OPENED.with(|o| o.borrow_mut().clear());
        Schema::load(app.join("a.schema.haus"), &NoImports).unwrap();
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
        assert!(matches!(files.open(&link, Kind::Schema), Opened::NotRegular));
        assert!(matches!(files.open(&file, Kind::Manifest), Opened::TooLarge(104000)));
    }

    /// Names the build looks up itself are spelled exactly (spec §13.3,
    /// "Spelling"), also on file systems that ignore case.
    #[test]
    fn names_are_spelled_exactly() {
        use super::{FileCache, Kind, Opened};
        use std::fs;
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("Package.haus"), "{ name: \"@a/b\", version: \"1.0.0\" }").unwrap();
        let mut files = FileCache::new();
        assert!(matches!(files.open(&dir.path().join("package.haus"), Kind::Manifest), Opened::Missing));
        assert!(!crate::packages::has_manifest(dir.path()));
    }

    /// Messages show paths relative to the build's root (spec §13.3).
    #[test]
    fn paths_relative_to_the_root() {
        use super::relative;
        let root = Path::new("/home/someone/proj/app");
        assert_eq!(relative(root, Path::new("/home/someone/proj/app/x.schema.haus")), Path::new("x.schema.haus"));
        assert_eq!(relative(root, Path::new("/home/someone/proj/vendor/x")), Path::new("../vendor/x"));
        assert_eq!(relative(root, root), Path::new("."));
    }

    /// A file's id never has the form of a package's id (spec §13.3, "Identity").
    #[test]
    fn file_ids_are_not_package_ids() {
        use super::{file_id, relative_id};
        assert_eq!(file_id("@acme/x@1".into()), "./@acme/x@1");
        assert_eq!(
            file_id(format!("@acme/{}", relative_id(Path::new("/p"), Path::new("/p/x@1.schema.haus")))),
            "./@acme/x@1"
        );
        assert_eq!(file_id("shop/x".into()), "shop/x");
    }
}
