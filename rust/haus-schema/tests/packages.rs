//! The package suite (test-suite/packages, spec §13.3): each case is a file
//! tree, written into a temporary directory, a schema file loaded from it
//! with packages found in `node_modules` (`Npm`) or given explicitly
//! (`Explicit`), and the result. See test-suite/README.md, "Package suite".
//! It runs on Unix and Windows (where making links needs Developer Mode or
//! an administrator, as on CI).
#![cfg(any(unix, windows))]

use haus::Value;
use haus::json::Json;
use haus_schema::{Error, Explicit, Locator, NodeModules, Schema};
use std::fs;
use std::path::Path;

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
        (tag, _) => panic!("unknown file entry {tag}"),
    }
}

/// The packages a case gives explicitly (`{ packages?, folders? }`).
fn given(root: &Path, given: Option<&Value>) -> Result<Explicit, Error> {
    let packages = strings(given.and_then(|g| field(g, "packages")));
    let folders = strings(given.and_then(|g| field(g, "folders")));
    let explicit = packages.iter().try_fold(Explicit::new(), |e, dir| e.package(root.join(dir)))?;
    folders.iter().try_fold(explicit, |e, dir| e.folder(root.join(dir)))
}

/// Loads the case's root in its mode: the packages reached, or the error.
fn load(root: &Path, case: &Value) -> Result<Vec<String>, Error> {
    let path = root.join(string(field(case, "root").expect("root")));
    let schema = match variant(field(case, "mode").expect("mode")) {
        // Packages given, then node_modules.
        ("Npm", args) => Schema::load(&path, &given(root, args.first())?.or(NodeModules))?,
        // Only the packages given: no node_modules.
        ("Explicit", args) => Schema::load(&path, &given(root, args.first())?)?,
        (mode, _) => panic!("unknown mode {mode}"),
    };
    let mut reached: Vec<String> = schema.packages().iter().map(|p| format!("{}@{}", p.name, p.version)).collect();
    reached.sort();
    Ok(reached)
}

/// Runs a case: None if it passes, what went wrong otherwise.
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
    let result = load(dir.path(), case);
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
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|case| {
            let name = string(field(case, "name").expect("name"));
            failure(case).map(|f| format!("{name}: {f}"))
        })
        .collect();
    // This binding reads node_modules, takes packages explicitly and makes
    // the SHOULD checks (`should: True`): it runs every case.
    let should =
        cases.iter().filter(|c| field(c, "should").is_some_and(|s| matches!(variant(s), ("True", [])))).count();
    println!("package suite: {} cases run ({should} of them the SHOULD version check), 0 skipped", cases.len());
    assert_eq!(cases.len(), 99, "the suite's cases");
    assert!(failures.is_empty(), "{} of {} cases fail:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

/// Copies are one package only if their imports reach the same packages,
/// whichever copy is loaded first (spec §13.3).
#[test]
fn copies_are_checked_in_either_order() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/packages/cases.haus");
    let cases = haus::parse(&fs::read_to_string(&path).unwrap()).unwrap();
    let case = cases
        .iter()
        .map(|c| &variant(c).1[0])
        .find(|c| string(field(c, "name").unwrap()) == "identical-copies-different-dependencies")
        .expect("the case");
    for root in [
        "import @acme/orders@1 (Order)\nimport @acme/billing@1 (Bill)\ntype Root = { order: Order, bill: Bill }",
        "import @acme/billing@1 (Bill)\nimport @acme/orders@1 (Order)\ntype Root = { order: Order, bill: Bill }",
    ] {
        let dir = tempfile::tempdir().unwrap();
        match field(case, "files") {
            Some(Value::Array(files)) => files
                .iter()
                .filter(|e| variant(e).0 != "Link")
                .chain(files.iter().filter(|e| variant(e).0 == "Link"))
                .for_each(|entry| create(dir.path(), entry)),
            _ => panic!("files"),
        }
        write(&dir.path().join("app/app.schema.haus"), root);
        let e = load(dir.path(), case).expect_err(root);
        assert_eq!(e.code().as_str(), "duplicate-package", "{e}");
        assert!(e.to_string().contains("1.2.0") && e.to_string().contains("1.4.0"), "{e}");
    }
}
