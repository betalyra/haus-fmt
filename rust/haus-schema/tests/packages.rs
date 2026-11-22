//! The package suite (test-suite/packages, spec §13.3): each case is a file
//! tree, written into a temporary directory, a schema file loaded from it
//! with the packages given explicitly, and the result. See
//! test-suite/README.md, "Package suite". This binding runs the `core`
//! cases: it is no implementation of the npm ecosystem, so it never looks in
//! `node_modules` and skips the `npm` cases (with a count). It runs on Unix
//! and Windows (where making links needs Developer Mode or an
//! administrator, as on CI); Windows skips the cases with `os: "unix"`.
#![cfg(any(unix, windows))]

use haus::Value;
use haus::json::Json;
use haus_schema::{Error, Explicit, FileCache, Location, Locator, Options, Schema};
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

/// The packages a case gives explicitly (`{ packages?, folders? }`).
fn given(root: &Path, given: Option<&Value>) -> Result<Explicit, Error> {
    let packages = strings(given.and_then(|g| field(g, "packages")));
    let folders = strings(given.and_then(|g| field(g, "folders")));
    let explicit = packages.iter().try_fold(Explicit::new(), |e, dir| e.package(root.join(dir)))?;
    folders.iter().try_fold(explicit, |e, dir| e.folder(root.join(dir)))
}

/// Loads the case's root with the packages it gives, and its `rootDir` as
/// the build's root: the packages reached, or the error.
fn load(root: &Path, case: &Value) -> Result<Vec<String>, Error> {
    let path = root.join(string(field(case, "root").expect("root")));
    let packages = match variant(field(case, "mode").expect("mode")) {
        ("Explicit", args) => given(root, args.first())?,
        (mode, _) => panic!("mode {mode} in a case this binding runs"),
    };
    let root_dir = field(case, "rootDir").map(|dir| root.join(string(dir)));
    let options = Options { packages: &packages, root: root_dir.as_deref(), ..Options::default() };
    let schema = Schema::load_with(&path, &options)?;
    let mut reached: Vec<String> = schema.packages().iter().map(|p| format!("{}@{}", p.name, p.version)).collect();
    reached.sort();
    Ok(reached)
}

/// Writes the case's tree into a temporary directory and loads it: None if
/// it passes, what went wrong otherwise.
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
    let result = load(dir.path(), case);
    // The owner's permissions back (chmod -R u+rwx), so the directory can be removed.
    modes.iter().for_each(|(path, mode)| chmod(path, mode | 0o700));
    match (variant(field(case, "expect").expect("expect")), result) {
        (("Ok", [want]), Ok(reached)) => {
            let want = strings(field(want, "packages"));
            (reached != want).then(|| format!("reached {reached:?}, expected {want:?}"))
        }
        (("Ok", _), Err(e)) => Some(format!("failed with {}: {e}", e.code())),
        (("Err", [want]), Ok(reached)) => {
            Some(format!("loaded (reaching {reached:?}), expected {}", string(field(want, "code").unwrap())))
        }
        (("Err", [want]), Err(e)) => {
            let message = e.to_string();
            let code = string(field(want, "code").expect("code"));
            let missing: Vec<String> = strings(field(want, "mentions"))
                .into_iter()
                .filter(|m| !message.replace('\\', "/").contains(m.as_str()))
                .collect();
            let shown: Vec<String> =
                strings(field(want, "hides")).into_iter().filter(|h| message.contains(h)).collect();
            match (e.code().as_str() == code, missing.is_empty(), shown.is_empty()) {
                (true, true, true) => None,
                (false, _, _) => Some(format!("failed with {}, expected {code}: {message}", e.code())),
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

fn cases() -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/packages/cases.haus");
    haus::parse(&fs::read_to_string(&path).unwrap())
        .unwrap_or_else(|e| panic!("{}: {e}", path.display()))
        .iter()
        .map(|case| match variant(case) {
            ("Case", [fields]) => fields.clone(),
            _ => panic!("every entry is Case {{ … }}"),
        })
        .collect()
}

fn text<'a>(case: &'a Value, key: &str) -> Option<&'a str> {
    field(case, key).map(string)
}

/// Cases that are wrong in the suite, and why: they are expected to fail here until the suite is fixed.
const BROKEN: &[(&str, &str)] = &[];

#[test]
fn package_suite() {
    let cases = cases();
    let core: Vec<&Value> = cases.iter().filter(|c| text(c, "ecosystem") == Some("core")).collect();
    let npm = cases.iter().filter(|c| text(c, "ecosystem") == Some("npm")).count();
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
    // This binding makes the SHOULD checks (`should: True`).
    let should = run.iter().filter(|c| field(c, "should").is_some_and(|s| matches!(variant(s), ("True", [])))).count();
    println!(
        "package suite: {} core cases run ({should} of them the SHOULD version check), {} skipped here ({}), \
         {npm} npm cases skipped (this binding never reads node_modules)",
        run.len(),
        skipped.len(),
        if unix { "Mode cases as root" } else { "os: unix" }
    );
    assert_eq!((cases.len(), core.len(), npm), (133, 87, 46), "the suite's cases: all, core, npm");
    assert!(failures.is_empty(), "{} of {} cases fail:\n{}", failures.len(), run.len(), failures.join("\n"));
}

/// A package manager that installs a copy of a package for each package
/// that depends on it, for this test only: `name` is the nearest
/// `deps/<name>` above the importing file.
struct Nearest;

impl Locator for Nearest {
    fn locate_in(&self, name: &str, from: Option<&Path>, _files: &mut FileCache) -> Result<Location, Error> {
        let dir = from.and_then(Path::parent).expect("a file");
        dir.ancestors()
            .map(|d| d.join("deps").join(name))
            .find(|d| d.is_dir())
            .map(Location::new)
            .ok_or_else(|| Error::new(haus::ErrorCode::ImportNotFound, format!("no deps/{name}")))
    }
}

/// Copies are one package only if their imports reach the same packages,
/// whichever copy is loaded first (spec §13.3): two identical copies of
/// orders, whose import of common finds 1.4.0 from one place and 1.2.0 from
/// the other (as the npm case identical-copies-different-dependencies).
#[test]
fn copies_are_checked_in_either_order() {
    let orders = "import @acme/common@1 (Address)\ntype Order = { to: Address }";
    let packages = [
        ("app/deps/@acme/orders", "@acme/orders", "1.0.0", orders),
        ("app/deps/@acme/common", "@acme/common", "1.4.0", "type Address = { city: String, zip?: String }"),
        ("app/deps/@acme/billing", "@acme/billing", "1.0.0", "import @acme/orders@1 (Order)\ntype Bill = { o: Order }"),
        ("app/deps/@acme/billing/deps/@acme/orders", "@acme/orders", "1.0.0", orders),
        ("app/deps/@acme/billing/deps/@acme/common", "@acme/common", "1.2.0", "type Address = { city: String }"),
    ];
    for root in [
        "import @acme/orders@1 (Order)\nimport @acme/billing@1 (Bill)\ntype Root = { order: Order, bill: Bill }",
        "import @acme/billing@1 (Bill)\nimport @acme/orders@1 (Order)\ntype Root = { order: Order, bill: Bill }",
    ] {
        let dir = tempfile::tempdir().unwrap();
        for (path, name, version, schema) in packages {
            write(&dir.path().join(path).join("package.haus"), &format!("{{ name: {name:?}, version: {version:?} }}"));
            write(&dir.path().join(path).join("schema.haus"), schema);
        }
        write(&dir.path().join("app/app.schema.haus"), root);
        let e = Schema::load(dir.path().join("app/app.schema.haus"), &Nearest).expect_err(root);
        assert_eq!(e.code().as_str(), "duplicate-package", "{e}");
        assert!(e.to_string().contains("1.2.0") && e.to_string().contains("1.4.0"), "{e}");
    }
}
