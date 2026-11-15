//! The format conformance suite (test-suite/format/README.md): every input,
//! formatted in the pretty and the compact layout, must give the expected
//! files byte for byte (they come from the TypeScript reference formatter),
//! and formatting the output again must change nothing.

use haus::{FormatOptions, Limits, MAX_SUPPORTED_DEPTH, Style, Value};
use std::fs;
use std::path::{Path, PathBuf};

fn suite() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite")
}

struct Case {
    name: String,
    input: PathBuf,
    /// NAME.pretty, NAME.compact and NAME.options are here, with these extensions.
    expected: PathBuf,
}

/// The names of the `.haus` files in `dir`, sorted.
fn haus_files(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter_map(|f| f.strip_suffix(".haus").map(str::to_owned))
        .collect();
    names.sort();
    names
}

fn cases() -> Vec<Case> {
    let format = suite().join("format");
    let mut cases = Vec::new();
    for group in ["cases", "examples"] {
        let dir = format.join(group);
        for name in haus_files(&dir) {
            cases.push(Case {
                name: format!("{group}/{name}"),
                input: dir.join(format!("{name}.haus")),
                expected: dir.join(&name),
            });
        }
    }
    for name in haus_files(&suite().join("valid")) {
        cases.push(Case {
            name: format!("valid/{name}"),
            input: suite().join("valid").join(format!("{name}.haus")),
            expected: format.join("valid").join(&name),
        });
    }
    assert!(cases.len() > 50, "too few cases: {}", cases.len());
    cases
}

fn with_extension(path: &Path, ext: &str) -> PathBuf {
    let mut p = path.as_os_str().to_owned();
    p.push(format!(".{ext}"));
    p.into()
}

/// NAME.options: a record `{ indent: 4, width: 40 }`, applied to both layouts.
fn options(case: &Case, style: Style) -> FormatOptions {
    let mut options = FormatOptions { style, ..FormatOptions::default() };
    let Ok(text) = fs::read_to_string(with_extension(&case.expected, "options")) else { return options };
    let values = haus::parse(&text).unwrap();
    let int = |k: &str| match values[0].get(k) {
        Some(Value::Number(n)) => Some(n.parse::<usize>().unwrap()),
        _ => None,
    };
    if let Some(indent) = int("indent") {
        options.indent = indent;
    }
    if let Some(width) = int("width") {
        options.width = width;
    }
    options
}

#[test]
fn suite_cases_are_byte_identical_and_idempotent() {
    let mut failures = Vec::new();
    let mut checked = 0;
    for case in cases() {
        let input = String::from_utf8(fs::read(&case.input).unwrap()).unwrap();
        for (style, ext) in [(Style::Pretty, "pretty"), (Style::Compact, "compact")] {
            let options = options(&case, style);
            let file = with_extension(&case.expected, ext);
            let Ok(expected) = fs::read(&file) else {
                failures.push(format!("{}: {} is missing", case.name, file.display()));
                continue;
            };
            let out = match haus::format(&input, &options) {
                Ok(out) => out,
                Err(e) => {
                    failures.push(format!("{} ({ext}): {e}", case.name));
                    continue;
                }
            };
            if out.as_bytes() != expected {
                failures.push(format!(
                    "{} ({ext}): got\n{out}\nexpected\n{}",
                    case.name,
                    String::from_utf8_lossy(&expected)
                ));
                continue;
            }
            if out.contains('\r') {
                failures.push(format!("{} ({ext}): a carriage return in the output", case.name));
            }
            if haus::format(&out, &options).as_ref() != Ok(&out) {
                failures.push(format!("{} ({ext}): formatting the output again changes it", case.name));
            }
            if haus::parse(&out) != haus::parse(&input) {
                failures.push(format!("{} ({ext}): the output holds other values", case.name));
            }
            checked += 1;
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
    assert!(checked > 100);
}

#[test]
fn errors_are_the_parsers() {
    for text in ["{ a: 1, a: 2 }", "[1, 2", "\"\\q\"", "x\"0\"", "{ a: 1 } { b: 2 }", "Tag\n(1)", "/* open"] {
        assert_eq!(haus::format(text, &FormatOptions::default()), Err(haus::parse(text).unwrap_err()), "{text:?}");
    }
    let limits = Limits { max_depth: MAX_SUPPORTED_DEPTH + 1, ..Limits::default() };
    let e = haus::format("1", &FormatOptions { limits, ..FormatOptions::default() }).unwrap_err();
    assert!(e.reason.contains("supported maximum"), "{e}");
    let limits = Limits { max_depth: 1, ..Limits::default() };
    assert!(haus::format("[[1]]", &FormatOptions { limits, ..FormatOptions::default() }).is_err());
}

#[test]
fn indent_and_width() {
    let text = "{ a: Point(1, 2), b: \"x\\ny\" }";
    let narrow = FormatOptions { indent: 4, width: 12, ..FormatOptions::default() };
    assert_eq!(
        haus::format(text, &narrow).unwrap(),
        "{\n    a: Point(\n        1,\n        2,\n    ),\n    b: \"\"\"\n        x\n        y\n        \"\"\",\n}\n"
    );
    let compact = FormatOptions { style: Style::Compact, indent: 4, width: 12, ..FormatOptions::default() };
    assert_eq!(haus::format(text, &compact).unwrap(), "{ a: Point(1, 2), b: \"x\\ny\" }\n");
}

/// Every kind of nesting, with comments, `MAX_SUPPORTED_DEPTH` levels deep.
fn deep_text(depth: usize) -> String {
    let opens = ["[ // array\n", "{ a: /* key */ ", "Some(", "Tag { b: 1, c: ", "{ \"k\": [1, "];
    let closes = [", 2 ]", " }", ")", " }", "] }"];
    let levels = [1, 1, 1, 1, 2];
    let (mut head, mut tail, mut n, mut i) = (String::new(), String::new(), 0, 0);
    while n + levels[i % 5] <= depth {
        head.push_str(opens[i % 5]);
        tail.insert_str(0, closes[i % 5]);
        n += levels[i % 5];
        i += 1;
    }
    while n < depth {
        head.push('[');
        tail.insert(0, ']');
        n += 1;
    }
    format!("// deep\n{head}\"\"\"\n  a\n  b\n  \"\"\"{tail}, 1,\n")
}

#[test]
fn the_supported_depth_formats_in_a_small_thread() {
    std::thread::Builder::new()
        .stack_size(2 * 1024 * 1024)
        .spawn(|| {
            let text = deep_text(MAX_SUPPORTED_DEPTH);
            let values = haus::parse(&text).unwrap();
            for style in [Style::Pretty, Style::Compact] {
                let options = FormatOptions { style, ..FormatOptions::default() };
                let out = haus::format(&text, &options).unwrap();
                assert_eq!(haus::format(&out, &options).unwrap(), out);
                assert_eq!(haus::parse(&out).unwrap(), values);
                if style == Style::Pretty {
                    assert_eq!(out.matches("// array").count(), text.matches("// array").count());
                }
            }
            // One level more is the parser's error.
            let e = haus::format(&deep_text(MAX_SUPPORTED_DEPTH + 1), &FormatOptions::default()).unwrap_err();
            assert!(e.reason.starts_with("nesting deeper than"), "{e}");
        })
        .unwrap()
        .join()
        .unwrap();
}
