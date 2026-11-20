//! The Rust speed benchmark of haus against serde_json (`cargo bench`, in
//! `benches/speed.rs`): the inputs it reads and the results it writes.
//!
//! - [`corpus`]: the documents `bench convert` exported to
//!   `bench/.out/<source>/corpus/`, the same files every language reads.
//! - [`results`]: `bench/.out/<source>/speed-rust.json`, the same shape as
//!   the TypeScript step's `speed-typescript.json`, from criterion's samples.
//! - [`machine`]: the CPU, memory, OS and compiler, for the results.

pub mod corpus;
pub mod machine;
pub mod results;

use std::fmt;

/// What went wrong: a message that says where.
#[derive(Debug)]
pub struct Error(pub String);

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

/// `Err(Error(…))` from anything printable.
pub fn fail<T>(message: impl fmt::Display) -> Result<T, Error> {
    Err(Error(message.to_string()))
}
