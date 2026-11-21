//! Exit statuses, colors, and writing to standard output.

use crate::cli::Color;
use annotate_snippets::Renderer;
use std::io::{self, IsTerminal, Write};
use std::path::Path;

/// How a command ended: its exit code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
    /// Everything is fine (hints and warnings allowed).
    Ok = 0,
    /// Invalid data, or files that would change.
    Invalid = 1,
    /// A usage or I/O error.
    Failed = 2,
}

/// Whether to color output going to `stream`: `auto` colors a terminal,
/// unless NO_COLOR is set to anything but the empty string.
pub fn colored(choice: Color, stream: &impl IsTerminal) -> bool {
    match choice {
        Color::Always => true,
        Color::Never => false,
        Color::Auto => stream.is_terminal() && std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty()),
    }
}

/// How a path is shown: as given or found, with `/` between its parts on
/// every system, so output and JSON reports read the same on Windows.
pub fn shown(path: impl AsRef<Path>) -> String {
    let text = path.as_ref().display().to_string();
    if cfg!(windows) { text.replace('\\', "/") } else { text }
}

/// The diagnostics renderer, styled or plain.
pub fn renderer(color: bool) -> Renderer {
    if color { Renderer::styled() } else { Renderer::plain() }
}

/// `text` on standard output, flushed. A closed pipe (`haus canonical x | head`)
/// is not an error.
pub fn print(text: &str) -> io::Result<()> {
    match write(text) {
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Ok(()),
        result => result,
    }
}

/// `text` on standard output, flushed; a closed pipe is an error, for a
/// command that should stop writing.
pub fn write(text: &str) -> io::Result<()> {
    let mut out = io::stdout().lock();
    out.write_all(text.as_bytes()).and_then(|()| out.flush())
}

/// `text` on standard error; nothing to do if that fails.
pub fn eprint(text: &str) {
    let _ = io::stderr().lock().write_all(text.as_bytes());
}

/// A usage or I/O error, on standard error.
pub fn fail(message: impl std::fmt::Display) -> Status {
    eprint(&format!("error: {message}\n"));
    Status::Failed
}

/// `n` and the noun, plural if needed: `1 file`, `2 errors`.
pub fn count(n: usize, noun: &str) -> String {
    match n {
        1 => format!("1 {noun}"),
        n => format!("{n} {noun}s"),
    }
}
