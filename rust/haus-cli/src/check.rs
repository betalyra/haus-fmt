//! `haus check`: data files (syntax, then their schema) and schema files.

use crate::cli::{CheckArgs, Color};
use crate::diagnostic::{self, Diagnostic, Severity};
use crate::input::{self, Target};
use crate::json::{self, Members, b, n, s};
use crate::output::{self, Status, count};
use haus::json::Json;
use haus::{ErrorCode, Limits};
use haus_schema::{FileResolver, Schema};
use std::collections::HashMap;
use std::io::stdout;
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
    schemas: HashMap<PathBuf, Rc<Result<Schema, haus_schema::Error>>>,
}

pub fn run(args: &CheckArgs, color: Color) -> Status {
    let forced = match args.schema.as_deref().map(split_schema_arg) {
        Some((file, _)) if !file.is_file() => {
            return output::fail(format!("--schema {}: no such file", file.display()));
        }
        forced => forced,
    };
    let mut checker =
        Checker { limits: args.limits.limits(), no_schema: args.no_schema, forced, schemas: HashMap::new() };
    let reports: Vec<Report> = input::collect(&args.paths, input::is_haus).iter().map(|t| checker.check(t)).collect();
    let status = if reports.iter().any(|r| r.error.is_some()) {
        Status::Failed
    } else if reports.iter().any(|r| r.errors() > 0) {
        Status::Invalid
    } else {
        Status::Ok
    };
    let text = if args.json {
        json::write(&to_json(&reports, status)) + "\n"
    } else {
        human(&reports, output::colored(color, &stdout()))
    };
    match output::print(&text) {
        Ok(()) => status,
        Err(e) => output::fail(e),
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
        match &*self.load(path) {
            Err(e) => vec![Diagnostic::schema(e, Severity::Error, Some(&text))],
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
        let Some(r) = self.schema_for(dir, adjacent, text) else { return (None, vec![]) };
        let label = format!("{}#{}", r.file.display(), r.type_name);
        let place = |d: Diagnostic| match &r.comment {
            Some(span) => d.at(text, span.clone()),
            None => d,
        };
        let diagnostics = match &*self.load(&r.file) {
            Err(e) if e.position().is_some() => {
                let schema_text = std::fs::read_to_string(&r.file).ok();
                vec![
                    Diagnostic::schema(e, Severity::Error, schema_text.as_deref())
                        .in_file(r.file.display().to_string()),
                ]
            }
            Err(e) => {
                let message = match r.file.exists() {
                    false => format!("the schema {} does not exist", r.file.display()),
                    true => format!("cannot load the schema {}: {}", r.file.display(), e.reason()),
                };
                vec![place(Diagnostic::new(Severity::Error, e.code(), message))]
            }
            Ok(schema) if schema.definition(&r.type_name).is_none() => {
                let message = format!("the schema {} has no type {}", r.file.display(), r.type_name);
                vec![place(Diagnostic::new(Severity::Error, ErrorCode::UnknownType, message))]
            }
            Ok(schema) => schema
                .check_text_with(&r.type_name, text, &self.limits)
                .iter()
                .map(|i| Diagnostic::issue(i, text))
                .collect(),
        };
        (Some(label), diagnostics)
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
    fn load(&mut self, path: &Path) -> Rc<Result<Schema, haus_schema::Error>> {
        let key = path.canonicalize().unwrap_or_else(|_| path.to_owned());
        self.schemas.entry(key).or_insert_with(|| Rc::new(Schema::load(path, &FileResolver::new()))).clone()
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

fn to_json(reports: &[Report], status: Status) -> Json {
    let total = |f: fn(&Report) -> usize| reports.iter().map(f).sum::<usize>();
    let mut summary = Members::default();
    summary.add("files", n(reports.len()));
    summary.add("errors", n(total(Report::errors)));
    summary.add("warnings", n(total(|r| r.count(Severity::Warning))));
    summary.add("hints", n(total(|r| r.count(Severity::Hint))));
    summary.add("unreadable", n(reports.iter().filter(|r| r.error.is_some()).count()));
    let mut m = Members::default();
    m.add("ok", b(status == Status::Ok));
    m.add("files", Json::Array(reports.iter().map(Report::to_json).collect()));
    m.add("summary", summary.into());
    m.into()
}

fn human(reports: &[Report], color: bool) -> String {
    let renderer = output::renderer(color);
    let mut out = String::new();
    for r in reports {
        if let Some(e) = &r.error {
            out.push_str(&format!("error: cannot read {}: {e}\n\n", r.name));
        }
        for d in &r.diagnostics {
            out.push_str(&d.render(&r.name, &renderer));
            out.push_str("\n\n");
        }
    }
    let total = |severity| reports.iter().map(|r| r.count(severity)).sum::<usize>();
    let unreadable = reports.iter().filter(|r| r.error.is_some()).count();
    let found: Vec<String> = [
        (total(Severity::Error), "error"),
        (total(Severity::Warning), "warning"),
        (total(Severity::Hint), "hint"),
        (unreadable, "unreadable file"),
    ]
    .into_iter()
    .filter(|&(n, _)| n > 0)
    .map(|(n, noun)| count(n, noun))
    .collect();
    let found = if found.is_empty() { "no problems".to_owned() } else { found.join(", ") };
    out.push_str(&format!("Checked {}: {found}.\n", count(reports.len(), "file")));
    out
}
