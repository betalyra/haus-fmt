//! Where each value of a data file is: a tree of spans with the shape of the
//! values `haus::parse` gives for the same text, so that a check can point
//! at the value, key or tag it reports.
//!
//! It scans text the parser has already accepted, so it only has to find
//! where things start and end; anything unexpected gives no locations
//! rather than wrong ones.

/// A value's span (byte offsets, end exclusive), and its parts.
#[derive(Debug, Clone)]
pub(crate) struct Node {
    pub start: usize,
    pub end: usize,
    /// For a variant, where its tag ends.
    pub tag_end: usize,
    pub kids: Kids,
}

#[derive(Debug, Clone)]
pub(crate) enum Kids {
    Leaf,
    /// Array items, or the arguments of a variant (`Tag { … }`: one record).
    Items(Vec<Node>),
    /// Record fields: the key's span, and the value.
    Fields(Vec<((usize, usize), Node)>),
}

impl Node {
    pub fn item(&self, i: usize) -> Option<&Node> {
        match &self.kids {
            Kids::Items(items) => items.get(i),
            _ => None,
        }
    }

    pub fn field(&self, i: usize) -> Option<&((usize, usize), Node)> {
        match &self.kids {
            Kids::Fields(fields) => fields.get(i),
            _ => None,
        }
    }
}

/// The top-level values of `text`, which `haus::parse` accepts.
pub(crate) fn locate(text: &str) -> Option<Vec<Node>> {
    let b = text.as_bytes();
    let mut s = Scan { b, pos: if text.starts_with('\u{FEFF}') { 3 } else { 0 } };
    let mut out = vec![];
    s.trivia();
    while s.pos < b.len() {
        out.push(s.value()?);
        s.trivia();
        if s.pos < b.len() {
            s.eat(b',')?;
            s.trivia();
        }
    }
    Some(out)
}

struct Scan<'a> {
    b: &'a [u8],
    pos: usize,
}

impl Scan<'_> {
    fn peek(&self) -> Option<u8> {
        self.b.get(self.pos).copied()
    }

    fn rest(&self) -> &[u8] {
        &self.b[self.pos.min(self.b.len())..]
    }

    fn eat(&mut self, c: u8) -> Option<()> {
        (self.peek() == Some(c)).then(|| self.pos += 1)
    }

    fn trivia(&mut self) {
        loop {
            match self.peek() {
                Some(b' ' | b'\t' | b'\n' | b'\r') => self.pos += 1,
                Some(b'/') if self.rest().starts_with(b"//") => {
                    self.pos += self.rest().iter().position(|&c| c == b'\n').unwrap_or(self.rest().len());
                }
                Some(b'/') if self.rest().starts_with(b"/*") => {
                    let mut depth = 0usize;
                    while self.pos < self.b.len() {
                        if self.rest().starts_with(b"/*") {
                            depth += 1;
                            self.pos += 2;
                        } else if self.rest().starts_with(b"*/") {
                            depth -= 1;
                            self.pos += 2;
                            if depth == 0 {
                                break;
                            }
                        } else {
                            self.pos += 1;
                        }
                    }
                }
                _ => return,
            }
        }
    }

    fn leaf(&self, start: usize) -> Node {
        Node { start, end: self.pos, tag_end: start, kids: Kids::Leaf }
    }

    fn value(&mut self) -> Option<Node> {
        let start = self.pos;
        match self.peek()? {
            b'{' => self.record(),
            b'[' => {
                self.pos += 1;
                let items = self.items(b']')?;
                Some(Node { start, end: self.pos, tag_end: start, kids: Kids::Items(items) })
            }
            b'"' => {
                self.string();
                Some(self.leaf(start))
            }
            b'x' if self.b.get(self.pos + 1) == Some(&b'"') => {
                self.pos += 2;
                self.pos += self.rest().iter().position(|&c| c == b'"')? + 1;
                Some(self.leaf(start))
            }
            b'-' | b'0'..=b'9' => {
                self.pos += 1;
                while matches!(self.peek(), Some(c) if c.is_ascii_alphanumeric() || b"_.+-".contains(&c)) {
                    self.pos += 1;
                }
                Some(self.leaf(start))
            }
            c if c.is_ascii_uppercase() => {
                self.ident();
                let tag_end = self.pos;
                while matches!(self.peek(), Some(b' ' | b'\t')) {
                    self.pos += 1;
                }
                let args = match self.peek() {
                    Some(b'(') => {
                        self.pos += 1;
                        self.items(b')')?
                    }
                    Some(b'{') => vec![self.record()?],
                    _ => {
                        self.pos = tag_end;
                        vec![]
                    }
                };
                Some(Node { start, end: self.pos, tag_end, kids: Kids::Items(args) })
            }
            _ => None,
        }
    }

    fn ident(&mut self) {
        while matches!(self.peek(), Some(c) if c.is_ascii_alphanumeric() || c == b'_') {
            self.pos += 1;
        }
    }

    /// A string or block string; escapes are skipped whole.
    fn string(&mut self) {
        let block = self.rest().starts_with(b"\"\"\"");
        self.pos += if block { 3 } else { 1 };
        while let Some(c) = self.peek() {
            match c {
                b'\\' => self.pos += 2,
                b'"' if !block => {
                    self.pos += 1;
                    return;
                }
                b'"' if self.rest().starts_with(b"\"\"\"") => {
                    self.pos += 3;
                    return;
                }
                _ => self.pos += 1,
            }
        }
    }

    /// Values up to `close`, after the opening bracket.
    fn items(&mut self, close: u8) -> Option<Vec<Node>> {
        let mut out = vec![];
        self.trivia();
        while self.peek()? != close {
            out.push(self.value()?);
            self.trivia();
            if self.eat(b',').is_some() {
                self.trivia();
            }
        }
        self.pos += 1;
        Some(out)
    }

    fn record(&mut self) -> Option<Node> {
        let start = self.pos;
        self.eat(b'{')?;
        let mut fields = vec![];
        self.trivia();
        while self.peek()? != b'}' {
            let key_start = self.pos;
            match self.peek()? {
                b'"' => self.string(),
                _ => self.ident(),
            }
            let key = (key_start, self.pos);
            self.trivia();
            self.eat(b':')?;
            self.trivia();
            fields.push((key, self.value()?));
            self.trivia();
            if self.eat(b',').is_some() {
                self.trivia();
            }
        }
        self.pos += 1;
        Some(Node { start, end: self.pos, tag_end: start, kids: Kids::Fields(fields) })
    }
}

/// Line and column of byte offsets (1-based; columns in code points, spec §8).
pub(crate) struct Lines<'a> {
    text: &'a str,
    starts: Vec<usize>,
}

impl<'a> Lines<'a> {
    pub fn new(text: &'a str) -> Lines<'a> {
        let starts = std::iter::once(0).chain(text.match_indices('\n').map(|(i, _)| i + 1)).collect();
        Lines { text, starts }
    }

    pub fn position(&self, offset: usize) -> (usize, usize) {
        let offset = offset.min(self.text.len());
        let line = self.starts.partition_point(|&s| s <= offset) - 1;
        let start = self.starts[line];
        let column = self.text.get(start..offset).map_or(offset - start, |s| s.chars().count());
        (line + 1, column + 1)
    }
}
