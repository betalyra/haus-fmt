//! The standard formatter (spec §11): a port of the TypeScript reference
//! formatter (typescript/packages/haus/src/format.ts), which keeps comments,
//! blank lines and the source spelling of numbers, strings and byte strings.
//!
//! The text is checked by the value parser first, so errors are exactly
//! those of [`crate::parse_with`]. A second pass over the checked text finds
//! where every value, key and comment is ([`Document`]); it, the layout and
//! the single-line rendering all loop over explicit stacks instead of
//! recursing, so any depth the parser accepts formats in a small stack.

use crate::parser::{Limits, parse_with};
use crate::ser::{key, quote};
use crate::{SyntaxError, Value};
use std::fmt::Write as _;

/// The layout [`format()`] writes (spec §11).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Style {
    /// For people: one entry per line in every non-empty record and array,
    /// each followed by a comma; positional payloads stay inline when they
    /// fit the width. Comments and blank lines are kept.
    #[default]
    Pretty,
    /// Every top-level item on one line (`{ a: 1, b: [1, 2] }`), multi-line
    /// strings as `\n` escapes, a comma after every item of a stream.
    /// Comments are dropped.
    Compact,
    /// Compact without the whitespace between tokens, for the wire and
    /// storage: `Person{name:"Ada",tags:[1,2]}`. Literals keep their
    /// spelling (`1_000`, `x"9f86 d081"`); comments are dropped.
    Minimised,
}

/// Options of [`format()`], the same as the TypeScript formatter's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FormatOptions {
    /// The layout (default: [`Style::Pretty`]).
    pub style: Style,
    /// Spaces per indentation level (default 2).
    pub indent: usize,
    /// Line width for positional payloads like `Money(7.90, EUR)` to stay
    /// inline (default 80). Counted in code points (as error columns are,
    /// spec §8), including the comma after the entry.
    pub width: usize,
    /// The limits the text is parsed with (spec §7; default: the spec's).
    pub limits: Limits,
}

impl Default for FormatOptions {
    fn default() -> Self {
        FormatOptions { style: Style::Pretty, indent: 2, width: 80, limits: Limits::default() }
    }
}

/// Format a whole file in the standard layout (spec §11): one value, or a
/// stream with a comma after each value. The pretty layout keeps comments,
/// blank lines (at most one in a row) and the source spelling of numbers,
/// single-line strings and byte strings (`0xFF` stays `0xFF`); the compact
/// and minimised layouts drop comments. Formatting the output again changes
/// nothing, and every layout holds the same values as the input.
///
/// Fails with the parser's error if `text` isn't valid haus within
/// `options.limits`, or if those limits aren't supported
/// ([`crate::MAX_SUPPORTED_DEPTH`]).
///
/// ```
/// let text = "{ name: \"Ada\", // who\n tags: [0xFF] }";
/// let out = haus::format(text, &haus::FormatOptions::default()).unwrap();
/// assert_eq!(out, "{\n  name: \"Ada\", // who\n  tags: [\n    0xFF,\n  ],\n}\n");
/// let compact = haus::FormatOptions { style: haus::Style::Compact, ..Default::default() };
/// assert_eq!(haus::format(text, &compact).unwrap(), "{ name: \"Ada\", tags: [0xFF] }\n");
/// let minimised = haus::FormatOptions { style: haus::Style::Minimised, ..Default::default() };
/// assert_eq!(haus::format(text, &minimised).unwrap(), "{name:\"Ada\",tags:[0xFF]}\n");
/// ```
pub fn format(text: &str, options: &FormatOptions) -> Result<String, SyntaxError> {
    let values = parse_with(text, &options.limits)?;
    let doc = Document::scan(text, values);
    let f = Formatter {
        src: text,
        doc: &doc,
        step: options.indent,
        width: i64::try_from(options.width).unwrap_or(i64::MAX),
        gaps: if options.style == Style::Minimised { Gaps::NONE } else { Gaps::SPACED },
    };
    Ok(match options.style {
        Style::Pretty => f.pretty(),
        Style::Compact | Style::Minimised => f.lines(),
    })
}

/// Whether a text has comments: a tool that rewrites a file in place in the
/// compact or minimised layout, which drop them, must refuse if it has
/// (spec §11, "Comments and layouts"), unless the user asked to drop them.
/// Fails with the parser's error if `text` isn't valid haus within `limits`.
///
/// ```
/// let limits = haus::Limits::default();
/// assert_eq!(haus::has_comments("{ a: 1 } // why", &limits), Ok(true));
/// assert_eq!(haus::has_comments("{ a: \"// not one\" }", &limits), Ok(false));
/// ```
pub fn has_comments(text: &str, limits: &Limits) -> Result<bool, SyntaxError> {
    let values = parse_with(text, limits)?;
    Ok(!Document::scan(text, values).comments.is_empty())
}

// ── the document: values, keys and comments with their positions ──────────

/// `[start, end)` byte offsets in the text.
type Span = (usize, usize);

struct Node {
    start: usize,
    end: usize,
    kind: Kind,
}

enum Kind {
    Number,
    /// The decoded string.
    String(String),
    Bytes,
    Array(Vec<usize>),
    Record(Vec<Field>),
    /// `Tag`, `Tag(…)` (`paren` is where the `(` is) or `Tag { … }` (one record argument).
    Variant {
        tag_end: usize,
        args: Vec<usize>,
        paren: Option<usize>,
    },
}

struct Field {
    /// The decoded key.
    key: String,
    /// Where the key starts.
    start: usize,
    value: usize,
}

/// The values of a checked text as a tree of positioned nodes (indexes into
/// `nodes`), and the span of every comment, in source order.
struct Document {
    nodes: Vec<Node>,
    roots: Vec<usize>,
    comments: Vec<Span>,
}

/// A container being read.
struct Open {
    node: usize,
    close: u8,
    /// In a record: the key of the value being read, and where it starts.
    key: Option<(String, usize)>,
    /// For the record payload of `Tag { … }`: the variant node.
    variant: Option<usize>,
}

struct Scanner<'a> {
    src: &'a str,
    b: &'a [u8],
    pos: usize,
    doc: Document,
    /// Decoded record keys and strings, in source order (from the parsed values).
    strings: std::vec::IntoIter<String>,
}

impl Document {
    /// Read `src`, which the parser has accepted and read as `values`.
    fn scan(src: &str, values: Vec<Value>) -> Document {
        let mut s = Scanner {
            src,
            b: src.as_bytes(),
            pos: if src.starts_with('\u{FEFF}') { 3 } else { 0 },
            doc: Document { nodes: Vec::new(), roots: Vec::new(), comments: Vec::new() },
            strings: strings_in_order(values).into_iter(),
        };
        let mut stack: Vec<Open> = Vec::new();
        loop {
            s.trivia();
            let Some(c) = s.b.get(s.pos).copied() else { break };
            match stack.last_mut() {
                _ if c == b',' => s.pos += 1,
                Some(open) if c == open.close => {
                    s.pos += 1;
                    let end = s.pos;
                    s.doc.nodes[open.node].end = end;
                    let node = match open.variant {
                        Some(v) => {
                            s.doc.nodes[v].end = end;
                            if let Kind::Variant { args, .. } = &mut s.doc.nodes[v].kind {
                                args.push(open.node);
                            }
                            v
                        }
                        None => open.node,
                    };
                    stack.pop();
                    s.attach(&mut stack, node);
                }
                Some(open) if open.key.is_none() && matches!(s.doc.nodes[open.node].kind, Kind::Record(_)) => {
                    let start = s.pos;
                    s.pos = if c == b'"' { s.basic_string_end(start) } else { s.ident_end(start) };
                    open.key = Some((s.strings.next().unwrap_or_default(), start));
                    s.trivia();
                    s.pos += 1; // :
                }
                _ => {
                    if let Some(node) = s.begin_value(&mut stack) {
                        s.attach(&mut stack, node);
                    }
                }
            }
        }
        s.doc
    }
}

/// The record keys and strings in `values`, in source order.
fn strings_in_order(values: Vec<Value>) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack: Vec<Value> = values.into_iter().rev().collect();
    while let Some(v) = stack.pop() {
        match v {
            Value::String(s) => out.push(s),
            Value::Array(items) | Value::Variant { args: items, .. } => stack.extend(items.into_iter().rev()),
            Value::Record(fields) => {
                for (k, v) in fields.into_iter().rev() {
                    stack.push(v);
                    stack.push(Value::String(k));
                }
            }
            Value::Number(_) | Value::Bytes(_) => {}
        }
    }
    out
}

impl Scanner<'_> {
    fn node(&mut self, start: usize, end: usize, kind: Kind) -> usize {
        self.doc.nodes.push(Node { start, end, kind });
        self.doc.nodes.len() - 1
    }

    /// The value starting here: its node if it is complete, or None if it
    /// opened a container (pushed on `stack`).
    fn begin_value(&mut self, stack: &mut Vec<Open>) -> Option<usize> {
        let start = self.pos;
        let open = |node, close, variant| Open { node, close, key: None, variant };
        match self.b[start] {
            b'{' => {
                self.pos += 1;
                let node = self.node(start, start, Kind::Record(Vec::new()));
                stack.push(open(node, b'}', None));
                None
            }
            b'[' => {
                self.pos += 1;
                let node = self.node(start, start, Kind::Array(Vec::new()));
                stack.push(open(node, b']', None));
                None
            }
            b'"' => {
                self.pos = if self.b[start..].starts_with(b"\"\"\"") {
                    self.block_string_end(start)
                } else {
                    self.basic_string_end(start)
                };
                let s = self.strings.next().unwrap_or_default();
                Some(self.node(start, self.pos, Kind::String(s)))
            }
            b'x' => {
                // x"…": hex digits, spaces and tabs.
                let close = self.b[start + 2..].iter().position(|&c| c == b'"').map_or(self.b.len(), |i| start + 2 + i);
                self.pos = close + 1;
                Some(self.node(start, self.pos, Kind::Bytes))
            }
            c if c.is_ascii_uppercase() => {
                let tag_end = self.ident_end(start);
                let mut at = tag_end;
                while matches!(self.b.get(at), Some(b' ' | b'\t')) {
                    at += 1;
                }
                let variant = |args, paren| Kind::Variant { tag_end, args, paren };
                match self.b.get(at) {
                    Some(b'(') => {
                        self.pos = at + 1;
                        let node = self.node(start, start, variant(Vec::new(), Some(at)));
                        stack.push(open(node, b')', None));
                        None
                    }
                    Some(b'{') => {
                        self.pos = at + 1;
                        let v = self.node(start, start, variant(Vec::new(), None));
                        let record = self.node(at, at, Kind::Record(Vec::new()));
                        stack.push(open(record, b'}', Some(v)));
                        None
                    }
                    _ => {
                        self.pos = tag_end;
                        Some(self.node(start, tag_end, variant(Vec::new(), None)))
                    }
                }
            }
            _ => {
                // A number: in checked text, it ends at the first other character.
                let len = self.b[start..]
                    .iter()
                    .position(|&c| !(c.is_ascii_alphanumeric() || matches!(c, b'-' | b'+' | b'_' | b'.')))
                    .unwrap_or(self.b.len() - start);
                self.pos = start + len;
                Some(self.node(start, self.pos, Kind::Number))
            }
        }
    }

    /// Add the complete `node` to the container being read, or to the roots.
    fn attach(&mut self, stack: &mut [Open], node: usize) {
        let Some(open) = stack.last_mut() else { return self.doc.roots.push(node) };
        match &mut self.doc.nodes[open.node].kind {
            Kind::Record(fields) => {
                let (key, start) = open.key.take().unwrap_or_default();
                fields.push(Field { key, start, value: node });
            }
            Kind::Array(items) | Kind::Variant { args: items, .. } => items.push(node),
            Kind::Number | Kind::String(_) | Kind::Bytes => {}
        }
    }

    fn ident_end(&self, start: usize) -> usize {
        start + self.b[start..].iter().take_while(|&&c| c.is_ascii_alphanumeric() || c == b'_').count()
    }

    /// After the `"…"` string starting at `start`.
    fn basic_string_end(&self, start: usize) -> usize {
        let mut i = start + 1;
        while i < self.b.len() {
            match self.b[i] {
                b'\\' => i += 2,
                b'"' => return i + 1,
                _ => i += 1,
            }
        }
        self.b.len()
    }

    /// After the `"""` block string starting at `start`.
    fn block_string_end(&self, start: usize) -> usize {
        let mut i = start + 3;
        while i < self.b.len() {
            match self.b[i] {
                b'\\' => i += 1,
                b'"' if self.b[i..].starts_with(b"\"\"\"") => return i + 3,
                _ => {}
            }
            i += 1;
        }
        self.b.len()
    }

    /// Whitespace and comments, recording the comments.
    fn trivia(&mut self) {
        loop {
            match (self.b.get(self.pos), self.b.get(self.pos + 1)) {
                (Some(b' ' | b'\t' | b'\n' | b'\r'), _) => self.pos += 1,
                (Some(b'/'), Some(b'/')) => {
                    let end = self.src[self.pos..].find('\n').map_or(self.b.len(), |n| self.pos + n);
                    self.doc.comments.push((self.pos, end));
                    self.pos = end;
                }
                (Some(b'/'), Some(b'*')) => {
                    let open = self.pos;
                    let mut depth = 0usize;
                    while self.pos < self.b.len() {
                        let rest = &self.b[self.pos..];
                        if rest.starts_with(b"/*") {
                            depth += 1;
                            self.pos += 2;
                        } else if rest.starts_with(b"*/") {
                            self.pos += 2;
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        } else {
                            self.pos += 1;
                        }
                    }
                    self.doc.comments.push((open, self.pos));
                }
                _ => return,
            }
        }
    }
}

// ── layout ─────────────────────────────────────────────────────────────────

struct Formatter<'a> {
    src: &'a str,
    doc: &'a Document,
    step: usize,
    width: i64,
    /// What goes between tokens on one line.
    gaps: Gaps,
}

/// The whitespace between tokens on one line: the minimised layout has none.
#[derive(Clone, Copy)]
struct Gaps {
    /// Between entries: `, `.
    comma: &'static str,
    /// After a key: `: `.
    colon: &'static str,
    /// Inside a non-empty record: `{ ` and ` }`.
    open: &'static str,
    close: &'static str,
    /// Between a tag and its record payload: `Tag {`.
    tag: &'static str,
}

impl Gaps {
    const SPACED: Gaps = Gaps { comma: ", ", colon: ": ", open: "{ ", close: " }", tag: " " };
    const NONE: Gaps = Gaps { comma: ",", colon: ":", open: "{", close: "}", tag: "" };
}

/// One entry of a container: a record field, an array item, a payload
/// argument, a top-level value.
struct Entry<'a> {
    /// The whole entry (key included).
    start: usize,
    end: usize,
    /// Where the value starts (after `key:`); comments before it move above the entry.
    value_start: usize,
    /// Written before the value: `key: ` for a record field.
    prefix: String,
    node: &'a Node,
}

/// The entries of one container (or of the file), being written one after the other.
struct EntryList<'a> {
    entries: Vec<Entry<'a>>,
    level: usize,
    sep: &'static str,
    blank_after_multiline: bool,
    /// Comments placed before, after (on the same line) each entry, and after the last one.
    leading: Vec<Vec<Span>>,
    trailing: Vec<Vec<Span>>,
    dangling: Vec<Span>,
    /// The next entry to write.
    next: usize,
    /// Source offset after what was written last, to keep a blank line before the next entry.
    cursor: usize,
    first: bool,
    prev_multiline: bool,
}

/// What is left to write, on a stack: a closing bracket, a value, the rest
/// of a list of entries (an index into the lists), or the end of an entry
/// (its separator and trailing comments).
enum Task<'a> {
    Close { level: usize, close: char },
    Value { node: &'a Node, level: usize, used: i64 },
    Entries(usize),
    EntryEnd { list: usize, index: usize, mark: usize },
}

/// One line being rendered, and its width in code points.
struct Line {
    out: String,
    width: i64,
}

impl Line {
    fn push(&mut self, s: &str) {
        self.out.push_str(s);
        self.width += width(s);
    }
}

/// The width of `s`: its code points.
fn width(s: &str) -> i64 {
    let n = if s.is_ascii() { s.len() } else { s.chars().count() };
    i64::try_from(n).unwrap_or(i64::MAX)
}

/// Single-line rendering: what is left to write.
enum Piece<'a> {
    Node(&'a Node),
    Text(&'static str),
    /// A record key, after `, ` unless it is the first.
    Key(&'a str, bool),
}

/// The state of a multi-line layout.
struct Writer<'a> {
    out: String,
    lists: Vec<EntryList<'a>>,
    tasks: Vec<Task<'a>>,
}

impl<'a> Formatter<'a> {
    fn node(&self, i: usize) -> &'a Node {
        &self.doc.nodes[i]
    }

    fn pretty(&self) -> String {
        let roots: Vec<Entry<'a>> = self.doc.roots.iter().map(|&i| self.entry_of(i)).collect();
        let stream = roots.len() > 1;
        let mut w = Writer { out: String::new(), lists: Vec::new(), tasks: Vec::new() };
        let list = self.entry_list(0, self.src.len(), roots, 0, if stream { "," } else { "" }, stream);
        w.lists.push(list);
        w.tasks.push(Task::Entries(0));
        self.run(&mut w);
        let mut out = w.out;
        if out.ends_with('\n') {
            out.pop();
        }
        if !out.is_empty() {
            out.push('\n');
        }
        out
    }

    /// The compact or minimised layout: every top-level item on one line.
    fn lines(&self) -> String {
        let line = |&i: &usize| self.inline(self.node(i), false, i64::MAX).unwrap_or_default();
        match self.doc.roots.as_slice() {
            [] => String::new(),
            [one] => line(one) + "\n",
            roots => roots.iter().map(|i| line(i) + ",\n").collect(),
        }
    }

    // ── single line ────────────────────────────────────────────

    /// `node` on one line, or None if it is wider than `budget`. Pretty: also
    /// None if it can't be written on one line (a block string, a non-empty
    /// record or array). Loops over a stack, like `run`.
    fn inline(&self, node: &'a Node, pretty: bool, budget: i64) -> Option<String> {
        let mut line = Line { out: String::new(), width: 0 };
        let mut work = vec![Piece::Node(node)];
        while let Some(piece) = work.pop() {
            match piece {
                Piece::Text(t) => line.push(t),
                Piece::Key(k, first) => {
                    if !first {
                        line.push(self.gaps.comma);
                    }
                    let mut text = String::new();
                    key(k, &mut text);
                    text.push_str(self.gaps.colon);
                    line.push(&text);
                }
                Piece::Node(n) => match &n.kind {
                    Kind::Number | Kind::Bytes => line.push(self.original(n)),
                    Kind::String(s) => {
                        if pretty && s.contains('\n') {
                            return None;
                        }
                        line.push(&self.basic_string(n, s));
                    }
                    Kind::Array(items) => {
                        if pretty && !items.is_empty() {
                            return None;
                        }
                        line.push("[");
                        self.items(&mut work, items, "]");
                    }
                    Kind::Record(fields) => self.inline_record(&mut line, &mut work, fields, pretty)?,
                    Kind::Variant { tag_end, args, .. } => {
                        line.push(&self.src[n.start..*tag_end]);
                        match self.record_payload(args) {
                            Some(fields) => {
                                line.push(self.gaps.tag);
                                self.inline_record(&mut line, &mut work, fields, pretty)?;
                            }
                            None if args.is_empty() => {}
                            None => {
                                line.push("(");
                                self.items(&mut work, args, ")");
                            }
                        }
                    }
                },
            }
            // Too wide to stay inline anyway: stop early, so nested payloads
            // aren't rendered in full at every level (quadratic in the depth).
            if line.width > budget {
                return None;
            }
        }
        Some(line.out)
    }

    /// `items` next, separated by commas, then `close`.
    fn items(&self, work: &mut Vec<Piece<'a>>, items: &[usize], close: &'static str) {
        work.push(Piece::Text(close));
        for (i, &item) in items.iter().enumerate().rev() {
            work.push(Piece::Node(self.node(item)));
            if i > 0 {
                work.push(Piece::Text(self.gaps.comma));
            }
        }
    }

    /// A record on one line; None in the pretty layout unless it is empty.
    fn inline_record(
        &self,
        line: &mut Line,
        work: &mut Vec<Piece<'a>>,
        fields: &'a [Field],
        pretty: bool,
    ) -> Option<()> {
        if fields.is_empty() {
            line.push("{}");
        } else if pretty {
            return None;
        } else {
            line.push(self.gaps.open);
            work.push(Piece::Text(self.gaps.close));
            for (i, f) in fields.iter().enumerate().rev() {
                work.push(Piece::Node(self.node(f.value)));
                work.push(Piece::Key(&f.key, i == 0));
            }
        }
        Some(())
    }

    /// The fields of a variant's payload if it is one record (`Tag { … }`, `Tag({ … })`).
    fn record_payload(&self, args: &[usize]) -> Option<&'a [Field]> {
        match args {
            [one] => match &self.node(*one).kind {
                Kind::Record(fields) => Some(fields),
                _ => None,
            },
            _ => None,
        }
    }

    // ── multi-line ─────────────────────────────────────────────

    /// Write the tasks of `w` until none are left.
    fn run(&self, w: &mut Writer<'a>) {
        while let Some(task) = w.tasks.pop() {
            match task {
                Task::Close { level, close } => {
                    self.indent(&mut w.out, level);
                    w.out.push(close);
                }
                Task::Value { node, level, used } => self.write_value(w, node, level, used),
                Task::Entries(list) => self.next_entry(w, list),
                Task::EntryEnd { list, index, mark } => {
                    let l = &mut w.lists[list];
                    let multiline = l.blank_after_multiline && w.out[mark..].contains('\n');
                    w.out.push_str(l.sep);
                    for c in &l.trailing[index] {
                        w.out.push(' ');
                        w.out.push_str(&self.text(*c));
                    }
                    w.out.push('\n');
                    l.cursor = l.trailing[index].last().map_or(l.entries[index].end, |c| c.1);
                    l.prev_multiline = multiline;
                }
            }
        }
    }

    /// `node` at indentation `level`, with `used` columns already taken on
    /// the current line: inline if it fits, else broken.
    fn write_value(&self, w: &mut Writer<'a>, node: &'a Node, level: usize, used: i64) {
        if !self.has_comments(node.start, node.end)
            && let Some(flat) = self.inline(node, true, self.width.saturating_sub(used))
        {
            return w.out.push_str(&flat);
        }
        match &node.kind {
            Kind::Number | Kind::Bytes => w.out.push_str(self.original(node)),
            Kind::String(s) if s.contains('\n') => self.block_string(&mut w.out, s, level + 1),
            Kind::String(s) => w.out.push_str(&self.basic_string(node, s)),
            Kind::Array(items) => {
                let entries = items.iter().map(|&i| self.entry_of(i)).collect();
                self.container(w, ('[', ']'), (node.start + 1, node.end - 1), entries, level);
            }
            Kind::Record(fields) => self.record(w, fields, (node.start + 1, node.end - 1), level),
            Kind::Variant { tag_end, args, paren } => {
                w.out.push_str(&self.src[node.start..*tag_end]);
                if args.is_empty() {
                    return;
                }
                let record = self.node(args[0]);
                // `Tag(…)`: between the parentheses; `Tag { … }`: between the braces.
                let span = match paren {
                    Some(p) => (p + 1, node.end - 1),
                    None => (record.start + 1, record.end - 1),
                };
                if let [_] = args.as_slice()
                    && let Kind::Record(fields) = &record.kind
                {
                    // In `Tag({ … })`, comments between the parentheses and the braces move inside the braces.
                    w.out.push(' ');
                    return self.record(w, fields, span, level);
                }
                let entries = args.iter().map(|&i| self.entry_of(i)).collect();
                self.container(w, ('(', ')'), span, entries, level);
            }
        }
    }

    /// A record broken over lines, with the comments in `span`.
    fn record(&self, w: &mut Writer<'a>, fields: &'a [Field], span: Span, level: usize) {
        let entries = fields
            .iter()
            .map(|f| {
                let value = self.node(f.value);
                let mut prefix = String::new();
                key(&f.key, &mut prefix);
                prefix.push_str(": ");
                Entry { start: f.start, end: value.end, value_start: value.start, prefix, node: value }
            })
            .collect();
        self.container(w, ('{', '}'), span, entries, level);
    }

    /// `open` + one entry per line (comments and blank lines kept) + `close`.
    fn container(
        &self,
        w: &mut Writer<'a>,
        (open, close): (char, char),
        (from, to): Span,
        entries: Vec<Entry<'a>>,
        level: usize,
    ) {
        w.out.push(open);
        if entries.is_empty() && !self.has_comments(from, to) {
            return w.out.push(close);
        }
        w.out.push('\n');
        let list = self.entry_list(from, to, entries, level + 1, ",", false);
        w.lists.push(list);
        w.tasks.push(Task::Close { level, close });
        w.tasks.push(Task::Entries(w.lists.len() - 1));
    }

    /// Entries at indentation `level`, each to be written on its own line(s)
    /// ending in "\n", with the comments in `[from, to)` placed next to them.
    fn entry_list(
        &self,
        from: usize,
        to: usize,
        entries: Vec<Entry<'a>>,
        level: usize,
        sep: &'static str,
        blank_after_multiline: bool,
    ) -> EntryList<'a> {
        let mut leading = vec![Vec::new(); entries.len()];
        let mut trailing = vec![Vec::new(); entries.len()];
        let mut dangling = Vec::new();
        // Comments and entries are sorted by position, so binary search keeps
        // this linear in the comments of this container (not all comments).
        let starts: Vec<usize> = entries.iter().map(|e| e.start).collect();
        let ends: Vec<usize> = entries.iter().map(|e| e.end).collect();
        let comments = &self.doc.comments;
        for &c in &comments[comments.partition_point(|c| c.0 < from)..] {
            let (cs, ce) = c;
            if cs >= to {
                break;
            }
            if ce > to {
                continue;
            }
            // The last entry starting at or before the comment.
            let last = starts.partition_point(|&s| s <= cs).checked_sub(1);
            if let Some(owner) = last.filter(|&i| cs < ends[i]) {
                // Inside an entry: between key and value it moves above the
                // entry; deeper inside, the nested container places it.
                if cs < entries[owner].value_start {
                    leading[owner].push(c);
                }
                continue;
            }
            // The last entry ending at or before the comment, and the first starting after it.
            let prev = ends.partition_point(|&e| e <= cs).checked_sub(1);
            let next = starts.partition_point(|&s| s < ce);
            match prev {
                Some(p) if !self.src[entries[p].end..cs].contains('\n') => trailing[p].push(c),
                _ if next < entries.len() => leading[next].push(c),
                _ => dangling.push(c),
            }
        }
        EntryList {
            entries,
            level,
            sep,
            blank_after_multiline,
            leading,
            trailing,
            dangling,
            next: 0,
            cursor: from,
            first: true,
            prev_multiline: false,
        }
    }

    /// Write the next entry of a list (its leading comments, then the
    /// entry), or the comments after the last one.
    fn next_entry(&self, w: &mut Writer<'a>, list: usize) {
        let l = &mut w.lists[list];
        let (i, level) = (l.next, l.level);
        let Some(e) = l.entries.get(i) else {
            l.prev_multiline = false;
            for c in std::mem::take(&mut l.dangling) {
                self.comment_line(&mut w.out, l, c);
            }
            return;
        };
        let (start, node, prefix) = (e.start, e.node, std::mem::take(&mut l.entries[i].prefix));
        l.next += 1;
        for c in std::mem::take(&mut l.leading[i]) {
            self.comment_line(&mut w.out, l, c);
        }
        self.start_line(&mut w.out, l, start);
        let ind = level * self.step;
        push_spaces(&mut w.out, ind);
        w.out.push_str(&prefix);
        // The comma after the entry counts towards the width.
        let used = i64::try_from(ind + l.sep.len()).unwrap_or(i64::MAX).saturating_add(width(&prefix));
        w.tasks.push(Task::Entries(list));
        w.tasks.push(Task::EntryEnd { list, index: i, mark: w.out.len() });
        w.tasks.push(Task::Value { node, level, used });
    }

    /// A comment on a line of its own.
    fn comment_line(&self, out: &mut String, l: &mut EntryList<'a>, c: Span) {
        self.start_line(out, l, c.0);
        push_spaces(out, l.level * self.step);
        out.push_str(&self.text(c));
        out.push('\n');
        l.cursor = c.1;
    }

    /// Before a line starting at source offset `start`: a blank line if the
    /// source had one there (at most one), or after a multi-line entry.
    fn start_line(&self, out: &mut String, l: &mut EntryList<'a>, start: usize) {
        let blank = start > l.cursor && has_blank_line(&self.src.as_bytes()[l.cursor..start]);
        if !l.first && (blank || l.prev_multiline) {
            out.push('\n');
        }
        l.first = false;
        l.prev_multiline = false;
    }

    fn indent(&self, out: &mut String, level: usize) {
        push_spaces(out, level * self.step);
    }

    /// A comment's text, with LF line endings (a carriage return in a
    /// comment is always part of a CR LF).
    fn text(&self, c: Span) -> std::borrow::Cow<'a, str> {
        let text = &self.src[c.0..c.1];
        if text.contains('\r') { text.replace('\r', "").into() } else { text.into() }
    }

    /// Is there a comment inside `[start, end)`?
    fn has_comments(&self, start: usize, end: usize) -> bool {
        let comments = &self.doc.comments;
        comments.get(comments.partition_point(|c| c.0 < start)).is_some_and(|c| c.0 < end)
    }

    /// An array item, a payload argument or a top-level value as an entry.
    fn entry_of(&self, i: usize) -> Entry<'a> {
        let node = self.node(i);
        Entry { start: node.start, end: node.end, value_start: node.start, prefix: String::new(), node }
    }

    // ── leaves ─────────────────────────────────────────────────

    /// The value's source text.
    fn original(&self, n: &Node) -> &'a str {
        &self.src[n.start..n.end]
    }

    /// The original spelling, unless it was a block string (those span
    /// lines). Raw line and paragraph separators, which the parser accepts
    /// but some software breaks lines at, are escaped (spec §11).
    fn basic_string(&self, n: &Node, s: &str) -> String {
        let original = self.original(n);
        if original.starts_with('"') && !original.starts_with("\"\"\"") {
            return original.replace('\u{2028}', "\\u{2028}").replace('\u{2029}', "\\u{2029}");
        }
        let mut out = String::new();
        quote(s, &mut out);
        out
    }

    /// A `"""` block string whose content and closing quotes sit at `level`.
    fn block_string(&self, out: &mut String, s: &str, level: usize) {
        let ind = level * self.step;
        out.push_str("\"\"\"\n");
        for line in s.split('\n') {
            let escaped = block_line(line);
            if !escaped.is_empty() {
                push_spaces(out, ind);
                out.push_str(&escaped);
            }
            out.push('\n');
        }
        push_spaces(out, ind);
        out.push_str("\"\"\"");
    }
}

/// One line of a block string, escaped: backslashes, carriage returns,
/// control and bidi characters, line and paragraph separators, every quote
/// that has two more after it (a run of three would close the string early),
/// and the last space or tab of a line that ends in one (`\u{20}`, `\t`), so
/// that no line ends in a blank an editor might trim (spec §11).
fn block_line(line: &str) -> String {
    let mut escaped = String::with_capacity(line.len());
    for c in line.chars() {
        match c {
            '\\' => escaped.push_str("\\\\"),
            '\r' => escaped.push_str("\\r"),
            c if (matches!(u32::from(c), 0..0x20 | 0x7F..=0x9F) && c != '\t')
                || matches!(c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{2028}' | '\u{2029}') =>
            {
                let _ = write!(escaped, "\\u{{{:X}}}", u32::from(c));
            }
            c => escaped.push(c),
        }
    }
    // Escapes end in a letter or `}`, so a blank at the end is a raw one.
    match escaped.pop() {
        Some(' ') => escaped.push_str("\\u{20}"),
        Some('\t') => escaped.push_str("\\t"),
        Some(c) => escaped.push(c),
        None => {}
    }
    if !escaped.contains("\"\"\"") {
        return escaped;
    }
    let b = escaped.as_bytes();
    let mut out = String::with_capacity(escaped.len() + 8);
    for (i, c) in escaped.char_indices() {
        if c == '"' && b.get(i + 1) == Some(&b'"') && b.get(i + 2) == Some(&b'"') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// A line break, spaces and tabs, then another line break (CR LF counts).
fn has_blank_line(b: &[u8]) -> bool {
    b.iter().enumerate().any(|(i, &c)| {
        if c != b'\n' {
            return false;
        }
        let mut j = i + 1;
        while matches!(b.get(j), Some(b' ' | b'\t')) {
            j += 1;
        }
        if b.get(j) == Some(&b'\r') {
            j += 1;
        }
        b.get(j) == Some(&b'\n')
    })
}

fn push_spaces(out: &mut String, n: usize) {
    out.extend(std::iter::repeat_n(' ', n));
}
