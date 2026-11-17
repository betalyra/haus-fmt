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
    /// A data file is checked against the schema given with --schema, or else
    /// the type `Root` of `x.schema.haus` next to `x.haus`. Directories are
    /// searched for `*.haus` files (schema files included), respecting
    /// .gitignore. Standard input is checked value by value: each value is
    /// reported as soon as the comma after it arrives (`tail -f x.haus | haus
    /// check -`). Schema packages are found in `node_modules`, from each schema
    /// file's real path, or given with --package and --packages.
    Check(CheckArgs),
    /// Rewrite data files in the standard layout (spec §11).
    ///
    /// Directories are searched for `*.haus` data files (not `*.schema.haus`),
    /// respecting .gitignore. Prints each file it rewrites. `-` formats
    /// standard input to standard output; from a pipe, the compact and
    /// minimised layouts write each value as soon as it is complete. A file
    /// with a syntax error is never written.
    Fmt(FmtArgs),
    /// Print the canonical form (spec §12) of each value, one per line.
    Canonical(CanonicalArgs),
    /// Print the SHA-256 hash (spec §12) of a file's values (`hashAll`).
    ///
    /// The hash is of the values, not of the text: the pretty, compact and
    /// minimised layouts and the canonical form of the same data all have
    /// the same hash, whatever their comments, key order or spelling.
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

    /// Print one JSON document instead of text, once everything is checked.
    #[arg(long)]
    pub json: bool,

    #[command(flatten)]
    pub packages: PackageArgs,

    #[command(flatten)]
    pub limits: LimitArgs,
}

/// Where the schema packages that schemas import are (spec §13.3): by
/// default in `node_modules`, from each schema file's real path, as Node
/// finds them, for the packages the nearest package.json declares. A
/// package given by its directory comes first, for its name; one found in a
/// folder doesn't replace an installed one with other files.
#[derive(Debug, Args)]
#[command(next_help_heading = "Packages")]
pub struct PackageArgs {
    /// A schema package's directory (with package.haus and schema.haus); its
    /// manifest names it. With NAME=, the manifest must say NAME. Repeatable.
    #[arg(long = "package", value_name = "[NAME=]DIR")]
    pub package: Vec<String>,

    /// A folder whose subdirectories with a package.haus are schema packages
    /// (not deeper; one whose manifest is invalid is left out). Repeatable.
    #[arg(long = "packages", value_name = "FOLDER")]
    pub packages: Vec<PathBuf>,
}

#[derive(Debug, Args)]
pub struct FmtArgs {
    /// Files or directories to format; `-` formats standard input to standard output.
    #[arg(required = true, value_name = "PATH")]
    pub paths: Vec<PathBuf>,

    /// Write nothing: print the files that would change, and exit with 1 if any would.
    #[arg(long)]
    pub check: bool,

    /// The layout (spec §11). `--style` is an older name for it.
    #[arg(long, alias = "style", value_enum, default_value_t = Layout::Pretty, value_name = "LAYOUT")]
    pub layout: Layout,

    /// Drop comments when rewriting a file in the compact or minimised layout.
    /// Without it, such a file with comments is refused; standard output
    /// needs no option.
    #[arg(long)]
    pub drop_comments: bool,

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
pub enum Layout {
    /// One entry per line, comments kept: for people who edit.
    Pretty,
    /// One line per top-level value, with spaces; comments dropped.
    Compact,
    /// One line per top-level value, no whitespace between tokens; comments dropped.
    #[value(alias = "minimized")]
    Minimised,
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

    /// Characters in one number literal [default: 1000]; also limits a hex literal's hex digits (829 for 1000).
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
