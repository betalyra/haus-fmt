use crate::json::escape;
use std::fmt;

pub use crate::error_codes::{ErrorCategory, ErrorCode};

impl ErrorCode {
    /// The code called `name` (`payload-newline`), if the catalogue has it.
    pub fn from_name(name: &str) -> Option<ErrorCode> {
        ErrorCode::ALL.into_iter().find(|c| c.as_str() == name)
    }

    /// Its documentation: `https://haus-fmt.org/docs/errors#<code>`.
    pub fn docs(self) -> String {
        format!("https://haus-fmt.org/docs/errors#{}", self.as_str())
    }
}

/// `payload-newline`.
impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A syntax error, with its position (spec §8) and its code (spec §17).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyntaxError {
    /// Which mistake it is.
    pub code: ErrorCode,
    /// The message, without position.
    pub reason: String,
    /// Byte offset in the input.
    pub offset: usize,
    /// 1-based line.
    pub line: usize,
    /// 1-based column, in Unicode code points.
    pub column: usize,
    details: Details,
}

/// What an error says beyond its message (spec §17), boxed: errors pass
/// through recursive code, whose frames stay small this way.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct Details(Option<Box<Extra>>);

#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct Extra {
    expected: Option<String>,
    found: Option<String>,
    hint: Option<String>,
}

impl Details {
    fn extra(&self) -> Option<&Extra> {
        self.0.as_deref()
    }
    fn with(self, f: impl FnOnce(&mut Extra)) -> Details {
        let mut extra = self.0.unwrap_or_default();
        f(&mut extra);
        Details(Some(extra))
    }
    fn expected(&self) -> Option<&str> {
        self.extra().and_then(|e| e.expected.as_deref())
    }
    fn found(&self) -> Option<&str> {
        self.extra().and_then(|e| e.found.as_deref())
    }
    fn hint(&self) -> Option<&str> {
        self.extra().and_then(|e| e.hint.as_deref())
    }
}

/// The accessors and builders every error type has: [`SyntaxError`],
/// [`DecodeError`], [`EncodeError`].
macro_rules! details {
    ($t:ty) => {
        impl $t {
            /// What should be there, where that is natural: `','`, `Int64`.
            pub fn expected(&self) -> Option<&str> {
                self.details.expected()
            }

            /// What is there instead: `'{'`, `2.5`.
            pub fn found(&self) -> Option<&str> {
                self.details.found()
            }

            /// A concrete fix: the one for this case, or the catalogue's for the code.
            pub fn hint(&self) -> &str {
                self.details.hint().unwrap_or(self.code.hint())
            }

            /// The documentation of the code: `https://haus-fmt.org/docs/errors#<code>`.
            pub fn docs(&self) -> String {
                self.code.docs()
            }

            /// With what should be there, and what is.
            pub fn with_expected_found(self, expected: impl Into<String>, found: impl Into<String>) -> Self {
                let details = self.details.with(|e| {
                    e.expected = Some(expected.into());
                    e.found = Some(found.into());
                });
                Self { details, ..self }
            }

            /// With what should be there.
            pub fn with_expected(self, expected: impl Into<String>) -> Self {
                Self { details: self.details.with(|e| e.expected = Some(expected.into())), ..self }
            }

            /// With a fix for this case, better than the code's.
            pub fn with_hint(self, hint: impl Into<String>) -> Self {
                Self { details: self.details.with(|e| e.hint = Some(hint.into())), ..self }
            }
        }
    };
}
details!(SyntaxError);
details!(DecodeError);
details!(EncodeError);

impl fmt::Display for SyntaxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at {}:{}", self.reason, self.line, self.column)
    }
}

impl std::error::Error for SyntaxError {}

impl SyntaxError {
    /// An error at byte offset `at` of `src`.
    pub(crate) fn at(src: &str, at: usize, code: ErrorCode, reason: impl Into<String>) -> SyntaxError {
        let at = Position::START.after(&src[..floor_char_boundary(src, at.min(src.len()))]);
        SyntaxError::new(code, reason, at)
    }

    pub(crate) fn new(code: ErrorCode, reason: impl Into<String>, at: Position) -> SyntaxError {
        SyntaxError {
            code,
            reason: reason.into(),
            offset: at.offset,
            line: at.line,
            column: at.column,
            details: Details::default(),
        }
    }

    /// The same error, in a piece of text that starts at `origin` of the whole input.
    pub(crate) fn from(self, origin: Position) -> SyntaxError {
        SyntaxError {
            offset: origin.offset + self.offset,
            column: if self.line == 1 { origin.column + self.column - 1 } else { self.column },
            line: origin.line + self.line - 1,
            ..self
        }
    }

    /// The JSON form of spec §17: `{ code, message, line, column, expected?, found?, hint, docs }`.
    pub fn to_json(&self) -> String {
        json_form(&ErrorJson {
            code: self.code,
            message: &self.reason,
            position: Some((self.line, self.column)),
            path: None,
            expected: self.expected(),
            found: self.found(),
            hint: self.hint(),
        })
    }
}

/// The members of an error's JSON form (spec §17); those that are None are left out.
/// [`ErrorJson::write`] writes it.
#[derive(Debug, Clone, Copy)]
pub struct ErrorJson<'a> {
    pub code: ErrorCode,
    pub message: &'a str,
    /// Line and column, for an error in text.
    pub position: Option<(usize, usize)>,
    /// The place in the value (`$.items[2].price`), for an error in a value.
    pub path: Option<&'a str>,
    pub expected: Option<&'a str>,
    pub found: Option<&'a str>,
    pub hint: &'a str,
}

impl ErrorJson<'_> {
    /// The JSON text, on one line:
    /// `{"code":…,"message":…,"line":…,"column":…,"path":…,"expected":…,"found":…,"hint":…,"docs":…}`,
    /// without the members that are None. Other crates' errors (schema files,
    /// checkers) use it to give the same form.
    pub fn write(&self) -> String {
        json_form(self)
    }
}

fn json_form(e: &ErrorJson) -> String {
    let mut out = String::from("{");
    let mut member = |name: &str, value: &str, quoted: bool| {
        if out.len() > 1 {
            out.push(',');
        }
        escape(name, &mut out);
        out.push(':');
        if quoted { escape(value, &mut out) } else { out.push_str(value) }
    };
    member("code", e.code.as_str(), true);
    member("message", e.message, true);
    if let Some((line, column)) = e.position {
        member("line", &line.to_string(), false);
        member("column", &column.to_string(), false);
    }
    if let Some(path) = e.path {
        member("path", path, true);
    }
    if let Some(expected) = e.expected {
        member("expected", expected, true);
    }
    if let Some(found) = e.found {
        member("found", found, true);
    }
    member("hint", e.hint, true);
    member("docs", &e.code.docs(), true);
    out.push('}');
    out
}

/// A place in the input: byte offset, 1-based line and column (in code points).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Position {
    pub offset: usize,
    pub line: usize,
    pub column: usize,
}

impl Position {
    pub const START: Position = Position { offset: 0, line: 1, column: 1 };
    /// After a byte order mark, which is column 1, as in the whole-text parser.
    pub const AFTER_BOM: Position = Position { offset: 3, line: 1, column: 2 };

    /// Where the input is after `text`, starting here.
    pub fn after(self, text: &str) -> Position {
        text.chars().fold(Position { offset: self.offset + text.len(), ..self }, |p, c| match c {
            '\n' => Position { line: p.line + 1, column: 1, ..p },
            _ => Position { column: p.column + 1, ..p },
        })
    }
}

fn floor_char_boundary(s: &str, mut i: usize) -> usize {
    while !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// A value that doesn't match its type, with where it is: `.total(Money)[1]: …`,
/// and its code (spec §17).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodeError {
    /// Which mistake it is.
    pub code: ErrorCode,
    /// Where in the value, outermost first; empty at the root.
    pub path: Vec<Segment>,
    pub reason: String,
    details: Details,
}

/// One step into a value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Segment {
    /// A record field: `.name`, or `["pt-BR"]` for keys that aren't identifiers.
    Field(String),
    /// An array item or a payload value: `[2]`.
    Index(usize),
    /// The payload of a tag: `(Money)`.
    Tag(String),
}

impl DecodeError {
    pub fn new(code: ErrorCode, reason: impl Into<String>) -> DecodeError {
        DecodeError { code, path: Vec::new(), reason: reason.into(), details: Details::default() }
    }

    /// The same error with another code: the same problem, which is another mistake here.
    pub fn with_code(self, code: ErrorCode) -> DecodeError {
        DecodeError { code, ..self }
    }

    /// The same error, one step further out. Errors are built from the
    /// inside out, so this prepends.
    fn within(mut self, segment: Segment) -> DecodeError {
        self.path.insert(0, segment);
        self
    }

    /// The same error, inside field `key`.
    pub fn field(self, key: &str) -> DecodeError {
        self.within(Segment::Field(key.to_owned()))
    }

    /// The same error, inside item `i` of an array or a payload.
    pub fn index(self, i: usize) -> DecodeError {
        self.within(Segment::Index(i))
    }

    /// The same error, inside the payload of `tag`.
    pub fn tag(self, tag: &str) -> DecodeError {
        self.within(Segment::Tag(tag.to_owned()))
    }

    /// The place in the value as spec §15 writes it: `$.items[2].price`.
    /// Tags are left out: the arguments of a payload are `[i]`, the fields of a record payload `.name`.
    pub fn place(&self) -> String {
        place(&self.path)
    }

    /// The JSON form of spec §17: `{ code, message, path, expected?, found?, hint, docs }`.
    pub fn to_json(&self) -> String {
        json_form(&ErrorJson {
            code: self.code,
            message: &self.reason,
            position: None,
            path: Some(&self.place()),
            expected: self.expected(),
            found: self.found(),
            hint: self.hint(),
        })
    }
}

/// `$.items[2].price`, as TypeScript's `formatPath` writes it.
pub(crate) fn place(path: &[Segment]) -> String {
    let mut out = String::from("$");
    for s in path {
        match s {
            Segment::Field(key) if is_identifier(key) => {
                out.push('.');
                out.push_str(key);
            }
            Segment::Field(key) => {
                out.push('[');
                escape(key, &mut out);
                out.push(']');
            }
            Segment::Index(i) => out.push_str(&format!("[{i}]")),
            Segment::Tag(_) => {}
        }
    }
    out
}

impl fmt::Display for Segment {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Segment::Field(key) if is_identifier(key) => write!(f, ".{key}"),
            Segment::Field(key) => write!(f, "[{key:?}]"),
            Segment::Index(i) => write!(f, "[{i}]"),
            Segment::Tag(tag) => write!(f, "({tag})"),
        }
    }
}

/// A key written without quotes: `name`, `_id`.
fn is_identifier(key: &str) -> bool {
    key.starts_with(|c: char| c.is_ascii_lowercase() || c == '_')
        && key.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
}

/// `path: reason`, or just the reason at the root.
fn at_path(path: &[Segment], reason: &str, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    path.iter().try_for_each(|s| fmt::Display::fmt(s, f))?;
    if path.is_empty() { f.write_str(reason) } else { write!(f, ": {reason}") }
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        at_path(&self.path, &self.reason, f)
    }
}

impl std::error::Error for DecodeError {}

/// A value that can't be written, with where it is: `.data[3]: not a number
/// literal`, and its code (spec §17). Writing checks the whole value against
/// the syntax and the limits (spec §7, §9.8), since a [`Value`](crate::Value)
/// built in code, such as the raw value of an `Any` or an unknown variant,
/// may hold anything.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodeError {
    /// Which mistake it is.
    pub code: ErrorCode,
    /// Where in the value, outermost first; empty at the root.
    pub path: Vec<Segment>,
    pub reason: String,
    details: Details,
}

impl EncodeError {
    pub fn new(code: ErrorCode, reason: impl Into<String>) -> EncodeError {
        EncodeError { code, path: Vec::new(), reason: reason.into(), details: Details::default() }
    }

    /// The same error, one step further out (errors are built from the inside out).
    pub fn within(mut self, segment: Segment) -> EncodeError {
        self.path.insert(0, segment);
        self
    }

    /// The place in the value: `$.items[2].price` (see [`DecodeError::place`]).
    pub fn place(&self) -> String {
        place(&self.path)
    }

    /// The JSON form of spec §17: `{ code, message, path, expected?, found?, hint, docs }`.
    pub fn to_json(&self) -> String {
        json_form(&ErrorJson {
            code: self.code,
            message: &self.reason,
            position: None,
            path: Some(&self.place()),
            expected: self.expected(),
            found: self.found(),
            hint: self.hint(),
        })
    }

    /// The same mistake, found while reading (plain JSON read into a value that can't be written).
    pub(crate) fn into_decode(self) -> DecodeError {
        let EncodeError { code, path, reason, details } = self;
        DecodeError { code, path, reason, details }
    }
}

impl fmt::Display for EncodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        at_path(&self.path, &self.reason, f)
    }
}

impl std::error::Error for EncodeError {}

/// Reading or writing a typed value: the input can't be read, isn't haus or
/// doesn't match its type, or a value can't be written.
#[derive(Debug)]
pub enum Error {
    Syntax(SyntaxError),
    Decode(DecodeError),
    Encode(EncodeError),
    Io(std::io::Error),
}

impl Error {
    /// The error's code (spec §17); None for an I/O error, which is not a mistake in the data.
    pub fn code(&self) -> Option<ErrorCode> {
        match self {
            Error::Syntax(e) => Some(e.code),
            Error::Decode(e) => Some(e.code),
            Error::Encode(e) => Some(e.code),
            Error::Io(_) => None,
        }
    }

    /// The JSON form of spec §17; None for an I/O error.
    pub fn to_json(&self) -> Option<String> {
        match self {
            Error::Syntax(e) => Some(e.to_json()),
            Error::Decode(e) => Some(e.to_json()),
            Error::Encode(e) => Some(e.to_json()),
            Error::Io(_) => None,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Syntax(e) => e.fmt(f),
            Error::Decode(e) => e.fmt(f),
            Error::Encode(e) => e.fmt(f),
            Error::Io(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Syntax(e) => Some(e),
            Error::Decode(e) => Some(e),
            Error::Encode(e) => Some(e),
            Error::Io(e) => Some(e),
        }
    }
}

impl From<EncodeError> for Error {
    fn from(e: EncodeError) -> Self {
        Error::Encode(e)
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

impl From<SyntaxError> for Error {
    fn from(e: SyntaxError) -> Self {
        Error::Syntax(e)
    }
}
impl From<DecodeError> for Error {
    fn from(e: DecodeError) -> Self {
        Error::Decode(e)
    }
}
