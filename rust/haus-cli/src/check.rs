//! `haus check`: data files (syntax, then their schema) and schema files.
//! Standard input is checked value by value, so that `tail -f x.haus | haus
//! check -` reports each value as soon as it is complete.

use crate::cli::{CheckArgs, Color, PackageArgs};
use crate::diagnostic::{self, Diagnostic, Severity};
use crate::highlight::{Token, tokens};
use crate::input::{self, Target};
use crate::json::{self, Members, b, n, s};
use crate::official;
use crate::output::{self, Status, count};
use crate::pieces::{Piece, Pieces};
use annotate_snippets::Renderer;
use haus::json::Json;
use haus::{ErrorCode, Limits};
use haus_schema::rules::unchecked_rules;
use haus_schema::{CheckOptions, Explicit, MAX_ERRORS, Manifest, Options, Schema, StreamCheck};
use std::cell::OnceCell;
use std::collections::HashMap;
use std::io::{self, Read, stdout};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::rc::Rc;

/// What checking one file found.
struct Report {
    name: String,
    kind: Kind,
    /// The schema and type a data file was checked against: `order.schema.haus#Root`.
    schema: Option<String>,
    /// Why the file couldn't be read.
    error: Option<String>,
    diagnostics: Vec<Diagnostic>,
    /// The check stopped at the cap ([`MAX_ERRORS`]): the file may have more.
    stopped: bool,
}

#[derive(Clone, Copy)]
enum Kind {
    Data,
    Schema,
}

impl Report {
    fn new(name: String, kind: Kind) -> Report {
        Report { name, kind, schema: None, error: None, diagnostics: vec![], stopped: false }
    }

    fn errors(&self) -> usize {
        self.count(Severity::Error)
    }

    fn count(&self, severity: Severity) -> usize {
        self.diagnostics.iter().filter(|d| d.severity == severity).count()
    }

    fn ok(&self) -> bool {
        self.error.is_none() && self.errors() == 0
    }

    fn to_json(&self) -> Json {
        let mut m = Members::default();
        m.add("path", s(&self.name));
        m.add(
            "kind",
            s(match self.kind {
                Kind::Data => "data",
                Kind::Schema => "schema",
            }),
        );
        m.opt("schema", self.schema.as_deref().map(s));
        m.add("ok", b(self.ok()));
        m.opt("error", self.error.as_deref().map(s));
        m.add("diagnostics", Json::Array(self.diagnostics.iter().map(Diagnostic::to_json).collect()));
        // Only when it did, so that the document of a complete check stays as it was.
        m.opt("stopped", self.stopped.then(|| b(true)));
        m.into()
    }
}

/// What checking standard input shows as it goes.
enum Shown<'a> {
    Diagnostic(&'a Diagnostic),
    /// The check stopped at the cap, in the value starting on this line.
    Stopped(usize),
}

/// The note that a check stopped at the cap (spec §14, "Every error").
fn stopped_note(name: &str) -> String {
    format!("note: {name}: stopped after {MAX_ERRORS} errors; there may be more\n\n")
}

/// Where a data file's schema is.
struct SchemaRef {
    file: PathBuf,
    type_name: String,
}

struct Checker {
    limits: Limits,
    no_schema: bool,
    /// --first: stop at the first error of each data file.
    first: bool,
    /// The schema given with --schema.
    forced: Option<(PathBuf, String)>,
    /// Packages given with --package and --packages (never node_modules, spec §13.3).
    packages: Explicit,
    /// Schemas loaded so far, by canonical path.
    schemas: HashMap<PathBuf, Loaded>,
}

type Loaded = Result<Rc<Schema>, Rc<haus_schema::Error>>;

/// The schema and type data is checked against.
struct Checking {
    schema: Rc<Schema>,
    type_name: String,
}

impl Checking {
    /// Whether the type is a `Stream` (without parameters): checked item by item.
    fn stream(&self) -> bool {
        (self.schema.definition(&self.type_name))
            .is_some_and(|d| d.params.is_empty() && self.schema.instance(d.template).stream)
    }
}

pub fn run(args: &CheckArgs, color: Color) -> Status {
    let forced = match args.schema.as_deref().map(split_schema_arg) {
        Some((file, _)) if !file.is_file() => {
            let message = format!("--schema {}: no such file", output::shown(file));
            let hint = "Fix the path given with --schema.".into();
            return fail(args.json, Failure { code: ErrorCode::ImportNotFound, message, hint });
        }
        forced => forced,
    };
    let packages = match explicit(&args.packages) {
        Ok(packages) => packages,
        Err(failure) => return fail(args.json, failure),
    };
    let mut checker = Checker {
        limits: args.limits.limits(),
        no_schema: args.no_schema,
        first: args.first,
        forced,
        packages,
        schemas: HashMap::new(),
    };
    let targets = input::collect(&args.paths, input::is_haus);
    if !args.json {
        return text(&mut checker, &targets, &output::renderer(output::colored(color, &stdout())));
    }
    // One document: standard input is read to its end.
    let reports: Vec<Report> = targets.iter().map(|t| checker.check(t)).collect();
    let status = if reports.iter().any(|r| r.error.is_some()) {
        Status::Failed
    } else if reports.iter().any(|r| r.errors() > 0) {
        Status::Invalid
    } else {
        Status::Ok
    };
    match output::print(&(json::write(&to_json(&reports, None)) + "\n")) {
        Ok(()) => status,
        Err(e) => output::fail(e),
    }
}

/// Why nothing could be checked (exit code 2). With --json, the document
/// still comes, saying why.
fn fail(json: bool, failure: Failure) -> Status {
    match json {
        true => match output::print(&(json::write(&to_json(&[], Some(&failure))) + "\n")) {
            Ok(()) => Status::Failed,
            Err(e) => output::fail(e),
        },
        false => output::fail(failure.message),
    }
}

/// The packages of a check: the official ones, built in, then those given
/// with `--package [NAME=]DIR` and `--packages FOLDER` (packages.md §2,
/// "Tools": nothing is searched for).
pub(crate) fn explicit(args: &PackageArgs) -> Result<Explicit, Failure> {
    let given = |flag: &str, arg: &str, e: haus_schema::Error| Failure {
        code: diagnostic::schema_code(&e),
        message: format!("{flag} {arg}: {e}"),
        hint: e.hint().to_owned(),
    };
    let built_in = official::packages().into_iter().try_fold(Explicit::new(), Explicit::value);
    let built_in = built_in.map_err(|e| given("(built in)", "official packages", e))?;
    let explicit = args.package.iter().try_fold(built_in, |all, arg| {
        let named = arg.split_once('=').filter(|(name, _)| name.starts_with('@'));
        let (name, dir) = named.map_or((None, arg.as_str()), |(name, dir)| (Some(name), dir));
        let all = all.package(dir).map_err(|e| given("--package", arg, e))?;
        match (name, Manifest::read(Path::new(dir))) {
            (Some(name), Ok(manifest)) if manifest.name != name => Err(Failure {
                code: ErrorCode::ImportNotFound,
                message: format!("--package {arg}: its package.haus names the package {}, not {name}", manifest.name),
                hint: format!("Give the directory of {name}, or leave out {name}= to use the name its manifest gives."),
            }),
            _ => Ok(all),
        }
    })?;
    args.packages.iter().try_fold(explicit, |all, folder| {
        all.folder(folder).map_err(|e| given("--packages", &output::shown(folder), e))
    })
}

/// The text output, written as it is found: each file's diagnostics once it
/// is checked, standard input's as soon as their value is complete, and the
/// summary last. A closed output (`haus check - | head`) ends the check.
fn text(checker: &mut Checker, targets: &[Target], renderer: &Renderer) -> Status {
    let mut tally = Tally::default();
    let render = |d: &Diagnostic, name: &str| format!("{}\n\n", d.render(name, renderer));
    for target in targets {
        tally.files += 1;
        let name = target.name();
        let shown = match target {
            Target::Stdin => {
                let mut show = |shown: Shown| match shown {
                    Shown::Diagnostic(d) => {
                        tally.add(d);
                        output::write(&render(d, &name))
                    }
                    Shown::Stopped(line) => output::write(&stopped_note(&format!("{name}:{line}"))),
                };
                match checker.check_stream(io::stdin().lock(), &mut show) {
                    Ok(Some(e)) => {
                        tally.unreadable += 1;
                        output::write(&format!("error: cannot read {name}: {e}\n\n"))
                    }
                    shown => shown.map(drop),
                }
            }
            _ => {
                let report = checker.check(target);
                let mut out = String::new();
                if let Some(e) = &report.error {
                    tally.unreadable += 1;
                    out.push_str(&format!("error: cannot read {name}: {e}\n\n"));
                }
                for d in &report.diagnostics {
                    tally.add(d);
                    out.push_str(&render(d, &name));
                }
                if report.stopped {
                    out.push_str(&stopped_note(&name));
                }
                output::write(&out)
            }
        };
        match shown {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::BrokenPipe => return tally.status(),
            Err(e) => return output::fail(e),
        }
    }
    match output::write(&tally.summary()) {
        Err(e) if e.kind() != io::ErrorKind::BrokenPipe => output::fail(e),
        _ => tally.status(),
    }
}

/// What the text output has shown so far.
#[derive(Default)]
struct Tally {
    files: usize,
    errors: usize,
    warnings: usize,
    hints: usize,
    unreadable: usize,
}

impl Tally {
    fn add(&mut self, d: &Diagnostic) {
        match d.severity {
            Severity::Error => self.errors += 1,
            Severity::Warning => self.warnings += 1,
            Severity::Hint => self.hints += 1,
        }
    }

    fn status(&self) -> Status {
        match (self.unreadable, self.errors) {
            (0, 0) => Status::Ok,
            (0, _) => Status::Invalid,
            _ => Status::Failed,
        }
    }

    /// `Checked 2 files: 1 error, 1 hint.`
    fn summary(&self) -> String {
        let found: Vec<String> = [
            (self.errors, "error"),
            (self.warnings, "warning"),
            (self.hints, "hint"),
            (self.unreadable, "unreadable file"),
        ]
        .into_iter()
        .filter(|&(n, _)| n > 0)
        .map(|(n, noun)| count(n, noun))
        .collect();
        let found = if found.is_empty() { "no problems".to_owned() } else { found.join(", ") };
        format!("Checked {}: {found}.\n", count(self.files, "file"))
    }
}

/// `--schema order.schema.haus#Order`: the file and the type (default `Root`).
fn split_schema_arg(arg: &str) -> (PathBuf, String) {
    match arg.rsplit_once('#') {
        Some((file, ty)) if ty.starts_with(|c: char| c.is_ascii_uppercase()) => (file.into(), ty.into()),
        _ => (arg.into(), "Root".into()),
    }
}

impl Checker {
    fn check(&mut self, target: &Target) -> Report {
        let kind = if target.is_schema() { Kind::Schema } else { Kind::Data };
        let mut report = Report::new(target.name(), kind);
        let bytes = match target.read() {
            Ok(bytes) => bytes,
            Err(e) => return Report { error: Some(e.to_string()), ..report },
        };
        match (kind, target) {
            (Kind::Schema, Target::File(path)) => report.diagnostics = self.check_schema(path, &bytes),
            _ => {
                let adjacent = match target {
                    Target::File(path) => adjacent_schema(path),
                    _ => None,
                };
                (report.schema, report.diagnostics, report.stopped) = self.check_data(adjacent, &bytes);
            }
        }
        report
    }

    /// A schema file: its errors, or its warnings, and a note at each import
    /// of a package with a rule the schema reaches that this tool doesn't
    /// check: one that isn't official (`missing-codec`, packages.md §7, "Tools").
    fn check_schema(&mut self, path: &Path, bytes: &[u8]) -> Vec<Diagnostic> {
        let text = String::from_utf8_lossy(bytes);
        match self.load(path) {
            Err(e) => vec![Diagnostic::schema(&e, Severity::Error, Some(&text))],
            // Shown in the text the schema was loaded from.
            Ok(schema) => {
                let text = &schema.files()[0].text;
                let warnings = schema.warnings().iter().map(|w| Diagnostic::schema(w, Severity::Warning, Some(text)));
                let notes = unchecked_rules(text, &schema)
                    .into_iter()
                    .map(|n| Diagnostic::schema(&n, Severity::Hint, Some(text)));
                let mut all: Vec<Diagnostic> = warnings.chain(notes).collect();
                // In the order of their places (a stable sort: warnings first at one place).
                all.sort_by_key(|d| d.position);
                all
            }
        }
    }

    fn options(&self) -> CheckOptions {
        CheckOptions { first: self.first, limits: self.limits }
    }

    /// A data file: syntax errors, then what its schema finds, and whether
    /// that stopped at the cap. A `Stream` is checked item by item: a syntax
    /// error ends its check, after the issues of the items before it.
    fn check_data(&mut self, adjacent: Option<PathBuf>, bytes: &[u8]) -> (Option<String>, Vec<Diagnostic>, bool) {
        let text = match diagnostic::utf8(bytes) {
            Ok(text) => text,
            Err(d) => return (None, vec![*d], false),
        };
        let syntax = haus::parse_with(text, &self.limits).err();
        match (syntax, self.checking(adjacent)) {
            (Some(e), checking) if !matches!(&checking, Some((_, Ok(c))) if c.stream()) => {
                (None, vec![Diagnostic::syntax(&e, Some(text))], false)
            }
            (_, None) => (None, vec![], false),
            (_, Some((label, Err(diagnostics)))) => (Some(label), diagnostics, false),
            (_, Some((label, Ok(c)))) => {
                let report = c.schema.check_text_report(&c.type_name, text, &self.options());
                let diagnostics = (report.issues.iter())
                    .map(|i| match i.syntax() {
                        Some(e) => Diagnostic::syntax(e, Some(text)),
                        None => Diagnostic::issue(i, text),
                    })
                    .collect();
                (Some(label), diagnostics, report.stopped)
            }
        }
    }

    /// What a data file is checked against, and its label
    /// (`order.schema.haus#Root`); or, if it has a schema that can't be
    /// used, why. None: no schema.
    fn checking(&mut self, adjacent: Option<PathBuf>) -> Option<(String, Result<Checking, Vec<Diagnostic>>)> {
        let r = self.schema_for(adjacent)?;
        let label = format!("{}#{}", output::shown(&r.file), r.type_name);
        let checking = match self.load(&r.file) {
            Err(e) if e.position().is_some() => {
                let schema_text = std::fs::read_to_string(&r.file).ok();
                Err(vec![
                    Diagnostic::schema(&e, Severity::Error, schema_text.as_deref()).in_file(output::shown(&r.file)),
                ])
            }
            Err(e) => {
                let message = match r.file.exists() {
                    false => format!("the schema {} does not exist", output::shown(&r.file)),
                    true => format!("cannot load the schema {}: {}", output::shown(&r.file), e.reason()),
                };
                Err(vec![Diagnostic::new(Severity::Error, diagnostic::schema_code(&e), message)])
            }
            Ok(schema) if schema.definition(&r.type_name).is_none() => {
                let message = format!("the schema {} has no type {}", output::shown(&r.file), r.type_name);
                Err(vec![Diagnostic::new(Severity::Error, ErrorCode::UnknownType, message)])
            }
            Ok(schema) => Ok(Checking { schema, type_name: r.type_name }),
        };
        Some((label, checking))
    }

    /// Standard input, value by value: `show` gets each diagnostic as soon
    /// as its value is complete, with its place in the whole stream. Its
    /// schema is the one given with --schema, loaded once the first value
    /// is complete. A `Stream` type checks each value as it arrives, with one
    /// cap on errors for the whole stream (spec §14, "Every error"); a type
    /// that isn't one gets the first value, and an error at the second.
    /// `stopped` is told when the check stopped at the cap (at the line of
    /// the value it stopped in). Returns why the input couldn't be read, if
    /// it couldn't; fails if `show` does.
    fn check_stream(
        &mut self,
        input: impl Read,
        show: &mut dyn FnMut(Shown) -> io::Result<()>,
    ) -> io::Result<Option<String>> {
        let options = haus::stream::Options { limits: self.limits, ..Default::default() };
        let mut pieces = Pieces::new(input, options);
        // Found at the first value: what the stream is checked against, if anything.
        let found: OnceCell<Option<Checking>> = OnceCell::new();
        // For a Stream type: its values' check, one for the whole stream.
        let mut stream: Option<StreamCheck> = None;
        // Whether values are still checked (not after an error that ends the checks).
        let mut checking = true;
        let mut seen = 0;
        while let Some(piece) = pieces.next() {
            let piece = match piece {
                Ok(piece) => piece,
                Err(haus::Error::Syntax(e)) => {
                    show(Shown::Diagnostic(&pieces.diagnostic(&e)))?;
                    break;
                }
                Err(e) => return Ok(Some(e.to_string())),
            };
            if found.get().is_none() {
                let (c, diagnostics) = match self.checking(None) {
                    Some((_, Ok(c))) => (Some(c), vec![]),
                    Some((_, Err(diagnostics))) => (None, diagnostics),
                    None => (None, vec![]),
                };
                diagnostics.iter().try_for_each(|d| show(Shown::Diagnostic(d)))?;
                let c = found.get_or_init(|| c).as_ref();
                checking = c.is_some();
                stream =
                    c.filter(|c| c.stream()).and_then(|c| c.schema.check_stream(&c.type_name, &self.options()).ok());
            }
            match (found.get(), stream.as_mut()) {
                (_, _) if !checking => {}
                (_, Some(s)) => {
                    let diagnostics: Vec<Diagnostic> = (piece.values.iter())
                        .flat_map(|v| s.check_text(v, &piece.text))
                        .map(|i| {
                            let span = i.span.clone().unwrap_or(0..0);
                            piece.place(Diagnostic::issue(&i, &piece.text), span)
                        })
                        .collect();
                    diagnostics.iter().try_for_each(|d| show(Shown::Diagnostic(d)))?;
                    if s.done() {
                        if s.stopped() {
                            show(Shown::Stopped(piece.line))?;
                        }
                        checking = false;
                    }
                }
                (Some(Some(c)), None) => {
                    let (diagnostics, more, stopped) = self.check_piece(c, &piece, seen);
                    diagnostics.iter().try_for_each(|d| show(Shown::Diagnostic(d)))?;
                    if stopped {
                        show(Shown::Stopped(piece.line))?;
                    }
                    // --first: the first error ends the checks.
                    let failed = diagnostics.iter().any(|d| d.severity == Severity::Error);
                    checking = more && !(self.first && failed);
                }
                _ => {}
            }
            seen += piece.values.len();
        }
        Ok(None)
    }

    /// What the schema finds in a value of a stream whose type isn't a
    /// `Stream` (or has parameters), after `seen` others; whether the values
    /// after it are still to be checked; and whether its check stopped at the cap.
    fn check_piece(&self, c: &Checking, piece: &Piece, seen: usize) -> (Vec<Diagnostic>, bool, bool) {
        let Some(def) = c.schema.definition(&c.type_name) else { return (vec![], false, false) };
        // A type with parameters can't describe a whole file: said once, at the first value.
        let more = def.params.is_empty() && seen == 0;
        if piece.values.is_empty() && seen > 0 {
            return (vec![], more, false);
        }
        if seen > 0 {
            let message = format!("expected one value ({} is not a Stream), found more than one", c.type_name);
            let mut d = Diagnostic::new(Severity::Error, ErrorCode::NotOneValue, message);
            d.path = Some("$".to_owned());
            return (vec![piece.place(d, value_span(&piece.text))], false, false);
        }
        let report = c.schema.check_text_report(&c.type_name, &piece.text, &self.options());
        let diagnostics = report
            .issues
            .into_iter()
            .map(|i| {
                let span = i.span.clone().unwrap_or(0..0);
                piece.place(Diagnostic::issue(&i, &piece.text), span)
            })
            .collect();
        (diagnostics, more, report.stopped)
    }

    /// The schema of a data file: --schema, else `x.schema.haus` next to
    /// `x.haus` (`adjacent`, if it exists). The reader decides: a data file
    /// never names its schema (spec §14).
    fn schema_for(&self, adjacent: Option<PathBuf>) -> Option<SchemaRef> {
        if self.no_schema {
            return None;
        }
        if let Some((file, type_name)) = &self.forced {
            return Some(SchemaRef { file: file.clone(), type_name: type_name.clone() });
        }
        adjacent.map(|file| SchemaRef { file, type_name: "Root".into() })
    }

    /// The schema file at `path`, loaded once.
    fn load(&mut self, path: &Path) -> Loaded {
        let key = path.canonicalize().unwrap_or_else(|_| path.to_owned());
        // The official rules are checked; others are pointed out (packages.md §7, "Tools").
        let rules = official::rules();
        let options = Options { packages: &self.packages, rules: &rules, require_rules: false, ..Options::default() };
        let load = || Schema::load_with(path, &options).map(Rc::new).map_err(Rc::new);
        self.schemas.entry(key).or_insert_with(load).clone()
    }
}

/// Where the value is in a value's `text`, without the whitespace and
/// comments around it.
pub(crate) fn value_span(text: &str) -> Range<usize> {
    let solid: Vec<Range<usize>> = tokens(text)
        .into_iter()
        .filter(|(token, range)| *token != Token::Comment && !text[range.clone()].trim().is_empty())
        .map(|(_, range)| range)
        .collect();
    match (solid.first(), solid.last()) {
        (Some(first), Some(last)) => {
            let start = first.start + (text[first.clone()].len() - text[first.clone()].trim_start().len());
            let end = last.end - (text[last.clone()].len() - text[last.clone()].trim_end().len());
            start..end
        }
        _ => 0..0,
    }
}

/// `x.schema.haus` next to the data file `x.haus`, if there is one.
fn adjacent_schema(path: &Path) -> Option<PathBuf> {
    let stem = path.file_name()?.to_str()?.strip_suffix(".haus")?;
    Some(path.with_file_name(format!("{stem}.schema.haus"))).filter(|p| p.is_file())
}

/// Why a check couldn't run at all (exit code 2): with --json, the
/// document's top-level `error`, in the error form of spec §17.
pub(crate) struct Failure {
    pub code: ErrorCode,
    pub message: String,
    pub hint: String,
}

impl Failure {
    pub fn to_json(&self) -> Json {
        let mut m = Members::default();
        m.add("code", s(self.code.as_str()));
        m.add("message", s(&self.message));
        m.add("hint", s(&self.hint));
        m.add("docs", s(&self.code.docs()));
        m.into()
    }
}

/// The --json document: `ok`, then `error` if the check couldn't run, the files and the summary.
fn to_json(reports: &[Report], failure: Option<&Failure>) -> Json {
    let ok = failure.is_none() && reports.iter().all(Report::ok);
    let total = |f: fn(&Report) -> usize| reports.iter().map(f).sum::<usize>();
    let mut summary = Members::default();
    summary.add("files", n(reports.len()));
    summary.add("errors", n(total(Report::errors)));
    summary.add("warnings", n(total(|r| r.count(Severity::Warning))));
    summary.add("hints", n(total(|r| r.count(Severity::Hint))));
    summary.add("unreadable", n(reports.iter().filter(|r| r.error.is_some()).count()));
    let mut m = Members::default();
    m.add("ok", b(ok));
    m.opt("error", failure.map(Failure::to_json));
    m.add("files", Json::Array(reports.iter().map(Report::to_json).collect()));
    m.add("summary", summary.into());
    m.into()
}
