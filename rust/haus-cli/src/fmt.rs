//! `haus fmt`: data files in the standard layout (spec §11).

use crate::cli::{Color, FmtArgs, Layout};
use crate::diagnostic::{self, Diagnostic};
use crate::highlight::highlight;
use crate::input::{self, Target};
use crate::output::{self, Status};
use crate::pieces::{self, Pieces};
use annotate_snippets::Renderer;
use haus::{FormatOptions, Style};
use std::io::{self, Write, stderr, stdout};
use std::path::Path;

/// Data files, not schema files: those have another grammar, and no formatter yet.
fn is_data(path: &Path) -> bool {
    input::is_haus(path) && !input::is_schema(path)
}

pub fn run(args: &FmtArgs, color: Color) -> Status {
    let options = FormatOptions {
        style: match args.layout {
            Layout::Pretty => Style::Pretty,
            Layout::Compact => Style::Compact,
            Layout::Minimised => Style::Minimised,
        },
        indent: usize::from(args.indent),
        width: usize::try_from(args.width).unwrap_or(usize::MAX),
        stream: args.stream,
        limits: args.limits.limits(),
    };
    let renderer = output::renderer(output::colored(color, &stderr()));
    let colored = output::colored(color, &stdout());
    let print = |text: &str| match colored {
        true => output::print(&highlight(text)),
        false => output::print(text),
    };
    let mut status = Status::Ok;
    for target in input::collect(&args.paths, is_data) {
        let name = target.name();
        if target.is_schema() {
            status = status.max(output::fail(format!("{name}: schema files are not formatted, only data files")));
            continue;
        }
        // Compact and minimised have no layout across values: a pipe is formatted as it comes.
        if target == Target::Stdin && !args.check && options.style != Style::Pretty && !pieces::stdin_is_file() {
            status = status.max(stream(&options, &renderer, colored));
            continue;
        }
        let bytes = match target.read() {
            Ok(bytes) => bytes,
            Err(e) => {
                status = status.max(output::fail(format!("cannot read {name}: {e}")));
                continue;
            }
        };
        let formatted = diagnostic::utf8(&bytes).and_then(|text| {
            let formatted = haus::format(text, &options).map_err(|e| Box::new(Diagnostic::syntax(&e, Some(text))))?;
            Ok((text, formatted))
        });
        let (text, formatted) = match formatted {
            Ok(formatted) => formatted,
            Err(d) => {
                output::eprint(&format!("{}\n\n", d.render(&name, &renderer)));
                status = status.max(Status::Invalid);
                continue;
            }
        };
        let result = match (&target, args.check) {
            (Target::Stdin, false) => print(&formatted),
            _ if formatted.as_bytes() == bytes => Ok(()),
            (_, true) => {
                status = status.max(Status::Invalid);
                output::print(&format!("{name}\n"))
            }
            (Target::File(_), false) if drops_comments(text, &options, args.drop_comments) => {
                let layout = if options.style == Style::Compact { "compact" } else { "minimised" };
                status = status.max(output::fail(format!(
                    "{name}: not rewritten: it has comments, which the {layout} layout drops \
                     (pass --drop-comments to drop them, or format to standard output)"
                )));
                Ok(())
            }
            (Target::File(path), false) => {
                std::fs::write(path, &formatted).and_then(|()| output::print(&format!("{name}\n")))
            }
            (Target::Failed(..), false) => Ok(()),
        };
        if let Err(e) = result {
            status = status.max(output::fail(format!("{name}: {e}")));
        }
    }
    status
}

/// Whether rewriting a file in place would drop its comments without the
/// user asking for it (spec §11, "Comments and layouts").
fn drops_comments(text: &str, options: &FormatOptions, drop_comments: bool) -> bool {
    !drop_comments && options.style != Style::Pretty && haus::has_comments(text, &options.limits).unwrap_or(true)
}

/// Standard input in the compact or minimised layout, value by value: each
/// is written as soon as its comma arrives, followed by a comma. Only a lone
/// value that the input ends without a comma is written without one, unless
/// the input is a stream (`--stream`).
fn stream(options: &FormatOptions, renderer: &Renderer, colored: bool) -> Status {
    let stream_options = haus::stream::Options { limits: options.limits, ..Default::default() };
    let mut pieces = Pieces::new(io::stdin().lock(), stream_options);
    let mut out = io::stdout().lock();
    let mut first = true;
    let syntax_error = |d: Diagnostic| {
        output::eprint(&format!("{}\n\n", d.render(input::STDIN, renderer)));
        Status::Invalid
    };
    let written = loop {
        if pieces.waiting()
            && let Err(e) = out.flush()
        {
            break Err(e);
        }
        let piece = match pieces.next() {
            None => break Ok(()),
            Some(Ok(piece)) if piece.values.is_empty() => continue,
            Some(Ok(piece)) => piece,
            Some(Err(haus::Error::Syntax(e))) => {
                let _ = out.flush();
                return syntax_error(pieces.diagnostic(&e));
            }
            Some(Err(e)) => return output::fail(format!("cannot read {}: {e}", input::STDIN)),
        };
        let formatted = match haus::format(&piece.text, options) {
            Ok(formatted) => formatted,
            Err(e) => {
                let _ = out.flush();
                return syntax_error(piece.place(Diagnostic::syntax(&e, None), e.offset..e.offset));
            }
        };
        let body = formatted.strip_suffix('\n').unwrap_or(&formatted);
        let comma = if (piece.comma || !first) && !body.ends_with(',') { "," } else { "" };
        first = false;
        let line = format!("{body}{comma}\n");
        let line = if colored { highlight(&line) } else { line };
        if let Err(e) = out.write_all(line.as_bytes()) {
            break Err(e);
        }
    };
    match written.and_then(|()| out.flush()) {
        Ok(()) => Status::Ok,
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Status::Ok,
        Err(e) => output::fail(format!("{}: {e}", input::STDIN)),
    }
}
