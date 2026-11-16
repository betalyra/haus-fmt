//! One problem found in a file: its JSON form (spec §17 and a severity),
//! and its text with a source excerpt (annotate-snippets).

use crate::json::{Members, n, s};
use annotate_snippets::{AnnotationKind, Level, Origin, Renderer, Snippet};
use haus::json::Json;
use haus::{ErrorCode, SyntaxError};
use haus_schema::Issue;
use std::ops::Range;

/// How bad a diagnostic is. Only errors fail a check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    /// The file is invalid.
    Error,
    /// Allowed, but probably not meant: an attribute this version doesn't
    /// know, a deprecated type used in a schema.
    Warning,
    /// Allowed, maybe not meant: a field or tag the schema doesn't list, a
    /// deprecated one the data uses.
    Hint,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Error => "error",
            Severity::Warning => "warning",
            Severity::Hint => "hint",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub severity: Severity,
    pub code: ErrorCode,
    pub message: String,
    /// The file the place is in, when it isn't the file checked (its schema).
    pub file: Option<String>,
    /// Line and column, 1-based, columns in code points (spec §8).
    pub position: Option<(usize, usize)>,
    /// The place in the value: `$.items[2].price`.
    pub path: Option<String>,
    pub expected: Option<String>,
    pub found: Option<String>,
    pub hint: String,
    excerpt: Option<Excerpt>,
}

/// The source line a diagnostic points into, and the part it points at.
#[derive(Debug, Clone)]
struct Excerpt {
    line: String,
    span: Range<usize>,
}

impl Diagnostic {
    pub fn new(severity: Severity, code: ErrorCode, message: impl Into<String>) -> Diagnostic {
        Diagnostic {
            severity,
            code,
            message: message.into(),
            file: None,
            position: None,
            path: None,
            expected: None,
            found: None,
            hint: code.hint().to_owned(),
            excerpt: None,
        }
    }

    /// A syntax error in `text` (None: the text isn't at hand, as in a stream).
    pub fn syntax(e: &SyntaxError, text: Option<&str>) -> Diagnostic {
        Diagnostic {
            position: Some((e.line, e.column)),
            expected: e.expected().map(str::to_owned),
            found: e.found().map(str::to_owned),
            hint: e.hint().to_owned(),
            excerpt: text.map(|t| Excerpt::new(t, e.offset..e.offset)),
            ..Diagnostic::new(Severity::Error, e.code, &e.reason)
        }
    }

    /// What a schema check found in the data file `text`.
    pub fn issue(i: &Issue, text: &str) -> Diagnostic {
        let severity = match i.severity {
            haus_schema::Severity::Error => Severity::Error,
            haus_schema::Severity::Hint => Severity::Hint,
        };
        Diagnostic {
            position: i.position.map(|p| (p.line, p.column)),
            path: Some(i.path_string()),
            hint: i.hint().to_owned(),
            excerpt: i.span.clone().map(|span| Excerpt::new(text, span)),
            ..Diagnostic::new(severity, i.code, &i.message)
        }
    }

    /// An error or warning about a schema file whose text is `text`.
    pub fn schema(e: &haus_schema::Error, severity: Severity, text: Option<&str>) -> Diagnostic {
        let excerpt = text.zip(e.position()).map(|(t, (line, column))| {
            let at = offset(t, line, column);
            Excerpt::new(t, at..at)
        });
        Diagnostic {
            position: e.position(),
            hint: e.hint().to_owned(),
            excerpt,
            ..Diagnostic::new(severity, e.code(), e.reason())
        }
    }

    /// The same diagnostic, at `span` of `text`.
    pub fn at(self, text: &str, span: Range<usize>) -> Diagnostic {
        let (line, column) = position(text, span.start);
        Diagnostic { position: Some((line, column)), excerpt: Some(Excerpt::new(text, span)), ..self }
    }

    /// The same diagnostic, for text that starts on line `line` of the file
    /// rather than on line 1 (a value of a stream, from its excerpt).
    pub fn on_line(self, line: usize) -> Diagnostic {
        Diagnostic { position: self.position.map(|(l, c)| (l + line - 1, c)), ..self }
    }

    /// The same diagnostic, at `line` and `column`, without an excerpt.
    pub fn placed(self, line: usize, column: usize) -> Diagnostic {
        Diagnostic { position: Some((line, column)), excerpt: None, ..self }
    }

    /// The same diagnostic, in the file `file` rather than the one checked.
    pub fn in_file(self, file: String) -> Diagnostic {
        Diagnostic { file: Some(file), ..self }
    }

    /// The JSON form: spec §17's members, the severity first, and `file`
    /// after the message when the place is in another file.
    pub fn to_json(&self) -> Json {
        let mut m = Members::default();
        m.add("severity", s(self.severity.as_str()));
        m.add("code", s(self.code.as_str()));
        m.add("message", s(&self.message));
        m.opt("file", self.file.as_deref().map(s));
        if let Some((line, column)) = self.position {
            m.add("line", n(line));
            m.add("column", n(column));
        }
        m.opt("path", self.path.as_deref().map(s));
        m.opt("expected", self.expected.as_deref().map(s));
        m.opt("found", self.found.as_deref().map(s));
        m.add("hint", s(&self.hint));
        m.add("docs", s(&self.code.docs()));
        m.into()
    }

    /// The text for people: title, place, source line with a caret, the
    /// place in the value, the hint and the docs. `name` is the file checked.
    pub fn render(&self, name: &str, renderer: &Renderer) -> String {
        let level = match self.severity {
            Severity::Error => Level::ERROR,
            Severity::Warning => Level::WARNING,
            Severity::Hint => Level::INFO.with_name("hint"),
        };
        let file = self.file.as_deref().unwrap_or(name);
        let title = level.primary_title(&self.message).id(self.code.as_str());
        let mut group = match (&self.excerpt, self.position) {
            (Some(x), Some((line, _))) => {
                let annotation = AnnotationKind::Primary.span(x.span.clone());
                title.element(Snippet::source(&x.line).path(file).line_start(line).annotation(annotation))
            }
            (None, Some((line, column))) => title.element(Origin::path(file).line(line).char_column(column)),
            _ => title.element(Origin::path(file)),
        };
        if self.file.is_some() {
            group = group.element(Level::NOTE.message(format!("while checking {name} against this schema")));
        }
        if let Some(path) = &self.path {
            group = group.element(Level::NOTE.with_name("at").message(path));
        }
        let group = group
            .element(Level::HELP.with_name("hint").message(&self.hint))
            .element(Level::NOTE.with_name("docs").message(self.code.docs()));
        renderer.render(&[group])
    }
}

/// `bytes` as text, or the `invalid-utf8` error, at the first bad byte.
pub fn utf8(bytes: &[u8]) -> Result<&str, Box<Diagnostic>> {
    std::str::from_utf8(bytes).map_err(|_| {
        let lossy = String::from_utf8_lossy(bytes);
        Box::new(match haus::parse_bytes(bytes) {
            Err(e) => Diagnostic::syntax(&e, Some(&lossy)),
            Ok(_) => Diagnostic::new(Severity::Error, ErrorCode::InvalidUtf8, "invalid UTF-8"),
        })
    })
}

impl Excerpt {
    /// The line of `text` where `span` starts, and the part of `span` on it:
    /// at least one character, unless the span is at the end of the line.
    /// A line's CR and C1 control characters aren't shown.
    fn new(text: &str, span: Range<usize>) -> Excerpt {
        let start = floor(text, span.start);
        let begin = text[..start].rfind('\n').map_or(0, |i| i + 1);
        let end = text[start..].find('\n').map_or(text.len(), |i| start + i);
        let line = &text[begin..end];
        let line = line.strip_suffix('\r').unwrap_or(line);
        let from = (start - begin).min(line.len());
        let to = floor(line, span.end.saturating_sub(begin).clamp(from, line.len()));
        let to = match line[from..].chars().next() {
            Some(c) if to == from => from + c.len_utf8(),
            _ => to,
        };
        let (line, span) = shown(line, from..to);
        Excerpt { line, span }
    }
}

/// `line` with C1 control characters replaced by U+FFFD, and `span` moved
/// along. annotate-snippets replaces C0 controls and bidi controls itself.
fn shown(line: &str, span: Range<usize>) -> (String, Range<usize>) {
    let mut out = String::with_capacity(line.len());
    let mut moved = span.clone();
    for (i, c) in line.char_indices() {
        if i == span.start {
            moved.start = out.len();
        }
        if i == span.end {
            moved.end = out.len();
        }
        out.push(if ('\u{80}'..='\u{9f}').contains(&c) { '\u{FFFD}' } else { c });
    }
    if span.start >= line.len() {
        moved.start = out.len();
    }
    if span.end >= line.len() {
        moved.end = out.len();
    }
    (out, moved)
}

fn floor(text: &str, mut i: usize) -> usize {
    i = i.min(text.len());
    while !text.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// The byte offset of 1-based `line` and `column` (in code points).
fn offset(text: &str, line: usize, column: usize) -> usize {
    let start = if line <= 1 { 0 } else { text.match_indices('\n').nth(line - 2).map_or(text.len(), |(i, _)| i + 1) };
    text[start..].char_indices().nth(column.saturating_sub(1)).map_or(text.len(), |(i, _)| start + i)
}

/// The 1-based line and column (in code points) of byte offset `at`.
pub fn position(text: &str, at: usize) -> (usize, usize) {
    let at = floor(text, at);
    let before = &text[..at];
    let line_start = before.rfind('\n').map_or(0, |i| i + 1);
    let line = before.matches('\n').count() + 1;
    let column = before[line_start..].chars().count() + 1;
    (line, column)
}
