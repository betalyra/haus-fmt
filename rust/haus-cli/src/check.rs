//! `haus check`: data files (syntax, then their schema) and schema files.
//! Standard input is checked value by value, so that `tail -f x.haus | haus
//! check -` reports each value as soon as it is complete.

use crate::cli::{CheckArgs, Color};
use crate::diagnostic::{self, Diagnostic, Severity};
use crate::highlight::{Token, tokens};
use crate::input::{self, Target};
use crate::json::{self, Members, b, n, s};
use crate::output::{self, Status, count};
use crate::pieces::{Piece, Pieces};
use annotate_snippets::Renderer;
use haus::json::Json;
use haus::{ErrorCode, Limits};
use haus_schema::{FileResolver, Schema, Segment};
use std::collections::HashMap;
use std::io::{self, Read, stdout};
use std::ops::Range;
use std::path::{Component, Path, PathBuf};
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
}

#[derive(Clone, Copy)]
enum Kind {
    Data,
    Schema,
}

impl Report {
    fn new(name: String, kind: Kind) -> Report {
        Report { name, kind, schema: None, error: None, diagnostics: vec![] }
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
        m.into()
    }
}

/// Where a data file's schema is.
struct SchemaRef {
    file: PathBuf,
    type_name: String,
    /// Where the `// schema:` comment names it, if it does.
    comment: Option<Range<usize>>,
}

struct Checker {
    limits: Limits,
    no_schema: bool,
    /// The schema given with --schema.
    forced: Option<(PathBuf, String)>,
    /// Schemas loaded so far, by canonical path.
    schemas: HashMap<PathBuf, Loaded>,
}

type Loaded = Result<Rc<Schema>, Rc<haus_schema::Error>>;

/// The schema and type data is checked against.
struct Checking {
    schema: Rc<Schema>,
    type_name: String,
}

pub fn run(args: &CheckArgs, color: Color) -> Status {
    let forced = match args.schema.as_deref().map(split_schema_arg) {
        Some((file, _)) if !file.is_file() => {
            let message = format!("--schema {}: no such file", file.display());
            let failure =
                Failure { code: ErrorCode::ImportNotFound, message, hint: "Fix the path given with --schema." };
            return match args.json {
                // With --json, the document still comes, saying why nothing was checked.
                true => match output::print(&(json::write(&to_json(&[], Some(&failure))) + "\n")) {
                    Ok(()) => Status::Failed,
                    Err(e) => output::fail(e),
                },
                false => output::fail(failure.message),
            };
        }
        forced => forced,
    };
    let mut checker =
        Checker { limits: args.limits.limits(), no_schema: args.no_schema, forced, schemas: HashMap::new() };
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
                let mut show = |d: &Diagnostic| {
                    tally.add(d);
                    output::write(&render(d, &name))
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
                let dir = match target {
                    Target::File(path) => path.parent().unwrap_or(Path::new("")).to_owned(),
                    _ => PathBuf::new(),
                };
                let adjacent = match target {
                    Target::File(path) => adjacent_schema(path),
                    _ => None,
                };
                (report.schema, report.diagnostics) = self.check_data(&dir, adjacent, &bytes);
            }
        }
        report
    }

    /// A schema file: its errors, or its warnings.
    fn check_schema(&mut self, path: &Path, bytes: &[u8]) -> Vec<Diagnostic> {
        let text = String::from_utf8_lossy(bytes);
        match self.load(path) {
            Err(e) => vec![Diagnostic::schema(&e, Severity::Error, Some(&text))],
            Ok(schema) => {
                schema.warnings().iter().map(|w| Diagnostic::schema(w, Severity::Warning, Some(&text))).collect()
            }
        }
    }

    /// A data file in `dir`: syntax errors, then what its schema finds.
    fn check_data(&mut self, dir: &Path, adjacent: Option<PathBuf>, bytes: &[u8]) -> (Option<String>, Vec<Diagnostic>) {
        let text = match diagnostic::utf8(bytes) {
            Ok(text) => text,
            Err(d) => return (None, vec![*d]),
        };
        if let Err(e) = haus::parse_with(text, &self.limits) {
            return (None, vec![Diagnostic::syntax(&e, Some(text))]);
        }
        match self.checking(dir, adjacent, text) {
            None => (None, vec![]),
            Some((label, Err(diagnostics))) => (Some(label), diagnostics),
            Some((label, Ok(c))) => {
                let issues = c.schema.check_text_with(&c.type_name, text, &self.limits);
                (Some(label), issues.iter().map(|i| Diagnostic::issue(i, text)).collect())
            }
        }
    }

    /// What a data file in `dir` whose text is (or starts with) `text` is
    /// checked against, and its label (`order.schema.haus#Root`); or, if it
    /// has a schema that can't be used, why. None: no schema.
    fn checking(
        &mut self,
        dir: &Path,
        adjacent: Option<PathBuf>,
        text: &str,
    ) -> Option<(String, Result<Checking, Vec<Diagnostic>>)> {
        let r = self.schema_for(dir, adjacent, text)?;
        let label = format!("{}#{}", r.file.display(), r.type_name);
        let place = |d: Diagnostic| match &r.comment {
            Some(span) => d.at(text, span.clone()),
            None => d,
        };
        let checking = match self.load(&r.file) {
            Err(e) if e.position().is_some() => {
                let schema_text = std::fs::read_to_string(&r.file).ok();
                Err(vec![
                    Diagnostic::schema(&e, Severity::Error, schema_text.as_deref())
                        .in_file(r.file.display().to_string()),
                ])
            }
            Err(e) => {
                let message = match r.file.exists() {
                    false => format!("the schema {} does not exist", r.file.display()),
                    true => format!("cannot load the schema {}: {}", r.file.display(), e.reason()),
                };
                Err(vec![place(Diagnostic::new(Severity::Error, e.code(), message))])
            }
            Ok(schema) if schema.definition(&r.type_name).is_none() => {
                let message = format!("the schema {} has no type {}", r.file.display(), r.type_name);
                Err(vec![place(Diagnostic::new(Severity::Error, ErrorCode::UnknownType, message))])
            }
            Ok(schema) => Ok(Checking { schema, type_name: r.type_name }),
        };
        Some((label, checking))
    }

    /// Standard input, value by value: `show` gets each diagnostic as soon
    /// as its value is complete, with its place in the whole stream. Its
    /// schema is found as a file's (--schema, or the `// schema:` comment at
    /// the top), once the first value is complete. A type that isn't a
    /// `Stream` gets the first value, and an error at the second. Returns
    /// why the input couldn't be read, if it couldn't; fails if `show` does.
    fn check_stream(
        &mut self,
        input: impl Read,
        show: &mut dyn FnMut(&Diagnostic) -> io::Result<()>,
    ) -> io::Result<Option<String>> {
        let options = haus::stream::Options { limits: self.limits, ..Default::default() };
        let mut pieces = Pieces::new(input, options);
        // Found at the first value; then None if there is none, or after an error that ends the checks.
        let mut checking: Option<Option<Checking>> = None;
        let mut seen = 0;
        while let Some(piece) = pieces.next() {
            let piece = match piece {
                Ok(piece) => piece,
                Err(haus::Error::Syntax(e)) => {
                    show(&pieces.diagnostic(&e))?;
                    break;
                }
                Err(e) => return Ok(Some(e.to_string())),
            };
            if checking.is_none() {
                let (found, diagnostics) = match self.checking(Path::new(""), None, &piece.text) {
                    Some((_, Ok(c))) => (Some(c), vec![]),
                    Some((_, Err(diagnostics))) => (None, diagnostics),
                    None => (None, vec![]),
                };
                diagnostics.iter().try_for_each(&mut *show)?;
                checking = Some(found);
            }
            if let Some(Some(c)) = &checking {
                let (diagnostics, more) = self.check_piece(c, &piece, seen);
                diagnostics.iter().try_for_each(&mut *show)?;
                if !more {
                    checking = Some(None);
                }
            }
            seen += piece.values.len();
        }
        Ok(None)
    }

    /// What the schema finds in a value of the stream, after `seen` others;
    /// and whether the values after it are still to be checked.
    fn check_piece(&self, c: &Checking, piece: &Piece, seen: usize) -> (Vec<Diagnostic>, bool) {
        let Some(def) = c.schema.definition(&c.type_name) else { return (vec![], false) };
        let stream = c.schema.instance(def.template).stream;
        // A type with parameters can't describe a whole file: said once, at the first value.
        let more = def.params.is_empty() && (stream || seen == 0);
        if piece.values.is_empty() && seen > 0 {
            return (vec![], more);
        }
        if !stream && seen > 0 {
            let message = format!("expected one value ({} is not a Stream), found more than one", c.type_name);
            let mut d = Diagnostic::new(Severity::Error, ErrorCode::NotOneValue, message);
            d.path = Some("$".to_owned());
            return (vec![piece.place(d, value_span(&piece.text))], false);
        }
        let diagnostics = c
            .schema
            .check_text_with(&c.type_name, &piece.text, &self.limits)
            .into_iter()
            .map(|mut i| {
                if let (true, Some(Segment::Index(j))) = (stream, i.path.first_mut()) {
                    *j += seen;
                }
                let span = i.span.clone().unwrap_or(0..0);
                piece.place(Diagnostic::issue(&i, &piece.text), span)
            })
            .collect();
        (diagnostics, more)
    }

    /// The schema of a data file in `dir`: --schema, else the `// schema:`
    /// comment, else `x.schema.haus` next to `x.haus` (`adjacent`, if it exists).
    fn schema_for(&self, dir: &Path, adjacent: Option<PathBuf>, text: &str) -> Option<SchemaRef> {
        if self.no_schema {
            return None;
        }
        if let Some((file, type_name)) = &self.forced {
            return Some(SchemaRef { file: file.clone(), type_name: type_name.clone(), comment: None });
        }
        if let Some(r) = haus_schema::schema_reference(text) {
            let file = normalize(&dir.join(&r.path));
            return Some(SchemaRef { file, type_name: r.type_name, comment: Some(r.span) });
        }
        adjacent.map(|file| SchemaRef { file, type_name: "Root".into(), comment: None })
    }

    /// The schema file at `path`, loaded once.
    fn load(&mut self, path: &Path) -> Loaded {
        let key = path.canonicalize().unwrap_or_else(|_| path.to_owned());
        let load = || Schema::load(path, &FileResolver::new()).map(Rc::new).map_err(Rc::new);
        self.schemas.entry(key).or_insert_with(load).clone()
    }
}

/// Where the value is in a value's `text`, without the whitespace and
/// comments around it.
fn value_span(text: &str) -> Range<usize> {
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

/// `dir/./order.schema.haus` as `dir/order.schema.haus`.
fn normalize(path: &Path) -> PathBuf {
    let mut out: PathBuf = path.components().filter(|c| *c != Component::CurDir).collect();
    if out.as_os_str().is_empty() {
        out.push(".");
    }
    out
}

/// Why a check couldn't run at all (exit code 2): with --json, the
/// document's top-level `error`, in the error form of spec §17.
struct Failure {
    code: ErrorCode,
    message: String,
    hint: &'static str,
}

impl Failure {
    fn to_json(&self) -> Json {
        let mut m = Members::default();
        m.add("code", s(self.code.as_str()));
        m.add("message", s(&self.message));
        m.add("hint", s(self.hint));
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
