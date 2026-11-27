//! Schema packages (spec §13.3): the manifest, the rules a package's files
//! follow, and the schema packages among a Cargo crate's direct dependencies.
//!
//! A package crate's build script calls `haus_build::package()`, which tells
//! Cargo where its manifest is (`cargo::metadata=haus_package=…`). Cargo
//! passes that only to crates that depend on it directly, as
//! `DEP_<LINKS>_HAUS_PACKAGE`: no registry, no network.
//!
//! A package crate also passes on the packages its schema reaches, directly
//! or not (`cargo::metadata=haus_graph=<file>`, [`GRAPH`]): the crates that
//! depend on it then see the packages their dependencies import, for
//! checking and for the codec closure (spec §13.4), and name their crates
//! through its re-exports ([`DEPS_MODULE`]). Only packages' files import
//! them: a crate's own files import its direct dependencies.

use crate::files::{self, FileCache, Kind};
use crate::locator::{Location, Locator};
use crate::{Error, Result, quote, shown, syntax, var};
use haus::ErrorCode;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::{env, fs};

/// A schema package's manifest.
pub const MANIFEST: &str = "package.haus";
/// A schema package's one schema file, next to its manifest.
pub const SCHEMA: &str = "schema.haus";
/// The largest manifest, in bytes (64 KiB).
pub const MAX_MANIFEST: u64 = 64 * 1024;
/// The file in a package crate's `OUT_DIR` that lists the packages its
/// schema reaches, other than itself: `[{ name, dir, krate, version }]`,
/// `krate` being the path of the package's crate from this one
/// (`haus_money`, `haus_ledger::__haus_deps::haus_money`).
pub const GRAPH: &str = "haus_graph.haus";
/// The module of a package crate that re-exports the crates of the schema
/// packages it depends on, for the code generated in crates that depend on
/// it: `::haus_orders::__haus_deps::haus_money::Money`.
pub const DEPS_MODULE: &str = "__haus_deps";

/// `package.haus`: `{ name: "@haus-fmt/money", version: "1.2.0", rules: {
/// "Currency": "iso" } }`. Other fields are ignored (packages.md §4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub name: String,
    pub version: String,
    /// The `rules` field as written, if there is one: which of the
    /// package's types have a rule (packages.md §4). It is checked when a
    /// schema that reaches the package is compiled ([`Manifest::rules`]),
    /// since its types need the package's schema; a broken one doesn't make
    /// the manifest invalid.
    pub rules: Option<haus::Value>,
}

/// A rule's name: `[a-z][a-z0-9-]*` (packages.md §4).
pub fn is_rule_name(name: &str) -> bool {
    name.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

impl Manifest {
    /// The manifest of the package in `dir`, checked (spec §13.3): a missing
    /// one is `import-not-found`, a symbolic link or a file that isn't a
    /// regular file `package-path` (not read), and one that isn't a valid
    /// manifest `package-manifest`.
    pub fn read(dir: &Path) -> Result<Manifest> {
        Manifest::read_as(dir, &shown(dir))
    }

    /// [`Manifest::read`], with the directory shown as `shown` in messages.
    pub(crate) fn read_as(dir: &Path, shown: &str) -> Result<Manifest> {
        let opened = files::open(&dir.join(MANIFEST), Kind::Manifest);
        files::manifest(dir, shown, opened).map(|(manifest, _)| manifest)
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
            Some(haus::Value::String(s)) => Ok(s.to_string()),
            _ => Err(format!("the manifest needs a string field {key}")),
        };
        let rules = record.get("rules").cloned();
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
        Ok(Manifest { name, version, rules })
    }

    /// The `rules` field (packages.md §4): each type's name and its rule's
    /// name, in the order written; none without the field. Checked here: a
    /// record, each value a string, each rule's name `[a-z][a-z0-9-]*`;
    /// the error is the reason. The types are checked against the
    /// package's schema when it is compiled.
    pub fn rules(&self) -> Result<Vec<(String, String)>, String> {
        let name = quote(&self.name);
        let Some(field) = &self.rules else { return Ok(vec![]) };
        let Some(record) = field.as_record() else {
            return Err(format!(
                "the rules of {name} are not a record from type names to rule names, like rules: {{ \"Currency\": \"iso\" }}"
            ));
        };
        record
            .iter()
            .map(|(ty, rule)| match rule.as_str() {
                Some(rule) if is_rule_name(rule) => Ok((ty.clone(), rule.to_owned())),
                Some(rule) => Err(format!(
                    "the rules of {name} give {} the rule \"{}\", which is not a rule's name: [a-z][a-z0-9-]*",
                    quote(ty),
                    quote(rule)
                )),
                None => Err(format!(
                    "the rules of {name} give {} something other than one rule's name: a type has one rule, a string",
                    quote(ty)
                )),
            })
            .collect()
    }

    /// The package's schema file, `schema.haus` in its directory `dir`
    /// (spec §13.3). Checked, not read: a missing file (or one its directory
    /// doesn't list with that spelling) is `import-not-found`, a symbolic
    /// link or a file that isn't a regular file `package-path`.
    pub fn schema_path(&self, dir: &Path) -> Result<PathBuf> {
        let path = dir.join(SCHEMA);
        let listed = files::listed(dir, SCHEMA.as_ref());
        match path.symlink_metadata() {
            Ok(meta) if listed && meta.is_file() => Ok(path),
            Ok(_) if listed => {
                let reason = format!(
                    "{}: its {SCHEMA} is a symbolic link or not a regular file; it is not read",
                    quote(&self.name)
                );
                Err(Error::new(ErrorCode::PackagePath, reason))
            }
            _ => {
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

/// A schema package among a crate's dependencies (Cargo, packages.md §3).
pub struct Crate {
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
    /// For a package that is not a dependency of this crate, but of a
    /// dependency's (from its [`GRAPH`]): that dependency's crate. Only
    /// packages' files import it; `krate` is a path through that crate.
    pub through: Option<String>,
    /// The implementations of its rules its crate has (packages.md §3:
    /// "the crate's generated code carries the implementations"): each type
    /// id, and the path in the crate of a type implementing `haus::Rule`
    /// (`iso::Iso`, for `::haus_money::iso::Iso`).
    pub rules: Vec<(String, String)>,
}

/// The rules metadata of a package crate (`haus_rules`): `id=path` pairs
/// separated by `;`, each path in the crate (`iso::Iso`).
pub fn rules_metadata<'a>(rules: impl IntoIterator<Item = (&'a str, &'a str)>) -> String {
    rules.into_iter().map(|(id, path)| format!("{id}={path}")).collect::<Vec<_>>().join(";")
}

/// The rules of [`rules_metadata`] again.
fn parse_rules(text: &str) -> Vec<(String, String)> {
    text.split(';').filter_map(|pair| pair.split_once('=')).map(|(id, p)| (id.to_owned(), p.to_owned())).collect()
}

/// The schema packages among a crate's direct dependencies, and those their
/// schemas reach: a [`Locator`] for build scripts. The direct ones count as
/// declared: Cargo lets a crate use only its direct dependencies. The others
/// only packages' files import (see [`Crate::through`]).
#[derive(Default)]
pub struct Packages {
    packages: Vec<Crate>,
    /// The [`GRAPH`]s they were read from.
    graphs: Vec<PathBuf>,
}

impl Packages {
    /// None: for schemas without package imports.
    pub fn none() -> Packages {
        Packages::default()
    }

    /// The direct dependencies that are schema packages, then the packages
    /// their schemas reach (each one's [`GRAPH`]) that aren't among them.
    pub fn from_env() -> Result<Packages> {
        let mut links: Vec<(String, String)> = env::vars()
            .filter_map(|(key, dir)| Some((key.strip_prefix("DEP_")?.strip_suffix("_HAUS_PACKAGE")?.to_owned(), dir)))
            .collect();
        links.sort();
        let direct = links
            .iter()
            .map(|(links, dir)| {
                let package = Crate::load(Path::new(dir), var(&format!("DEP_{links}_HAUS_CRATE"))?)?;
                let rules = env::var(format!("DEP_{links}_HAUS_RULES")).map(|r| parse_rules(&r)).unwrap_or_default();
                // Set by haus-fmt-build 0.1.1 and later.
                Ok(Crate { version: env::var(format!("DEP_{links}_HAUS_VERSION")).ok(), rules, ..package })
            })
            .collect::<Result<Vec<_>>>()?;
        let mut packages = Packages { packages: direct, graphs: vec![] };
        for (links, _) in &links {
            // Set by haus-fmt-build 0.1.1 and later, for the packages a schema reaches.
            let Ok(graph) = env::var(format!("DEP_{links}_HAUS_GRAPH")) else { continue };
            let through = var(&format!("DEP_{links}_HAUS_CRATE"))?;
            packages.graphs.push(PathBuf::from(&graph));
            for entry in read_graph(Path::new(&graph))? {
                if packages.packages.iter().any(|p| same_dir(&p.dir, Path::new(&entry.dir))) {
                    continue;
                }
                let krate = format!("{through}::{DEPS_MODULE}::{}", entry.krate);
                packages = packages.through(Path::new(&entry.dir), &krate)?;
                if let Some(p) = packages.packages.last_mut() {
                    p.version = entry.version;
                    p.rules = entry.rules.as_deref().map(parse_rules).unwrap_or_default();
                }
            }
        }
        Ok(packages)
    }

    /// With the package in `dir`, whose types are in the crate `krate`.
    pub fn with(mut self, dir: &Path, krate: &str) -> Result<Packages> {
        self.packages.push(Crate::load(dir, krate.to_owned())?);
        Ok(self)
    }

    /// With the package in `dir`, a dependency of a dependency, whose types
    /// are at the path `krate` through that dependency's crate:
    /// `haus_orders::__haus_deps::haus_money`. Only packages' files import it.
    pub fn through(mut self, dir: &Path, krate: &str) -> Result<Packages> {
        let via = krate.split("::").next().unwrap_or(krate).to_owned();
        self.packages.push(Crate { through: Some(via), ..Crate::load(dir, krate.to_owned())? });
        Ok(self)
    }

    /// The [`GRAPH`] of a package crate whose schema reached `used` (the
    /// names of the packages, itself left out), each with the path of its
    /// crate from this crate.
    pub fn graph<'a>(&self, used: impl IntoIterator<Item = &'a str>) -> Result<String> {
        let entries = used
            .into_iter()
            .map(|name| {
                let p = self.find(name)?;
                let version = p.version.clone().unwrap_or_else(|| p.manifest.version.clone());
                let dir = p.dir.to_str().ok_or_else(|| {
                    Error::at(&p.dir, ErrorCode::ImportNotFound, "the directory of a schema package must be UTF-8")
                })?;
                let rules = rules_metadata(p.rules.iter().map(|(id, path)| (id.as_str(), path.as_str())));
                Ok(BTreeMap::from([
                    ("name".to_owned(), name.to_owned()),
                    ("dir".to_owned(), dir.to_owned()),
                    ("krate".to_owned(), p.krate.clone()),
                    ("version".to_owned(), version),
                    ("rules".to_owned(), rules),
                ]))
            })
            .collect::<Result<Vec<_>>>()?;
        haus::to_string(&entries).map_err(|e| Error::new(ErrorCode::ImportNotFound, e.to_string()))
    }

    /// The one package called `name`.
    pub fn find(&self, name: &str) -> Result<&Crate> {
        match self.packages.iter().filter(|p| p.manifest.name == name).collect::<Vec<_>>().as_slice() {
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
    pub fn iter(&self) -> impl Iterator<Item = &Crate> {
        self.packages.iter()
    }

    /// The files read to find them: each package's manifest and schema
    /// file, and the dependencies' [`GRAPH`]s. A build script tells Cargo to
    /// rerun when one changes (haus-fmt-build does); this crate never prints.
    pub fn files(&self) -> Vec<PathBuf> {
        let own = self.packages.iter().flat_map(|p| [p.dir.join(MANIFEST), p.dir.join(SCHEMA)]);
        own.chain(self.graphs.iter().cloned()).collect()
    }
}

impl Locator for Packages {
    fn locate_in(&self, name: &str, from: Option<&Path>, _files: &mut FileCache) -> Result<Location> {
        let p = self.find(name)?;
        // A package's file: its imports were checked when its crate was built.
        let in_package = from.and_then(Path::parent).is_some_and(|d| self.packages.iter().any(|p| p.dir == d));
        match &p.through {
            Some(through) if !in_package => Err(Error::new(
                ErrorCode::UndeclaredPackage,
                format!(
                    "{name} is a dependency of {through}, not of this crate: add the crate that provides it to \
                     [dependencies] to import it"
                ),
            )),
            _ => Ok(Location { version: p.version.clone(), ..Location::new(&p.dir) }),
        }
    }
}

/// An entry of a [`GRAPH`].
struct Entry {
    dir: String,
    krate: String,
    version: Option<String>,
    rules: Option<String>,
}

/// The entries of the [`GRAPH`] at `path`, which a dependency's build script wrote.
fn read_graph(path: &Path) -> Result<Vec<Entry>> {
    let text = fs::read_to_string(path).map_err(|e| Error::at(path, ErrorCode::ImportNotFound, e))?;
    let entries: Vec<BTreeMap<String, String>> =
        haus::from_str(&text).map_err(|e| Error::at(path, ErrorCode::ImportNotFound, e))?;
    entries
        .into_iter()
        .map(|mut e| {
            let mut take = |key: &str| e.remove(key);
            let (dir, krate, version, rules) = (take("dir"), take("krate"), take("version"), take("rules"));
            match (dir, krate) {
                (Some(dir), Some(krate)) => Ok(Entry { dir, krate, version, rules }),
                _ => Err(Error::at(path, ErrorCode::ImportNotFound, "an entry without its dir or krate")),
            }
        })
        .collect()
}

/// Whether `a` and `b` are the same directory.
fn same_dir(a: &Path, b: &Path) -> bool {
    a == b || b.canonicalize().is_ok_and(|b| a == b)
}

impl Crate {
    fn load(dir: &Path, krate: String) -> Result<Crate> {
        let dir = &dir.canonicalize().map_err(|e| Error::at(dir, ErrorCode::ImportNotFound, e))?;
        let mut files = FileCache::new();
        let (manifest, _) = files.manifest(dir)?;
        let path = dir.join(SCHEMA);
        let text = files.schema(&path, Kind::PackageSchema, || {
            format!("{} has no {SCHEMA} next to its manifest ({})", manifest.name, shown(dir))
        })?;
        // Its own types are all that is read here: spreads of imported types are left in place.
        let file = syntax::parse_with_imported_spreads(&text).map_err(|e| Error::from(e).in_file(&path))?;
        imports_no_files(&manifest, &file, &text).map_err(|e| e.in_file(&path))?;
        let types = file.types.into_iter().map(|t| (t.name, t.params.len())).collect();
        Ok(Crate { manifest, dir: dir.to_owned(), krate, version: None, types, through: None, rules: vec![] })
    }
}

/// A package's schema (`text`, parsed as `file`) imports standard modules and
/// packages, never files (spec §13.3): a relative import is `package-path`.
pub fn imports_no_files(manifest: &Manifest, file: &syntax::File, text: &str) -> Result<()> {
    match file.imports.iter().find(|imp| imp.module.starts_with('.')) {
        Some(imp) => {
            let reason = format!(
                "can't import {}: the schema of {} can't import files, only packages by name",
                crate::quote(&imp.module),
                crate::quote(&manifest.name)
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

/// Whether the directory `dir` has a `package.haus`: one it lists with
/// that spelling (`Package.haus` makes no package, spec §13.3, "Spelling"),
/// whatever it is (a link or a directory is rejected when it is read).
pub fn has_manifest(dir: &Path) -> bool {
    dir.join(MANIFEST).symlink_metadata().is_ok() && files::listed(dir, MANIFEST.as_ref())
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
