//! `haus`: check, format and hash haus files. The commands are in their
//! modules; the work is done by the `haus-fmt` and `haus-fmt-schema` crates.

mod check;
mod cli;
mod diagnostic;
mod fmt;
mod highlight;
mod input;
mod json;
mod official;
mod output;
mod package;
mod pieces;
mod values;

use clap::{CommandFactory, Parser};
use cli::{Cli, Command, PackageCommand};
use std::process::ExitCode;

fn main() -> ExitCode {
    let cli = Cli::parse();
    let status = match cli.command {
        Command::Check(args) => check::run(&args, cli.color),
        Command::Fmt(args) => fmt::run(&args, cli.color),
        Command::Canonical(args) => values::canonical(&args, cli.color),
        Command::Hash(args) => values::hash(&args, cli.color),
        Command::Package(PackageCommand::Check(args)) => package::check(&args, cli.color),
        Command::Completions { shell } => {
            clap_complete::generate(shell, &mut Cli::command(), "haus", &mut std::io::stdout());
            output::Status::Ok
        }
    };
    ExitCode::from(status as u8)
}
