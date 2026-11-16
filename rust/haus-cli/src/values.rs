//! `haus canonical` and `haus hash` (spec §12), on a stream: values are
//! handled as they are read, so memory stays bounded by the largest value.
//! When the input may come slowly (a pipe, a terminal, a FIFO), what was
//! written for the values so far is flushed before waiting for more.

use crate::cli::{CanonicalArgs, Color, HashArgs, LimitArgs};
use crate::diagnostic::Diagnostic;
use crate::highlight::highlight;
use crate::input::STDIN;
use crate::output::{self, Status};
use crate::pieces::{self, Pieces};
use haus::Value;
use std::fs::File;
use std::io::{self, BufWriter, IsTerminal, Read, Write, stderr, stdout};
use std::path::Path;

/// Print each value's canonical form on its own line, colored on a terminal.
pub fn canonical(args: &CanonicalArgs, color: Color) -> Status {
    let colored = output::colored(color, &stdout());
    each_value(args.file.as_deref(), &args.limits, color, |out, v| match colored {
        true => writeln!(out, "{}", highlight(&haus::canonical(v))),
        false => writeln!(out, "{}", haus::canonical(v)),
    })
}

/// Print `hashAll` of the values, or with --each the hash of each value.
pub fn hash(args: &HashArgs, color: Color) -> Status {
    let file = args.file.as_deref();
    if args.each {
        return each_value(file, &args.limits, color, |out, v| writeln!(out, "{}", haus::hash(v)));
    }
    let mut hasher = haus::Hasher::new();
    let add = |_: &mut dyn Write, v: &Value| {
        hasher.add(v);
        Ok(())
    };
    match each_value(file, &args.limits, color, add) {
        Status::Ok => output::print(&format!("{}\n", hasher.digest())).map_or_else(output::fail, |()| Status::Ok),
        status => status,
    }
}

/// Read the stream in `file` (None or `-`: standard input), calling `value`
/// for each value. A syntax error is reported on standard error; what was
/// written before it stays written.
fn each_value(
    file: Option<&Path>,
    limits: &LimitArgs,
    color: Color,
    mut value: impl FnMut(&mut dyn Write, &Value) -> io::Result<()>,
) -> Status {
    let (name, input, live): (String, Box<dyn Read>, bool) = match file.filter(|f| *f != Path::new("-")) {
        Some(path) => match File::open(path) {
            Ok(f) => {
                let live = !pieces::is_file(&f);
                (path.display().to_string(), Box::new(f), live)
            }
            Err(e) => return output::fail(format!("cannot read {}: {e}", path.display())),
        },
        None if file.is_none() && io::stdin().is_terminal() => {
            return output::fail("no input: give a FILE, or pipe the data in (`-` reads standard input)");
        }
        None => (STDIN.to_owned(), Box::new(io::stdin().lock()), !pieces::stdin_is_file()),
    };
    let options = haus::stream::Options { limits: limits.limits(), ..Default::default() };
    let mut out = BufWriter::new(io::stdout().lock());
    let mut pieces = Pieces::new(input, options);
    let written = loop {
        if live
            && pieces.waiting()
            && let Err(e) = out.flush()
        {
            break Err(e);
        }
        let piece = match pieces.next() {
            None => break Ok(()),
            Some(Ok(piece)) => piece,
            Some(Err(haus::Error::Syntax(e))) => {
                let _ = out.flush();
                let renderer = output::renderer(output::colored(color, &stderr()));
                output::eprint(&format!("{}\n", Diagnostic::syntax(&e, None).render(&name, &renderer)));
                return Status::Invalid;
            }
            Some(Err(e)) => return output::fail(format!("cannot read {name}: {e}")),
        };
        if let Err(e) = piece.values.iter().try_for_each(|v| value(&mut out, v)) {
            break Err(e);
        }
    };
    match written.and_then(|()| out.flush()) {
        Ok(()) => Status::Ok,
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Status::Ok,
        Err(e) => output::fail(e),
    }
}
