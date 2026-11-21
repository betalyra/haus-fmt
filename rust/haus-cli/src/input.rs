//! Which files a command works on, and reading them.

use std::collections::HashSet;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

/// The name standard input is shown with.
pub const STDIN: &str = "<stdin>";

/// One input of a command.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Target {
    Stdin,
    File(PathBuf),
    /// A path that couldn't be found or walked, and why.
    Failed(String, String),
}

impl Target {
    /// How it is shown: the path as given or found, or `<stdin>`.
    pub fn name(&self) -> String {
        match self {
            Target::Stdin => STDIN.to_owned(),
            Target::File(path) => crate::output::shown(path),
            Target::Failed(name, _) => name.clone(),
        }
    }

    /// Whether it is a schema file (`.schema.haus`); standard input is data.
    pub fn is_schema(&self) -> bool {
        match self {
            Target::File(path) => is_schema(path),
            _ => false,
        }
    }

    /// Its bytes.
    pub fn read(&self) -> io::Result<Vec<u8>> {
        match self {
            Target::Stdin => {
                let mut bytes = Vec::new();
                io::stdin().lock().read_to_end(&mut bytes)?;
                Ok(bytes)
            }
            Target::File(path) => std::fs::read(path),
            Target::Failed(_, why) => Err(io::Error::other(why.clone())),
        }
    }
}

pub fn is_schema(path: &Path) -> bool {
    path.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with(".schema.haus") || n == "schema.haus")
}

pub fn is_haus(path: &Path) -> bool {
    path.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with(".haus"))
}

/// The inputs `paths` name, in order: `-` is standard input, a file is
/// itself (whatever its name), and a directory is every file in it that
/// `wanted` accepts, sorted by path, skipping what .gitignore, .ignore and
/// hidden names exclude. Each input is listed once.
pub fn collect(paths: &[PathBuf], wanted: fn(&Path) -> bool) -> Vec<Target> {
    let mut seen = HashSet::new();
    paths.iter().flat_map(|path| expand(path, wanted)).filter(|t| seen.insert(t.clone())).collect()
}

fn expand(path: &Path, wanted: fn(&Path) -> bool) -> Vec<Target> {
    if path == Path::new("-") {
        return vec![Target::Stdin];
    }
    match std::fs::metadata(path) {
        Err(e) => vec![Target::Failed(crate::output::shown(path), e.to_string())],
        Ok(meta) if meta.is_dir() => walk(path, wanted),
        Ok(_) => vec![Target::File(path.to_owned())],
    }
}

fn walk(dir: &Path, wanted: fn(&Path) -> bool) -> Vec<Target> {
    ignore::WalkBuilder::new(dir)
        .require_git(false)
        .sort_by_file_path(|a, b| a.cmp(b))
        .build()
        .filter_map(|entry| match entry {
            Ok(e) if e.file_type().is_some_and(|t| t.is_file()) && wanted(e.path()) => {
                Some(Target::File(e.into_path()))
            }
            Ok(_) => None,
            Err(e) => Some(Target::Failed(crate::output::shown(dir), e.to_string())),
        })
        .collect()
}
