//! The error codes (spec §17): `src/error_codes.rs` is generated from the
//! catalogue, spec/errors.haus, by this test, read with this crate's parser.
//! When the catalogue changes, the test fails; regenerate the file with
//!
//!     HAUS_WRITE_ERROR_CODES=1 cargo test -p haus-fmt --test error_codes
//!
//! The catalogue's examples of syntax errors (`Data`) and of self-describing
//! JSON (`HausJson`) are checked here too; haus-fmt-schema checks the others.

use haus::{ErrorCode, Value};
use std::path::{Path, PathBuf};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

struct Entry {
    code: String,
    category: String,
    means: String,
    example: Value,
    fix: String,
}

fn text<'a>(fields: &'a [(String, Value)], key: &str) -> &'a str {
    match fields.iter().find(|(k, _)| k == key) {
        Some((_, Value::String(s))) => s,
        _ => panic!("spec/errors.haus: an entry has no string {key}"),
    }
}

fn field<'a>(fields: &'a [(String, Value)], key: &str) -> &'a Value {
    fields.iter().find(|(k, _)| k == key).map(|(_, v)| v).unwrap_or_else(|| panic!("no field {key}"))
}

fn catalogue() -> Vec<Entry> {
    let source = std::fs::read_to_string(root().join("spec/errors.haus")).expect("spec/errors.haus");
    haus::parse(&source)
        .expect("spec/errors.haus is haus")
        .into_iter()
        .map(|v| match &v {
            Value::Variant { tag, args } if tag == "Code" => match args.as_slice() {
                [Value::Record(fields)] => Entry {
                    code: text(fields, "code").to_owned(),
                    category: match field(fields, "category") {
                        Value::Variant { tag, .. } => tag.clone(),
                        _ => panic!("a category is a tag"),
                    },
                    means: text(fields, "means").to_owned(),
                    example: field(fields, "example").clone(),
                    fix: text(fields, "fix").to_owned(),
                },
                _ => panic!("every entry is Code {{ … }}"),
            },
            _ => panic!("every entry is Code {{ … }}"),
        })
        .collect()
}

/// `payload-newline` as a Rust name: `PayloadNewline`.
fn variant(code: &str) -> String {
    code.split('-')
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_ascii_uppercase().to_string() + c.as_str()).unwrap_or_default()
        })
        .collect()
}

/// The categories, in the catalogue's order: the tag in errors.haus, and its id.
const CATEGORIES: [(&str, &str); 8] = [
    ("Syntax", "syntax"),
    ("Limits", "limits"),
    ("Streams", "streams"),
    ("SchemaFiles", "schema-files"),
    ("Imports", "imports"),
    ("Decoding", "decoding"),
    ("Json", "json"),
    ("Hints", "hints"),
];

/// A doc comment line: the text, with what rustdoc would read as a link escaped.
fn doc(s: &str) -> String {
    s.replace('[', "\\[").replace(']', "\\]").replace('\n', " ")
}

fn generate(entries: &[Entry]) -> String {
    let mut out = String::new();
    let mut line = |s: &str| {
        out.push_str(s);
        out.push('\n');
    };
    line("// Generated from spec/errors.haus by tests/error_codes.rs. Don't edit: edit spec/errors.haus and run");
    line("// `HAUS_WRITE_ERROR_CODES=1 cargo test -p haus-fmt --test error_codes`.");
    line("");
    line("/// An error code (spec §17): which mistake an error is. Stable, and the same in every binding.");
    line("/// [`ErrorCode::as_str`] is its name, `payload-newline`; [`ErrorCode::hint`] the usual fix.");
    line("#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]");
    line("#[non_exhaustive]");
    line("pub enum ErrorCode {");
    for e in entries {
        line(&format!("    /// `{}`: {}", e.code, doc(&e.means)));
        line(&format!("    {},", variant(&e.code)));
    }
    line("}");
    line("");
    line("/// The category of an error code (spec §17).");
    line("#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]");
    line("#[non_exhaustive]");
    line("pub enum ErrorCategory {");
    for (tag, _) in CATEGORIES {
        line(&format!("    {tag},"));
    }
    line("}");
    line("");
    line("impl ErrorCategory {");
    line("    /// Its id: `schema-files`.");
    line("    pub const fn as_str(self) -> &'static str {");
    line("        match self {");
    for (tag, id) in CATEGORIES {
        line(&format!("            ErrorCategory::{tag} => {id:?},"));
    }
    line("        }");
    line("    }");
    line("}");
    line("");
    line("impl ErrorCode {");
    line("    /// Every code, in the catalogue's order.");
    line(&format!("    pub const ALL: [ErrorCode; {}] = [", entries.len()));
    for e in entries {
        line(&format!("        ErrorCode::{},", variant(&e.code)));
    }
    line("    ];");
    line("");
    line("    /// The code: `payload-newline`.");
    line("    pub const fn as_str(self) -> &'static str {");
    line("        match self {");
    for e in entries {
        line(&format!("            ErrorCode::{} => {:?},", variant(&e.code), e.code));
    }
    line("        }");
    line("    }");
    line("");
    line("    /// Its category.");
    line("    pub const fn category(self) -> ErrorCategory {");
    line("        match self {");
    for e in entries {
        line(&format!("            ErrorCode::{} => ErrorCategory::{},", variant(&e.code), e.category));
    }
    line("        }");
    line("    }");
    line("");
    line("    /// The catalogue's fix: the hint of an error that knows no better one.");
    line("    pub const fn hint(self) -> &'static str {");
    line("        match self {");
    for e in entries {
        line(&format!("            ErrorCode::{} => {:?},", variant(&e.code), e.fix));
    }
    line("        }");
    line("    }");
    line("}");
    out
}

#[test]
fn the_table_is_generated_from_the_catalogue() {
    let entries = catalogue();
    for e in &entries {
        assert!(CATEGORIES.iter().any(|(tag, _)| *tag == e.category), "{}: unknown category {}", e.code, e.category);
    }
    let expected = generate(&entries);
    let file = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/error_codes.rs");
    if std::env::var_os("HAUS_WRITE_ERROR_CODES").is_some() {
        std::fs::write(&file, &expected).expect("write src/error_codes.rs");
    }
    let actual = std::fs::read_to_string(&file).unwrap_or_default();
    assert!(
        actual == expected,
        "src/error_codes.rs is out of date: run HAUS_WRITE_ERROR_CODES=1 cargo test -p haus-fmt --test error_codes"
    );
    let codes: Vec<&str> = ErrorCode::ALL.iter().map(|c| c.as_str()).collect();
    assert_eq!(codes, entries.iter().map(|e| e.code.as_str()).collect::<Vec<_>>());
}

#[test]
fn codes_have_their_names_hints_and_docs() {
    for (code, e) in ErrorCode::ALL.iter().zip(catalogue()) {
        assert_eq!(ErrorCode::from_name(&e.code), Some(*code));
        assert_eq!(code.to_string(), e.code);
        assert_eq!(code.hint(), e.fix);
        assert_eq!(code.docs(), format!("https://haus-fmt.org/docs/errors#{}", e.code));
    }
    assert_eq!(ErrorCode::from_name("no-such-code"), None);
}

/// The catalogue's examples this crate can run: `Data` (haus text) and
/// `HausJson` (self-describing JSON) fail with their entry's code.
#[test]
fn examples_have_their_codes() {
    let mut checked = 0;
    for e in catalogue() {
        let Value::Variant { tag, args } = &e.example else { panic!("{}: an example is a tag", e.code) };
        let [Value::String(input)] = args.as_slice() else { continue };
        let code = match tag.as_str() {
            "Data" => haus::parse(input).err().map(|err| err.code),
            "HausJson" => haus::from_haus_json(input).err().and_then(|err| err.code()),
            _ => continue,
        };
        assert_eq!(code.map(|c| c.as_str()), Some(e.code.as_str()), "{}: {input:?}", e.code);
        checked += 1;
    }
    assert!(checked > 30, "{checked} examples");
}

#[test]
fn the_json_form() {
    let e = haus::parse("Heartbeat\n{ at: 1 }").unwrap_err();
    assert_eq!(
        e.to_json(),
        concat!(
            r#"{"code":"payload-newline","message":"expected ',' between top-level values, found '{'","#,
            r#""line":2,"column":1,"expected":"','","found":"'{'","#,
            r#""hint":"Put the payload on the same line as Heartbeat, or add a comma if they are two values.","#,
            r#""docs":"https://haus-fmt.org/docs/errors#payload-newline"}"#
        )
    );
    let e = haus::from_str::<Vec<i64>>("[1, 2.5]").unwrap_err();
    assert_eq!(
        e.to_json().unwrap(),
        concat!(
            r#"{"code":"not-an-integer","message":"expected a whole number (Int64), found 2.5","path":"$[1]","#,
            r#""expected":"Int64","found":"2.5","#,
            r#""hint":"Write the integer without a fraction or exponent.","#,
            r#""docs":"https://haus-fmt.org/docs/errors#not-an-integer"}"#
        )
    );
}

#[test]
fn messages_name_keys_as_the_path_does() {
    // A key that isn't an identifier is a canonical haus string (spec §12, §15),
    // in the message as in the path: never Rust's debug quoting.
    let e = haus::from_str::<std::collections::BTreeMap<String, i64>>(r#"{ "a\nb\u{7F}": 1.5 }"#).unwrap_err();
    let haus::Error::Decode(e) = e else { panic!("{e}") };
    assert_eq!(e.place(), r#"$["a\nb\u{7F}"]"#);
    assert_eq!(e.to_string(), r#"["a\nb\u{7F}"]: expected a whole number (Int64), found 1.5"#);
}

/// Where one input could be read as several mistakes, the reference
/// (spec/lean/Haus/Parser.lean) decides; these follow it.
#[test]
fn codes_follow_the_reference() {
    let long = "1".repeat(1001);
    let cases: &[(&str, &str)] = &[
        ("Heartbeat\n{ at: 1 }", "payload-newline"),
        ("[A /* c */ (1)]", "payload-newline"),
        ("[A(1)\n(2)]", "missing-comma"),
        ("[1 }", "unexpected-closer"),
        ("{ a: 1 ]", "unexpected-closer"),
        ("1 )", "unexpected-closer"),
        ("[1 2]", "missing-comma"),
        ("+1", "invalid-number"),
        (".5", "invalid-number"),
        ("[1, +2]", "invalid-number"),
        ("null", "null-literal"),
        ("{ a: true }", "boolean-literal"),
        ("false", "boolean-literal"),
        ("nil", "bare-identifier"),
        ("1 /* a\rb */", "lone-carriage-return"),
        ("1\r", "lone-carriage-return"),
        ("\"\\u0041\"", "invalid-unicode-escape"),
        ("\"\\u{110000}\"", "invalid-unicode-escape"),
        ("\"\\q\"", "invalid-escape"),
        (&format!("{long}x"), "invalid-number"),
        (&format!("{long}.5.5"), "invalid-number"),
        (&long, "number-too-long"),
        ("1e6145x", "invalid-number"),
        ("1e6145", "exponent-too-large"),
        ("0x", "invalid-number"),
        ("1.", "invalid-number"),
        ("#haus 2\n1", "version-directive"),
        ("{ A: 1 }", "uppercase-key"),
        ("A()", "empty-payload"),
    ];
    for (text, code) in cases {
        let e = haus::parse(text).expect_err(text);
        assert_eq!(e.code.as_str(), *code, "{text:.40?}: {e}");
    }
    let e = haus::parse("{ A: 1 }").unwrap_err();
    assert_eq!(e.hint(), "Quote the key: \"A\".");
    let e = haus::parse("nil").unwrap_err();
    assert_eq!((e.expected(), e.found()), (Some("a value"), Some("'nil'")));
}
