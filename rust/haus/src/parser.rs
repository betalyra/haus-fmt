//! Recursive-descent parser over one complete piece of text: a port of the
//! TypeScript reference parser (typescript/packages/haus/src/parser.ts).

use crate::keys::Keys;
use crate::scan::{Special, ident_end, is_bidi, is_control, is_ident, next_special, plain_decimal, shown};
use crate::{ErrorCode as Code, Number, Record, SyntaxError as Error, Tag, Value};
use std::borrow::Cow;
use std::fmt::Write as _;

/// The largest [`Limits::max_depth`] this binding supports (spec §7): the
/// default, 256.
///
/// The parser, decoding, encoding and the JSON mappings recurse once per
/// level of nesting (the JSON reader and writer and the canonical form
/// don't), so the depth limit bounds the call stack they use. Every function
/// that takes limits rejects a larger `max_depth` with an error that names
/// this maximum, rather than risk overflowing the stack on deep input. At
/// this depth each of them stays well within a thread with a 2 MiB stack
/// (the default of spawned threads, test threads and many async runtimes),
/// in a debug build too. Code generated for a recursive type takes stack in
/// proportion to the type's size: see the README.
pub const MAX_SUPPORTED_DEPTH: usize = 256;

/// How many levels of a [`crate::Value`] or [`crate::Json`] `{:?}` shows:
/// deeper arrays, records, arguments and objects are `…`, so that printing
/// a value built in code of any depth takes a bounded stack (spec §7).
pub const DEBUG_DEPTH: usize = 64;

/// Resource limits (spec §7): enforced while parsing, and by the writers,
/// which check a value against the limits of the reader it is for (§11).
/// The canonical form and hashing apply none of them (§12).
///
/// ```
/// let limits = haus::Limits { max_nodes: 3, ..haus::Limits::default() };
/// let v = haus::parse("[1, [2, 3]]").unwrap().remove(0);
/// let e = haus::to_string_with(&v, &limits).unwrap_err();
/// assert_eq!(e.code, haus::ErrorCode::TooManyNodes);
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Nesting depth of records, arrays and payloads: at most
    /// [`MAX_SUPPORTED_DEPTH`].
    pub max_depth: usize,
    /// Characters in one number literal, including sign, separators and
    /// exponent. A hex literal also has at most
    /// [`max_hex_digits`](Limits::max_hex_digits) hex digits, so that every
    /// integer has a decimal form within this limit.
    pub max_number_length: usize,
    /// Largest absolute exponent: 6144 allows `1e6144` but not `1e6145`.
    /// `u64::MAX` is no limit: an exponent of any size is read.
    pub max_exponent: u64,
    /// Characters (code points) in one decoded string, record key or tag,
    /// or between the quotes of a byte string.
    pub max_string_length: usize,
    /// Values written for one value (spec §7, "Values written"): the value
    /// itself and every element, field value and argument in it, each as
    /// often as it is written. Writers of values and encoding fail with
    /// `too-many-nodes` beyond it, for each top-level value on its own: it
    /// ends a native value whose parts are shared (an `Rc`), which expands
    /// when written. Parsing, the canonical form and hashing don't use it: a
    /// [`Value`] owns its parts, so it can't share them. 64 Mi (67,108,864).
    pub max_nodes: usize,
}

impl Limits {
    /// The most hex digits (leading zeros counted, `_` not) in one hex
    /// literal, derived from the number limit *n* (spec §7): the largest *h*
    /// with 16^*h* ≤ 10^(*n*−1), so that the integer's decimal form, sign
    /// included, fits in *n* characters. 829 for the default 1000.
    ///
    /// ```
    /// assert_eq!(haus::Limits::default().max_hex_digits(), 829);
    /// ```
    pub fn max_hex_digits(&self) -> usize {
        max_hex_digits(self.max_number_length)
    }

    /// Whether an exponent, its decimal digits without sign, `_` or leading
    /// zeros, is above the exponent limit. `u64::MAX` is no limit, so that an
    /// exponent of any length can be read (`Number::new`, spec §11).
    pub(crate) fn exponent_exceeds(&self, digits: &str) -> bool {
        self.max_exponent != u64::MAX && (digits.len() > 19 || digits.parse::<u64>().unwrap_or(0) > self.max_exponent)
    }

    /// Why this binding can't use these limits: a depth limit above
    /// [`MAX_SUPPORTED_DEPTH`].
    pub(crate) fn unsupported(&self) -> Option<String> {
        (self.max_depth > MAX_SUPPORTED_DEPTH)
            .then(|| format!("max_depth {} is more than the supported maximum, {MAX_SUPPORTED_DEPTH}", self.max_depth))
    }
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_depth: 256,
            max_number_length: 1000,
            max_exponent: 6144,
            max_string_length: 16 * 1024 * 1024,
            max_nodes: 64 * 1024 * 1024,
        }
    }
}

/// Parse a file with the given limits.
/// Fails, before reading anything, if `limits.max_depth` is more than
/// [`MAX_SUPPORTED_DEPTH`].
pub fn parse_with(src: &str, limits: &Limits) -> Result<Vec<Value>, Error> {
    let start = if src.starts_with('\u{FEFF}') { 3 } else { 0 };
    Parser::new(src, limits, start, Some(start))?.sequence()
}

/// The rest of a stream: like `parse_with`, but a byte order mark is not
/// skipped (the reader removes the one at the start). `at_start`: the text
/// is the start of the file.
pub(crate) fn parse_rest(src: &str, limits: &Limits, at_start: bool) -> Result<Vec<Value>, Error> {
    Parser::new(src, limits, 0, at_start.then_some(0))?.sequence()
}

/// Exactly one value, with comments and whitespace around it: one item of a stream.
pub(crate) fn parse_single(src: &str, limits: &Limits, at_start: bool) -> Result<Value, Error> {
    Parser::new(src, limits, 0, at_start.then_some(0))?.single(false)
}

/// One item of a stream with the comma after it, which ends `src`: errors
/// are those of the whole file, which sees the comma too (`1,,2`: "expected
/// a value, found ','").
pub(crate) fn parse_item(src: &str, limits: &Limits, at_start: bool) -> Result<Value, Error> {
    Parser::new(src, limits, 0, at_start.then_some(0))?.single(true)
}

/// `text` as exactly one number literal (`1E5`, `0xFF`, `1_000`), normalized
/// as the parser reads it (`1e5`, `255`, `1000`); None if it isn't one or is
/// beyond the limits.
pub(crate) fn number_literal(text: &str, limits: &Limits) -> Option<Number> {
    let mut p = Parser::build(text, limits, 0, None);
    match p.number() {
        Ok(n) if p.pos == text.len() => Some(n),
        _ => None,
    }
}

/// ⌊2^128 · log₁₆ 10⌋, as its high and low 64 bits.
const LOG16_10: (u128, u128) = (0xd49a_784b_cd1b_8afe, 0x492b_f6ff_4daf_db4c);

/// The largest `h` with 16^h ≤ 10^(n−1), i.e. ⌊(n−1) · log₁₆ 10⌋, exactly:
/// computed with log₁₆ 10 rounded down and up in 128 bits, which give the
/// same floor unless (n−1) · log₁₆ 10 is within (n−1)/2^128 of an integer;
/// that is then decided with exact powers.
fn max_hex_digits(n: usize) -> usize {
    let m = n.saturating_sub(1) as u128;
    // ⌊m · f / 2^128⌋ for the 128-bit fraction f = (high, low).
    let floor = |(high, low): (u128, u128)| (m * high + ((m * low) >> 64)) >> 64;
    let below = floor(LOG16_10);
    let above = floor((LOG16_10.0, LOG16_10.1 + 1));
    let h = if below == above || !hex_fits(above, m) { below } else { above };
    usize::try_from(h).unwrap_or(usize::MAX)
}

/// Whether 16^h ≤ 10^m, exactly: 2^(4h) ≤ 2^m · 5^m, i.e. 4h − m is less than
/// the bit length of 5^m (which is no power of 2 for m > 0).
fn hex_fits(h: u128, m: u128) -> bool {
    let Some(k) = (4 * h).checked_sub(m) else { return true };
    // 5^m in little-endian 64-bit limbs, 5^27 (< 2^64) at a time.
    let mut limbs: Vec<u64> = vec![1];
    let mut left = m;
    while left > 0 {
        let e = left.min(27);
        left -= e;
        let mut carry = 0u128;
        for limb in &mut limbs {
            let v = u128::from(*limb) * 5u128.pow(e as u32) + carry;
            *limb = v as u64;
            carry = v >> 64;
        }
        if carry > 0 {
            limbs.push(carry as u64);
        }
    }
    let top = limbs.last().copied().unwrap_or(1);
    let bits = (limbs.len() as u128 - 1) * 64 + u128::from(64 - top.leading_zeros());
    k < bits
}

type R<T> = Result<T, Error>;

/// Which kind of container an item is in.
#[derive(Clone, Copy)]
enum Within {
    Record,
    List,
}

struct Parser<'a> {
    src: &'a str,
    b: &'a [u8],
    pos: usize,
    depth: usize,
    limits: &'a Limits,
    /// [`Limits::max_hex_digits`], computed once.
    max_hex_digits: usize,
    /// Where the file's first character is, if this text has it (after a byte order mark).
    file_start: Option<usize>,
    /// The items of the arrays and payloads being read, innermost last: each
    /// container takes its own off the top when it closes, into a vector of
    /// exactly their number.
    items: Vec<Value>,
    /// The fields of the records being read, the same way.
    fields: Vec<(String, Value)>,
}

fn is_lower_start(c: u8) -> bool {
    c.is_ascii_lowercase() || c == b'_'
}
fn is_blank(s: &str) -> bool {
    s.bytes().all(|c| c == b' ' || c == b'\t')
}
fn hex_value(c: u8) -> Option<u8> {
    (c as char).to_digit(16).and_then(|d| u8::try_from(d).ok())
}
fn describe(c: Option<char>) -> String {
    match c {
        None => "end of input".into(),
        Some('\n') => "line break".into(),
        Some(c) => format!("'{}'", shown(c.encode_utf8(&mut [0; 4]))),
    }
}

impl<'a> Parser<'a> {
    /// A parser at `pos`, if this binding supports `limits`.
    fn new(src: &'a str, limits: &'a Limits, pos: usize, file_start: Option<usize>) -> R<Parser<'a>> {
        match limits.unsupported() {
            Some(reason) => Err(Error::at(src, 0, Code::UnsupportedDepth, reason)),
            None => Ok(Parser::build(src, limits, pos, file_start)),
        }
    }

    /// A parser at `pos`, for limits this binding supports.
    fn build(src: &'a str, limits: &'a Limits, pos: usize, file_start: Option<usize>) -> Parser<'a> {
        Parser {
            src,
            b: src.as_bytes(),
            pos,
            depth: 0,
            limits,
            max_hex_digits: limits.max_hex_digits(),
            file_start,
            items: Vec::new(),
            fields: Vec::new(),
        }
    }

    // ── values ─────────────────────────────────────────────────

    fn sequence(&mut self) -> R<Vec<Value>> {
        let mut out = Vec::new();
        self.trivia()?;
        while !self.eof() {
            out.push(self.value()?);
            self.trivia()?;
            if self.eof() {
                break;
            }
            if self.peek() != Some(b',') {
                return Err(self.separator_error(out.last(), "expected ',' between top-level values", None));
            }
            self.pos += 1;
            self.trivia()?;
        }
        Ok(out)
    }

    /// `comma`: the text ends with the comma after the value.
    fn single(&mut self, comma: bool) -> R<Value> {
        self.trivia()?;
        if self.eof() || self.peek() == Some(b',') {
            let found = describe(self.peek_char());
            return Err(self
                .fail(Code::ExpectedValue, format!("expected a value, found {found}"))
                .with_expected_found("a value", found));
        }
        let value = self.value()?;
        self.trivia()?;
        if comma && self.peek() == Some(b',') && self.pos + 1 == self.b.len() {
            self.pos += 1;
        }
        match self.eof() {
            true => Ok(value),
            false => Err(self.separator_error(Some(&value), "expected ',' between top-level values", None)),
        }
    }

    fn value(&mut self) -> R<Value> {
        match self.peek() {
            Some(b'{') => self.record(),
            Some(b'[') => self.list(b']').map(Value::Array),
            Some(b'"') if self.b[self.pos..].starts_with(b"\"\"\"") => self.block_string().map(Value::String),
            Some(b'"') => self.basic_string().map(Value::String),
            Some(b'-' | b'0'..=b'9') => match self.plain_number() {
                Some(n) => Ok(Value::Number(n)),
                None => self.number().map(Value::Number),
            },
            Some(b'x') if self.at(1) == Some(b'"') => self.bytes(),
            Some(c) if c.is_ascii_uppercase() => self.variant(),
            _ => Err(self.not_a_value()),
        }
    }

    /// Why no value starts here. Kept out of [`Parser::value`], which
    /// recurses: its frame stays small (see [`crate::MAX_SUPPORTED_DEPTH`]).
    #[cold]
    #[inline(never)]
    fn not_a_value(&mut self) -> Error {
        match self.peek() {
            Some(c) if is_lower_start(c) => {
                let start = self.pos;
                let word = self.ident();
                let (code, hint) = match word {
                    "true" | "false" => (Code::BooleanLiteral, " (booleans are the variants True / False)"),
                    "null" => (Code::NullLiteral, " (use the variant None)"),
                    _ => (Code::BareIdentifier, ""),
                };
                self.fail_at(
                    start,
                    code,
                    format!(
                        "unexpected identifier '{}': lowercase identifiers can only be record keys{hint}",
                        shown(word)
                    ),
                )
                .with_expected_found("a value", format!("'{}'", shown(word)))
            }
            // Reserved for a version directive (spec §10): `#haus 2`.
            Some(b'#') if self.file_start == Some(self.pos) && self.b[self.pos..].starts_with(b"#haus") => self.fail(
                Code::VersionDirective,
                "the file starts with a version directive (#haus): it needs a newer version of haus",
            ),
            c => {
                // `+1` and `.5`: a number written the way other languages allow.
                let code = if matches!(c, Some(b'+' | b'.')) { Code::InvalidNumber } else { Code::ExpectedValue };
                let found = describe(self.peek_char());
                self.fail(code, format!("expected a value, found {found}")).with_expected_found("a value", found)
            }
        }
    }

    fn enter(&mut self) -> R<()> {
        self.depth += 1;
        if self.depth > self.limits.max_depth {
            return Err(
                self.fail(Code::NestingTooDeep, format!("nesting deeper than {} levels", self.limits.max_depth))
            );
        }
        Ok(())
    }

    fn record(&mut self) -> R<Value> {
        let open = self.pos;
        self.enter()?;
        self.pos += 1; // {
        let base = self.fields.len();
        let mut keys = Keys::default();
        self.trivia()?;
        while self.more(open, b'}')? {
            let key = self.field_key(base, &mut keys)?;
            let value = self.value()?;
            self.fields.push((key.into_owned(), value));
            self.separator(open, b'}', Within::Record)?;
        }
        self.pos += 1; // }
        self.depth -= 1;
        Ok(Value::Record(Record::from_unique(self.fields.drain(base..).collect())))
    }

    /// A field's key and the `:` after it, in the record whose fields start
    /// at `base`. The key must be new (spec §1): a duplicate is reported at
    /// its name as soon as it is read, before its colon and value (§17).
    fn field_key(&mut self, base: usize, keys: &mut Keys) -> R<Cow<'a, str>> {
        let key_pos = self.pos;
        let key = self.key()?;
        if !keys.insert(&self.fields[base..], &key) {
            return Err(self.fail_at(key_pos, Code::DuplicateKey, format!("duplicate key '{}'", shown(&key))));
        }
        self.trivia()?;
        if self.peek() != Some(b':') {
            let found = describe(self.peek_char());
            return Err(self
                .fail(Code::MissingColon, format!("expected ':' after key '{}', found {found}", shown(&key)))
                .with_expected_found("':'", found));
        }
        self.pos += 1;
        self.trivia()?;
        Ok(key)
    }

    fn key(&mut self) -> R<Cow<'a, str>> {
        match self.peek() {
            Some(b'"') if self.b[self.pos..].starts_with(b"\"\"\"") => {
                Err(self.fail(Code::BlockStringKey, "block strings can't be record keys"))
            }
            // A quoted key is a string: the string limit says so.
            Some(b'"') => self.string(),
            Some(c) if is_lower_start(c) => self.name(Code::KeyTooLong).map(Cow::Borrowed),
            Some(c) if c.is_ascii_uppercase() => {
                let start = self.pos;
                let word = self.ident();
                Err(self
                    .fail_at(
                        start,
                        Code::UppercaseKey,
                        format!("record keys must start with a lowercase letter or '_'; quote it: \"{}\"", shown(word)),
                    )
                    .with_hint(format!("Quote the key: \"{}\".", shown(word))))
            }
            _ => {
                let found = describe(self.peek_char());
                Err(self
                    .fail(Code::ExpectedKey, format!("expected a record key, found {found}"))
                    .with_expected_found("a record key", found))
            }
        }
    }

    /// `open value, value, … close`, with an optional trailing comma.
    fn list(&mut self, close: u8) -> R<Vec<Value>> {
        let start = self.pos;
        self.enter()?;
        self.pos += 1;
        let base = self.items.len();
        self.trivia()?;
        while self.more(start, close)? {
            let item = self.value()?;
            self.items.push(item);
            self.separator(start, close, Within::List)?;
        }
        self.pos += 1;
        self.depth -= 1;
        Ok(self.items.drain(base..).collect())
    }

    // The containers' steps that don't recurse are functions of their own,
    // so that the frames of the recursive ones stay small (see
    // `crate::MAX_SUPPORTED_DEPTH`).

    /// Whether another item comes before `close`, in the container opened at `start`.
    fn more(&self, start: usize, close: u8) -> R<bool> {
        match self.peek() {
            Some(c) if c == close => Ok(false),
            None => Err(self.unclosed(start)),
            _ => Ok(true),
        }
    }

    /// After an item of a record or a list (`within`): `,` and the trivia
    /// after it, or `close`.
    fn separator(&mut self, start: usize, close: u8, within: Within) -> R<()> {
        self.trivia()?;
        match self.peek() {
            Some(b',') => {
                self.pos += 1;
                self.trivia()
            }
            Some(c) if c == close => Ok(()),
            None => Err(self.unclosed(start)),
            _ => {
                let previous = match within {
                    Within::Record => self.fields.last().map(|(_, v)| v),
                    Within::List => self.items.last(),
                };
                Err(self.separator_error(previous, &format!("expected ',' or '{}'", close as char), Some(close)))
            }
        }
    }

    /// After `previous`, something other than a comma (or the closing bracket
    /// `close`). Which mistake it is: a payload `(…)` or `{…}` on a line after
    /// its tag (the tag took no payload, so anything between them was a line
    /// break or a comment), a closing bracket of the wrong kind, or a missing
    /// comma (spec §17).
    #[cold]
    #[inline(never)]
    fn separator_error(&self, previous: Option<&Value>, message: &str, close: Option<u8>) -> Error {
        let found = describe(self.peek_char());
        let reason = format!("{message}, found {found}");
        let expected = match close {
            None => "','".to_owned(),
            Some(c) => format!("',' or '{}'", c as char),
        };
        match (self.peek(), previous) {
            (Some(b'(' | b'{'), Some(Value::Variant { tag, args })) if args.is_empty() => {
                self.fail(Code::PayloadNewline, reason).with_expected_found("','", found).with_hint(format!(
                    "Put the payload on the same line as {tag}, or add a comma if they are two values."
                ))
            }
            (Some(b'}' | b']' | b')'), _) => {
                self.fail(Code::UnexpectedCloser, reason).with_expected_found(expected, found)
            }
            _ => self.fail(Code::MissingComma, reason).with_expected_found("','", found),
        }
    }

    #[cold]
    fn unclosed(&self, start: usize) -> Error {
        let close = match self.b[start] {
            b'{' => '}',
            b'[' => ']',
            _ => ')',
        };
        self.fail_at(start, Code::UnclosedBracket, format!("unclosed '{}'", self.b[start] as char))
            .with_expected(format!("'{close}'"))
    }

    fn variant(&mut self) -> R<Value> {
        let tag = self.name(Code::TagTooLong)?.to_owned();
        let args = match self.payload() {
            Some(b'(') => {
                let paren = self.pos;
                let args = self.list(b')')?;
                if args.is_empty() {
                    return Err(self.empty_payload(paren, &tag));
                }
                args
            }
            Some(_) => {
                let record = self.record()?;
                vec![record]
            }
            None => Vec::new(),
        };
        Ok(Value::Variant { tag: Tag::from_valid(tag), args })
    }

    /// After a tag: `(` or `{` if a payload starts here, at it. The payload
    /// must follow on the same line: only spaces and tabs in between.
    /// Otherwise `Heartbeat⏎{ a: 1 }` with a forgotten comma would silently
    /// become one variant with a payload.
    fn payload(&mut self) -> Option<u8> {
        let after_tag = self.pos;
        while matches!(self.peek(), Some(b' ' | b'\t')) {
            self.pos += 1;
        }
        match self.peek() {
            Some(c @ (b'(' | b'{')) => Some(c),
            _ => {
                self.pos = after_tag;
                None
            }
        }
    }

    #[cold]
    fn empty_payload(&self, paren: usize, tag: &str) -> Error {
        self.fail_at(paren, Code::EmptyPayload, format!("empty payload: write '{}' without parentheses", shown(tag)))
            .with_hint(format!("Write {} without parentheses.", shown(tag)))
    }

    // ── numbers ────────────────────────────────────────────────

    /// A number: the literal (a linear scan), then what follows it, then
    /// the limits, as the reference does (a literal that runs into a letter
    /// is invalid however long it is). Converted only within the limits, so
    /// huge literals stay cheap.
    fn number(&mut self) -> R<Number> {
        let start = self.pos;
        let neg = self.peek() == Some(b'-');
        let body = start + usize::from(neg);
        let (radix, end) = match self.radix_literal(body) {
            Some((radix, end)) => (Some(radix), end),
            None => match self.decimal_literal(start) {
                Some(end) => (None, end),
                None => return Err(self.fail_at(start, Code::InvalidNumber, "invalid number")),
            },
        };
        if matches!(self.b.get(end), Some(&c) if is_ident(c) || c == b'.') {
            let mut to = end;
            while matches!(self.b.get(to), Some(&c) if is_ident(c) || c == b'.') {
                to += 1;
            }
            return Err(self.fail_at(
                start,
                Code::InvalidNumber,
                format!("invalid number '{}'", shown(&self.src[start..to])),
            ));
        }
        self.check_number_limits(start, end, radix)?;
        self.pos = end;
        let text = match radix {
            Some(radix) => {
                let digits: Vec<u8> = self.b[body + 2..end].iter().copied().filter(|&c| c != b'_').collect();
                let n = to_decimal(&digits, radix);
                // The sign stays, also on zero: `-0x0` is `-0`, as `-0` is (spec §2).
                if neg { format!("-{n}") } else { n }
            }
            None => normalize_exponent(self.src[start..end].replace('_', "").replace('E', "e")),
        };
        Ok(Number::from_normalized(text))
    }

    /// The common case of [`Parser::number`], in one pass: a decimal
    /// literal without separators or exponent (`-12`, `0.5`), within the
    /// length limit and not running into a letter, digit or `.`, which is
    /// already its normalized text. None for anything else, which
    /// [`Parser::number`] reads (and rejects) as before.
    fn plain_number(&mut self) -> Option<Number> {
        let start = self.pos;
        let end = start + plain_decimal(&self.b[start..])?;
        if matches!(self.b.get(end), Some(&c) if is_ident(c) || c == b'.')
            || end - start > self.limits.max_number_length
        {
            return None;
        }
        self.pos = end;
        Some(Number::from_normalized(self.src[start..end].to_owned()))
    }

    /// `0x…` or `0b…` at `i`: the radix and where the literal ends.
    fn radix_literal(&self, i: usize) -> Option<(u32, usize)> {
        let radix = match (self.b.get(i), self.b.get(i + 1)) {
            (Some(b'0'), Some(b'x')) => 16,
            (Some(b'0'), Some(b'b')) => 2,
            _ => return None,
        };
        let end = self.digits(i + 2, |c| (c as char).is_digit(radix))?;
        Some((radix, end))
    }

    /// `d ('_'? d)*` at `i`: where it ends, or None without a first digit.
    fn digits(&self, i: usize, is: impl Fn(u8) -> bool) -> Option<usize> {
        if !matches!(self.b.get(i), Some(&c) if is(c)) {
            return None;
        }
        let mut j = i + 1;
        loop {
            match self.b.get(j) {
                Some(&c) if is(c) => j += 1,
                Some(b'_') if matches!(self.b.get(j + 1), Some(&c) if is(c)) => j += 2,
                _ => return Some(j),
            }
        }
    }

    /// `-?(0|[1-9]('_'?d)*)(.d('_'?d)*)?([eE][+-]?d('_'?d)*)?` at `i`: where it ends.
    fn decimal_literal(&self, mut i: usize) -> Option<usize> {
        let digit = |c: u8| c.is_ascii_digit();
        if self.b.get(i) == Some(&b'-') {
            i += 1;
        }
        i = match self.b.get(i) {
            Some(b'0') => i + 1,
            Some(b'1'..=b'9') => self.digits(i, digit)?,
            _ => return None,
        };
        if self.b.get(i) == Some(&b'.')
            && let Some(end) = self.digits(i + 1, digit)
        {
            i = end;
        }
        if matches!(self.b.get(i), Some(b'e' | b'E')) {
            let sign = usize::from(matches!(self.b.get(i + 1), Some(b'+' | b'-')));
            if let Some(end) = self.digits(i + 1 + sign, digit) {
                i = end;
            }
        }
        Some(i)
    }

    /// The literal at `start..end` (in `radix`, None for decimal) is within
    /// the number limits: its length, then a hex literal's hex digits or a
    /// decimal's exponent. Checked before converting, so huge literals are
    /// rejected cheaply.
    fn check_number_limits(&self, start: usize, end: usize, radix: Option<u32>) -> R<()> {
        if end - start > self.limits.max_number_length {
            let reason = format!("number literal longer than {} characters", self.limits.max_number_length);
            return Err(self.fail_at(start, Code::NumberTooLong, reason));
        }
        if radix == Some(16) {
            // After `-0x` or `0x`; leading zeros count, separators don't.
            let digits = self.src[start..end].bytes().skip_while(|&c| c != b'x').filter(|c| c.is_ascii_hexdigit());
            if digits.count() > self.max_hex_digits {
                let reason = format!("hex literal with more than {} hex digits", self.max_hex_digits);
                return Err(self.fail_at(start, Code::NumberTooLong, reason));
            }
        }
        if let Some(exp) = decimal_exponent(&self.src[start..end]).filter(|_| radix.is_none()) {
            let digits: String = exp.chars().filter(|&c| c != '_').collect();
            if self.limits.exponent_exceeds(digits.trim_start_matches('0')) {
                let reason = format!("exponent larger than {}", self.limits.max_exponent);
                return Err(self.fail_at(start, Code::ExponentTooLarge, reason));
            }
        }
        Ok(())
    }

    // ── bytes ──────────────────────────────────────────────────

    /// `x"0b34 ff"`: two hex digits per byte; spaces and tabs between bytes.
    fn bytes(&mut self) -> R<Value> {
        let open = self.pos;
        self.pos += 2; // x"
        let mut out = Vec::new();
        loop {
            let Some(c) = self.peek() else {
                return Err(self.fail_at(open, Code::UnterminatedBytes, "unterminated byte string"));
            };
            match c {
                b'"' => break,
                b' ' | b'\t' => {
                    self.pos += 1;
                    continue;
                }
                _ => {}
            }
            let Some(hi) = hex_value(c) else {
                return Err(self.fail(
                    Code::BytesNotHex,
                    if c == b'\n' || c == b'\r' {
                        "line break in byte string (keep x\"…\" on one line)".to_owned()
                    } else {
                        format!("invalid character {} in byte string (expected hex digits)", describe(self.peek_char()))
                    },
                ));
            };
            let Some(lo) = self.at(1).and_then(hex_value) else {
                // A digit at the end of the input: unterminated, reported at the start (like the reference).
                if self.at(1).is_none() {
                    return Err(self.fail_at(open, Code::UnterminatedBytes, "unterminated byte string"));
                }
                return Err(self.fail(
                    Code::BytesOddDigits,
                    "a byte needs two hex digits (an odd number of digits, or a space inside a byte)",
                ));
            };
            out.push(hi * 16 + lo);
            self.pos += 2;
            if self.pos - open - 2 > self.limits.max_string_length {
                let reason = format!("byte string longer than {} characters", self.limits.max_string_length);
                return Err(self.fail_at(open, Code::StringTooLong, reason));
            }
        }
        self.pos += 1; // "
        Ok(Value::Bytes(out))
    }

    // ── strings ────────────────────────────────────────────────

    fn basic_string(&mut self) -> R<String> {
        self.string().map(Cow::into_owned)
    }

    /// A `"…"` string: borrowed from the source when it has no escapes.
    fn string(&mut self) -> R<Cow<'a, str>> {
        let open = self.pos;
        self.pos += 1; // "
        let mut chunk = self.pos;
        let mut out = String::new();
        loop {
            self.pos = self.plain(self.pos)?;
            match self.peek() {
                Some(b'"') => break,
                Some(_) => {
                    // A backslash.
                    out.push_str(&self.src[chunk..self.pos]);
                    out.push(self.escape()?);
                    chunk = self.pos;
                }
                None => return Err(self.fail_at(open, Code::UnterminatedString, "unterminated string")),
            }
        }
        let text = match chunk == open + 1 {
            true => Cow::Borrowed(&self.src[chunk..self.pos]),
            false => {
                out.push_str(&self.src[chunk..self.pos]);
                Cow::Owned(out)
            }
        };
        self.pos += 1; // "
        self.check_length(text, open, Code::StringTooLong)
    }

    /// The plain text of a string from `i`: where it ends, at a quote, a
    /// backslash or the end of the input; an error at a character a string
    /// can't hold raw.
    fn plain(&self, mut i: usize) -> R<usize> {
        loop {
            match next_special(self.src, i) {
                None => return Ok(self.b.len()),
                Some((at, Special::Quote | Special::Backslash)) => return Ok(at),
                // Taken raw (the writers escape them).
                Some((at, special @ Special::LineSeparator)) => i = at + special.width(),
                Some((at, Special::Control | Special::C1 | Special::Bidi)) => return Err(self.raw_char_error(at)),
            }
        }
    }

    /// The error for the character at `i` of a string, which a string can't hold raw.
    #[cold]
    #[inline(never)]
    fn raw_char_error(&self, i: usize) -> Error {
        match self.src[i..].chars().next().unwrap_or_default() {
            '\n' => self.fail_at(i, Code::StringLineBreak, "line break in string (use \\n or a \"\"\" block string)"),
            '\t' => self.fail_at(i, Code::ControlCharacter, "raw tab in string (use \\t)"),
            c if is_bidi(c) => self.fail_at(i, Code::BidiControl, bidi_message(c)),
            c => self.fail_at(i, Code::ControlCharacter, control_message(c, "string")),
        }
    }

    /// At a backslash: consumes the escape and returns its character.
    fn escape(&mut self) -> R<char> {
        let start = self.pos;
        let e = self.at(1);
        self.pos += 2;
        Ok(match e {
            Some(b'"') => '"',
            Some(b'\\') => '\\',
            Some(b'n') => '\n',
            Some(b'r') => '\r',
            Some(b't') => '\t',
            Some(b'u') => {
                let bad = || {
                    let reason = "invalid unicode escape: expected \\u{1-6 hex digits}";
                    Error::at(self.src, start, Code::InvalidUnicodeEscape, reason)
                };
                if self.peek() != Some(b'{') {
                    return Err(bad());
                }
                let digits = self.b[self.pos + 1..].iter().take_while(|c| c.is_ascii_hexdigit()).count();
                if !(1..=6).contains(&digits) || self.b.get(self.pos + 1 + digits) != Some(&b'}') {
                    return Err(bad());
                }
                let hex = &self.src[self.pos + 1..self.pos + 1 + digits];
                let Some(c) = char::from_u32(u32::from_str_radix(hex, 16).unwrap_or(u32::MAX)) else {
                    let reason = format!("\\u{{{hex}}} is not a Unicode scalar value");
                    return Err(self.fail_at(start, Code::InvalidUnicodeEscape, reason));
                };
                self.pos += digits + 2;
                c
            }
            _ => {
                let e = self.src[start + 1..].chars().next().map(String::from).unwrap_or_default();
                return Err(self.fail_at(
                    start,
                    Code::InvalidEscape,
                    format!("invalid escape '{}'", shown(&format!("\\{e}"))),
                ));
            }
        })
    }

    fn block_string(&mut self) -> R<String> {
        let open = self.pos;
        self.pos += 3;
        while matches!(self.peek(), Some(b' ' | b'\t')) {
            self.pos += 1;
        }
        if self.b[self.pos..].starts_with(b"\r\n") {
            self.pos += 2;
        } else if self.peek() == Some(b'\n') {
            self.pos += 1;
        } else {
            // At the first character after the quotes and their blanks, or the end of the input (spec §8).
            return Err(self.fail_at(
                self.pos,
                Code::BlockStringOpening,
                "opening \"\"\" must be followed by a line break",
            ));
        }

        // Find the closing """, skipping escaped characters.
        let content = self.pos;
        let mut close = None;
        let mut i = content;
        while i < self.b.len() {
            match self.b[i] {
                b'\\' => i += 1,
                b'"' if self.b[i..].starts_with(b"\"\"\"") => {
                    close = Some(i);
                    break;
                }
                _ => {}
            }
            i += 1;
        }
        let Some(close) = close else {
            return Err(self.fail_at(open, Code::UnterminatedBlockString, "unterminated block string"));
        };

        // Lines, with where each starts.
        let mut lines: Vec<(usize, &str)> = Vec::new();
        let mut at = content;
        loop {
            match self.src[at..close].find('\n') {
                None => {
                    lines.push((at, &self.src[at..close]));
                    break;
                }
                Some(n) => {
                    let nl = at + n;
                    let end = if nl > at && self.b[nl - 1] == b'\r' { nl - 1 } else { nl };
                    lines.push((at, &self.src[at..end]));
                    at = nl + 1;
                }
            }
        }
        let (_, indent) = lines.pop().unwrap_or_default();
        if !is_blank(indent) {
            return Err(self.fail_at(close, Code::BlockStringClosing, "closing \"\"\" must be on its own line"));
        }

        let mut out = Vec::with_capacity(lines.len());
        for (at, text) in lines {
            if let Some(rest) = text.strip_prefix(indent) {
                out.push(self.block_line(rest, at + indent.len())?);
            } else if is_blank(text) {
                out.push(String::new());
            } else {
                return Err(self.fail_at(at, Code::BlockStringIndent, "line is indented less than the closing \"\"\""));
            }
        }
        self.pos = close + 3;
        self.check_length(out.join("\n"), open, Code::StringTooLong)
    }

    /// Escapes in one block-string line, which starts at `at` in the source.
    fn block_line(&mut self, text: &str, at: usize) -> R<String> {
        let mut out = String::new();
        let saved = self.pos;
        let (mut i, mut chunk) = (0, 0);
        while i < text.len() {
            let c = text.as_bytes()[i];
            if c == b'\\' {
                out.push_str(&text[chunk..i]);
                self.pos = at + i;
                out.push(self.escape()?);
                i = self.pos - at;
                chunk = i;
            } else if (c < 0x20 || c == 0x7F) && c != b'\t' {
                return Err(self.fail_at(at + i, Code::ControlCharacter, control_message(c as char, "block string")));
            } else if c >= 0x80 {
                let ch = text[i..].chars().next().unwrap_or_default();
                if is_bidi(ch) {
                    return Err(self.fail_at(at + i, Code::BidiControl, bidi_message(ch)));
                }
                if is_control(ch) {
                    return Err(self.fail_at(at + i, Code::ControlCharacter, control_message(ch, "block string")));
                }
                i += ch.len_utf8();
            } else {
                i += 1;
            }
        }
        self.pos = saved;
        out.push_str(&text[chunk..]);
        Ok(out)
    }

    /// `s`, a string, key or tag (`code` says which) that starts at `open`,
    /// if it is within the string limit (spec §7).
    fn check_length<S: AsRef<str>>(&self, s: S, open: usize, code: Code) -> R<S> {
        let (text, max) = (s.as_ref(), self.limits.max_string_length);
        // Bytes bound code points from above: count only when it could matter.
        if text.len() > max && text.chars().count() > max {
            let what = match code {
                Code::KeyTooLong => "key",
                Code::TagTooLong => "tag",
                _ => "string",
            };
            return Err(self.fail_at(open, code, format!("{what} longer than {max} characters")));
        }
        Ok(s)
    }

    // ── trivia & helpers ───────────────────────────────────────

    /// Whitespace and comments, if any: most tokens have none before them.
    #[inline]
    fn trivia(&mut self) -> R<()> {
        match self.peek() {
            Some(b' ' | b'\t' | b'\n' | b'\r' | b'/') => self.more_trivia(),
            _ => Ok(()),
        }
    }

    fn more_trivia(&mut self) -> R<()> {
        loop {
            match (self.peek(), self.at(1)) {
                (Some(b' ' | b'\t' | b'\n'), _) => self.pos += 1,
                (Some(b'\r'), Some(b'\n')) => self.pos += 2,
                (Some(b'\r'), _) => {
                    let reason = "carriage return without a line feed (line breaks are LF or CRLF)";
                    return Err(self.fail(Code::LoneCarriageReturn, reason));
                }
                (Some(b'/'), Some(b'/')) => {
                    let end = self.src[self.pos..].find('\n').map_or(self.b.len(), |n| self.pos + n);
                    self.check_comment(self.pos, end)?;
                    self.pos = end;
                }
                (Some(b'/'), Some(b'*')) => self.block_comment()?,
                (Some(b'/'), _) => return Err(self.fail(Code::StraySlash, "unexpected '/' (comments are // or /* */)")),
                _ => return Ok(()),
            }
        }
    }

    fn block_comment(&mut self) -> R<()> {
        let open = self.pos;
        let mut depth = 0;
        while self.pos < self.b.len() {
            let rest = &self.b[self.pos..];
            if rest.starts_with(b"/*") {
                depth += 1;
                self.pos += 2;
            } else if rest.starts_with(b"*/") {
                self.pos += 2;
                depth -= 1;
                if depth == 0 {
                    return self.check_comment(open, self.pos);
                }
            } else {
                self.pos += 1;
            }
        }
        Err(self.fail_at(open, Code::UnterminatedComment, "unterminated block comment"))
    }

    /// Comments are where "Trojan Source" attacks hide reordered text, and where control
    /// characters (ESC, CSI, NUL) can rewrite what a terminal shows. Allowed: tab, and in
    /// block comments line breaks (CR only before LF).
    fn check_comment(&self, start: usize, end: usize) -> R<()> {
        let text = &self.src[start..end];
        let bad = text.char_indices().find(|&(i, c)| {
            is_bidi(c)
                || (is_control(c)
                    && c != '\t'
                    && c != '\n'
                    && !(c == '\r' && self.src[start + i + 1..].starts_with('\n')))
        });
        match bad {
            Some((i, c)) if is_bidi(c) => {
                let reason = format!("raw bidirectional control character U+{:04X} in comment", c as u32);
                Err(self.fail_at(start + i, Code::BidiControl, reason))
            }
            Some((i, '\r')) => {
                let reason = "carriage return without a line feed (line breaks are LF or CRLF)";
                Err(self.fail_at(start + i, Code::LoneCarriageReturn, reason))
            }
            Some((i, c)) => {
                let reason = format!("raw control character U+{:04X} in comment", c as u32);
                Err(self.fail_at(start + i, Code::ControlCharacter, reason))
            }
            None => Ok(()),
        }
    }

    /// An identifier key or a tag (`code`: the error if it is too long), within the string limit.
    fn name(&mut self, code: Code) -> R<&'a str> {
        let start = self.pos;
        let word = self.ident();
        self.check_length(word, start, code)
    }

    fn ident(&mut self) -> &'a str {
        let start = self.pos;
        self.pos = ident_end(self.b, start);
        &self.src[start..self.pos]
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.pos).copied()
    }
    fn at(&self, n: usize) -> Option<u8> {
        self.b.get(self.pos + n).copied()
    }
    fn peek_char(&self) -> Option<char> {
        self.src.get(self.pos..).and_then(|s| s.chars().next())
    }
    fn eof(&self) -> bool {
        self.pos >= self.b.len()
    }

    fn fail(&self, code: Code, reason: impl Into<String>) -> Error {
        Error::at(self.src, self.pos, code, reason)
    }
    fn fail_at(&self, at: usize, code: Code, reason: impl Into<String>) -> Error {
        Error::at(self.src, at, code, reason)
    }
}

fn control_message(c: char, place: &str) -> String {
    let code = c as u32;
    format!("raw control character U+{code:04X} in {place} (write it as \\u{{{code:04X}}})")
}

fn bidi_message(c: char) -> String {
    let code = c as u32;
    format!("raw bidirectional control character U+{code:04X} (write it as \\u{{{code:04X}}})")
}

/// The exponent digits of a decimal literal with an exponent
/// (`-?(0|[1-9][0-9_]*)(\.[0-9_]+)?[eE][+-]?[0-9_]+`), or None.
fn decimal_exponent(s: &str) -> Option<&str> {
    let s = s.strip_prefix('-').unwrap_or(s);
    let e = s.find(['e', 'E'])?;
    let (mantissa, exp) = (&s[..e], &s[e + 1..]);
    let (int, frac) = match mantissa.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (mantissa, None),
    };
    let digits_ = |t: &str| !t.is_empty() && t.bytes().all(|c| c.is_ascii_digit() || c == b'_');
    let int_ok = int == "0" || (int.starts_with(|c: char| ('1'..='9').contains(&c)) && digits_(int));
    let exp = exp.strip_prefix(['+', '-']).unwrap_or(exp);
    (int_ok && frac.is_none_or(digits_) && digits_(exp)).then_some(exp)
}

/// Digits in base 2 or 16 as a decimal integer string.
fn to_decimal(digits: &[u8], radix: u32) -> String {
    // Little-endian limbs of base 10^9.
    let mut limbs: Vec<u64> = vec![0];
    for &d in digits {
        let mut carry = u64::from((d as char).to_digit(radix).unwrap_or(0));
        for limb in &mut limbs {
            let v = *limb * u64::from(radix) + carry;
            *limb = v % 1_000_000_000;
            carry = v / 1_000_000_000;
        }
        if carry > 0 {
            limbs.push(carry);
        }
    }
    // The most significant limb as is, the others padded to 9 digits.
    let first = limbs.last().copied().unwrap_or(0).to_string();
    limbs.iter().rev().skip(1).fold(first, |mut out, limb| {
        let _ = write!(out, "{limb:09}");
        out
    })
}

/// The exponent of a decimal literal as its value (§2): `1e+05` is `1e5`, `1e-0` is `1e0`.
pub(crate) fn normalize_exponent(text: String) -> String {
    let Some(at) = text.find('e') else { return text };
    let (mantissa, exponent) = text.split_at(at + 1);
    let negative = exponent.starts_with('-');
    let digits = exponent.trim_start_matches(['+', '-']).trim_start_matches('0');
    let digits = if digits.is_empty() { "0" } else { digits };
    format!("{mantissa}{}{digits}", if negative && digits != "0" { "-" } else { "" })
}

#[cfg(test)]
mod tests {
    use crate::parse;

    #[test]
    fn a_version_directive_needs_a_newer_version() {
        let newer = "the file starts with a version directive (#haus): it needs a newer version of haus";
        for text in ["#haus 2\n{ a: 1 }", "\u{FEFF}#haus 2\n1"] {
            let e = parse(text).unwrap_err();
            assert_eq!((e.reason.as_str(), e.line), (newer, 1), "{text:?}");
        }
        let stream = crate::stream::values("#haus 2\n1,\n".as_bytes()).next().unwrap().unwrap_err();
        assert!(stream.to_string().contains("needs a newer version of haus"), "{stream}");
        // Anywhere else, or another `#`, is an ordinary syntax error.
        for text in [" #haus 2", "1, #haus 2", "#2"] {
            assert_eq!(parse(text).unwrap_err().reason, "expected a value, found '#'", "{text:?}");
        }
    }
}
