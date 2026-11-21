//! A strict JSON reader: RFC 8259 restricted to I-JSON (RFC 7493), as spec §16
//! asks. Numbers keep their exact text, member names are unique, `\u`
//! escapes pair their surrogates, and the depth and number limits of spec §7
//! apply. Lengths of strings, keys, tags and bytes are checked on the haus
//! value that results, by the reader of each form.

use super::{Json, JsonNumber};
use crate::scan::{is_bidi, is_control};
use crate::{ErrorCode as Code, Limits, SyntaxError};
use std::collections::HashSet;

type R<T> = Result<T, SyntaxError>;

/// Which of the forms of spec §16 a JSON text is read as. The form sets how
/// deep the JSON may nest, and whether raw DEL, C1 and bidi controls are
/// allowed in strings and member names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Form {
    /// Self-describing JSON (§16.2): 4·d + 2 levels (one for the envelope),
    /// and no raw DEL, C1 or bidi controls: only haus writes it, and it escapes them.
    SelfDescribing,
    /// Schema-based JSON (§16.3): 4·d + 1 levels. A mapping can take several
    /// JSON levels for one haus level (`Tag { … }` is `{"_tag": …, "_args":
    /// [{"_rec": {…}}]}`); the depth of the haus value that results is
    /// checked against d where JSON becomes one.
    SchemaBased,
    /// JSON import (§16.1): d levels, one per level of the haus value.
    Import,
}

impl Form {
    /// How deep JSON in this form may nest for `limits`.
    pub(crate) fn max_depth(self, limits: &Limits) -> usize {
        let d = limits.max_depth;
        match self {
            Form::SelfDescribing => d.saturating_mul(4).saturating_add(2),
            Form::SchemaBased => d.saturating_mul(4).saturating_add(1),
            Form::Import => d,
        }
    }
}

/// One JSON text in `form`, with whitespace around it. A byte order mark at
/// the start is skipped if `bom`.
pub(crate) fn parse(src: &str, limits: &Limits, form: Form, bom: bool) -> R<Json> {
    if let Some(reason) = limits.unsupported() {
        return Err(SyntaxError::at(src, 0, Code::UnsupportedDepth, reason));
    }
    let start = if bom && src.starts_with('\u{FEFF}') { 3 } else { 0 };
    let mut reader =
        Reader { src, b: src.as_bytes(), pos: start, depth: 0, limits, max_depth: form.max_depth(limits), form };
    reader.whitespace();
    let value = reader.value()?;
    reader.whitespace();
    match reader.peek() {
        None => Ok(value),
        Some(_) => Err(reader.fail(Code::JsonSyntax, format!("unexpected {} after the JSON value", reader.found()))),
    }
}

struct Reader<'a> {
    src: &'a str,
    b: &'a [u8],
    pos: usize,
    depth: usize,
    limits: &'a Limits,
    max_depth: usize,
    form: Form,
}

/// A container being read: its items so far, and for an object the names
/// seen and the name of the member whose value comes next.
enum Open {
    Array(Vec<Json>),
    Object { members: Vec<(String, Json)>, seen: HashSet<String>, name: String },
}

impl Reader<'_> {
    /// A value, read with a stack of open containers rather than recursion,
    /// so that deep nesting takes no call stack.
    fn value(&mut self) -> R<Json> {
        let mut open: Vec<Open> = Vec::new();
        loop {
            // A value starts here: a scalar, an empty container, or a container to fill.
            let mut done = match self.peek() {
                Some(b'[') => {
                    self.enter()?;
                    self.pos += 1;
                    self.whitespace();
                    if !self.eat(b']') {
                        open.push(Open::Array(Vec::new()));
                        continue;
                    }
                    self.depth -= 1;
                    Json::Array(Vec::new())
                }
                Some(b'{') => {
                    self.enter()?;
                    self.pos += 1;
                    self.whitespace();
                    if !self.eat(b'}') {
                        let mut seen = HashSet::new();
                        let name = self.member_name(&mut seen)?;
                        open.push(Open::Object { members: Vec::new(), seen, name });
                        continue;
                    }
                    self.depth -= 1;
                    Json::Object(Vec::new())
                }
                _ => self.scalar()?,
            };
            // Add it to the containers it completes, until one wants another value.
            loop {
                let Some(container) = open.last_mut() else { return Ok(done) };
                self.whitespace();
                match container {
                    Open::Array(items) => {
                        items.push(done);
                        match self.next_of(b']') {
                            Some(true) => {
                                self.whitespace();
                                break;
                            }
                            Some(false) => done = Json::Array(std::mem::take(items)),
                            None => {
                                return Err(
                                    self.fail(Code::JsonSyntax, format!("expected ',' or ']', found {}", self.found()))
                                );
                            }
                        }
                    }
                    Open::Object { members, seen, name } => {
                        members.push((std::mem::take(name), done));
                        match self.next_of(b'}') {
                            Some(true) => {
                                self.whitespace();
                                *name = self.member_name(seen)?;
                                break;
                            }
                            Some(false) => done = Json::Object(std::mem::take(members)),
                            None => {
                                return Err(self
                                    .fail(Code::JsonSyntax, format!("expected ',' or '}}', found {}", self.found())));
                            }
                        }
                    }
                }
                open.pop();
                self.depth -= 1;
            }
        }
    }

    fn scalar(&mut self) -> R<Json> {
        match self.peek() {
            Some(b'"') => self.string().map(Json::String),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            _ => Err(self.fail(Code::JsonSyntax, format!("expected a JSON value, found {}", self.found()))),
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> R<Json> {
        if self.b[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(value)
        } else {
            Err(self.fail(Code::JsonSyntax, format!("expected a JSON value, found {}", self.found())))
        }
    }

    fn enter(&mut self) -> R<()> {
        self.depth += 1;
        let max = self.max_depth;
        if self.depth > max {
            return Err(self.fail(Code::NestingTooDeep, format!("JSON nested deeper than {max} levels")));
        }
        Ok(())
    }

    /// A member's name and the `:` after it, not one of the names `seen`.
    fn member_name(&mut self, seen: &mut HashSet<String>) -> R<String> {
        let at = self.pos;
        if self.peek() != Some(b'"') {
            return Err(self.fail(Code::JsonSyntax, format!("expected a member name, found {}", self.found())));
        }
        let name = self.string()?;
        if !seen.insert(name.clone()) {
            return Err(SyntaxError::at(
                self.src,
                at,
                Code::DuplicateKey,
                format!("duplicate member name \"{}\"", crate::scan::shown(&name)),
            ));
        }
        self.whitespace();
        if !self.eat(b':') {
            return Err(self.fail(Code::JsonSyntax, format!("expected ':', found {}", self.found())));
        }
        self.whitespace();
        Ok(name)
    }

    /// `-?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?`, within the number limits.
    fn number(&mut self) -> R<Json> {
        let start = self.pos;
        self.eat(b'-');
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => self.digits(),
            _ => return Err(self.fail_at(start, Code::JsonSyntax, "invalid number")),
        }
        if self.eat(b'.') {
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.fail_at(start, Code::JsonSyntax, "invalid number: a digit must follow '.'"));
            }
            self.digits();
        }
        let mut exponent = None;
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if !self.eat(b'+') {
                self.eat(b'-');
            }
            let digits = self.pos;
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.fail_at(start, Code::JsonSyntax, "invalid number: a digit must follow the exponent"));
            }
            self.digits();
            exponent = Some(&self.src[digits..self.pos]);
        }
        let text = &self.src[start..self.pos];
        if text.len() > self.limits.max_number_length {
            let max = self.limits.max_number_length;
            return Err(self.fail_at(
                start,
                Code::NumberTooLong,
                format!("number literal longer than {max} characters"),
            ));
        }
        if let Some(exp) = exponent.map(|e| e.trim_start_matches('0'))
            && (exp.len() > 19 || exp.parse::<u64>().unwrap_or(0) > self.limits.max_exponent)
        {
            return Err(self.fail_at(
                start,
                Code::ExponentTooLarge,
                format!("exponent larger than {}", self.limits.max_exponent),
            ));
        }
        Ok(Json::Number(JsonNumber::from_valid(text.to_owned())))
    }

    fn digits(&mut self) {
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.pos += 1;
        }
    }

    /// A string, after its opening quote is seen.
    fn string(&mut self) -> R<String> {
        let open = self.pos;
        self.pos += 1;
        let mut out = String::new();
        loop {
            let run = self.pos;
            while matches!(self.peek(), Some(c) if c != b'"' && c != b'\\' && c >= 0x20) {
                self.pos += 1;
            }
            self.raw(run)?;
            out.push_str(&self.src[run..self.pos]);
            match self.peek() {
                Some(b'"') => {
                    self.pos += 1;
                    break;
                }
                Some(b'\\') => out.push(self.escape()?),
                Some(c) => {
                    return Err(self.fail(
                        Code::ControlCharacter,
                        format!("raw control character U+{c:04X} in a string (escape it)"),
                    ));
                }
                None => return Err(self.fail_at(open, Code::UnterminatedString, "unclosed string")),
            }
        }
        // Lengths are counted on the haus value that results (spec §16), by
        // the reader of each form: a member name may be a key or a form's
        // own (`"_tag"`), a string a string, a tag, bytes or a number.
        Ok(out)
    }

    /// In self-describing JSON, a raw DEL, C1 or bidi control in the
    /// characters from `run` to here is an error (spec §16).
    fn raw(&self, run: usize) -> R<()> {
        if self.form != Form::SelfDescribing {
            return Ok(());
        }
        let text = &self.src[run..self.pos];
        if text.is_ascii() && !text.contains('\u{7F}') {
            return Ok(());
        }
        match text.char_indices().find(|&(_, c)| is_control(c) || is_bidi(c)) {
            Some((i, c)) if is_bidi(c) => Err(self.fail_at(
                run + i,
                Code::BidiControl,
                format!("raw bidirectional control character U+{:04X} in a string (escape it)", u32::from(c)),
            )),
            Some((i, c)) => Err(self.fail_at(
                run + i,
                Code::ControlCharacter,
                format!("raw control character U+{:04X} in a string (escape it)", u32::from(c)),
            )),
            None => Ok(()),
        }
    }

    /// An escape sequence, at its backslash.
    fn escape(&mut self) -> R<char> {
        let at = self.pos;
        self.pos += 1;
        let c = match self.next() {
            Some(b'"') => '"',
            Some(b'\\') => '\\',
            Some(b'/') => '/',
            Some(b'b') => '\u{8}',
            Some(b'f') => '\u{c}',
            Some(b'n') => '\n',
            Some(b'r') => '\r',
            Some(b't') => '\t',
            Some(b'u') => {
                let unit = self.hex4(at)?;
                let code = match unit {
                    0xD800..=0xDBFF => {
                        let low = self.b[self.pos..]
                            .starts_with(b"\\u")
                            .then(|| {
                                self.pos += 2;
                                self.hex4(at)
                            })
                            .transpose()?
                            .filter(|low| (0xDC00..=0xDFFF).contains(low))
                            .ok_or_else(|| {
                                self.fail_at(at, Code::UnpairedSurrogate, "unpaired surrogate in a \\u escape")
                            })?;
                        0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    }
                    0xDC00..=0xDFFF => {
                        return Err(self.fail_at(at, Code::UnpairedSurrogate, "unpaired surrogate in a \\u escape"));
                    }
                    unit => unit,
                };
                char::from_u32(code)
                    .ok_or_else(|| self.fail_at(at, Code::InvalidUnicodeEscape, "invalid \\u escape"))?
            }
            _ => {
                return Err(self.fail_at(
                    at,
                    Code::InvalidEscape,
                    "invalid escape: use \\\" \\\\ \\/ \\b \\f \\n \\r \\t or \\uXXXX",
                ));
            }
        };
        Ok(c)
    }

    /// Four hex digits of a `\u` escape that starts at `at`.
    fn hex4(&mut self, at: usize) -> R<u32> {
        let digits = self.b.get(self.pos..self.pos + 4).filter(|d| d.iter().all(u8::is_ascii_hexdigit));
        let digits = digits.ok_or_else(|| self.fail_at(at, Code::InvalidUnicodeEscape, "\\u takes four hex digits"))?;
        self.pos += 4;
        Ok(digits.iter().fold(0, |n, &d| n * 16 + (d as char).to_digit(16).unwrap_or(0)))
    }

    fn whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.pos).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let c = self.peek();
        self.pos += usize::from(c.is_some());
        c
    }

    /// After an item: a comma (true) or the closing bracket (false), or None.
    fn next_of(&mut self, close: u8) -> Option<bool> {
        let found = match self.peek()? {
            b',' => true,
            c if c == close => false,
            _ => return None,
        };
        self.pos += 1;
        Some(found)
    }

    fn eat(&mut self, c: u8) -> bool {
        let found = self.peek() == Some(c);
        self.pos += usize::from(found);
        found
    }

    /// What is at the current position, for messages.
    fn found(&self) -> String {
        match self.src[self.pos..].chars().next() {
            None => "end of input".into(),
            Some('\n') => "line break".into(),
            Some(c) => format!("'{}'", crate::scan::shown(c.encode_utf8(&mut [0; 4]))),
        }
    }

    fn fail(&self, code: Code, reason: impl Into<String>) -> SyntaxError {
        SyntaxError::at(self.src, self.pos, code, reason)
    }

    fn fail_at(&self, at: usize, code: Code, reason: impl Into<String>) -> SyntaxError {
        SyntaxError::at(self.src, at, code, reason)
    }
}
