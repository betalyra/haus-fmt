// External scanner shared by the haus and haus_schema grammars.
//
// It handles what the grammar DSL can't express:
//
// - comments: nested block comments (`/* a /* b */ c */`, spec
//   grammar.ebnf), and line comments, so that invalid UTF-8 in them is an
//   error (tree-sitter's generated lexer lets it through negated character
//   classes);
// - line breaks that are a carriage return without a line feed: the
//   generated lexer can't reject one at the end of the input (it accepts the
//   end of the input in the middle of the `\r?\n` extra), so the scanner
//   lexes it as a token that no rule accepts;
// - the content of basic strings, so that `/*` inside a string is never
//   taken for a comment;
// - block strings (spec §4): the opening `"""` ends its line, the closing
//   `"""` stands on a line of its own after only blanks (the indent), and
//   every content line that isn't blank starts with the indent;
// - the rule that a variant's payload starts on the tag's line (spec §5):
//   right after a tag the scanner emits a zero-width token that says whether
//   a payload follows (only spaces and tabs before `(` or `{`), before any
//   comment or line break can be lexed.
//
// Characters that may not appear raw in the input (spec §4: C0 controls but
// tab, DEL, C1 controls, bidirectional controls, a carriage return not
// followed by a line feed, invalid UTF-8) end a token, so the parser reports
// an error there.
//
// A byte order mark needs nothing here: the tree-sitter runtime skips one at
// the very start of the input (byte 0) before any lexer runs, and nothing
// lexes U+FEFF anywhere else, so a second one, or one after a comment or a
// value, is an error.

#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum TokenType {
  BLOCK_COMMENT,
  LINE_COMMENT,
  STRING_CONTENT,
  BLOCK_STRING_START,
  BLOCK_STRING_CONTENT,
  BLOCK_STRING_END,
  PAYLOAD_START,
  NO_PAYLOAD,
  LONE_CARRIAGE_RETURN,
  ERROR_SENTINEL,
};

// The indent of a block string is compared with the blanks that start its
// content lines. Longer runs of blanks than this are not compared.
#define HAUS_MAX_INDENT 255

typedef struct {
  // Inside a block string, between its opening and closing `"""`.
  bool in_block_string;
  // A content line that isn't blank has been seen.
  bool seen_line;
  // A run of leading blanks was longer than HAUS_MAX_INDENT.
  bool overflow;
  // The longest common prefix of the leading blanks of the content lines
  // that aren't blank. The closing indent must be a prefix of it.
  uint8_t prefix_length;
  char prefix[HAUS_MAX_INDENT];
} Scanner;

static inline void haus_advance(TSLexer *lexer) { lexer->advance(lexer, false); }

static inline void haus_skip(TSLexer *lexer) { lexer->advance(lexer, true); }

static inline bool haus_is_blank(int32_t c) { return c == ' ' || c == '\t'; }

// Characters that may appear in strings, block strings and comments: not a
// control character (C0, DEL, C1) and not a bidirectional control. Tab and
// line breaks are handled by the callers. A negative lookahead is invalid
// UTF-8.
static inline bool haus_is_text_char(int32_t c) {
  if (c < 0x20) return false;
  if (c >= 0x7F && c <= 0x9F) return false;
  if (c >= 0x202A && c <= 0x202E) return false;
  if (c >= 0x2066 && c <= 0x2069) return false;
  return true;
}

static inline bool haus_at_eof(TSLexer *lexer) { return lexer->eof(lexer); }

// Forgets the block string, if any.
static void haus_reset(Scanner *s) {
  s->in_block_string = false;
  s->seen_line = false;
  s->overflow = false;
  s->prefix_length = 0;
}

static unsigned haus_serialize(Scanner *s, char *buffer) {
  buffer[0] = (char)((s->in_block_string ? 1 : 0) | (s->seen_line ? 2 : 0) | (s->overflow ? 4 : 0));
  buffer[1] = (char)s->prefix_length;
  memcpy(&buffer[2], s->prefix, s->prefix_length);
  return 2 + s->prefix_length;
}

static void haus_deserialize(Scanner *s, const char *buffer, unsigned length) {
  haus_reset(s);
  if (length < 2) return;
  uint8_t flags = (uint8_t)buffer[0];
  s->in_block_string = flags & 1;
  s->seen_line = flags & 2;
  s->overflow = flags & 4;
  uint8_t prefix_length = (uint8_t)buffer[1];
  if (prefix_length > length - 2) prefix_length = (uint8_t)(length - 2);
  s->prefix_length = prefix_length;
  memcpy(s->prefix, &buffer[2], prefix_length);
}

// ── Comments ────────────────────────────────────────────────────────────

// At `//`: runs to the end of its line, which isn't part of it. Ends early at
// a character that may not appear raw, which is then an error.
static bool haus_scan_line_comment(TSLexer *lexer) {
  while (!haus_at_eof(lexer) && (lexer->lookahead == '\t' || haus_is_text_char(lexer->lookahead))) {
    haus_advance(lexer);
  }
  lexer->mark_end(lexer);
  lexer->result_symbol = LINE_COMMENT;
  return true;
}

// At `/*`: a block comment, nested. Read left to right, every `/*` opens a
// comment and the first `*/` closes one, so `/* a /*/` is unterminated.
static bool haus_scan_block_comment(TSLexer *lexer) {
  unsigned depth = 1;
  for (;;) {
    if (haus_at_eof(lexer)) return false;
    int32_t c = lexer->lookahead;
    if (c == '/') {
      haus_advance(lexer);
      if (lexer->lookahead == '*') {
        haus_advance(lexer);
        depth++;
      }
    } else if (c == '*') {
      haus_advance(lexer);
      if (lexer->lookahead == '/') {
        haus_advance(lexer);
        if (--depth == 0) {
          lexer->mark_end(lexer);
          lexer->result_symbol = BLOCK_COMMENT;
          return true;
        }
      }
    } else if (c == '\n' || c == '\t') {
      haus_advance(lexer);
    } else if (c == '\r') {
      haus_advance(lexer);
      if (lexer->lookahead != '\n') return false;
    } else if (haus_is_text_char(c)) {
      haus_advance(lexer);
    } else {
      return false;
    }
  }
}

// ── Basic strings ───────────────────────────────────────────────────────

// The text of a basic string up to a quote, a backslash (an escape, lexed by
// the grammar) or a character that may not appear raw (an error).
static bool haus_scan_string_content(TSLexer *lexer) {
  bool has_content = false;
  while (!haus_at_eof(lexer)) {
    int32_t c = lexer->lookahead;
    if (c == '"' || c == '\\' || !haus_is_text_char(c)) break;
    haus_advance(lexer);
    has_content = true;
  }
  if (!has_content) return false;
  lexer->mark_end(lexer);
  lexer->result_symbol = STRING_CONTENT;
  return true;
}

// ── Block strings ───────────────────────────────────────────────────────

// `"""`, blanks, and then a line break must follow: the opening delimiter
// ends its line. The line break belongs to the content.
static bool haus_scan_block_string_start(Scanner *s, TSLexer *lexer) {
  for (int i = 0; i < 3; i++) {
    if (lexer->lookahead != '"') return false;
    haus_advance(lexer);
  }
  while (haus_is_blank(lexer->lookahead)) haus_advance(lexer);
  lexer->mark_end(lexer);
  if (lexer->lookahead == '\r') haus_advance(lexer);
  if (lexer->lookahead != '\n') return false;
  haus_reset(s);
  s->in_block_string = true;
  lexer->result_symbol = BLOCK_STRING_START;
  return true;
}

// Whether `indent` (the blanks before the closing `"""`) is a prefix of the
// leading blanks of every content line that isn't blank.
static bool haus_indent_fits(Scanner *s, const char *indent, unsigned length, bool overflow) {
  if (!s->seen_line) return true;
  // An indent longer than every line's blanks can't be a prefix of them.
  if (overflow && !s->overflow) return false;
  if (!overflow && length > s->prefix_length) return false;
  // Runs longer than HAUS_MAX_INDENT are compared up to that length only.
  unsigned n = length < s->prefix_length ? length : s->prefix_length;
  return memcmp(indent, s->prefix, n) == 0;
}

// A content line that isn't blank starts with `blanks`: shorten the common
// prefix to what it shares with them.
static void haus_record_line(Scanner *s, const char *blanks, unsigned length, bool overflow) {
  if (!s->seen_line) {
    s->seen_line = true;
    s->overflow = overflow;
    s->prefix_length = (uint8_t)length;
    memcpy(s->prefix, blanks, length);
    return;
  }
  unsigned n = 0;
  while (n < s->prefix_length && n < length && s->prefix[n] == blanks[n]) n++;
  // The prefix stays longer than what is stored only if both runs are.
  s->overflow = s->overflow && overflow && n == s->prefix_length;
  s->prefix_length = (uint8_t)n;
}

// Content of a block string: text, line breaks and blanks up to an escape
// (lexed by the grammar), up to the line break before the closing `"""`, or
// up to an error. At the line break before the closing `"""`, emits the
// closing delimiter instead when there is no content before it.
static bool haus_scan_block_string_content(Scanner *s, TSLexer *lexer, const bool *valid_symbols) {
  bool has_content = false;
  for (;;) {
    if (haus_at_eof(lexer)) break;
    int32_t c = lexer->lookahead;

    if (c == '\r' || c == '\n') {
      // The content so far ends before this line break, in case the next
      // line closes the string.
      lexer->mark_end(lexer);
      if (c == '\r') {
        haus_advance(lexer);
        if (lexer->lookahead != '\n') {
          // A carriage return on its own: end the content before it.
          if (!has_content) return false;
          lexer->result_symbol = BLOCK_STRING_CONTENT;
          return true;
        }
      }
      haus_advance(lexer);

      char blanks[HAUS_MAX_INDENT];
      unsigned length = 0;
      bool overflow = false;
      while (haus_is_blank(lexer->lookahead)) {
        if (length < HAUS_MAX_INDENT) blanks[length++] = (char)lexer->lookahead;
        else overflow = true;
        haus_advance(lexer);
      }

      if (lexer->lookahead == '"') {
        haus_advance(lexer);
        if (lexer->lookahead == '"') {
          haus_advance(lexer);
          if (lexer->lookahead == '"') {
            // The closing line. Its blanks are the indent.
            if (has_content) {
              lexer->result_symbol = BLOCK_STRING_CONTENT;
              return true;
            }
            if (!valid_symbols[BLOCK_STRING_END]) return false;
            if (!haus_indent_fits(s, blanks, length, overflow)) return false;
            haus_advance(lexer);
            lexer->mark_end(lexer);
            haus_reset(s);
            lexer->result_symbol = BLOCK_STRING_END;
            return true;
          }
        }
        // One or two quotes start an ordinary content line.
        haus_record_line(s, blanks, length, overflow);
        has_content = true;
        continue;
      }

      has_content = true;
      if (lexer->lookahead == '\r' || lexer->lookahead == '\n' || haus_at_eof(lexer)) {
        // A line of only blanks: it never needs the indent.
        continue;
      }
      haus_record_line(s, blanks, length, overflow);
      continue;
    }

    if (c == '\\') break;

    if (c == '"') {
      // `"""` inside a line: the closing delimiter must stand on a line of
      // its own, so this is an error. One or two quotes are content.
      lexer->mark_end(lexer);
      haus_advance(lexer);
      if (lexer->lookahead == '"') {
        haus_advance(lexer);
        if (lexer->lookahead == '"') {
          if (!has_content) return false;
          lexer->result_symbol = BLOCK_STRING_CONTENT;
          return true;
        }
      }
      has_content = true;
      continue;
    }

    if (c == '\t' || haus_is_text_char(c)) {
      haus_advance(lexer);
      has_content = true;
      continue;
    }

    break;
  }

  // An escape, an invalid character or the end of the input.
  if (!has_content) return false;
  lexer->mark_end(lexer);
  lexer->result_symbol = BLOCK_STRING_CONTENT;
  return true;
}

// ── Payloads ────────────────────────────────────────────────────────────

// Right after a tag: a payload follows if only spaces and tabs come before
// `(` or `{`. Zero-width either way, so no comment or line break can be lexed
// between the tag and this decision.
static bool haus_scan_payload(TSLexer *lexer, const bool *valid_symbols) {
  lexer->mark_end(lexer);
  while (haus_is_blank(lexer->lookahead)) haus_advance(lexer);
  bool payload = lexer->lookahead == '(' || lexer->lookahead == '{';
  if (payload && valid_symbols[PAYLOAD_START]) {
    lexer->result_symbol = PAYLOAD_START;
    return true;
  }
  if (!payload && valid_symbols[NO_PAYLOAD]) {
    lexer->result_symbol = NO_PAYLOAD;
    return true;
  }
  return false;
}

// ── Entry point ─────────────────────────────────────────────────────────

// At `/`: a line or block comment.
static bool haus_scan_comment(TSLexer *lexer, const bool *valid_symbols) {
  if (lexer->lookahead != '/') return false;
  haus_advance(lexer);
  if (lexer->lookahead == '/' && valid_symbols[LINE_COMMENT]) return haus_scan_line_comment(lexer);
  if (lexer->lookahead == '*' && valid_symbols[BLOCK_COMMENT]) {
    haus_advance(lexer);
    return haus_scan_block_comment(lexer);
  }
  return false;
}

// Skips spaces, tabs and line breaks. Returns true, with the token
// LONE_CARRIAGE_RETURN, at a carriage return that isn't followed by a line
// feed: no rule accepts that token, so the parser reports an error there.
static bool haus_skip_whitespace(TSLexer *lexer) {
  for (;;) {
    int32_t c = lexer->lookahead;
    if (haus_is_blank(c) || c == '\n') {
      haus_skip(lexer);
    } else if (c == '\r') {
      // Part of the token unless a line feed follows; skipping the line feed
      // then moves the token's start past both.
      haus_advance(lexer);
      if (lexer->lookahead == '\n') {
        haus_skip(lexer);
        continue;
      }
      lexer->mark_end(lexer);
      lexer->result_symbol = LONE_CARRIAGE_RETURN;
      return true;
    } else {
      return false;
    }
  }
}

static bool haus_scan(Scanner *s, TSLexer *lexer, const bool *valid_symbols) {
  // During error recovery every symbol is valid: only lex comments and lone
  // carriage returns, so that a broken string or payload doesn't swallow
  // what follows.
  if (valid_symbols[ERROR_SENTINEL]) {
    if (haus_skip_whitespace(lexer)) return true;
    return haus_scan_comment(lexer, valid_symbols);
  }

  if (valid_symbols[BLOCK_STRING_CONTENT] || valid_symbols[BLOCK_STRING_END]) {
    return haus_scan_block_string_content(s, lexer, valid_symbols);
  }

  if (valid_symbols[STRING_CONTENT]) {
    return haus_scan_string_content(lexer);
  }

  if (valid_symbols[PAYLOAD_START] || valid_symbols[NO_PAYLOAD]) {
    return haus_scan_payload(lexer, valid_symbols);
  }

  // Whitespace before a block string or a comment.
  if (haus_skip_whitespace(lexer)) return true;

  if (lexer->lookahead == '"') {
    return valid_symbols[BLOCK_STRING_START] && haus_scan_block_string_start(s, lexer);
  }

  if (lexer->lookahead == '/') {
    return haus_scan_comment(lexer, valid_symbols);
  }

  return false;
}
