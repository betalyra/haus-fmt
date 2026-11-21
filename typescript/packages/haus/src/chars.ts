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

/** A character code as error messages write it after `U+`: four or more uppercase hex digits. */
export const hex4 = (c: number): string => c.toString(16).toUpperCase().padStart(4, "0")

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

// ── unpaired surrogates ──────────────────────────────────────

/** An unpaired surrogate: a high one without a low one after it, or a low one without a high one before it. */
const UNPAIRED = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/

/** `String.prototype.isWellFormed` (ES2024), where the runtime has it. */
const isWellFormed: ((this: string) => boolean) | undefined = (String.prototype as { isWellFormed?: (this: string) => boolean }).isWellFormed

/**
 * The index of the first unpaired surrogate in `text`, or -1. A JavaScript
 * string can hold one; it has no UTF-8 form (spec §4).
 */
export function unpairedSurrogate(text: string): number {
  if (isWellFormed !== undefined && isWellFormed.call(text)) return -1
  return text.search(UNPAIRED)
}

// ── quoting in messages ──────────────────────────────────────

/** Bidirectional controls and marks, shown escaped in messages. */
const isBidiMark = (c: number): boolean => isBidiControl(c) || c === 0x061c || c === 0x200e || c === 0x200f

/**
 * A character as a message shows it (spec §9.2): control, bidi and
 * line-separator characters (and a lone surrogate) as `\u{…}`, in uppercase
 * hex as the canonical form writes them (§12).
 */
const shownChar = (cp: number): string =>
  isControl(cp) || isBidiMark(cp) || isLineSeparator(cp) || (cp >= 0xd800 && cp <= 0xdfff) ? `\\u{${cp.toString(16).toUpperCase()}}` : String.fromCodePoint(cp)

/**
 * Text from the input, for a message (spec §9.2): control and bidirectional
 * characters escaped as `\u{…}`, then at most `max` characters (default 40)
 * as shown, after escaping. A longer text is cut to whole characters in
 * `max - 1` and marked with `…`, within the `max`; a cut never falls inside
 * an escape. Reads only as much of `text` as it shows.
 */
export function quoteText(text: string, max = 40): string {
  const pieces: string[] = []
  let shown = 0
  // The shown length of the pieces that fit in max - 1, should the text need a cut.
  let kept = -1
  for (const ch of text) {
    const piece = shownChar(ch.codePointAt(0)!)
    const width = piece === ch ? 1 : piece.length
    if (shown + width > max - 1 && kept < 0) kept = pieces.length
    shown += width
    if (shown > max) return `${pieces.slice(0, kept).join("")}…`
    pieces.push(piece)
  }
  return pieces.join("")
}

// ── names ────────────────────────────────────────────────────

/** A record key written bare (spec §3): an identifier starting with a lowercase letter or `_`. Any other key is quoted. */
export const BARE_KEY = /^[a-z_][A-Za-z0-9_]*$/

/** A tag: an identifier starting with an uppercase letter. */
export const TAG = /^[A-Z][A-Za-z0-9_]*$/
