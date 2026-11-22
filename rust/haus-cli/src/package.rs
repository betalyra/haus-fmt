//! `haus package check`: a schema package before it is published (spec
//! §13.3). Its manifest and schema, its profiles' test vectors, and the
//! wrappers of package managers next to them (`package.json`, `Cargo.toml`,
//! `pyproject.toml`): versions, names, the files they ship, the
//! dependencies they declare, install scripts. The files are only read:
//! nothing is run, packed or fetched.

use crate::check::{self, Failure, value_span};
use crate::cli::{Color, PackageCheckArgs};
use crate::diagnostic::{Diagnostic, Severity};
use crate::json::{self, Members, b, n, s};
use crate::output::{self, Status, count};
use crate::pieces::Pieces;
use haus::json::Json;
use haus::{ErrorCode, Limits, Value};
use haus_schema::packages::{MANIFEST, SCHEMA, is_package_name};
use haus_schema::{Explicit, Locator, Manifest, Schema, syntax};
use ignore::Match;
use ignore::gitignore::GitignoreBuilder;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::io::stdout;
use std::ops::Range;
use std::path::{Path, PathBuf};
use toml::de::{DeTable, DeValue};

/// The largest wrapper (`package.json`, `Cargo.toml`, `pyproject.toml`) and
/// profile read, in bytes (1 MiB, spec §13.3's limit for `package.json`).
const MAX_FILE: u64 = 1024 * 1024;
/// The most package directories followed through path dependencies, to
/// find the packages a schema imports.
const MAX_PACKAGES: usize = 256;
/// The crates of haus itself: dependencies that are no schema packages.
const HAUS_CRATES: [&str; 3] = ["haus-fmt", "haus-fmt-schema", "haus-fmt-build"];
/// npm's fields of dependencies that count for a package's `schema.haus` (spec §13.3).
const NPM_FIELDS: [&str; 3] = ["dependencies", "peerDependencies", "optionalDependencies"];
/// npm scripts that run when a package is installed.
const INSTALL_SCRIPTS: [&str; 3] = ["preinstall", "install", "postinstall"];

/// What checking one package found.
struct Report {
    /// The directory, as given.
    path: String,
    manifest: Option<Manifest>,
    /// Why the directory couldn't be read.
    error: Option<String>,
    diagnostics: Vec<Diagnostic>,
}

impl Report {
    fn count(&self, severity: Severity) -> usize {
        self.diagnostics.iter().filter(|d| d.severity == severity).count()
    }

    fn ok(&self) -> bool {
        self.error.is_none() && self.count(Severity::Error) == 0
    }

    fn to_json(&self) -> Json {
        let mut m = Members::default();
        m.add("path", s(&self.path));
        m.opt("name", self.manifest.as_ref().map(|m| s(&m.name)));
        m.opt("version", self.manifest.as_ref().map(|m| s(&m.version)));
        m.add("ok", b(self.ok()));
        m.opt("error", self.error.as_deref().map(s));
        m.add("diagnostics", Json::Array(self.diagnostics.iter().map(Diagnostic::to_json).collect()));
        m.into()
    }
}

pub fn check(args: &PackageCheckArgs, color: Color) -> Status {
    let given = match check::explicit(&args.packages) {
        Ok(given) => given,
        Err(failure) => return fail(args.json, &failure),
    };
    let reports: Vec<Report> = args.dirs.iter().map(|dir| Package::check(dir, &given)).collect();
    let status = match () {
        _ if reports.iter().any(|r| r.error.is_some()) => Status::Failed,
        _ if reports.iter().any(|r| !r.ok()) => Status::Invalid,
        _ => Status::Ok,
    };
    let text = match args.json {
        true => json::write(&to_json(&reports, None)) + "\n",
        false => text(&reports, &output::renderer(output::colored(color, &stdout()))),
    };
    match output::print(&text) {
        Ok(()) => status,
        Err(e) => output::fail(e),
    }
}

/// Why nothing could be checked (exit code 2): with --json, the document still comes.
fn fail(json: bool, failure: &Failure) -> Status {
    match json {
        true => match output::print(&(json::write(&to_json(&[], Some(failure))) + "\n")) {
            Ok(()) => Status::Failed,
            Err(e) => output::fail(e),
        },
        false => output::fail(&failure.message),
    }
}

/// The text output: each package's diagnostics, then the summary.
fn text(reports: &[Report], renderer: &annotate_snippets::Renderer) -> String {
    let mut out = String::new();
    for r in reports {
        if let Some(e) = &r.error {
            out += &format!("error: cannot read {}: {e}\n\n", r.path);
        }
        for d in &r.diagnostics {
            out += &format!("{}\n\n", d.render_alone(renderer));
        }
    }
    let total = |severity| reports.iter().map(|r| r.count(severity)).sum::<usize>();
    let unreadable = reports.iter().filter(|r| r.error.is_some()).count();
    let found: Vec<String> = [
        (total(Severity::Error), "error"),
        (total(Severity::Warning), "warning"),
        (unreadable, "unreadable directory"),
    ]
    .into_iter()
    .filter(|&(n, _)| n > 0)
    .map(|(n, noun)| count(n, noun))
    .collect();
    let found = if found.is_empty() { "no problems".to_owned() } else { found.join(", ") };
    out + &format!("Checked {}: {found}.\n", count(reports.len(), "package"))
}

/// The --json document: `ok`, `error` if the check couldn't run, the packages and the summary.
fn to_json(reports: &[Report], failure: Option<&Failure>) -> Json {
    let total = |severity| reports.iter().map(|r| r.count(severity)).sum::<usize>();
    let mut summary = Members::default();
    summary.add("packages", n(reports.len()));
    summary.add("errors", n(total(Severity::Error)));
    summary.add("warnings", n(total(Severity::Warning)));
    summary.add("unreadable", n(reports.iter().filter(|r| r.error.is_some()).count()));
    let mut m = Members::default();
    m.add("ok", b(failure.is_none() && reports.iter().all(Report::ok)));
    m.opt("error", failure.map(Failure::to_json));
    m.add("packages", Json::Array(reports.iter().map(Report::to_json).collect()));
    m.add("summary", summary.into());
    m.into()
}

/// The package manager a wrapper file is for.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Wrapper {
    Npm,
    Cargo,
    Python,
}

impl Wrapper {
    fn file(self) -> &'static str {
        match self {
            Wrapper::Npm => "package.json",
            Wrapper::Cargo => "Cargo.toml",
            Wrapper::Python => "pyproject.toml",
        }
    }
}

/// A dependency a wrapper declares.
struct Dep {
    /// Its name in the wrapper: the npm name, the key in `[dependencies]`,
    /// the distribution's name.
    name: String,
    /// Where its name is in the wrapper's text.
    span: Option<Range<usize>>,
    /// Its directory, for a path dependency (`path = "../money"`, `file:../money`).
    dir: Option<PathBuf>,
    /// npm: the field it is in (`peerDependencies`).
    field: &'static str,
    /// Cargo: the crate it renames (`money = { package = "haus-fmt-money" }`).
    renames: Option<String>,
    /// A dependency on haus itself (`haus-fmt`), which is no schema package.
    haus: bool,
}

/// The dependencies a wrapper of the package declares, and its text.
struct Declared {
    wrapper: Wrapper,
    text: String,
    deps: Vec<Dep>,
}

/// A package being checked: its directory and what is found.
struct Package<'a> {
    dir: &'a Path,
    out: Vec<Diagnostic>,
}

impl Package<'_> {
    fn check(dir: &Path, given: &Explicit) -> Report {
        let mut report = Report { path: output::shown(dir), manifest: None, error: None, diagnostics: vec![] };
        match fs::metadata(dir) {
            Ok(meta) if meta.is_dir() => {}
            Ok(_) => return Report { error: Some("not a directory".into()), ..report },
            Err(e) => return Report { error: Some(e.to_string()), ..report },
        }
        let mut p = Package { dir, out: vec![] };
        if dir.join(MANIFEST).symlink_metadata().is_err() {
            // Not a package: nothing else to check.
            let message = format!("{} is not a schema package: it has no {MANIFEST}", output::shown(dir));
            let d = Diagnostic::new(Severity::Error, ErrorCode::ImportNotFound, message)
                .with_hint("Give the directory of a schema package: the one with package.haus and schema.haus.");
            p.report(d, MANIFEST, None);
            return Report { diagnostics: p.out, ..report };
        }
        let manifest = p.manifest();
        let profiles = p.profile_files();
        // The package's files: the profiles' vectors, and their rules where they are (a missing one is reported once).
        let rules = profiles.iter().map(|v| v.replace(".vectors.haus", ".md")).filter(|r| dir.join(r).is_file());
        let shipped: Vec<String> =
            [MANIFEST, SCHEMA].map(str::to_owned).into_iter().chain(profiles.clone()).chain(rules).collect();
        let declared: Vec<Declared> = [p.npm(manifest.as_ref(), &shipped), p.cargo(manifest.as_ref(), &shipped)]
            .into_iter()
            .chain([p.python(manifest.as_ref(), &shipped)])
            .flatten()
            .collect();
        let schema = manifest.as_ref().and_then(|m| p.schema(m, &packages(given, &declared)));
        if let Some((_, imports)) = &schema {
            p.imports_declared(imports, &declared);
        }
        let schema = schema.and_then(|(schema, _)| schema);
        for file in &profiles {
            p.vectors(file, schema.as_ref());
        }
        report.manifest = manifest;
        report.diagnostics = p.out;
        report
    }

    /// How a file of the package is shown: `extensions/money/Cargo.toml`.
    fn shown(&self, file: &str) -> String {
        output::shown(self.dir.join(file))
    }

    /// Reports `d` about `file`, at `span` of its `text` if given.
    fn report(&mut self, d: Diagnostic, file: &str, at: Option<(&str, Range<usize>)>) {
        let d = match at {
            Some((text, span)) => d.at(text, span),
            None => d,
        };
        self.out.push(d.in_file(self.shown(file)));
    }

    fn error(&mut self, code: ErrorCode, file: &str, at: Option<(&str, Range<usize>)>, message: String, hint: &str) {
        self.report(Diagnostic::new(Severity::Error, code, message).with_hint(hint), file, at);
    }

    fn warn(&mut self, code: ErrorCode, file: &str, at: Option<(&str, Range<usize>)>, message: String, hint: &str) {
        self.report(Diagnostic::new(Severity::Warning, code, message).with_hint(hint), file, at);
    }

    // ── the manifest and the schema ─────────────────────────────

    /// `package.haus`: one record with a lowercase `@org/name` and a semantic
    /// version, at most 64 KiB, a regular file (spec §13.3).
    fn manifest(&mut self) -> Option<Manifest> {
        match Manifest::read(self.dir) {
            Ok(manifest) => {
                // Read once more for its other fields; it is a regular file, checked.
                let text = fs::read_to_string(self.dir.join(MANIFEST)).unwrap_or_default();
                if let Ok([record]) = haus::parse(&text).as_deref()
                    && record.get("schema").is_some()
                {
                    self.warn(
                        ErrorCode::PackageManifest,
                        MANIFEST,
                        None,
                        "package.haus has a field schema, which is ignored: a package's schema is always schema.haus"
                            .into(),
                        "Remove the field, and keep the schema in schema.haus next to package.haus.",
                    );
                }
                Some(manifest)
            }
            Err(e) => {
                self.report(Diagnostic::schema(&e, Severity::Error, None), MANIFEST, None);
                None
            }
        }
    }

    /// `schema.haus`, a regular file, loaded with its imports: errors and
    /// warnings. Returns the schema, if it is valid, and the packages it
    /// imports (if it parses).
    fn schema(&mut self, manifest: &Manifest, packages: &dyn Locator) -> Option<(Option<Schema>, Vec<String>)> {
        let path = match manifest.schema_path(self.dir) {
            Ok(path) => path,
            Err(e) => {
                self.report(Diagnostic::schema(&e, Severity::Error, None), SCHEMA, None);
                return None;
            }
        };
        let (schema, text) = match Schema::load(&path, packages) {
            Ok(schema) => {
                let text = schema.files()[0].text.clone();
                for w in schema.warnings() {
                    self.report(Diagnostic::schema(w, Severity::Warning, Some(&text)), SCHEMA, None);
                }
                (Some(schema), text)
            }
            Err(e) => {
                // Read again for the excerpt and the imports, unless it is too large to be read at all.
                let small = path.metadata().is_ok_and(|m| m.len() <= MAX_FILE);
                let text = fs::read(&path).ok().filter(|_| small).map(|b| String::from_utf8_lossy(&b).into_owned());
                self.report(Diagnostic::schema(&e, Severity::Error, text.as_deref()), SCHEMA, None);
                (None, text.unwrap_or_default())
            }
        };
        let imports: BTreeSet<String> = syntax::parse(&text)
            .map(|file| {
                let packages = file.imports.into_iter().filter(|imp| imp.module.starts_with('@'));
                packages.map(|imp| syntax::package(&imp.module).to_owned()).collect()
            })
            .unwrap_or_default();
        Some((schema, imports.into_iter().collect()))
    }

    /// Every package the schema imports is a dependency in every wrapper,
    /// and a schema package Cargo depends on isn't renamed.
    fn imports_declared(&mut self, imports: &[String], declared: &[Declared]) {
        for d in declared {
            let file = d.wrapper.file();
            // The schema packages among its dependencies, by name.
            let mut names: Vec<(String, &Dep)> = vec![];
            for dep in d.deps.iter().filter(|dep| d.wrapper == Wrapper::Npm || dep.dir.is_some()) {
                match (d.wrapper, &dep.dir) {
                    (Wrapper::Npm, _) => names.push((dep.name.clone(), dep)),
                    (_, Some(dir)) if dir.join(MANIFEST).symlink_metadata().is_ok() => match Manifest::read(dir) {
                        Ok(m) => names.push((m.name, dep)),
                        Err(e) => {
                            let message = format!(
                                "the dependency {} ({}) is not a valid schema package: {}",
                                dep.name,
                                output::shown(dir),
                                e.reason()
                            );
                            let at = dep.span.clone().map(|span| (d.text.as_str(), span));
                            self.report(Diagnostic::new(Severity::Error, e.code(), message), file, at);
                        }
                    },
                    _ => {}
                }
            }
            for (name, dep) in &names {
                if let Some(krate) = &dep.renames {
                    let at = dep.span.clone().map(|span| (d.text.as_str(), span));
                    self.error(
                        ErrorCode::PackageCrate,
                        file,
                        at,
                        format!(
                            "the dependency on {name} renames the crate {krate} to {}: generated code names a schema \
                             package's crate by its library name",
                            dep.name
                        ),
                        "Depend on the crate under its own name: remove package = … and use its name as the key.",
                    );
                }
            }
            for import in imports {
                let found: Vec<&Dep> = names.iter().filter(|(name, _)| name == import).map(|(_, dep)| *dep).collect();
                match (d.wrapper, found.as_slice()) {
                    (Wrapper::Npm, []) => self.report(
                        Diagnostic::new(
                            Severity::Error,
                            ErrorCode::UndeclaredPackage,
                            format!("schema.haus imports {import}, but package.json doesn't declare it"),
                        )
                        .with_hint(format!(
                            "Add \"{import}\" to the peerDependencies of package.json (spec §13.3: npm then installs \
                             one copy for the application)."
                        )),
                        file,
                        None,
                    ),
                    (Wrapper::Npm, found) if found.iter().all(|dep| dep.field == "devDependencies") => self.report(
                        Diagnostic::new(
                            Severity::Error,
                            ErrorCode::UndeclaredPackage,
                            format!(
                                "schema.haus imports {import}, but package.json lists it only in devDependencies, \
                                 which aren't installed with the package"
                            ),
                        )
                        .with_hint(format!("Move \"{import}\" to the peerDependencies of package.json.")),
                        file,
                        found[0].span.clone().map(|span| (d.text.as_str(), span)),
                    ),
                    (Wrapper::Npm, found) if !found.iter().any(|dep| dep.field == "peerDependencies") => self.warn(
                        ErrorCode::UndeclaredPackage,
                        file,
                        found[0].span.clone().map(|span| (d.text.as_str(), span)),
                        format!(
                            "{import} is in the {} of package.json; a schema package should declare the packages it \
                             imports as peerDependencies",
                            found[0].field
                        ),
                        "Move it to peerDependencies, so that npm installs one copy for the whole application or \
                         reports a conflict when installing (spec §13.3).",
                    ),
                    (_, []) => {
                        let unknown: Vec<&str> = d
                            .deps
                            .iter()
                            .filter(|dep| dep.dir.is_none() && !dep.haus)
                            .map(|dep| dep.name.as_str())
                            .collect();
                        match unknown.is_empty() {
                            true => self.report(
                                Diagnostic::new(
                                    Severity::Error,
                                    ErrorCode::UndeclaredPackage,
                                    format!(
                                        "schema.haus imports {import}, but none of the dependencies in {file} is that \
                                         package"
                                    ),
                                )
                                .with_hint(format!("Add the package {import} to the dependencies in {file}.")),
                                file,
                                None,
                            ),
                            false => self.warn(
                                ErrorCode::UndeclaredPackage,
                                file,
                                None,
                                format!(
                                    "schema.haus imports {import}: {file} has no path dependency with that name, and \
                                     which package its other dependencies are ({}) can't be told from the files here",
                                    unknown.join(", ")
                                ),
                                "Check that one of them is the package, or build the package once, which checks it.",
                            ),
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    // ── profiles ────────────────────────────────────────────────

    /// The profiles' test vectors: `profiles/<name>.vectors.haus`, sorted.
    fn profile_files(&self) -> Vec<String> {
        let Ok(entries) = fs::read_dir(self.dir.join("profiles")) else { return vec![] };
        let mut files: Vec<String> = entries
            .filter_map(|e| e.ok()?.file_name().into_string().ok())
            .filter(|name| name.ends_with(".vectors.haus"))
            .map(|name| format!("profiles/{name}"))
            .collect();
        files.sort();
        files
    }

    /// A profile's vectors (each one as [`vector`] says), and its rule,
    /// `profiles/<name>.md`, next to them.
    fn vectors(&mut self, file: &str, schema: Option<&Schema>) {
        let path = self.dir.join(file);
        let profile = file.trim_start_matches("profiles/").trim_end_matches(".vectors.haus");
        if !is_package_name(&format!("@x/{profile}")) {
            self.error(
                ErrorCode::ProfileVectors,
                file,
                None,
                format!("{profile} is not a profile name: like a package name's parts, a-z, 0-9, -, . and _"),
                "Rename the file: profiles/<name>.vectors.haus, the name in lowercase.",
            );
        }
        let rule = format!("profiles/{profile}.md");
        if !self.dir.join(&rule).symlink_metadata().is_ok_and(|m| m.is_file()) {
            self.error(
                ErrorCode::ProfileVectors,
                file,
                None,
                format!("the profile {profile} has no rule: no {rule} next to its vectors"),
                "Write the rule in prose in profiles/<name>.md: a profile is defined by its rule, and the vectors \
                 are examples of it (spec §13.3).",
            );
        }
        let opened = match path.symlink_metadata() {
            Ok(meta) if !meta.is_file() => Err("it is a symbolic link or not a regular file".to_owned()),
            Ok(meta) if meta.len() > MAX_FILE => Err(format!("it has {} bytes, more than 1 MiB", meta.len())),
            Ok(_) => fs::File::open(&path).map_err(|e| e.to_string()),
            Err(e) => Err(e.to_string()),
        };
        let input = match opened {
            Ok(input) => input,
            Err(why) => {
                self.error(
                    ErrorCode::ProfileVectors,
                    file,
                    None,
                    format!("cannot read the profile's vectors: {why}"),
                    "Ship it as a regular file.",
                );
                return;
            }
        };
        let mut pieces = Pieces::new(input, haus::stream::Options::default());
        let mut vectors = 0;
        while let Some(piece) = pieces.next() {
            let piece = match piece {
                Ok(piece) => piece,
                Err(haus::Error::Syntax(e)) => {
                    let d = pieces.diagnostic(&e);
                    self.report(d, file, None);
                    return;
                }
                Err(e) => {
                    self.error(
                        ErrorCode::ProfileVectors,
                        file,
                        None,
                        format!("cannot read the profile's vectors: {e}"),
                        "Fix the file.",
                    );
                    return;
                }
            };
            for value in &piece.values {
                vectors += 1;
                if let Err(d) = vector(value, schema) {
                    self.report(piece.place(*d, value_span(&piece.text)), file, None);
                }
            }
        }
        if vectors == 0 {
            self.error(
                ErrorCode::ProfileVectors,
                file,
                None,
                "the profile has no vectors".into(),
                "Write values a codec of the profile accepts and rejects: Accept { type: \"T\", value: \"…\" }, \
                 Reject { type: \"T\", value: \"…\" }.",
            );
        }
    }

    // ── wrappers ────────────────────────────────────────────────

    /// A wrapper's text, if the package has it: a regular file (for
    /// `package.json`, spec §13.3), at most 1 MiB.
    fn read_wrapper(&mut self, wrapper: Wrapper) -> Option<String> {
        let file = wrapper.file();
        let path = self.dir.join(file);
        let meta = path.symlink_metadata().ok()?;
        let refused =
            |code, why: String| Some(Diagnostic::new(Severity::Error, code, format!("{file} {why}; it is not read")));
        let problem = match () {
            _ if meta.file_type().is_symlink() && wrapper == Wrapper::Npm => {
                refused(ErrorCode::PackagePath, "is a symbolic link".into())
            }
            _ if path.is_dir() => refused(ErrorCode::PackagePath, "is not a regular file".into()),
            _ if path.metadata().is_ok_and(|m| m.len() > MAX_FILE) => {
                refused(ErrorCode::FileTooLarge, "has more than 1 MiB".into())
            }
            _ => None,
        };
        if let Some(d) = problem {
            self.report(d, file, None);
            return None;
        }
        match fs::read_to_string(&path) {
            Ok(text) => Some(text),
            Err(e) => {
                self.error(ErrorCode::PackageWrapper, file, None, format!("cannot read {file}: {e}"), "Fix the file.");
                None
            }
        }
    }

    /// The version a wrapper gives the package equals the manifest's (`package-version`).
    fn same_version(
        &mut self,
        wrapper: Wrapper,
        manifest: Option<&Manifest>,
        version: &str,
        at: Option<(&str, Range<usize>)>,
    ) {
        let file = wrapper.file();
        if let Some(m) = manifest.filter(|m| m.version != version) {
            let message = format!("package.haus says version {}, {file} {version}", m.version);
            self.report(Diagnostic::new(Severity::Error, ErrorCode::PackageVersion, message), file, at);
        }
    }

    /// Each of the `required` files is shipped, as `ships` says; `how` says why one isn't.
    fn ships(&mut self, file: &str, required: &[String], how: &str, ships: impl Fn(&str) -> bool, hint: &str) {
        for path in required.iter().filter(|path| !ships(path)) {
            self.error(ErrorCode::PackageFiles, file, None, format!("{path} is not shipped: {how}"), hint);
        }
    }

    /// `package.json`: npm's name is the manifest's, so is the version; no
    /// install scripts; `files` ships the package's files.
    fn npm(&mut self, manifest: Option<&Manifest>, required: &[String]) -> Option<Declared> {
        let wrapper = Wrapper::Npm;
        let file = wrapper.file();
        let text = self.read_wrapper(wrapper)?;
        let json = match haus::json::parse(&text) {
            Ok(json @ Json::Object(_)) => json,
            Ok(_) => {
                self.error(
                    ErrorCode::PackageWrapper,
                    file,
                    None,
                    "package.json is not a JSON object".into(),
                    "Fix package.json.",
                );
                return None;
            }
            Err(e) => {
                let at = Some((text.as_str(), e.offset..e.offset));
                self.error(
                    ErrorCode::PackageWrapper,
                    file,
                    at,
                    format!("package.json is not valid JSON: {}", e.reason),
                    "Fix package.json.",
                );
                return None;
            }
        };
        let at = |key: &str| json_key(&text, key).map(|span| (text.as_str(), span));
        match (member(&json, "name"), manifest) {
            (Some(Json::String(name)), Some(m)) if *name != m.name => self.error(
                ErrorCode::PackageName,
                file,
                at("name"),
                format!("package.json names the package {name}, its package.haus {}", m.name),
                "On npm, a schema package is published under its manifest's name: make them the same.",
            ),
            (Some(Json::String(_)), _) => {}
            _ => self.error(
                ErrorCode::PackageWrapper,
                file,
                None,
                "package.json has no name".into(),
                "Give it the manifest's name: npm publishes the package under it, and imports find it by it.",
            ),
        }
        match member(&json, "version") {
            Some(Json::String(version)) => self.same_version(wrapper, manifest, version, at("version")),
            _ => self.report(
                Diagnostic::new(Severity::Error, ErrorCode::PackageVersion, "package.json has no version"),
                file,
                None,
            ),
        }
        if let Some(Json::Object(scripts)) = member(&json, "scripts") {
            for (script, _) in scripts.iter().filter(|(name, _)| INSTALL_SCRIPTS.contains(&name.as_str())) {
                self.error(
                    ErrorCode::PackageInstallScript,
                    file,
                    at(script),
                    format!("package.json has a {script} script: npm runs it when the package is installed"),
                    "Remove it: a schema package is data, and needs no code to install (spec §13.3).",
                );
            }
        }
        if self.dir.join("binding.gyp").exists() {
            self.error(
                ErrorCode::PackageInstallScript,
                "binding.gyp",
                None,
                "the package has a binding.gyp: npm runs node-gyp when the package is installed".into(),
                "Remove it: a schema package is data, and needs no code to install (spec §13.3).",
            );
        }
        let hint = "List package.haus, schema.haus and profiles (vectors and rules) in the files of package.json.";
        match member(&json, "files") {
            Some(Json::Array(files)) => {
                let patterns: Vec<String> = files
                    .iter()
                    .filter_map(|f| match f {
                        Json::String(f) => Some(f.trim_start_matches("./").to_owned()),
                        _ => None,
                    })
                    .collect();
                let dir = self.dir.to_owned();
                self.ships(
                    file,
                    required,
                    "the files of package.json don't include it",
                    |p| matched(&dir, &patterns, p) == Some(true),
                    hint,
                );
            }
            Some(_) => self.error(
                ErrorCode::PackageFiles,
                file,
                at("files"),
                "the files of package.json are not a list".into(),
                hint,
            ),
            None => {
                // Without files, npm ships what .npmignore (or else .gitignore) doesn't exclude.
                let ignore = [".npmignore", ".gitignore"].into_iter().find(|f| self.dir.join(f).is_file());
                if let Some(ignore) = ignore {
                    let patterns: Vec<String> = fs::read_to_string(self.dir.join(ignore))
                        .unwrap_or_default()
                        .lines()
                        .map(str::to_owned)
                        .collect();
                    let dir = self.dir.to_owned();
                    let how = format!("package.json has no files, and {ignore} excludes it");
                    self.ships(file, required, &how, |p| matched(&dir, &patterns, p) != Some(true), hint);
                }
            }
        }
        let mut deps = vec![];
        for field in NPM_FIELDS.into_iter().chain(["devDependencies"]) {
            if let Some(Json::Object(members)) = member(&json, field) {
                for (name, spec) in members {
                    let dir = match spec {
                        Json::String(spec) => spec
                            .strip_prefix("file:")
                            .or_else(|| spec.strip_prefix("link:"))
                            .map(|path| self.dir.join(path)),
                        _ => None,
                    };
                    let span = json_key(&text, name);
                    deps.push(Dep { name: name.clone(), span, dir, field, renames: None, haus: false });
                }
            }
        }
        Some(Declared { wrapper, text, deps })
    }

    /// `Cargo.toml`: the version is the manifest's, `links` is the library's
    /// name (generated code names the crate by it), `include` ships the
    /// package's files.
    fn cargo(&mut self, manifest: Option<&Manifest>, required: &[String]) -> Option<Declared> {
        let wrapper = Wrapper::Cargo;
        let file = wrapper.file();
        let text = self.read_wrapper(wrapper)?;
        let root = match DeTable::parse(&text) {
            Ok(root) => DeValue::Table(root.into_inner()),
            Err(e) => {
                let at = e.span().map(|span| (text.as_str(), span));
                self.error(
                    ErrorCode::PackageWrapper,
                    file,
                    at,
                    format!("Cargo.toml is not valid TOML: {}", e.message()),
                    "Fix Cargo.toml.",
                );
                return None;
            }
        };
        let Some(package) = get(&root, &["package"]) else {
            self.error(
                ErrorCode::PackageWrapper,
                file,
                None,
                "Cargo.toml has no [package]".into(),
                "A package crate is a [package].",
            );
            return None;
        };
        let at = |v: &toml::Spanned<DeValue>| Some((text.as_str(), v.span()));
        let name = get(package.get_ref(), &["name"]).and_then(|v| v.get_ref().as_str()).unwrap_or_default();
        let workspace = OnceWorkspace::default();
        match get(package.get_ref(), &["version"]) {
            Some(v) => match v.get_ref().as_str() {
                Some(version) => self.same_version(wrapper, manifest, version, at(v)),
                None => match workspace.get(self.dir).and_then(|ws| ws.str(&["workspace", "package", "version"])) {
                    Some(version) => self.same_version(wrapper, manifest, &version, at(v)),
                    None => self.warn(
                        ErrorCode::PackageVersion,
                        file,
                        at(v),
                        "the version of Cargo.toml can't be read here: it isn't a string, nor found in the workspace"
                            .into(),
                        "Give the version in Cargo.toml.",
                    ),
                },
            },
            // Cargo's default.
            None => self.same_version(wrapper, manifest, "0.0.0", at(package)),
        }
        let lib = get(&root, &["lib", "name"])
            .and_then(|v| v.get_ref().as_str().map(str::to_owned))
            .unwrap_or_else(|| name.replace('-', "_"));
        match get(package.get_ref(), &["links"]) {
            Some(links) if links.get_ref().as_str() == Some(&lib) => {}
            Some(links) => self.error(
                ErrorCode::PackageCrate,
                file,
                at(links),
                format!(
                    "links is {}, but the library is {lib}: crates that use the package's types name its crate by \
                     its links",
                    links.get_ref().as_str().map_or_else(|| "not a string".to_owned(), |l| format!("\"{l}\""))
                ),
                &format!("Set links = \"{lib}\", the library's name."),
            ),
            None => self.error(
                ErrorCode::PackageCrate,
                file,
                at(package),
                "Cargo.toml has no links: crates that depend on the package find its schema through it".into(),
                &format!("Add links = \"{lib}\" (the library's name) to [package]."),
            ),
        }
        let patterns = |key| -> Option<Vec<String>> {
            let list = get(package.get_ref(), &[key])?.get_ref().as_array()?;
            Some(list.iter().filter_map(|p| p.get_ref().as_str().map(str::to_owned)).collect())
        };
        let dir = self.dir.to_owned();
        let hint = "List package.haus, schema.haus and profiles (vectors and rules) in the include of Cargo.toml.";
        match (patterns("include"), patterns("exclude")) {
            (Some(include), _) => self.ships(
                file,
                required,
                "the include of Cargo.toml doesn't list it",
                |p| matched(&dir, &include, p) == Some(true),
                hint,
            ),
            (None, Some(exclude)) => self.ships(
                file,
                required,
                "the exclude of Cargo.toml lists it",
                |p| matched(&dir, &exclude, p) != Some(true),
                hint,
            ),
            (None, None) => {}
        }
        let deps = cargo_deps(&root, self.dir, &workspace);
        Some(Declared { wrapper, text, deps })
    }

    /// `pyproject.toml`, for a Python distribution (one with a `[project]`):
    /// the version is the manifest's, and the wheel ships the package's files
    /// (checked for hatchling).
    fn python(&mut self, manifest: Option<&Manifest>, required: &[String]) -> Option<Declared> {
        let wrapper = Wrapper::Python;
        let file = wrapper.file();
        let text = self.read_wrapper(wrapper)?;
        let root = match DeTable::parse(&text) {
            Ok(root) => DeValue::Table(root.into_inner()),
            Err(e) => {
                let at = e.span().map(|span| (text.as_str(), span));
                self.error(
                    ErrorCode::PackageWrapper,
                    file,
                    at,
                    format!("pyproject.toml is not valid TOML: {}", e.message()),
                    "Fix it.",
                );
                return None;
            }
        };
        // Tools' settings only: not a distribution.
        let project = get(&root, &["project"])?;
        let at = |v: &toml::Spanned<DeValue>| Some((text.as_str(), v.span()));
        let dynamic = |key: &str| strings(get(project.get_ref(), &["dynamic"])).iter().any(|d| d == key);
        match get(project.get_ref(), &["version"]) {
            Some(v) => match v.get_ref().as_str() {
                Some(version) => self.same_version(wrapper, manifest, version, at(v)),
                None => {
                    self.error(ErrorCode::PackageWrapper, file, at(v), "the version is not a string".into(), "Fix it.")
                }
            },
            None if dynamic("version") => self.warn(
                ErrorCode::PackageVersion,
                file,
                at(project),
                "the version is dynamic: whether it is package.haus's can't be told from the files".into(),
                "Write the version in [project], or check the built wheel's version yourself.",
            ),
            None => self.report(
                Diagnostic::new(Severity::Error, ErrorCode::PackageVersion, "pyproject.toml has no version"),
                file,
                at(project),
            ),
        }
        let backend = get(&root, &["build-system", "build-backend"]).and_then(|v| v.get_ref().as_str());
        match backend {
            Some("hatchling.build") => {
                let wheel = Hatch::new(&root);
                self.ships(
                    file,
                    required,
                    "the hatch configuration of the wheel doesn't include it",
                    |p| wheel.ships(self.dir, p),
                    "Add it to [tool.hatch.build.targets.wheel.force-include], inside the importable package: \
                     \"package.haus\" = \"<module>/package.haus\".",
                );
            }
            other => self.warn(
                ErrorCode::PackageFiles,
                file,
                get(&root, &["build-system"]).and_then(at),
                format!(
                    "which files the wheel ships can't be told from the files with the build backend {}",
                    other.unwrap_or("of setuptools (none given)")
                ),
                "Check that the wheel ships package.haus, schema.haus and the profiles, or use hatchling, whose \
                 configuration is checked.",
            ),
        }
        let deps = python_deps(&root, self.dir);
        Some(Declared { wrapper, text, deps })
    }
}

/// What a vector is (spec §13.3): `Accept { type, value, output?, note? }`
/// or `Reject { type, value, note? }`, the strings `value` and `output`
/// each one haus value. With the package's `schema` (None if it doesn't
/// load), `type` names one of its types without parameters, and an
/// accepted `value` and its `output` are valid for it, since codecs run
/// after the schema. The error, at the vector.
fn vector(value: &Value, schema: Option<&Schema>) -> Result<(), Box<Diagnostic>> {
    let plain = |message: String| {
        Box::new(Diagnostic::new(Severity::Error, ErrorCode::ProfileVectors, message).with_hint(
            "A vector is Accept { type: \"T\", value: \"…\", output: \"…\", note: \"…\" } or Reject { type: \"T\", \
             value: \"…\", note: \"…\" }: values as haus text for the package's type T; output and note optional.",
        ))
    };
    let (tag, fields) = match value {
        Value::Variant { tag, args } if tag == "Accept" || tag == "Reject" => match args.as_slice() {
            [Value::Record(fields)] => (tag.as_str(), fields),
            _ => return Err(plain(format!("{tag} has no record: {tag} {{ type: \"T\", value: \"…\" }}"))),
        },
        _ => return Err(plain("a vector is Accept { … } or Reject { … }".into())),
    };
    let allowed: &[&str] = match tag {
        "Accept" => &["type", "value", "output", "note"],
        _ => &["type", "value", "note"],
    };
    if let Some((key, _)) = fields.iter().find(|(key, _)| !allowed.contains(&key.as_str())) {
        return Err(plain(match key.as_str() {
            "output" => "only an Accept has an output: a rejected value encodes to nothing".to_owned(),
            key => format!("{tag} has an unknown field {key}: its fields are {}", allowed.join(", ")),
        }));
    }
    let string = |key: &str| match fields.iter().find(|(k, _)| k == key).map(|(_, v)| v) {
        Some(Value::String(s)) => Ok(Some(s.as_str())),
        Some(_) => Err(plain(format!("the {key} of {tag} is not a string"))),
        None => Ok(None),
    };
    string("note")?;
    let Some(type_name) = string("type")? else {
        return Err(plain(format!("{tag} has no type: the package's type its value is for")));
    };
    let Some(text) = string("value")? else {
        return Err(plain(format!("{tag} has no value: the value, as haus text")));
    };
    let output = string("output")?;
    let texts = [Some(("value", text)), output.map(|o| ("output", o))];
    for (key, text) in texts.iter().flatten() {
        match haus::parse(text) {
            Err(e) => {
                let message = format!(
                    "the {key} of {tag} is not valid haus: {} ({}, at {}:{})",
                    e.reason, e.code, e.line, e.column
                );
                let d = Diagnostic::new(Severity::Error, ErrorCode::ProfileVectors, message).with_hint(e.hint());
                return Err(Box::new(d));
            }
            Ok(values) if values.len() != 1 => {
                return Err(plain(format!("the {key} of {tag} is {} values, not one", values.len())));
            }
            Ok(_) => {}
        }
    }
    let Some(schema) = schema else { return Ok(()) };
    let types: Vec<&str> =
        schema.definitions().iter().filter(|d| d.params.is_empty()).map(|d| d.name.as_str()).collect();
    if !types.contains(&type_name) {
        let why = match schema.definitions().iter().any(|d| d.name == type_name) {
            true => "a type with parameters",
            false => "not a type of the package",
        };
        return Err(plain(format!("the type of {tag}, {type_name}, is {why}: one of {}", types.join(", "))));
    }
    if tag == "Accept" {
        for (key, text) in texts.iter().flatten() {
            let issues = schema.check_text_with(type_name, text, &Limits::default());
            if let Some(i) = issues.iter().find(|i| i.severity == haus_schema::Severity::Error) {
                let message = format!(
                    "the {key} of Accept is not a valid {type_name}: {} ({}, at {}); a codec runs after the schema, \
                     so it can't accept it",
                    i.message,
                    i.code,
                    i.path_string()
                );
                return Err(Box::new(Diagnostic::new(Severity::Error, ErrorCode::ProfileVectors, message).with_hint(
                    "Fix the value, or make it a Reject: profiles add rules to the schema, they don't relax it.",
                )));
            }
        }
    }
    Ok(())
}

/// Whether the gitignore-style `patterns` (npm's `files`, Cargo's `include`)
/// match `path` (relative to `dir`, `/`-separated) or a directory above it:
/// Some(true) if they do, Some(false) if a negation (`!x`) does, None if
/// none does.
fn matched(dir: &Path, patterns: &[String], path: &str) -> Option<bool> {
    let mut builder = GitignoreBuilder::new(dir);
    for pattern in patterns {
        // A pattern that isn't valid matches nothing.
        let _ = builder.add_line(None, pattern);
    }
    match builder.build().ok()?.matched_path_or_any_parents(path, false) {
        Match::Ignore(_) => Some(true),
        Match::Whitelist(_) => Some(false),
        Match::None => None,
    }
}

/// The value at `path` of the TOML table `v`.
fn get<'a, 'i>(v: &'a DeValue<'i>, path: &[&str]) -> Option<&'a toml::Spanned<DeValue<'i>>> {
    let (first, rest) = path.split_first()?;
    let found = v.get(*first)?;
    match rest {
        [] => Some(found),
        _ => get(found.get_ref(), rest),
    }
}

/// The strings of a TOML array.
fn strings(v: Option<&toml::Spanned<DeValue>>) -> Vec<String> {
    let Some(list) = v.and_then(|v| v.get_ref().as_array()) else { return vec![] };
    list.iter().filter_map(|s| s.get_ref().as_str().map(str::to_owned)).collect()
}

/// The member `key` of a JSON object: the last one, as `JSON.parse` keeps.
fn member<'a>(json: &'a Json, key: &str) -> Option<&'a Json> {
    match json {
        Json::Object(members) => members.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
        _ => None,
    }
}

/// Where `"key":` is in a JSON text (the first one), for excerpts.
fn json_key(text: &str, key: &str) -> Option<Range<usize>> {
    let quoted = haus::json::write(&Json::String(key.to_owned())).ok()?;
    text.match_indices(&quoted)
        .find(|(i, _)| text[i + quoted.len()..].trim_start().starts_with(':'))
        .map(|(i, _)| i..i + quoted.len())
}

/// The Cargo workspace above a package directory, read once if needed.
#[derive(Default)]
struct OnceWorkspace(std::cell::OnceCell<Option<Workspace>>);

/// A workspace's `Cargo.toml`: its directory and text.
struct Workspace {
    dir: PathBuf,
    text: String,
}

impl OnceWorkspace {
    /// The nearest `Cargo.toml` above `dir` with a `[workspace]`.
    fn get(&self, dir: &Path) -> Option<&Workspace> {
        self.0
            .get_or_init(|| {
                let dir = dir.canonicalize().ok()?;
                dir.ancestors().skip(1).find_map(|d| {
                    let text = fs::read_to_string(d.join("Cargo.toml")).ok()?;
                    let root = DeValue::Table(DeTable::parse(&text).ok()?.into_inner());
                    get(&root, &["workspace"]).is_some().then(|| Workspace { dir: d.to_owned(), text: text.clone() })
                })
            })
            .as_ref()
    }
}

impl Workspace {
    fn str(&self, path: &[&str]) -> Option<String> {
        let root = DeValue::Table(DeTable::parse(&self.text).ok()?.into_inner());
        get(&root, path)?.get_ref().as_str().map(str::to_owned)
    }

    /// `[workspace.dependencies]`'s entry `name`: its path (from the
    /// workspace's directory) and the crate it renames.
    fn dependency(&self, name: &str) -> (Option<PathBuf>, Option<String>) {
        let Ok(root) = DeTable::parse(&self.text).map(|t| DeValue::Table(t.into_inner())) else { return (None, None) };
        let entry = get(&root, &["workspace", "dependencies", name]);
        let field = |key| entry.and_then(|e| get(e.get_ref(), &[key])).and_then(|v| v.get_ref().as_str());
        (field("path").map(|p| self.dir.join(p)), field("package").map(str::to_owned))
    }
}

/// The dependencies of a `Cargo.toml` (`[dependencies]`, and the
/// `[target.….dependencies]`), with the directories of path dependencies.
fn cargo_deps(root: &DeValue, dir: &Path, workspace: &OnceWorkspace) -> Vec<Dep> {
    let targets = get(root, &["target"]).and_then(|t| t.get_ref().as_table());
    let tables = get(root, &["dependencies"])
        .into_iter()
        .chain(targets.into_iter().flat_map(|t| t.iter().filter_map(|(_, cfg)| get(cfg.get_ref(), &["dependencies"]))));
    let mut deps = vec![];
    for table in tables.filter_map(|t| t.get_ref().as_table()) {
        for (key, spec) in table.iter() {
            let name = key.get_ref().to_string();
            let field = |k| get(spec.get_ref(), &[k]).and_then(|v| v.get_ref().as_str());
            let inherited = get(spec.get_ref(), &["workspace"]).and_then(|v| v.get_ref().as_bool()) == Some(true);
            let (path, package) = match inherited {
                true => workspace.get(dir).map_or((None, None), |ws| ws.dependency(&name)),
                false => (field("path").map(|p| dir.join(p)), field("package").map(str::to_owned)),
            };
            let krate = package.clone().unwrap_or_else(|| name.clone());
            deps.push(Dep {
                span: Some(key.span()),
                dir: path,
                field: "dependencies",
                renames: package.filter(|p| *p != name),
                haus: HAUS_CRATES.contains(&krate.as_str()),
                name,
            });
        }
    }
    deps
}

/// The dependencies of a `pyproject.toml` (`[project] dependencies`), with
/// the directories of path sources (`[tool.uv.sources]`).
fn python_deps(root: &DeValue, dir: &Path) -> Vec<Dep> {
    let Some(list) = get(root, &["project", "dependencies"]).and_then(|v| v.get_ref().as_array()) else {
        return vec![];
    };
    let normal = |name: &str| name.to_ascii_lowercase().replace(['_', '.'], "-");
    let sources = get(root, &["tool", "uv", "sources"]).and_then(|v| v.get_ref().as_table());
    list.iter()
        .filter_map(|req| {
            let spec = req.get_ref().as_str()?;
            let end = spec.find(|c: char| !(c.is_ascii_alphanumeric() || "-_.".contains(c))).unwrap_or(spec.len());
            let name = spec[..end].to_owned();
            let source = sources.and_then(|s| s.iter().find(|(k, _)| normal(k.get_ref()) == normal(&name)));
            let path = source.and_then(|(_, v)| get(v.get_ref(), &["path"])?.get_ref().as_str().map(|p| dir.join(p)));
            Some(Dep {
                haus: normal(&name) == "haus-fmt",
                span: Some(req.span()),
                dir: path,
                field: "dependencies",
                renames: None,
                name,
            })
        })
        .collect()
}

/// What hatchling's wheel ships: `[tool.hatch.build.targets.wheel]`, else
/// `[tool.hatch.build]`.
struct Hatch {
    force_include: Vec<String>,
    only_include: Option<Vec<String>>,
    packages: Option<Vec<String>>,
    include: Option<Vec<String>>,
    exclude: Vec<String>,
}

impl Hatch {
    fn new(root: &DeValue) -> Hatch {
        let key = |k: &str| {
            get(root, &["tool", "hatch", "build", "targets", "wheel", k])
                .or_else(|| get(root, &["tool", "hatch", "build", k]))
        };
        let list = |k: &str| key(k).map(|v| strings(Some(v)));
        let force_include = key("force-include")
            .and_then(|v| v.get_ref().as_table())
            .map(|t| t.iter().map(|(k, _)| k.get_ref().trim_start_matches("./").to_owned()).collect())
            .unwrap_or_default();
        Hatch {
            force_include,
            only_include: list("only-include"),
            packages: list("packages"),
            include: list("include"),
            exclude: list("exclude").unwrap_or_default(),
        }
    }

    fn ships(&self, dir: &Path, path: &str) -> bool {
        let under = |dirs: &[String]| {
            dirs.iter()
                .map(|d| d.trim_start_matches("./").trim_end_matches('/'))
                .any(|d| path == d || path.strip_prefix(d).is_some_and(|rest| rest.starts_with('/')))
        };
        if under(&self.force_include) {
            return true;
        }
        let selected = self.only_include.as_deref().is_some_and(under)
            || self.packages.as_deref().is_some_and(under)
            || self.include.as_ref().is_some_and(|include| matched(dir, include, path) == Some(true));
        selected && matched(dir, &self.exclude, path) != Some(true)
    }
}

/// The packages imports are found in: those given, the path dependencies
/// of the package's wrappers that are schema packages, and theirs (so that
/// a package's dependencies find their own). Never node_modules (spec
/// §13.3: only implementations of the npm ecosystem look there). Explicit
/// packages count as declared: whether the package declares them is
/// checked for each wrapper.
fn packages(given: &Explicit, declared: &[Declared]) -> impl Locator + use<> {
    let mut explicit = given.clone();
    let mut queue: Vec<PathBuf> =
        declared.iter().flat_map(|d| d.deps.iter().filter_map(|dep| dep.dir.clone())).collect();
    let mut seen = HashSet::new();
    while let Some(dir) = queue.pop() {
        let Ok(real) = dir.canonicalize() else { continue };
        if seen.len() >= MAX_PACKAGES || !seen.insert(real.clone()) || !real.join(MANIFEST).exists() {
            continue;
        }
        // A package given explicitly wins over a path dependency with its name.
        if let Ok(more) = explicit.clone().package(&real) {
            explicit = more;
        }
        queue.extend(path_deps(&real));
    }
    explicit
}

/// A TOML document as a table, if it is valid.
fn parse_toml(text: &str) -> Option<DeValue<'_>> {
    DeTable::parse(text).ok().map(|t| DeValue::Table(t.into_inner()))
}

/// The directories of the path dependencies the wrappers in `dir` declare.
fn path_deps(dir: &Path) -> Vec<PathBuf> {
    let read = |file: &str| fs::read_to_string(dir.join(file)).ok();
    let mut deps: Vec<Dep> = vec![];
    if let Some(text) = read("Cargo.toml")
        && let Some(root) = parse_toml(&text)
    {
        deps.extend(cargo_deps(&root, dir, &OnceWorkspace::default()));
    }
    if let Some(text) = read("pyproject.toml")
        && let Some(root) = parse_toml(&text)
    {
        deps.extend(python_deps(&root, dir));
    }
    if let Some(json) = read("package.json").and_then(|text| haus::json::parse(&text).ok())
        && let Json::Object(json) = &json
    {
        let fields: BTreeMap<&str, &Json> = json.iter().map(|(k, v)| (k.as_str(), v)).collect();
        for field in NPM_FIELDS {
            if let Some(Json::Object(members)) = fields.get(field) {
                for (_, spec) in members {
                    if let Json::String(spec) = spec
                        && let Some(path) = spec.strip_prefix("file:").or_else(|| spec.strip_prefix("link:"))
                    {
                        deps.push(Dep {
                            name: String::new(),
                            span: None,
                            dir: Some(dir.join(path)),
                            field,
                            renames: None,
                            haus: false,
                        });
                    }
                }
            }
        }
    }
    deps.into_iter().filter_map(|d| d.dir).collect()
}
