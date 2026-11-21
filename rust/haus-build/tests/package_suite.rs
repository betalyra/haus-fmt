//! The package suite (test-suite/packages, spec §13.3) through both
//! generators: the cases that give packages explicitly (`Explicit`), loaded
//! by haus-fmt-schema as `Config::compile` and `haus-gen roc` load them,
//! must generate code (`Ok`) or fail with the case's error (`Err`).
//!
//! The `Npm` cases are not run: neither generator reads node_modules (Cargo
//! gives a build script its dependencies; haus-gen takes packages
//! explicitly). haus-fmt-schema's own adapter runs every case, with
//! `NodeModules` too (haus-schema/tests/packages.rs). It runs on Unix and
//! Windows (where making links needs Developer Mode or an administrator, as
//! on CI).
#![cfg(any(unix, windows))]

use haus::Value;
use haus::json::Json;
use haus_build::roc::RocConfig;
use haus_build::{Config, Error, Explicit, Options};
use std::fs;
use std::path::Path;

fn field<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    v.get(key)
}

fn string(v: &Value) -> &str {
    match v {
        Value::String(s) => s,
        other => panic!("expected a string, found {}", haus::canonical(other).unwrap()),
    }
}

fn strings(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::Array(items)) => items.iter().map(|s| string(s).to_owned()).collect(),
        None => vec![],
        Some(other) => panic!("expected a list of strings, found {}", haus::canonical(other).unwrap()),
    }
}

/// `Tag(args…)` or `Tag { … }`: the tag and its arguments.
fn variant(v: &Value) -> (&str, &[Value]) {
    match v {
        Value::Variant { tag, args } => (tag, args),
        other => panic!("expected a variant, found {}", haus::canonical(other).unwrap()),
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
                    let deps = strings(Some(names)).into_iter().map(|n| (n, Json::String("*".into()))).collect();
                    members.push((key.to_owned(), Json::Object(deps)));
                }
            }
            write(&root.join(string(dir)).join("package.json"), &haus::json::write(&Json::Object(members)).unwrap());
        }
        ("Link", [path, target]) => {
            let path = root.join(string(path));
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            symlink(string(target), &path).unwrap();
        }
        (tag, _) => panic!("unknown file entry {tag}"),
    }
}

/// Generates the case's root with both generators: the first error, if any.
fn generate(root: &Path, case: &Value, given: Option<&Value>) -> Result<(), Error> {
    let path = root.join(string(field(case, "root").expect("root")));
    let packages = strings(given.and_then(|g| field(g, "packages")));
    let folders = strings(given.and_then(|g| field(g, "folders")));

    let explicit = packages.iter().try_fold(Explicit::new(), |e, dir| e.package(root.join(dir)))?;
    let explicit = folders.iter().try_fold(explicit, |e, dir| e.folder(root.join(dir)))?;
    let krate = |name: &str| name.trim_start_matches('@').replace(['/', '-', '.', '~'], "_");
    Config::new().generate(&path, &Options { packages: &explicit, ..Options::default() }, &krate)?;

    let roc =
        packages.iter().enumerate().fold(RocConfig::new(), |c, (i, dir)| c.package(root.join(dir), format!("p{i}")));
    let roc = folders.iter().fold(roc, |c, dir| c.folder(root.join(dir)));
    roc.modules(&path, "Root", "root")?;
    Ok(())
}

/// Runs an `Explicit` case: None if it passes, what went wrong otherwise.
fn failure(case: &Value, given: Option<&Value>) -> Option<String> {
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
    match (variant(field(case, "expect").expect("expect")), generate(dir.path(), case, given)) {
        (("Ok", _), Ok(())) => None,
        (("Ok", _), Err(e)) => Some(format!("failed with {}: {e}", e.code())),
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
    let (mut run, mut skipped, mut failures) = (0, vec![], vec![]);
    for case in &cases {
        let name = string(field(case, "name").expect("name"));
        match variant(field(case, "mode").expect("mode")) {
            ("Explicit", given) => {
                run += 1;
                if let Some(f) = failure(case, given.first()) {
                    failures.push(format!("{name}: {f}"));
                }
            }
            _ => skipped.push(name),
        }
    }
    println!("package suite through the generators: {run} Explicit cases run, {} Npm cases skipped", skipped.len());
    assert_eq!(cases.len(), 91, "the suite's cases");
    assert!(failures.is_empty(), "{} of {run} cases fail:\n{}", failures.len(), failures.join("\n"));
}
