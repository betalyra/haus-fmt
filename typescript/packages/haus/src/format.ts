/**
 * Serializer and standard formatter (spec §11, "Standard format").
 *
 * Three official layouts, like gofmt there are no other style options:
 * - pretty (default): every non-empty record and array has one entry per
 *   line, each with a trailing comma; short positional payloads stay inline.
 * - compact: every top-level item on a single line, `{ a: 1, b: [1, 2] }`.
 * - minimised: compact without the whitespace between tokens, `{a:1,b:[1,2]}`.
 *
 * Given the source text and comment positions (`parseDocument`), comments
 * and blank lines between entries are kept: a comment on its own line stays
 * above the entry that follows it, a comment after an entry on the same line
 * stays after that entry's comma. The output has LF line endings only, in
 * comments too.
 *
 * Every `Value` is a haus value (value.ts: the constructors check what they
 * build), so writing one can't fail but for a bad option. A value forged past
 * the constructors (with a cast) is not one, and what the writers do with it
 * is undefined (spec §11, "Values built in code").
 */
import { BACKSLASH, BARE_KEY, codePoints, CR, highSurrogates, isBidiControl, isControl, isLineSeparator, LF, QUOTE, TAB, unpairedSurrogate } from "./chars.js"
import { HausEncodeError } from "./errors.js"
import { numberLimitIssue } from "./number.js"
import { DEFAULT_LIMITS, type Limits } from "./parser.js"
import type { HRecord, HVariant, Value } from "./value.js"

/**
 * The layouts of spec §11:
 * - `"pretty"`: one entry per line in every non-empty record and array, comments kept. For people who edit.
 * - `"compact"`: every top-level item on one line, `{ a: 1, b: [1, 2] }`. Comments are dropped. For logs.
 * - `"minimised"`: compact without the whitespace between tokens, `{a:1,b:[1,2]}`. Comments are dropped. For the wire and storage.
 */
export type FormatStyle = "pretty" | "compact" | "minimised"

export interface FormatOptions {
  /** The layout (spec §11): `"pretty"` (default), `"compact"` or `"minimised"`. */
  readonly style?: FormatStyle
  /** Spaces per indentation level (default 2). */
  readonly indent?: number
  /**
   * Line width for positional payloads like `Money(7.90, EUR)` to stay inline
   * (default 80), in code points, counting the comma after the entry.
   */
  readonly width?: number
  /**
   * The text the values were parsed from (with `parseWithLocations` or
   * `parseDocument`). Numbers and single-line strings then keep their
   * original spelling (`0xFF`, `1_000`, escapes), and blank lines between
   * entries are kept.
   */
  readonly source?: string
  /** Comment spans from `parseDocument`; they are kept in the output. Needs `source`. */
  readonly comments?: readonly (readonly [number, number])[]
  /**
   * The number limits (spec §7) a number written from its value must fit, so
   * that a parser with these limits reads it back: its literal's length
   * (`number-too-long`) and its exponent (`exponent-too-large`), a decimal's
   * too (`1.000…`, `1e9999`). A limit not given is the parser's default.
   */
  readonly limits?: Partial<Pick<Limits, "maxNumberLength" | "maxExponent">>
}

/** Format a whole file: one value, or a stream with a comma after each value. */
export function format(values: readonly Value[], options: FormatOptions = {}): string {
  if (oneLine(options)) {
    const f = new Formatter(options)
    if (values.length === 0) return ""
    if (values.length === 1) return f.line(values[0]!) + "\n"
    return values.map((v) => f.line(v) + ",\n").join("")
  }
  const f = new Formatter(options)
  const text = f.file(values)
  return text === "" ? "" : text + "\n"
}

/** Serialize one value (no trailing newline). */
export function stringify(value: Value, options: FormatOptions = {}): string {
  const f = new Formatter(options)
  return oneLine(options) ? f.line(value) : f.value(value)
}

/**
 * An indent or width as given (spec §11): a whole number of at least 0,
 * taken literally (0 means 0). Anything else is a misuse of the API, not a
 * haus error: a `RangeError`.
 */
const wholeOption = (name: "indent" | "width", n: number): number => {
  if (!Number.isSafeInteger(n) || n < 0) throw new RangeError(`${name} must be a whole number of at least 0, not ${String(n)}`)
  return n
}

/** Compact and minimised write every top-level item on one line. */
const oneLine = (options: FormatOptions) => options.style === "compact" || options.style === "minimised"

/** The whitespace between the tokens of a line: compact and pretty have it, minimised has none. */
interface Spacing {
  /** Between items: `, `. */
  readonly comma: string
  /** After a key: `: `. */
  readonly colon: string
  /** Inside the braces of a non-empty record: `{ `, ` }`. */
  readonly open: string
  readonly close: string
  /** Between a tag and its record payload: `Tag { … }`. */
  readonly tag: string
}

const SPACED: Spacing = { comma: ", ", colon: ": ", open: "{ ", close: " }", tag: " " }
const TIGHT: Spacing = { comma: ",", colon: ":", open: "{", close: "}", tag: "" }

/** One entry of a container: a record field, an array item, a payload argument, a top-level value. */
interface Entry {
  /** Source span of the whole entry (key included); undefined without locations. */
  readonly start: number | undefined
  readonly end: number | undefined
  /** Where the value starts (after `key:`); comments before it move above the entry. */
  readonly valueStart: number | undefined
  /** Written before the value: `key: ` for a record field. */
  readonly prefix: string
  /** The width of `prefix`, in code points. */
  readonly prefixWidth: number
  readonly value: Value
}

type Span = readonly [number, number]
const NO_SPANS: readonly Span[] = []

/** The entries of one container (or of the file), being written one after the other. */
interface EntryList {
  readonly entries: readonly Entry[]
  readonly ind: string
  readonly sep: string
  readonly blankAfterMultiline: boolean
  /** Comments placed before, after (on the same line) each entry, and after the last one. */
  readonly leading: readonly (readonly Span[])[]
  readonly trailing: readonly (readonly Span[])[]
  readonly dangling: readonly Span[]
  /** The next entry to write. */
  next: number
  /** Source offset after what was written last, to keep a blank line before the next entry. */
  cursor: number | undefined
  first: boolean
  prevMultiline: boolean
}

/**
 * What is left to write, on a stack: text, a value, the rest of a list of
 * entries, or the end of an entry (its separator and trailing comments).
 * The formatter loops over it instead of recursing, so any depth works.
 */
type Task =
  | { readonly kind: "text"; readonly text: string }
  | { readonly kind: "value"; readonly value: Value; readonly ind: string; readonly used: number }
  | { readonly kind: "entries"; readonly list: EntryList }
  | { readonly kind: "entryEnd"; readonly list: EntryList; readonly index: number; readonly mark: number }

class Formatter {
  private readonly step: string
  private readonly width: number
  private readonly source: string | undefined
  private readonly comments: readonly Span[]
  private readonly limits: Pick<Limits, "maxNumberLength" | "maxExponent">
  /** The spacing of a top-level item on one line: compact's, or none (minimised). */
  private readonly spacing: Spacing

  constructor(options: FormatOptions) {
    this.spacing = options.style === "minimised" ? TIGHT : SPACED
    this.step = " ".repeat(wholeOption("indent", options.indent ?? 2))
    this.width = wholeOption("width", options.width ?? 80)
    this.source = options.source
    this.limits = { ...DEFAULT_LIMITS, ...options.limits }
    this.comments = options.source === undefined ? [] : [...(options.comments ?? [])].sort((a, b) => a[0] - b[0])
  }

  // ── entry points ───────────────────────────────────────────

  file(values: readonly Value[]): string {
    const stream = values.length > 1
    const entries = values.map(entryOf)
    const end = this.source?.length ?? 0
    const list = this.entryList(0, end, entries, "", stream ? "," : "", stream)
    return this.run({ kind: "entries", list }).replace(/\n$/, "")
  }

  /** Pretty: `v` at indentation 0. */
  value(v: Value): string {
    return this.run({ kind: "value", value: v, ind: "", used: 0 })
  }

  /**
   * Compact and minimised: the value on one line, with spaces between tokens
   * (compact) or without (minimised). Multi-line strings use `\n` escapes, so
   * a stream has exactly one item per line (like NDJSON).
   */
  line(v: Value): string {
    return this.inline(v, false, Infinity, this.spacing)!
  }

  // ── single line ────────────────────────────────────────────

  /**
   * `v` on one line, or undefined if it is longer than `budget`. Pretty: also
   * undefined if it can't be written on one line there (a block string, a
   * non-empty record or array). Iterative, like `run`.
   */
  private inline(v: Value, pretty: boolean, budget: number, spacing: Spacing = SPACED): string | undefined {
    // Pretty: a non-empty record or array is always broken over lines.
    if (pretty && (v.kind === "array" ? v.items.length > 0 : v.kind === "record" && v.fields.size > 0)) return undefined
    const { comma, colon } = spacing
    let out = ""
    // The width is in code points: `out.length` less the high surrogates in
    // `out`. Those are counted only once the length is over the budget, each
    // part of `out` once (up to `counted`).
    let highs = 0
    let counted = 0
    const work: Pending[] = [v]
    while (work.length > 0) {
      const x = work.pop()!
      if (typeof x === "string") out += x
      else if (x instanceof FieldsLeft) {
        const next = x.fields.next()
        if (!next.done) {
          const [k, value] = next.value
          out += x.first ? writtenKey(k) + colon : comma + writtenKey(k) + colon
          x.first = false
          work.push(x, value)
        }
      } else {
        switch (x.kind) {
          case "number":
            out += this.number(x)
            break
          case "string":
            if (pretty && x.value.includes("\n")) return undefined
            out += this.basicString(x)
            break
          case "bytes":
            out += this.bytes(x)
            break
          case "array":
            if (pretty && x.items.length > 0) return undefined // pretty: one item per line
            out += "["
            pushItems(work, x.items, comma, "]")
            break
          case "record":
            if (x.fields.size === 0) out += "{}"
            else if (pretty) return undefined // pretty: one field per line
            else {
              out += spacing.open
              work.push(spacing.close, new FieldsLeft(x.fields.entries()))
            }
            break
          case "variant": {
            const args = x.args
            const first = args[0]
            out += x.tag
            if (args.length === 1 && first!.kind === "record") {
              out += spacing.tag
              work.push(first!) // the record, next
            } else if (args.length > 0) {
              out += "("
              pushItems(work, args, comma, ")")
            }
          }
        }
      }
      // Too wide to stay inline anyway: stop early, so nested payloads aren't
      // rendered in full at every level (that would be quadratic in the depth).
      if (out.length > budget) {
        highs += highSurrogates(out, counted)
        counted = out.length
        if (out.length - highs > budget) return undefined
      }
    }
    return out
  }

  // ── multi-line ─────────────────────────────────────────────

  /** Write the tasks, starting with `task`. */
  private run(task: Task): string {
    const out: string[] = []
    const tasks: Task[] = [task]
    while (tasks.length > 0) {
      const t = tasks.pop()!
      switch (t.kind) {
        case "text":
          out.push(t.text)
          break
        case "value":
          this.writeValue(t.value, t.ind, t.used, out, tasks)
          break
        case "entries":
          this.nextEntry(t.list, out, tasks)
          break
        case "entryEnd": {
          const { list, index, mark } = t
          const e = list.entries[index]!
          const trailing = list.trailing[index]!
          const multiline = list.blankAfterMultiline && out.slice(mark).some((s) => s.includes("\n"))
          out.push(`${list.sep}${trailing.length ? " " + trailing.map((c) => this.text(c)).join(" ") : ""}\n`)
          list.cursor = trailing.at(-1)?.[1] ?? e.end
          list.prevMultiline = multiline
        }
      }
    }
    return out.join("")
  }

  /** `v` at indentation `ind`, with `used` columns already taken on the current line: inline if it fits, else broken. */
  private writeValue(v: Value, ind: string, used: number, out: string[], tasks: Task[]): void {
    // A number, string or byte string is written the same whether it fits or not: nothing to try.
    const leaf = v.kind === "number" || v.kind === "string" || v.kind === "bytes"
    if (!leaf && !this.hasComments(v.start, v.end)) {
      const flat = this.inline(v, true, this.width - used)
      if (flat !== undefined) return void out.push(flat)
    }
    switch (v.kind) {
      case "number":
        return void out.push(this.number(v))
      case "string":
        return void out.push(v.value.includes("\n") ? blockString(v.value, ind + this.step) : this.basicString(v))
      case "bytes":
        return void out.push(this.bytes(v))
      case "array":
        return this.container("[", "]", inside(v), v.items.map(entryOf), ind, out, tasks)
      case "record":
        return this.record(v, ind, out, tasks)
      case "variant": {
        const [first] = v.args
        out.push(v.tag)
        if (v.args.length === 0) return
        if (v.args.length === 1 && first?.kind === "record") {
          out.push(" ")
          // In `Tag({ … })`, comments between the parentheses and the braces move inside the braces.
          return this.record(first, ind, out, tasks, this.argsSpan(v) ?? inside(first))
        }
        return this.container("(", ")", this.argsSpan(v), v.args.map(entryOf), ind, out, tasks)
      }
    }
  }

  /** `r` broken over lines; `span` is where its comments are (default: between its braces). */
  private record(r: HRecord, ind: string, out: string[], tasks: Task[], span: Span | undefined = inside(r)): void {
    const entries: Entry[] = []
    for (const [k, v] of r.fields) {
      // A bare key is ASCII: its width is its length.
      const bare = BARE_KEY.test(k)
      const prefix = `${bare ? k : escaped(k)}: `
      const prefixWidth = bare ? k.length + 2 : codePoints(prefix)
      entries.push({ start: r.keySpans?.get(k)?.[0] ?? v.start, end: v.end, valueStart: v.start, prefix, prefixWidth, value: v })
    }
    this.container("{", "}", span, entries, ind, out, tasks)
  }

  /** `open` + one entry per line (comments and blank lines kept) + `close`. */
  private container(open: string, close: string, span: Span | undefined, entries: Entry[], ind: string, out: string[], tasks: Task[]): void {
    const [from, to] = span ?? [undefined, undefined]
    if (entries.length === 0 && !this.hasComments(from, to)) return void out.push(open + close)
    out.push(`${open}\n`)
    tasks.push({ kind: "text", text: ind + close }, { kind: "entries", list: this.entryList(from, to, entries, ind + this.step, ",", false) })
  }

  /**
   * Entries at indentation `ind`, each to be written on its own line(s)
   * ending in "\n", with the comments in [from, to) placed next to them.
   */
  private entryList(from: number | undefined, to: number | undefined, entries: readonly Entry[], ind: string, sep: string, blankAfterMultiline: boolean): EntryList {
    const src = this.source
    if (src === undefined || from === undefined || to === undefined || this.comments.length === 0) {
      // No comments to place: every entry shares one empty list.
      const none = new Array<readonly Span[]>(entries.length).fill(NO_SPANS)
      return { entries, ind, sep, blankAfterMultiline, leading: none, trailing: none, dangling: NO_SPANS, next: 0, cursor: from, first: true, prevMultiline: false }
    }
    const leading: Span[][] = entries.map(() => [])
    const trailing: Span[][] = entries.map(() => [])
    const dangling: Span[] = []
    // Comments and entries are sorted by position, so binary search keeps
    // this linear in the comments of this container (not all comments).
    const starts = entries.map((e) => e.start ?? -1)
    const ends = entries.map((e) => e.end ?? -1)
    for (let k = firstAtOrAfter(this.comments, from); k < this.comments.length; k++) {
      const c = this.comments[k]!
      const [cs, ce] = c
      if (cs >= to) break
      if (ce > to) continue
      const last = countBelow(starts, cs + 1) - 1 // last entry starting at or before cs
      const owner = last >= 0 && cs < ends[last]! ? last : -1
      if (owner >= 0) {
        // Inside an entry: between key and value it moves above the entry;
        // deeper inside, the nested container places it.
        const e = entries[owner]!
        if (e.valueStart !== undefined && cs < e.valueStart) leading[owner]!.push(c)
        continue
      }
      const prev = countBelow(ends, cs + 1) - 1 // last entry ending at or before cs
      const n = countBelow(starts, ce) // first entry starting at or after ce
      const next = n < entries.length ? n : -1
      if (prev >= 0 && !src.slice(entries[prev]!.end, cs).includes("\n")) trailing[prev]!.push(c)
      else if (next >= 0) leading[next]!.push(c)
      else dangling.push(c)
    }
    return { entries, ind, sep, blankAfterMultiline, leading, trailing, dangling, next: 0, cursor: from, first: true, prevMultiline: false }
  }

  /** Write the next entry of `list` (its leading comments, then the entry), or the comments after the last one. */
  private nextEntry(list: EntryList, out: string[], tasks: Task[]): void {
    const { entries, ind } = list
    if (list.next < entries.length) {
      const i = list.next++
      for (const c of list.leading[i]!) {
        this.startLine(list, c[0], out)
        out.push(`${ind}${this.text(c)}\n`)
        list.cursor = c[1]
      }
      const e = entries[i]!
      this.startLine(list, e.start, out)
      out.push(ind + e.prefix)
      tasks.push(
        { kind: "entries", list },
        { kind: "entryEnd", list, index: i, mark: out.length },
        // The comma after the entry counts towards the width.
        { kind: "value", value: e.value, ind, used: ind.length + e.prefixWidth + list.sep.length },
      )
      return
    }
    list.prevMultiline = false
    for (const c of list.dangling) {
      this.startLine(list, c[0], out)
      out.push(`${ind}${this.text(c)}\n`)
      list.cursor = c[1]
    }
  }

  /** Before a line starting at source offset `start`: a blank line if the source had one there (at most one), or after a multi-line entry. */
  private startLine(list: EntryList, start: number | undefined, out: string[]): void {
    const src = this.source
    const cursor = list.cursor
    const blank = src !== undefined && cursor !== undefined && start !== undefined && start > cursor && /\n[ \t]*\r?\n/.test(src.slice(cursor, start))
    if (!list.first && (blank || list.prevMultiline)) out.push("\n")
    list.first = false
    list.prevMultiline = false
  }

  /** A comment's text, with LF line endings (a carriage return in a comment is always part of a CR LF). */
  private text(c: Span): string {
    return this.source!.slice(c[0], c[1]).replaceAll("\r", "")
  }

  /** Is there a comment inside [start, end)? */
  private hasComments(start: number | undefined, end: number | undefined): boolean {
    if (start === undefined || end === undefined || this.comments.length === 0) return false
    const k = firstAtOrAfter(this.comments, start)
    return k < this.comments.length && this.comments[k]![0] < end
  }

  /** The source span between `(` and `)` of a payload, or undefined for `Tag { … }`. */
  private argsSpan(v: HVariant): [number, number] | undefined {
    const src = this.source
    if (src === undefined || v.start === undefined || v.end === undefined) return undefined
    let i = v.start + v.tag.length
    while (src[i] === " " || src[i] === "\t") i++
    return src[i] === "(" ? [i + 1, v.end - 1] : undefined
  }

  // ── leaves ─────────────────────────────────────────────────

  /** The source spelling when reformatting (`0xFF` stays `0xFF`), else the normalized literal, always decimal (spec §11). */
  private number(v: Extract<Value, { kind: "number" }>): string {
    const original = this.original(v)
    if (original !== undefined) return original
    const text = v.text
    // Most numbers are short and have no exponent: nothing to check.
    if (text.length > this.limits.maxNumberLength || text.includes("e")) {
      const issue = numberLimitIssue(text, this.limits)
      if (issue !== undefined) throw new HausEncodeError(issue.reason, [], issue.code)
    }
    return text
  }

  /** `x"…"`: the source spelling when reformatting (spaces kept), else lowercase hex. */
  private bytes(v: Extract<Value, { kind: "bytes" }>): string {
    return this.original(v) ?? `x"${toHex(v.bytes)}"`
  }

  private basicString(v: Extract<Value, { kind: "string" }>): string {
    // The original spelling, unless it was a block string (those span lines),
    // with raw line and paragraph separators escaped (spec §11).
    const original = this.original(v)
    return original !== undefined && original.startsWith('"') && !original.startsWith('"""')
      ? original.replace(SEPARATORS, (ch) => hexEscape(ch.charCodeAt(0)))
      : escaped(v.value)
  }

  /** The value's source text, when formatting a parsed document. */
  private original(v: Value): string | undefined {
    return this.source !== undefined && v.start !== undefined && v.end !== undefined ? this.source.slice(v.start, v.end) : undefined
  }
}

/** The fields of a record being written on one line, from the next one on. */
class FieldsLeft {
  first = true
  constructor(readonly fields: Iterator<[string, Value]>) {}
}

/** What `inline` has left to write: text, a value, or the rest of a record's fields. */
type Pending = Value | string | FieldsLeft

/** `values` next on the `work` stack, separated by commas, then `close`. */
const pushItems = (work: Pending[], values: readonly Value[], comma: string, close: string): void => {
  work.push(close)
  for (let i = values.length - 1; i >= 0; i--) {
    work.push(values[i]!)
    if (i > 0) work.push(comma)
  }
}

/** An array item, a payload argument or a top-level value as an entry. */
const entryOf = (v: Value): Entry => ({ start: v.start, end: v.end, valueStart: v.start, prefix: "", prefixWidth: 0, value: v })

/** The source span between a container's brackets. */
const inside = (v: Value): [number, number] | undefined =>
  v.start !== undefined && v.end !== undefined ? [v.start + 1, v.end - 1] : undefined

/** How many of the ascending numbers `xs` are below `x`. */
const countBelow = (xs: readonly number[], x: number): number => {
  let lo = 0
  let hi = xs.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (xs[mid]! < x) lo = mid + 1
    else hi = mid
  }
  return lo
}

/** Index of the first comment starting at or after `offset`. */
const firstAtOrAfter = (comments: readonly (readonly [number, number])[], offset: number): number => {
  let lo = 0
  let hi = comments.length
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (comments[mid]![0] < offset) lo = mid + 1
    else hi = mid
  }
  return lo
}

// ── keys and strings ─────────────────────────────────────────

/** A record key of a value as every writer writes it: bare if it can be, else quoted. */
export const writtenKey = (k: string): string => (BARE_KEY.test(k) ? k : escaped(k))

/**
 * Any string as a record key, as `writtenKey` writes it (for the compiled
 * codecs, which write the application's strings, not values): one with an
 * unpaired surrogate is HausEncodeError `cannot-encode`.
 */
export const keyText = (k: string): string => (BARE_KEY.test(k) ? k : quote(k))

/** The line and paragraph separators (`isLineSeparator`), to escape in a string's original spelling. */
const SEPARATORS = /[\u2028\u2029]/g
const hexEscape = (c: number) => `\\u{${c.toString(16).toUpperCase()}}`

const HEX = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, "0"))

/** Lowercase hex, two digits per byte. */
export function toHex(data: Uint8Array): string {
  let out = ""
  for (const b of data) out += HEX[b]
  return out
}

/**
 * Any string as a `"…"` string with the minimal escapes. A string with an
 * unpaired surrogate has no UTF-8 form (spec §4), so it can't be written:
 * HausEncodeError `cannot-encode`.
 */
export function quote(s: string): string {
  if (unpairedSurrogate(s) >= 0) throw new HausEncodeError("a string or key with an unpaired surrogate, which has no UTF-8 form", [], "cannot-encode")
  return escaped(s)
}

/**
 * `quote` without the check: for the strings of values (which have a UTF-8
 * form), and for messages (a key in an error's path).
 */
export function escaped(s: string): string {
  // Hot: most strings need no escape at all (the regex scan is native, much faster than a loop here).
  if (!NEEDS_ESCAPE.test(s)) return `"${s}"`
  // Scan UTF-16 units (no character that needs an escape is a surrogate) and
  // copy the runs between escapes whole.
  let out = '"'
  let chunk = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    // Printable ASCII is raw but for `"` and `\`; above it, all but the classes that are escaped.
    if (c >= 0x20 && c < 0x7f ? c !== QUOTE && c !== BACKSLASH : !(isControl(c) || isBidiControl(c) || isLineSeparator(c))) continue
    out += s.slice(chunk, i) + escapeOf(c)
    chunk = i + 1
  }
  return chunk === 0 ? `"${s}"` : `${out}${s.slice(chunk)}"`
}

/** A character `quote` escapes: `"`, `\`, control characters (C0, DEL, C1), separators, bidirectional controls. */
const NEEDS_ESCAPE = /["\\\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]/

/** The escape of a character that `quote` doesn't write raw. */
const escapeOf = (c: number): string =>
  c === QUOTE ? '\\"' : c === BACKSLASH ? "\\\\" : c === LF ? "\\n" : c === CR ? "\\r" : c === TAB ? "\\t" : hexEscape(c)

/**
 * A `"""` block string whose content and closing quotes sit at `ind`. No line
 * ends in a space or tab (spec §11): the last one of a content line that ends
 * in one is written as an escape, so trimming trailing whitespace can't
 * change the value.
 */
function blockString(s: string, ind: string): string {
  const lines = s.split("\n").map((line) => {
    let out = ""
    for (const ch of line) {
      const c = ch.codePointAt(0)!
      if (ch === "\\") out += "\\\\"
      else if (ch === "\r") out += "\\r"
      else if ((isControl(c) && ch !== "\t") || isBidiControl(c) || isLineSeparator(c)) out += hexEscape(c)
      else out += ch
    }
    // A run of three quotes would close the string early: escape every quote
    // that has two more after it, so at most two raw quotes remain in a row.
    out = out.replace(/"(?="")/g, '\\"')
    return out.endsWith(" ") ? out.slice(0, -1) + "\\u{20}" : out.endsWith("\t") ? out.slice(0, -1) + "\\t" : out
  })
  return `"""\n${lines.map((l) => (l === "" ? "" : ind + l)).join("\n")}\n${ind}"""`
}
