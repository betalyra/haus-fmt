//! `haus fmt`: data files in the standard layout (spec §11).

use crate::cli::{Color, FmtArgs, Style};
use crate::diagnostic::{self, Diagnostic};
use crate::input::{self, Target};
use crate::output::{self, Status};
use haus::FormatOptions;
use std::io::stderr;
use std::path::Path;

/// Data files, not schema files: those have another grammar, and no formatter yet.
fn is_data(path: &Path) -> bool {
    input::is_haus(path) && !input::is_schema(path)
}

pub fn run(args: &FmtArgs, color: Color) -> Status {
    let options = FormatOptions {
        style: match args.style {
            Style::Pretty => haus::Style::Pretty,
            Style::Compact => haus::Style::Compact,
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
        let formatted = diagnostic::utf8(&bytes)
            .and_then(|text| haus::format(text, &options).map_err(|e| Box::new(Diagnostic::syntax(&e, Some(text)))));
        let formatted = match formatted {
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
