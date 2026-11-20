//! Recursive-descent parser over one complete piece of text: a port of the
//! TypeScript reference parser (typescript/packages/haus/src/parser.ts).

use crate::keys::Keys;
use crate::{ErrorCode as Code, SyntaxError as Error, Value};
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

/// Resource limits, enforced while parsing (spec §7).
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
    pub max_exponent: u64,
    /// Characters (code points) in one decoded string, record key or tag,
    /// or between the quotes of a byte string.
    pub max_string_length: usize,
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

    /// Why this binding can't use these limits: a depth limit above
    /// [`MAX_SUPPORTED_DEPTH`].
    pub(crate) fn unsupported(&self) -> Option<String> {
        (self.max_depth > MAX_SUPPORTED_DEPTH)
            .then(|| format!("max_depth {} is more than the supported maximum, {MAX_SUPPORTED_DEPTH}", self.max_depth))
    }
}

impl Default for Limits {
    fn default() -> Self {
        Limits { max_depth: 256, max_number_length: 1000, max_exponent: 6144, max_string_length: 16 * 1024 * 1024 }
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
pub(crate) fn number_literal(text: &str, limits: &Limits) -> Option<String> {
    let max_hex_digits = limits.max_hex_digits();
    let mut p = Parser {
        src: text,
        b: text.as_bytes(),
        pos: 0,
        depth: 0,
        limits,
        max_hex_digits,
        file_start: None,
        items: Vec::new(),
        fields: Vec::new(),
    };
    match p.number() {
        Ok(Value::Number(n)) if p.pos == text.len() => Some(n),
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

/// Bytes that end a run of plain text in a string: the closing quote, a
/// backslash, the control characters (C0 and DEL), and the lead bytes of the
/// characters a string can't hold raw (spec §4): `0xC2` starts the C1
/// controls (U+0080–U+009F), `0xE2` the bidirectional ones (and the line
/// and paragraph separators, which the writer escapes).
pub(crate) static STRING_STOP: [bool; 256] = {
    let mut t = [false; 256];
    let mut c = 0;
    while c < 0x20 {
        t[c] = true;
        c += 1;
    }
    t[b'"' as usize] = true;
    t[b'\\' as usize] = true;
    t[0x7F] = true;
    t[0xC2] = true;
    t[0xE2] = true;
    t
};

const ONES: u64 = 0x0101_0101_0101_0101;
const HIGH: u64 = 0x8080_8080_8080_8080;

/// Whether one of the eight bytes of `x` is zero.
const fn has_zero(x: u64) -> bool {
    x.wrapping_sub(ONES) & !x & HIGH != 0
}

/// Whether one of the eight bytes of `x` might end a run of plain string
/// text: not ASCII, a control character, `"`, `\\` or DEL.
const fn may_stop(x: u64) -> bool {
    x & HIGH != 0
        || x.wrapping_sub(ONES * 0x20) & HIGH != 0
        || has_zero(x ^ (ONES * b'"' as u64))
        || has_zero(x ^ (ONES * b'\\' as u64))
        || has_zero(x ^ (ONES * 0x7F))
}

/// Where the identifier bytes (`[A-Za-z0-9_]`) from `i` end: eight bytes
/// at a time, each tested for the three ranges and `_` at once.
fn ident_end(b: &[u8], mut i: usize) -> usize {
    // For bytes below 0x80 (no carry crosses a byte): the high bit of each
    // byte is set where it is at least `lo`, or within `lo..=hi`.
    let at_least = |x: u64, lo: u8| x.wrapping_add(ONES * u64::from(0x80 - lo));
    let within = |x: u64, lo: u8, hi: u8| at_least(x, lo) & !at_least(x, hi + 1);
    while let Some(chunk) = b.get(i..i + 8) {
        let x = u64::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6], chunk[7]]);
        let ascii = x & !HIGH;
        // The high bit of each byte that is `_`: set where `ascii ^ '_'` is zero.
        let underscore = ascii ^ (ONES * u64::from(b'_'));
        let is_underscore = !((underscore & !HIGH).wrapping_add(!HIGH) | underscore);
        let ident = (within(ascii, b'0', b'9') | within(ascii | (ONES * 0x20), b'a', b'z') | is_underscore) & !x & HIGH;
        let other = !ident & HIGH;
        if other != 0 {
            return i + (other.trailing_zeros() / 8) as usize;
        }
        i += 8;
    }
    i + b[i..].iter().position(|&c| !IDENT[usize::from(c)]).unwrap_or(b.len() - i)
}

/// Past the blocks of eight bytes of plain ASCII string text from `i` (see
/// [`may_stop`]), up to the first block that might hold a [`STRING_STOP`].
pub(crate) fn skip_plain_ascii(b: &[u8], mut i: usize) -> usize {
    while let Some(chunk) = b.get(i..i + 8) {
        let x = u64::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6], chunk[7]]);
        if may_stop(x) {
            break;
        }
        i += 8;
    }
    i
}

/// Raw bidirectional controls (U+202A–U+202E, U+2066–U+2069) are not allowed outside escapes.
pub(crate) fn is_bidi(c: char) -> bool {
    matches!(c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}
pub(crate) fn is_ident(c: u8) -> bool {
    IDENT[usize::from(c)]
}
/// The bytes of identifiers: `[A-Za-z0-9_]`.
static IDENT: [bool; 256] = {
    let mut t = [false; 256];
    let mut c = 0;
    while c < 256 {
        t[c] = (c as u8).is_ascii_alphanumeric() || c == b'_' as usize;
        c += 1;
    }
    t
};
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
        Some(c) => format!("'{c}'"),
    }
}

impl<'a> Parser<'a> {
    /// A parser at `pos`, if this binding supports `limits`.
    fn new(src: &'a str, limits: &'a Limits, pos: usize, file_start: Option<usize>) -> R<Parser<'a>> {
        match limits.unsupported() {
            Some(reason) => Err(Error::at(src, 0, Code::UnsupportedDepth, reason)),
            None => {
                let max_hex_digits = limits.max_hex_digits();
                Ok(Parser {
                    src,
                    b: src.as_bytes(),
                    pos,
                    depth: 0,
                    limits,
                    max_hex_digits,
                    file_start,
                    items: Vec::new(),
                    fields: Vec::new(),
                })
            }
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
                Some(n) => Ok(n),
                None => self.number(),
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
                    format!("unexpected identifier '{word}': lowercase identifiers can only be record keys{hint}"),
                )
                .with_expected_found("a value", format!("'{word}'"))
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
            let (key_pos, key) = self.field_key()?;
            let value = self.value()?;
            self.add_field(base, &mut keys, key_pos, key, value)?;
            self.separator(open, b'}', Within::Record)?;
        }
        self.pos += 1; // }
        self.depth -= 1;
        Ok(Value::Record(self.fields.drain(base..).collect()))
    }

    /// A field's key and the `:` after it, with where the key starts.
    fn field_key(&mut self) -> R<(usize, Cow<'a, str>)> {
        let key_pos = self.pos;
        let key = self.key()?;
        self.trivia()?;
        if self.peek() != Some(b':') {
            let found = describe(self.peek_char());
            return Err(self
                .fail(Code::MissingColon, format!("expected ':' after key '{key}', found {found}"))
                .with_expected_found("':'", found));
        }
        self.pos += 1;
        self.trivia()?;
        Ok((key_pos, key))
    }

    /// Adds a field to the record whose fields start at `base`, if its key
    /// is new (spec §1).
    fn add_field(&mut self, base: usize, keys: &mut Keys, key_pos: usize, key: Cow<'a, str>, value: Value) -> R<()> {
        self.fields.push((key.into_owned(), value));
        if keys.repeated(&self.fields[base..]) {
            let key = self.fields.pop().map(|(k, _)| k).unwrap_or_default();
            return Err(self.fail_at(key_pos, Code::DuplicateKey, format!("duplicate key '{key}'")));
        }
        Ok(())
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
                        format!("record keys must start with a lowercase letter or '_'; quote it: \"{word}\""),
                    )
                    .with_hint(format!("Quote the key: \"{word}\".")))
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
        Ok(Value::Variant { tag, args })
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
        self.fail_at(paren, Code::EmptyPayload, format!("empty payload: write '{tag}' without parentheses"))
            .with_hint(format!("Write {tag} without parentheses."))
    }

    // ── numbers ────────────────────────────────────────────────

    /// A number: the literal (a linear scan), then what follows it, then
    /// the limits, as the reference does (a literal that runs into a letter
    /// is invalid however long it is). Converted only within the limits, so
    /// huge literals stay cheap.
    fn number(&mut self) -> R<Value> {
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
            return Err(self.fail_at(start, Code::InvalidNumber, format!("invalid number '{}'", &self.src[start..to])));
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
        Ok(Value::Number(text))
    }

    /// The common case of [`Parser::number`], in one pass: a decimal
    /// literal without separators or exponent (`-12`, `0.5`), within the
    /// length limit and not running into a letter, digit or `.`, which is
    /// already its normalized text. None for anything else, which
    /// [`Parser::number`] reads (and rejects) as before.
    fn plain_number(&mut self) -> Option<Value> {
        let start = self.pos;
        let end = start + plain_decimal(&self.b[start..])?;
        if matches!(self.b.get(end), Some(&c) if is_ident(c) || c == b'.')
            || end - start > self.limits.max_number_length
        {
            return None;
        }
        self.pos = end;
        Some(Value::Number(self.src[start..end].to_owned()))
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
            let digits = digits.trim_start_matches('0');
            if digits.len() > 19 || digits.parse::<u64>().unwrap_or(0) > self.limits.max_exponent {
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
    /// can't hold raw. Eight ASCII bytes at a time where it can.
    fn plain(&self, mut i: usize) -> R<usize> {
        let b = self.b;
        loop {
            i = skip_plain_ascii(b, i);
            // Then at most eight bytes, one at a time, up to the next stop.
            let end = (i + 8).min(b.len());
            while i < end && !STRING_STOP[usize::from(b[i])] {
                i += 1;
            }
            match b.get(i) {
                None | Some(b'"' | b'\\') => return Ok(i),
                Some(&c) if STRING_STOP[usize::from(c)] => i = self.raw_special(i, c)?,
                Some(_) => {}
            }
        }
    }

    /// At a stop byte `c` (at `i`) other than a quote or a backslash: an
    /// error for a raw control or bidirectional character, or where the
    /// next character starts.
    fn raw_special(&self, i: usize, c: u8) -> R<usize> {
        let next = |n: usize| self.b.get(i + n).copied().unwrap_or(0);
        match c {
            0xC2 if (0x80..=0x9F).contains(&next(1)) => Err(self.raw_char_error(i)),
            0xE2 if matches!((next(1), next(2)), (0x80, 0xAA..=0xAE) | (0x81, 0xA6..=0xA9)) => {
                Err(self.raw_char_error(i))
            }
            0xC2 | 0xE2 => Ok(i + 1),
            _ => Err(self.raw_char_error(i)),
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
                return Err(self.fail_at(start, Code::InvalidEscape, format!("invalid escape '\\{e}'")));
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
            let at = if self.eof() { open } else { self.pos };
            return Err(self.fail_at(at, Code::BlockStringOpening, "opening \"\"\" must be followed by a line break"));
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

/// A raw control character: C0, DEL or C1 (spec §4).
pub(crate) fn is_control(c: char) -> bool {
    matches!(c as u32, 0..0x20 | 0x7F..=0x9F)
}

fn control_message(c: char, place: &str) -> String {
    let code = c as u32;
    format!("raw control character U+{code:04X} in {place} (write it as \\u{{{code:04X}}})")
}

fn bidi_message(c: char) -> String {
    let code = c as u32;
    format!("raw bidirectional control character U+{code:04X} (write it as \\u{{{code:04X}}})")
}

/// The length of the decimal literal without separators or exponent at the
/// start of `b`, `-?(0|[1-9][0-9]*)(.[0-9]+)?`, if there is one: the
/// literal is then normalized (spec §2).
pub(crate) fn plain_decimal(b: &[u8]) -> Option<usize> {
    let digits = |mut i: usize| {
        while matches!(b.get(i), Some(b'0'..=b'9')) {
            i += 1;
        }
        i
    };
    let mut i = usize::from(b.first() == Some(&b'-'));
    i = match b.get(i) {
        Some(b'0') => i + 1,
        Some(b'1'..=b'9') => digits(i + 1),
        _ => return None,
    };
    if b.get(i) == Some(&b'.') {
        let fraction = i + 1;
        i = digits(fraction);
        if i == fraction {
            return None;
        }
    }
    Some(i)
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
