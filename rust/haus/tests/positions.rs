//! Error positions (test-suite/positions/cases.haus, test-suite/README.md
//! "Error positions", spec §8): each case's text, parsed whole, is rejected
//! with its code at its line and column (1-based, columns in code points).

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
            match haus::parse(text) {
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
