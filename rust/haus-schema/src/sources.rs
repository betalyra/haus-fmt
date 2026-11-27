//! Reading apart from compiling (packages.md §2, "Reading is separate from
//! compiling"; §3): a schema's files and the packages it is given are
//! values, read from the file system or made from data the program has from
//! anywhere, and a compile takes values only and reads no file.
//!
//! ```
//! use haus_schema::{Package, Schema, Sources};
//!
//! let codes = Package::make(
//!     r#"{ name: "@acme/codes", version: "1.0.0" }"#,
//!     "type Code = < >",
//! )?;
//! let sources = Sources::make("order.schema.haus", [
//!     ("order.schema.haus", "import @acme/codes@1 (Code)\nimport ./common (Id)\ntype Order = { id: Id, code: Code }"),
//!     ("common.schema.haus", "type Id = Int"),
//! ])?
//! .with_package(codes)?;
//! let schema = Schema::compile(&sources)?;
//! let order = haus::parse_one("{ id: 1, code: EUR }").unwrap();
//! assert!(schema.decode("Order", &order).is_ok());
//! # Ok::<(), haus_schema::Error>(())
//! ```

use crate::files::{self, FileCache, Kind};
use crate::locator::Explicit;
use crate::packages::{Manifest, SCHEMA};
use crate::resolve::{Options, PackageRule, Schema};
use crate::{Error, Result, quote, shown, syntax};
use haus::ErrorCode as Code;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

/// A schema package as a value (packages.md §3): its manifest and its
/// schema text, checked as a package read from a directory is, and the
/// program's choices for it: the implementations of its rules it supplies
/// ([`Package::with_rule`]), or that it takes it shape-only
/// ([`Package::shape_only`]).
#[derive(Debug, Clone)]
pub struct Package {
    manifest: Manifest,
    pub(crate) text: Arc<PackageText>,
    /// Its directory's real path, if it was read from one.
    dir: Option<PathBuf>,
    rules: Vec<PackageRule>,
    shape_only: bool,
}

/// The texts of a package, as a compile takes them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageText {
    pub manifest: String,
    pub schema: String,
    /// The documents of its rules it has (`rules/<name>.md`, by name), noted
    /// when it was read from a directory; None for a package made from data,
    /// which isn't checked for them (packages.md §3).
    pub documents: Option<BTreeSet<String>>,
}

impl Package {
    /// A package made from plain data (packages.md §3): a manifest text and
    /// a schema text, checked as a package's files are, except for what
    /// concerns files: the manifest (`package-manifest`, at most 64 KiB) and
    /// the schema's size (`file-too-large`, at most 1 MiB). Its `rules`
    /// field and its imports are checked when a schema that reaches it is
    /// compiled.
    pub fn make(manifest: &str, schema: &str) -> Result<Package> {
        let parsed = Manifest::parse(manifest).map_err(|reason| Error::new(Code::PackageManifest, reason))?;
        if schema.len() as u64 > files::MAX_FILE {
            let reason = format!("the schema of {} has {} bytes, more than 1 MiB", quote(&parsed.name), schema.len());
            return Err(Error::new(Code::FileTooLarge, reason));
        }
        let text = PackageText { manifest: manifest.to_owned(), schema: schema.to_owned(), documents: None };
        Ok(Package { manifest: parsed, text: Arc::new(text), dir: None, rules: vec![], shape_only: false })
    }

    /// The package in the directory `dir`, read (packages.md §2): its
    /// `package.haus` and `schema.haus` as regular files, spelled exactly
    /// (`import-not-found`, `package-path`, `package-manifest`,
    /// `file-too-large`), the `version` of a `package.json` beside them
    /// (`package-version`, read leniently), and which documents of its rules
    /// it has (`rules/<name>.md`, looked at, not read).
    pub fn read(dir: impl AsRef<Path>) -> Result<Package> {
        let dir = dir.as_ref();
        let real = dir.canonicalize().map_err(|e| Error::at(dir, Code::ImportNotFound, e))?;
        let mut cache = FileCache::new();
        let (manifest, manifest_text) = cache.manifest(&real)?;
        if let Some(version) = crate::locator::explicit_version(&real, &mut cache)
            && version != manifest.version
        {
            let reason = format!(
                "the package.haus of {} says version {}, its package.json {} ({})",
                quote(&manifest.name),
                quote(&manifest.version),
                quote(&version),
                shown(dir)
            );
            return Err(Error::new(Code::PackageVersion, reason));
        }
        let path = real.join(SCHEMA);
        let schema = cache.schema(&path, Kind::PackageSchema, || {
            format!("{} has no {SCHEMA} next to its manifest ({})", quote(&manifest.name), shown(dir))
        })?;
        let documents = manifest
            .rules()
            .unwrap_or_default()
            .into_iter()
            .map(|(_, rule)| rule)
            .filter(|rule| files::rule_document(&real, rule))
            .collect();
        let text = PackageText { manifest: manifest_text, schema, documents: Some(documents) };
        Ok(Package { manifest, text: Arc::new(text), dir: Some(real), rules: vec![], shape_only: false })
    }

    /// Its manifest.
    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// Its name: `@acme/codes`.
    pub fn name(&self) -> &str {
        &self.manifest.name
    }

    /// Its directory, if it was read from one.
    pub fn dir(&self) -> Option<&Path> {
        self.dir.as_deref()
    }

    /// The same package, with the program's implementation `R` of one of
    /// its rules (packages.md §7, "Supplying a rule"): decoding checks it on
    /// every value of its type. A rule for a type the package's `rules`
    /// field gives none is a mistake of the program's, reported when the
    /// schema is compiled.
    pub fn with_rule<R: haus::Rule>(self) -> Package {
        self.with(PackageRule::of::<R>())
    }

    /// [`Package::with_rule`], with the rule as a value.
    pub fn with(mut self, rule: PackageRule) -> Package {
        self.rules.push(rule);
        self
    }

    /// The same package, taken shape-only (packages.md §7): the rules of its
    /// types are not checked, their values are checked for their shape
    /// only, and `missing-codec` is not reported for them.
    pub fn shape_only(self) -> Package {
        Package { shape_only: true, ..self }
    }

    /// Whether it is taken shape-only.
    pub fn is_shape_only(&self) -> bool {
        self.shape_only
    }

    /// The implementations of its rules the program supplies.
    pub fn rules(&self) -> &[PackageRule] {
        &self.rules
    }

    /// The directory it is known by in a compile: its real one, or a name
    /// of its own for one made from data.
    pub(crate) fn place(&self) -> PathBuf {
        self.dir.clone().unwrap_or_else(|| PathBuf::from(format!("<{}>", self.manifest.name)))
    }

    /// Whether two packages are copies of one: the same manifest and schema
    /// texts, byte for byte (core §13.3).
    pub(crate) fn same_as(&self, other: &Package) -> bool {
        self.text.manifest == other.text.manifest && self.text.schema == other.text.schema
    }
}

/// The packages of the folder `folder` (packages.md §2): its
/// subdirectories that have a `package.haus`, each read as
/// [`Package::read`] reads it. One that can't be read, or whose
/// `package.json` gives another version, is left out, and named (by the
/// folder's last name and its own, `schemas/broken`) with why.
pub fn read_folder(folder: impl AsRef<Path>) -> Result<Folder> {
    let (packages, skipped) = Explicit::new().folder(folder)?.read_values();
    Ok(Folder { packages, skipped })
}

/// The packages of a folder ([`read_folder`]).
#[derive(Debug, Clone)]
pub struct Folder {
    /// The packages read.
    pub packages: Vec<Package>,
    /// Those left out, each named (`schemas/broken`) with why.
    pub skipped: Vec<(String, Error)>,
}

/// The files of a schema (the entry file and the files its relative imports
/// reach, directly or not) and the packages given to it, as values: what
/// [`Schema::compile`] takes.
#[derive(Debug, Clone)]
pub struct Sources {
    /// The entry file's path: its real path, or a path under `/` for files made from data.
    pub(crate) entry: PathBuf,
    /// The build's root: relative imports stay inside it.
    pub(crate) root: PathBuf,
    pub(crate) files: BTreeMap<PathBuf, String>,
    pub(crate) packages: Explicit,
}

impl Sources {
    /// Files made from data (packages.md §2): `files` by their paths,
    /// relative to the build's root and `/`-separated (`order.schema.haus`,
    /// `billing/common.schema.haus`), the entry file among them. Their
    /// relative imports resolve among them, staying inside the root.
    pub fn make<P: AsRef<str>, T: Into<String>>(
        entry: &str,
        files: impl IntoIterator<Item = (P, T)>,
    ) -> Result<Sources> {
        let root = PathBuf::from("/");
        let at = |p: &str| -> Result<PathBuf> {
            normal(&root, p).ok_or_else(|| {
                Error::new(Code::ImportOutsideRoot, format!("{} is not a path inside the root", quote(p)))
            })
        };
        let files = files
            .into_iter()
            .map(|(p, text)| {
                let text = text.into();
                match text.len() as u64 > files::MAX_FILE {
                    true => Err(Error::new(
                        Code::FileTooLarge,
                        format!("{} has {} bytes, more than 1 MiB", quote(p.as_ref()), text.len()),
                    )),
                    false => Ok((at(p.as_ref())?, text)),
                }
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        let entry = at(entry)?;
        if !files.contains_key(&entry) {
            return Err(Error::new(Code::ImportNotFound, format!("file not found: {}", shown(&entry))));
        }
        Ok(Sources { entry, root, files, packages: Explicit::new() })
    }

    /// The schema file at `path` and the files its relative imports reach,
    /// read by the rules of core §13.3: inside the build's root (the
    /// directory of the file's real path), each name spelled as its
    /// directory lists it, no symbolic link followed, regular files within
    /// their limit, none in a package's directory. Packages it imports are
    /// not read here: give them with [`Sources::with_package`].
    pub fn read(path: impl AsRef<Path>) -> Result<Sources> {
        Sources::read_with_root(path, None)
    }

    /// [`Sources::read`], with the build's root `root` (core §13.3, "The
    /// root"), relative to the directory of the file's real path.
    pub fn read_with_root(path: impl AsRef<Path>, root: Option<&Path>) -> Result<Sources> {
        let path = path.as_ref();
        let mut cache = FileCache::new();
        let (entry, text) = files::root(path, &mut cache)?;
        let root = files::build_root(&entry, root)?;
        cache.set_root(root.clone());
        let mut files = BTreeMap::from([(entry.clone(), text)]);
        let mut todo = vec![entry.clone()];
        while let Some(from) = todo.pop() {
            let text = files[&from].clone();
            let shown_from = cache.shown(&from);
            let file = syntax::parse_with_imported_spreads(&text)
                .map_err(|e| Error::from(e).in_file(Path::new(&shown_from)))?;
            for import in file.imports.iter().filter(|i| i.module.starts_with("./") || i.module.starts_with("../")) {
                let at = |e: Error| {
                    let reason = format!("can't import {}: {}", import.module, e.reason());
                    let code = e.code().unwrap_or(Code::ImportNotFound);
                    Error::from(syntax::error(&text, import.pos, code, reason)).in_file(Path::new(&shown_from))
                };
                let source = files::file(&import.module, Some(&from), None, &mut cache).map_err(at)?;
                if files.len() >= crate::resolve::MAX_FILES {
                    let reason = format!("more than {} schema files are imported", crate::resolve::MAX_FILES);
                    return Err(Error::new(Code::TooManyFiles, reason));
                }
                if let std::collections::btree_map::Entry::Vacant(entry) = files.entry(source.path) {
                    todo.push(entry.key().clone());
                    entry.insert(source.text);
                }
            }
        }
        Ok(Sources { entry, root, files, packages: Explicit::new() })
    }

    /// The same sources, with the package `package` given to the build: two
    /// packages with one name are `duplicate-package`, unless they are copies.
    pub fn with_package(mut self, package: Package) -> Result<Sources> {
        self.packages = self.packages.value(package)?;
        Ok(self)
    }

    /// The same sources, with each of `packages`.
    pub fn with_packages(self, packages: impl IntoIterator<Item = Package>) -> Result<Sources> {
        packages.into_iter().try_fold(self, Sources::with_package)
    }

    /// The entry file's path.
    pub fn entry(&self) -> &Path {
        &self.entry
    }

    /// The files, by path, the entry file among them.
    pub fn files(&self) -> &BTreeMap<PathBuf, String> {
        &self.files
    }

    /// The text of the file a relative import `module` of the file at `from`
    /// names, compiled without reading files: resolved on the paths, inside
    /// the root (`import-outside-root`), or `import-not-found`.
    pub(crate) fn file(&self, module: &str, from: &Path) -> Result<(PathBuf, String)> {
        let dir = from.parent().unwrap_or(&self.root);
        let path = normal(dir, &format!("{module}{}", files::EXTENSION))
            .filter(|p| p.starts_with(&self.root))
            .ok_or_else(|| {
                let reason = "its .. names go above the build's root; nothing there is looked at";
                Error::new(Code::ImportOutsideRoot, reason)
            })?;
        match self.files.get(&path) {
            Some(text) => Ok((path, text.clone())),
            None => Err(Error::new(
                Code::ImportNotFound,
                format!("file not found: {}", shown(&files::relative(&self.root, &path))),
            )),
        }
    }
}

/// `relative` joined to `dir` without touching the file system: `.` names
/// left out, each `..` taking the name before it away; None if it goes above
/// the first name of `dir` or is absolute.
fn normal(dir: &Path, relative: &str) -> Option<PathBuf> {
    let mut out: Vec<Component> = dir.components().collect();
    let base = out.iter().take_while(|c| matches!(c, Component::RootDir | Component::Prefix(_))).count();
    for name in relative.split('/') {
        match name {
            "" | "." => {}
            ".." if out.len() > base => {
                out.pop();
            }
            ".." => return None,
            name if Path::new(name).components().count() == 1 => out.push(Component::Normal(name.as_ref())),
            _ => return None,
        }
    }
    Some(out.into_iter().collect())
}

impl Schema {
    /// Compile `sources` (packages.md §2): their entry file, the files it
    /// imports and the packages given, all values, reading no file. Every
    /// rule of core §13.3 and §14 is checked, each reached package's `rules`
    /// field, and that every rule the schema reaches has an implementation
    /// (supplied with [`Package::with_rule`]) or its package is taken
    /// shape-only (`missing-codec`).
    pub fn compile(sources: &Sources) -> Result<Schema> {
        Schema::compile_options(sources, &Options::default())
    }

    /// [`Schema::compile`], with the implementations of rules this program
    /// has built in besides those its packages carry (a tool's official
    /// rules).
    pub fn compile_with(sources: &Sources, built_in: &[PackageRule]) -> Result<Schema> {
        Schema::compile_options(sources, &Options { rules: built_in, ..Options::default() })
    }

    /// [`Schema::compile`], with `options`: their rules and packages taken
    /// shape-only besides the packages' own, whether missing rules are
    /// errors, the ids of files (`id`, `project`). Their packages, path
    /// and root are the sources'.
    pub fn compile_options(sources: &Sources, options: &Options) -> Result<Schema> {
        let values = sources.packages.values();
        let own = values.iter().flat_map(|p| p.rules().iter().cloned());
        let rules: Vec<PackageRule> = options.rules.iter().cloned().chain(own).collect();
        let shape_only: Vec<&str> = options
            .shape_only
            .iter()
            .copied()
            .chain(values.iter().filter(|p| p.is_shape_only()).map(Package::name))
            .collect();
        let options = Options {
            packages: &sources.packages,
            path: Some(&sources.entry),
            root: Some(&sources.root),
            rules: &rules,
            shape_only: &shape_only,
            ..*options
        };
        Schema::compile_sources(sources, &options)
    }
}
