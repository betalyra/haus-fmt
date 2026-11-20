//! Scanning bytes, for the parser and the writers: identifiers, the plain
//! text of strings and the characters that end it, plain decimals. Eight
//! bytes at a time where that pays: a word of eight bytes is tested for a
//! byte of interest with a few arithmetic operations.

use std::ops::RangeInclusive;

// ── characters a string can't hold raw (spec §4) ────────────────

/// The C0 control characters, U+0000–U+001F: one byte each in UTF-8.
const C0_CONTROLS: RangeInclusive<char> = '\u{0}'..='\u{1F}';
/// DEL, U+007F: one byte.
const DEL: char = '\u{7F}';
/// The C1 control characters, U+0080–U+009F: `C2 80`–`C2 9F` in UTF-8.
const C1_CONTROLS: RangeInclusive<char> = '\u{80}'..='\u{9F}';
/// The line and paragraph separators, U+2028 and U+2029: `E2 80 A8` and
/// `E2 80 A9`. The parser takes them raw; the writers escape them.
const LINE_SEPARATORS: RangeInclusive<char> = '\u{2028}'..='\u{2029}';
/// The bidirectional embeddings and overrides, U+202A–U+202E: `E2 80 AA`–`E2 80 AE`.
const BIDI_EMBEDDINGS: RangeInclusive<char> = '\u{202A}'..='\u{202E}';
/// The bidirectional isolates, U+2066–U+2069: `E2 81 A6`–`E2 81 A9`.
const BIDI_ISOLATES: RangeInclusive<char> = '\u{2066}'..='\u{2069}';

/// A raw control character: C0, DEL or C1 (spec §4).
pub(crate) fn is_control(c: char) -> bool {
    C0_CONTROLS.contains(&c) || c == DEL || C1_CONTROLS.contains(&c)
}

/// A bidirectional control (U+202A–U+202E, U+2066–U+2069): not allowed raw outside escapes.
pub(crate) fn is_bidi(c: char) -> bool {
    BIDI_EMBEDDINGS.contains(&c) || BIDI_ISOLATES.contains(&c)
}

/// A character that ends a run of plain string text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Special {
    /// `"`, which closes the string.
    Quote,
    /// `\`, which starts an escape.
    Backslash,
    /// A C0 control character or DEL (line feed and tab included).
    Control,
    /// A C1 control character.
    C1,
    /// A bidirectional control.
    Bidi,
    /// The line or paragraph separator.
    LineSeparator,
}

impl Special {
    /// Its length in UTF-8.
    pub(crate) const fn width(self) -> usize {
        match self {
            Special::Quote | Special::Backslash | Special::Control => 1,
            Special::C1 => 2,
            Special::Bidi | Special::LineSeparator => 3,
        }
    }

    /// Which special character `c` is, if it is one.
    fn of(c: char) -> Option<Special> {
        match c {
            '"' => Some(Special::Quote),
            '\\' => Some(Special::Backslash),
            c if C0_CONTROLS.contains(&c) || c == DEL => Some(Special::Control),
            c if C1_CONTROLS.contains(&c) => Some(Special::C1),
            c if LINE_SEPARATORS.contains(&c) => Some(Special::LineSeparator),
            c if is_bidi(c) => Some(Special::Bidi),
            _ => None,
        }
    }
}

/// The first byte of a character in UTF-8.
const fn first_byte(c: char) -> usize {
    let mut utf8 = [0; 4];
    c.encode_utf8(&mut utf8);
    utf8[0] as usize
}

/// The first bytes of the [`Special`] characters: `"`, `\`, the C0 controls
/// and DEL themselves, and the lead bytes of the others (`C2` of
/// U+0080–U+00BF, `E2` of U+2000–U+2FFF). Plain text has none of them but
/// as the start of another character of those two blocks (`°`, `—`, `€`).
static STRING_STOP: [bool; 256] = {
    let mut t = [false; 256];
    let mut c = 0;
    while c <= *C0_CONTROLS.end() as usize {
        t[c] = true;
        c += 1;
    }
    t[b'"' as usize] = true;
    t[b'\\' as usize] = true;
    t[DEL as usize] = true;
    t[first_byte(*C1_CONTROLS.start())] = true;
    t[first_byte(*LINE_SEPARATORS.start())] = true;
    t[first_byte(*BIDI_EMBEDDINGS.start())] = true;
    t[first_byte(*BIDI_ISOLATES.start())] = true;
    t
};

/// The next [`Special`] character of the string text `s` from `i` (where a
/// character starts): where it is and which one, or None if there is none
/// before the end of `s`.
#[inline]
pub(crate) fn next_special(s: &str, mut i: usize) -> Option<(usize, Special)> {
    let b = s.as_bytes();
    loop {
        i = skip_plain_ascii(b, i);
        // Then at most eight bytes, one at a time, up to the next stop byte.
        let end = (i + 8).min(b.len());
        while i < end && !STRING_STOP[usize::from(b[i])] {
            i += 1;
        }
        let &c = b.get(i)?;
        if STRING_STOP[usize::from(c)] {
            // `s` is UTF-8: a whole character starts at a stop byte.
            match s[i..].chars().next().and_then(Special::of) {
                Some(special) => return Some((i, special)),
                // Another character of the block: its other bytes are no stop.
                None => i += 1,
            }
        }
    }
}

// ── eight bytes at a time ───────────────────────────────────────

/// A one in each byte of a word.
const ONES: u64 = 0x0101_0101_0101_0101;
/// The high bit of each byte of a word.
const HIGH: u64 = 0x8080_8080_8080_8080;

/// The eight bytes of `b` at `i`, as a little-endian word (the first byte
/// lowest), if there are eight.
#[inline]
fn word_at(b: &[u8], i: usize) -> Option<u64> {
    b.get(i..)?.first_chunk().map(|chunk| u64::from_le_bytes(*chunk))
}

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
        || has_zero(x ^ (ONES * DEL as u64))
}

/// Past the blocks of eight bytes of plain ASCII string text from `i` (see
/// [`may_stop`]), up to the first block that might hold a stop byte.
pub(crate) fn skip_plain_ascii(b: &[u8], mut i: usize) -> usize {
    while let Some(x) = word_at(b, i) {
        if may_stop(x) {
            break;
        }
        i += 8;
    }
    i
}

// ── identifiers ─────────────────────────────────────────────────

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

/// Whether `c` is a byte of identifiers: `[A-Za-z0-9_]`.
pub(crate) fn is_ident(c: u8) -> bool {
    IDENT[usize::from(c)]
}

/// Where the identifier bytes (`[A-Za-z0-9_]`) from `i` end: eight bytes
/// at a time, each tested for the three ranges and `_` at once.
pub(crate) fn ident_end(b: &[u8], mut i: usize) -> usize {
    // For bytes below 0x80 (no carry crosses a byte): the high bit of each
    // byte is set where it is at least `lo`, or within `lo..=hi`.
    let at_least = |x: u64, lo: u8| x.wrapping_add(ONES * u64::from(0x80 - lo));
    let within = |x: u64, lo: u8, hi: u8| at_least(x, lo) & !at_least(x, hi + 1);
    while let Some(x) = word_at(b, i) {
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
    i + b[i..].iter().position(|&c| !is_ident(c)).unwrap_or(b.len() - i)
}

// ── numbers ─────────────────────────────────────────────────────

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

#[cfg(test)]
mod tests {
    use super::{Special, ident_end, is_bidi, is_control, next_special, plain_decimal, skip_plain_ascii};

    /// A fixed sequence of numbers below `n` (xorshift).
    fn numbers() -> impl FnMut(usize) -> usize {
        let mut state = 0x2545_f491_4f6c_dd1d_u64;
        move |n| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state % n as u64) as usize
        }
    }

    /// Texts of up to 40 characters from `alphabet`, many of them.
    fn texts(alphabet: &[char]) -> impl Iterator<Item = String> {
        let mut next = numbers();
        std::iter::repeat_with(move || {
            let n = next(41);
            (0..n).map(|_| alphabet[next(alphabet.len())]).collect()
        })
        .take(50_000)
    }

    #[test]
    fn ident_end_is_where_the_identifier_bytes_end() {
        let alphabet =
            ['a', 'z', 'A', 'Z', '0', '9', '_', '@', '[', '`', '{', '/', ':', ' ', '-', '.', 'é', '\u{0}', '\u{7F}'];
        for text in texts(&alphabet) {
            let b = text.as_bytes();
            for start in 0..=b.len() {
                let expected = (start..b.len()).find(|&i| !(b[i].is_ascii_alphanumeric() || b[i] == b'_'));
                assert_eq!(ident_end(b, start), expected.unwrap_or(b.len()), "{text:?} from {start}");
            }
        }
        // Every byte, alone and after a run of identifier bytes.
        for c in 0..=255u8 {
            let ident = c.is_ascii_alphanumeric() || c == b'_';
            for run in [0, 3, 7, 8, 15] {
                let mut b = vec![b'a'; run];
                b.extend([c, b'!', 0, 0, 0, 0, 0, 0, 0, 0]);
                assert_eq!(ident_end(&b, 0), run + usize::from(ident), "{c:#x} after {run}");
            }
        }
    }

    #[test]
    fn skip_plain_ascii_skips_whole_blocks_of_plain_text() {
        let alphabet = ['a', ' ', '~', '!', '"', '\\', '\n', '\u{1F}', '\u{7F}', 'é', '\u{80}', '\u{2028}'];
        let plain = |c: u8| c.is_ascii() && !c.is_ascii_control() && c != b'"' && c != b'\\';
        for text in texts(&alphabet) {
            let b = text.as_bytes();
            for start in 0..=b.len() {
                let blocks =
                    b[start..].as_chunks::<8>().0.iter().take_while(|block| block.iter().all(|&c| plain(c))).count();
                assert_eq!(skip_plain_ascii(b, start), start + 8 * blocks, "{text:?} from {start}");
            }
        }
    }

    /// [`Special`] by code point, without the byte tables.
    fn special(c: char) -> Option<Special> {
        match u32::from(c) {
            0x22 => Some(Special::Quote),
            0x5C => Some(Special::Backslash),
            0..=0x1F | 0x7F => Some(Special::Control),
            0x80..=0x9F => Some(Special::C1),
            0x2028 | 0x2029 => Some(Special::LineSeparator),
            0x202A..=0x202E | 0x2066..=0x2069 => Some(Special::Bidi),
            _ => None,
        }
    }

    #[test]
    fn next_special_finds_the_next_special_character() {
        let alphabet = [
            'a', ' ', '"', '\\', '\n', '\t', '\u{0}', '\u{7}', '\u{7F}', '\u{80}', '\u{9F}', '\u{A0}', '\u{BF}', 'é',
            '\u{2000}', '\u{2027}', '\u{2028}', '\u{2029}', '\u{202A}', '\u{202E}', '\u{202F}', '\u{2065}', '\u{2066}',
            '\u{2069}', '\u{206A}', '\u{2FFF}', '€', '中', '😀',
        ];
        for text in texts(&alphabet) {
            for (start, _) in text.char_indices().chain([(text.len(), ' ')]) {
                let expected = text[start..].char_indices().find_map(|(i, c)| Some((start + i, special(c)?)));
                assert_eq!(next_special(&text, start), expected, "{text:?} from {start}");
            }
        }
        // Every character of the blocks the lead bytes start.
        for c in ('\u{0}'..='\u{FF}').chain('\u{2000}'..='\u{2FFF}') {
            let text = format!("abcdefghij{c}abcdefghij");
            assert_eq!(next_special(&text, 0), special(c).map(|s| (10, s)), "{c:?}");
            if let Some(s) = special(c) {
                assert_eq!(s.width(), c.len_utf8());
            }
            assert_eq!(is_control(c), matches!(u32::from(c), 0..=0x1F | 0x7F..=0x9F), "{c:?}");
            assert_eq!(is_bidi(c), special(c) == Some(Special::Bidi), "{c:?}");
        }
    }

    #[test]
    fn plain_decimals() {
        for (text, len) in [
            ("0", Some(1)),
            ("-12", Some(3)),
            ("0.5,", Some(3)),
            ("12.50]", Some(5)),
            ("-0.0", Some(4)),
            ("01", Some(1)),
            ("1e5", Some(1)),
            ("1_000", Some(1)),
            ("1.", None),
            ("-", None),
            (".5", None),
            ("", None),
        ] {
            assert_eq!(plain_decimal(text.as_bytes()), len, "{text}");
        }
    }
}
