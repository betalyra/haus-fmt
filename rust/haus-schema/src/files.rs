//! Finding the files that imports name (spec §13.3): schema packages and
//! files next to the importing one. Resolution happens when a schema is
//! loaded, never while data is parsed, and never over the network (§9.2).

use crate::packages::{MANIFEST, Manifest, Packages};
use std::path::{Path, PathBuf};
use std::{env, fs};

/// A schema file found for an import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Module {
    /// Unique for each file (its canonical path, say); passed back as `from`
    /// for the file's own imports.
    pub key: String,
    /// The file's identity, the same in every language: `@haus-fmt/money@1`
    /// for a package's schema (from its manifest), `@org/name@1/path` for its
    /// other files.
    pub id: String,
    pub text: String,
    /// The package's version, checked against an `@major` in the import.
    pub version: Option<String>,
}

/// Finds the schema files that imports name.
pub trait Resolver {
    /// `module` as written, without an `@major` (`@haus-fmt/money`,
    /// `./common`), imported by the file with key `from` (None: the root
    /// file, when it has no key). An error says why it can't be found.
    fn resolve(&self, module: &str, from: Option<&str>) -> Result<Module, String>;
}

/// No resolver: only std modules can be imported.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoImports;

impl Resolver for NoImports {
    fn resolve(&self, _module: &str, _from: Option<&str>) -> Result<Module, String> {
        Err("no module resolver (only std modules can be imported here)".into())
    }
}

/// The schema packages of a crate's direct dependencies (build scripts).
impl Resolver for Packages {
    fn resolve(&self, module: &str, _from: Option<&str>) -> Result<Module, String> {
        if !module.starts_with('@') {
            return Err("haus-fmt-build imports std/time and schema packages (@org/name) so far".into());
        }
        let pkg = self.find(module)?;
        read_module(&pkg.dir.join(&pkg.manifest.schema))
    }
}

/// Files from the file system, like the Node resolver of the TypeScript binding:
///
/// - `import ./common (Address)`: `./common.schema.haus`, next to the importing file;
/// - `import @haus-fmt/money (Money)`: a package directory given with
///   [`FileResolver::package`], else `node_modules/@haus-fmt/money/haus.package.haus`
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
    fn resolve(&self, module: &str, from: Option<&str>) -> Result<Module, String> {
        let dir = match from {
            Some(from) => Path::new(from).parent().map(Path::to_path_buf).unwrap_or_default(),
            None => match &self.base {
                Some(base) => base.clone(),
                None => env::current_dir().map_err(|e| e.to_string())?,
            },
        };
        if module.starts_with("./") || module.starts_with("../") {
            let file = if module.ends_with(EXTENSION) { module.to_owned() } else { format!("{module}{EXTENSION}") };
            let path = dir.join(file);
            if !path.is_file() {
                return Err(format!("file not found: {}", path.display()));
            }
            return read_module(&path);
        }
        let direct = self.packages.iter().filter(|(n, _)| n == module).map(|(_, d)| d.join(MANIFEST));
        let installed =
            dir.ancestors().map(|d| module.split('/').fold(d.join("node_modules"), |p, s| p.join(s)).join(MANIFEST));
        for manifest in direct.chain(installed) {
            if manifest.is_file() {
                let package = manifest.parent().unwrap_or(Path::new("."));
                let m = Manifest::read(package).map_err(|e| e.to_string())?;
                if m.name != module {
                    return Err(format!("{} names the package {}, not {module}", manifest.display(), m.name));
                }
                return read_module(&package.join(&m.schema));
            }
        }
        Err(format!("package not found (no node_modules/{module}/{MANIFEST} above {})", dir.display()))
    }
}

const EXTENSION: &str = ".schema.haus";

/// The schema file at `path`, with its key, identity and package version.
pub(crate) fn read_module(path: &Path) -> Result<Module, String> {
    let path = path.canonicalize().map_err(|e| format!("{}: {e}", path.display()))?;
    let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let (id, version) = identify(&path);
    Ok(Module { key: path.display().to_string(), id, text, version })
}

/// The identity of the schema file at `path` (canonical), and the version of
/// its package: `@haus-fmt/money@1` for a package's schema, `@haus-fmt/money@1/path`
/// for another file in a package, and the file's name (`order`) outside one.
pub(crate) fn identify(path: &Path) -> (String, Option<String>) {
    for dir in path.ancestors().skip(1) {
        if dir.join(MANIFEST).is_file()
            && let Ok(m) = Manifest::read(dir)
        {
            let rel = path.strip_prefix(dir).unwrap_or(path);
            let id = match rel == Path::new(&m.schema) {
                true => m.id(),
                false => format!("{}/{}", m.id(), stem(&rel.to_string_lossy().replace('\\', "/"))),
            };
            return (id, Some(m.version));
        }
    }
    (stem(&path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()), None)
}

/// `order` for `order.schema.haus`.
fn stem(file: &str) -> String {
    file.strip_suffix(EXTENSION).unwrap_or(file).to_owned()
}
