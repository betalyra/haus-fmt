//! `haus package check`, run as a process: the package in
//! tests/fixtures/packages/good passes; each check fails on a copy of it
//! with one thing broken; the official extensions pass.

use assert_cmd::cargo::cargo_bin_cmd;
use haus::json::Json;
use std::fs;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/packages")
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// `haus package check …` in `dir`: the exit code and the standard output.
fn run(dir: &Path, args: &[&str]) -> (i32, String) {
    let out = cargo_bin_cmd!("haus").current_dir(dir).args(["package", "check"]).args(args).output().unwrap();
    (out.status.code().unwrap(), String::from_utf8(out.stdout).unwrap())
}

/// `haus package check --json …` in `dir`: the exit code and the document.
fn run_json(dir: &Path, args: &[&str]) -> (i32, Json) {
    let (code, text) = run(dir, &[&["--json"], args].concat());
    assert_eq!(text.matches('\n').count(), 1, "one line of JSON: {text}");
    (code, haus::json::parse(&text).unwrap())
}

fn str_of<'a>(json: &'a Json, name: &str) -> Option<&'a str> {
    match json.get(name) {
        Some(Json::String(s)) => Some(s),
        _ => None,
    }
}

fn array<'a>(json: &'a Json, name: &str) -> &'a [Json] {
    match json.get(name) {
        Some(Json::Array(items)) => items,
        other => panic!("{name}: {other:?}"),
    }
}

/// One diagnostic: severity, code (if any), message and file.
#[derive(Debug)]
struct Found {
    severity: String,
    code: Option<String>,
    message: String,
    file: String,
}

/// The diagnostics of the one package checked.
fn found(json: &Json) -> Vec<Found> {
    let [package] = array(json, "packages") else { panic!("one package: {json:?}") };
    array(package, "diagnostics")
        .iter()
        .map(|d| Found {
            severity: str_of(d, "severity").unwrap().to_owned(),
            code: str_of(d, "code").map(str::to_owned),
            message: str_of(d, "message").unwrap().to_owned(),
            file: str_of(d, "file").unwrap_or_default().to_owned(),
        })
        .collect()
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        match entry.file_type().unwrap().is_dir() {
            true => copy_dir(&entry.path(), &target),
            false => drop(fs::copy(entry.path(), target).unwrap()),
        }
    }
}

/// The fixtures `good` and `base`, copied into a temporary directory.
fn copy() -> TempDir {
    let dir = tempfile::tempdir().unwrap();
    for name in ["good", "base"] {
        copy_dir(&fixtures().join(name), &dir.path().join(name));
    }
    dir
}

/// Replaces `from` with `to` in the file `file` of the package `good`.
fn edit(dir: &Path, file: &str, from: &str, to: &str) {
    let path = dir.join("good").join(file);
    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains(from), "{file} has no {from:?}");
    fs::write(&path, text.replacen(from, to, 1)).unwrap();
}

/// Checks `good` after `change`: exactly one diagnostic of `severity`, with
/// `code`, in `file`, its message containing `message`.
fn fails(change: impl FnOnce(&Path), severity: &str, code: &str, file: &str, message: &str) {
    let dir = copy();
    change(dir.path());
    let (exit, json) = run_json(dir.path(), &["good"]);
    let found = found(&json);
    let relevant: Vec<&Found> = found.iter().filter(|f| f.severity == severity).collect();
    assert_eq!(relevant.len(), 1, "one {severity} ({message}): {found:#?}");
    let f = relevant[0];
    assert_eq!(f.code.as_deref(), Some(code), "{f:#?}");
    assert!(f.message.contains(message), "{message:?} in {f:#?}");
    assert_eq!(f.file, format!("good/{file}"), "{f:#?}");
    assert_eq!(exit, if severity == "error" { 1 } else { 0 }, "{found:#?}");
}

fn error(change: impl FnOnce(&Path), code: &str, file: &str, message: &str) {
    fails(change, "error", code, file, message);
}

#[test]
fn a_good_package_passes() {
    let (code, json) = run_json(&fixtures(), &["good", "base"]);
    assert_eq!(code, 0, "{json:?}");
    assert_eq!(json.get("ok"), Some(&Json::Bool(true)));
    let packages = array(&json, "packages");
    assert_eq!(str_of(&packages[0], "name"), Some("@fixture/good"));
    assert_eq!(str_of(&packages[0], "version"), Some("1.0.0"));
    assert!(packages.iter().all(|p| array(p, "diagnostics").is_empty()), "{json:?}");
    let (code, text) = run(&fixtures(), &["good"]);
    assert_eq!((code, text.as_str()), (0, "Checked 1 package: no problems.\n"));
}

#[test]
fn the_extensions_pass() {
    let mut dirs: Vec<String> = fs::read_dir(repo().join("extensions"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.join("package.haus").exists())
        .map(|p| p.display().to_string())
        .collect();
    dirs.sort();
    assert!(dirs.len() >= 2, "{dirs:?}");
    let args: Vec<&str> = dirs.iter().map(String::as_str).collect();
    let (code, json) = run_json(&repo(), &args);
    let problems: Vec<&Json> =
        array(&json, "packages").iter().filter(|p| !array(p, "diagnostics").is_empty()).collect();
    assert!(problems.is_empty(), "{problems:#?}");
    assert_eq!(code, 0);
}

// ── the manifest and the schema ─────────────────────────────

#[test]
fn the_manifest_is_checked() {
    let manifest = |text: &'static str| move |dir: &Path| fs::write(dir.join("good/package.haus"), text).unwrap();
    error(manifest(r#"{ name: "@Fixture/Good", version: "1.0.0" }"#), "package-manifest", "package.haus", "");
    error(manifest(r#"{ name: "@fixture/good", version: "1.0" }"#), "package-manifest", "package.haus", "1.0");
    // A former schema field is ignored.
    fails(
        manifest(r#"{ name: "@fixture/good", version: "1.0.0", schema: "../../secret" }"#),
        "warning",
        "package-manifest",
        "package.haus",
        "ignored",
    );
    error(
        |dir| fs::remove_file(dir.join("good/package.haus")).unwrap(),
        "import-not-found",
        "package.haus",
        "is not a schema package",
    );
}

#[test]
fn the_schema_is_checked_with_its_imports() {
    error(|dir| edit(dir, "schema.haus", "total: Int", "total: Intt"), "unknown-type", "schema.haus", "Intt");
    // A package's schema imports packages, never files.
    error(
        |dir| {
            fs::write(dir.join("good/near.schema.haus"), "type Near = Int\n").unwrap();
            edit(dir, "schema.haus", "type Order", "import ./near (Near)\ntype Order");
        },
        "package-path",
        "schema.haus",
        "can't import files",
    );
    // An import that no wrapper declares, found nowhere.
    let dir = copy();
    edit(dir.path(), "schema.haus", "type Order", "import @fixture/gone (Gone)\ntype Order");
    let (code, json) = run_json(dir.path(), &["good"]);
    let found = found(&json);
    assert_eq!(code, 1);
    assert!(found.iter().any(|f| f.file == "good/schema.haus" && f.code.is_some()), "{found:#?}");
    for wrapper in ["package.json", "Cargo.toml", "pyproject.toml"] {
        assert!(
            found.iter().any(|f| f.file == format!("good/{wrapper}")
                && f.code.as_deref() == Some("undeclared-package")
                && f.message.contains("@fixture/gone")),
            "{wrapper}: {found:#?}"
        );
    }
}

#[cfg(unix)]
#[test]
fn package_files_are_not_links() {
    let link = |file: &'static str| {
        move |dir: &Path| {
            let path = dir.join("good").join(file);
            let target = dir.join(format!("elsewhere-{file}"));
            fs::rename(&path, &target).unwrap();
            std::os::unix::fs::symlink(&target, &path).unwrap();
        }
    };
    error(link("schema.haus"), "package-path", "schema.haus", "symbolic link");
    error(link("package.json"), "package-path", "package.json", "symbolic link");
}

// ── versions and names ──────────────────────────────────────

#[test]
fn every_wrapper_has_the_manifests_version() {
    let code = "package-version";
    error(|d| edit(d, "package.json", r#""version": "1.0.0""#, r#""version": "1.0.1""#), code, "package.json", "1.0.1");
    error(|d| edit(d, "Cargo.toml", r#"version = "1.0.0""#, r#"version = "1.1.0""#), code, "Cargo.toml", "1.1.0");
    error(
        |d| edit(d, "pyproject.toml", r#"version = "1.0.0""#, r#"version = "2.0.0""#),
        code,
        "pyproject.toml",
        "2.0.0",
    );
}

#[test]
fn npm_names_the_package_as_its_manifest() {
    error(
        |d| edit(d, "package.json", r#""name": "@fixture/good""#, r#""name": "@fixture/other""#),
        "package-name",
        "package.json",
        "names the package @fixture/other",
    );
}

#[test]
fn cargo_links_is_the_library_name() {
    error(
        |d| edit(d, "Cargo.toml", r#"links = "fixture_good""#, r#"links = "good""#),
        "package-crate",
        "Cargo.toml",
        "links",
    );
    error(|d| edit(d, "Cargo.toml", "links = \"fixture_good\"\n", ""), "package-crate", "Cargo.toml", "has no links");
}

#[test]
fn cargo_doesnt_rename_schema_packages() {
    error(
        |d| edit(d, "Cargo.toml", r#"fixture-base = { path"#, r#"base = { package = "fixture-base", path"#),
        "package-crate",
        "Cargo.toml",
        "renames the crate fixture-base to base",
    );
}

// ── no install scripts ──────────────────────────────────────

#[test]
fn npm_runs_nothing_when_installed() {
    error(
        |d| edit(d, "package.json", r#""test": "haus package check""#, r#""postinstall": "node setup.js""#),
        "package-install-script",
        "package.json",
        "postinstall",
    );
    error(
        |d| fs::write(d.join("good/binding.gyp"), "{}").unwrap(),
        "package-install-script",
        "binding.gyp",
        "node-gyp",
    );
}

// ── files shipped ───────────────────────────────────────────

#[test]
fn every_wrapper_ships_the_packages_files() {
    let shipped = "profiles/positive.vectors.haus is not shipped";
    error(
        |d| edit(d, "package.json", r#""profiles"]"#, r#""profiles/*.md"]"#),
        "package-files",
        "package.json",
        shipped,
    );
    error(|d| edit(d, "Cargo.toml", r#""profiles"]"#, r#""profiles/*.md"]"#), "package-files", "Cargo.toml", shipped);
    error(
        |d| edit(d, "pyproject.toml", "\"schema.haus\" = \"fixture_good/schema.haus\"\n", ""),
        "package-files",
        "pyproject.toml",
        "schema.haus is not shipped",
    );
    // Without files, npm ships what .npmignore doesn't exclude.
    error(
        |d| {
            edit(d, "package.json", r#""files": ["package.haus", "schema.haus", "profiles"],"#, "");
            fs::write(d.join("good/.npmignore"), "*.vectors.haus\n").unwrap();
        },
        "package-files",
        "package.json",
        shipped,
    );
    // A build backend whose configuration isn't read: said, not failed.
    fails(
        |d| {
            edit(
                d,
                "pyproject.toml",
                r#"build-backend = "hatchling.build""#,
                r#"build-backend = "setuptools.build_meta""#,
            )
        },
        "warning",
        "package-files",
        "pyproject.toml",
        "setuptools.build_meta",
    );
}

// ── declared dependencies ───────────────────────────────────

#[test]
fn every_wrapper_declares_the_packages_the_schema_imports() {
    let code = "undeclared-package";
    error(
        |d| {
            edit(d, "package.json", r#""peerDependencies": { "@fixture/base": "^1.2.0" },"#, "");
            edit(d, "package.json", r#""devDependencies": { "@fixture/base": "file:../base" }"#, r#""private": false"#);
        },
        code,
        "package.json",
        "doesn't declare it",
    );
    // devDependencies aren't installed with the package.
    error(
        |d| edit(d, "package.json", r#""peerDependencies": { "@fixture/base": "^1.2.0" },"#, ""),
        code,
        "package.json",
        "only in devDependencies",
    );
    error(
        |d| edit(d, "Cargo.toml", "fixture-base = { path = \"../base\" }\n", ""),
        code,
        "Cargo.toml",
        "@fixture/base",
    );
    error(|d| edit(d, "pyproject.toml", r#", "fixture-base>=1.2,<2""#, ""), code, "pyproject.toml", "@fixture/base");
    // npm: a dependency rather than a peer dependency is allowed, and said.
    fails(
        |d| edit(d, "package.json", r#""peerDependencies""#, r#""dependencies""#),
        "warning",
        "undeclared-package",
        "package.json",
        "peerDependencies",
    );
    // A registry dependency might be the package: said, not failed.
    fails(
        |d| edit(d, "Cargo.toml", r#"fixture-base = { path = "../base" }"#, r#"fixture-base = "1.2""#),
        "warning",
        "undeclared-package",
        "Cargo.toml",
        "fixture-base",
    );
}

// ── profiles ────────────────────────────────────────────────

#[test]
fn profile_vectors_parse() {
    let vectors = "profiles/positive.vectors.haus";
    let first = r#"Accept { type: "Order", value: "{ id: 1, total: 5 }" },"#;
    let replace = |to: &'static str| move |d: &Path| edit(d, vectors, first, to);
    // The file is haus.
    let (_, json) = {
        let dir = copy();
        replace(r#"Accept { type: "Order", value: "{ id: 1, total: 5 }" ,,"#)(dir.path());
        run_json(dir.path(), &["good"])
    };
    let found = found(&json);
    assert!(found.len() == 1 && found[0].code.is_some() && found[0].file.ends_with(vectors), "{found:#?}");
    // Each vector is Accept or Reject, with a type and a value, and no other fields.
    error(
        replace(r#"Maybe { type: "Order", value: "{ id: 1 }" },"#),
        "profile-vectors",
        vectors,
        "Accept { … } or Reject",
    );
    error(replace(r#"Accept { type: "Order", note: "no value" },"#), "profile-vectors", vectors, "has no value");
    error(replace(r#"Accept { value: "{ id: 1, total: 5 }" },"#), "profile-vectors", vectors, "has no type");
    error(
        replace(r#"Accept { type: "Order", value: "{ id: 1, total: 5 }", why: "x" },"#),
        "profile-vectors",
        vectors,
        "unknown field why",
    );
    // Only an Accept has an output.
    error(
        replace(r#"Reject { type: "Order", value: "{ id: -1, total: 5 }", output: "{ id: -1, total: 5 }" },"#),
        "profile-vectors",
        vectors,
        "only an Accept has an output",
    );
    // The type is one of the package's own, without parameters.
    error(
        replace(r#"Accept { type: "Id", value: "1" },"#),
        "profile-vectors",
        vectors,
        "Id, is not a type of the package",
    );
    // The value and output are one haus value each; an accepted one is valid for the type.
    error(
        replace(r#"Accept { type: "Order", value: "{ id: 1," },"#),
        "profile-vectors",
        vectors,
        "the value of Accept is not valid haus: unclosed '{' (unclosed-bracket, at 1:1)",
    );
    error(
        replace(r#"Accept { type: "Order", value: "{ id: \"1\", total: 5 }" },"#),
        "profile-vectors",
        vectors,
        "(type-mismatch, at $.id)",
    );
    error(
        replace(r#"Accept { type: "Order", value: "{ id: 1, total: 5 }", output: "{ id: 1 }" },"#),
        "profile-vectors",
        vectors,
        "the output of Accept is not a valid Order",
    );
}

#[test]
fn every_profile_has_its_rule_and_ships_it() {
    error(
        |d| fs::remove_file(d.join("good/profiles/positive.md")).unwrap(),
        "profile-vectors",
        "profiles/positive.vectors.haus",
        "no profiles/positive.md",
    );
    error(
        |d| edit(d, "package.json", r#""profiles"]"#, r#""profiles/*.vectors.haus"]"#),
        "package-files",
        "package.json",
        "profiles/positive.md is not shipped",
    );
}

// ── output and exit codes ───────────────────────────────────

#[test]
fn text_output() {
    let dir = copy();
    edit(dir.path(), "package.json", r#""version": "1.0.0""#, r#""version": "1.0.1""#);
    edit(dir.path(), "Cargo.toml", r#"links = "fixture_good""#, r#"links = "good""#);
    let (code, text) = run(dir.path(), &["--color", "never", "good"]);
    assert_eq!(code, 1);
    insta::assert_snapshot!(text);
}

#[test]
fn what_cant_be_checked_exits_with_2() {
    let (code, json) = run_json(&fixtures(), &["nowhere"]);
    assert_eq!(code, 2);
    assert!(str_of(&array(&json, "packages")[0], "error").is_some(), "{json:?}");
    let (code, json) = run_json(&fixtures(), &["--package", "nowhere", "good"]);
    assert_eq!(code, 2);
    assert_eq!(str_of(json.get("error").unwrap(), "code"), Some("import-not-found"));
    assert!(array(&json, "packages").is_empty());
}
