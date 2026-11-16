//! `haus fmt`: data files in the standard layout (spec §11).

use crate::cli::{Color, FmtArgs, Layout};
use crate::diagnostic::{self, Diagnostic};
use crate::input::{self, Target};
use crate::output::{self, Status};
use haus::{FormatOptions, Style};
use std::io::stderr;
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
        limits: args.limits.limits(),
    };
    let renderer = output::renderer(output::colored(color, &stderr()));
    let mut status = Status::Ok;
    for target in input::collect(&args.paths, is_data) {
        let name = target.name();
        if target.is_schema() {
            status = status.max(output::fail(format!("{name}: schema files are not formatted, only data files")));
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
            (Target::Stdin, false) => output::print(&formatted),
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
