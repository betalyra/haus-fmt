/**
 * Differential testing of the formatters (spec §11): generated documents
 * (format-gen.ts) through the TypeScript, Rust, Go and Swift formatters in the
 * pretty, compact and minimised layouts, which must write the same bytes and
 * keep the properties of §11; and generated values through the value writers
 * of TypeScript, Rust, Roc, Go and Swift, which must write what Lean's layout writers
 * write (compact, minimised and pretty), byte for byte. See ../README.md.
 *
 *   node fuzz/src/main.ts --format [--count N] [--seed S] [--out DIR]
 */
import { spawnSync } from "node:child_process"
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"
import { canonical, format, parseAll, parseDocument, stringify, type Value } from "../../typescript/packages/haus/dist/index.js"
import { formatInput } from "./format-gen.ts"
import { Rng } from "./generate.ts"

export const STYLES = ["pretty", "compact", "minimised"] as const
export type Style = (typeof STYLES)[number]

/** Indentation and width, the same for every case of a batch. */
export interface Options {
  readonly indent: number
  readonly width: number
}

/** A formatter's output, or the input rejected (a crash is a finding). */
export type Out = { readonly ok: true; readonly text: string; readonly crash?: undefined } | { readonly ok: false; readonly crash?: string }

/** A property that doesn't hold for an input: which one, and what was seen. */
export interface Failure {
  readonly check: string
  readonly detail: string
}

const root = new URL("../..", import.meta.url).pathname
const RUST = join(root, "rust/target/release/examples/fuzz_runner")
const ROC = join(root, "fuzz/.build/roc-runner")
const GO = join(root, "fuzz/.build/go-runner")
const SWIFT = join(root, "fuzz/.build/swift-runner")
const JVM = join(root, "fuzz/.build/jvm-runner/bin/jvm-runner")
const LEAN = join(root, "spec/lean/.lake/build/bin/haus-ref")

const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })
const enc = new TextEncoder()

// ── properties ───────────────────────────────────────────────

/** The values of a text, as their canonical forms (spec §12); undefined if it isn't haus. */
export function valuesOf(text: string): string | undefined {
  try {
    return JSON.stringify(parseAll(text).map(canonical))
  } catch {
    return undefined
  }
}

/** The texts of a document's comments in order, CR LF as LF: what pretty must keep. */
export function commentTexts(text: string): string[] {
  const { comments } = parseDocument(text)
  return comments.map(([s, e]) => text.slice(s, e).replaceAll("\r", ""))
}

/** What an editor that trims trailing whitespace makes of a text. */
export const trimLines = (text: string) => text.replace(/[ \t]+$/gm, "")

/** The offsets of the lines' last characters that are a space or tab outside a comment. */
export function trailingBlanks(text: string): number[] {
  const { comments } = parseDocument(text)
  const inComment = (i: number) => comments.some(([s, e]) => s <= i && i < e)
  return [...text.matchAll(/[ \t](?=\r?\n|$)/g)].map((m) => m.index).filter((i) => !inComment(i))
}

export const withoutBlankLines = (text: string) => text.split("\n").filter((l) => l !== "").join("\n")

const show = (s: string) => JSON.stringify(s)

/** The number of code points: the width of text (spec §8, §11). */
export const codePoints = (s: string) => [...s].length

/** `text` with the spans replaced by `fill`, one per UTF-16 unit (line breaks too). */
export function mask(text: string, spans: readonly (readonly [number, number])[], fill: string): string {
  let out = ""
  let at = 0
  for (const [s, e] of [...spans].sort((a, b) => a[0] - b[0])) {
    if (s < at) continue
    out += text.slice(at, s) + fill.repeat(e - s)
    at = e
  }
  return out + text.slice(at)
}

const BARE_KEY = /^[a-z_][A-Za-z0-9_]*$/

/** Whether a value can't be on one line in pretty, wherever it is: a block string, a non-empty container. */
const unbreakable = (v: Value): boolean => {
  switch (v.kind) {
    case "string": return v.value.includes("\n")
    case "array": return v.items.length > 0
    case "record": return v.fields.size > 0
    case "variant": return v.args.some(unbreakable)
    default: return false
  }
}

/** A variant with a positional payload, `Tag(…)` (not `Tag { … }`). */
const positional = (v: Extract<Value, { kind: "variant" }>) => v.args.length > 0 && !(v.args.length === 1 && v.args[0]!.kind === "record")

/**
 * The rules of spec §11 that a layout's text shows, checked without either
 * formatter. Returns [check, detail] pairs.
 *
 * Every layout: keys are bare when they can be; raw U+2028 and U+2029 only
 * in comments. Pretty and compact: one space after `:` and `,`, one between
 * a tag and its `{`, none between a tag and its `(`; minimised: no space or
 * tab outside strings and byte strings. Pretty: every non-empty record and
 * array broken over lines, each entry one level deeper than its brackets and
 * block strings one level deeper than their entry; a positional payload
 * inline exactly when it fits the width (in code points, with the comma
 * after the entry) and can be (no comment, block string or non-empty
 * container in it); at most one blank line in a row; in a stream, a comma
 * after every item and a blank line after each multi-line item that another
 * item follows, and a single item without a comma.
 */
export function layoutRules(style: Style, out: string, options: Options): [string, string][] {
  const problems: [string, string][] = []
  const problem = (check: string, detail: string) => problems.push([check, detail])
  const { values, comments } = parseDocument(out)
  const pretty = style === "pretty"
  const lineOf = (at: number) => out.lastIndexOf("\n", at - 1) + 1
  const indentOf = (at: number) => out.slice(lineOf(at), at)
  const spaces = (level: number) => " ".repeat(level * options.indent)
  const hasComment = (start: number, end: number) => comments.some(([s]) => s >= start && s < end)
  const context = (at: number) => show(out.slice(Math.max(0, at - 30), at + 30))
  /** Strings, byte strings and quoted keys: masked, so that only the layout's own characters are left. */
  const literals: [number, number][] = []

  /** `v`, an entry at indentation `level`; `inline` if it is inside a payload written on one line. */
  const walk = (v: Value, level: number, inline: boolean) => {
    const start = v.start!
    const end = v.end!
    const text = out.slice(start, end)
    const broken = text.includes("\n")
    /** The entries of a broken container one level deeper, its closing bracket at `level`. */
    const entries = (starts: readonly number[]) => {
      if (!pretty || !broken) return
      for (const at of starts) if (indentOf(at) !== spaces(level + 1)) problem("indentation", `an entry at ${show(indentOf(at))}, not ${level + 1} levels: ${context(at)}`)
      if (indentOf(end - 1) !== spaces(level)) problem("indentation", `a closing bracket at ${show(indentOf(end - 1))}, not ${level} levels: ${context(end - 1)}`)
    }
    const record = (r: Extract<Value, { kind: "record" }>) => {
      if (pretty && r.fields.size > 0 && !broken) problem("containers", `a record on one line: ${show(text)}`)
      const keys: number[] = []
      for (const [k, x] of r.fields) {
        const [ks, ke] = r.keySpans?.get(k) ?? [x.start!, x.start!]
        keys.push(ks)
        const spelling = out.slice(ks, ke)
        if (BARE_KEY.test(k) === spelling.startsWith('"')) problem("keys", `key ${show(k)} written ${spelling}`)
        if (spelling.startsWith('"')) literals.push([ks, ke])
        walk(x, level + 1, inline)
      }
      entries(keys)
    }
    switch (v.kind) {
      case "string":
        literals.push([start, end])
        if (pretty && !inline && text.startsWith('"""') && indentOf(end - 3) !== spaces(level + 1)) {
          problem("indentation", `a block string closed at ${show(indentOf(end - 3))}, not ${level + 1} levels: ${context(end - 3)}`)
        }
        return
      case "bytes":
        literals.push([start, end])
        return
      case "number":
        return
      case "array":
        if (pretty && v.items.length > 0 && !broken) problem("containers", `an array on one line: ${show(text)}`)
        v.items.forEach((x) => walk(x, level + 1, inline))
        return entries(v.items.map((x) => x.start!))
      case "record":
        return record(v)
      case "variant": {
        if (!positional(v)) return v.args.forEach((x) => (x.kind === "record" ? record(x) : walk(x, level + 1, inline)))
        if (pretty && !inline) {
          const before = codePoints(out.slice(lineOf(start), start))
          const comma = out[end] === "," ? 1 : 0
          if (!broken) {
            // The whole line, without the comments after the entry.
            const lineEnd = out.indexOf("\n", end) < 0 ? out.length : out.indexOf("\n", end)
            const after = comments.find(([s]) => s >= end && s < lineEnd)
            const line = out.slice(lineOf(start), after ? after[0] : lineEnd).trimEnd()
            if (codePoints(line) > options.width) problem("width", `${codePoints(line)} code points, wider than ${options.width}: ${show(line)}`)
          } else if (!hasComment(start, end) && !unbreakable(v)) {
            const flat = format(parseDocument(text).values, { style: "compact", source: text }).replace(/\n$/, "")
            const used = before + codePoints(flat) + comma
            if (used <= options.width) problem("width", `broken, but ${show(flat)} fits in ${used} code points of ${options.width}: ${show(text)}`)
          }
        }
        v.args.forEach((x) => walk(x, level + 1, inline || !broken))
        return entries(v.args.map((x) => x.start!))
      }
    }
  }
  values.forEach((v) => walk(v, 0, false))

  // What the layout itself writes: literals as `s`, comments as `c`.
  const skeleton = mask(mask(out, literals, "s"), comments, "c")
  if (/[\u2028\u2029]/.test(mask(out, comments, "c"))) problem("separators", "a raw U+2028 or U+2029 outside a comment")
  const spacing: [RegExp, string][] =
    style === "minimised"
      ? [[/[ \t]/, "a space or tab"]]
      : [
          [/[A-Za-z0-9_][ \t]+\(/, "a blank between a tag and its ("],
          [/[A-Za-z0-9_](?:\{|[ \t]{2,}\{)/, "not one space between a tag and its {"],
          [/:(?! [^ \t])/, "not one space after :"],
          [/,(?! [^ \t\n]|\n)/, "not one space or a line break after ,"],
          [/[ \t][,:]/, "a blank before , or :"],
          [/[\[(] |\S {2,}|\S [\])]|\t/, "blanks out of place"],
          ...(pretty ? [] : ([[/\{(?! [^ ]|\})|[^ {]\}/, "not one space inside { … }"]] as [RegExp, string][])),
        ]
  for (const [re, what] of spacing) {
    const m = re.exec(skeleton)
    if (m) problem("spacing", `${what}: ${context(m.index)}`)
  }
  if (!pretty) return problems

  const blank = /\n[ \t]*\n[ \t]*\n/.exec(skeleton)
  if (blank) problem("blank lines", `two blank lines in a row: ${context(blank.index)}`)
  values.forEach((v, i) => {
    const comma = out[v.end!] === ","
    if (values.length > 1 && !comma) problem("stream", `item ${i + 1} of a stream without a comma: ${context(v.end!)}`)
    if (values.length === 1 && comma) problem("stream", "a single item with a comma")
    const next = values[i + 1]
    if (next && out.slice(v.start!, v.end!).includes("\n") && !/\n[ \t]*\n/.test(skeleton.slice(v.end!, next.start!))) {
      problem("stream", `no blank line after multi-line item ${i + 1}: ${context(v.end!)}`)
    }
  })
  return problems
}

/** The properties of one layout's output for `input` (spec §11). */
export function layoutFailures(style: Style, input: string, out: string, options: Options): Failure[] {
  const failures: Failure[] = []
  const fail = (check: string, detail: string) => failures.push({ check: `${check}: ${style}`, detail })
  const values = valuesOf(input)
  const outValues = valuesOf(out)
  if (outValues !== values) {
    fail("values", `input ${values}\noutput ${outValues ?? "is not haus"}`)
    return failures
  }
  if (out.includes("\r")) fail("line endings", "a carriage return in the output")
  const count = parseAll(input).length
  if (out !== "" && !out.endsWith("\n")) fail("last line", `no line break at the end: ${show(out.slice(-20))}`)
  if (count === 0 && out !== "" && (style !== "pretty" || commentTexts(input).length === 0)) fail("empty", `output ${show(out)}`)
  for (const [check, detail] of layoutRules(style, out, options)) fail(check, detail)
  if (style === "pretty") {
    const kept = commentTexts(out)
    const had = commentTexts(input)
    if (JSON.stringify(kept) !== JSON.stringify(had)) fail("comments", `input ${show(had.join(" | "))}\noutput ${show(kept.join(" | "))}`)
    const blanks = trailingBlanks(out)
    if (blanks.length > 0) fail("trailing blanks", `at offsets ${blanks.join(", ")}: ${show(out.slice(Math.max(0, blanks[0]! - 30), blanks[0]! + 1))}`)
    if (valuesOf(trimLines(out)) !== values) fail("trimmed", `trimming the lines changes the values: ${valuesOf(trimLines(out)) ?? "not haus"}`)
    return failures
  }
  // Compact and minimised: no comments, one top-level item per line, each a value on its own.
  if (commentTexts(out).length > 0) fail("comments", "a comment in the output")
  const lines = out === "" ? [] : out.slice(0, -1).split("\n")
  if (lines.length !== count) fail("lines", `${count} items on ${lines.length} lines`)
  lines.forEach((line, i) => {
    const one = valuesOf(line)
    if (one === undefined || JSON.parse(one).length !== 1) fail("lines", `line ${i + 1} is not one item: ${show(line)}`)
    if (count > 1 && !line.endsWith(",")) fail("lines", `line ${i + 1} of a stream has no comma`)
    if (count === 1 && line.endsWith(",")) fail("lines", "a single item with a comma")
  })
  return failures
}

// ── formatters ───────────────────────────────────────────────

/** The TypeScript formatter: parse the document, format it keeping comments where the layout does. */
export function tsFormat(bytes: Uint8Array, style: Style, options: Options): Out {
  let text: string
  let doc: ReturnType<typeof parseDocument>
  try {
    text = utf8.decode(bytes)
    doc = parseDocument(text)
  } catch {
    return { ok: false }
  }
  try {
    return { ok: true, text: format(doc.values, { style, indent: options.indent, width: options.width, source: text, comments: doc.comments }) }
  } catch (e) {
    return { ok: false, crash: String(e) }
  }
}

function writeCases(dir: string, cases: readonly Uint8Array[]) {
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(dir, { recursive: true })
  cases.forEach((c, i) => writeFileSync(join(dir, `${String(i).padStart(5, "0")}.haus`), c))
}

/** The cases last written to each directory: the runners of one batch share them. */
const written = new Map<string, readonly Uint8Array[]>()

/** A runner's line: `ok <JSON>` or `err …`. */
const parseOut = <T>(line: string): { ok: true; json: T } | { ok: false; reason: string } =>
  line.startsWith("ok ") ? { ok: true, json: JSON.parse(line.slice(3)) as T } : { ok: false, reason: line.slice(4) }

/**
 * `program [...args] DIR N` over the cases, one line each; if it crashes,
 * case by case, so that the crash is reported for the case that has it.
 */
function external(program: string, args: readonly string[], dir: string, cases: readonly Uint8Array[]): string[] {
  if (written.get(dir) !== cases) {
    writeCases(dir, cases)
    written.set(dir, cases)
  }
  const p = spawnSync(program, [...args, dir, String(cases.length)], { maxBuffer: 1 << 30, encoding: "utf8" })
  if (p.error) throw new Error(`${program}: ${p.error.message} (run sh fuzz/build.sh)`)
  if (p.status === 0) {
    const lines = p.stdout.split("\n").filter((l) => l !== "")
    if (lines.length !== cases.length) throw new Error(`${program}: ${lines.length} results for ${cases.length} cases`)
    return lines
  }
  if (cases.length === 1) return [`crash ${(p.stderr || String(p.signal)).trim().split("\n").slice(0, 3).join(" ")}`]
  return cases.map((c) => external(program, args, `${dir}-single`, [c])[0]!)
}

/** A formatter that is a separate program: `program --format STYLE --indent N --width N DIR N`. */
interface Formatter {
  readonly name: string
  readonly program: string
  /** Whether it can be given these options. */
  readonly takes: (options: Options) => boolean
}

/**
 * The formatters compared with TypeScript's: Rust's (`fuzz_runner --format`),
 * Go's (`go-runner --format`, `haus.Format`), Swift's (`swift-runner
 * --format`, `format`) and the JVM's (`jvm-runner --format`, `Haus.format`).
 * Go's options take 0 as the default (indent 2, width 80), so it can't be
 * given an indent or width of 0 and sits out those batches; the JVM takes
 * every option.
 */
const FORMATTERS: readonly Formatter[] = [
  { name: "rust", program: RUST, takes: () => true },
  { name: "go", program: GO, takes: (o) => o.indent > 0 && o.width > 0 },
  { name: "swift", program: SWIFT, takes: () => true },
  { name: "jvm", program: JVM, takes: () => true },
]

const formattersFor = (options: Options) => FORMATTERS.filter((f) => f.takes(options))

/** An external formatter's outputs. */
function externalFormat(f: Formatter, dir: string, cases: readonly Uint8Array[], style: Style, options: Options): Out[] {
  if (cases.length === 0) return []
  const args = ["--format", style, "--indent", String(options.indent), "--width", String(options.width)]
  return external(f.program, args, dir, cases).map((line) => {
    if (line.startsWith("crash ")) return { ok: false, crash: line }
    const r = parseOut<string>(line)
    return r.ok ? { ok: true, text: r.json } : { ok: false }
  })
}

const describeOut = (o: Out | undefined) => (o === undefined ? "-" : o.ok ? show(o.text) : o.crash ? `CRASH ${o.crash}` : "rejected")
const same = (a: Out, b: Out) => (a.ok && b.ok ? a.text === b.text : a.ok === b.ok && !a.crash && !b.crash)

/**
 * Every property of §11 for each case, in each layout: the TypeScript,
 * Rust and Go formatters agree byte for byte, the output keeps the values
 * (and in pretty every comment, in order), formatting it again changes
 * nothing, minimised formatted as pretty is compact formatted as pretty and
 * the pretty file without its comments and blank lines, and the layouts' own
 * rules hold (`layoutFailures`). Returns the failures of each case.
 */
export function checkFormat(dir: string, cases: readonly Uint8Array[], options: Options): Failure[][] {
  const failures: Failure[][] = cases.map(() => [])
  const formatters = formattersFor(options)
  /** A failure for each external formatter whose output differs from TypeScript's. */
  const compare = (i: number, what: string, t: Out, others: readonly Out[]) =>
    formatters.forEach((f, k) => {
      const o = others[k]!
      if (!same(t, o)) failures[i]!.push({ check: `${f.name} ≠ typescript: ${what}`, detail: `typescript ${describeOut(t)}\n${f.name.padEnd(10)} ${describeOut(o)}` })
    })
  const outs = new Map<Style, Out[]>()
  for (const style of STYLES) {
    const ts = cases.map((c) => tsFormat(c, style, options))
    const others = formatters.map((f) => externalFormat(f, join(dir, "input"), cases, style, options))
    outs.set(style, ts)
    ts.forEach((t, i) => {
      if (t.crash) failures[i]!.push({ check: `crash: typescript ${style}`, detail: t.crash })
      formatters.forEach((f, k) => {
        const crash = others[k]![i]!.crash
        if (crash) failures[i]!.push({ check: `crash: ${f.name} ${style}`, detail: crash })
      })
      compare(i, style, t, others.map((o) => o[i]!))
      if (t.ok) failures[i]!.push(...layoutFailures(style, utf8.decode(cases[i]!), t.text, options))
    })
  }

  // Round two, on the outputs: each layout again (idempotence), and compact and minimised as pretty.
  const accepted = cases.flatMap((_, i) => (STYLES.every((s) => outs.get(s)![i]!.ok) ? [i] : []))
  const text = (s: Style, i: number) => (outs.get(s)![i] as { text: string }).text
  const inputsOf = new Map<Style, Uint8Array[]>()
  /** Every formatter's output, TypeScript's first, for each accepted case. */
  const again = (input: Style, style: Style): (readonly Out[])[] => {
    const inputs = inputsOf.get(input) ?? accepted.map((i) => enc.encode(text(input, i)))
    inputsOf.set(input, inputs)
    const ts = inputs.map((c) => tsFormat(c, style, options))
    const others = formatters.map((f) => externalFormat(f, join(dir, input), inputs, style, options))
    return accepted.map((i, k) => {
      const all = [ts[k]!, ...others.map((o) => o[k]!)]
      compare(i, `${input} → ${style}`, all[0]!, all.slice(1))
      return all
    })
  }
  const names = ["typescript", ...formatters.map((f) => f.name)]
  for (const style of STYLES) {
    again(style, style).forEach((all, k) => {
      const i = accepted[k]!
      const out = text(style, i)
      all.forEach((o, n) => {
        if (!o.ok || o.text !== out) failures[i]!.push({ check: `idempotence: ${style} (${names[n]})`, detail: `once  ${show(out)}\ntwice ${describeOut(o)}` })
      })
    })
  }
  const fromCompact = again("compact", "pretty")
  again("minimised", "pretty").forEach((all, k) => {
    const i = accepted[k]!
    all.forEach((m, n) => {
      const c = fromCompact[k]![n]!
      if (!same(m, c)) failures[i]!.push({ check: `minimised → pretty (${names[n]})`, detail: `pretty(minimised) ${describeOut(m)}\npretty(compact)   ${describeOut(c)}` })
    })
    // The pretty file without its comments and blank lines (spec §11).
    const t = all[0]!
    if (t.ok) {
      const input = utf8.decode(cases[i]!)
      const { values } = parseDocument(input)
      const bare = format(values, { style: "pretty", indent: options.indent, width: options.width, source: input, comments: [] })
      if (withoutBlankLines(t.text) !== withoutBlankLines(bare)) {
        failures[i]!.push({ check: "minimised → pretty = pretty without comments", detail: `pretty(minimised)  ${show(t.text)}\npretty, no comments ${show(bare)}` })
      }
    }
  })
  return failures
}

// ── value writers ────────────────────────────────────────────

/**
 * What a value writer wrote for a case: each value alone (no line break
 * after it), and, where the binding has a writer for them, the whole file
 * (one value alone, more each followed by a comma; spec §6, §11) or a stream
 * (every value followed by a comma); or why it couldn't.
 */
type Written =
  | { readonly ok: true; readonly values: readonly string[]; readonly file?: string | null; readonly stream?: string | null }
  | { readonly ok: false; readonly reason: string }

function externalWritten(program: string, args: readonly string[], dir: string, cases: readonly Uint8Array[]): Written[] {
  return external(program, args, dir, cases).map((line) => {
    if (line.startsWith("crash ")) return { ok: false, reason: line }
    const r = parseOut<{ values: string[]; file?: string | null; stream?: string | null }>(line)
    return r.ok ? { ok: true, ...r.json } : { ok: false, reason: r.reason }
  })
}

const describeValues = (w: Written) => (w.ok ? JSON.stringify(w.values) : `err ${w.reason}`)

/** A value writer that is a separate program, and its arguments for a layout and options (undefined: it can't be given them). */
interface Writer {
  readonly name: string
  readonly program: string
  readonly args: (style: Style, options: Options) => readonly string[] | undefined
}

/**
 * The value writers compared with Lean's: Rust's `to_string`,
 * `to_string_minimised` and `to_string_all` (`fuzz_runner --write`), Roc's
 * `Encode.to_str`, `Encode.minimised`, `Encode.stream` and
 * `Encode.stream_minimised` (`runner.roc --write`), neither with a pretty
 * writer from values; and Go's `FormatValue` and `FormatValues` in every
 * layout (`go-runner --write`; its options take 0 as the default, so it sits
 * out pretty with an indent or width of 0); Swift's `stringify` and
 * `stringifyAll` in every layout (`swift-runner --write`); and the JVM's
 * `Haus.write` and `Haus.writeAll` in every layout, with every option
 * (`jvm-runner --write`). TypeScript's `stringify` and `format` run in this
 * process.
 */
const WRITERS: readonly Writer[] = [
  { name: "rust", program: RUST, args: (s) => (s === "pretty" ? undefined : ["--write", s]) },
  { name: "roc", program: ROC, args: (s) => (s === "pretty" ? undefined : ["--write", s]) },
  {
    name: "go",
    program: GO,
    args: (s, o) => (s !== "pretty" ? ["--write", s] : o.indent > 0 && o.width > 0 ? ["--write", s, "--indent", String(o.indent), "--width", String(o.width)] : undefined),
  },
  { name: "swift", program: SWIFT, args: (s, o) => ["--write", s, "--indent", String(o.indent), "--width", String(o.width)] },
  { name: "jvm", program: JVM, args: (s, o) => ["--write", s, "--indent", String(o.indent), "--width", String(o.width)] },
]

/** Lean's layout argument: pretty with the options. */
const leanLayout = (style: Style, o: Options) => (style === "pretty" ? ["pretty", String(o.indent), String(o.width)] : [style])

/**
 * The value writers on the values of the cases that parse (no source text,
 * so numbers are normalized and byte strings lowercase), in each layout and
 * with the batch's options, against Lean's layout writers (`haus-ref
 * --write-batch`: spec/lean/Haus/Layout, proven to parse back): TypeScript's
 * `stringify` and `format` and the writers of `WRITERS` must write each
 * value, and the file or stream where they have a writer for it, byte for
 * byte as Lean does. Lean's text is also read back without any writer: it
 * must hold the values and keep the layout's rules (`layoutRules`), which
 * checks the checks.
 */
export function checkWriters(dir: string, cases: readonly Uint8Array[], options: Options): Failure[][] {
  const failures: Failure[][] = cases.map(() => [])
  const parsed = cases.map((c) => {
    try {
      return parseAll(utf8.decode(c))
    } catch {
      return undefined
    }
  })
  const input = join(dir, "input")
  for (const style of STYLES) {
    const lean = externalWritten(LEAN, ["--write-batch", ...leanLayout(style, options)], input, cases)
    const writers = WRITERS.flatMap((w) => {
      const args = w.args(style, options)
      return args ? [{ name: w.name, out: externalWritten(w.program, args, input, cases) }] : []
    })
    const opts = { style, indent: options.indent, width: options.width }
    parsed.forEach((values, i) => {
      if (!values) return
      const fail = (check: string, detail: string) => failures[i]!.push({ check: `${check} (${style})`, detail })
      const reference = lean[i]!
      if (!reference.ok) return fail("writer: lean rejects", `err ${reference.reason}`)
      let ts: Written
      try {
        ts = { ok: true, values: values.map((v) => stringify(v, opts)), file: format(values, opts) }
      } catch (e) {
        ts = { ok: false, reason: String(e) }
      }
      const stream = reference.values.map((v) => v + ",\n").join("")
      for (const { name, out } of [{ name: "typescript", out: ts }, ...writers.map((w) => ({ name: w.name, out: w.out[i]! }))]) {
        if (describeValues(out) !== describeValues(reference)) {
          fail(`writer: ${name} ≠ lean`, `lean       ${describeValues(reference)}\n${name.padEnd(10)} ${describeValues(out)}`)
        }
        if (!out.ok) continue
        if (out.file != null && out.file !== reference.file) fail(`writer file: ${name} ≠ lean`, `lean       ${show(reference.file!)}\n${name.padEnd(10)} ${show(out.file)}`)
        if (out.stream != null && out.stream !== stream) fail(`writer stream: ${name} ≠ lean`, `lean       ${show(stream)}\n${name.padEnd(10)} ${show(out.stream)}`)
      }
      // Lean's text, read back without any writer.
      reference.values.forEach((text, j) => {
        const one = valuesOf(text)
        if (one !== JSON.stringify([canonical(values[j]!)])) fail("writer values", `${show(text)} reads as ${one ?? "not haus"}, not ${canonical(values[j]!)}`)
        if (style !== "pretty" && /[\n\r\u2028\u2029]/.test(text)) fail("writer lines", show(text))
        for (const [check, detail] of layoutRules(style, text, options)) fail(`writer ${check}`, detail)
      })
      const file = reference.file!
      if (valuesOf(file) !== JSON.stringify(values.map(canonical))) fail("writer file values", `${show(file)} reads as ${valuesOf(file) ?? "not haus"}`)
      for (const [check, detail] of layoutRules(style, file, options)) fail(`writer file ${check}`, detail)
    })
  }
  return failures
}

// ── run ──────────────────────────────────────────────────────

type Checker = (dir: string, cases: readonly Uint8Array[]) => Failure[][]

/**
 * The smallest input that still fails `check`, found by removing ever
 * smaller slices (delta debugging), each round checked as one batch.
 */
function shrink(bytes: Uint8Array, check: string, run: Checker): Uint8Array {
  let best = bytes
  let size = Math.max(1, best.length >> 1)
  for (let round = 0; round < 300 && best.length > 1; round++) {
    const candidates: Uint8Array[] = []
    for (let at = 0; at < best.length; at += size) candidates.push(Uint8Array.from([...best.subarray(0, at), ...best.subarray(at + size)]))
    const results = run(dir("shrink"), candidates)
    const i = results.findIndex((fs) => fs.some((f) => f.check === check))
    if (i >= 0) best = candidates[i]!
    else if (size > 1) size >>= 1
    else break
  }
  return best
}

let outDir = "fuzz/.out"
const dir = (name: string) => join(outDir, "format", name)

/** Every layout's output of both formatters, for a report. */
function outputs(bytes: Uint8Array, options: Options): string {
  return STYLES.flatMap((style) => {
    const t = tsFormat(bytes, style, options)
    const others = formattersFor(options).map((f) => `  ${"".padEnd(9)} ${f.name.padEnd(10)} ${describeOut(externalFormat(f, dir("report"), [bytes], style, options)[0])}`)
    return [`  ${style.padEnd(9)} typescript ${describeOut(t)}`, ...others]
  }).join("\n")
}

const OPTIONS: readonly Options[] = [{ indent: 4, width: 40 }, { indent: 1, width: 100 }, { indent: 2, width: 20 }, { indent: 8, width: 60 }, { indent: 0, width: 0 }]

export async function run(argv: readonly string[]): Promise<number> {
  const { values: args } = parseArgs({
    args: [...argv],
    strict: false,
    options: {
      count: { type: "string", default: "2000" },
      seed: { type: "string", default: String(Date.now() % 1_000_000) },
      out: { type: "string", default: "fuzz/.out" },
      batch: { type: "string", default: "1000" },
    },
  })
  const count = Number(args.count)
  const seed = Number(args.seed)
  const batch = Number(args.batch)
  outDir = String(args.out)
  const suite = join(root, "test-suite")
  const seeds = [join(suite, "valid"), join(suite, "format/cases"), join(suite, "format/examples")].flatMap((d) =>
    readdirSync(d).filter((f) => f.endsWith(".haus")).map((f) => new Uint8Array(readFileSync(join(d, f)))))

  const rng = new Rng(seed)
  const started = Date.now()
  /** Per check: how many cases failed it, and the shrunk inputs (at most a few per check). */
  const found = new Map<string, { count: number; inputs: Map<string, { bytes: Uint8Array; options: Options; formatter: boolean; failure: Failure }> }>()
  let accepted = 0
  let comments = 0
  let streams = 0
  const MAX_SHRUNK = 3

  console.log(`seed ${seed}: ${count} documents through the typescript, rust, go, swift and jvm formatters (pretty, compact, minimised), their values through the lean, typescript, rust, roc, go, swift and jvm writers`)
  for (let done = 0; done < count; done += batch) {
    // Most batches use the default options; some another indentation and width.
    const options = rng.chance(0.7) ? { indent: 2, width: 80 } : rng.pick(OPTIONS)
    const cases = Array.from({ length: Math.min(batch, count - done) }, () => formatInput(rng, seeds))
    const formatRun: Checker = (d, cs) => checkFormat(d, cs, options)
    const writeRun: Checker = (d, cs) => checkWriters(d, cs, options)
    const results = [formatRun(dir("cases"), cases), writeRun(dir("cases"), cases)]
    cases.forEach((c, i) => {
      try {
        const doc = parseDocument(utf8.decode(c))
        accepted++
        if (doc.comments.length > 0) comments++
        if (doc.values.length > 1) streams++
      } catch {}
      results.forEach((rs, kind) => {
        for (const f of rs[i]!) {
          const entry = found.get(f.check) ?? { count: 0, inputs: new Map() }
          found.set(f.check, entry)
          entry.count++
          if (entry.inputs.size >= MAX_SHRUNK) continue
          const small = shrink(c, f.check, kind === 0 ? formatRun : writeRun)
          const key = show(Buffer.from(small).toString("latin1"))
          if (entry.inputs.has(key)) continue
          const failure = (kind === 0 ? formatRun : writeRun)(dir("shrink"), [small])[0]!.find((x) => x.check === f.check) ?? f
          entry.inputs.set(key, { bytes: small, options, formatter: kind === 0, failure })
        }
      })
    })
  }
  const seconds = (Date.now() - started) / 1000
  console.log(`${accepted} accepted (${comments} with comments, ${streams} streams), ${count - accepted} rejected; ${seconds.toFixed(1)} s`)

  rmSync(join(outDir, "format", "failures"), { recursive: true, force: true })
  mkdirSync(join(outDir, "format", "failures"), { recursive: true })
  if (found.size === 0) {
    console.log("no disagreements")
    return 0
  }
  let n = 0
  for (const [check, { count: times, inputs }] of found) {
    console.log(`\nFAILED ${check}: ${times} cases`)
    for (const { bytes, options, formatter, failure } of inputs.values()) {
      const name = join(outDir, "format", "failures", String(n++))
      const report = [
        `check: ${check}`,
        `input: ${show(Buffer.from(bytes).toString("utf8"))}`,
        `options: indent ${options.indent}, width ${options.width}`,
        failure.detail,
        ...(formatter ? ["outputs:", outputs(bytes, options)] : []),
      ].join("\n")
      writeFileSync(`${name}.haus`, bytes)
      writeFileSync(`${name}.txt`, report + "\n")
      console.log(`(shrunk, saved to ${name}.haus)\n${report}`)
    }
  }
  return 1
}
