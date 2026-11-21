//! Error positions (test-suite/positions/cases.haus, test-suite/README.md
//! "Error positions", spec §8): each case's text, parsed whole, is rejected
//! with its code at its line and column (1-based, columns in code points). A
//! case with `document: True` is read as a single document ([`haus::parse_one`]).

use haus::{Value, canonical};
use std::path::{Path, PathBuf};

#[test]
fn error_positions() {
    // `HAUS_SUITE` names another directory holding the suite.
    let path = std::env::var_os("HAUS_SUITE")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite"))
        .join("positions/cases.haus");
    let cases = haus::parse(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(!cases.is_empty(), "no cases in {}", path.display());
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|c| {
            let (
                Some(Value::String(text)),
                Some(Value::String(code)),
                Some(Value::Number(line)),
                Some(Value::Number(column)),
            ) = (c.get("text"), c.get("code"), c.get("line"), c.get("column"))
            else {
                panic!("not a case: {}", canonical(c))
            };
            let want = format!("{code} at {line}:{column}");
            let document = matches!(c.get("document"), Some(Value::Variant { tag, .. }) if tag == "True");
            let parsed = match document {
                true => haus::parse_one(text).map(|v| vec![v]),
                false => haus::parse(text),
            };
            match parsed {
                Ok(values) => Some(format!("{text:?}: accepted as {values:?}, expected {want}")),
                Err(e) => {
                    let got = format!("{} at {}:{}", e.code, e.line, e.column);
                    (got != want).then(|| format!("{text:?}: {got} ({e}), expected {want}"))
                }
            }
        })
        .collect();
    assert!(failures.is_empty(), "{} of {} cases failed:\n{}", failures.len(), cases.len(), failures.join("\n"));
}

/// `block-string-opening` is at the first character after the opening `"""` and its blanks, or
/// at the end of the input when nothing follows (spec §8; the suite has no case for it yet).
#[test]
fn block_string_opening_is_after_the_quotes() {
    for (text, want) in [
        ("\"\"\"", (1, 4)),
        ("\"\"\"x", (1, 4)),
        ("\"\"\"  x", (1, 6)),
        ("[\"\"\"", (1, 5)),
        ("\"\"\"  ", (1, 6)),
        ("\"\"\"\r", (1, 4)),
    ] {
        let e = haus::parse(text).unwrap_err();
        assert_eq!((e.code.to_string(), (e.line, e.column)), ("block-string-opening".to_owned(), want), "{text:?}");
    }
}
