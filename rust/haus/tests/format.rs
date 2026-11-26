//! The format conformance suite (test-suite/format/README.md): every input,
//! formatted in the pretty, compact and minimised layouts, must give the
//! expected files byte for byte (they come from the TypeScript reference
//! formatter), and formatting the output again must change nothing.

use haus::{FormatOptions, Limits, MAX_SUPPORTED_DEPTH, Style, Value};
use std::fs;
use std::path::{Path, PathBuf};

/// The suite; `HAUS_SUITE` names another directory holding it.
fn suite() -> PathBuf {
    std::env::var_os("HAUS_SUITE")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite"))
}

struct Case {
    name: String,
    input: PathBuf,
    /// NAME.pretty, NAME.compact, NAME.minimised and NAME.options are here, with these extensions.
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

/// An option that is `True` (`stream: True`); unset or `False` is false.
fn is_true(v: Option<&Value>) -> bool {
    match v {
        None => false,
        Some(Value::Variant { tag, args }) if args.is_empty() && (tag == "True" || tag == "False") => tag == "True",
        Some(v) => panic!("not True or False: {}", haus::canonical(v)),
    }
}

/// NAME.options: a record `{ indent: 4, width: 40 }` or `{ stream: True }`, applied to every layout.
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
    options.stream = is_true(values[0].get("stream"));
    options
}

const LAYOUTS: [(Style, &str); 3] =
    [(Style::Pretty, "pretty"), (Style::Compact, "compact"), (Style::Minimised, "minimised")];

#[test]
fn suite_cases_are_byte_identical_and_idempotent() {
    let mut failures = Vec::new();
    let mut checked = 0;
    for case in cases() {
        let input = String::from_utf8(fs::read(&case.input).unwrap()).unwrap();
        for (style, ext) in LAYOUTS {
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
    assert!(checked > 150);
}

fn format(text: &str, style: Style) -> String {
    haus::format(text, &FormatOptions { style, ..FormatOptions::default() }).unwrap()
}

/// `text` with the spaces and tabs at the end of every line removed, as an
/// editor that trims trailing whitespace would save it.
fn trim_lines(text: &str) -> String {
    text.split('\n').map(|line| line.trim_end_matches([' ', '\t'])).collect::<Vec<_>>().join("\n")
}

/// The pretty output of `text` survives an editor that trims trailing
/// whitespace: it parses to the same values afterwards. Without comments
/// (whose text is kept as written), no line ends in a space or tab at all.
fn check_trimmed(name: &str, text: &str, failures: &mut Vec<String>) {
    let values = haus::parse(text).unwrap();
    let pretty = format(text, Style::Pretty);
    if haus::parse(&trim_lines(&pretty)).as_ref() != Ok(&values) {
        failures.push(format!("{name}: trimming the pretty output changes its values:\n{pretty}"));
    }
    let uncommented = format(&format(text, Style::Compact), Style::Pretty);
    if let Some(line) = uncommented.lines().find(|l| l.ends_with([' ', '\t'])) {
        failures.push(format!("{name}: a line of the pretty output ends in a blank: {line:?}"));
    }
}

#[test]
fn pretty_output_survives_trimming_trailing_whitespace() {
    let mut failures = Vec::new();
    for case in cases() {
        let input = String::from_utf8(fs::read(&case.input).unwrap()).unwrap();
        check_trimmed(&case.name, &input, &mut failures);
    }
    for (i, s) in strings_with_blanks().into_iter().enumerate() {
        let note = Value::variant("Note", vec![Value::String(s.clone())]).unwrap();
        let value = Value::record([("s", Value::String(s.clone())), ("nested", Value::Array(vec![note]))]).unwrap();
        // From a value (written compact, so every string is a `"…"` string) ...
        check_trimmed(&format!("generated {i} {s:?}"), &haus::to_string(&value).unwrap(), &mut failures);
        // ... and from a block string whose source lines end in blanks.
        if !s.contains(['\r', '\\', '"']) && s.contains('\n') {
            let block = format!(
                "{{ s: \"\"\"\n{}\n  \"\"\" }}",
                s.split('\n').map(|l| format!("  {l}")).collect::<Vec<_>>().join("\n")
            );
            check_trimmed(&format!("block {i} {s:?}"), &block, &mut failures);
        }
    }
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

/// Multi-line strings with spaces and tabs at the ends of lines, in lines of
/// only blanks, and next to escapes: every combination of a few pieces, and
/// some longer ones from a fixed pseudo-random sequence.
fn strings_with_blanks() -> Vec<String> {
    let pieces = ["a", " ", "\t", "\n", "  ", "\"\"\"", "\\", "\r", "\u{2028}", "x y"];
    let mut out = vec![
        "end \nof line".to_owned(),
        "  \nonly spaces above".to_owned(),
        "tab\t\nat the end".to_owned(),
        "\t\nonly a tab above".to_owned(),
        "two  \t \n\t \n \t".to_owned(),
        "\n \n".to_owned(),
    ];
    for a in pieces {
        for b in pieces {
            for c in pieces {
                out.push(format!("{a}{b}\n{c}"));
            }
        }
    }
    let mut seed: u64 = 0x2545_F491_4F6C_DD1D;
    for _ in 0..200 {
        let mut s = String::new();
        for _ in 0..12 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            s.push_str(pieces[(seed % pieces.len() as u64) as usize]);
        }
        out.push(s);
    }
    out
}

#[test]
fn block_strings_never_end_a_line_in_a_blank() {
    let text = "{ s: \"end \\n  \\n\\t\\nx\\t\\n  a b  \\nlast\" }";
    assert_eq!(
        format(text, Style::Pretty),
        "{\n  s: \"\"\"\n    end\\u{20}\n     \\u{20}\n    \\t\n    x\\t\n      a b \\u{20}\n    last\n    \"\"\",\n}\n"
    );
    // A source block string whose lines end in blanks is rewritten with the escapes.
    let block = "{ s: \"\"\"\n  a \n  \t\n  b\n  \"\"\" }";
    let pretty = format(block, Style::Pretty);
    assert_eq!(pretty, "{\n  s: \"\"\"\n    a\\u{20}\n    \\t\n    b\n    \"\"\",\n}\n");
    assert_eq!(haus::parse(&pretty), haus::parse(block));
    // Only the last blank: the others stay raw. Escapes and quotes as before.
    assert_eq!(
        format("\"a\\t \\t\\n\\\"\\\"\\\" \\r\"", Style::Pretty),
        "\"\"\"\n  a\t \\t\n  \\\"\"\" \\r\n  \"\"\"\n"
    );
}

#[test]
fn line_and_paragraph_separators_are_escaped_in_every_layout() {
    // Raw in a string, a block string and a key; escapes stay escapes.
    let text = "{ \"k\u{2028}\": \"a\u{2028}b\u{2029}\", b: \"\"\"\n  x\u{2029}\n  y\n  \"\"\", e: \"\\u{2028}\" }";
    for (style, _) in LAYOUTS {
        let out = format(text, style);
        assert!(!out.contains(['\u{2028}', '\u{2029}']), "{style:?}: {out}");
        assert_eq!(haus::parse(&out), haus::parse(text), "{style:?}");
    }
    assert_eq!(
        format(text, Style::Minimised),
        "{\"k\\u{2028}\":\"a\\u{2028}b\\u{2029}\",b:\"x\\u{2029}\\ny\",e:\"\\u{2028}\"}\n"
    );
    let value = Value::String("a\u{2028}b\u{2029}".into());
    assert_eq!(haus::to_string(&value).unwrap(), "\"a\\u{2028}b\\u{2029}\"");
}

#[test]
fn minimised_keeps_spellings_and_drops_comments() {
    let text = "// head\n{ n: 1_000, h: 0xfF, b: x\"9f86 d081\", /* c */ s: \"\\u{41}\", \"k y\": Tag { a: [1, 2] }, p: P(1, \"x\") }, // after\n\n[1], // tail\n";
    assert_eq!(
        format(text, Style::Minimised),
        "{n:1_000,h:0xfF,b:x\"9f86 d081\",s:\"\\u{41}\",\"k y\":Tag{a:[1,2]},p:P(1,\"x\")},\n[1],\n"
    );
    assert_eq!(format("1", Style::Minimised), "1\n");
    assert_eq!(format("// only a comment\n", Style::Minimised), "");
}

#[test]
fn minimised_then_pretty_is_pretty_without_comments() {
    for case in cases() {
        let input = String::from_utf8(fs::read(&case.input).unwrap()).unwrap();
        let minimised = format(&input, Style::Minimised);
        let compact = format(&input, Style::Compact);
        let pretty = format(&minimised, Style::Pretty);
        assert_eq!(pretty, format(&compact, Style::Pretty), "{}", case.name);
        assert_eq!(format(&pretty, Style::Minimised), minimised, "{}", case.name);
        assert!(!haus::has_comments(&minimised, &Limits::default()).unwrap(), "{}", case.name);
        assert!(!haus::has_comments(&pretty, &Limits::default()).unwrap(), "{}", case.name);
    }
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

/// test-suite/format/options.cases.haus: the pretty layout with the case's
/// `indent` and `width` (the default where not given) gives `Ok(text)`. The
/// options are `usize`, so a negative one (a `Rejected` case) can't be
/// expressed: rejected by the types, and the case passes.
#[test]
fn format_options() {
    let path = suite().join("format/options.cases.haus");
    let cases = haus::parse(&fs::read_to_string(&path).unwrap()).unwrap();
    assert!(!cases.is_empty(), "no cases in {}", path.display());
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let (Some(Value::String(input)), Some(result)) = (c.get("input"), c.get("result")) else {
                panic!("not a case: {}", haus::canonical(c))
            };
            // None: a negative number, which `usize` can't hold.
            let option = |key: &str| match c.get(key) {
                Some(Value::Number(n)) => n.parse::<usize>().ok().map(Some),
                None => Some(None),
                _ => panic!("not a case: {}", haus::canonical(c)),
            };
            let (indent, width) = (option("indent"), option("width"));
            let expected = match result {
                Value::Variant { tag, args } if tag == "Ok" => match args.as_slice() {
                    [Value::String(text)] => Some(text),
                    _ => panic!("not a case: {}", haus::canonical(c)),
                },
                Value::Variant { tag, args } if tag == "Rejected" && args.is_empty() => None,
                _ => panic!("not a case: {}", haus::canonical(c)),
            };
            let (Some(indent), Some(width)) = (indent, width) else {
                // Not expressible with these types: passes if it is to be rejected.
                return expected.map(|_| format!("{}: options a usize can't hold", haus::canonical(c)));
            };
            let defaults = FormatOptions::default();
            let options = FormatOptions {
                indent: indent.unwrap_or(defaults.indent),
                width: width.unwrap_or(defaults.width),
                stream: is_true(c.get("stream")),
                ..defaults
            };
            match (haus::format(input, &options), expected) {
                (Ok(out), Some(text)) if &out == text => None,
                (Ok(out), Some(text)) => Some(format!("{input:?} {options:?}: got {out:?}, expected {text:?}")),
                (Err(e), Some(_)) => Some(format!("{input:?} {options:?}: {e}")),
                (got, None) => Some(format!("{input:?} {options:?}: {got:?}, expected it to be rejected")),
            }
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
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

/// Formats text at the supported depth in a thread with a stack of `kib` KiB.
fn format_at_the_supported_depth(kib: usize) {
    std::thread::Builder::new()
        .stack_size(kib * 1024)
        .spawn(|| {
            let text = deep_text(MAX_SUPPORTED_DEPTH);
            let values = haus::parse(&text).unwrap();
            for (style, _) in LAYOUTS {
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

#[test]
fn the_supported_depth_formats_in_a_small_thread() {
    format_at_the_supported_depth(2 * 1024);
}

/// In a 512 KiB thread (spec §7), in an optimized build: a debug build's
/// parser needs more at 256 levels (see tests/limits.rs).
#[test]
#[cfg_attr(debug_assertions, ignore = "a debug build needs more than 512 KiB at 256 levels: run with --release")]
fn the_supported_depth_formats_in_a_512_kib_thread() {
    format_at_the_supported_depth(512);
}
