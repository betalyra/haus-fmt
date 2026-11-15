//! The command line: commands, arguments and their help.

use clap::{Args, Parser, Subcommand, ValueEnum};
use std::path::PathBuf;

/// The spec version this build implements (spec/README.md's header).
#[macro_export]
macro_rules! spec_version {
    () => {
        "draft 0.1"
    };
}

const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), " (spec ", spec_version!(), ")");

/// Check, format and hash haus files.
///
/// Exit codes: 0 ok (hints and warnings allowed), 1 invalid data or files
/// that would change, 2 usage or I/O error. `-` reads standard input.
#[derive(Debug, Parser)]
#[command(name = "haus", version = VERSION, max_term_width = 100)]
pub struct Cli {
    /// Color diagnostics: auto is on for a terminal, unless NO_COLOR is set.
    #[arg(long, value_enum, default_value_t = Color::Auto, global = true, value_name = "WHEN")]
    pub color: Color,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Color {
    Auto,
    Always,
    Never,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Check data files (syntax, and their schema) and schema files.
    ///
    /// A data file is checked against the type `Root` of `x.schema.haus` next
    /// to `x.haus`, or the schema named by a `// schema: ./s.schema.haus#Type`
    /// comment at its top, or the one given with --schema. Directories are
    /// searched for `*.haus` files (schema files included), respecting
    /// .gitignore.
    Check(CheckArgs),
    /// Rewrite data files in the standard layout (spec §11).
    ///
    /// Directories are searched for `*.haus` data files (not `*.schema.haus`),
    /// respecting .gitignore. Prints each file it rewrites. `-` formats
    /// standard input to standard output. A file with a syntax error is never
    /// written.
    Fmt(FmtArgs),
    /// Print the canonical form (spec §12) of each value, one per line.
    Canonical(CanonicalArgs),
    /// Print the SHA-256 hash (spec §12) of a file's values (`hashAll`).
    Hash(HashArgs),
    /// Print a shell completion script.
    Completions {
        #[arg(value_enum)]
        shell: clap_complete::Shell,
    },
}

#[derive(Debug, Args)]
pub struct CheckArgs {
    /// Files or directories to check; `-` reads a data file from standard input,
    /// `.` checks the current directory.
    #[arg(required = true, value_name = "PATH")]
    pub paths: Vec<PathBuf>,

    /// Check data files against this schema, and type (default Root).
    #[arg(long, value_name = "FILE[#Type]", conflicts_with = "no_schema")]
    pub schema: Option<String>,

    /// Check syntax only, without a schema.
    #[arg(long)]
    pub no_schema: bool,

    /// Print one JSON document instead of text.
    #[arg(long)]
    pub json: bool,

    #[command(flatten)]
    pub limits: LimitArgs,
}

#[derive(Debug, Args)]
pub struct FmtArgs {
    /// Files or directories to format; `-` formats standard input to standard output.
    #[arg(required = true, value_name = "PATH")]
    pub paths: Vec<PathBuf>,

    /// Write nothing: print the files that would change, and exit with 1 if any would.
    #[arg(long)]
    pub check: bool,

    /// The layout.
    #[arg(long, value_enum, default_value_t = Style::Pretty)]
    pub style: Style,

    /// Spaces per indentation level.
    #[arg(long, value_name = "N", default_value_t = 2, value_parser = clap::value_parser!(u16).range(1..=16))]
    pub indent: u16,

    /// Line width for positional payloads to stay inline.
    #[arg(long, value_name = "N", default_value_t = 80, value_parser = clap::value_parser!(u32).range(1..))]
    pub width: u32,

    #[command(flatten)]
    pub limits: LimitArgs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Style {
    /// One entry per line, comments kept.
    Pretty,
    /// One line per top-level value, comments dropped.
    Compact,
}

#[derive(Debug, Args)]
pub struct CanonicalArgs {
    /// The file; `-` or nothing reads standard input.
    #[arg(value_name = "FILE")]
    pub file: Option<PathBuf>,

    #[command(flatten)]
    pub limits: LimitArgs,
}

#[derive(Debug, Args)]
pub struct HashArgs {
    /// The file; `-` or nothing reads standard input.
    #[arg(value_name = "FILE")]
    pub file: Option<PathBuf>,

    /// Print the hash of each value, one per line, instead of the file's.
    #[arg(long)]
    pub each: bool,

    #[command(flatten)]
    pub limits: LimitArgs,
}

/// The parser's limits (spec §7); the defaults are the spec's.
#[derive(Debug, Args)]
#[command(next_help_heading = "Limits")]
pub struct LimitArgs {
    /// Nesting depth of records, arrays and payloads [default: 256, at most 256].
    #[arg(long, value_name = "N", value_parser = clap::value_parser!(u16).range(0..=haus::MAX_SUPPORTED_DEPTH as i64))]
    pub max_depth: Option<u16>,

    /// Characters in one number literal [default: 1000].
    #[arg(long, value_name = "N", value_parser = clap::value_parser!(u64).range(1..))]
    pub max_number_length: Option<u64>,

    /// Largest absolute exponent [default: 6144].
    #[arg(long, value_name = "N")]
    pub max_exponent: Option<u64>,

    /// Characters in one string, key, tag or byte string [default: 16777216].
    #[arg(long, value_name = "N")]
    pub max_string_length: Option<u64>,
}

impl LimitArgs {
    pub fn limits(&self) -> haus::Limits {
        let default = haus::Limits::default();
        let size = |n: Option<u64>, d: usize| n.map_or(d, |n| usize::try_from(n).unwrap_or(usize::MAX));
        haus::Limits {
            max_depth: self.max_depth.map_or(default.max_depth, usize::from),
            max_number_length: size(self.max_number_length, default.max_number_length),
            max_exponent: self.max_exponent.unwrap_or(default.max_exponent),
            max_string_length: size(self.max_string_length, default.max_string_length),
        }
    }
}
