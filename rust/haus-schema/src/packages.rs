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

pub const MANIFEST: &str = "haus.package.haus";

/// `haus.package.haus`: `{ name: "@haus-fmt/money", version: "1.2.0", schema: "money.schema.haus" }`.
pub struct Manifest {
    pub name: String,
    pub version: String,
    pub schema: String,
}

impl Manifest {
    pub fn read(dir: &Path) -> Result<Manifest> {
        let path = dir.join(MANIFEST);
        let value = haus::parse(&read(&path)?)
            .map_err(|e| Error::at(&path, ErrorCode::ImportNotFound, e))?
            .into_iter()
            .next()
            .ok_or_else(|| Error::at(&path, ErrorCode::ImportNotFound, "empty manifest"))?;
        let field = |key: &str| match value.get(key) {
            Some(haus::Value::String(s)) => Ok(s.clone()),
            _ => Err(Error::at(&path, ErrorCode::ImportNotFound, format!("the manifest needs a string field {key}"))),
        };
        Ok(Manifest { name: field("name")?, version: field("version")?, schema: field("schema")? })
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
        self.0.iter().flat_map(|p| [p.dir.join(MANIFEST), p.dir.join(&p.manifest.schema)]).collect()
    }
}

impl Package {
    fn load(dir: &Path, krate: String) -> Result<Package> {
        let manifest = Manifest::read(dir)?;
        let path = dir.join(&manifest.schema);
        let file = syntax::parse(&read(&path)?).map_err(|e| Error::from(e).in_file(&path))?;
        let types = file.types.into_iter().map(|t| (t.name, t.params.len())).collect();
        Ok(Package { manifest, dir: dir.to_owned(), krate, types })
    }
}
