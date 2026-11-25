//! The package suite (test-suite/packages, spec §13.3) through both
//! generators: the `core` cases (packages given explicitly), loaded by
//! haus-fmt-schema as `Config::compile` and `haus-gen roc` load them, must
//! generate code (`Ok`) or fail with the case's error (`Err`).
//!
//! The `npm` cases are not run: neither generator reads node_modules (Cargo
//! gives a build script its dependencies; haus-gen takes packages
//! explicitly). The `cargo` cases (none yet) would be this suite's own:
//! Cargo passes packages through build-script metadata, which a file tree
//! can't express, so the crates of haus-build-tests test that. It runs on
//! Unix and Windows (where making links needs Developer Mode or an
//! administrator, as on CI); Windows skips the cases with `os: "unix"`.
#![cfg(any(unix, windows))]

use haus::Value;
use haus::json::Json;
use haus_build::roc::RocConfig;
use haus_build::{Config, Error, Explicit, Options};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

/// How long a case may take: a resolver that opened a FIFO blocking would hang.
const TIMEOUT: Duration = Duration::from_secs(10);

fn field<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.get(key)
}

fn string(v: &Value) -> &str {
    match v {
        Value::String(s) => s,
        other => panic!("expected a string, found {}", haus::canonical(other)),
    }
}

fn text<'a>(case: &'a Value, key: &str) -> Option<&'a str> {
    field(case, key).map(string)
}

fn strings(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::Array(items)) => items.iter().map(|s| string(s).to_owned()).collect(),
        None => vec![],
        Some(other) => panic!("expected a list of strings, found {}", haus::canonical(other)),
    }
}

/// `Tag(args…)` or `Tag { … }`: the tag and its arguments.
fn variant(v: &Value) -> (&str, &[Value]) {
    match v {
        Value::Variant { tag, args } => (tag, args),
        other => panic!("expected a variant, found {}", haus::canonical(other)),
    }
}

/// A symbolic link at `path` to `target`, relative to the link's directory,
/// as `ln -s`. On Windows a link to a directory must be made as one, and the
/// target is written with `\`.
fn symlink(target: &str, path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    return std::os::unix::fs::symlink(target, path);
    #[cfg(windows)]
    {
        let target = target.replace('/', "\\");
        if path.parent().unwrap().join(&target).is_dir() {
            std::os::windows::fs::symlink_dir(target, path)
        } else {
            std::os::windows::fs::symlink_file(target, path)
        }
    }
}

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// Writes one entry of a case's `files` under `root`.
fn create(root: &Path, entry: &Value) {
    match variant(entry) {
        ("File", [path, text]) => write(&root.join(string(path)), string(text)),
        ("Package", [dir, name, version, schema]) => {
            let dir = root.join(string(dir));
            let manifest = format!("{{ name: {:?}, version: {:?} }}", string(name), string(version));
            write(&dir.join("package.haus"), &manifest);
            write(&dir.join("schema.haus"), string(schema));
        }
        ("Npm", [dir, fields]) => {
            let mut members = vec![];
            for key in ["name", "version"] {
                if let Some(v) = field(fields, key) {
                    members.push((key.to_owned(), Json::String(string(v).to_owned())));
                }
            }
            for key in ["dependencies", "peerDependencies", "devDependencies", "optionalDependencies"] {
                if let Some(names) = field(fields, key) {
                    let deps = strings(Some(names)).into_iter().map(|n| (n, Json::String("*".into())));
                    members.push((key.to_owned(), Json::object(deps).unwrap()));
                }
            }
            write(
                &root.join(string(dir)).join("package.json"),
                &haus::json::write(&Json::object(members).unwrap()).unwrap(),
            );
        }
        ("Link", [path, target]) => {
            let path = root.join(string(path));
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            symlink(string(target), &path).unwrap();
        }
        ("Large", [path, Value::Number(bytes)]) => {
            let bytes: usize = bytes.as_str().parse().expect("a size");
            write(&root.join(string(path)), &" ".repeat(bytes));
        }
        #[cfg(unix)]
        ("Fifo", [path]) => {
            let path = root.join(string(path));
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            let made = std::process::Command::new("mkfifo").arg(&path).status().expect("mkfifo");
            assert!(made.success(), "mkfifo {}", path.display());
        }
        // After the tree is written (`modes`).
        ("Mode", [_, _]) => {}
        (tag, _) => panic!("unknown file entry {tag}"),
    }
}

/// The `Mode(path, mode)` entries of a case: the directories and their modes.
fn modes(root: &Path, files: &[Value]) -> Vec<(PathBuf, u32)> {
    files
        .iter()
        .filter_map(|entry| match variant(entry) {
            ("Mode", [path, mode]) => {
                Some((root.join(string(path)), u32::from_str_radix(string(mode), 8).expect("an octal mode")))
            }
            _ => None,
        })
        .collect()
}

#[cfg(unix)]
fn chmod(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

#[cfg(not(unix))]
fn chmod(_path: &Path, _mode: u32) {
    unreachable!("Mode entries are in cases for Unix only");
}

/// Whether the tests run as root (uid 0), which permissions don't stop.
#[cfg(unix)]
fn as_root() -> bool {
    use std::os::unix::fs::MetadataExt;
    let dir = tempfile::tempdir().unwrap();
    fs::metadata(dir.path()).unwrap().uid() == 0
}

#[cfg(not(unix))]
fn as_root() -> bool {
    false
}

/// Generates the case's root with both generators, with its `rootDir` as
/// the build's root: the first error, if any.
fn generate(root: &Path, case: &Value) -> Result<(), Error> {
    let path = root.join(text(case, "root").expect("root"));
    let given = match variant(field(case, "mode").expect("mode")) {
        ("Explicit", given) => given.first(),
        (mode, _) => panic!("mode {mode} in a core case"),
    };
    let packages = strings(given.and_then(|g| field(g, "packages")));
    let folders = strings(given.and_then(|g| field(g, "folders")));
    let root_dir = text(case, "rootDir").map(|dir| root.join(dir));

    let explicit = packages.iter().try_fold(Explicit::new(), |e, dir| e.package(root.join(dir)))?;
    let explicit = folders.iter().try_fold(explicit, |e, dir| e.folder(root.join(dir)))?;
    let krate = |name: &str| name.trim_start_matches('@').replace(['/', '-', '.', '~'], "_");
    let options = Options { packages: &explicit, root: root_dir.as_deref(), ..Options::default() };
    Config::new().generate(&path, &options, &krate)?;

    let roc =
        packages.iter().enumerate().fold(RocConfig::new(), |c, (i, dir)| c.package(root.join(dir), format!("p{i}")));
    let roc = folders.iter().fold(roc, |c, dir| c.folder(root.join(dir)));
    let roc = match root_dir {
        Some(dir) => roc.root(dir),
        None => roc,
    };
    roc.modules(&path, "Root", "root")?;
    Ok(())
}

/// Runs a core case: None if it passes, what went wrong otherwise.
fn failure(case: &Value) -> Option<String> {
    let dir = tempfile::tempdir().unwrap();
    let files = match field(case, "files") {
        Some(Value::Array(files)) => files,
        _ => panic!("a case without files"),
    };
    files
        .iter()
        .filter(|e| variant(e).0 != "Link")
        .chain(files.iter().filter(|e| variant(e).0 == "Link"))
        .for_each(|entry| create(dir.path(), entry));
    let modes = modes(dir.path(), files);
    modes.iter().for_each(|(path, mode)| chmod(path, *mode));
    let result = generate(dir.path(), case);
    // The owner's permissions back (chmod -R u+rwx), so the directory can be removed.
    modes.iter().for_each(|(path, mode)| chmod(path, mode | 0o700));
    match (variant(field(case, "expect").expect("expect")), result) {
        (("Ok", _), Ok(())) => None,
        (("Ok", _), Err(e)) => Some(format!("failed with {:?}: {e}", e.code())),
        (("Err", [want]), Ok(())) => Some(format!("generated code, expected {}", string(field(want, "code").unwrap()))),
        (("Err", [want]), Err(e)) => {
            let message = e.to_string();
            let code = string(field(want, "code").expect("code"));
            let missing: Vec<String> = strings(field(want, "mentions"))
                .into_iter()
                .filter(|m| !message.replace('\\', "/").contains(m.as_str()))
                .collect();
            let shown: Vec<String> =
                strings(field(want, "hides")).into_iter().filter(|h| message.contains(h)).collect();
            match (e.code().map(|c| c.as_str()) == Some(code), missing.is_empty(), shown.is_empty()) {
                (true, true, true) => None,
                (false, _, _) => Some(format!("failed with {:?}, expected {code}: {message}", e.code())),
                (_, false, _) => Some(format!("the message doesn't mention {missing:?}: {message}")),
                (_, _, false) => Some(format!("the message shows {shown:?}: {message}")),
            }
        }
        ((tag, _), _) => panic!("unknown expectation {tag}"),
    }
}

/// [`failure`] on a thread of its own, which must finish within [`TIMEOUT`].
fn failure_in_time(case: &Value) -> Option<String> {
    let (send, receive) = mpsc::channel();
    let case = case.clone();
    std::thread::spawn(move || send.send(failure(&case)));
    match receive.recv_timeout(TIMEOUT) {
        Ok(failure) => failure,
        Err(mpsc::RecvTimeoutError::Timeout) => Some(format!("took more than {TIMEOUT:?} (an open that blocks?)")),
        Err(mpsc::RecvTimeoutError::Disconnected) => Some("panicked".into()),
    }
}

/// Cases that are wrong in the suite, and why: they are expected to fail here until the suite is fixed.
const BROKEN: &[(&str, &str)] = &[];

#[test]
fn package_suite() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/packages/cases.haus");
    let cases: Vec<Value> = haus::parse(&fs::read_to_string(&path).unwrap())
        .unwrap_or_else(|e| panic!("{}: {e}", path.display()))
        .iter()
        .map(|case| match variant(case) {
            ("Case", [fields]) => fields.clone(),
            _ => panic!("every entry is Case {{ … }}"),
        })
        .collect();
    let of = |ecosystem: &str| cases.iter().filter(|c| text(c, "ecosystem") == Some(ecosystem)).collect::<Vec<_>>();
    let (core, npm, cargo) = (of("core"), of("npm"), of("cargo"));
    let has_mode = |c: &Value| match field(c, "files") {
        Some(Value::Array(files)) => files.iter().any(|e| variant(e).0 == "Mode"),
        _ => false,
    };
    let (unix, root) = (cfg!(unix), as_root());
    let (run, skipped): (Vec<&Value>, Vec<&Value>) =
        core.iter().partition(|c| (unix || text(c, "os") != Some("unix")) && !(root && has_mode(c)));
    // A case broken in the suite is expected to fail; once it passes, it is a failure to drop it from BROKEN.
    let failures: Vec<String> = run
        .iter()
        .filter_map(|case| {
            let name = text(case, "name").expect("name");
            match (failure_in_time(case), BROKEN.iter().any(|(b, _)| *b == name)) {
                (Some(f), false) => Some(format!("{name}: {f}")),
                (None, true) => Some(format!("{name}: passes, but is listed as broken in the suite")),
                _ => None,
            }
        })
        .collect();
    println!(
        "package suite through the generators: {} core cases run, {} skipped here ({}), {} npm cases skipped, \
         {} cargo cases",
        run.len(),
        skipped.len(),
        if unix { "Mode cases as root" } else { "os: unix" },
        npm.len(),
        cargo.len(),
    );
    assert_eq!((cases.len(), core.len(), npm.len(), cargo.len()), (136, 90, 46, 0), "the suite's cases");
    assert!(failures.is_empty(), "{} of {} cases fail:\n{}", failures.len(), run.len(), failures.join("\n"));
}
