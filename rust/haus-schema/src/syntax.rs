//! One schema file (`.schema.haus`): syntax tree and parser, following
//! spec/grammar.ebnf. Parsing builds the tree; `check` then reports what
//! the grammar allows but the spec doesn't (duplicates, `closed < >`,
//! attributes with the wrong arguments), and `expand` copies spread types
//! in (`< ...UserEvent | Ping >`), so the generators and the resolver only
//! ever see plain records and variants.
//!
//! What needs other files (names, arities, imports) is checked by
//! [`Schema`](crate::Schema), and by the code generators of haus-fmt-build.

use crate::packages::is_package_name;
use crate::quote;
use haus::{ErrorCode as Code, Value};
use std::collections::{HashMap, HashSet};
use std::fmt;
use winnow::ascii::{multispace1, till_line_ending};
use winnow::combinator::{alt, cut_err, delimited, eof, fail, not, opt, peek, preceded, repeat, separated, terminated};
use winnow::error::{ContextError, ErrMode, ModalResult, StrContext, StrContextValue};
use winnow::prelude::*;
use winnow::stream::{LocatingSlice, Location};
use winnow::token::{any, literal, none_of, one_of, take_while};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    /// Which mistake it is (spec §17).
    pub code: Code,
    pub reason: String,
    pub line: usize,
    pub column: usize,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}: {}", self.line, self.column, self.reason)
    }
}

impl std::error::Error for Error {}

/// Why the version in a package import (`@haus-fmt/money@1.1`) isn't a major
/// version, `@N` without leading zeros (spec §13.3); None if it is one, or
/// the import names none.
pub fn import_version(module: &str) -> Option<String> {
    let (name, version) = module.strip_prefix('@')?.split_once('@')?;
    let digits = version.find(|c: char| !c.is_ascii_digit()).map_or(version, |end| &version[..end]);
    let major = digits.trim_start_matches('0');
    let major = if major.is_empty() { "0" } else { major };
    let rest = &version[digits.len()..];
    // Quoted as messages quote text from files (spec §9): at most 40 characters.
    let (shown, like) = (quote(module), |major: &str| quote(&format!("@{name}@{major}")));
    if digits.is_empty() || !(rest.is_empty() || rest.starts_with('.')) {
        Some(format!("{shown}: expected a major version after '@', like {}", like("1")))
    } else if !rest.is_empty() {
        Some(format!("{shown}: an import names only the major version ({})", like(major)))
    } else if digits.len() != major.len() {
        Some(format!("{shown}: a major version has no leading zeros ({})", like(major)))
    } else {
        None
    }
}

/// The package a package import names, without its `@major`: `@haus-fmt/money` for `@haus-fmt/money@1`.
pub fn package(module: &str) -> &str {
    match module.get(1..).and_then(|m| m.find('@')) {
        Some(at) => &module[..at + 1],
        None => module,
    }
}

/// The hint for an [`import_version`] error (None for other errors).
pub fn import_version_hint(reason: &str) -> Option<&'static str> {
    if reason.contains("an import names only the major version") {
        Some(
            "An import names only the major version (`@1`); the minimum minor goes in your package manager's dependency range.",
        )
    } else if reason.contains("a major version has no leading zeros") {
        Some("Write the major version without leading zeros (`@1`).")
    } else if reason.contains("expected a major version after '@'") {
        Some("An import names only the major version (`@1`), or none.")
    } else {
        None
    }
}

/// An error at byte offset `pos` of `text`.
pub fn error(text: &str, pos: usize, code: Code, reason: impl Into<String>) -> Error {
    let before = &text[..pos.min(text.len())];
    let line = before.matches('\n').count() + 1;
    let column = before.rsplit('\n').next().map_or(0, |l| l.chars().count()) + 1;
    Error { code, reason: reason.into(), line, column }
}

// ── syntax tree ──────────────────────────────────────────────

/// The prelude (spec §14): built-in types and their number of parameters.
/// A schema can't redefine them.
pub const PRELUDE: &[(&str, usize)] = &[
    ("Bool", 0),
    ("Maybe", 1),
    ("Result", 2),
    ("String", 0),
    ("Bytes", 0),
    ("Array", 1),
    ("Map", 1),
    ("Int", 0),
    ("Int8", 0),
    ("Int16", 0),
    ("Int32", 0),
    ("Int64", 0),
    ("UInt8", 0),
    ("UInt16", 0),
    ("UInt32", 0),
    ("UInt64", 0),
    ("Float32", 0),
    ("Float64", 0),
    ("Decimal", 0),
    ("Any", 0),
    ("Secret", 1),
    ("Stream", 1),
];

/// The types of std/time (spec §13.2), the only standard module.
pub const STD_TIME: [&str; 8] =
    ["Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone"];

/// `unknown type Money`, with how to import it if it's a well-known type.
pub fn unknown_type(name: &str) -> String {
    match name {
        "Money" | "Currency" => format!(
            "unknown type {name} (import it with: import @haus-fmt/money ({name}), and install @haus-fmt/money with your package manager)"
        ),
        "LatLng" | "BBox" => format!(
            "unknown type {name} (import it with: import @haus-fmt/geo ({name}), and install @haus-fmt/geo with your package manager)"
        ),
        _ if STD_TIME.contains(&name) => format!("unknown type {name} (import it with: import std/time ({name}))"),
        _ => format!("unknown type {name}"),
    }
}

#[derive(Debug, Clone)]
pub struct File {
    pub imports: Vec<Import>,
    pub types: Vec<TypeDef>,
    /// What is allowed but probably not meant: unknown attributes, uses of deprecated types.
    pub warnings: Vec<Error>,
}

#[derive(Debug, Clone)]
pub struct Import {
    pub module: String,
    pub names: Vec<(String, usize)>,
    pub pos: usize,
}

#[derive(Debug, Clone)]
pub struct TypeDef {
    pub name: String,
    pub params: Vec<String>,
    pub ty: Ty,
    pub pos: usize,
    /// The `//` lines directly above.
    pub doc: String,
    pub attrs: Vec<Attribute>,
}

/// `@deprecated("use email")`: information for tools, never for decoding (spec §14).
#[derive(Debug, Clone)]
pub struct Attribute {
    pub name: String,
    /// The arguments (none without parentheses), or what is wrong with them.
    pub args: Result<Vec<Value>, Fail>,
    pub pos: usize,
}

/// The attributes this version of haus defines (spec §14).
const DEFINED_ATTRIBUTES: &[&str] = &["deprecated"];

/// Whether `attrs` mark something deprecated, and the message if there is one.
pub fn deprecation(attrs: &[Attribute]) -> Option<Option<&str>> {
    attrs.iter().find(|a| a.name == "deprecated").map(|a| match a.args.as_deref() {
        Ok([Value::String(why)]) => Some(why.as_str()),
        _ => None,
    })
}

#[derive(Debug, Clone)]
pub enum Ty {
    /// A named type, applied to arguments: `Array Point`, `Int`.
    Name { name: String, args: Vec<Ty>, pos: usize },
    /// A type parameter: `a`.
    Param { name: String, pos: usize },
    Record {
        closed: bool,
        fields: Vec<Field>,
        /// `...Name`; once the file is expanded, only spreads of imported
        /// types, kept by [`parse_with_imported_spreads`].
        spreads: Vec<Spread>,
        pos: usize,
    },
    Variant {
        closed: bool,
        cases: Vec<Case>,
        /// `...Name`; once the file is expanded, only spreads of imported
        /// types, kept by [`parse_with_imported_spreads`].
        spreads: Vec<Spread>,
        pos: usize,
    },
}

/// `...Name`: the fields or tags of the named type, copied in where it is
/// written. `at` is how many own fields or cases come before it (after
/// expanding, how many fields or cases, the copied ones included).
#[derive(Debug, Clone)]
pub struct Spread {
    pub name: String,
    pub at: usize,
    pub pos: usize,
    /// Attributes written before it, which `check` rejects.
    pub attrs: Vec<Attribute>,
}

impl Ty {
    pub fn pos(&self) -> usize {
        match self {
            Ty::Name { pos, .. } | Ty::Param { pos, .. } | Ty::Record { pos, .. } | Ty::Variant { pos, .. } => *pos,
        }
    }
}

/// As written in a schema, for messages: `Array (Maybe Int)`, `{ … }`.
impl fmt::Display for Ty {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Ty::Name { name, args, .. } => {
                f.write_str(name)?;
                args.iter().try_for_each(|a| match a {
                    Ty::Name { args, .. } if !args.is_empty() => write!(f, " ({a})"),
                    _ => write!(f, " {a}"),
                })
            }
            Ty::Param { name, .. } => f.write_str(name),
            Ty::Record { closed, .. } => f.write_str(if *closed { "closed { … }" } else { "{ … }" }),
            Ty::Variant { closed, .. } => f.write_str(if *closed { "closed < … >" } else { "< … >" }),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Field {
    pub key: String,
    pub optional: bool,
    pub ty: Ty,
    pub pos: usize,
    pub attrs: Vec<Attribute>,
}

#[derive(Debug, Clone)]
pub struct Case {
    pub tag: String,
    /// `Tag A B`: positional; `Tag { … }`: one record.
    pub payload: Vec<Ty>,
    pub pos: usize,
    pub attrs: Vec<Attribute>,
}

/// Parse and check a schema file.
pub fn parse(text: &str) -> Result<File, Error> {
    parse_file(text, false)
}

/// [`parse`], but spreads of imported types (`< ...UserEvent >` with
/// `UserEvent` imported) are left in `spreads`, after the file's own fields
/// or tags, for [`Schema`](crate::Schema), which loads the imported files.
pub fn parse_with_imported_spreads(text: &str) -> Result<File, Error> {
    parse_file(text, true)
}

fn parse_file(text: &str, imported_spreads: bool) -> Result<File, Error> {
    // The first mistake of the file, read from its start: a lexical one (or
    // types nested too deep) only if the grammar has no complaint before it.
    // So the text is parsed up to it, never past it; types nested too deep
    // aren't parsed at all, which would take as deep a stack.
    let lexical = lexis(text).err();
    if let Some((pos, Code::TypeTooDeep, reason)) = lexical {
        return Err(error(text, pos, Code::TypeTooDeep, reason));
    }
    let upto = lexical.as_ref().map_or(text.len(), |(pos, _, _)| *pos);
    let file = file.parse(LocatingSlice::new(&text[..upto])).map_err(|e| {
        let expected = e.inner().context().find_map(|c| match c {
            StrContext::Expected(StrContextValue::Description(d)) => Some(d.to_string()),
            StrContext::Expected(StrContextValue::StringLiteral(s)) => Some(format!("'{s}'")),
            _ => None,
        });
        // Reached the lexical mistake (attribute arguments without their `)`
        // are one, which `lexis` describes).
        // Whatever follows `...` without a name, a comment too, is the spread's mistake (§14).
        let spread = expected.as_deref() == Some(SPREAD_ONE_WORD);
        if let Some((pos, code, reason)) = &lexical
            && (e.offset() > *pos || (e.offset() == *pos && !spread) || expected.as_deref() == Some(ATTRIBUTE_CLOSE))
        {
            return error(text, *pos, *code, reason.clone());
        }
        let rest = &text[e.offset()..];
        // A '/' that doesn't start a comment, where whitespace may be: as in data (§14).
        if rest.starts_with('/') && !spread {
            return error(text, e.offset(), Code::StraySlash, "unexpected '/' (comments are // or /* */)");
        }
        let found = found(rest);
        let code = expected.as_deref().map_or(Code::SchemaSyntax, syntax_code);
        error(
            text,
            e.offset(),
            code,
            expected.map_or_else(|| format!("unexpected {found}"), |what| format!("expected {what}, found {found}")),
        )
    })?;
    if let Some((pos, code, reason)) = lexical {
        return Err(error(text, pos, code, reason));
    }
    let at = |(pos, code, reason): Fail| error(text, pos, code, reason);
    let mut warnings = check(&file).map_err(at)?;
    // Before spreads are copied in, so each use is reported once, where it is written.
    warnings.extend(deprecated_uses(&file));
    let file = expand(file, imported_spreads).map_err(at)?;
    guarded(&file).map_err(at)?;
    warnings.sort_by_key(|(pos, _, _)| *pos);
    let types = file
        .types
        .into_iter()
        .map(|d| TypeDef { doc: doc_comment(text, d.attrs.first().map_or(d.pos, |a| a.pos)), ..d })
        .collect();
    Ok(File { types, warnings: warnings.into_iter().map(at).collect(), ..file })
}

/// The same file without its attributes: they never change decoding (spec §15).
pub fn without_attributes(file: File) -> File {
    fn ty(t: &mut Ty) {
        match t {
            Ty::Name { args, .. } => args.iter_mut().for_each(ty),
            Ty::Param { .. } => {}
            Ty::Record { fields, .. } => fields.iter_mut().for_each(|f| {
                f.attrs.clear();
                ty(&mut f.ty);
            }),
            Ty::Variant { cases, .. } => cases.iter_mut().for_each(|c| {
                c.attrs.clear();
                c.payload.iter_mut().for_each(ty);
            }),
        }
    }
    let types = file
        .types
        .into_iter()
        .map(|mut d| {
            d.attrs.clear();
            ty(&mut d.ty);
            d
        })
        .collect();
    File { types, warnings: vec![], ..file }
}

/// The code of a syntax error, by what was expected there (spec §17).
fn syntax_code(expected: &str) -> Code {
    match expected {
        COMMENT_END => Code::UnterminatedComment,
        STRING_END => Code::UnterminatedString,
        ATTRIBUTE_CLOSE => Code::UnclosedBracket,
        ATTRIBUTE_PAREN => Code::AttributeSpace,
        _ => Code::SchemaSyntax,
    }
}

const COMMENT_END: &str = "*/ closing the comment";
const STRING_END: &str = "'\"' closing the string";
const ATTRIBUTE_CLOSE: &str = "')' closing the attribute's arguments";
const ATTRIBUTE_PAREN: &str = "'(' right after the attribute's name, without a space";
const SPREAD_ONE_WORD: &str = "the type name right after '...' (...Name is one word)";

/// What the parser stopped at, for messages.
fn found(rest: &str) -> String {
    let word = rest.bytes().take_while(|b| b.is_ascii_alphanumeric() || *b == b'_').count();
    match rest.chars().next() {
        None => "end of file".into(),
        Some(_) if word > 0 => format!("'{}'", quote(&rest[..word])),
        Some(c) if c.is_ascii() => format!("{c:?}"),
        Some(c) => format!("'{}'", quote(&c.to_string())),
    }
}

// ── grammar ──────────────────────────────────────────────────

type Input<'a> = LocatingSlice<&'a str>;
type E = ErrMode<ContextError>;

const KEYWORDS: [&str; 3] = ["type", "import", "closed"];

fn expected(what: &'static str) -> StrContext {
    StrContext::Expected(StrContextValue::Description(what))
}

/// Whitespace and comments (`//`, nested `/* */`).
fn ws(i: &mut Input) -> ModalResult<()> {
    repeat(0.., alt((multispace1.void(), ("//", till_line_ending).void(), block_comment))).parse_next(i)
}

fn block_comment(i: &mut Input) -> ModalResult<()> {
    let inner = alt((block_comment, (not(alt(("/*", "*/"))), any).void()));
    ("/*", cut_err((repeat(0.., inner).map(|()| ()), "*/").context(expected(COMMENT_END)))).void().parse_next(i)
}

/// `p`, then whitespace.
fn token<'a, O>(p: impl Parser<Input<'a>, O, E>) -> impl Parser<Input<'a>, O, E> {
    terminated(p, ws)
}

fn sym<'a>(s: &'static str) -> impl Parser<Input<'a>, &'a str, E> {
    token(literal(s)).context(StrContext::Expected(StrContextValue::StringLiteral(s)))
}

fn keyword<'a>(w: &'static str) -> impl Parser<Input<'a>, (), E> {
    token(terminated(literal(w), not(one_of(|c: char| c.is_ascii_alphanumeric() || c == '_')))).void()
}

fn pos(i: &mut Input) -> ModalResult<usize> {
    Ok(i.current_token_start())
}

fn word<'a>(first: fn(char) -> bool) -> impl Parser<Input<'a>, String, E> {
    token((one_of(first), take_while(0.., |c: char| c.is_ascii_alphanumeric() || c == '_')).take().map(str::to_owned))
}

/// A type name or tag: `Money`.
fn upper(i: &mut Input) -> ModalResult<String> {
    word(|c| c.is_ascii_uppercase()).context(expected("a type name")).parse_next(i)
}

/// A lower-case word, keywords included (record keys may be `type`).
fn lower(i: &mut Input) -> ModalResult<String> {
    word(|c| c.is_ascii_lowercase() || c == '_').parse_next(i)
}

/// A type parameter: a lower-case word that isn't a keyword. One starting
/// with `_` is read too, for [`check`] to say what is wrong with it.
fn param(i: &mut Input) -> ModalResult<String> {
    lower.verify(|w: &String| !KEYWORDS.contains(&w.as_str())).context(expected("a type parameter")).parse_next(i)
}

/// A `"…"` string, with the escapes of data strings (spec §4): [`lexis`]
/// has checked it, and the data parser reads it.
fn string(i: &mut Input) -> ModalResult<String> {
    let escape = ('\\', any).void();
    let raw = ('"', repeat::<_, _, (), _, _>(0.., alt((none_of(['"', '\\', '\n']).void(), escape))), cut_err('"'))
        .take()
        .context(expected(STRING_END));
    token(raw)
        .map(|raw: &str| match haus::parse(raw).as_deref() {
            Ok([Value::String(s)]) => s.clone(),
            _ => raw.to_owned(),
        })
        .parse_next(i)
}

/// The deepest nesting of parentheses, records and variants in a type (as in every binding).
const MAX_TYPE_NESTING: usize = 128;

/// Comments, whitespace and `"…"` strings are those of data files (spec
/// §14): each run of whitespace and comments, and each string, is read by
/// the data parser, so their mistakes have the codes they have there
/// (`lone-carriage-return`, `control-character`, `bidi-control`,
/// `invalid-escape`, `unterminated-string`, …). The arguments of attributes
/// are data values, read by it later; anything else is left to the grammar.
/// It also counts how deep types nest (`type-too-deep`), and reports
/// attribute arguments without their `)`.
///
/// Everything it looks for is ASCII, and in UTF-8 an ASCII byte is never part
/// of another character, so it scans bytes and slices only at ASCII.
fn lexis(text: &str) -> Result<(), Fail> {
    let b = text.as_bytes();
    let data = |start: usize, end: usize| -> Result<(), Fail> {
        haus::parse(&text[start..end]).map(|_| ()).map_err(|e| (start + e.offset, e.code, e.reason))
    };
    let mut i = if text.starts_with('\u{feff}') { 3 } else { 0 };
    // Parentheses, records and variants nest within a type (type-too-deep).
    let mut depth = 0usize;
    while let Some(&c) = b.get(i) {
        let rest = &b[i..];
        i = match c {
            b' ' | b'\t' | b'\n' | b'\r' => trivia(b, i, &data)?,
            b'(' | b'{' | b'<' => {
                depth += 1;
                if depth > MAX_TYPE_NESTING {
                    return Err((i, Code::TypeTooDeep, format!("types nested deeper than {MAX_TYPE_NESTING} levels")));
                }
                i + 1
            }
            b')' | b'}' | b'>' => {
                depth = depth.saturating_sub(1);
                i + 1
            }
            b'/' if rest.starts_with(b"//") || rest.starts_with(b"/*") => trivia(b, i, &data)?,
            // Only in the arguments of attributes, where the data parser reads them.
            b'"' if rest.starts_with(b"\"\"\"") => return Ok(()),
            b'"' => {
                let end = after_string(b, i + 1);
                data(i, end)?;
                end
            }
            b'@' => {
                let name = i + 1 + rest[1..].iter().take_while(|c| c.is_ascii_alphanumeric() || **c == b'_').count();
                match b.get(name) {
                    Some(b'(') => match closing_paren(&text[name..]) {
                        Some(close) => name + close + 1,
                        None => return Err(unclosed_arguments(text, &text[i + 1..name], name)),
                    },
                    _ => name,
                }
            }
            _ => i + 1,
        };
    }
    Ok(())
}

/// The error of attribute arguments whose `(` at `open` has no `)`: what
/// reading them value by value finds first, as for any arguments. A value
/// that isn't one is the data parser's error; after the last value, a comma
/// or nothing means the `(` is unclosed, anything else that a `,` or `)` is
/// missing.
fn unclosed_arguments(text: &str, attribute: &str, open: usize) -> Fail {
    let inner = &text[open + 1..];
    match arguments(inner) {
        Err(e) => (open + e.offset, e.code, format!("in the arguments of @{attribute}: {}", e.reason)),
        Ok(values) if values.is_empty() || inner.trim_end().ends_with(',') => {
            (open, Code::UnclosedBracket, format!("unclosed '(' of @{attribute}"))
        }
        Ok(_) => (text.len(), Code::MissingComma, format!("expected ',' or ')' in the arguments of @{attribute}")),
    }
}

/// The values of attribute arguments: `inner`, the text after their `(`.
/// They don't start the file, so a byte order mark at their start is a
/// mistake, as after a comma, and `#haus` no version directive. They are
/// parsed after a space that stands for the `(`: an error's offset is from
/// the `(`.
fn arguments(inner: &str) -> Result<Vec<Value>, haus::SyntaxError> {
    haus::parse(&format!(" {inner}"))
}

/// After the run of whitespace and comments at `i`, which `data` has checked.
fn trivia(b: &[u8], start: usize, data: &impl Fn(usize, usize) -> Result<(), Fail>) -> Result<usize, Fail> {
    let mut i = start;
    while let Some(&c) = b.get(i) {
        let rest = &b[i..];
        i = match c {
            b' ' | b'\t' | b'\n' | b'\r' => i + 1,
            b'/' if rest.starts_with(b"//") => rest.iter().position(|&c| c == b'\n').map_or(b.len(), |n| i + n),
            // Unterminated: the data parser says so.
            b'/' if rest.starts_with(b"/*") => after_block_comment(b, i).unwrap_or(b.len()),
            _ => break,
        };
    }
    data(start, i)?;
    Ok(i)
}

fn file(i: &mut Input) -> ModalResult<File> {
    enum Item {
        Import(Import),
        Type(TypeDef),
    }
    let item = alt((import.map(Item::Import), typedef.map(Item::Type))).context(expected("'type' or 'import'"));
    let items: Vec<Item> =
        delimited((opt('\u{feff}'), ws), repeat(0.., item), eof.context(expected("'type' or 'import'")))
            .parse_next(i)?;
    let (imports, types) = items.into_iter().fold((vec![], vec![]), |(mut imports, mut types), item| {
        match item {
            Item::Import(imp) => imports.push(imp),
            Item::Type(def) => types.push(def),
        }
        (imports, types)
    });
    Ok(File { imports, types, warnings: vec![] })
}

fn import(i: &mut Input) -> ModalResult<Import> {
    let module = alt((
        preceded("std/", lower).map(|m| format!("std/{m}")),
        // A package's version may hold `~` (`@a/b@1~x`, an `import-version`); a
        // file path can't (grammar `path`): `./a~b` ends before it.
        token(('@', take_while(1.., |c: char| module_char(c) || c == '~')).take().map(str::to_owned)),
        token(('.', take_while(1.., module_char)).take().map(str::to_owned)),
    ))
    .context(expected("a module (std/time, @org/name, ./file)"));
    // At least one, which `check` says.
    let names = separated(0.., (pos, upper).map(|(p, n)| (n, p)), sym(","));
    let (pos, (module, names)) =
        (pos, preceded(keyword("import"), cut_err((module, delimited(sym("("), names, (opt(sym(",")), sym(")")))))))
            .parse_next(i)?;
    Ok(Import { module, names, pos })
}

/// A character of a module after its first: `[A-Za-z0-9_./@-]`.
fn module_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || "_.-/@".contains(c)
}

fn typedef(i: &mut Input) -> ModalResult<TypeDef> {
    let (attrs, (pos, name, params, ty)) = attributed(
        "'type' after the attributes",
        preceded(keyword("type"), cut_err((pos, upper, repeat(0.., param), preceded(sym("="), ty)))),
    )
    .parse_next(i)?;
    // The doc comment is filled in by `parse`, which has the whole text.
    Ok(TypeDef { name, params, ty, pos, doc: String::new(), attrs })
}

/// `@name` or `@name(value, …)`, then whitespace. The arguments are haus
/// values, read by the data parser; what is wrong with them is reported by
/// [`check`].
fn attribute(i: &mut Input) -> ModalResult<Attribute> {
    let pos = i.current_token_start();
    let name = (
        one_of(|c: char| c.is_ascii_lowercase() || c == '_'),
        take_while(0.., |c: char| c.is_ascii_alphanumeric() || c == '_'),
    )
        .take()
        .map(str::to_owned)
        .context(expected("an attribute name after '@': @deprecated"));
    let name = preceded('@', cut_err(name)).parse_next(i)?;
    let rest: &str = i;
    let args = if rest.starts_with('(') {
        let Some(close) = closing_paren(rest) else {
            return cut_err(fail.context(expected(ATTRIBUTE_CLOSE))).parse_next(i);
        };
        let open = i.current_token_start();
        let inner = &rest[1..close];
        let _ = i.next_slice(close + 1);
        match arguments(inner) {
            Ok(args) if args.is_empty() => {
                Err((open, Code::AttributeArguments, format!("empty parentheses: write @{name} without them")))
            }
            Ok(args) => Ok(args),
            Err(e) => Err((open + e.offset, e.code, format!("in the arguments of @{name}: {}", e.reason))),
        }
    } else {
        // `@deprecated ("x")` would be an attribute without arguments, then `("x")`.
        let before = i.checkpoint();
        ws.parse_next(i)?;
        if i.starts_with('(') {
            i.reset(&before);
            return cut_err(fail.context(expected(ATTRIBUTE_PAREN))).parse_next(i);
        }
        Ok(vec![])
    };
    ws.parse_next(i)?;
    Ok(Attribute { name, args, pos })
}

/// The attributes before `p`, and `p`, which must follow if there are any
/// (`what`, for the message if it doesn't).
fn attributed<'a, O>(
    what: &'static str,
    mut p: impl Parser<Input<'a>, O, E>,
) -> impl Parser<Input<'a>, (Vec<Attribute>, O), E> {
    move |i: &mut Input<'a>| {
        let attrs: Vec<Attribute> = repeat(0.., attribute).parse_next(i)?;
        if attrs.is_empty() {
            return Ok((attrs, p.parse_next(i)?));
        }
        let start = i.checkpoint();
        match p.parse_next(i) {
            Ok(x) => Ok((attrs, x)),
            // Nothing of `p` was read: say what should have come.
            Err(ErrMode::Backtrack(_)) => {
                i.reset(&start);
                cut_err(fail.context(expected(what))).parse_next(i)
            }
            Err(e) => Err(e.cut()),
        }
    }
}

/// Where the `)` matching the `(` that `s` starts with is, skipping strings,
/// comments and nested brackets.
///
/// Everything it looks for is ASCII, and in UTF-8 an ASCII byte is never part
/// of another character, so it scans bytes and never slices the text.
fn closing_paren(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    let mut depth = 0usize;
    let mut i = 0;
    while let Some(&c) = b.get(i) {
        i = match c {
            b'(' | b'[' | b'{' => {
                depth += 1;
                i + 1
            }
            b')' | b']' | b'}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return (c == b')').then_some(i);
                }
                i + 1
            }
            b'"' if b[i..].starts_with(b"\"\"\"") => after_block_string(b, i + 3)?,
            b'"' => after_string(b, i + 1),
            b'/' if b[i..].starts_with(b"//") => i + b[i..].iter().position(|&c| c == b'\n')?,
            b'/' if b[i..].starts_with(b"/*") => after_block_comment(b, i)?,
            _ => i + 1,
        };
    }
    None
}

/// After the `"` that ends the string whose text starts at `i` (or the line
/// break or end where it stops, unterminated: the data parser reports that).
fn after_string(b: &[u8], mut i: usize) -> usize {
    while let Some(&c) = b.get(i) {
        match c {
            b'\\' => i += 2,
            b'"' | b'\n' => return i + 1,
            _ => i += 1,
        }
    }
    i
}

/// After the `"""` that ends the block string whose text starts at `i`.
fn after_block_string(b: &[u8], mut i: usize) -> Option<usize> {
    loop {
        match b.get(i)? {
            b'\\' => i += 2,
            b'"' if b[i..].starts_with(b"\"\"\"") => return Some(i + 3),
            _ => i += 1,
        }
    }
}

/// After the `*/` that ends the (nested) block comment starting at `i`.
fn after_block_comment(b: &[u8], mut i: usize) -> Option<usize> {
    let mut nested = 0usize;
    loop {
        let rest = b.get(i..)?;
        if rest.starts_with(b"/*") {
            nested += 1;
            i += 2;
        } else if rest.starts_with(b"*/") {
            nested -= 1;
            i += 2;
            if nested == 0 {
                return Some(i);
            }
        } else if rest.is_empty() {
            return None;
        } else {
            i += 1;
        }
    }
}

/// `Name atom+ | atom`.
fn ty(i: &mut Input) -> ModalResult<Ty> {
    alt(((pos, upper, repeat(0.., atom)).map(|(pos, name, args)| Ty::Name { name, args, pos }), atom)).parse_next(i)
}

fn atom(i: &mut Input) -> ModalResult<Ty> {
    alt((
        (pos, upper).map(|(pos, name)| Ty::Name { name, args: vec![], pos }),
        preceded(
            keyword("closed"),
            cut_err(preceded(
                peek(one_of(['{', '<'])).context(expected("'{' or '<' after closed")),
                alt((record(true), variant(true))),
            )),
        ),
        (pos, param).map(|(pos, name)| Ty::Param { name, pos }),
        delimited(sym("("), cut_err(ty), cut_err(sym(")"))),
        record(false),
        variant(false),
    ))
    .context(expected("a type"))
    .parse_next(i)
}

/// One entry of a record or variant: its own field or case, or a spread.
enum Member<T> {
    Own(T),
    Spread(String, usize),
}

/// `...Name`, after which [`check`] rejects a lower-case `...r`. One token (spec §14): no
/// whitespace, line break or comment between `...` and the name, `schema-syntax` after `...`.
fn spread<T>(i: &mut Input) -> ModalResult<Member<T>> {
    let name = word(|c| c.is_ascii_alphabetic() || c == '_').context(expected("a type name after '...': ...UserEvent"));
    let joined = peek(one_of(|c: char| c.is_ascii_alphabetic() || c == '_')).context(expected(SPREAD_ONE_WORD));
    preceded(literal("..."), cut_err(preceded(joined, (pos, name))))
        .map(|(pos, name)| Member::Spread(name, pos))
        .parse_next(i)
}

/// Own entries and spreads, each spread remembering how many entries came before it.
/// `with` gives an own entry its attributes.
fn split<T>(members: Vec<(Vec<Attribute>, Member<T>)>, with: impl Fn(T, Vec<Attribute>) -> T) -> (Vec<T>, Vec<Spread>) {
    members.into_iter().fold((vec![], vec![]), |(mut own, mut spreads), (attrs, m)| {
        match m {
            Member::Own(x) => own.push(with(x, attrs)),
            Member::Spread(name, pos) => spreads.push(Spread { name, at: own.len(), pos, attrs }),
        }
        (own, spreads)
    })
}

fn record<'a>(closed: bool) -> impl Parser<Input<'a>, Ty, E> {
    let key = alt((lower, string)).context(expected("a field name"));
    let field = (pos, key, cut_err((opt(sym("?")), preceded(sym(":"), ty)))).map(|(pos, key, (optional, ty))| {
        Member::Own(Field { key, optional: optional.is_some(), ty, pos, attrs: vec![] })
    });
    // A trailing comma only after a member: `{,}` is not a record (grammar: record_type).
    let body = opt(terminated(
        separated(1.., attributed("a field after the attributes", alt((spread, field))), sym(",")),
        opt(sym(",")),
    ))
    .map(Option::unwrap_or_default);
    (pos, preceded(sym("{"), cut_err(terminated(body, sym("}"))))).map(move |(pos, members)| {
        let (fields, spreads) = split(members, |f, attrs| Field { attrs, ..f });
        Ty::Record { closed, fields, spreads, pos }
    })
}

fn variant<'a>(closed: bool) -> impl Parser<Input<'a>, Ty, E> {
    let case = (pos, upper, repeat(0.., atom))
        .map(|(pos, tag, payload)| Member::Own(Case { tag, payload, pos, attrs: vec![] }));
    let body = preceded(
        opt(sym("|")),
        separated(0.., attributed("a tag after the attributes", alt((spread, case))), sym("|")),
    );
    (pos, preceded(sym("<"), cut_err(terminated(body, sym(">"))))).map(move |(pos, members)| {
        let (cases, spreads) = split(members, |c, attrs| Case { attrs, ..c });
        Ty::Variant { closed, cases, spreads, pos }
    })
}

/// The `//` lines directly above the line of `pos` (no blank line in between).
fn doc_comment(text: &str, pos: usize) -> String {
    let before = &text[..pos];
    let lines: Vec<&str> = before
        .lines()
        .rev()
        .skip(usize::from(!before.ends_with('\n')))
        .map_while(|l| l.trim().strip_prefix("//").map(|l| l.strip_prefix(' ').unwrap_or(l)))
        .collect();
    lines.into_iter().rev().collect::<Vec<_>>().join("\n")
}

// ── checks ───────────────────────────────────────────────────

/// What the grammar allows but the spec doesn't (§14): types defined twice
/// or named like a prelude type, duplicate fields and tags, `closed < >`,
/// row parameters (`...r`), and attributes with arguments they don't take,
/// twice on one thing, or on a spread. Returns the warnings: unknown attributes.
fn check(file: &File) -> Result<Vec<Fail>, Fail> {
    fn first_duplicate<'a>(mut names: impl Iterator<Item = (&'a str, usize)>) -> Option<(&'a str, usize)> {
        let mut seen = HashSet::new();
        names.find(|(n, _)| !seen.insert(*n))
    }
    if let Some((name, pos)) = first_duplicate(file.types.iter().map(|d| (d.name.as_str(), d.pos))) {
        return Err((pos, Code::DuplicateType, format!("{name} is defined twice")));
    }
    if let Some(d) = file.types.iter().find(|d| PRELUDE.iter().any(|(n, _)| *n == d.name)) {
        return Err((d.pos, Code::RedefinePrelude, format!("{} is a prelude type and can't be redefined", d.name)));
    }
    if let Some(imp) = file.imports.iter().find(|imp| imp.names.is_empty()) {
        let module = quote(&imp.module);
        let reason = format!("import {module} names no type: import {module} (Name, …)");
        return Err((imp.pos, Code::UnknownImport, reason));
    }
    if let Some((imp, reason)) = file.imports.iter().find_map(|imp| Some((imp, import_version(&imp.module)?))) {
        return Err((imp.pos, Code::ImportVersion, reason));
    }
    if let Some(imp) =
        file.imports.iter().find(|imp| imp.module.starts_with('@') && !is_package_name(package(&imp.module)))
    {
        let reason = format!(
            "unknown module {}: a package is @org/name, in lowercase letters, digits, -, . and _ (not node_modules)",
            quote(&imp.module)
        );
        return Err((imp.pos, Code::UnknownModule, reason));
    }
    for d in &file.types {
        let mut seen = HashSet::new();
        for p in &d.params {
            if p.starts_with('_') {
                let reason = format!("{p} can't be a parameter name: a parameter starts with a lowercase letter");
                return Err((d.pos, Code::InvalidParameter, reason));
            }
            if !seen.insert(p) {
                return Err((d.pos, Code::InvalidParameter, format!("parameter {p} appears twice")));
            }
        }
    }
    fn ty(t: &Ty) -> Result<(), Fail> {
        let rows = match t {
            Ty::Record { spreads, .. } | Ty::Variant { spreads, .. } => spreads.as_slice(),
            _ => &[],
        };
        if let Some(s) = rows.iter().find(|s| !s.name.starts_with(|c: char| c.is_ascii_uppercase())) {
            return Err((
                s.pos,
                Code::RowParameter,
                format!("row parameters (...{}) aren't supported; spread a named type instead: ...UserEvent", s.name),
            ));
        }
        if let Some((s, a)) = rows.iter().find_map(|s| s.attrs.first().map(|a| (s, a))) {
            return Err((
                a.pos,
                Code::AttributeOnSpread,
                format!("a spread can't have attributes; the fields or tags of {} keep their own", s.name),
            ));
        }
        match t {
            Ty::Name { args, .. } => args.iter().try_for_each(ty),
            Ty::Param { name, pos } if name == "_" => Err((
                *pos,
                Code::UnderscoreType,
                "types are open by default, so there is no _: write < > for any tag, or use a type parameter".into(),
            )),
            Ty::Param { .. } => Ok(()),
            Ty::Record { fields, .. } => match first_duplicate(fields.iter().map(|f| (f.key.as_str(), f.pos))) {
                Some((key, pos)) => Err((pos, Code::DuplicateField, format!("duplicate field {key}"))),
                None => fields.iter().try_for_each(|f| ty(&f.ty)),
            },
            Ty::Variant { closed: true, cases, spreads, pos } if cases.is_empty() && spreads.is_empty() => {
                Err((*pos, Code::ClosedEmptyVariant, "a closed variant needs at least one tag".into()))
            }
            Ty::Variant { cases, .. } => match first_duplicate(cases.iter().map(|c| (c.tag.as_str(), c.pos))) {
                Some((tag, pos)) => Err((pos, Code::DuplicateTag, format!("duplicate tag {tag}"))),
                None => cases.iter().flat_map(|c| &c.payload).try_for_each(ty),
            },
        }
    }
    file.types.iter().try_for_each(|d| ty(&d.ty))?;
    let warnings = attribute_lists(file).into_iter().map(attributes).collect::<Result<Vec<_>, _>>()?;
    Ok(warnings.concat())
}

/// Every list of attributes in a file: of its types, fields and tags.
fn attribute_lists(file: &File) -> Vec<&[Attribute]> {
    fn ty<'a>(t: &'a Ty, out: &mut Vec<&'a [Attribute]>) {
        match t {
            Ty::Name { args, .. } => args.iter().for_each(|a| ty(a, out)),
            Ty::Param { .. } => {}
            Ty::Record { fields, .. } => fields.iter().for_each(|f| {
                out.push(&f.attrs);
                ty(&f.ty, out);
            }),
            Ty::Variant { cases, .. } => cases.iter().for_each(|c| {
                out.push(&c.attrs);
                c.payload.iter().for_each(|p| ty(p, out));
            }),
        }
    }
    let mut out = vec![];
    for d in &file.types {
        out.push(d.attrs.as_slice());
        ty(&d.ty, &mut out);
    }
    out
}

/// The attributes of one type, field or tag: defined ones with the right
/// arguments, once each. Unknown ones are accepted with a warning, which this
/// returns: they may come from a later version of haus (spec §14).
fn attributes(attrs: &[Attribute]) -> Result<Vec<Fail>, Fail> {
    let mut warnings = vec![];
    for (i, a) in attrs.iter().enumerate() {
        let args = a.args.as_ref().map_err(Clone::clone)?;
        if !DEFINED_ATTRIBUTES.contains(&a.name.as_str()) {
            let reason = format!("unknown attribute @{}: this version of haus ignores it", a.name);
            warnings.push((a.pos, Code::UnknownAttribute, reason));
            continue;
        }
        if attrs[..i].iter().any(|b| b.name == a.name) {
            return Err((a.pos, Code::AttributeTwice, format!("@{} is written twice here", a.name)));
        }
        if a.name == "deprecated" && !matches!(args.as_slice(), [] | [Value::String(_)]) {
            let reason = "@deprecated takes at most one argument, a string: @deprecated(\"use email\")";
            return Err((a.pos, Code::AttributeArguments, reason.into()));
        }
    }
    Ok(warnings)
}

/// Every cycle of definitions consumes input (spec §9.9): `type A = B`,
/// `type B = A` would apply a type to the same value again and again. A
/// definition reaches another without consuming input if its whole type is
/// that one, or a `Secret` of it, or an argument a generic type passes through
/// (`type Id a = a`).
fn guarded(file: &File) -> Result<(), Fail> {
    let defs: HashMap<&str, &TypeDef> = file.types.iter().map(|d| (d.name.as_str(), d)).collect();
    // The parameters a definition's whole type may be (`type Id a = a`, `type S a = Secret a`).
    fn passes<'a>(def: &'a TypeDef, defs: &HashMap<&str, &'a TypeDef>, busy: &mut Vec<&'a str>) -> Vec<usize> {
        if busy.contains(&def.name.as_str()) {
            return vec![];
        }
        busy.push(&def.name);
        let mut out = vec![];
        let mut names = vec![];
        reaches(&def.ty, defs, busy, &mut names, &mut out, &def.params);
        busy.pop();
        out
    }
    /// The definitions `t` reaches without consuming input, and the parameters (by index) it may be.
    fn reaches<'a>(
        t: &'a Ty,
        defs: &HashMap<&str, &'a TypeDef>,
        busy: &mut Vec<&'a str>,
        names: &mut Vec<&'a str>,
        params: &mut Vec<usize>,
        own: &[String],
    ) {
        match t {
            Ty::Name { name, args, .. } if name == "Secret" => {
                args.iter().for_each(|a| reaches(a, defs, busy, names, params, own));
            }
            Ty::Name { name, args, .. } => {
                if let Some(def) = defs.get(name.as_str()) {
                    names.push(&def.name);
                    for i in passes(def, defs, busy) {
                        if let Some(a) = args.get(i) {
                            reaches(a, defs, busy, names, params, own);
                        }
                    }
                }
            }
            Ty::Param { name, .. } => params.extend(own.iter().position(|p| p == name)),
            Ty::Record { .. } | Ty::Variant { .. } => {}
        }
    }
    let edges: HashMap<&str, Vec<&str>> = file
        .types
        .iter()
        .map(|d| {
            let mut names = vec![];
            reaches(&d.ty, &defs, &mut vec![], &mut names, &mut vec![], &d.params);
            (d.name.as_str(), names)
        })
        .collect();
    for d in &file.types {
        let (mut seen, mut todo) = (HashSet::new(), edges[d.name.as_str()].clone());
        while let Some(n) = todo.pop() {
            if n == d.name {
                return Err((
                    d.pos,
                    Code::UnguardedRecursion,
                    format!(
                        "{} refers to itself without a record field, array element or variant payload in between, \
                         so decoding it would never end",
                        d.name
                    ),
                ));
            }
            if seen.insert(n) {
                todo.extend(edges.get(n).into_iter().flatten());
            }
        }
    }
    Ok(())
}

/// Warnings for uses of deprecated types, outside deprecated types (spec §14),
/// in the file as written: a spread of a deprecated type (`...OldEvent`) is a
/// use, and a field or tag that is spread elsewhere is still one use.
fn deprecated_uses(file: &File) -> Vec<Fail> {
    fn walk(t: &Ty, f: &mut impl FnMut(&str, usize)) {
        match t {
            Ty::Name { name, args, pos } => {
                f(name, *pos);
                args.iter().for_each(|a| walk(a, f));
            }
            Ty::Param { .. } => {}
            Ty::Record { fields, spreads, .. } => {
                spreads.iter().for_each(|s| f(&s.name, s.pos));
                fields.iter().for_each(|x| walk(&x.ty, f));
            }
            Ty::Variant { cases, spreads, .. } => {
                spreads.iter().for_each(|s| f(&s.name, s.pos));
                cases.iter().flat_map(|c| &c.payload).for_each(|p| walk(p, f));
            }
        }
    }
    let deprecated: HashMap<&str, Option<&str>> =
        file.types.iter().filter_map(|d| deprecation(&d.attrs).map(|why| (d.name.as_str(), why))).collect();
    let mut out = vec![];
    for d in file.types.iter().filter(|d| !deprecated.contains_key(d.name.as_str())) {
        walk(&d.ty, &mut |name, pos| {
            if let Some(why) = deprecated.get(name) {
                out.push((
                    pos,
                    Code::Deprecated,
                    why.map_or(format!("{name} is deprecated"), |why| format!("{name} is deprecated: {why}")),
                ));
            }
        });
    }
    out
}

// ── spreads ──────────────────────────────────────────────────

/// What is wrong, at a byte offset, and its code.
pub type Fail = (usize, Code, String);

/// Copies every `...Name` in: a variant gets the named variant's tags, a
/// record the named record's fields, in the place they are written. Whether
/// the result is open or closed stays its own (spec §14).
/// With `keep_imported`, spreads of imported types stay (see [`parse_with_imported_spreads`]).
fn expand(file: File, keep_imported: bool) -> Result<File, Fail> {
    let mut x = Expander {
        defs: file.types.iter().map(|d| (d.name.clone(), d.clone())).collect(),
        imported: names(file.imports.iter().filter(|i| !i.module.starts_with("std/"))),
        std: names(file.imports.iter().filter(|i| i.module.starts_with("std/"))),
        keep_imported,
        done: HashMap::new(),
        busy: vec![],
    };
    let types =
        file.types.iter().map(|d| Ok(TypeDef { ty: x.ty(&d.ty)?, ..d.clone() })).collect::<Result<Vec<_>, Fail>>()?;
    Ok(File { types, ..file })
}

/// The names the imports bring in.
fn names<'a>(imports: impl Iterator<Item = &'a Import>) -> HashSet<String> {
    imports.flat_map(|i| i.names.iter().map(|(n, _)| n.clone())).collect()
}

struct Expander {
    defs: HashMap<String, TypeDef>,
    /// Names imported from files and packages.
    imported: HashSet<String>,
    /// Names imported from standard modules (std/time): types, but not records or variants.
    std: HashSet<String>,
    /// Leave spreads of imported types in place, for the resolver.
    keep_imported: bool,
    /// Bodies of definitions already expanded.
    done: HashMap<String, Ty>,
    /// Definitions being expanded, to catch a type that spreads itself.
    busy: Vec<String>,
}

impl Expander {
    fn ty(&mut self, t: &Ty) -> Result<Ty, Fail> {
        Ok(match t {
            Ty::Name { name, args, pos } => Ty::Name {
                name: name.clone(),
                args: args.iter().map(|a| self.ty(a)).collect::<Result<_, _>>()?,
                pos: *pos,
            },
            Ty::Param { .. } => t.clone(),
            Ty::Record { closed, fields, spreads, pos } => {
                let own = fields
                    .iter()
                    .map(|f| Ok((Field { ty: self.ty(&f.ty)?, ..f.clone() }, None)))
                    .collect::<Result<Vec<_>, Fail>>()?;
                let (fields, spreads) = self.merge(own, spreads, |x, s| match x.body(s, "record")? {
                    Ty::Record { fields, .. } => Ok(fields),
                    _ => Err((
                        s.pos,
                        Code::InvalidSpread,
                        format!("{} is not a record, so it can't be spread here", s.name),
                    )),
                })?;
                if let Some((key, pos)) = duplicate(fields.iter().map(|(f, from)| (f.key.as_str(), f.pos, *from))) {
                    return Err((pos, Code::DuplicateField, format!("duplicate field {key}")));
                }
                Ty::Record { closed: *closed, fields: fields.into_iter().map(|(f, _)| f).collect(), spreads, pos: *pos }
            }
            Ty::Variant { closed, cases, spreads, pos } => {
                let own = cases
                    .iter()
                    .map(|c| {
                        let payload = c.payload.iter().map(|p| self.ty(p)).collect::<Result<_, _>>()?;
                        Ok((Case { payload, ..c.clone() }, None))
                    })
                    .collect::<Result<Vec<_>, Fail>>()?;
                let (cases, spreads) = self.merge(own, spreads, |x, s| match x.body(s, "variant")? {
                    Ty::Variant { cases, .. } => Ok(cases),
                    _ => Err((
                        s.pos,
                        Code::InvalidSpread,
                        format!("{} is not a variant, so it can't be spread here", s.name),
                    )),
                })?;
                if let Some((tag, pos)) = duplicate(cases.iter().map(|(c, from)| (c.tag.as_str(), c.pos, *from))) {
                    return Err((pos, Code::DuplicateTag, format!("duplicate tag {tag}")));
                }
                Ty::Variant { closed: *closed, cases: cases.into_iter().map(|(c, _)| c).collect(), spreads, pos: *pos }
            }
        })
    }

    /// Whether `name` is imported, or an alias of an imported type.
    fn imports(&self, name: &str) -> bool {
        let mut name = name;
        for _ in 0..=self.defs.len() {
            match self.defs.get(name) {
                Some(TypeDef { params, ty: Ty::Name { name: next, args, .. }, .. })
                    if params.is_empty() && args.is_empty() =>
                {
                    name = next
                }
                Some(_) => return false,
                None => return self.imported.contains(name),
            }
        }
        false
    }

    /// Own entries with each spread's entries inserted where it was written.
    /// Copied entries carry the spread's position, for error messages. The
    /// spreads left for the resolver (of imported types, when they are kept)
    /// come back with their place among the entries.
    #[allow(clippy::type_complexity)]
    fn merge<T: Clone>(
        &mut self,
        own: Vec<(T, Option<usize>)>,
        spreads: &[Spread],
        copied: impl Fn(&mut Self, &Spread) -> Result<Vec<T>, Fail>,
    ) -> Result<(Vec<(T, Option<usize>)>, Vec<Spread>), Fail> {
        let (mut out, mut kept) = (vec![], vec![]);
        let n = own.len();
        for (i, entry) in own.into_iter().map(Some).chain([None]).enumerate() {
            for s in spreads.iter().filter(|s| s.at == i) {
                match self.keep_imported && self.imports(&s.name) {
                    true => kept.push(Spread { at: out.len(), ..s.clone() }),
                    false => out.extend(copied(self, s)?.into_iter().map(|x| (x, Some(s.pos)))),
                }
            }
            if i < n {
                out.extend(entry);
            }
        }
        Ok((out, kept))
    }

    /// The expanded body of the type a spread names, following aliases and
    /// instances of generic types (spec §14): `type C = Page Int` is spread
    /// as the body of `Page`, its parameters replaced by the arguments.
    /// `want`: a record or a variant, for errors.
    fn body(&mut self, s: &Spread, want: &str) -> Result<Ty, Fail> {
        let (mut name, mut args) = (s.name.clone(), Vec::new());
        // Every hop goes to another definition, unless the names go round in
        // a circle, which `guarded` would report later.
        for _ in 0..=self.defs.len() {
            let Some(def) = self.defs.get(&name).cloned() else {
                // A standard or built-in type is known, just not a record or variant.
                let known = self.std.contains(&name) || PRELUDE.iter().any(|(n, _)| *n == name);
                return match (known, self.imported.contains(&name)) {
                    (true, _) => Err((
                        s.pos,
                        Code::InvalidSpread,
                        format!("{} is not a {want}, so it can't be spread here", s.name),
                    )),
                    (false, true) => Err((
                        s.pos,
                        Code::InvalidSpread,
                        format!(
                            "{name} is imported; spreading it needs the files it comes from (load the schema with its imports)"
                        ),
                    )),
                    (false, false) => Err((s.pos, Code::UnknownType, unknown_type(&name))),
                };
            };
            if def.params.len() != args.len() {
                let params = def.params.join(" ");
                return Err(match args.is_empty() {
                    true => (
                        s.pos,
                        Code::InvalidSpread,
                        format!(
                            "{name} has parameters ({name} {params}); only a type without parameters can be spread"
                        ),
                    ),
                    false => (
                        s.pos,
                        Code::WrongArity,
                        format!("{name} takes {} argument(s), found {}", def.params.len(), args.len()),
                    ),
                });
            }
            let body = match self.done.get(&name) {
                Some(t) => t.clone(),
                None => {
                    if self.busy.contains(&name) {
                        return Err((
                            def.pos,
                            Code::SpreadCycle,
                            format!("type {name} spreads itself (directly or through another type)"),
                        ));
                    }
                    self.busy.push(name.clone());
                    let t = self.ty(&def.ty)?;
                    self.busy.pop();
                    self.done.insert(name.clone(), t.clone());
                    t
                }
            };
            let env: Vec<(String, Ty)> = def.params.iter().cloned().zip(args).collect();
            match substitute(&body, &env) {
                Ty::Name { name: stream, .. } if stream == "Stream" => {
                    return Err((s.pos, Code::InvalidSpread, format!("{} is a Stream and can't be spread", s.name)));
                }
                Ty::Name { name: next, args: next_args, .. } => (name, args) = (next, next_args),
                other => return Ok(other),
            }
        }
        let def = &self.defs[&s.name];
        Err((
            def.pos,
            Code::UnguardedRecursion,
            format!(
                "{} refers to itself without a record field, array element or variant payload in between, \
                 so decoding it would never end",
                s.name
            ),
        ))
    }
}

/// `t` with each type parameter that `env` names replaced by its argument.
fn substitute(t: &Ty, env: &[(String, Ty)]) -> Ty {
    if env.is_empty() {
        return t.clone();
    }
    match t {
        Ty::Param { name, .. } => env.iter().find(|(p, _)| p == name).map_or_else(|| t.clone(), |(_, a)| a.clone()),
        Ty::Name { name, args, pos } => {
            Ty::Name { name: name.clone(), args: args.iter().map(|a| substitute(a, env)).collect(), pos: *pos }
        }
        Ty::Record { closed, fields, spreads, pos } => Ty::Record {
            closed: *closed,
            fields: fields.iter().map(|f| Field { ty: substitute(&f.ty, env), ..f.clone() }).collect(),
            spreads: spreads.clone(),
            pos: *pos,
        },
        Ty::Variant { closed, cases, spreads, pos } => Ty::Variant {
            closed: *closed,
            cases: cases
                .iter()
                .map(|c| Case { payload: c.payload.iter().map(|p| substitute(p, env)).collect(), ..c.clone() })
                .collect(),
            spreads: spreads.clone(),
            pos: *pos,
        },
    }
}

/// The first name that appears twice, at the later entry (or the spread that brought it).
fn duplicate<'a>(mut names: impl Iterator<Item = (&'a str, usize, Option<usize>)>) -> Option<(&'a str, usize)> {
    let mut seen = HashSet::new();
    names.find(|(n, _, _)| !seen.insert(*n)).map(|(n, pos, from)| (n, from.unwrap_or(pos)))
}
