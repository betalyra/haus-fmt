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
//! same in every language (`@haus-fmt/money@1#Money`).

mod codegen;
pub mod roc;

// The schema syntax tree and schema packages are haus-fmt-schema's, which
// also checks data against schemas at runtime.
use haus_schema::{packages, syntax as schema};

use codegen::{Imported, STD_TIME};
use haus::ErrorCode as Code;
use packages::{MANIFEST, Manifest};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{env, fs};

pub use codegen::Codec;
/// What went wrong, and where: `src/order.schema.haus:3:5: unknown type Strin`.
pub use haus_schema::Error;
pub use haus_schema::Packages;
/// Something a schema allows but probably doesn't mean, with where it is:
/// `3:1: unknown attribute @since: this version of haus ignores it`. Build
/// scripts report warnings to Cargo.
pub use haus_schema::Warning;

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
        // A file in this crate: `<crate>/<path>`; elsewhere: its name (like the TypeScript binding).
        let relative = crate_dir.canonicalize().ok().and_then(|dir| path.strip_prefix(dir).ok().map(Path::to_path_buf));
        let id = match relative {
            Some(relative) => format!("{}/{}", var("CARGO_PKG_NAME")?, relative.with_file_name(stem(&path)).display()),
            None => stem(&path),
        };
        self.emit(&path, &id, name)
    }

    /// For a schema package crate: generate the types of its `schema.haus`
    /// to `$OUT_DIR/schema.rs` (`haus::include_schema!("schema")`), with ids
    /// from its manifest, and tell dependent crates where it is.
    pub fn package(&self) -> Result<()> {
        let dir = PathBuf::from(var("CARGO_MANIFEST_DIR")?);
        let manifest = Manifest::read(&dir)?;
        let schema = manifest.schema_path(&dir)?;
        let text = read(&schema)?;
        let file = schema::parse(&text).map_err(|e| Error::from(e).in_file(&schema))?;
        packages::imports_no_files(&manifest, &file, &text).map_err(|e| e.in_file(&schema))?;
        self.emit(&schema, &manifest.id(), "schema")?;
        rerun_if_changed(&dir.join(MANIFEST));
        println!("cargo::metadata=haus_package={}", dir.display());
        // The name code uses for this crate: its `links`, which is its library
        // name (`haus_money` for haus-fmt-money), else its package name.
        let krate = env::var("CARGO_MANIFEST_LINKS").or_else(|_| var("CARGO_PKG_NAME"))?;
        println!("cargo::metadata=haus_crate={}", krate.replace('-', "_"));
        Ok(())
    }

    fn emit(&self, schema: &Path, id: &str, name: &str) -> Result<()> {
        rerun_if_changed(schema);
        let text = read(schema)?;
        let file = schema::parse(&text).map_err(|e| Error::from(e).in_file(schema))?;
        let file = if self.without_attributes { schema::without_attributes(file) } else { file };
        if !self.quiet {
            for w in &file.warnings {
                println!("cargo::warning={}:{w}", schema.display());
            }
        }
        let packages = Packages::from_env()?;
        // haus-fmt-schema never prints: the build script tells Cargo what it read.
        packages.files().iter().for_each(|f| rerun_if_changed(f));
        let code = generate_file(&file, &text, id, &self.codecs, &packages).map_err(|e| e.in_file(schema))?;
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

/// The Rust code for a schema, without touching the environment.
pub fn generate(text: &str, id: &str, codecs: &[Codec], packages: &Packages) -> Result<String> {
    generate_file(&schema::parse(text)?, text, id, codecs, packages)
}

fn generate_file(file: &schema::File, text: &str, id: &str, codecs: &[Codec], packages: &Packages) -> Result<String> {
    let imports = file
        .imports
        .iter()
        .map(|imp| resolve(imp, packages).map_err(|(code, reason)| schema::error(text, imp.pos, code, reason).into()))
        .collect::<Result<Vec<_>>>()?
        .into_iter()
        .flatten()
        .try_fold(HashMap::new(), |mut all, (name, t)| match all.insert(name.clone(), t) {
            Some(_) => Err(Error::new(Code::DuplicateImport, format!("{name} is imported twice"))),
            None => Ok(all),
        })?;
    Ok(codegen::generate(file, &codegen::Input { text, id, imports: &imports, codecs })?)
}

/// The types an import brings in, by name.
fn resolve(imp: &schema::Import, packages: &Packages) -> Result<Vec<(String, Imported)>, (Code, String)> {
    let names = imp.names.iter().map(|(n, _)| n.as_str());
    match imp.module.as_str() {
        "std/time" => names
            .map(|n| {
                if !STD_TIME.contains(&n) {
                    return Err((Code::UnknownImport, format!("std/time has no type {n} (it has {})", STD_TIME.join(", "))));
                }
                let imported = Imported { id: format!("std/time#{n}"), path: format!("::haus::time::{n}"), params: 0 };
                Ok((n.to_owned(), imported))
            })
            .collect(),
        "std/money" => Err((
            Code::UnknownModule,
            "std/money is no longer a standard module; it is the package @haus-fmt/money: import @haus-fmt/money (Money)"
                .into(),
        )),
        module if module.starts_with('@') => {
            let (name, major) = match module.rsplit_once('@').filter(|(n, _)| !n.is_empty()) {
                Some((n, v)) => (n, Some(v)),
                None => (module, None),
            };
            let pkg = packages.find(name).map_err(|e| (e.code(), e.reason().to_owned()))?;
            if let Some(major) = major.filter(|m| *m != pkg.manifest.major()) {
                return Err((Code::ImportVersion, format!(
                    "{module} wants major version {major}, but version {} was found",
                    pkg.manifest.version
                )));
            }
            names
                .map(|n| match pkg.types.get(n) {
                    Some(&params) => {
                        let id = format!("{}#{n}", pkg.manifest.id());
                        Ok((n.to_owned(), Imported { id, path: format!("::{}::{n}", pkg.krate), params }))
                    }
                    None => Err((Code::UnknownImport, format!("{name} has no type {n}"))),
                })
                .collect()
        }
        module => Err((
            Code::ImportUnavailable,
            format!("can't import {module}: haus-fmt-build imports std/time and schema packages (@org/name) so far"),
        )),
    }
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
