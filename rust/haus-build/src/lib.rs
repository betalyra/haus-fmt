//! Rust types from haus schemas, generated in `build.rs`.
//!
//! An application:
//!
//! ```no_run
//! // build.rs
//! haus_build::Config::new()
//!     .codec("@haus-fmt/money@1#Money", "crate::codecs::Cents")
//!     .compile("src/order.schema.haus")
//!     .unwrap();
//! ```
//!
//! ```ignore
//! // src/main.rs
//! mod order { haus::include_schema!("order"); }
//! let order: order::Root = haus::from_str(&text)?;
//! ```
//!
//! A schema package (`package.haus` and `schema.haus` next to `Cargo.toml`,
//! and `links = "<library name>"` in it) calls [`package`] instead, and its
//! `lib.rs` includes the types with `haus::include_schema!("schema")`. Crates
//! that depend on it directly can then `import @org/name (…)`: the package's
//! types are its crate's types (`haus_money::Money`), and their ids are the
//! same in every language (`@haus-fmt/money@1#Money`). Generated code names
//! the crate by its `links`: don't rename schema package dependencies.
//!
//! Imports are loaded and checked by haus-fmt-schema (spec §13.3); files
//! the schema imports (`import ./common (Address)`) are generated into the
//! same output, as modules ([`Config::compile`]).

mod codegen;
mod graph;
pub mod roc;

// The schema syntax tree and schema packages are haus-fmt-schema's, which
// also loads and checks schemas with their imports.
use haus_schema::{Schema, packages, syntax as schema};

use codegen::Imported;
use graph::{Origin, Unit};
use haus::ErrorCode as Code;
use packages::{MANIFEST, Manifest};
use proc_macro2::TokenStream;
use quote::{format_ident, quote};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{env, fs};

pub use codegen::Codec;
/// What went wrong, and where: `src/order.schema.haus:3:5: unknown type Strin`.
pub use haus_schema::Error;
/// Something a schema allows but probably doesn't mean, with where it is:
/// `3:1: unknown attribute @since: this version of haus ignores it`. Build
/// scripts report warnings to Cargo.
pub use haus_schema::Warning;
pub use haus_schema::{Explicit, Locator, Options, Packages};

type Result<T, E = Error> = std::result::Result<T, E>;

/// How to generate code for a schema.
#[derive(Debug, Clone, Default)]
pub struct Config {
    codecs: Vec<Codec>,
    quiet: bool,
    without_attributes: bool,
}

impl Config {
    pub fn new() -> Config {
        Config::default()
    }

    /// Use the codec at `path` (a type implementing `haus::Codec`) for the type
    /// with this id: `.codec("std/time#Date", "crate::codecs::JiffDate")`.
    pub fn codec(mut self, id: impl Into<String>, path: impl Into<String>) -> Config {
        self.codecs.push(Codec { id: id.into(), path: path.into() });
        self
    }

    /// Don't report the schema's warnings ([`Warning`]) to Cargo.
    pub fn quiet(mut self) -> Config {
        self.quiet = true;
        self
    }

    /// Leave the schema's attributes out, as if they weren't written: the
    /// code decodes and encodes the same (spec §15), without `#[deprecated]`.
    /// For tests of that.
    #[doc(hidden)]
    pub fn without_attributes(mut self) -> Config {
        self.without_attributes = true;
        self
    }

    /// Generate `$OUT_DIR/<name>.rs` for `<name>.schema.haus`; include it with
    /// `haus::include_schema!("<name>")`.
    ///
    /// The files the schema imports (`import ./common (Address)`) are
    /// generated into the same file, each as a module named after its path
    /// from the schema's directory: `common`, `billing_common` for
    /// `billing/common.schema.haus`, `up_shared_money` for
    /// `../shared/money.schema.haus`.
    pub fn compile(&self, schema: impl AsRef<Path>) -> Result<()> {
        let schema = schema.as_ref();
        self.compile_as(schema, &stem(schema))
    }

    /// Like [`Config::compile`], to `$OUT_DIR/<name>.rs`: to compile one schema
    /// with different codecs.
    pub fn compile_as(&self, schema: impl AsRef<Path>, name: &str) -> Result<()> {
        let schema = schema.as_ref();
        let crate_dir = PathBuf::from(var("CARGO_MANIFEST_DIR")?);
        let path = crate_dir.join(schema).canonicalize().map_err(|e| Error::at(schema, Code::ImportNotFound, e))?;
        let krate = var("CARGO_PKG_NAME")?;
        // Files in this crate: `<crate>/<path>`; elsewhere: the schema's name (like the TypeScript binding).
        let crate_dir = crate_dir.canonicalize().unwrap_or(crate_dir);
        let id = match path.strip_prefix(&crate_dir) {
            Ok(relative) => format!("{krate}/{}", relative.with_file_name(stem(&path)).display()),
            Err(_) => stem(&path),
        };
        let packages = Packages::from_env()?;
        let options =
            Options { packages: &packages, id: Some(&id), project: Some((&krate, &crate_dir)), ..Options::default() };
        self.emit(&path, &options, &packages, name)
    }

    /// For a schema package crate: generate the types of its `schema.haus`
    /// to `$OUT_DIR/schema.rs` (`haus::include_schema!("schema")`), with ids
    /// from its manifest, and tell dependent crates where it is.
    ///
    /// Checks the crate too: its version is the manifest's
    /// (`package-version`), and its `links` is its library name, which
    /// generated code names it by.
    pub fn package(&self) -> Result<()> {
        let dir = PathBuf::from(var("CARGO_MANIFEST_DIR")?);
        let manifest = Manifest::read(&dir)?;
        let version = var("CARGO_PKG_VERSION")?;
        if version != manifest.version {
            let reason = format!(
                "the package.haus of {} says version {}, its Cargo.toml {version} ({})",
                manifest.name,
                manifest.version,
                dir.display()
            );
            return Err(Error::at(&dir.join(MANIFEST), Code::PackageVersion, reason));
        }
        let lib = crate_lib(&dir)?;
        let schema_path = manifest.schema_path(&dir)?;
        let packages = Packages::from_env()?;
        self.emit(&schema_path, &Options { packages: &packages, ..Options::default() }, &packages, "schema")?;
        rerun_if_changed(&dir.join(MANIFEST));
        rerun_if_changed(&dir.join("Cargo.toml"));
        println!("cargo::metadata=haus_package={}", dir.display());
        // The name code uses for this crate: its `links`, which is its library name.
        println!("cargo::metadata=haus_crate={lib}");
        println!("cargo::metadata=haus_version={version}");
        Ok(())
    }

    /// The Rust code for the schema file at `path`, loaded with `options`
    /// (its packages found by `options.packages`), the types of the package
    /// `@org/name` being in the crate `krate(name)`. Build scripts use
    /// [`Config::compile`]; this is for tests and tools.
    #[doc(hidden)]
    pub fn generate(&self, path: &Path, options: &Options, krate: &dyn Fn(&str) -> String) -> Result<String> {
        self.load(path, options, krate).map(|(_, _, code)| code)
    }

    /// The schema at `path`, the files to generate, and their code.
    fn load(
        &self,
        path: &Path,
        options: &Options,
        krate: &dyn Fn(&str) -> String,
    ) -> Result<(Schema, Vec<Unit>, String)> {
        let schema = Schema::load_with(path, &Options { without_attributes: self.without_attributes, ..*options })?;
        let units = graph::units(&schema, None, self.without_attributes)?;
        let code = generate_units(&schema, &units, &self.codecs, krate)?;
        Ok((schema, units, code))
    }

    /// Writes the code for the schema at `path` to `$OUT_DIR/<name>.rs`.
    fn emit(&self, path: &Path, options: &Options, packages: &Packages, name: &str) -> Result<()> {
        rerun_if_changed(path);
        // haus-fmt-schema never prints: the build script tells Cargo what it read.
        packages.files().iter().for_each(|f| rerun_if_changed(f));
        let krate = |package: &str| packages.find(package).map(|p| p.krate.clone()).unwrap_or_default();
        let (schema, units, code) = self.load(path, options, &krate)?;
        schema.files().iter().filter_map(|f| f.path.as_deref()).for_each(rerun_if_changed);
        if !self.quiet {
            for unit in &units {
                let path = unit.path.as_deref().map(|p| p.display().to_string()).unwrap_or_default();
                unit.file.warnings.iter().for_each(|w| println!("cargo::warning={path}:{w}"));
            }
        }
        let out = PathBuf::from(var("OUT_DIR")?).join(format!("{name}.rs"));
        fs::write(&out, code).map_err(|e| Error::at(&out, Code::ImportNotFound, e))
    }
}

/// [`Config::package`] with no codecs: the whole build script of a schema package.
pub fn package() -> Result<()> {
    Config::new().package()
}

/// Check a schema on its own, without its imports (spec §14): its syntax and
/// the rules that need no other file. Returns its warnings.
pub fn check(text: &str) -> Result<Vec<Warning>> {
    Ok(schema::parse(text)?.warnings.into_iter().map(Error::from).collect())
}

/// The Rust code for a schema given as text, with the id `id`, without
/// touching the environment. It imports std modules and `packages`, not files.
pub fn generate(text: &str, id: &str, codecs: &[Codec], packages: &Packages) -> Result<String> {
    let schema = Schema::parse_with(text, &Options { packages, id: Some(id), ..Options::default() })?;
    let units = graph::units(&schema, Some(text), false)?;
    let krate = |package: &str| packages.find(package).map(|p| p.krate.clone()).unwrap_or_default();
    generate_units(&schema, &units, codecs, &krate)
}

/// The code of a schema's files: the root's types, then a module for each
/// file it imports.
fn generate_units(schema: &Schema, units: &[Unit], codecs: &[Codec], krate: &dyn Fn(&str) -> String) -> Result<String> {
    graph::check_codecs(schema, units, codecs.iter().map(|c| c.id.as_str()), krate, "other crates' types")
        .map_err(|e| in_root(e, units))?;
    let modules = graph::module_names(&units[1..], &[], "_", rust_module);
    let module = |u: usize| format_ident!("{}", modules[u - 1]);
    let items = units
        .iter()
        .enumerate()
        .map(|(u, unit)| {
            let imports = unit
                .imports
                .iter()
                .map(|(name, origin)| {
                    let (path, params) = match origin {
                        Origin::Time => (format!("::haus::time::{name}"), 0),
                        Origin::Package { package, params, .. } => (format!("::{}::{name}", krate(package)), *params),
                        Origin::File { unit: 0, params, .. } => (format!("super::{name}"), *params),
                        Origin::File { unit: to, params, .. } => {
                            let at = if u == 0 { "self" } else { "super" };
                            (format!("{at}::{}::{name}", modules[to - 1]), *params)
                        }
                    };
                    (name.clone(), Imported { id: origin.id(name), path, params })
                })
                .collect::<HashMap<_, _>>();
            let input =
                codegen::Input { text: &unit.text, id: &unit.id, imports: &imports, codecs, check_codecs: u == 0 };
            let items = codegen::generate(&unit.file, &input).map_err(|e| {
                let e = Error::from(e);
                match &unit.path {
                    Some(path) => e.in_file(path),
                    None => e,
                }
            })?;
            Ok(match u {
                0 => items,
                _ => {
                    let (name, file) = (module(u), unit.path.as_deref().and_then(Path::file_name));
                    let doc = format!(
                        " The types of `{}` ({}).",
                        unit.id,
                        file.map(|f| f.to_string_lossy()).unwrap_or_default()
                    );
                    quote! {
                        #[doc = #doc]
                        pub mod #name { #items }
                    }
                }
            })
        })
        .collect::<Result<Vec<TokenStream>>>()?;
    codegen::print(quote! { #(#items)* }, &units[0].id)
}

/// An error about the schema as a whole, in its root file.
fn in_root(e: Error, units: &[Unit]) -> Error {
    match units[0].path.as_deref() {
        Some(path) if e.path().is_none() => e.in_file(path),
        _ => e,
    }
}

/// The module of an imported file in Rust: `billing_common` for `billing/common`.
fn rust_module(segments: &[String]) -> String {
    let words: Vec<String> = segments
        .iter()
        .flat_map(|s| s.split(|c: char| !c.is_ascii_alphanumeric()))
        .filter(|w| !w.is_empty())
        .map(|w| w.to_ascii_lowercase())
        .collect();
    let name = words.join("_");
    match name.as_str() {
        "" => "file".into(),
        n if n.starts_with(|c: char| c.is_ascii_digit()) => format!("file_{n}"),
        n if syn::parse_str::<syn::Ident>(n).is_err() => format!("{n}_"),
        _ => name,
    }
}

/// The library name of the package crate in `dir`, checked: generated code
/// names the crate by its `links` (Cargo passes the package's metadata only
/// with one), so `links` must be its library name (G9).
fn crate_lib(dir: &Path) -> Result<String> {
    let path = dir.join("Cargo.toml");
    let package = var("CARGO_PKG_NAME")?;
    let toml = fs::read_to_string(&path).map_err(|e| Error::at(&path, Code::ImportNotFound, e))?;
    let lib = lib_name(&toml).unwrap_or_else(|| package.replace('-', "_"));
    match env::var("CARGO_MANIFEST_LINKS") {
        Ok(links) if links == lib => Ok(lib),
        Ok(links) => Err(Error::at(
            &path,
            Code::ImportNotFound,
            format!(
                "{package} has links = \"{links}\", but its library is {lib}: crates that use its types name it by \
                 its links, so they must be the same: links = \"{lib}\""
            ),
        )),
        Err(_) => Err(Error::at(
            &path,
            Code::ImportNotFound,
            format!(
                "{package} has no links: add links = \"{lib}\" (its library name) to [package], so that crates \
                 depending on it find its schema"
            ),
        )),
    }
}

/// `name` in the `[lib]` table of a Cargo.toml, if it has one.
fn lib_name(toml: &str) -> Option<String> {
    let mut in_lib = false;
    for line in toml.lines().map(str::trim) {
        if line.starts_with('[') {
            in_lib = line.split('#').next().is_some_and(|t| t.trim() == "[lib]");
            continue;
        }
        let value = line.strip_prefix("name").map(str::trim_start).and_then(|r| r.strip_prefix('='));
        if let (true, Some(value)) = (in_lib, value) {
            let value = value.trim().strip_prefix('"')?;
            return value.split_once('"').map(|(name, _)| name.to_owned());
        }
    }
    None
}

/// Tells Cargo to rerun the build script when `path` changes (only in a build script).
fn rerun_if_changed(path: &Path) {
    if env::var_os("OUT_DIR").is_some() {
        println!("cargo::rerun-if-changed={}", path.display());
    }
}

fn read(path: &Path) -> Result<String> {
    fs::read_to_string(path).map_err(|e| Error::at(path, Code::ImportNotFound, e))
}

fn var(key: &str) -> Result<String> {
    let reason = format!("{key} is not set: haus-fmt-build runs in a build script");
    env::var(key).map_err(|_| Error::new(Code::ImportUnavailable, reason))
}

/// `order` for `src/order.schema.haus`.
fn stem(path: &Path) -> String {
    let file = path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
    file.strip_suffix(".schema.haus").unwrap_or(&file).to_owned()
}
