//! `haus canonical` and `haus hash` (spec §12), on a stream: values are
//! handled as they are read, so memory stays bounded by the largest value.

use crate::cli::{CanonicalArgs, Color, HashArgs, LimitArgs};
use crate::diagnostic::Diagnostic;
use crate::input::STDIN;
use crate::output::{self, Status};
use haus::{EncodeError, Value};
use std::fs::File;
use std::io::{self, BufWriter, IsTerminal, Read, Write, stderr};
use std::path::Path;

/// Print each value's canonical form on its own line.
pub fn canonical(args: &CanonicalArgs, color: Color) -> Status {
    each_value(args.file.as_deref(), &args.limits, color, |out, v| Ok(writeln!(out, "{}", haus::canonical(v)?)?))
}

/// Print `hashAll` of the values, or with --each the hash of each value.
pub fn hash(args: &HashArgs, color: Color) -> Status {
    let file = args.file.as_deref();
    if args.each {
        return each_value(file, &args.limits, color, |out, v| Ok(writeln!(out, "{}", haus::hash(v)?)?));
    }
    let mut hasher = haus::Hasher::new();
    let add = |_: &mut dyn Write, v: &Value| {
        hasher.add(v)?;
        Ok(())
    };
    match each_value(file, &args.limits, color, add) {
        Status::Ok => output::print(&format!("{}\n", hasher.digest())).map_or_else(output::fail, |()| Status::Ok),
        status => status,
    }
}

/// Why handling a value stopped: output failed, or the value has no
/// canonical form (`number-too-long`).
enum Stop {
    Io(io::Error),
    Encode(EncodeError),
}

impl From<io::Error> for Stop {
    fn from(e: io::Error) -> Stop {
        Stop::Io(e)
    }
}

impl From<EncodeError> for Stop {
    fn from(e: EncodeError) -> Stop {
        Stop::Encode(e)
    }
}

/// Read the stream in `file` (None or `-`: standard input), calling `value`
/// for each value. A syntax error, or a value without a canonical form, is
/// reported on standard error; what was written before it stays written.
fn each_value(
    file: Option<&Path>,
    limits: &LimitArgs,
    color: Color,
    mut value: impl FnMut(&mut dyn Write, &Value) -> Result<(), Stop>,
) -> Status {
    let (name, input): (String, Box<dyn Read>) = match file.filter(|f| *f != Path::new("-")) {
        Some(path) => match File::open(path) {
            Ok(f) => (path.display().to_string(), Box::new(f)),
            Err(e) => return output::fail(format!("cannot read {}: {e}", path.display())),
        },
        None if file.is_none() && io::stdin().is_terminal() => {
            return output::fail("no input: give a FILE, or pipe the data in (`-` reads standard input)");
        }
        None => (STDIN.to_owned(), Box::new(io::stdin().lock())),
    };
    let options = haus::stream::Options { limits: limits.limits(), ..Default::default() };
    let mut out = BufWriter::new(io::stdout().lock());
    let report = |out: &mut BufWriter<_>, diagnostic: Diagnostic| {
        let _ = out.flush();
        let renderer = output::renderer(output::colored(color, &stderr()));
        output::eprint(&format!("{}\n", diagnostic.render(&name, &renderer)));
        Status::Invalid
    };
    let mut written = Ok(());
    for v in haus::stream::values_with(input, options) {
        let v = match v {
            Ok(v) => v,
            Err(haus::Error::Syntax(e)) => return report(&mut out, Diagnostic::syntax(&e, None)),
            Err(e) => return output::fail(format!("cannot read {name}: {e}")),
        };
        written = match value(&mut out, &v) {
            Ok(()) => Ok(()),
            Err(Stop::Encode(e)) => return report(&mut out, Diagnostic::encode(&e)),
            Err(Stop::Io(e)) => Err(e),
        };
        if written.is_err() {
            break;
        }
    }
    match written.and_then(|()| out.flush()) {
        Ok(()) => Status::Ok,
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Status::Ok,
        Err(e) => output::fail(e),
    }
}
