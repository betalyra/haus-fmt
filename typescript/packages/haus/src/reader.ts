/**
 * The `Reader`: the one haus parser, as a pull API over a complete text.
 *
 * It does everything the format defines (whitespace, comments, escapes,
 * bidirectional and control characters, the limits of spec §7, error codes
 * and positions) and nothing else: it hands out one token at a time, and its
 * consumers decide what to build.
 *
 * - `readValue` (parser.ts) builds the generic `Value` tree: `parse`, `parseAll`.
 * - Compiled codecs (codec.ts) read straight into typed values, with no tree in between.
 *
 * A value is read as:
 *
 *   switch (r.next()) {                    // counts the value; fails if nothing can start one
 *     case STRING:  r.string()
 *     case NUMBER:  r.number()             // the normalized literal text (spec §2)
 *     case BYTES:   r.bytes()
 *     case VARIANT: const tag = r.tag()
 *                   switch (r.payload(tag)) {
 *                     case NO_PAYLOAD: …
 *                     case ARGS:       do { …a value…; r.endItem(CLOSE_ARGS) } while (r.more(CLOSE_ARGS))   // at least one
 *                     case PAYLOAD_RECORD: …a record value (the one argument)…
 *                   }
 *     case ARRAY:   r.openList(); while (r.more(CLOSE_ARRAY)) { …a value…; r.endItem(CLOSE_ARRAY) }
 *     case RECORD:  r.openRecord(); for (let k = r.key(); k !== undefined; k = r.key()) { …a value…; r.endField() }
 *   }
 *
 * Duplicate keys are the consumer's to detect (it knows which keys it has
 * seen), with `failDuplicate` after the value, as the generic parser does.
 */
import * as chars from "./chars.js"
import { codePoints, hex4, hexValue, isBidiControl, isControl, isDigit, isIdentChar, isLowerStart, isUpper, quoteText } from "./chars.js"
import { HausSyntaxError, locate, START, type ErrorCode, type ErrorDetails, type Origin } from "./errors.js"

// Hot: the character codes as constants of this module. V8 reads an imported
// binding through its module cell at every use, which measured 3-5% slower
// reading; a constant of the module is folded into the code.
const {
  BACKSLASH, BYTE_ORDER_MARK, CLOSE_BRACE, CLOSE_BRACKET, CLOSE_PAREN, COLON, COMMA, CR, DIGIT_0, DIGIT_1, DIGIT_9, DOT,
  LF, LOWER_X, MINUS, OPEN_BRACE, OPEN_BRACKET, OPEN_PAREN, QUOTE, SLASH, SPACE, STAR, TAB, UPPER_A, UPPER_Z,
} = chars

/** Resource limits. Every parser enforces them while parsing (spec: "Limits"). */
export interface Limits {
  /** Nesting depth of records, arrays and payloads: at most MAX_SUPPORTED_DEPTH. */
  readonly maxDepth: number
  /** Characters in one number literal, including sign, separators and exponent. */
  readonly maxNumberLength: number
  /** Largest absolute exponent, e.g. 6144 allows `1e6144` but not `1e6145`. */
  readonly maxExponent: number
  /** Characters in one decoded string, record key or tag (or between the quotes of a byte string). */
  readonly maxStringLength: number
}

/** The default nesting depth (spec §7). */
export const MAX_DEPTH = 256

export const DEFAULT_LIMITS: Limits = {
  maxDepth: MAX_DEPTH,
  maxNumberLength: 1000,
  maxExponent: 6144,
  maxStringLength: 16 * 1024 * 1024,
}

// What `next` finds: the kind of the value that starts here.
export const RECORD = 1
export const ARRAY = 2
export const STRING = 3
export const NUMBER = 4
export const VARIANT = 5
export const BYTES = 6

// What `payload` finds after a tag.
export const NO_PAYLOAD = 0
/** `Tag(a, …)`: the list is open, with at least one argument. */
export const ARGS = 1
/**
 * `Tag { … }`: at the `{`. The record is the variant's one argument, a value
 * of its own (`Tag { … }` is `Tag({ … })` written without the parentheses):
 * `next` counts it and finds RECORD.
 */
export const PAYLOAD_RECORD = 2

// The closing brackets of lists, for `more` and `endItem`.
export const CLOSE_ARRAY = CLOSE_BRACKET
export const CLOSE_ARGS = CLOSE_PAREN

/** log₁₆ 10: a power of ten 10^e is 16^(e · this). */
const HEX_PER_DECIMAL = Math.log(10) / Math.log(16)

/** The hex digit limit of each number limit seen, computed once. */
const hexDigitLimits = new Map<number, number>()

/**
 * The most hex digits a hex literal may have under the number limit
 * `maxNumberLength` = n (spec §7): the largest h with 16^h ≤ 10^(n−1), so
 * that every integer's decimal form, sign included, fits in n characters.
 * 829 for the default 1000. A float estimate, checked with exact powers
 * where it is near a whole number.
 */
export const maxHexDigits = (maxNumberLength: number): number => {
  if (maxNumberLength === Infinity) return Infinity
  if (!(maxNumberLength >= 1)) return 0
  const n = Math.floor(maxNumberLength)
  const known = hexDigitLimits.get(n)
  if (known !== undefined) return known
  const e = n - 1
  const estimate = e * HEX_PER_DECIMAL
  let h = Math.floor(estimate)
  if (Math.abs(estimate - Math.round(estimate)) < 1e-9 * (estimate + 1)) {
    const ten = 10n ** BigInt(e)
    while (1n << BigInt(4 * h) > ten) h--
    while (1n << BigInt(4 * (h + 1)) <= ten) h++
  }
  hexDigitLimits.set(n, h)
  return h
}

/** Whether `s` has more than `max` characters (code points: an emoji is one character, but two UTF-16 units). */
export const longerThan = (s: string, max: number): boolean => s.length > max && codePoints(s) > max

/** Whether a number literal that ends before `c` runs on into it (a letter, digit, `_` or `.`), which makes it invalid. Not past the end (NaN). */
const continuesNumber = (c: number) => isIdentChar(c) || c === DOT

const HEX = /-?0x([0-9A-Fa-f](?:_?[0-9A-Fa-f])*)/y
const BIN = /-?0b([01](?:_?[01])*)/y
const DEC = /-?(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?/y
const BLANK = /^[ \t]*$/
/** A run of identifier characters (see `isIdentChar`). */
const IDENT_RUN = /[0-9A-Za-z_]*/y
/** A run of characters a `"…"` string has raw without a check: all but `"`, `\`, control characters and bidirectional controls. */
const PLAIN_RUN = /[^"\\\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]*/y

/** The kind of value an ASCII character starts (0: none, or not that simply: `x"…"` and errors). */
const STARTS = (() => {
  const t = new Uint8Array(128)
  t[OPEN_BRACE] = RECORD
  t[OPEN_BRACKET] = ARRAY
  t[QUOTE] = STRING
  t[MINUS] = NUMBER
  for (let c = DIGIT_0; c <= DIGIT_9; c++) t[c] = NUMBER
  for (let c = UPPER_A; c <= UPPER_Z; c++) t[c] = VARIANT
  return t
})()

/** The character at `pos` of `src`, as a message shows it (spec §9.2): `'x'`, a line break or the end. */
const describe = (src: string, pos: number) => {
  const c = src.codePointAt(pos)
  return c === undefined ? "end of input" : c === 0x0a ? "line break" : `'${quoteText(String.fromCodePoint(c))}'`
}

/**
 * A pull parser over one complete piece of text (see the module comment).
 * Fields are public for the consumers' hot loops; only the methods move them.
 */
export class Reader {
  pos = 0
  depth = 0
  /**
   * The values read so far, nested ones included: a record payload `Tag { … }`
   * is a value of its own. For a single value, the size of its tree.
   */
  valueCount = 0
  /** With locations: [start, end) of every comment, in source order. */
  readonly comments: [number, number][] = []
  /** Where the last key read by `key` starts and ends. */
  keyStart = 0
  keyEnd = 0
  /**
   * The last tag read without a payload, and where it ends. If nothing but
   * trivia follows it up to a separator error, it was the value before the
   * error: a `(` or `{` there is a payload put on the wrong line (spec §3),
   * and the error says so. (Kept this way so that reading other values costs
   * nothing for it.)
   */
  private bareTag = ""
  private bareTagEnd = -1
  /** By depth: where each open container starts (for "unclosed" errors). */
  private readonly opens: number[] = [0]

  constructor(
    readonly src: string,
    readonly origin: Origin = START,
    readonly limits: Limits = DEFAULT_LIMITS,
    /** Record source positions (for editor tooling): comments are collected. */
    readonly locations = false,
  ) {}

  // ── the document ───────────────────────────────────────────

  /** At the start of the text: the byte order mark, the version directive (spec §10), trivia. */
  begin(): void {
    this.skipBom()
    this.checkDirective()
    this.skipTrivia()
  }

  atEnd(): boolean {
    return this.pos >= this.src.length
  }

  /**
   * After a top-level value: whether another one follows. Consumes the trivia
   * and the `,` in between; anything else after the value is an error.
   */
  nextTop(): boolean {
    this.skipTrivia()
    if (this.atEnd()) return false
    if (this.src.charCodeAt(this.pos) !== COMMA) this.failSeparator("expected ',' between top-level values")
    this.pos++
    this.skipTrivia()
    return !this.atEnd()
  }

  /**
   * After the one value of a stream item: trivia, then the end of the text or
   * the ',' that ends it (the stream reader passes each item with its comma).
   */
  endSingle(): void {
    this.skipTrivia()
    if (!this.atEnd() && !(this.src.charCodeAt(this.pos) === COMMA && this.pos === this.src.length - 1)) this.failSeparator("expected ',' between top-level values")
  }

  /**
   * Spec §10: a file whose first character (after a byte order mark) is `#`
   * is reserved for a version directive such as `#haus 2`. Such a file is
   * written for a later, incompatible version: say so instead of reporting
   * an ordinary syntax error.
   */
  private checkDirective() {
    // Only at the start of the whole text: offset 0, or 1 after a byte order mark
    // (the stream reader drops the mark and starts its first piece at offset 1).
    if (this.origin.offset + this.pos > 1 || !this.src.startsWith("#haus", this.pos)) return
    this.fail("version-directive", "this file starts with a #haus version directive: it needs a newer version of haus")
  }

  /** A byte order mark is skipped only at the start of the whole input, not of a later stream item. */
  private skipBom() {
    if (this.origin.offset === 0 && this.pos === 0 && this.src.charCodeAt(0) === BYTE_ORDER_MARK) this.pos = 1
  }

  // ── values ─────────────────────────────────────────────────

  /**
   * The kind of the value starting here (RECORD, ARRAY, STRING, NUMBER,
   * VARIANT, BYTES), counted as one value. Fails for anything that can't
   * start a value. Moves nothing.
   */
  next(): number {
    this.valueCount++
    // Hot: one table lookup (past the end, c is NaN: no kind).
    const c = this.src.charCodeAt(this.pos)
    const kind = c < 128 ? STARTS[c]! : 0
    return kind !== 0 ? kind : this.otherStart(c)
  }

  /** A value starting with a character `STARTS` doesn't know: a byte string, or an error. */
  private otherStart(c: number): number {
    if (c === LOWER_X && this.src.charCodeAt(this.pos + 1) === QUOTE) return BYTES
    if (isLowerStart(c)) {
      const word = this.readIdent()
      const [code, hint]: [ErrorCode, string] =
        word === "true" || word === "false" ? ["boolean-literal", " (booleans are the variants True / False)"]
        : word === "null" ? ["null-literal", " (use the variant None)"]
        : ["bare-identifier", ""]
      this.fail(code, `unexpected identifier '${quoteText(word)}': lowercase identifiers can only be record keys${hint}`, this.pos - word.length, { expected: "a value", found: `'${quoteText(word)}'` })
    }
    // `+1` and `.5`: a number written the way other languages allow.
    const code = this.peek() === "+" || this.peek() === "." ? "invalid-number" : "expected-value"
    this.fail(code, `expected a value, found ${describe(this.src, this.pos)}`, this.pos, { expected: "a value", found: describe(this.src, this.pos) })
  }

  /** At `"`: a basic or block string's value. */
  string(): string {
    return this.src.startsWith('"""', this.pos) ? this.blockString() : this.basicString()
  }

  /** At a number: its normalized literal text (spec §2). */
  number(): string {
    return this.plainDecimal() ?? this.anyNumber()
  }

  /** At a tag: its name. Then `payload`. */
  tag(): string {
    return this.checkWordLength(this.readIdent(), "tag")
  }

  /**
   * After `tag`: what follows it on the same line. NO_PAYLOAD (nothing is
   * consumed), ARGS (the list is open and not empty: read the arguments, then
   * `more` closes it) or PAYLOAD_RECORD (at the `{` of the one argument).
   */
  payload(tag: string): number {
    const afterTag = this.pos
    // The payload must follow on the same line: only spaces and tabs in between.
    // Otherwise `Heartbeat⏎{ a: 1 }` with a forgotten comma would silently
    // become one variant with a payload.
    const src = this.src
    while (src.charCodeAt(this.pos) === SPACE || src.charCodeAt(this.pos) === TAB) this.pos++
    const c = src.charCodeAt(this.pos)
    if (c === OPEN_PAREN) {
      const parenPos = this.pos
      this.openList()
      if (src.charCodeAt(this.pos) === CLOSE_PAREN) this.fail("empty-payload", `empty payload: write '${quoteText(tag)}' without parentheses`, parenPos, { hint: `Write ${quoteText(tag)} without parentheses.` })
      return ARGS
    }
    if (c === OPEN_BRACE) return PAYLOAD_RECORD
    this.pos = afterTag
    this.bareTag = tag
    this.bareTagEnd = afterTag
    return NO_PAYLOAD
  }

  // ── containers ─────────────────────────────────────────────

  private enter(open: number) {
    if (++this.depth > this.limits.maxDepth) this.fail("nesting-too-deep", `nesting deeper than ${this.limits.maxDepth} levels`)
    this.opens[this.depth] = open
  }

  /** At `{`: opens the record. Then `key` until it returns undefined. */
  openRecord(): void {
    this.enter(this.pos)
    this.pos++
    this.skipTrivia()
  }

  /**
   * The next key of the open record, with its `:` consumed (at the value), or
   * undefined at the record's end (the `}` consumed). `keyStart` and `keyEnd`
   * say where the key is. After the value, `endField`.
   */
  key(): string | undefined {
    const src = this.src
    if (src.charCodeAt(this.pos) === CLOSE_BRACE) {
      this.pos++
      this.depth--
      return undefined
    }
    if (this.atEnd()) this.failUnclosed(CLOSE_BRACE)
    this.keyStart = this.pos
    const key = this.readKey()
    this.keyEnd = this.pos
    this.skipTrivia()
    if (src.charCodeAt(this.pos) !== COLON) this.fail("missing-colon", `expected ':' after key '${quoteText(key)}', found ${describe(this.src, this.pos)}`, this.pos, { expected: "':'", found: describe(this.src, this.pos) })
    this.pos++
    this.skipTrivia()
    return key
  }

  /**
   * Whether the next key of the open record is `name`, written bare (`name`
   * must be a bare key: `[a-z_][A-Za-z0-9_]*`). If so, it is read as `key`
   * reads it, and true is returned; otherwise nothing moves (`key` then reads
   * what is there). Hot: compared in place, no string is made.
   */
  keyIs(name: string): boolean {
    const src = this.src
    const start = this.pos
    const end = start + name.length
    if (!src.startsWith(name, start) || isIdentChar(src.charCodeAt(end)) || name.length > this.limits.maxStringLength) return false
    this.keyStart = start
    this.keyEnd = end
    this.pos = end
    this.skipTrivia()
    if (src.charCodeAt(this.pos) !== COLON) this.fail("missing-colon", `expected ':' after key '${quoteText(name)}', found ${describe(this.src, this.pos)}`, this.pos, { expected: "':'", found: describe(this.src, this.pos) })
    this.pos++
    this.skipTrivia()
    return true
  }

  /** After a field's value: a `,` (consumed) or the `}` (left for `key`). */
  endField(): void {
    this.skipTrivia()
    const c = this.src.charCodeAt(this.pos)
    if (c === COMMA) {
      this.pos++
      this.skipTrivia()
    } else if (c !== CLOSE_BRACE) {
      if (this.atEnd()) this.failUnclosed(CLOSE_BRACE)
      this.failSeparator("expected ',' or '}'", "}")
    }
  }

  /** The key just read (at `keyStart`) was seen before in this record. */
  failDuplicate(key: string): never {
    this.fail("duplicate-key", `duplicate key '${quoteText(key)}'`, this.keyStart)
  }

  /**
   * At `[` (or the `(` of a payload): opens the list. Then `more` before each
   * item and `endItem` after it, given the list's closing bracket:
   * CLOSE_ARRAY or CLOSE_ARGS.
   */
  openList(): void {
    this.enter(this.pos)
    this.pos++
    this.skipTrivia()
  }

  /** Whether another item follows in the open list closed by `close`; at its end, the bracket is consumed. */
  more(close: number): boolean {
    if (this.src.charCodeAt(this.pos) === close) {
      this.pos++
      this.depth--
      return false
    }
    if (this.atEnd()) this.failUnclosed(close)
    return true
  }

  /** After an item: a `,` (consumed) or the closing bracket `close` (left for `more`). */
  endItem(close: number): void {
    this.skipTrivia()
    const c = this.src.charCodeAt(this.pos)
    if (c === COMMA) {
      this.pos++
      this.skipTrivia()
    } else if (c !== close) {
      if (this.atEnd()) this.failUnclosed(close)
      const text = String.fromCharCode(close)
      this.failSeparator(`expected ',' or '${text}'`, text)
    }
  }

  private failUnclosed(closeCode: number): never {
    const close = String.fromCharCode(closeCode)
    const open = close === "}" ? "{" : close === "]" ? "[" : "("
    this.fail("unclosed-bracket", `unclosed '${open}'`, this.opens[this.depth]!, { expected: `'${close}'` })
  }

  private readKey(): string {
    const c = this.src.charCodeAt(this.pos)
    if (c === QUOTE) {
      if (this.src.startsWith('"""', this.pos)) this.fail("block-string-key", "block strings can't be record keys")
      return this.basicString()
    }
    if (isLowerStart(c)) return this.checkWordLength(this.readIdent(), "key")
    if (isUpper(c)) {
      const word = this.readIdent()
      this.fail("uppercase-key", `record keys must start with a lowercase letter or '_'; quote it: "${quoteText(word)}"`, this.pos - word.length, { hint: `Quote the key: "${quoteText(word)}".` })
    }
    this.fail("expected-key", `expected a record key, found ${describe(this.src, this.pos)}`, this.pos, { expected: "a record key", found: describe(this.src, this.pos) })
  }

  // ── numbers ────────────────────────────────────────────────

  /** The whole text as one number literal, without trivia around it: its normalized text (spec §2). */
  numberLiteral(): string {
    if (!/[-0-9]/.test(this.src[0] ?? "")) this.fail("invalid-number", "expected a number")
    const text = this.number()
    if (!this.atEnd()) this.fail("invalid-number", `expected the end of the number, found ${describe(this.src, this.pos)}`)
    return text
  }

  /**
   * Hot: the common literal `-?(0|[1-9][0-9]*)(\.[0-9]+)?` followed by
   * something that can't continue a number (not an identifier character or
   * `.`). Its normalized text is itself. Anything else (separators, an
   * exponent, hex, binary, an error) is left to `anyNumber`: undefined.
   */
  private plainDecimal(): string | undefined {
    const src = this.src
    const start = this.pos
    let i = start
    if (src.charCodeAt(i) === MINUS) i++
    const first = src.charCodeAt(i)
    if (first === DIGIT_0) i++
    else if (first >= DIGIT_1 && first <= DIGIT_9) {
      i++
      while (isDigit(src.charCodeAt(i))) i++
    } else return undefined
    if (src.charCodeAt(i) === DOT && isDigit(src.charCodeAt(i + 1))) {
      i += 2
      while (isDigit(src.charCodeAt(i))) i++
    }
    if (continuesNumber(src.charCodeAt(i))) return undefined
    if (i - start > this.limits.maxNumberLength) return undefined
    this.pos = i
    return src.slice(start, i)
  }

  private anyNumber(): string {
    const start = this.pos
    // The literal (a linear scan), then what follows it, then the limits, as
    // the reference does: a literal that runs into a letter is invalid however
    // long it is. Converted only within the limits, so huge ones stay cheap.
    let radix: "0x" | "0b" | undefined
    let digits: string | undefined
    let end = -1
    for (const [re, r] of [[HEX, "0x"], [BIN, "0b"]] as const) {
      re.lastIndex = start
      const m = re.exec(this.src)
      if (m) {
        radix = r
        digits = m[1]!
        end = re.lastIndex
        break
      }
    }
    if (radix === undefined) {
      DEC.lastIndex = start
      if (!DEC.exec(this.src)) this.fail("invalid-number", "invalid number", start)
      end = DEC.lastIndex
    }
    if (continuesNumber(this.src.charCodeAt(end))) {
      let to = end
      while (continuesNumber(this.src.charCodeAt(to))) to++
      this.fail("invalid-number", `invalid number '${quoteText(this.src.slice(start, to))}'`, start)
    }
    const literal = this.src.slice(start, end)
    if (literal.length > this.limits.maxNumberLength) {
      this.fail("number-too-long", `number literal longer than ${this.limits.maxNumberLength} characters`, start)
    }
    if (radix === "0x") {
      // So that its decimal form fits the number limit too (spec §7). `_` doesn't count; leading zeros do.
      const max = maxHexDigits(this.limits.maxNumberLength)
      if (digits!.length - (digits!.split("_").length - 1) > max) {
        this.fail("number-too-long", `hex literal with more than ${max} hex digits (the number limit is ${this.limits.maxNumberLength} characters in decimal)`, start)
      }
    }
    this.pos = end
    if (radix !== undefined) {
      const n = BigInt(radix + digits!.replaceAll("_", ""))
      // The sign is kept, also on zero: `-0x0` is `-0`, as `-0` is (spec §2).
      return (literal.startsWith("-") ? "-" : "") + n.toString()
    }
    const exp = /[eE]([+-]?)([0-9_]+)$/.exec(literal)
    if (exp && Number(exp[2]!.replaceAll("_", "")) > this.limits.maxExponent) {
      this.fail("exponent-too-large", `exponent larger than ${this.limits.maxExponent}`, start)
    }
    return normalizeExponent(literal.replaceAll("_", "").replace("E", "e"))
  }

  // ── bytes ──────────────────────────────────────────────────

  /** At `x"0b34 ff"`: two hex digits per byte; spaces and tabs between bytes. */
  bytes(): Uint8Array {
    const open = this.pos
    this.pos += 2 // x"
    const out: number[] = []
    for (;;) {
      if (this.atEnd()) this.fail("unterminated-bytes", "unterminated byte string", open)
      const c = this.src.charCodeAt(this.pos)
      if (c === QUOTE) break
      if (c === SPACE || c === TAB) {
        this.pos++
        continue
      }
      const hi = hexValue(c)
      if (hi < 0) {
        this.fail(
          "bytes-not-hex",
          c === LF || c === CR ? "line break in byte string (keep x\"…\" on one line)"
          : `invalid character ${describe(this.src, this.pos)} in byte string (expected hex digits)`,
        )
      }
      const lo = hexValue(this.src.charCodeAt(this.pos + 1))
      // A digit at the end of the input: the literal is unterminated, reported at its start (like the reference).
      if (lo < 0 && this.pos + 1 >= this.src.length) this.fail("unterminated-bytes", "unterminated byte string", open)
      if (lo < 0) this.fail("bytes-odd-digits", "a byte needs two hex digits (an odd number of digits, or a space inside a byte)", this.pos)
      out.push(hi * 16 + lo)
      this.pos += 2
      if (this.pos - open - 2 > this.limits.maxStringLength) this.fail("string-too-long", `byte string longer than ${this.limits.maxStringLength} characters`, open)
    }
    this.pos++ // "
    return Uint8Array.from(out)
  }

  // ── strings ────────────────────────────────────────────────

  /** The `"…"` string at `start`, with the offset after it (spec §4): schema files' quoted keys (§14). */
  basicStringAt(start: number): { readonly value: string; readonly end: number } {
    this.pos = start
    const value = this.basicString()
    return { value, end: this.pos }
  }

  private basicString(): string {
    const open = this.pos
    const src = this.src
    this.pos++ // "
    let out = ""
    let chunk = this.pos
    for (;;) {
      // Hot: skip the run of characters that need no check (a native regex scan, much faster than a loop).
      PLAIN_RUN.lastIndex = this.pos
      PLAIN_RUN.test(src)
      this.pos = PLAIN_RUN.lastIndex
      const c = src.charCodeAt(this.pos)
      if (this.atEnd()) this.fail("unterminated-string", "unterminated string", open)
      if (c === QUOTE) break
      if (c === BACKSLASH) {
        out += this.src.slice(chunk, this.pos)
        out += this.readEscape()
        chunk = this.pos
        continue
      }
      if (isBidiControl(c)) this.fail("bidi-control", `raw bidirectional control character U+${hex4(c)} (write it as \\u{${hex4(c)}})`)
      if (isControl(c)) {
        this.fail(
          c === LF ? "string-line-break" : "control-character",
          c === LF ? "line break in string (use \\n or a \"\"\" block string)"
          : c === TAB ? "raw tab in string (use \\t)"
          : `raw control character U+${hex4(c)} in string (write it as \\u{${hex4(c)}})`,
        )
      }
      this.pos++
    }
    out += this.src.slice(chunk, this.pos)
    this.pos++ // "
    return this.checkStringLength(out, open)
  }

  /** At a backslash. Consumes the escape and returns its text. */
  private readEscape(): string {
    const start = this.pos
    const e = this.src[this.pos + 1]
    this.pos += 2
    switch (e) {
      case '"': return '"'
      case "\\": return "\\"
      case "n": return "\n"
      case "r": return "\r"
      case "t": return "\t"
      case "u": {
        const m = /\{([0-9A-Fa-f]{1,6})\}/y
        m.lastIndex = this.pos
        const r = m.exec(this.src)
        if (!r) this.fail("invalid-unicode-escape", "invalid unicode escape: expected \\u{1-6 hex digits}", start)
        const cp = parseInt(r[1]!, 16)
        if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) this.fail("invalid-unicode-escape", `\\u{${r[1]}} is not a Unicode scalar value`, start)
        this.pos = m.lastIndex
        return String.fromCodePoint(cp)
      }
    }
    const after = this.src.codePointAt(start + 1)
    this.fail("invalid-escape", `invalid escape '\\${after === undefined ? "" : quoteText(String.fromCodePoint(after))}'`, start)
  }

  private blockString(): string {
    const open = this.pos
    this.pos += 3
    while (this.peek() === " " || this.peek() === "\t") this.pos++
    if (this.src.startsWith("\r\n", this.pos)) this.pos += 2
    else if (this.peek() === "\n") this.pos++
    else this.fail("block-string-opening", 'opening """ must be followed by a line break', this.atEnd() ? open : this.pos)

    // Find the closing """, skipping escaped characters.
    const contentStart = this.pos
    let close = -1
    for (let i = this.pos; i < this.src.length; i++) {
      const c = this.src.charCodeAt(i)
      if (c === BACKSLASH) i++
      else if (c === QUOTE && this.src.startsWith('"""', i)) {
        close = i
        break
      }
    }
    if (close < 0) this.fail("unterminated-block-string", "unterminated block string", open)

    // Split into lines, remembering where each starts.
    const lines: { text: string; at: number }[] = []
    let at = contentStart
    for (;;) {
      const nl = this.src.indexOf("\n", at)
      if (nl < 0 || nl >= close) {
        lines.push({ text: this.src.slice(at, close), at })
        break
      }
      const end = nl > at && this.src.charCodeAt(nl - 1) === CR ? nl - 1 : nl
      lines.push({ text: this.src.slice(at, end), at })
      at = nl + 1
    }
    const last = lines.pop()!
    if (!BLANK.test(last.text)) this.fail("block-string-closing", 'closing """ must be on its own line', close)
    const indent = last.text

    const out: string[] = []
    for (const line of lines) {
      if (line.text.startsWith(indent)) out.push(this.decodeBlockLine(line.text.slice(indent.length), line.at + indent.length))
      else if (BLANK.test(line.text)) out.push("")
      else this.fail("block-string-indent", 'line is indented less than the closing """', line.at)
    }
    this.pos = close + 3
    return this.checkStringLength(out.join("\n"), open)
  }

  /** The limit counts characters (code points), not UTF-16 units: an emoji is one character, but two units. */
  private checkStringLength(s: string, open: number): string {
    if (longerThan(s, this.limits.maxStringLength)) {
      this.fail("string-too-long", `string longer than ${this.limits.maxStringLength} characters`, open)
    }
    return s
  }

  /**
   * A record key or tag (spec §7: the string limit counts them too), just read:
   * the error is at its start. Identifiers are ASCII, so characters are units.
   */
  private checkWordLength(word: string, what: "key" | "tag"): string {
    if (word.length > this.limits.maxStringLength) this.fail(what === "key" ? "key-too-long" : "tag-too-long", `${what} longer than ${this.limits.maxStringLength} characters`, this.pos - word.length)
    return word
  }

  /** Process escapes in one block-string line, starting at `at` in the source. */
  private decodeBlockLine(text: string, at: number): string {
    let out = ""
    let i = 0
    let chunk = 0
    while (i < text.length) {
      const c = text.charCodeAt(i)
      if (c === BACKSLASH) {
        out += text.slice(chunk, i)
        const saved = this.pos
        this.pos = at + i
        out += this.readEscape()
        i = this.pos - at
        this.pos = saved
        chunk = i
      } else {
        if (isControl(c) && c !== TAB) this.fail("control-character", `raw control character U+${hex4(c)} in block string (write it as \\u{${hex4(c)}})`, at + i)
        if (isBidiControl(c)) this.fail("bidi-control", `raw bidirectional control character U+${hex4(c)} (write it as \\u{${hex4(c)}})`, at + i)
        i++
      }
    }
    return out + text.slice(chunk)
  }

  // ── trivia & helpers ───────────────────────────────────────

  /**
   * Whitespace and comments from `start`, as between values: the offset after
   * them. Schema files have the same (spec §14); a `/` that starts no comment
   * is left for the caller.
   */
  triviaEnd(start: number): number {
    this.pos = start
    this.skipSpace()
    return this.pos
  }

  /** Whitespace and comments between tokens; a `/` that starts no comment is an error. */
  skipTrivia(): void {
    // Hot, and small enough to be inlined: most tokens follow each other directly.
    const c = this.src.charCodeAt(this.pos)
    if (c === SPACE || c === TAB || c === LF || c === CR || c === SLASH) this.skipTriviaAt()
  }

  private skipTriviaAt() {
    this.skipSpace()
    if (this.src.charCodeAt(this.pos) === SLASH) this.fail("stray-slash", "unexpected '/' (comments are // or /* */)")
  }

  /** Whitespace and comments, up to anything else (a `/` that starts no comment included). */
  private skipSpace() {
    // Hot: character codes, not one-character strings (past the end: NaN, which matches nothing).
    const src = this.src
    for (;;) {
      const c = src.charCodeAt(this.pos)
      if (c === SPACE || c === TAB || c === LF) {
        this.pos++
      } else if (c === CR) {
        if (src.charCodeAt(this.pos + 1) !== LF) this.fail("lone-carriage-return", "carriage return without a line feed (line breaks are LF or CRLF)")
        this.pos += 2
      } else if (c === SLASH && src.charCodeAt(this.pos + 1) === SLASH) { // a line comment
        const nl = src.indexOf("\n", this.pos)
        const end = nl < 0 ? src.length : nl
        this.checkCommentText(this.pos, end)
        if (this.locations) this.comments.push([this.pos, end])
        this.pos = end
      } else if (c === SLASH && src.charCodeAt(this.pos + 1) === STAR) { // a block comment
        this.skipBlockComment()
      } else {
        return
      }
    }
  }

  private skipBlockComment() {
    const open = this.pos
    let depth = 0
    while (this.pos < this.src.length) {
      if (this.src.startsWith("/*", this.pos)) {
        depth++
        this.pos += 2
      } else if (this.src.startsWith("*/", this.pos)) {
        this.pos += 2
        if (--depth === 0) {
          if (this.locations) this.comments.push([open, this.pos])
          return this.checkCommentText(open, this.pos)
        }
      } else {
        this.pos++
      }
    }
    this.fail("unterminated-comment", "unterminated block comment", open)
  }

  /**
   * Comments are where "Trojan Source" attacks hide reordered text, and where
   * control characters (ESC, CSI, NUL) can rewrite what a terminal shows.
   * Allowed: tab, and in block comments line breaks (CR only before LF).
   */
  private checkCommentText(start: number, end: number) {
    for (let i = start; i < end; i++) {
      const c = this.src.charCodeAt(i)
      if (isBidiControl(c)) this.fail("bidi-control", `raw bidirectional control character U+${hex4(c)} in comment`, i)
      if (!isControl(c) || c === TAB || c === LF) continue
      if (c === CR && this.src.charCodeAt(i + 1) === LF) continue
      if (c === CR) this.fail("lone-carriage-return", "carriage return without a line feed (line breaks are LF or CRLF)", i)
      this.fail("control-character", `raw control character U+${hex4(c)} in comment`, i)
    }
  }

  private readIdent(): string {
    const start = this.pos
    IDENT_RUN.lastIndex = start
    IDENT_RUN.test(this.src)
    this.pos = IDENT_RUN.lastIndex
    return this.src.slice(start, this.pos)
  }

  private peek(): string | undefined {
    return this.src[this.pos]
  }

  /**
   * Whether the value before here was a tag without payload: only trivia
   * since `bareTagEnd` (that trivia was read without error before, after the tag).
   */
  private afterBareTag(): boolean {
    if (this.bareTagEnd < 0) return false
    const here = this.pos
    const end = this.triviaEnd(this.bareTagEnd)
    this.pos = here
    return end === here
  }

  /**
   * After a value, something other than a comma (or the closing bracket
   * `close`). Which mistake it is: a payload `(…)` or `{…}` on a line after
   * its tag (the tag took no payload, so anything between them was a line
   * break or a comment), a closing bracket of the wrong kind, or a missing comma.
   */
  private failSeparator(message: string, close?: string): never {
    const c = this.peek()
    const found = describe(this.src, this.pos)
    const reason = `${message}, found ${found}`
    if ((c === "(" || c === "{") && this.afterBareTag()) {
      this.fail("payload-newline", reason, this.pos, { expected: "','", found, hint: `Put the payload on the same line as ${this.bareTag}, or add a comma if they are two values.` })
    }
    if (c === "}" || c === "]" || c === ")") {
      this.fail("unexpected-closer", reason, this.pos, { expected: close === undefined ? "','" : `',' or '${close}'`, found })
    }
    this.fail("missing-comma", reason, this.pos, { expected: "','", found })
  }

  /** Throw a HausSyntaxError at `at` (default: here). */
  fail(code: ErrorCode, reason: string, at: number = this.pos, details?: ErrorDetails): never {
    const p = locate(this.src, at, this.origin)
    throw new HausSyntaxError(reason, p.offset, p.line, p.column, code, details)
  }
}

/** The exponent of a decimal literal as its value (§2): `1e+05` is `1e5`, `1e-0` is `1e0`. */
function normalizeExponent(text: string): string {
  const at = text.indexOf("e")
  if (at < 0) return text
  const negative = text[at + 1] === "-"
  const digits = text.slice(at + 1).replace(/^[+-]/, "").replace(/^0+(?=.)/, "")
  return text.slice(0, at + 1) + (negative && digits !== "0" ? "-" : "") + digits
}
