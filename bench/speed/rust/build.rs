//! The compiler's version, for the results (`machine.runtime`).

use std::env;
use std::process::Command;

fn main() {
    let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let version = Command::new(&rustc)
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map_or_else(|| "rustc (unknown version)".into(), |v| v.trim().to_owned());
    println!("cargo:rustc-env=HAUS_BENCH_RUSTC={version}");
    println!("cargo:rerun-if-env-changed=RUSTC");
}
