//! Finding the files that imports name (spec §13.3): schema packages and
//! files next to the importing one. Resolution happens when a schema is
//! loaded, never while data is parsed, and never over the network (§9.2).

use crate::packages::{MANIFEST, Manifest, Packages, package_dir_of, package_of};
use crate::{Error, Result};
use haus::ErrorCode;
use std::path::{Path, PathBuf};
use std::{env, fs};

/// A schema file found for an import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Module {
    /// Unique for each file (its canonical path, say); passed back as `from`
    /// for the file's own imports.
    pub key: String,
    /// The file's identity: `@haus-fmt/money@1` for a package's
    /// `schema.haus` (from its manifest), the same in every language; for
    /// other files, one the resolver chooses.
    pub id: String,
    pub text: String,
    /// The package's version, checked against an `@major` in the import.
    pub version: Option<String>,
}

/// Finds the schema files that imports name.
pub trait Resolver {
    /// `module` as written, without an `@major` (`@haus-fmt/money`,
    /// `./common`), imported by the file with key `from` (None: the root
    /// file, when it has no key). An error says why it can't be found:
    /// `import-not-found`, or `import-unavailable` if this resolver can't
    /// import such modules at all.
    fn resolve(&self, module: &str, from: Option<&str>) -> Result<Module>;
}

/// No resolver: only std modules can be imported.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoImports;

impl Resolver for NoImports {
    fn resolve(&self, _module: &str, _from: Option<&str>) -> Result<Module> {
        Err(Error::new(ErrorCode::ImportUnavailable, "no module resolver (only std modules can be imported here)"))
    }
}

/// The schema packages of a crate's direct dependencies (build scripts).
impl Resolver for Packages {
    fn resolve(&self, module: &str, _from: Option<&str>) -> Result<Module> {
        if !module.starts_with('@') {
            let reason = "haus-fmt-build imports std/time and schema packages (@org/name) so far";
            return Err(Error::new(ErrorCode::ImportUnavailable, reason));
        }
        let pkg = self.find(module)?;
        read_module(&pkg.manifest.schema_path(&pkg.dir)?)
    }
}

/// Files from the file system, like the Node resolver of the TypeScript binding:
///
/// - `import ./common (Address)`: `./common.schema.haus`, next to the importing file;
/// - `import @haus-fmt/money (Money)`: a package directory given with
///   [`FileResolver::package`], else `node_modules/@haus-fmt/money/package.haus`
///   in the importing file's directory or above it.
#[derive(Debug, Clone, Default)]
pub struct FileResolver {
    base: Option<PathBuf>,
    packages: Vec<(String, PathBuf)>,
}

impl FileResolver {
    pub fn new() -> FileResolver {
        FileResolver::default()
    }

    /// Where relative imports of a root file without a key resolve from
    /// (default: the working directory).
    pub fn base(mut self, dir: impl Into<PathBuf>) -> FileResolver {
        self.base = Some(dir.into());
        self
    }

    /// The package `name` is in `dir` (with its manifest), looked up before `node_modules`.
    pub fn package(mut self, name: impl Into<String>, dir: impl Into<PathBuf>) -> FileResolver {
        self.packages.push((name.into(), dir.into()));
        self
    }
}

impl Resolver for FileResolver {
    fn resolve(&self, module: &str, from: Option<&str>) -> Result<Module> {
        let dir = match from {
            Some(from) => Path::new(from).parent().map(Path::to_path_buf).unwrap_or_default(),
            None => match &self.base {
                Some(base) => base.clone(),
                None => env::current_dir().map_err(|e| not_found(e.to_string()))?,
            },
        };
        if module.starts_with("./") || module.starts_with("../") {
            // A package is one file: its schema imports other packages by name (spec §13.3).
            if let Some(package) = from.and_then(|from| package_dir_of(Path::new(from))) {
                let name = Manifest::read(package).map_or_else(|_| package.display().to_string(), |m| m.name);
                let reason = format!("the schema of {name} can't import files, only packages by name");
                return Err(Error::new(ErrorCode::PackagePath, reason));
            }
            let path = dir.join(format!("{module}{EXTENSION}"));
            // An application's file doesn't reach into a package: it imports the package by name.
            let real = path.canonicalize().ok();
            if let Some(into) = package_dir_of(&path).or_else(|| real.as_deref().and_then(package_dir_of)) {
                let reason =
                    format!("the file is in the package directory {}: import the package by its name", into.display());
                return Err(Error::new(ErrorCode::PackagePath, reason));
            }
            if !path.is_file() {
                return Err(not_found(format!("file not found: {}", path.display())));
            }
            return read_module(&path);
        }
        let direct = self.packages.iter().filter(|(n, _)| n == module).map(|(_, d)| d.join(MANIFEST));
        let installed =
            dir.ancestors().map(|d| module.split('/').fold(d.join("node_modules"), |p, s| p.join(s)).join(MANIFEST));
        for manifest in direct.chain(installed) {
            if manifest.is_file() {
                let package = manifest.parent().unwrap_or(Path::new("."));
                let m = Manifest::read(package)?;
                if m.name != module {
                    return Err(not_found(format!(
                        "{} names the package {}, not {module}",
                        manifest.display(),
                        m.name
                    )));
                }
                return read_module(&m.schema_path(package)?);
            }
        }
        Err(not_found(format!("package not found (no node_modules/{module}/{MANIFEST} above {})", dir.display())))
    }
}

const EXTENSION: &str = ".schema.haus";

fn not_found(reason: String) -> Error {
    Error::new(ErrorCode::ImportNotFound, reason)
}

/// The schema file at `path`, with its key (its canonical path), identity and package version.
pub(crate) fn read_module(path: &Path) -> Result<Module> {
    let (id, version) = identify(path);
    let path = path.canonicalize().map_err(|e| not_found(format!("{}: {e}", path.display())))?;
    let text = fs::read_to_string(&path).map_err(|e| not_found(format!("{}: {e}", path.display())))?;
    Ok(Module { key: path.display().to_string(), id, text, version })
}

/// The identity of the schema file at `path`, and the version of its
/// package: `@haus-fmt/money@1` for a package's `schema.haus`, and the
/// file's name (`order`) for other files.
pub(crate) fn identify(path: &Path) -> (String, Option<String>) {
    match package_of(path) {
        Some((_, Ok(m))) => (m.id(), Some(m.version)),
        _ => (stem(&path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()), None),
    }
}

/// `order` for `order.schema.haus`.
fn stem(file: &str) -> String {
    file.strip_suffix(EXTENSION).unwrap_or(file).to_owned()
}
