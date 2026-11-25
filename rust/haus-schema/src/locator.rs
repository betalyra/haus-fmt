//! Where packages are (spec §13.3). A [`Locator`] knows one place packages
//! come from: it finds the directory of the package an import names, and
//! says whether the importing file declares it. Everything else is the same
//! for every package manager and is checked when a schema is loaded: the
//! manifest, its name and version, the `@major` of the import, containment,
//! one package per name, cycles and ids.
//!
//! - [`Explicit`]: package directories given by the user (a command line's
//!   `--package`, a generator's list);
//! - [`Packages`](crate::Packages): a Cargo crate's direct dependencies;
//! - [`NoImports`], which finds none.
//!
//! [`Locator::or`] combines two: `Explicit::new().package(dir)?.or(Packages::from_env()?)`.
//!
//! This binding is no implementation of the npm ecosystem: it never looks
//! in `node_modules` (spec §13.3, "Installed packages"). Give the packages
//! a schema imports explicitly, or take them from Cargo.

use crate::files::FileCache;
use crate::packages::{Manifest, has_manifest, same_files};
use crate::{Error, Result, quote, shown};
use haus::ErrorCode;
use haus::json::Json;
use std::fs;
use std::path::{Path, PathBuf};

/// The most entries a folder of packages may have ([`Explicit::folder`]).
pub const MAX_FOLDER_ENTRIES: usize = 4096;

/// Finds the packages imports name, for one package manager.
pub trait Locator {
    /// The package called `name` (`@org/name`, without `@major`), imported by
    /// the file at `from`: its real path, or None for a schema given as text.
    /// A package that isn't there is an `import-not-found` error that says
    /// where it was looked for; [`Locator::or`] then tries the next locator.
    fn locate(&self, name: &str, from: Option<&Path>) -> Result<Location> {
        self.locate_in(name, from, &mut FileCache::new())
    }

    /// [`Locator::locate`], reading files through `files`: the files one
    /// schema reads, each once.
    fn locate_in(&self, name: &str, from: Option<&Path>, files: &mut FileCache) -> Result<Location>;

    /// This locator, then `other` for the packages this one doesn't find.
    /// A package this one found by scanning a folder ([`Location::scanned`])
    /// doesn't replace one `other` finds: their files must be the same.
    fn or<L: Locator>(self, other: L) -> Or<Self, L>
    where
        Self: Sized,
    {
        Or(self, other)
    }
}

/// A package directory a [`Locator`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Location {
    /// The directory, with `package.haus` and `schema.haus`.
    pub dir: PathBuf,
    /// The version the package manager gives the package (the `version` of
    /// a `package.json` beside a package given explicitly, Cargo's package
    /// version), if it gives one: the manifest's must be the same
    /// (`package-version`).
    pub version: Option<String>,
    /// Found by scanning a folder of packages: it doesn't replace a package
    /// the next locator of [`Locator::or`] finds.
    pub scanned: bool,
    /// A package with the same name found by scanning a folder: its
    /// `package.haus` and `schema.haus` must be the same as this one's, or
    /// the schema has two packages with one name (`duplicate-package`).
    pub same_as: Option<PathBuf>,
}

impl Location {
    /// The package in `dir`, without a version from a package manager.
    pub fn new(dir: impl Into<PathBuf>) -> Location {
        Location { dir: dir.into(), version: None, scanned: false, same_as: None }
    }
}

/// No packages: only std modules and files can be imported.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoImports;

impl Locator for NoImports {
    fn locate_in(&self, _name: &str, _from: Option<&Path>, _files: &mut FileCache) -> Result<Location> {
        Err(Error::new(
            ErrorCode::ImportUnavailable,
            "no package locator (only std modules and files can be imported here)",
        ))
    }
}

/// [`Locator::or`]: the first locator, then the second.
#[derive(Debug, Clone, Copy, Default)]
pub struct Or<A, B>(A, B);

impl<A: Locator, B: Locator> Locator for Or<A, B> {
    fn locate_in(&self, name: &str, from: Option<&Path>, files: &mut FileCache) -> Result<Location> {
        match self.0.locate_in(name, from, files) {
            Err(first) if first.code() == Some(ErrorCode::ImportNotFound) => {
                match self.1.locate_in(name, from, files) {
                    Err(second) if second.code() == Some(ErrorCode::ImportNotFound) => {
                        Err(Error::new(ErrorCode::ImportNotFound, format!("{}; {}", first.reason(), second.reason())))
                    }
                    second => second,
                }
            }
            // A package found in a folder: the other locator's comes first, if it has the same files.
            Ok(scanned) if scanned.scanned => match self.1.locate_in(name, from, files) {
                Ok(found) => Ok(Location { same_as: Some(scanned.dir), ..found }),
                Err(e) if matches!(e.code(), Some(ErrorCode::ImportNotFound | ErrorCode::UndeclaredPackage)) => {
                    Ok(scanned)
                }
                Err(e) => Err(e),
            },
            found => found,
        }
    }
}

impl<L: Locator + ?Sized> Locator for &L {
    fn locate_in(&self, name: &str, from: Option<&Path>, files: &mut FileCache) -> Result<Location> {
        (**self).locate_in(name, from, files)
    }
}

/// Packages given explicitly: each by its directory ([`Explicit::package`]),
/// or the packages in a folder ([`Explicit::folder`]). Their manifests name
/// them, whatever the directories are called. They count as declared
/// wherever they are imported. A package given by its directory comes
/// before other locators for its name ([`Locator::or`]); one found in a
/// folder doesn't: if the next locator finds a package with its name and
/// other files, the schema has two packages with one name.
///
/// A `package.json` beside a package given explicitly is read leniently,
/// only for its `version`: one that can't be read (a symbolic link, not a
/// regular file, too large, not JSON) is ignored (spec §13.3, "Package
/// versions").
///
/// ```no_run
/// use haus_schema::{Explicit, Locator, Schema};
/// # fn main() -> Result<(), haus_schema::Error> {
/// let packages = Explicit::new().package("../../extensions/money")?.folder("schemas")?;
/// let schema = Schema::load("order.schema.haus", &packages)?;
/// # Ok(()) }
/// ```
#[derive(Debug, Clone, Default)]
pub struct Explicit {
    packages: Vec<Given>,
    /// Subdirectories of folders whose manifest couldn't be read, by the
    /// folder's last name and their own (`schemas/broken`), with why: named
    /// when an import isn't found.
    unreadable: Vec<(String, Error)>,
}

#[derive(Debug, Clone)]
struct Given {
    manifest: Manifest,
    /// Its real path.
    dir: PathBuf,
    /// Found by scanning a folder.
    scanned: bool,
}

impl Explicit {
    pub fn new() -> Explicit {
        Explicit::default()
    }

    /// With the package in `dir`. Its manifest is read and checked now: a
    /// directory without one is `import-not-found`. Two packages with one
    /// name are `duplicate-package`, unless they are copies (the same
    /// `package.haus` and `schema.haus`).
    pub fn package(self, dir: impl AsRef<Path>) -> Result<Explicit> {
        let dir = dir.as_ref();
        let real = dir.canonicalize().map_err(|e| Error::at(dir, ErrorCode::ImportNotFound, e))?;
        let manifest = Manifest::read(&real)?;
        self.add(manifest, real, false)
    }

    /// With the packages in `folder`: its subdirectories (or links to
    /// directories) that have a `package.haus`, not deeper. A folder that
    /// can't be read is `import-not-found`, one with more than 4096 entries
    /// `too-many-files`. A subdirectory whose manifest is invalid, or whose
    /// `package.json` gives another version, is left out; an import that
    /// isn't found names it, by the last name of the folder's real path and
    /// its own (`./schemas/` and a link to `schemas` are both `schemas`,
    /// spec §13.3).
    pub fn folder(mut self, folder: impl AsRef<Path>) -> Result<Explicit> {
        let given = folder.as_ref();
        let folder = &given.canonicalize().map_err(|e| Error::at(given, ErrorCode::ImportNotFound, e))?;
        let entries = fs::read_dir(folder).map_err(|e| Error::at(folder, ErrorCode::ImportNotFound, e))?;
        let mut dirs = vec![];
        for (i, entry) in entries.enumerate() {
            if i >= MAX_FOLDER_ENTRIES {
                let reason = format!("the folder of packages has more than {MAX_FOLDER_ENTRIES} entries");
                return Err(Error::at(folder, ErrorCode::TooManyFiles, reason));
            }
            let path = entry.map_err(|e| Error::at(folder, ErrorCode::ImportNotFound, e))?.path();
            if has_manifest(&path) {
                dirs.push(path);
            }
        }
        dirs.sort();
        let last = |path: &Path| path.file_name().map(PathBuf::from).unwrap_or_default();
        for dir in dirs {
            let named = shown(&last(folder).join(last(&dir)));
            let read = dir.canonicalize().map_err(|e| Error::at(&dir, ErrorCode::ImportNotFound, e));
            match read.and_then(|real| Ok((Manifest::read_as(&real, &named)?, real))) {
                Ok((manifest, real)) => match explicit_version(&real, &mut FileCache::new()) {
                    // Skipped as one with an invalid manifest is (spec §13.3).
                    Some(version) if version != manifest.version => {
                        let (says, theirs) = (quote(&manifest.version), quote(&version));
                        let reason = format!("its package.haus says version {says}, its package.json {theirs}");
                        self.unreadable.push((named, Error::new(ErrorCode::PackageVersion, reason)));
                    }
                    _ => self = self.add(manifest, real, true)?,
                },
                Err(e) => self.unreadable.push((named, e)),
            }
        }
        Ok(self)
    }

    fn add(mut self, manifest: Manifest, dir: PathBuf, scanned: bool) -> Result<Explicit> {
        match self.packages.iter_mut().find(|g| g.manifest.name == manifest.name) {
            Some(given) if given.dir == dir || same_files(&given.dir, &dir) => given.scanned &= scanned,
            Some(given) => {
                return Err(duplicate((&given.manifest, &shown(&given.dir)), (&manifest, &shown(&dir))));
            }
            None => self.packages.push(Given { manifest, dir, scanned }),
        }
        Ok(self)
    }
}

impl Locator for Explicit {
    fn locate_in(&self, name: &str, _from: Option<&Path>, files: &mut FileCache) -> Result<Location> {
        if let Some(given) = self.packages.iter().find(|g| g.manifest.name == name) {
            let version = explicit_version(&given.dir, files);
            return Ok(Location { version, scanned: given.scanned, ..Location::new(&given.dir) });
        }
        let mut reason = format!("package {name} is not among the packages given");
        if !self.unreadable.is_empty() {
            let dirs: Vec<String> = self.unreadable.iter().map(|(dir, e)| format!("{dir} ({})", e.reason())).collect();
            reason += &format!(" (packages in the folders given that could not be read: {})", dirs.join(", "));
        }
        Err(Error::new(ErrorCode::ImportNotFound, reason))
    }
}

/// `duplicate-package`: two packages with one name, with their directories as shown.
pub(crate) fn duplicate((a, a_dir): (&Manifest, &str), (b, b_dir): (&Manifest, &str)) -> Error {
    let (name, va, vb) = (quote(&a.name), quote(&a.version), quote(&b.version));
    let copies = match a.version == b.version {
        true => format!(" (two copies of {va} whose files or imports differ)"),
        false => String::new(),
    };
    let reason = format!("two packages are called {name}: {va} in {a_dir} and {vb} in {b_dir}{copies}");
    Error::new(ErrorCode::DuplicatePackage, reason)
}

/// The version of the `package.json` beside a package given explicitly
/// (in the directory `dir`). It only gives a version: one that can't be
/// read (a symbolic link or not a regular file, too large, not JSON) is
/// ignored (spec §13.3, "Package versions").
fn explicit_version(dir: &Path, files: &mut FileCache) -> Option<String> {
    let json = files.package_json(&dir.join("package.json")).ok().flatten()?;
    match member(&json, "version") {
        Some(Json::String(v)) => Some(v.clone()),
        _ => None,
    }
}

/// The member `key` of a JSON object: the last one, as `JSON.parse` keeps.
fn member<'a>(json: &'a Json, key: &str) -> Option<&'a Json> {
    match json {
        Json::Object(members) => members.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
        _ => None,
    }
}
