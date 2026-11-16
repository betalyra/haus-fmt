//! Colors for haus text on a terminal, with the token roles of the editor
//! grammar (editors/vscode/syntaxes/haus.tmLanguage.json): tags, keys,
//! strings and their escapes, numbers, byte strings, comments.
//!
//! Only ANSI codes are added: removing them gives back the text, character
//! for character, whatever it is. A code never spans a line break, so each
//! line can be shown on its own (`less -R`, `grep`).

use std::ops::Range;

/// What a part of the text is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Token {
    /// Whitespace, punctuation, and anything else not colored.
    Plain,
    Comment,
    /// `Order`, `Some`, `True`.
    Tag,
    /// A record key, bare or quoted, before its `:`.
    Key,
    /// A string or block string, without its escapes.
    String,
    /// `\n`, `\u{1F600}` in a string.
    Escape,
    Number,
    /// `x"9f86 d081"`.
    Bytes,
}

impl Token {
    /// The ANSI style, readable on light and dark backgrounds.
    fn style(self) -> Option<&'static str> {
        match self {
            Token::Plain => None,
            Token::Comment => Some("2"),
            Token::Tag => Some("36"),
            Token::Key => Some("34"),
            Token::String => Some("32"),
            Token::Escape => Some("1;32"),
            Token::Number => Some("33"),
            Token::Bytes => Some("35"),
        }
    }
}

/// `text` with ANSI colors.
pub fn highlight(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 2);
    for (token, range) in tokens(text) {
        let part = &text[range];
        let Some(style) = token.style() else {
            out.push_str(part);
            continue;
        };
        for (i, line) in part.split('\n').enumerate() {
            if i > 0 {
                out.push('\n');
            }
            if !line.is_empty() {
                out.push_str(&format!("\x1b[{style}m{line}\x1b[0m"));
            }
        }
    }
    out
}

/// The tokens of `text`, in order, together covering all of it.
pub fn tokens(text: &str) -> Vec<(Token, Range<usize>)> {
    let mut lexer = Lexer { text, at: 0, out: Vec::new() };
    while lexer.at < text.len() {
        lexer.token();
    }
    lexer.out
}

struct Lexer<'t> {
    text: &'t str,
    at: usize,
    out: Vec<(Token, Range<usize>)>,
}

impl<'t> Lexer<'t> {
    fn rest(&self) -> &'t str {
        &self.text[self.at..]
    }

    /// The next `len` bytes are a `token`.
    fn emit(&mut self, token: Token, len: usize) {
        let end = self.at + len;
        match self.out.last_mut() {
            _ if len == 0 => {}
            Some((last, range)) if *last == token && range.end == self.at => range.end = end,
            _ => self.out.push((token, self.at..end)),
        }
        self.at = end;
    }

    /// The length of the start of the rest whose characters `f` accepts.
    fn span(&self, f: impl Fn(char) -> bool) -> usize {
        self.rest().find(|c| !f(c)).unwrap_or(self.rest().len())
    }

    fn token(&mut self) {
        let rest = self.rest();
        let c = rest.chars().next().unwrap_or_default();
        if rest.starts_with("//") {
            let len = rest.find('\n').unwrap_or(rest.len());
            self.emit(Token::Comment, len);
        } else if rest.starts_with("/*") {
            let len = block_comment(rest);
            self.emit(Token::Comment, len);
        } else if rest.starts_with("\"\"\"") {
            self.emit(Token::String, 3);
            self.string("\"\"\"");
        } else if c == '"' {
            let len = quoted(rest);
            if is_key(&rest[len..]) {
                self.emit(Token::Key, len);
            } else {
                self.emit(Token::String, 1);
                self.string("\"");
            }
        } else if let Some(bytes) = rest.strip_prefix("x\"") {
            let len = match bytes.find(['"', '\n']) {
                Some(i) if bytes[i..].starts_with('"') => 2 + i + 1,
                Some(i) => 2 + i,
                None => rest.len(),
            };
            self.emit(Token::Bytes, len);
        } else if c.is_ascii_digit() || (c == '-' && rest[1..].starts_with(|c: char| c.is_ascii_digit())) {
            let len = number(rest);
            self.emit(Token::Number, len);
        } else if c.is_ascii_uppercase() {
            let len = self.span(is_word);
            self.emit(Token::Tag, len);
        } else if c.is_ascii_lowercase() || c == '_' {
            let len = self.span(is_word);
            let token = if is_key(&rest[len..]) { Token::Key } else { Token::Plain };
            self.emit(token, len);
        } else {
            self.emit(Token::Plain, c.len_utf8());
        }
    }

    /// The rest of a string after its opening quote, up to and with `close`:
    /// its text and its escapes. A basic string also ends at a line break.
    fn string(&mut self, close: &str) {
        loop {
            let rest = self.rest();
            let stop = rest.find(|c| c == '\\' || c == '"' || (c == '\n' && close == "\"")).unwrap_or(rest.len());
            self.emit(Token::String, stop);
            let rest = self.rest();
            if rest.is_empty() || rest.starts_with('\n') {
                return;
            }
            if rest.starts_with(close) {
                self.emit(Token::String, close.len());
                return;
            }
            if rest.starts_with('"') {
                self.emit(Token::String, 1);
                continue;
            }
            self.emit(Token::Escape, escape(rest));
        }
    }
}

fn is_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// Whether a `:` follows, after spaces and tabs: what comes before is a key.
fn is_key(after: &str) -> bool {
    after.trim_start_matches([' ', '\t']).starts_with(':')
}

/// The length of the basic string at the start of `s`, closing quote included
/// (up to the end of the line if it isn't closed).
fn quoted(s: &str) -> usize {
    let mut chars = s.char_indices().skip(1);
    while let Some((i, c)) = chars.next() {
        match c {
            '"' => return i + 1,
            '\n' => return i,
            '\\' => {
                chars.next();
            }
            _ => {}
        }
    }
    s.len()
}

/// The length of the escape at the start of `s`: `\n`, or `\u{…}`.
fn escape(s: &str) -> usize {
    let mut chars = s.chars().skip(1);
    match chars.next() {
        None => 1,
        Some('u') if s[2..].starts_with('{') => {
            let digits = s[3..].find(|c: char| !c.is_ascii_hexdigit()).unwrap_or(s.len() - 3);
            3 + digits + usize::from(s[3 + digits..].starts_with('}'))
        }
        Some(c) => 1 + c.len_utf8(),
    }
}

/// The length of the (nested) block comment at the start of `s`, to its
/// last `*/`, or to the end if it isn't closed.
fn block_comment(s: &str) -> usize {
    let (mut depth, mut i) = (0usize, 0);
    while i < s.len() {
        if s[i..].starts_with("/*") {
            depth += 1;
            i += 2;
        } else if s[i..].starts_with("*/") {
            depth -= 1;
            i += 2;
            if depth == 0 {
                return i;
            }
        } else {
            i += s[i..].chars().next().map_or(1, char::len_utf8);
        }
    }
    s.len()
}

/// The length of the number at the start of `s`: a sign, digits, letters,
/// `_` and `.`, and a sign after a decimal exponent's `e`.
fn number(s: &str) -> usize {
    let sign = usize::from(s.starts_with('-'));
    let radix = s[sign..].starts_with(['0']) && s[sign + 1..].starts_with(['x', 'X', 'b', 'B']);
    let mut end = sign;
    let mut previous = '\0';
    for c in s[sign..].chars() {
        let exponent_sign = !radix && matches!(c, '+' | '-') && matches!(previous, 'e' | 'E');
        if !(is_word(c) || (c == '.' && !radix) || exponent_sign) {
            break;
        }
        end += c.len_utf8();
        previous = c;
    }
    end
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// `text` without its ANSI codes.
    fn strip(text: &str) -> String {
        let mut out = String::new();
        let mut rest = text;
        while let Some(i) = rest.find("\x1b[") {
            out.push_str(&rest[..i]);
            let end = rest[i..].find('m').expect("an ANSI code ends with m");
            rest = &rest[i + end + 1..];
        }
        out.push_str(rest);
        out
    }

    fn colored(token: Token, text: &str) -> String {
        format!("\x1b[{}m{text}\x1b[0m", token.style().unwrap())
    }

    #[test]
    fn colors_each_role() {
        let text = r#"Order { id: 0x1F, "x-y": 1.5e-3, note: "a\n\u{1F600}b", raw: x"9f86 d081", ok: True } // c"#;
        let out = highlight(text);
        assert_eq!(strip(&out), text);
        for (token, part) in [
            (Token::Tag, "Order"),
            (Token::Key, "id"),
            (Token::Number, "0x1F"),
            (Token::Key, "\"x-y\""),
            (Token::Number, "1.5e-3"),
            (Token::String, "\"a"),
            (Token::Escape, "\\n\\u{1F600}"),
            (Token::String, "b\""),
            (Token::Bytes, "x\"9f86 d081\""),
            (Token::Tag, "True"),
            (Token::Comment, "// c"),
        ] {
            assert!(out.contains(&colored(token, part)), "{part}: {out:?}");
        }
        // Punctuation and spaces stay plain.
        assert!(out.contains("\x1b[0m { "), "{out:?}");
    }

    #[test]
    fn multi_line_tokens_are_colored_line_by_line() {
        let text = "Note {\n  text: \"\"\"\n    a \\\"\"\"\n    b\n    \"\"\",\n} /* x\n /* y */\n*/ -12,\n";
        let out = highlight(text);
        assert_eq!(strip(&out), text);
        assert!(out.lines().all(|line| line.matches("\x1b[").count() % 2 == 0), "{out}");
        assert!(out.contains(&colored(Token::Escape, "\\\"")), "{out:?}");
        assert!(out.contains(&colored(Token::Comment, "*/")), "{out:?}");
        assert!(out.contains(&colored(Token::Number, "-12")), "{out:?}");
    }

    #[test]
    fn any_text_comes_back_unchanged() {
        for text in [
            "",
            "\"",
            "\"\"\"",
            "\"a\\",
            "x\"",
            "x\"0g\nA",
            "/*",
            "/* /* */",
            "-",
            "- 1",
            "1e",
            "1e+",
            "\u{feff}é: 1,\r\n\u{1F600}",
            "\"\\u{",
            "\"\\u{12",
            "a :b",
        ] {
            assert_eq!(strip(&highlight(text)), text, "{text:?}");
        }
    }

    /// Every input and expected output of the format suite.
    #[test]
    fn the_format_suite_comes_back_unchanged() {
        let suite = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test-suite/format");
        let mut count = 0;
        for entry in ignore::WalkBuilder::new(&suite).build() {
            let path = entry.unwrap().into_path();
            let wanted = ["haus", "pretty", "compact", "minimised"];
            if path.extension().is_some_and(|e| wanted.iter().any(|w| e == *w)) {
                let text = String::from_utf8_lossy(&std::fs::read(&path).unwrap()).into_owned();
                assert_eq!(strip(&highlight(&text)), text, "{}", path.display());
                count += 1;
            }
        }
        assert!(count > 100, "{count} files");
    }
}
