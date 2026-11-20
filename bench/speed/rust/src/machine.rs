//! The machine the benchmark runs on, in the words the TypeScript step uses
//! (Node's `os`): `Apple M1 Max`, 10 cores, `darwin 25.5.0 arm64`.

use std::fs;
use std::process::Command;

#[derive(Debug, Clone)]
pub struct Machine {
    pub cpu: String,
    /// Logical cores.
    pub cores: usize,
    pub memory_gb: u64,
    pub os: String,
    /// The compiler: `rustc 1.99.0 (b940084d7 2026-09-28)`.
    pub runtime: String,
}

fn command(program: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(program).args(args).output().ok()?;
    let text = String::from_utf8(out.stdout).ok()?;
    Some(text.trim().to_owned()).filter(|t| out.status.success() && !t.is_empty())
}

/// A line `key : value` of /proc/cpuinfo or /proc/meminfo.
fn proc_field(file: &str, key: &str) -> Option<String> {
    let text = fs::read_to_string(file).ok()?;
    text.lines().find(|l| l.starts_with(key)).and_then(|l| l.split_once(':')).map(|(_, v)| v.trim().to_owned())
}

/// macOS: a value of `sysctlbyname`, as Node's `os` reads it (the `sysctl`
/// command may not be allowed in a sandbox where the call is).
#[cfg(target_os = "macos")]
mod sysctl {
    use std::ffi::{CString, c_char, c_int, c_void};

    unsafe extern "C" {
        fn sysctlbyname(
            name: *const c_char,
            old: *mut c_void,
            old_len: *mut usize,
            new: *mut c_void,
            new_len: usize,
        ) -> c_int;
    }

    fn bytes(name: &str) -> Option<Vec<u8>> {
        let name = CString::new(name).ok()?;
        let mut len = 0usize;
        // SAFETY: a null buffer asks for the value's length only.
        if unsafe { sysctlbyname(name.as_ptr(), std::ptr::null_mut(), &mut len, std::ptr::null_mut(), 0) } != 0 {
            return None;
        }
        let mut buf = vec![0u8; len];
        // SAFETY: `buf` has room for `len` bytes, and `len` says so.
        if unsafe { sysctlbyname(name.as_ptr(), buf.as_mut_ptr().cast(), &mut len, std::ptr::null_mut(), 0) } != 0 {
            return None;
        }
        buf.truncate(len);
        Some(buf)
    }

    pub fn string(name: &str) -> Option<String> {
        let b = bytes(name)?;
        Some(String::from_utf8_lossy(b.split(|&c| c == 0).next()?).into_owned())
    }

    pub fn u64(name: &str) -> Option<u64> {
        Some(u64::from_ne_bytes(bytes(name)?.try_into().ok()?))
    }
}

#[cfg(not(target_os = "macos"))]
mod sysctl {
    pub fn string(_: &str) -> Option<String> {
        None
    }
    pub fn u64(_: &str) -> Option<u64> {
        None
    }
}

fn cpu() -> Option<String> {
    sysctl::string("machdep.cpu.brand_string").or_else(|| proc_field("/proc/cpuinfo", "model name"))
}

fn memory_bytes() -> Option<u64> {
    sysctl::u64("hw.memsize").or_else(|| {
        let kb = proc_field("/proc/meminfo", "MemTotal")?;
        kb.trim_end_matches("kB").trim().parse::<u64>().ok().map(|k| k * 1024)
    })
}

impl Machine {
    pub fn detect() -> Machine {
        // Node's names, so both languages' results read the same.
        let platform = match std::env::consts::OS {
            "macos" => "darwin",
            os => os,
        };
        let arch = match std::env::consts::ARCH {
            "aarch64" => "arm64",
            "x86_64" => "x64",
            arch => arch,
        };
        let release = command("uname", &["-r"]).unwrap_or_default();
        Machine {
            cpu: cpu().unwrap_or_else(|| "unknown".into()),
            cores: std::thread::available_parallelism().map_or(1, |n| n.get()),
            memory_gb: memory_bytes().map_or(0, |b| (b as f64 / f64::from(1u32 << 30)).round() as u64),
            os: format!("{platform} {release} {arch}"),
            runtime: env!("HAUS_BENCH_RUSTC").to_owned(),
        }
    }
}
