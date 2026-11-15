//! Schema packages among a crate's direct dependencies (spec §13.3).
//!
//! A package crate's build script calls `haus_build::package()`, which tells
//! Cargo where its manifest is (`cargo::metadata=haus_package=…`). Cargo
//! passes that only to crates that depend on it directly, as
//! `DEP_<LINKS>_HAUS_PACKAGE`: no registry, no network, no transitive lookups.

use crate::{Error, Result, read, syntax, var};
use haus::ErrorCode;
use std::collections::HashMap;
use std::env;
use std::path::{Path, PathBuf};

/// A schema package's manifest.
pub const MANIFEST: &str = "package.haus";
/// A schema package's one schema file, next to its manifest.
pub const SCHEMA: &str = "schema.haus";

/// `package.haus`: `{ name: "@haus-fmt/money", version: "1.2.0" }`. Other
/// fields are ignored.
pub struct Manifest {
    pub name: String,
    pub version: String,
}

impl Manifest {
    pub fn read(dir: &Path) -> Result<Manifest> {
        let path = dir.join(MANIFEST);
        check_inside(dir, &path, || format!("the manifest {}", path.display()))?;
        let value = haus::parse(&read(&path)?)
            .map_err(|e| Error::at(&path, ErrorCode::ImportNotFound, e))?
            .into_iter()
            .next()
            .ok_or_else(|| Error::at(&path, ErrorCode::ImportNotFound, "empty manifest"))?;
        let field = |key: &str| match value.get(key) {
            Some(haus::Value::String(s)) => Ok(s.clone()),
            _ => Err(Error::at(&path, ErrorCode::ImportNotFound, format!("the manifest needs a string field {key}"))),
        };
        Ok(Manifest { name: field("name")?, version: field("version")? })
    }

    /// The package's schema file, `schema.haus` in its directory `dir`
    /// (spec §13.3). Checked, not read: a missing file is `import-not-found`,
    /// a symbolic link to a file outside the package `package-path`.
    pub fn schema_path(&self, dir: &Path) -> Result<PathBuf> {
        let path = dir.join(SCHEMA);
        if !path.is_file() {
            let reason = format!("{} has no {SCHEMA} next to its manifest ({})", self.name, dir.display());
            return Err(Error::new(ErrorCode::ImportNotFound, reason));
        }
        check_inside(dir, &path, || format!("{}: its {SCHEMA}", self.name))?;
        Ok(path)
    }

    pub fn major(&self) -> &str {
        self.version.split('.').next().unwrap_or_default()
    }

    /// `@haus-fmt/money@1`.
    pub fn id(&self) -> String {
        format!("{}@{}", self.name, self.major())
    }
}

pub struct Package {
    pub manifest: Manifest,
    /// Its directory, with the manifest.
    pub dir: PathBuf,
    /// The Rust crate with its types: `haus_money`.
    pub krate: String,
    /// Its types and their number of parameters.
    pub types: HashMap<String, usize>,
}

/// The schema packages among a crate's direct dependencies.
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
            .map(|(links, dir)| Package::load(Path::new(&dir), var(&format!("DEP_{links}_HAUS_CRATE"))?))
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

impl Package {
    fn load(dir: &Path, krate: String) -> Result<Package> {
        let manifest = Manifest::read(dir)?;
        let path = manifest.schema_path(dir)?;
        let text = read(&path)?;
        let file = syntax::parse(&text).map_err(|e| Error::from(e).in_file(&path))?;
        imports_no_files(&manifest, &file, &text).map_err(|e| e.in_file(&path))?;
        let types = file.types.into_iter().map(|t| (t.name, t.params.len())).collect();
        Ok(Package { manifest, dir: dir.to_owned(), krate, types })
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
    let dir = path.parent().filter(|d| path.file_name() == Some(SCHEMA.as_ref()) && d.join(MANIFEST).is_file())?;
    Some((dir, Manifest::read(dir)))
}

/// The package directory a file is in: the nearest directory above it with a manifest.
pub fn package_dir_of(path: &Path) -> Option<&Path> {
    path.ancestors().skip(1).find(|d| d.join(MANIFEST).is_file())
}

/// A file read for a package stays inside it (spec §13.3): `path`, in the
/// package directory `root`, is still inside it after resolving symbolic
/// links. Checked before the file is read; `what` says which file it is. The
/// error (`package-path`) never quotes the file.
pub fn check_inside(root: &Path, path: &Path, what: impl FnOnce() -> String) -> Result<()> {
    let real = |p: &Path| p.canonicalize().ok();
    let escapes = path.exists()
        && match (real(root), real(path)) {
            (Some(root), Some(path)) => !path.starts_with(root),
            _ => true,
        };
    match escapes {
        true => Err(Error::new(
            ErrorCode::PackagePath,
            format!("{} is a symbolic link to a file outside the package {}", what(), root.display()),
        )),
        false => Ok(()),
    }
}
