//! The `haus` command, run as a process: fixtures in tests/fixtures, the
//! conformance suite and the repository's examples.

use assert_cmd::cargo::cargo_bin_cmd;
use haus::json::Json;
use predicates::prelude::*;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// `haus` in the fixtures directory, without color settings from the environment.
fn haus() -> assert_cmd::Command {
    let mut cmd = cargo_bin_cmd!("haus");
    cmd.current_dir(fixtures()).env_remove("NO_COLOR");
    cmd
}

/// `haus check --json …`: the exit code and the parsed output.
fn check_json(dir: &Path, args: &[&str]) -> (i32, Json) {
    let out = haus().current_dir(dir).args(["check", "--json"]).args(args).output().unwrap();
    let text = String::from_utf8(out.stdout).unwrap();
    assert_eq!(text.matches('\n').count(), 1, "one line of JSON: {text}");
    (out.status.code().unwrap(), haus::json::parse(&text).unwrap())
}

fn str_of<'a>(json: &'a Json, name: &str) -> &'a str {
    match json.get(name) {
        Some(Json::String(s)) => s,
        other => panic!("{name}: {other:?}"),
    }
}

fn array<'a>(json: &'a Json, name: &str) -> &'a [Json] {
    match json.get(name) {
        Some(Json::Array(items)) => items,
        other => panic!("{name}: {other:?}"),
    }
}

/// The JSON indented, one member per line, for readable snapshots.
fn pretty(json: &Json) -> String {
    fn write(json: &Json, depth: usize, out: &mut String) {
        let pad = |d: usize| "  ".repeat(d);
        let mut items = |open: char, close: char, items: Vec<(Option<&str>, &Json)>| {
            if items.is_empty() {
                out.push(open);
                out.push(close);
                return;
            }
            out.push(open);
            out.push('\n');
            for (i, (name, value)) in items.iter().enumerate() {
                out.push_str(&pad(depth + 1));
                if let Some(name) = name {
                    out.push_str(&haus::json::write(&Json::String((*name).to_owned())).unwrap());
                    out.push_str(": ");
                }
                write(value, depth + 1, out);
                out.push_str(if i + 1 < items.len() { ",\n" } else { "\n" });
            }
            out.push_str(&pad(depth));
            out.push(close);
        };
        match json {
            Json::Array(a) => items('[', ']', a.iter().map(|v| (None, v)).collect()),
            Json::Object(m) => items('{', '}', m.iter().map(|(k, v)| (Some(k.as_str()), v)).collect()),
            scalar => out.push_str(&haus::json::write(scalar).unwrap()),
        }
    }
    let mut out = String::new();
    write(json, 0, &mut out);
    out
}

// ── version, help, completions ──────────────────────────────────

#[test]
fn version_names_the_spec_version_of_the_spec_header() {
    let spec = fs::read_to_string(repo().join("spec/README.md")).unwrap();
    let header = spec.lines().next().unwrap();
    let version = header.split_once("— ").unwrap().1;
    let expected = format!("haus {} (spec {version})\n", env!("CARGO_PKG_VERSION"));
    haus().arg("--version").assert().success().stdout(expected);
}

#[test]
fn completions() {
    haus().args(["completions", "bash"]).assert().success().stdout(predicate::str::contains("haus"));
    haus().args(["completions", "zsh"]).assert().success().stdout(predicate::str::contains("#compdef haus"));
    haus().args(["completions", "nosh"]).assert().code(2);
}

#[test]
fn usage_errors_exit_with_2() {
    haus().assert().code(2);
    haus().arg("check").assert().code(2).stderr(predicate::str::contains("<PATH>"));
    haus().arg("fmt").assert().code(2);
    haus().args(["check", "--schema", "x.schema.haus", "--no-schema", "a.haus"]).assert().code(2);
    haus().args(["check", "--max-depth", "257", "adjacent"]).assert().code(2).stderr(predicate::str::contains("256"));
    haus().args(["fmt", "--indent", "0", "fmt"]).assert().code(2);
    haus().args(["fmt", "--layout", "fancy", "fmt"]).assert().code(2);
    haus().args(["fmt", "--style", "fancy", "fmt"]).assert().code(2);
}

// ── check ────────────────────────────────────────────────────────

#[test]
fn check_a_valid_file_against_the_schema_next_to_it() {
    haus().args(["check", "adjacent/order.haus"]).assert().success().stdout("Checked 1 file: no problems.\n");
    let (code, json) = check_json(&fixtures(), &["adjacent/order.haus"]);
    assert_eq!(code, 0);
    let file = &array(&json, "files")[0];
    assert_eq!(str_of(file, "schema"), "adjacent/order.schema.haus#Root");
}

#[test]
fn check_invalid_data_json() {
    let (code, json) = check_json(&fixtures(), &["adjacent/order-bad.haus"]);
    assert_eq!(code, 1);
    insta::assert_snapshot!(pretty(&json));
}

#[test]
fn check_invalid_data_text() {
    let out = haus().args(["check", "adjacent/order-bad.haus"]).assert().code(1).get_output().stdout.clone();
    insta::assert_snapshot!(String::from_utf8(out).unwrap());
}

#[test]
fn check_syntax_error_text() {
    let out = haus().args(["check", "syntax/payload-newline.haus"]).assert().code(1).get_output().stdout.clone();
    insta::assert_snapshot!(String::from_utf8(out).unwrap());
}

#[test]
fn check_with_the_schema_named_in_a_comment() {
    haus().args(["check", "comment/circle.haus"]).assert().success();
    let (code, json) = check_json(&fixtures(), &["comment/triangle.haus"]);
    assert_eq!(code, 1);
    let file = &array(&json, "files")[0];
    assert_eq!(str_of(file, "schema"), "comment/shapes.schema.haus#Shape");
    let d = &array(file, "diagnostics")[0];
    assert_eq!(str_of(d, "code"), "unknown-tag");
    assert_eq!(str_of(d, "path"), "$");
}

#[test]
fn a_schema_comment_that_names_nothing() {
    let (code, json) = check_json(&fixtures(), &["comment/missing.haus", "comment/notype.haus"]);
    assert_eq!(code, 1);
    insta::assert_snapshot!(pretty(&json));
}

#[test]
fn check_with_schema_option_overrides() {
    let schema = "comment/shapes.schema.haus#Shape";
    haus().args(["check", "--schema", schema, "-"]).write_stdin("Square { side: 2.0 }").assert().success();
    haus()
        .args(["check", "--schema", schema, "-"])
        .write_stdin("Square { side: \"2\" }")
        .assert()
        .code(1)
        .stdout(predicate::str::contains("error[type-mismatch]").and(predicate::str::contains("<stdin>:1:16")));
    // It wins over the comment and the file next to the data.
    haus().args(["check", "--schema", schema, "comment/triangle.haus"]).assert().code(1);
    haus().args(["check", "--schema", "adjacent/order.schema.haus", "comment/circle.haus"]).assert().code(1);
    haus().args(["check", "--schema", "nowhere.schema.haus", "adjacent"]).assert().code(2);
}

#[test]
fn check_syntax_only() {
    haus().args(["check", "--no-schema", "adjacent/order-bad.haus", "comment/missing.haus"]).assert().success();
    haus().args(["check", "--no-schema", "syntax/null.haus"]).assert().code(1);
}

#[test]
fn check_a_schema_file_shows_its_warnings() {
    let (code, json) = check_json(&fixtures(), &["schemas/old.schema.haus"]);
    assert_eq!(code, 0, "warnings don't fail");
    insta::assert_snapshot!(pretty(&json));
}

#[test]
fn a_broken_schema_is_reported_for_its_data_files_too() {
    let (code, json) = check_json(&fixtures(), &["badschema"]);
    assert_eq!(code, 1);
    let files = array(&json, "files");
    let paths: Vec<&str> = files.iter().map(|f| str_of(f, "path")).collect();
    assert_eq!(paths, ["badschema/data.haus", "badschema/data.schema.haus"]);
    let in_data = &array(&files[0], "diagnostics")[0];
    assert_eq!(str_of(in_data, "file"), "badschema/data.schema.haus");
    assert_eq!(str_of(in_data, "code"), "unknown-type");
    assert_eq!(str_of(&array(&files[1], "diagnostics")[0], "code"), "unknown-type");
}

#[test]
fn check_stdin() {
    let (code, json) = {
        let out = haus().args(["check", "--json", "-"]).write_stdin("{ a: 1 }\n{ b: 2 }").output().unwrap();
        (out.status.code().unwrap(), haus::json::parse(&String::from_utf8(out.stdout).unwrap()).unwrap())
    };
    assert_eq!(code, 1);
    let file = &array(&json, "files")[0];
    assert_eq!(str_of(file, "path"), "<stdin>");
    assert_eq!(str_of(&array(file, "diagnostics")[0], "code"), "missing-comma");
    haus().args(["check", "-"]).write_stdin("{ a: 1 },\n{ b: 2 },\n").assert().success();
    haus()
        .args(["check", "-"])
        .write_stdin("Circle\n  { r: 1 }")
        .assert()
        .code(1)
        .stdout(predicate::str::contains("error[payload-newline]"));
}

#[test]
fn invalid_utf8() {
    haus()
        .args(["check", "-"])
        .write_stdin(&b"\"ab\xff\""[..])
        .assert()
        .code(1)
        .stdout(predicate::str::contains("error[invalid-utf8]"));
}

#[test]
fn directories_respect_gitignore_and_skip_other_files() {
    let dir = tempfile::tempdir().unwrap();
    let write = |path: &str, text: &str| {
        let path = dir.path().join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    };
    write(".gitignore", "ignored/\n");
    write("a.haus", "{ a: 1 }\n");
    write("a.schema.haus", "type Root = { a: Int }\n");
    write("sub/b.haus", "[1, 2]\n");
    write("notes.txt", "not haus {\n");
    write("ignored/bad.haus", "{ broken\n");
    write(".hidden/bad.haus", "{ broken\n");
    let (code, json) = check_json(dir.path(), &["."]);
    assert_eq!(code, 0, "{json:?}");
    let files = array(&json, "files");
    let listed: Vec<(&str, &str)> = files.iter().map(|f| (str_of(f, "path"), str_of(f, "kind"))).collect();
    assert_eq!(listed, [("./a.haus", "data"), ("./a.schema.haus", "schema"), ("./sub/b.haus", "data")]);
    assert_eq!(str_of(&files[0], "schema"), "./a.schema.haus#Root");
    // A file named explicitly is checked whatever its name, and once.
    let (code, json) = check_json(dir.path(), &["ignored/bad.haus", "ignored/bad.haus"]);
    assert_eq!((code, array(&json, "files").len()), (1, 1));
}

#[cfg(unix)]
#[test]
fn packages_in_node_modules() {
    let dir = tempfile::tempdir().unwrap();
    let write = |path: &str, text: &str| {
        let path = dir.path().join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    };
    let manifest = |name: &str| format!("{{ name: \"{name}\", version: \"1.2.0\" }}");
    write("secret/creds.txt", "API_TOKEN=hunter2");
    write("secret/creds.schema.haus", "API_TOKEN=hunter2");
    // A package that works: app → @acme/orders → @haus-fmt/money, hoisted.
    write("app/node_modules/@haus-fmt/money/package.haus", &manifest("@haus-fmt/money"));
    write("app/node_modules/@haus-fmt/money/schema.haus", "type Money = closed < Money Decimal String >");
    write("app/node_modules/@acme/orders/package.haus", &manifest("@acme/orders"));
    write(
        "app/node_modules/@acme/orders/schema.haus",
        "import @haus-fmt/money@1 (Money)\ntype Order = { total: Money }",
    );
    write("app/order.schema.haus", "import @acme/orders (Order)\ntype Root = Order");
    write("app/order.haus", "{ total: Money(19.99, \"EUR\") }");
    let (code, json) = check_json(dir.path(), &["app"]);
    assert_eq!(code, 0, "{}", pretty(&json));
    // A package's schema.haus is a schema file.
    let (code, json) = check_json(dir.path(), &["app/node_modules/@acme/orders"]);
    assert_eq!(code, 0, "{}", pretty(&json));
    let kinds: Vec<&str> = array(&json, "files").iter().map(|f| str_of(f, "kind")).collect();
    assert_eq!(kinds, ["data", "schema"], "package.haus, schema.haus");
    // Packages that read files outside themselves, each imported by an app schema.
    let evil = [
        ("link", "", Some("secret/creds.schema.haus")),
        ("import", "import ../../../../secret/creds (T)\ntype U = T", None),
        ("near", "import ./near (T)\ntype U = T", None),
    ];
    for (name, schema, link) in evil {
        let package = format!("app/node_modules/@evil/{name}");
        write(&format!("{package}/package.haus"), &manifest(&format!("@evil/{name}")));
        write(&format!("{package}/near.schema.haus"), "type T = Int");
        match link {
            Some(target) => {
                std::os::unix::fs::symlink(dir.path().join(target), dir.path().join(&package).join("schema.haus"))
                    .unwrap()
            }
            None => write(&format!("{package}/schema.haus"), schema),
        }
        write(&format!("app/{name}.schema.haus"), &format!("import @evil/{name} (T)\ntype Root = T"));
        let (code, json) = check_json(dir.path(), &[&format!("app/{name}.schema.haus")]);
        assert_eq!(code, 1, "{name}");
        let diagnostic = &array(&array(&json, "files")[0], "diagnostics")[0];
        assert_eq!(str_of(diagnostic, "code"), "package-path", "{name}: {}", pretty(&json));
        assert!(!pretty(&json).contains("API_TOKEN"), "{name}: {}", pretty(&json));
    }
    // An app file that imports a file inside a package directory.
    write("app/into.schema.haus", "import ./node_modules/x/near (T)\ntype Root = T");
    write("app/node_modules/x/package.haus", &manifest("@evil/x"));
    write("app/node_modules/x/near.schema.haus", "type T = Int");
    let (code, json) = check_json(dir.path(), &["app/into.schema.haus"]);
    assert_eq!(code, 1);
    assert_eq!(str_of(&array(&array(&json, "files")[0], "diagnostics")[0], "code"), "package-path");
}

#[test]
fn io_errors_exit_with_2_and_are_reported() {
    let (code, json) = check_json(&fixtures(), &["adjacent/order.haus", "nowhere.haus"]);
    assert_eq!(code, 2);
    let missing = &array(&json, "files")[1];
    assert_eq!(str_of(missing, "path"), "nowhere.haus");
    assert!(missing.get("error").is_some());
    assert_eq!(missing.get("ok"), Some(&Json::Bool(false)));
    // Invalid data elsewhere doesn't lower it.
    haus().args(["check", "syntax/null.haus", "nowhere.haus"]).assert().code(2);
}

#[test]
fn json_output_even_when_nothing_can_be_checked() {
    // A --schema that doesn't exist: the document, with the reason in `error`, and exit code 2.
    let (code, json) = check_json(&fixtures(), &["--schema", "missing.schema.haus", "adjacent/order.haus"]);
    assert_eq!(code, 2);
    insta::assert_snapshot!(pretty(&json));
    haus()
        .args(["check", "--json", "--schema", "missing.schema.haus#Order", "-"])
        .write_stdin("{}")
        .assert()
        .code(2)
        .stderr("");
    // Without --json, the reason goes to standard error.
    haus()
        .args(["check", "--schema", "missing.schema.haus", "adjacent/order.haus"])
        .assert()
        .code(2)
        .stdout("")
        .stderr("error: --schema missing.schema.haus: no such file\n");
}

#[test]
fn wrong_payload_hints_name_the_case() {
    let schema = "comment/shapes.schema.haus#Shape";
    let out = haus().args(["check", "--json", "--schema", schema, "-"]).write_stdin("Circle(1.5)").output().unwrap();
    let json = haus::json::parse(&String::from_utf8(out.stdout).unwrap()).unwrap();
    let d = &array(&array(&json, "files")[0], "diagnostics")[0];
    assert_eq!(str_of(d, "code"), "wrong-payload");
    assert_eq!(str_of(d, "path"), "$");
    assert_eq!(str_of(d, "hint"), "Circle takes one argument, a record { r: Float64 }: write `Circle { … }`.");
}

#[test]
fn limits() {
    haus()
        .args(["check", "--max-depth", "1", "-"])
        .write_stdin("[[1]]")
        .assert()
        .code(1)
        .stdout(predicate::str::contains("nesting-too-deep"));
    haus().args(["check", "--max-number-length", "3", "-"]).write_stdin("1234").assert().code(1);
    haus().args(["check", "--max-depth", "256", "-"]).write_stdin("[[1]]").assert().success();
}

#[test]
fn colors() {
    let esc = predicate::str::contains("\u{1b}[");
    // Not a terminal: no colors, unless asked for.
    haus().args(["check", "syntax/null.haus"]).assert().code(1).stdout(esc.clone().not());
    haus()
        .args(["check", "--color", "auto", "syntax/null.haus"])
        .env("NO_COLOR", "1")
        .assert()
        .stdout(esc.clone().not());
    haus().args(["check", "--color", "never", "syntax/null.haus"]).assert().stdout(esc.clone().not());
    haus().args(["check", "--color", "always", "syntax/null.haus"]).assert().stdout(esc.clone());
    haus().args(["--color", "always", "fmt", "--check", "syntax/null.haus"]).assert().stderr(esc.clone());
    // JSON never has colors.
    haus().args(["check", "--json", "--color", "always", "syntax/null.haus"]).assert().stdout(esc.not());
}

// ── the conformance suite and the repository ─────────────────────

/// The repository's `examples` as CI sees them, without `pnpm install`: the
/// files copied into a temporary directory, with the official packages they
/// import in a `node_modules` of their own, taken from `extensions`.
fn examples_with_packages() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let examples = dir.path().join("examples");
    fs::create_dir_all(&examples).unwrap();
    for entry in fs::read_dir(repo().join("examples")).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() {
            fs::copy(&path, examples.join(path.file_name().unwrap())).unwrap();
        }
    }
    for name in ["money", "geo"] {
        let package = examples.join("node_modules/@haus-fmt").join(name);
        fs::create_dir_all(&package).unwrap();
        for file in ["package.haus", "schema.haus"] {
            fs::copy(repo().join("extensions").join(name).join(file), package.join(file)).unwrap();
        }
    }
    dir
}

#[test]
fn the_repository_has_no_errors() {
    let no_errors = |json: &Json| {
        let summary = json.get("summary").unwrap();
        assert_eq!(summary.get("errors"), Some(&Json::Number("0".into())), "{}", pretty(json));
    };
    let (code, json) = check_json(&repo(), &["test-suite/valid", "extensions"]);
    no_errors(&json);
    assert_eq!(code, 0);
    let suite = array(&json, "files").len();

    let examples = examples_with_packages();
    let (code, json) = check_json(examples.path(), &["examples"]);
    no_errors(&json);
    assert_eq!(code, 0);
    assert!(suite + array(&json, "files").len() > 40);
}

#[test]
fn invalid_suite_files_are_rejected_with_their_code() {
    let (code, json) = check_json(&repo(), &["test-suite/invalid"]);
    assert_eq!(code, 1);
    let files = array(&json, "files");
    let expected = fs::read_dir(repo().join("test-suite/invalid"))
        .unwrap()
        .filter(|e| e.as_ref().unwrap().path().extension().is_some_and(|x| x == "error"))
        .count();
    assert_eq!(files.len(), expected);
    for file in files {
        let path = str_of(file, "path");
        let error = repo().join(path.strip_suffix(".haus").unwrap().to_owned() + ".error");
        let code = fs::read_to_string(error).unwrap();
        let codes: Vec<&str> = array(file, "diagnostics").iter().map(|d| str_of(d, "code")).collect();
        assert_eq!(codes, [code.trim()], "{path}");
    }
}

#[test]
fn canonical_and_hash_match_the_suite() {
    let valid = repo().join("test-suite/valid");
    let mut n = 0;
    for entry in fs::read_dir(&valid).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|x| x != "haus") {
            continue;
        }
        n += 1;
        let canonical = fs::read_to_string(path.with_extension("canonical")).unwrap();
        let hash = fs::read_to_string(path.with_extension("hash")).unwrap();
        haus().arg("canonical").arg(&path).assert().success().stdout(canonical.clone());
        haus().arg("hash").arg(&path).assert().success().stdout(hash.clone());
        // Standard input, and the hash of each value.
        haus().arg("hash").write_stdin(fs::read(&path).unwrap()).assert().success().stdout(hash);
        let each = haus().args(["hash", "--each"]).arg(&path).assert().success().get_output().stdout.clone();
        assert_eq!(String::from_utf8(each).unwrap().lines().count(), canonical.lines().count());
    }
    assert!(n >= 20);
}

#[test]
fn canonical_and_hash_of_a_stream() {
    haus()
        .args(["canonical", "-"])
        .write_stdin("1, \"a\", Order { id: 0xFF, \"x-y\": 1e+5 },\n")
        .assert()
        .success()
        .stdout("1\n\"a\"\nOrder{id:255,\"x-y\":1e5}\n");
    // `v` and `v,` are the same file; the empty file hashes the empty text.
    let one = haus().args(["hash", "-"]).write_stdin("Some(1)").assert().success().get_output().stdout.clone();
    haus().args(["hash", "-"]).write_stdin("Some(1),").assert().stdout(String::from_utf8(one.clone()).unwrap());
    haus().args(["hash", "--each", "-"]).write_stdin("Some(1),").assert().stdout(String::from_utf8(one).unwrap());
    haus()
        .arg("hash")
        .write_stdin("")
        .assert()
        .success()
        .stdout("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
}

#[test]
fn canonical_and_hash_errors() {
    haus()
        .args(["canonical", "-"])
        .write_stdin("1,\n2 3,\n")
        .assert()
        .code(1)
        .stderr(predicate::str::contains("error[missing-comma]").and(predicate::str::contains("<stdin>:2:3")));
    haus().args(["hash", "-"]).write_stdin("[1,").assert().code(1).stdout("");
    haus().args(["hash", "nowhere.haus"]).assert().code(2);
}

#[test]
fn an_integer_of_any_size_has_a_canonical_form_and_hash() {
    // 1300 digits: beyond the default number limit, read with a raised one; written in decimal (spec §12).
    let huge = "9".repeat(1300);
    let input = format!("1, {{ a: [{huge}] }},\n");
    haus()
        .args(["canonical", "--max-number-length", "2000", "-"])
        .write_stdin(input.clone())
        .assert()
        .success()
        .stdout(format!("1\n{{a:[{huge}]}}\n"));
    for args in [&["hash", "--each"][..], &["hash"]] {
        haus()
            .args(args)
            .args(["--max-number-length", "2000", "-"])
            .write_stdin(input.clone())
            .assert()
            .success()
            .stdout(predicate::str::is_match("^([0-9a-f]{64}\n)+$").unwrap());
    }
    // With the default limit, it is a syntax error at the literal.
    haus()
        .args(["canonical", "-"])
        .write_stdin(input)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("error[number-too-long]").and(predicate::str::contains("<stdin>:1:10")));
}

// ── live streams (`tail -f x.haus | haus …`) ───────────────────

/// `haus` reading a stream that is still being written: standard input stays
/// open, and each line of output must come before it is closed.
struct Live {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
}

impl Live {
    fn start(dir: &Path, args: &[&str]) -> Live {
        let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_haus"))
            .current_dir(dir)
            .args(args)
            .env_remove("NO_COLOR")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (send, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if send.send(line.unwrap()).is_err() {
                    break;
                }
            }
        });
        Live { stdin: child.stdin.take(), child, lines }
    }

    fn send(&mut self, text: &str) {
        let stdin = self.stdin.as_mut().unwrap();
        stdin.write_all(text.as_bytes()).unwrap();
        stdin.flush().unwrap();
    }

    /// The next line of output, while standard input is still open.
    fn line(&self) -> String {
        self.lines.recv_timeout(Duration::from_secs(5)).expect("a line of output within 5 s")
    }

    /// The lines of output up to the one that starts with `end`, without
    /// the empty lines before them.
    fn lines_to(&self, end: &str) -> Vec<String> {
        let mut out = vec![self.line()];
        while out[0].is_empty() {
            out[0] = self.line();
        }
        while !out.last().unwrap().starts_with(end) {
            out.push(self.line());
        }
        out
    }

    /// Close standard input: the rest of the output, and the exit code.
    fn close(mut self) -> (Vec<String>, i32) {
        drop(self.stdin.take());
        let code = self.child.wait().unwrap().code().unwrap();
        (self.lines.iter().collect(), code)
    }
}

#[test]
fn canonical_and_hash_each_print_each_value_as_it_comes() {
    let mut live = Live::start(&fixtures(), &["canonical"]);
    live.send("A { x: 1 },\n");
    assert_eq!(live.line(), "A{x:1}");
    live.send("B(2.50),\n");
    assert_eq!(live.line(), "B(2.50)");
    assert_eq!(live.close(), (vec![], 0));

    let hash = |text: &str| haus::hash(&haus::parse(text).unwrap()[0]);
    let mut live = Live::start(&fixtures(), &["hash", "--each", "-"]);
    live.send("A { x: 1 },\n");
    assert_eq!(live.line(), hash("A { x: 1 }"));
    live.send("// a comment\nB,\n");
    assert_eq!(live.line(), hash("B"));
    assert_eq!(live.close(), (vec![], 0));
}

#[test]
fn check_stdin_reports_each_value_as_it_comes() {
    let mut live = Live::start(&fixtures(), &["check", "--color", "never", "-"]);
    live.send("{ a: 1 },\n");
    live.send("{ b: [1 2] },\n");
    let error = live.lines_to("  = docs");
    assert_eq!(error[0], "error[missing-comma]: expected ',' or ']', found '2'");
    assert_eq!(error[1], " --> <stdin>:2:9");
    assert_eq!(error[3], "2 | { b: [1 2] },");
    // A syntax error ends the stream: the summary comes without waiting for the rest.
    assert_eq!(live.line(), "");
    assert_eq!(live.line(), "Checked 1 file: 1 error.");
    assert_eq!(live.close(), (vec![], 1));
}

#[test]
fn check_stdin_against_a_stream_schema_reports_each_value_as_it_comes() {
    let dir = tempfile::tempdir().unwrap();
    let schema = "type Shape = closed < Circle { r: Float64 } | Square { side: Float64 } >\ntype Root = Stream Shape\n";
    fs::write(dir.path().join("shapes.schema.haus"), schema).unwrap();
    let mut live = Live::start(dir.path(), &["check", "--color", "never", "--schema", "shapes.schema.haus", "-"]);
    live.send("Square { side: 2.0 },\n");
    live.send("Square { side: \"2\" },\n");
    let error = live.lines_to("  = docs");
    assert_eq!(error[0], "error[type-mismatch]: expected Float64, found the string \"2\"");
    assert_eq!(error[1], " --> <stdin>:2:16");
    assert!(error.contains(&"  = at: $[1].side".to_owned()), "{error:?}");
    // The check goes on: two values on one line, the second one wrong.
    live.send("Circle { r: 1.0 }, Circle { r: Some(1) },\n");
    let error = live.lines_to("  = docs");
    assert_eq!(error[0], "error[type-mismatch]: expected Float64, found the tag Some");
    assert_eq!(error[1], " --> <stdin>:3:32");
    assert!(error.contains(&"  = at: $[3].r".to_owned()), "{error:?}");
    let (rest, code) = live.close();
    assert_eq!((rest, code), (vec!["".to_owned(), "Checked 1 file: 2 errors.".to_owned()], 1));
}

#[test]
fn check_stdin_against_a_document_schema_rejects_a_second_value() {
    let mut live =
        Live::start(&fixtures(), &["check", "--color", "never", "--schema", "comment/shapes.schema.haus#Shape", "-"]);
    live.send("Square { side: 2.0 },\n");
    live.send("Square { side: 3.0 },\n");
    let error = live.lines_to("  = docs");
    assert_eq!(error[0], "error[not-one-value]: expected one value (Shape is not a Stream), found more than one");
    assert_eq!(error[1], " --> <stdin>:2:1");
    live.send("Square { side: \"not checked\" },\n");
    let (rest, code) = live.close();
    assert_eq!((rest, code), (vec!["".to_owned(), "Checked 1 file: 1 error.".to_owned()], 1));
}

#[test]
fn fmt_compact_stdin_writes_each_value_as_it_comes() {
    for (layout, first) in [("compact", "{ a: 1, b: [2] },"), ("minimised", "{a:1,b:[2]},")] {
        let mut live = Live::start(&fixtures(), &["fmt", "--layout", layout, "-"]);
        live.send("{a:1,\n// c\nb:[2]},\n");
        assert_eq!(live.line(), first);
        live.send("  Tag,\n");
        assert_eq!(live.line(), "Tag,");
        live.send("Last");
        // The last value has no comma: it is complete only at the end of the input.
        assert_eq!(live.close(), (vec!["Last,".to_owned()], 0));
    }
    // A lone value keeps the comma it came with: when it was written, more could have come.
    haus().args(["fmt", "--layout", "compact", "-"]).write_stdin("{ a: 1 },\n").assert().stdout("{ a: 1 },\n");
    haus().args(["fmt", "--layout", "compact", "-"]).write_stdin("{ a: 1 }\n").assert().stdout("{ a: 1 }\n");
}

/// `text` without its ANSI codes.
fn strip_ansi(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(i) = rest.find("\x1b[") {
        out.push_str(&rest[..i]);
        rest = &rest[i + rest[i..].find('m').unwrap() + 1..];
    }
    out.push_str(rest);
    out
}

#[test]
fn haus_text_is_colored_only_when_asked_for() {
    let input = "// c\nOrder { id: 1, \"x-y\": \"a\\tb\", raw: x\"00ff\", ok: True, n: -1.5e3 },\nB,\n";
    let commands: [&[&str]; 4] =
        [&["canonical"], &["fmt", "-"], &["fmt", "--layout", "compact", "-"], &["fmt", "--layout", "minimised", "-"]];
    for args in commands {
        let run = |color: &[&str]| {
            let out = haus().args(color).args(args).write_stdin(input).output().unwrap();
            assert!(out.status.success(), "{args:?}");
            String::from_utf8(out.stdout).unwrap()
        };
        // Not a terminal: exactly the plain text.
        let plain = run(&[]);
        assert!(!plain.contains('\x1b'), "{args:?}");
        assert_eq!(run(&["--color", "never"]), plain);
        let colored = run(&["--color", "always"]);
        assert_ne!(colored, plain, "{args:?}");
        assert_eq!(strip_ansi(&colored), plain, "{args:?}");
        assert!(colored.contains("\x1b[36mOrder\x1b[0m"), "{args:?}: {colored:?}");
        assert!(colored.contains("\x1b[33m1\x1b[0m"), "{args:?}: {colored:?}");
    }
    let colored = haus().args(["--color", "always", "fmt", "-"]).write_stdin(input).output().unwrap().stdout;
    let colored = String::from_utf8(colored).unwrap();
    for part in ["\x1b[2m// c\x1b[0m", "\x1b[34m\"x-y\"\x1b[0m", "\x1b[1;32m\\t\x1b[0m", "\x1b[35mx\"00ff\"\x1b[0m"] {
        assert!(colored.contains(part), "{part:?}: {colored:?}");
    }
    // Hashes and check's JSON are never colored.
    let hashes = haus().args(["hash", "--each", "--color", "always", "-"]).write_stdin(input).output().unwrap().stdout;
    assert!(!hashes.contains(&0x1b));
}

// ── fmt ──────────────────────────────────────────────────────────

#[test]
fn fmt_check_lists_files_that_would_change() {
    let before = fs::read_to_string(fixtures().join("fmt/messy.haus")).unwrap();
    haus().args(["fmt", "--check", "fmt"]).assert().code(1).stdout("fmt/messy.haus\n");
    assert_eq!(fs::read_to_string(fixtures().join("fmt/messy.haus")).unwrap(), before, "--check writes nothing");
    haus().args(["fmt", "--check", "fmt/clean.haus"]).assert().success().stdout("");
}

#[test]
fn fmt_rewrites_in_place_and_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("messy.haus");
    fs::copy(fixtures().join("fmt/messy.haus"), &file).unwrap();
    fs::write(dir.path().join("s.schema.haus"), "type   Root = {a:Int}\n").unwrap();
    haus().current_dir(dir.path()).args(["fmt", "."]).assert().success().stdout("./messy.haus\n");
    insta::assert_snapshot!(fs::read_to_string(&file).unwrap());
    haus().current_dir(dir.path()).args(["fmt", "--check", "."]).assert().success().stdout("");
    haus().current_dir(dir.path()).args(["fmt", "."]).assert().success().stdout("");
    assert_eq!(fs::read_to_string(dir.path().join("s.schema.haus")).unwrap(), "type   Root = {a:Int}\n");
}

#[test]
fn fmt_never_writes_a_file_with_a_syntax_error() {
    let dir = tempfile::tempdir().unwrap();
    let broken = dir.path().join("broken.haus");
    let messy = dir.path().join("messy.haus");
    fs::write(&broken, "{ a:   1, b: null }\n").unwrap();
    fs::copy(fixtures().join("fmt/messy.haus"), &messy).unwrap();
    haus()
        .current_dir(dir.path())
        .args(["fmt", "broken.haus", "messy.haus"])
        .assert()
        .code(1)
        .stdout("messy.haus\n")
        .stderr(predicate::str::contains("error[null-literal]").and(predicate::str::contains("broken.haus:1:14")));
    assert_eq!(fs::read_to_string(&broken).unwrap(), "{ a:   1, b: null }\n");
}

#[test]
fn fmt_stdin_to_stdout() {
    haus()
        .args(["fmt", "-"])
        .write_stdin("{a:1,b:[Some(2)]}")
        .assert()
        .success()
        .stdout("{\n  a: 1,\n  b: [\n    Some(2),\n  ],\n}\n");
    // Standard output needs no --drop-comments. `--style` is the layout's older name.
    for layout in ["--layout", "--style"] {
        haus()
            .args(["fmt", layout, "compact", "-"])
            .write_stdin("{a:1,\n// c\nb:[2]}")
            .assert()
            .success()
            .stdout("{ a: 1, b: [2] }\n");
    }
    for name in ["minimised", "minimized"] {
        haus()
            .args(["fmt", "--layout", name, "-"])
            .write_stdin("{ a: 1_000, // c\n b: [x\"9f86 d081\", Tag { c: 0xFF }] }, 2,")
            .assert()
            .success()
            .stdout("{a:1_000,b:[x\"9f86 d081\",Tag{c:0xFF}]},\n2,\n");
    }
    haus().args(["fmt", "--indent", "4", "-"]).write_stdin("[1]").assert().stdout("[\n    1,\n]\n");
    haus()
        .args(["fmt", "--width", "10", "-"])
        .write_stdin("Money(7.90, EUR)")
        .assert()
        .stdout("Money(\n  7.90,\n  EUR,\n)\n");
    haus().args(["fmt", "--check", "-"]).write_stdin("[1]").assert().code(1).stdout("<stdin>\n");
    haus().args(["fmt", "--check", "-"]).write_stdin("[\n  1,\n]\n").assert().success().stdout("");
    haus().args(["fmt", "-"]).write_stdin("[1 2]").assert().code(1).stdout("");
}

#[test]
fn fmt_layouts() {
    let file = fs::read_to_string(fixtures().join("fmt/messy.haus")).unwrap();
    let layout = |name: &str| {
        let out = haus().args(["fmt", "--layout", name, "-"]).write_stdin(file.clone()).output().unwrap();
        assert!(out.status.success(), "{name}");
        format!("── {name}\n{}", String::from_utf8(out.stdout).unwrap())
    };
    insta::assert_snapshot!(["pretty", "compact", "minimised"].map(layout).join(""));
}

#[test]
fn fmt_in_place_drops_comments_only_when_asked() {
    let dir = tempfile::tempdir().unwrap();
    let commented = dir.path().join("commented.haus");
    let plain = dir.path().join("plain.haus");
    fs::write(&commented, "{ a: 1, // why\n b: 2 }\n").unwrap();
    fs::write(&plain, "{ a: 1,\n b: 2 }\n").unwrap();
    for layout in ["compact", "minimised"] {
        // Refused for the file with comments, which stays as it was; the other one is rewritten.
        haus()
            .current_dir(dir.path())
            .args(["fmt", "--layout", layout, "commented.haus", "plain.haus"])
            .assert()
            .code(2)
            .stdout("plain.haus\n")
            .stderr(format!(
                "error: commented.haus: not rewritten: it has comments, which the {layout} layout drops \
                 (pass --drop-comments to drop them, or format to standard output)\n"
            ));
        assert_eq!(fs::read_to_string(&commented).unwrap(), "{ a: 1, // why\n b: 2 }\n");
        // --check writes nothing, so it only lists the file.
        haus()
            .current_dir(dir.path())
            .args(["fmt", "--check", "--layout", layout, "commented.haus"])
            .assert()
            .code(1)
            .stdout("commented.haus\n");
    }
    assert_eq!(fs::read_to_string(&plain).unwrap(), "{a:1,b:2}\n");
    haus()
        .current_dir(dir.path())
        .args(["fmt", "--layout", "minimised", "--drop-comments", "commented.haus"])
        .assert()
        .success()
        .stdout("commented.haus\n");
    assert_eq!(fs::read_to_string(&commented).unwrap(), "{a:1,b:2}\n");
    // Pretty keeps comments, so it needs no option.
    fs::write(&commented, "{ a: 1, // why\n b: 2 }\n").unwrap();
    haus().current_dir(dir.path()).args(["fmt", "commented.haus"]).assert().success().stdout("commented.haus\n");
    assert_eq!(fs::read_to_string(&commented).unwrap(), "{\n  a: 1, // why\n  b: 2,\n}\n");
}

#[test]
fn every_form_of_the_same_data_has_the_same_hash() {
    let file = fs::read(fixtures().join("fmt/messy.haus")).unwrap();
    let run = |args: &[&str], input: &[u8]| haus().args(args).write_stdin(input).output().unwrap().stdout;
    let hash = run(&["hash", "-"], &file);
    assert_eq!(hash.len(), 65);
    for layout in ["pretty", "compact", "minimised"] {
        let formatted = run(&["fmt", "--layout", layout, "-"], &file);
        assert_ne!(formatted, file);
        assert_eq!(run(&["hash", "-"], &formatted), hash, "{layout}");
    }
    assert_eq!(run(&["hash", "-"], &run(&["canonical", "-"], &file)), hash, "canonical");
    haus()
        .args(["hash", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("minimised layouts and the canonical form of the same data all have"));
}

#[test]
fn fmt_refuses_schema_files() {
    haus()
        .args(["fmt", "schemas/old.schema.haus"])
        .assert()
        .code(2)
        .stderr(predicate::str::contains("schema files are not formatted"));
}
