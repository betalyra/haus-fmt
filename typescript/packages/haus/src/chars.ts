/**
 * Characters as the reader and the writers see them: the UTF-16 codes of the
 * format's punctuation, the classes of characters that are never written raw
 * (spec §4), and the patterns of keys and tags. One place, so that what the
 * reader accepts and what the writers escape can't drift apart.
 */

// ── character codes (`charCodeAt`) ───────────────────────────
// Past the end of a string, `charCodeAt` is NaN, which equals none of them.

export const TAB = 0x09
export const LF = 0x0a
export const CR = 0x0d
export const SPACE = 0x20
export const QUOTE = 0x22 // "
export const OPEN_PAREN = 0x28 // (
export const CLOSE_PAREN = 0x29 // )
export const STAR = 0x2a // *
export const COMMA = 0x2c // ,
export const MINUS = 0x2d // -
export const DOT = 0x2e // .
export const SLASH = 0x2f // /
export const DIGIT_0 = 0x30
export const DIGIT_1 = 0x31
export const DIGIT_9 = 0x39
export const COLON = 0x3a // :
export const UPPER_A = 0x41
export const UPPER_F = 0x46
export const UPPER_Z = 0x5a
export const OPEN_BRACKET = 0x5b // [
export const BACKSLASH = 0x5c // \
export const CLOSE_BRACKET = 0x5d // ]
export const UNDERSCORE = 0x5f // _
export const LOWER_A = 0x61
export const LOWER_F = 0x66
export const LOWER_X = 0x78 // x, of a byte string x"…"
export const LOWER_Z = 0x7a
export const OPEN_BRACE = 0x7b // {
export const CLOSE_BRACE = 0x7d // }
export const BYTE_ORDER_MARK = 0xfeff

// ── classes ──────────────────────────────────────────────────

export const isDigit = (c: number): boolean => c >= DIGIT_0 && c <= DIGIT_9
export const isUpper = (c: number): boolean => c >= UPPER_A && c <= UPPER_Z
/** What a record key or a lowercase word starts with: `[a-z_]`. */
export const isLowerStart = (c: number): boolean => (c >= LOWER_A && c <= LOWER_Z) || c === UNDERSCORE
/** What an identifier (key, tag) continues with: `[A-Za-z0-9_]`. */
export const isIdentChar = (c: number): boolean => isDigit(c) || isUpper(c) || isLowerStart(c)

/** The value of a hex digit, or -1. */
export const hexValue = (c: number): number =>
  isDigit(c) ? c - DIGIT_0
  : c >= LOWER_A && c <= LOWER_F ? c - LOWER_A + 10
  : c >= UPPER_A && c <= UPPER_F ? c - UPPER_A + 10
  : -1

/** Control characters (C0, DEL, C1): raw only as tab and line breaks, where the grammar allows them (spec §4). */
export const isControl = (c: number): boolean => c < 0x20 || (c >= 0x7f && c <= 0x9f)

/** Bidirectional controls (U+202A–U+202E, U+2066–U+2069): never raw, only escaped ("Trojan Source"). */
export const isBidiControl = (c: number): boolean => (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069)

/** The line and paragraph separators U+2028, U+2029: some software splits lines at them, so every writer escapes them (spec §11). */
export const isLineSeparator = (c: number): boolean => c === 0x2028 || c === 0x2029

const isHighSurrogate = (c: number): boolean => c >= 0xd800 && c <= 0xdbff

/** The high surrogates in `s` from `from` on: each starts a code point of two UTF-16 units. */
export const highSurrogates = (s: string, from = 0): number => {
  let n = 0
  for (let i = from; i < s.length; i++) if (isHighSurrogate(s.charCodeAt(i))) n++
  return n
}

/** The number of code points (characters, as the limits and widths count them): a surrogate pair counts once. */
export const codePoints = (s: string): number => s.length - highSurrogates(s)

// ── names ────────────────────────────────────────────────────

/** A record key written bare (spec §3): an identifier starting with a lowercase letter or `_`. Any other key is quoted. */
export const BARE_KEY = /^[a-z_][A-Za-z0-9_]*$/

/** A tag: an identifier starting with an uppercase letter. */
export const TAG = /^[A-Z][A-Za-z0-9_]*$/
