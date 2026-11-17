//! Schema packages (spec §13.3): the manifest, the rules a package's files
//! follow, and the schema packages among a Cargo crate's direct dependencies.
//!
//! A package crate's build script calls `haus_build::package()`, which tells
//! Cargo where its manifest is (`cargo::metadata=haus_package=…`). Cargo
//! passes that only to crates that depend on it directly, as
//! `DEP_<LINKS>_HAUS_PACKAGE`: no registry, no network, no transitive lookups.

use crate::files::{self, FileCache, Kind};
use crate::locator::{Location, Locator};
use crate::{Error, Result, quote, shown, syntax, var};
use haus::ErrorCode;
use std::collections::HashMap;
use std::env;
use std::path::{Path, PathBuf};

/// A schema package's manifest.
pub const MANIFEST: &str = "package.haus";
/// A schema package's one schema file, next to its manifest.
pub const SCHEMA: &str = "schema.haus";
/// The largest manifest, in bytes (64 KiB).
pub const MAX_MANIFEST: u64 = 64 * 1024;

/// `package.haus`: `{ name: "@haus-fmt/money", version: "1.2.0" }`. Other
/// fields are ignored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub name: String,
    pub version: String,
}

impl Manifest {
    /// The manifest of the package in `dir`, checked (spec §13.3): a missing
    /// one is `import-not-found`, a symbolic link or a file that isn't a
    /// regular file `package-path` (not read), and one that isn't a valid
    /// manifest `package-manifest`.
    pub fn read(dir: &Path) -> Result<Manifest> {
        Manifest::read_text(dir).map(|(manifest, _)| manifest)
    }

    /// The manifest and its text.
    pub(crate) fn read_text(dir: &Path) -> Result<(Manifest, String)> {
        files::manifest(dir, files::open(&dir.join(MANIFEST), Kind::Manifest))
    }

    /// The manifest written as `text`: one record, with a lowercase `name`
    /// `@org/name` and a semantic `version`. The error is the reason.
    pub fn parse(text: &str) -> Result<Manifest, String> {
        if text.len() as u64 > MAX_MANIFEST {
            return Err(format!("the manifest has {} bytes, more than 64 KiB", text.len()));
        }
        let values = haus::parse(text).map_err(|e| format!("the manifest is not valid haus: {e}"))?;
        let [record @ haus::Value::Record(_)] = values.as_slice() else {
            return Err("a manifest is one record: { name: \"@org/name\", version: \"1.0.0\" }".into());
        };
        let field = |key: &str| match record.get(key) {
            Some(haus::Value::String(s)) => Ok(s.clone()),
            _ => Err(format!("the manifest needs a string field {key}")),
        };
        let (name, version) = (field("name")?, field("version")?);
        if !is_package_name(&name) {
            return Err(format!(
                "\"{}\" is not a package name: @org/name in lowercase, each part starting with a letter or digit, \
                 made of a-z, 0-9, -, . and _, and not node_modules, at most {MAX_NAME} characters",
                quote(&name)
            ));
        }
        if !is_semver(&version) {
            return Err(format!("\"{}\" is not a semantic version, like 1.2.0", quote(&version)));
        }
        Ok(Manifest { name, version })
    }

    /// The package's schema file, `schema.haus` in its directory `dir`
    /// (spec §13.3). Checked, not read: a missing file is `import-not-found`,
    /// a symbolic link or a file that isn't a regular file `package-path`.
    pub fn schema_path(&self, dir: &Path) -> Result<PathBuf> {
        let path = dir.join(SCHEMA);
        match path.symlink_metadata() {
            Ok(meta) if meta.is_file() => Ok(path),
            Ok(_) => {
                let reason = format!(
                    "{}: its {SCHEMA} is a symbolic link or not a regular file; it is not read",
                    quote(&self.name)
                );
                Err(Error::new(ErrorCode::PackagePath, reason))
            }
            Err(_) => {
                let reason = format!("{} has no {SCHEMA} next to its manifest ({})", quote(&self.name), shown(dir));
                Err(Error::new(ErrorCode::ImportNotFound, reason))
            }
        }
    }

    pub fn major(&self) -> &str {
        self.version.split('.').next().unwrap_or_default()
    }

    /// `@haus-fmt/money@1`.
    pub fn id(&self) -> String {
        format!("{}@{}", self.name, self.major())
    }
}

/// The longest package name (npm's limit).
const MAX_NAME: usize = 214;

/// Whether `name` is `@org/name` (spec §13.3, `grammar.ebnf`), npm's rules
/// for scoped names in lowercase: each part starts with a lowercase letter
/// or digit, has only `a`–`z`, `0`–`9`, `-`, `.` and `_`, and is not
/// `node_modules`; the whole name has at most 214 characters.
pub fn is_package_name(name: &str) -> bool {
    let segment = |s: &str| {
        s.bytes().next().is_some_and(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
            && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"-._".contains(&b))
            && s != "node_modules"
    };
    name.len() <= MAX_NAME
        && name.strip_prefix('@').and_then(|n| n.split_once('/')).is_some_and(|(org, pkg)| segment(org) && segment(pkg))
}

/// Whether `version` is a semantic version (SemVer 2.0): `1.2.0`, `1.0.0-rc.1+build.5`.
pub(crate) fn is_semver(version: &str) -> bool {
    let number = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) && (s == "0" || !s.starts_with('0'));
    let ident = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    let (version, build) = version.split_once('+').map_or((version, None), |(v, b)| (v, Some(b)));
    let (core, pre) = version.split_once('-').map_or((version, None), |(v, p)| (v, Some(p)));
    let parts: Vec<&str> = core.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|p| number(p))
        && pre.is_none_or(|p| p.split('.').all(|i| ident(i) && (!i.bytes().all(|b| b.is_ascii_digit()) || number(i))))
        && build.is_none_or(|b| b.split('.').all(ident))
}

pub struct Package {
    pub manifest: Manifest,
    /// Its directory, with the manifest.
    pub dir: PathBuf,
    /// The Rust crate with its types: `haus_money`.
    pub krate: String,
    /// The version its package manager gives it (Cargo's package version),
    /// if known: the manifest's must be the same (`package-version`).
    pub version: Option<String>,
    /// Its types and their number of parameters.
    pub types: HashMap<String, usize>,
}

/// The schema packages among a crate's direct dependencies: a [`Locator`]
/// for build scripts. They count as declared: Cargo lets a crate use only
/// its direct dependencies.
#[derive(Default)]
pub struct Packages(Vec<Package>);

impl Packages {
    /// None: for schemas without package imports.
    pub fn none() -> Packages {
        Packages::default()
    }

    /// The direct dependencies that are schema packages.
    pub fn from_env() -> Result<Packages> {
        env::vars()
            .filter_map(|(key, dir)| Some((key.strip_prefix("DEP_")?.strip_suffix("_HAUS_PACKAGE")?.to_owned(), dir)))
            .map(|(links, dir)| {
                let package = Package::load(Path::new(&dir), var(&format!("DEP_{links}_HAUS_CRATE"))?)?;
                // Set by haus-fmt-build 0.1.1 and later.
                Ok(Package { version: env::var(format!("DEP_{links}_HAUS_VERSION")).ok(), ..package })
            })
            .collect::<Result<_>>()
            .map(Packages)
    }

    /// With the package in `dir`, whose types are in the crate `krate`.
    pub fn with(mut self, dir: &Path, krate: &str) -> Result<Packages> {
        self.0.push(Package::load(dir, krate.to_owned())?);
        Ok(self)
    }

    /// The one package called `name`.
    pub fn find(&self, name: &str) -> Result<&Package> {
        match self.0.iter().filter(|p| p.manifest.name == name).collect::<Vec<_>>().as_slice() {
            [one] => Ok(one),
            [] => Err(Error::new(
                ErrorCode::ImportNotFound,
                format!(
                    "package {name} not found among this crate's dependencies: \
                     add the crate that provides it (its build script calls haus_build::package)"
                ),
            )),
            [a, b, ..] => Err(Error::new(
                ErrorCode::DuplicatePackage,
                format!("two dependencies call themselves {name}: {} and {}", a.krate, b.krate),
            )),
        }
    }

    /// The packages.
    pub fn iter(&self) -> impl Iterator<Item = &Package> {
        self.0.iter()
    }

    /// The files read to find them: each package's manifest and schema file.
    /// A build script tells Cargo to rerun when one changes (haus-fmt-build
    /// does); this crate never prints.
    pub fn files(&self) -> Vec<PathBuf> {
        self.0.iter().flat_map(|p| [p.dir.join(MANIFEST), p.dir.join(SCHEMA)]).collect()
    }
}

impl Locator for Packages {
    fn locate_in(&self, name: &str, _from: Option<&Path>, _files: &mut FileCache) -> Result<Location> {
        self.find(name).map(|p| Location { version: p.version.clone(), ..Location::new(&p.dir) })
    }
}

impl Package {
    fn load(dir: &Path, krate: String) -> Result<Package> {
        let dir = &dir.canonicalize().map_err(|e| Error::at(dir, ErrorCode::ImportNotFound, e))?;
        let mut files = FileCache::new();
        let (manifest, _) = files.manifest(dir)?;
        let path = dir.join(SCHEMA);
        let text = files.schema(&path, Kind::PackageSchema, || {
            format!("{} has no {SCHEMA} next to its manifest ({})", manifest.name, shown(dir))
        })?;
        let file = syntax::parse(&text).map_err(|e| Error::from(e).in_file(&path))?;
        imports_no_files(&manifest, &file, &text).map_err(|e| e.in_file(&path))?;
        let types = file.types.into_iter().map(|t| (t.name, t.params.len())).collect();
        Ok(Package { manifest, dir: dir.to_owned(), krate, version: None, types })
    }
}

/// A package's schema (`text`, parsed as `file`) imports standard modules and
/// packages, never files (spec §13.3): a relative import is `package-path`.
pub fn imports_no_files(manifest: &Manifest, file: &syntax::File, text: &str) -> Result<()> {
    match file.imports.iter().find(|imp| imp.module.starts_with('.')) {
        Some(imp) => {
            let reason = format!(
                "can't import {}: the schema of {} can't import files, only packages by name",
                imp.module, manifest.name
            );
            Err(syntax::error(text, imp.pos, ErrorCode::PackagePath, reason).into())
        }
        None => Ok(()),
    }
}

/// The manifest of the package whose schema is the file at `path`, with
/// the package's directory, if it is one (`schema.haus` next to a manifest).
pub fn package_of(path: &Path) -> Option<(&Path, Result<Manifest>)> {
    let dir = path.parent().filter(|_| files::is_package_schema(path))?;
    Some((dir, Manifest::read(dir)))
}

/// The package directory a file is in: the nearest directory above it with a manifest.
pub fn package_dir_of(path: &Path) -> Option<&Path> {
    path.ancestors().skip(1).find(|d| d.join(MANIFEST).symlink_metadata().is_ok())
}

/// Whether the packages in `a` and `b` are copies of one package: their
/// manifests and schema files are the same, byte for byte (spec §13.3), and
/// regular files.
pub(crate) fn same_files(a: &Path, b: &Path) -> bool {
    let read = |dir: &Path| -> Option<Vec<std::rc::Rc<[u8]>>> {
        [(MANIFEST, Kind::Manifest), (SCHEMA, Kind::PackageSchema)]
            .iter()
            .map(|&(file, kind)| match files::open(&dir.join(file), kind) {
                files::Opened::Read(bytes) => Some(bytes),
                _ => None,
            })
            .collect()
    };
    read(a).is_some_and(|a| read(b) == Some(a))
}
