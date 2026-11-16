//! A stream (spec §6) read value by value, with each value's text and place,
//! so that commands can report on a value, or print it, as soon as its comma
//! arrives: `tail -f events.haus | haus check -` shows each error live.
//!
//! The values are found by haus's own stream reader. Each chunk is pushed in
//! pieces that end at a comma; a value can only end at a top-level comma, and
//! such a comma never waits for more input, so a value the reader returns
//! ends at the comma just pushed. The bytes since the previous one are its text.

use crate::diagnostic::{self, Diagnostic};
use haus::stream::{Options, Reader};
use haus::{SyntaxError, Value};
use std::collections::VecDeque;
use std::fs::File;
use std::io::{self, Read};
use std::ops::Range;

/// The longest start of a line kept for excerpts: a stream of values with no
/// line break between them would otherwise keep all of them.
const MAX_PREFIX: usize = 64 * 1024;

/// One top-level value of a stream, and the text around it.
pub struct Piece {
    /// The value; none for what follows the last comma when it is only
    /// whitespace and comments (or an empty input).
    pub values: Vec<Value>,
    /// From after the previous comma (or the start) to before its own comma
    /// (or the end), comments and whitespace included.
    pub text: String,
    /// Whether a comma ends it, rather than the end of the input.
    pub comma: bool,
    /// Line and column (1-based, columns in code points) where `text` starts.
    pub line: usize,
    pub column: usize,
    /// What is before `text` on its first line, for excerpts; None if too long to keep.
    prefix: Option<String>,
}

impl Piece {
    /// `d`, at `span` of `text`: its line and column in the stream, and the
    /// source line in its excerpt.
    pub fn place(&self, d: Diagnostic, span: Range<usize>) -> Diagnostic {
        match &self.prefix {
            Some(prefix) => {
                let comma = if self.comma { "," } else { "" };
                let window = format!("{prefix}{}{comma}", self.text);
                let span = span.start + prefix.len()..span.end + prefix.len();
                d.at(&window, span).on_line(self.line)
            }
            None => {
                let (line, column) = diagnostic::position(&self.text, span.start);
                let column = if line == 1 { self.column + column - 1 } else { column };
                d.placed(self.line + line - 1, column)
            }
        }
    }
}

/// The values of a stream, read from `input` as they arrive. It ends after the first error.
pub struct Pieces<R> {
    input: R,
    /// None once the input is finished, or after an error.
    reader: Option<Reader>,
    ready: VecDeque<Piece>,
    chunk: Vec<u8>,
    /// The bytes of the current value so far.
    pending: Vec<u8>,
    /// Where `pending` starts: byte offset, line and column.
    offset: usize,
    line: usize,
    column: usize,
    /// The line `pending` starts on, up to there.
    prefix: Option<String>,
}

impl<R: Read> Pieces<R> {
    pub fn new(input: R, options: Options) -> Pieces<R> {
        Pieces {
            input,
            reader: Some(Reader::new(options)),
            ready: VecDeque::new(),
            chunk: vec![0; 64 * 1024],
            pending: Vec::new(),
            offset: 0,
            line: 1,
            column: 1,
            prefix: Some(String::new()),
        }
    }

    /// Whether the next value needs more input: before waiting for it, a
    /// command flushes what it wrote for the values so far.
    pub fn waiting(&self) -> bool {
        self.ready.is_empty() && self.reader.is_some()
    }

    /// A syntax error the stream ended with, as a diagnostic with its excerpt.
    pub fn diagnostic(&self, e: &SyntaxError) -> Diagnostic {
        let Some(prefix) = &self.prefix else { return Diagnostic::syntax(e, None) };
        let window = format!("{prefix}{}", String::from_utf8_lossy(&self.pending));
        let mut relative = e.clone();
        relative.offset = (e.offset + prefix.len()).saturating_sub(self.offset).min(window.len());
        Diagnostic::syntax(&relative, Some(&window))
    }

    /// Read until there are values, or the input ends.
    fn fill(&mut self) -> Result<(), haus::Error> {
        while self.ready.is_empty() {
            let Some(mut reader) = self.reader.take() else { return Ok(()) };
            let n = match self.input.read(&mut self.chunk) {
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {
                    self.reader = Some(reader);
                    continue;
                }
                result => result?,
            };
            if n == 0 {
                let values = reader.finish()?;
                self.cut(values, false);
                return Ok(());
            }
            let chunk = std::mem::take(&mut self.chunk);
            for part in chunk[..n].split_inclusive(|&b| b == b',') {
                self.pending.extend_from_slice(part);
                let values = reader.push(part)?;
                if !values.is_empty() {
                    self.cut(values, true);
                }
            }
            self.chunk = chunk;
            self.reader = Some(reader);
        }
        Ok(())
    }

    /// The value in `pending` is complete: queue it, and move past it.
    fn cut(&mut self, values: Vec<Value>, comma: bool) {
        let bytes = std::mem::take(&mut self.pending);
        let consumed = String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned());
        let text = match comma {
            true => consumed.strip_suffix(',').unwrap_or(&consumed).to_owned(),
            false => consumed.clone(),
        };
        let piece = Piece { values, text, comma, line: self.line, column: self.column, prefix: self.prefix.clone() };
        self.ready.push_back(piece);
        self.offset += consumed.len();
        for c in consumed.chars() {
            (self.line, self.column) = if c == '\n' { (self.line + 1, 1) } else { (self.line, self.column + 1) };
        }
        self.prefix = match consumed.rsplit_once('\n') {
            Some((_, last)) => Some(last.to_owned()),
            None => self.prefix.take().map(|p| p + &consumed),
        }
        .filter(|p| p.len() <= MAX_PREFIX);
    }
}

impl<R: Read> Iterator for Pieces<R> {
    type Item = Result<Piece, haus::Error>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Err(e) = self.fill() {
            self.reader = None;
            return Some(Err(e));
        }
        self.ready.pop_front().map(Ok)
    }
}

/// Whether standard input is a regular file (`haus canonical < x.haus`)
/// rather than a pipe, a terminal or a FIFO, whose data may come slowly.
pub fn stdin_is_file() -> bool {
    #[cfg(unix)]
    let handle = std::os::fd::AsFd::as_fd(&io::stdin()).try_clone_to_owned();
    #[cfg(windows)]
    let handle = std::os::windows::io::AsHandle::as_handle(&io::stdin()).try_clone_to_owned();
    #[cfg(not(any(unix, windows)))]
    let handle: io::Result<File> = Err(io::ErrorKind::Unsupported.into());
    handle.map(File::from).and_then(|f| f.metadata()).is_ok_and(|m| m.is_file())
}

/// Whether the open file `f` is a regular file, rather than a FIFO or a device.
pub fn is_file(f: &File) -> bool {
    f.metadata().is_ok_and(|m| m.is_file())
}
