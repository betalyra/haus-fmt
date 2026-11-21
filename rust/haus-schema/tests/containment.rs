//! Unix only: links, FIFOs and permissions as Unix has them.
#![cfg(unix)]

//! A schema package is a directory with `package.haus` and `schema.haus`
//! (spec §13.3). Both are regular files, never symbolic links (the package
//! directory may be one); its schema imports other packages by name, never files;
//! application files don't import files inside a package directory. Errors
//! have the code `package-path` and never quote a file that wasn't read. And
//! imports name only major versions.
#![cfg(unix)]

use haus::ErrorCode;
use haus_schema::{Error, NodeModules, Packages, Schema};
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

const SECRET: &str = "API_TOKEN=hunter2";
const MONEY: &str = "type Money = closed < Money Decimal Currency >\ntype Currency = < >";
const MANIFEST: &str = "{ name: \"@acme/evil\", version: \"1.2.0\" }";
const PKG: &str = "app/node_modules/@acme/evil";

fn write(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

/// An app, `app/main.schema.haus` with `main`, with `files` around it, and a
/// directory `secret` with files that must never be read.
struct App {
    dir: TempDir,
}

impl App {
    fn new(files: &[(&str, &str)], main: &str) -> App {
        let app = App { dir: tempfile::tempdir().unwrap() };
        write(&app.path("secret/creds.txt"), SECRET);
        write(&app.path("secret/creds.schema.haus"), SECRET);
        fs::create_dir_all(app.path(PKG)).unwrap();
        // The app declares the package it imports (spec §13.3, npm).
        write(&app.path("app/package.json"), r#"{ "name": "app", "dependencies": { "@acme/evil": "*" } }"#);
        for (path, text) in files {
            write(&app.path(path), text);
        }
        write(&app.path("app/main.schema.haus"), main);
        app
    }

    /// An app importing `@acme/evil`, whose package directory has `files`.
    fn importing(files: &[(&str, &str)]) -> App {
        let files: Vec<(String, &str)> = files.iter().map(|(p, t)| (format!("{PKG}/{p}"), *t)).collect();
        let files: Vec<(&str, &str)> = files.iter().map(|(p, t)| (p.as_str(), *t)).collect();
        App::new(&files, "import @acme/evil (Money)\ntype Root = { m: Money }")
    }

    fn path(&self, path: &str) -> PathBuf {
        self.dir.path().join(path)
    }

    fn load(&self) -> Result<Schema, Error> {
        Schema::load(self.path("app/main.schema.haus"), &NodeModules)
    }

    /// The error, which must be `code` and must not quote the secret.
    fn rejected(&self, code: ErrorCode) -> String {
        let e = self.load().expect_err("rejected");
        let message = e.to_string();
        assert_eq!(e.code(), code, "{message}");
        assert!(!message.contains("API_TOKEN") && !message.contains("hunter2"), "{message}");
        message
    }
}

#[test]
fn a_package_is_its_manifest_and_schema_haus() {
    let app = App::importing(&[("package.haus", MANIFEST), ("schema.haus", MONEY)]);
    let schema = app.load().unwrap();
    let ids: Vec<&str> = schema.imported().iter().map(|d| d.id.as_str()).collect();
    assert_eq!(ids, ["@acme/evil@1#Money"]);
}

#[test]
fn other_manifest_fields_are_ignored() {
    let manifest = "{ name: \"@acme/evil\", version: \"1.2.0\", schema: \"../../../../secret/creds.txt\", x: 1 }";
    App::importing(&[("package.haus", manifest), ("schema.haus", MONEY)]).load().unwrap();
}

#[test]
fn a_package_without_schema_haus() {
    let app = App::importing(&[("package.haus", MANIFEST)]);
    assert!(app.rejected(ErrorCode::ImportNotFound).contains("has no schema.haus"));
}

#[test]
fn a_schema_or_manifest_that_links_outside_the_package() {
    let app = App::importing(&[("package.haus", MANIFEST)]);
    symlink(app.path("secret/creds.schema.haus"), app.path(PKG).join("schema.haus")).unwrap();
    assert!(app.rejected(ErrorCode::PackagePath).contains("schema.haus is a symbolic link or not a regular file"));
    let manifest = App::importing(&[("schema.haus", MONEY)]);
    symlink(manifest.path("secret/creds.txt"), manifest.path(PKG).join("package.haus")).unwrap();
    assert!(manifest.rejected(ErrorCode::PackagePath).contains("is a symbolic link"));
}

#[test]
fn a_link_to_the_package_is_followed_a_link_inside_it_is_not() {
    let app = App::new(&[("store/evil/package.haus", MANIFEST), ("store/evil/schema.haus", MONEY)], "");
    fs::remove_dir(app.path(PKG)).unwrap();
    symlink(app.path("store/evil"), app.path(PKG)).unwrap();
    write(&app.path("app/main.schema.haus"), "import @acme/evil (Money)\ntype Root = { m: Money }");
    let schema = app.load().unwrap();
    assert_eq!(schema.imported()[0].id, "@acme/evil@1#Money");
    // schema.haus is a regular file, also when its link stays inside the package.
    fs::rename(app.path("store/evil/schema.haus"), app.path("store/evil/real.haus")).unwrap();
    symlink("real.haus", app.path("store/evil/schema.haus")).unwrap();
    app.rejected(ErrorCode::PackagePath);
}

#[test]
fn a_package_schema_imports_no_files() {
    for import in ["./money", "../../../../secret/creds"] {
        let schema = format!("import {import} (Money)\ntype M = Money");
        let app = App::importing(&[("package.haus", MANIFEST), ("schema.haus", &schema), ("money.schema.haus", MONEY)]);
        let message = app.rejected(ErrorCode::PackagePath);
        assert!(message.contains("the schema of @acme/evil can't import files, only packages by name"), "{message}");
    }
}

#[test]
fn app_files_import_no_files_inside_a_package() {
    let files = [
        ("app/vendor/evil/package.haus", MANIFEST),
        ("app/vendor/evil/schema.haus", MONEY),
        ("app/vendor/evil/sub/extra.schema.haus", MONEY),
    ];
    let direct = App::new(&files, "import ./vendor/evil/sub/extra (Money)\ntype Root = Money");
    let message = direct.rejected(ErrorCode::PackagePath);
    assert!(message.contains("is in the package directory") && message.contains("import the package by its name"));
    let linked = App::new(&files, "import ./link/extra (Money)\ntype Root = Money");
    symlink(linked.path("app/vendor/evil/sub"), linked.path("app/link")).unwrap();
    assert!(linked.rejected(ErrorCode::PackagePath).contains("is in the package directory"));
}

#[test]
fn app_files_import_schema_files_anywhere_else() {
    let main = "import ../shared/money (Money)\ntype Root = { m: Money }";
    App::new(&[("shared/money.schema.haus", MONEY)], main).load().unwrap();
    // The extension is always added: `./x.schema.haus` is x.schema.haus.schema.haus.
    let main = "import ../shared/money.schema.haus (Money)\ntype R = Money";
    let twice = App::new(&[("shared/money.schema.haus", MONEY)], main);
    assert!(twice.rejected(ErrorCode::ImportNotFound).contains("money.schema.haus.schema.haus"));
}

#[test]
fn build_scripts_check_the_package_too() {
    let app = App::importing(&[("package.haus", MANIFEST)]);
    symlink(app.path("secret/creds.schema.haus"), app.path(PKG).join("schema.haus")).unwrap();
    let e = Packages::none().with(&app.path(PKG), "acme_evil").err().expect("rejected");
    assert_eq!(e.code(), ErrorCode::PackagePath);
    assert!(!e.to_string().contains("API_TOKEN"), "{e}");
}

#[test]
fn imports_name_only_major_versions() {
    for v in ["1.1", "1.1.0", "01", "x", ""] {
        let e = Schema::parse(&format!("import @haus-fmt/money@{v} (Money)\ntype A = Money")).expect_err(v);
        assert_eq!(e.code(), ErrorCode::ImportVersion, "@{v}: {e}");
    }
    let e = Schema::parse("import @haus-fmt/money@1.1 (Money)\ntype A = Money").unwrap_err();
    assert_eq!(e.to_string(), "1:1: @haus-fmt/money@1.1: an import names only the major version (@haus-fmt/money@1)");
    assert!(e.hint().contains("dependency range"), "{}", e.hint());
    // `@0` and `@10` are major versions: the import is checked against the package (none here).
    for v in ["0", "10"] {
        let e = Schema::parse(&format!("import @haus-fmt/money@{v} (Money)\ntype A = Money")).unwrap_err();
        assert_eq!(e.code(), ErrorCode::ImportUnavailable, "@{v}: {e}");
    }
}

#[test]
fn a_file_path_has_no_tilde() {
    // Grammar `path`: `./a~b` ends before the `~`, where `(` is expected.
    for module in ["./a~b", "../x~y"] {
        let e = Schema::parse(&format!("import {module} (A)\ntype T = A")).expect_err(module);
        assert_eq!(e.code(), ErrorCode::SchemaSyntax, "{module}: {e}");
        assert!(e.to_string().starts_with(&format!("1:{}:", module.find('~').unwrap() + 8)), "{module}: {e}");
    }
    // A package's version is read to its end: `1~x` is not a major version.
    let e = Schema::parse("import @a/b@1~x (A)\ntype T = A").unwrap_err();
    assert_eq!(e.code(), ErrorCode::ImportVersion, "{e}");
}

#[test]
fn schema_files_and_package_json_have_a_size_limit() {
    let big = format!("type Money = Int\n//{}", "x".repeat(1024 * 1024));
    let app = App::importing(&[("package.haus", MANIFEST), ("schema.haus", &big)]);
    assert!(app.rejected(ErrorCode::FileTooLarge).contains("more than 1 MiB"));
    let json = format!(r#"{{ "name": "@acme/evil", "version": "1.2.0", "x": "{}" }}"#, "x".repeat(1024 * 1024));
    let app = App::importing(&[("package.haus", MANIFEST), ("schema.haus", MONEY), ("package.json", &json)]);
    app.rejected(ErrorCode::FileTooLarge);
    let app = App::new(&[("app/big.schema.haus", &big)], "import ./big (Money)\ntype Root = Money");
    app.rejected(ErrorCode::FileTooLarge);
    // The root too.
    write(&app.path("app/main.schema.haus"), &big);
    app.rejected(ErrorCode::FileTooLarge);
}

#[test]
fn a_package_json_that_isnt_json_declares_nothing_and_gives_no_version() {
    let app = App::importing(&[("package.haus", MANIFEST), ("schema.haus", MONEY), ("package.json", "{ not json")]);
    app.load().unwrap();
    write(&app.path("app/package.json"), "{ not json");
    // The project's package.json isn't JSON: it declares nothing, and the
    // search doesn't go on above it (case package-json-not-json).
    assert!(app.rejected(ErrorCode::UndeclaredPackage).contains("package.json"));
}

#[test]
fn a_fifo_is_not_read_and_does_not_block() {
    let app = App::importing(&[("package.haus", MANIFEST)]);
    let fifo = |path: PathBuf| assert!(std::process::Command::new("mkfifo").arg(path).status().unwrap().success());
    fifo(app.path(PKG).join("schema.haus"));
    app.rejected(ErrorCode::PackagePath);
    let app = App::new(&[], "import ./pipe (T)\ntype Root = T");
    fifo(app.path("app/pipe.schema.haus"));
    assert!(app.rejected(ErrorCode::ImportNotFound).contains("not a regular file"));
}

#[test]
fn a_schema_reaches_at_most_256_files() {
    for (n, ok) in [(255, true), (256, false)] {
        let files: Vec<(String, String)> =
            (0..n).map(|i| (format!("app/f{i}.schema.haus"), format!("type T{i} = Int"))).collect();
        let files: Vec<(&str, &str)> = files.iter().map(|(p, t)| (p.as_str(), t.as_str())).collect();
        let imports: String = (0..n).map(|i| format!("import ./f{i} (T{i})\n")).collect();
        let app = App::new(&files, &format!("{imports}type Root = Int"));
        match ok {
            true => assert_eq!(app.load().unwrap().files().len(), 256),
            false => assert!(app.rejected(ErrorCode::TooManyFiles).contains("more than 256")),
        }
    }
}

#[test]
fn messages_escape_and_cut_text_from_files() {
    let name = format!("@acme/\u{202e}{}", "x".repeat(100));
    let app = App::importing(&[
        ("package.haus", &format!("{{ name: {name:?}, version: \"1.0.0\" }}")),
        ("schema.haus", MONEY),
    ]);
    let message = app.rejected(ErrorCode::PackageManifest);
    assert!(message.contains("\"@acme/\\u{202E}xxxx") && message.contains("x…\""), "{message}");
    assert!(!message.contains('\u{202e}') && !message.contains(&"x".repeat(40)), "{message}");
}
