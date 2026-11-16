/**
 * Documents for the formatter fuzzer (format.ts): valid haus text with
 * comments in every place the formatter treats differently (spec §11), blank
 * lines, CR LF, a byte order mark, streams, positional payloads near the line
 * width, block strings with blanks at the ends of lines, and the spellings a
 * layout keeps (`0xFF_ff`, `1E+05`, `x"9f86 D081"`).
 */
import { basicString, blockString, bytes, file, key, mutate, number, Rng, TAGS } from "./generate.ts"

/** How lines end in one document: LF, CR LF, or either at random. */
export type LineEnding = "\n" | "\r\n" | "mixed"

/** The state of one document being written. */
export class Doc {
  /** Numbers the comments, so that one lost or written twice shows. */
  private comments = 0
  readonly r: Rng
  readonly ending: LineEnding
  constructor(r: Rng, ending: LineEnding) {
    this.r = r
    this.ending = ending
  }

  nl(): string {
    return this.ending === "mixed" ? this.r.pick(["\n", "\r\n"]) : this.ending
  }

  /** A block comment: on one line, nested, over several lines, or with blanks and separators inside. */
  block(): string {
    const n = this.comments++
    const r = this.r
    switch (r.int(6)) {
      case 0: return `/* b${n} */`
      case 1: return `/* b${n} /* nested */ */`
      case 2: return `/* b${n}${this.nl()}   second line  ${this.nl()} */`
      case 3: return `/*b${n}*/`
      case 4: return `/* b${n} trailing blanks \t${this.nl()}*/`
      default: return `/* b${n} café 😀   */`
    }
  }

  /** A line comment with its line ending (none at the end of the file). */
  line(end = true): string {
    const n = this.comments++
    const text = this.r.pick([`// c${n}`, `//c${n}`, `// c${n} ends in blanks \t `, `// c${n} 😀 /* not a block */`, `// c${n}   sep`, `/// c${n}`])
    return end ? text + this.nl() : text
  }

  /** A comment of either kind; a line comment ends its line, so `ind` indents what follows. */
  comment(ind: string): string {
    return this.r.chance(0.5) ? this.block() : this.line() + ind
  }

  /**
   * Whitespace and comments between two tokens, inside a container at
   * indentation `ind`: often nothing or a space, else line breaks, blank
   * lines (some with blanks on them) and comments. `p` is the chance of
   * anything more than a space.
   */
  gap(ind: string, p = 0.3): string {
    const r = this.r
    if (!r.chance(p)) return r.pick(["", " ", " "])
    const parts: string[] = []
    for (let n = 1 + r.int(3); n > 0; n--) {
      switch (r.int(7)) {
        case 0: parts.push(" "); break
        case 1: parts.push(r.pick(["\t", "  "])); break
        case 2: parts.push(this.nl() + ind); break
        case 3: parts.push(this.nl() + r.pick(["", "  ", "\t", " \t "]) + this.nl() + ind); break
        case 4: parts.push(" " + this.block() + " "); break
        default: parts.push(r.pick([" ", ""]) + this.line() + ind)
      }
    }
    return parts.join("")
  }

  /** After an entry's comma: nothing, a comment on the same line, or a line break. */
  afterComma(ind: string): string {
    const r = this.r
    switch (r.int(8)) {
      case 0: return " " + this.line() + ind
      case 1: return " " + this.block() + this.nl() + ind
      case 2: return this.nl() + this.nl() + ind
      case 3: return this.gap(ind, 1)
      case 4: return this.nl() + ind + this.comment(ind) + this.nl() + ind
      default: return r.pick([" ", this.nl() + ind])
    }
  }
}

// ── values ───────────────────────────────────────────────────

const close = { "{": "}", "[": "]", "(": ")" } as const

/**
 * The entries of a container, `open … close`, laid out as people do: on one
 * line, or one per line with comments above them, after their commas, before
 * the closing bracket, and blank lines between them.
 */
function container(d: Doc, open: "{" | "[" | "(", entries: readonly string[], ind: string): string {
  const r = d.r
  const inner = ind + "  "
  const broken = r.chance(0.6)
  if (entries.length === 0) {
    if (r.chance(0.4)) return open + d.gap(inner, 1) + (r.chance(0.5) ? d.nl() + ind : "") + close[open]
    return open + r.pick(["", " "]) + close[open]
  }
  if (!broken) {
    const sep = () => d.gap(inner, 0.1) + "," + d.gap(inner, 0.15)
    return open + d.gap(inner, 0.15) + entries.join(sep()) + (r.chance(0.3) ? sep() : d.gap(inner, 0.15)) + close[open]
  }
  let out = open + (r.chance(0.2) ? " " + d.comment(inner) : "") + d.nl() + inner
  entries.forEach((e, i) => {
    if (r.chance(0.2)) out += d.comment(inner) + (r.chance(0.5) ? d.nl() + inner : " ")
    out += e
    const last = i === entries.length - 1
    // Before the comma: usually nothing, sometimes a comment or a line break.
    if (r.chance(0.08)) out += " " + d.block()
    if (last && r.chance(0.3)) {
      // No trailing comma: maybe a comment, then the closing bracket.
      out += r.chance(0.4) ? " " + d.line() + ind : d.nl() + ind
      return
    }
    out += ","
    out += last ? (r.chance(0.5) ? d.afterComma(inner).replace(/[ \t]*$/, "") + d.nl() + ind : d.nl() + ind) : d.afterComma(inner)
  })
  // Comments before the closing bracket.
  if (r.chance(0.2)) out = out.replace(/[ \t]*$/, "") + inner + d.comment(inner) + d.nl() + ind
  return out + close[open]
}

/** A string as long as `n` code points (some of them wide), for payloads near the line width. */
function longString(r: Rng, n: number): string {
  const fill = r.pick(["a", "a", "é", "😀", "中"])
  return '"' + fill.repeat(n) + '"'
}

/** A positional payload, `Tag(…)`, often of scalars that make its line close to the width. */
function payload(d: Doc, depth: number, ind: string): string {
  const r = d.r
  const tag = r.pick(TAGS)
  const args: string[] = []
  if (r.chance(0.5)) {
    // Scalars adding up to about the width: some lines fit, some are a character too long.
    for (let n = 1 + r.int(4); n > 0; n--) args.push(r.chance(0.5) ? longString(r, r.int(80)) : number(r))
  } else {
    for (let n = 1 + r.int(3); n > 0; n--) args.push(value(d, depth + 1, ind + "  "))
  }
  const space = r.pick(["", "", "", " ", "\t"])
  return tag + space + container(d, "(", args, ind)
}

/** `Tag { … }`, `Tag({ … })` with comments between the parentheses and the braces, or `Tag {}`. */
function recordPayload(d: Doc, depth: number, ind: string): string {
  const r = d.r
  const tag = r.pick(TAGS)
  const rec = record(d, depth, ind)
  if (r.chance(0.6)) return tag + r.pick([" ", " ", "", "\t"]) + rec
  const inner = ind + "  "
  const before = r.chance(0.5) ? d.gap(inner, 1) : ""
  const after = r.chance(0.5) ? d.gap(inner, 1) : ""
  const comma = r.chance(0.2) ? "," + d.gap(inner, 0.5) : ""
  return tag + r.pick(["", "", " "]) + "(" + before + rec + after + comma + ")"
}

function record(d: Doc, depth: number, ind: string): string {
  const r = d.r
  const inner = ind + "  "
  const used = new Set<string>()
  const fields: string[] = []
  for (let n = r.int(5); n > 0; n--) {
    // A key with a raw line separator: every layout writes it escaped.
    const k = r.chance(0.03) ? '"line\u2028sep"' : key(r)
    if (used.has(k)) continue
    used.add(k)
    // Comments between the key and the value move above the entry.
    fields.push(k + d.gap(inner, 0.1) + ":" + d.gap(inner, 0.12) + value(d, depth + 1, inner))
  }
  return container(d, "{", fields, ind)
}

/** One value at nesting `depth`, written at indentation `ind`. */
export function value(d: Doc, depth: number, ind: string): string {
  const r = d.r
  const leaf = depth > 3 || r.chance(0.3)
  switch (r.int(leaf ? 6 : 11)) {
    case 0: return number(r)
    case 1: return basicString(r)
    case 2: return blockString(r, ind + r.pick(["", "  ", "\t"]))
    case 3: return bytes(r)
    case 4: return r.pick(TAGS)
    case 5: return r.chance(0.2) ? longString(r, r.int(90)) : r.pick(["0xFF_ff", "1E+05", 'x"9f86 D081"', "-0x0", "1_000", "0b1010", '"\\u{41}"', "1e-0_5"])
    case 6:
    case 7: return container(d, "[", Array.from({ length: r.int(5) }, () => value(d, depth + 1, ind + "  ")), ind)
    case 8: return record(d, depth, ind)
    case 9: return payload(d, depth, ind)
    default: return recordPayload(d, depth, ind)
  }
}

/** A whole document: an optional byte order mark, then zero or more items, with comments and blank lines between them. */
export function document(r: Rng): string {
  const d = new Doc(r, r.pick<LineEnding>(["\n", "\n", "\n", "\r\n", "mixed"]))
  const bom = r.chance(0.05) ? "\uFEFF" : ""
  const n = r.pick([0, 1, 1, 1, 2, 2, 3, 4])
  let out = bom + (r.chance(0.3) ? d.gap("", 1) : "")
  for (let i = 0; i < n; i++) {
    out += value(d, 0, "")
    const last = i === n - 1
    if (last && r.chance(0.4)) break
    out += (r.chance(0.1) ? d.gap("", 1) : "") + "," + (last ? "" : d.afterComma(""))
  }
  if (r.chance(0.3)) out += d.gap("", 1)
  if (r.chance(0.05)) out += d.line(false) // the last line without a line break
  else if (r.chance(0.7)) out += d.nl()
  return out
}

const enc = new TextEncoder()

const TRIVIA = [" ", "\t", "\n", "\r\n", "\n\n", "\n  \n", "/* t */", " /* t */ ", "// t\n", " // t\n", "/* t\n */", "\n// t\n\n"]

/**
 * Whitespace and comments inserted at random places: between tokens the
 * text stays valid and gets comments where the generator puts none; inside a
 * token it mostly becomes invalid (or, in a string, another string).
 */
export function sprinkle(r: Rng, text: string): string {
  let out = text
  for (let n = 1 + r.int(4); n > 0; n--) {
    const at = r.int(out.length + 1)
    out = out.slice(0, at) + r.pick(TRIVIA) + out.slice(at)
  }
  return out
}

/**
 * A test input: mostly a document from `document`, sometimes one from the
 * parser fuzzer's generator or a file of the suites, some with whitespace
 * and comments sprinkled in, a few mutated (both formatters must then
 * reject them alike).
 */
export function formatInput(r: Rng, seeds: readonly Uint8Array[]): Uint8Array {
  const x = r.next()
  if (x < 0.55) return enc.encode(document(r))
  if (x < 0.7) return enc.encode(sprinkle(r, document(r)))
  if (x < 0.8) return enc.encode(file(r))
  const seed = seeds.length ? r.pick(seeds) : enc.encode(document(r))
  if (x < 0.88) return seed
  if (x < 0.95) return enc.encode(sprinkle(r, new TextDecoder().decode(seed)))
  return mutate(r, r.chance(0.5) ? seed : enc.encode(document(r)))
}
