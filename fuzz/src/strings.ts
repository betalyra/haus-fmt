/**
 * Differential testing of the string APIs (spec §4 "Host strings", §11,
 * §12; gap G1 of plans/notes/haus-json-issues-analysis.md): text given as
 * the language's string, not bytes, in the bindings whose strings can hold
 * an unpaired surrogate (UTF-16 in JavaScript and Java, Python's `str`).
 * Generated documents, schema files and JSON get lone surrogates put
 * anywhere in them (in strings, keys, comments, between tokens) or not, and
 * go through each binding's parser, formatter, schema-file reader and JSON
 * import; strings with them are built into values (a string, a key, a tag)
 * and written. The runners must agree, and with the spec: text with an
 * unpaired surrogate is `invalid-utf8` at its place when read, and a value
 * holding one is `cannot-encode` when written, hashed or put in canonical
 * form. Rust, Go, Swift, Roc and Zig strings are UTF-8 (or bytes) and can't
 * hold one: they sit out (the byte fuzzers cover them). See ../README.md,
 * "String APIs".
 *
 *   node fuzz/src/main.ts --strings [--count N] [--seed S] [--runners typescript,effect,python,jvm]
 *
 * A runner reads lines `KIND HEX`, the text as hex of its UTF-16 code units
 * (big-endian), and prints one line per case:
 *
 *   P (parse)      `ok C1,C2,…` (each value's canonical form, hex of UTF-8) or `err LINE COLUMN CODE`
 *   F (format)     `ok HEX` (the pretty layout, hex of UTF-8) or `err LINE COLUMN CODE`
 *   S (schema)     `ok` or `err LINE COLUMN CODE`
 *   J (JSON)       `ok C` (the canonical form of the imported value) or `err CODE`
 *   W (values)     `ok R R R`: the text as a string, as a record's key and as a tag, each built and
 *                  then written; R is `C/H/W`, the outcomes of canonical, hash and the compact
 *                  writer, each `ok` or the code, or `!CODE` when the constructor rejects it
 */
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"
import { pathToFileURL } from "node:url"
import * as h from "../../typescript/packages/haus/dist/index.js"
import { file as hausFile, Rng } from "./generate.ts"
import { external, fromUtf16Hex, inProcess, type LineRunner, utf16Hex } from "./lines.ts"
import { schemaFile } from "./schema-check-gen.ts"

const root = new URL("../..", import.meta.url).pathname
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })

// ── generating ───────────────────────────────────────────────

const LONE = ["\ud800", "\udbff", "\udc00", "\udfff"]
const JSON_TEXTS = ['{"a": "x", "b": [1, 2.5, true, null]}', '"s"', '[{"k": "v"}, "😀"]', '{"": {"é": -0}}', "  1e5 ", '{"a":"\\u00e9"}']

export interface StringCase {
  readonly kind: "P" | "F" | "S" | "J" | "W"
  readonly text: string
}

/** Whether the text holds an unpaired surrogate. */
export const lone = (s: string) => /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(s)

/** Lone surrogates put somewhere in `s`, none (a control case), or a pair (valid). */
function spoil(r: Rng, s: string): string {
  const units = s.split("")
  const n = r.chance(0.15) ? 0 : 1 + (r.chance(0.2) ? r.int(3) : 0)
  for (let i = 0; i < n; i++) {
    const at = r.int(units.length + 1)
    // Inside a string or comment, where a parser reads anything, or anywhere at all.
    const what = r.chance(0.15) ? ["\ud83d", "\ude00"] : [r.pick(LONE)]
    units.splice(at, 0, ...what)
  }
  return units.join("")
}

export function stringCase(r: Rng): StringCase {
  const x = r.int(10)
  if (x < 4) {
    const doc = hausFile(r)
    return { kind: r.chance(0.75) ? "P" : "F", text: spoil(r, doc) }
  }
  if (x < 6) {
    let text: string
    try {
      text = utf8.decode(schemaFile(r).bytes)
    } catch {
      // Not UTF-8 (the generator makes some): a file of its own instead.
      text = "type A = { s: String } // é"
    }
    return { kind: "S", text: spoil(r, text) }
  }
  if (x < 7) return { kind: "J", text: spoil(r, r.pick(JSON_TEXTS)) }
  return { kind: "W", text: spoil(r, r.pick(["", "a", "Tag", "Some", "x y", "é", "😀", "A_1", "ab"]).repeat(1 + r.int(2))) }
}

// ── TypeScript, Effect ───────────────────────────────────────

const code = (e: unknown): string => {
  const c = (e as { code?: unknown }).code
  if (typeof c === "string") return c
  throw e
}
const placed = (e: unknown): string => {
  const c = code(e)
  const x = e as { line?: number; column?: number }
  return `err ${x.line ?? 0} ${x.column ?? 0} ${c}`
}
const hex8 = (s: string) => Buffer.from(s, "utf8").toString("hex")

function tsWrite(build: () => h.Value): string {
  let v: h.Value
  try {
    v = build()
  } catch (e) {
    return `!${code(e)}`
  }
  const one = (f: () => unknown) => {
    try {
      f()
      return "ok"
    } catch (e) {
      return code(e)
    }
  }
  // hash is canonical's SHA-256: its error is canonical's (it is async, so it is checked through canonical here).
  return [one(() => h.canonical(v)), one(() => h.canonical(v)), one(() => h.stringify(v, { style: "compact" }))].join("/")
}

function tsOne(l: string): string {
  const [kind, hex] = l.split(" ") as [StringCase["kind"], string]
  const text = fromUtf16Hex(hex ?? "")
  switch (kind) {
    case "P":
      try {
        return `ok ${h.parseAll(text).map((v) => hex8(h.canonical(v))).join(",") || "-"}`
      } catch (e) {
        return placed(e)
      }
    case "F":
      try {
        const doc = h.parseDocument(text)
        return `ok ${hex8(h.format(doc.values, { style: "pretty", source: text, comments: doc.comments }))}`
      } catch (e) {
        return placed(e)
      }
    case "S":
      try {
        h.compileSchemaFile(text)
        return "ok"
      } catch (e) {
        return placed(e)
      }
    case "J":
      try {
        return `ok ${hex8(h.canonical(h.importJson(text)))}`
      } catch (e) {
        return `err ${code(e)}`
      }
    case "W":
      return `ok ${tsWrite(() => h.str(text))} ${tsWrite(() => h.rec([[text, h.num("1")]]))} ${tsWrite(() => h.variant(text))}`
  }
}

async function effectRunner(): Promise<LineRunner> {
  const Haus = await import(pathToFileURL(join(root, "typescript/packages/effect/dist/index.js")).href)
  return inProcess("effect", (l) => {
    const [kind, hex] = l.split(" ") as [string, string]
    if (kind !== "S") return "skip"
    try {
      Haus.compileSchemaFile(fromUtf16Hex(hex ?? ""))
      return "ok"
    } catch (e) {
      return placed(e)
    }
  })
}

const ALL = ["typescript", "effect", "python", "jvm"]

async function runner(name: string): Promise<LineRunner> {
  switch (name) {
    case "typescript": return inProcess("typescript", tsOne)
    case "effect": return effectRunner()
    case "python": return external("python", join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/api_runner.py"), "--strings"])
    case "jvm": return external("jvm", join(root, "fuzz/.build/jvm-runner/bin/jvm-runner"), ["--strings"])
  }
  throw new Error(`unknown runner ${name} (${ALL.join(", ")}; the other bindings' strings can't hold a lone surrogate)`)
}

// ── comparing ────────────────────────────────────────────────

/** What the spec says a case gives, where it says: invalid-utf8 when read, cannot-encode when written. */
function expected(c: StringCase): string | undefined {
  if (!lone(c.text)) return undefined
  if (c.kind === "W") return "cannot-encode"
  if (c.kind === "J") return undefined
  return "invalid-utf8"
}

/** Whether an outcome is what the spec says. */
function meets(c: StringCase, o: string): boolean {
  const want = expected(c)
  if (want === undefined) return true
  if (c.kind === "W") {
    // Each part: the constructor rejects it (!cannot-encode), or every writer does (cannot-encode/cannot-encode/cannot-encode).
    // A tag with a lone surrogate isn't a tag either: invalid-tag is the other code it may have.
    const parts = o.split(" ").slice(1)
    const ok = (p: string, codes: readonly string[]) => codes.some((x) => p === `!${x}` || p === `${x}/${x}/${x}`)
    const stringy = (s: string) => ok(s, ["cannot-encode"])
    return parts.length === 3 && stringy(parts[0]!) && stringy(parts[1]!) && ok(parts[2]!, ["cannot-encode", "invalid-tag"])
  }
  return o.startsWith("err ") && o.endsWith(` ${want}`)
}

/**
 * What of an outcome is compared. An error's place only for `invalid-utf8`,
 * whose place §4 fixes (one column at the surrogate); other places are
 * informative (errors.md). A tag with an unpaired surrogate is no tag and
 * has no UTF-8 form: §11 gives it both `invalid-tag` and `cannot-encode`,
 * and doesn't say which comes first (finding F1 of fuzz round C), so either
 * is the same here.
 */
function comparable(c: StringCase, o: string): string {
  // Text without one: whether it is read, and what it holds. Which mistake a text with several
  // reports isn't fixed (§17); the byte fuzzers compare codes where it is.
  if (!lone(c.text) && c.kind !== "W") return o.startsWith("err ") ? "err" : o
  const m = /^err \d+ \d+ (\S+)$/.exec(o)
  if (m && m[1] !== "invalid-utf8") return `err ${m[1]}`
  if (c.kind === "W" && lone(c.text)) return o.replace(/ !invalid-tag$/, " !cannot-encode").replace(/ invalid-tag\/invalid-tag\/invalid-tag$/, " cannot-encode/cannot-encode/cannot-encode")
  return o
}

export async function run(argv: readonly string[]): Promise<number> {
  const { values: args } = parseArgs({
    args: [...argv],
    options: {
      count: { type: "string", default: "2000" },
      seed: { type: "string", default: String(Date.now() % 1_000_000) },
      out: { type: "string", default: "fuzz/.out/strings" },
      runners: { type: "string", default: ALL.join(",") },
      batch: { type: "string", default: "2000" },
      strings: { type: "boolean", default: false }, // from main.ts
    },
  })
  const count = Number(args.count)
  const seed = Number(args.seed)
  const out = args.out!
  mkdirSync(out, { recursive: true })
  const runners: LineRunner[] = []
  for (const n of args.runners!.split(",")) runners.push(await runner(n))
  const names = runners.map((r) => r.name)
  const file = join(out, "cases.txt")

  const runAll = (cases: readonly StringCase[]): string[][] => {
    const lines = cases.map((c) => `${c.kind} ${utf16Hex(c.text)}`)
    const byRunner = runners.map((r) => r.run(file, lines))
    return cases.map((_, i) => byRunner.map((rs) => rs[i]!))
  }
  /** Who disagrees, and who breaks the spec's rule: empty if nobody. */
  const pattern = (c: StringCase, rs: readonly string[]): string => {
    const live = rs.map((o, i) => [names[i]!, o] as const).filter(([, o]) => o !== "skip")
    const groups = new Map<string, string[]>()
    for (const [n, o] of live) groups.set(comparable(c, o), [...(groups.get(comparable(c, o)) ?? []), n])
    const problems: string[] = []
    if (groups.size > 1) problems.push(`${c.kind}: ${[...groups.values()].map((ns) => ns.join(",")).join(" vs ")}`)
    const bad = live.filter(([, o]) => !meets(c, o)).map(([n]) => n)
    if (bad.length) problems.push(`${c.kind} spec: ${bad.join(",")}`)
    return problems.join("; ")
  }
  /** Smaller texts with the same pattern: code units removed. */
  const shrink = (c: StringCase, want: string): StringCase => {
    let best = c
    let size = Math.max(1, best.text.length >> 1)
    for (let round = 0; round < 200 && best.text.length > 1; round++) {
      const cands: StringCase[] = []
      for (let at = 0; at < best.text.length; at += size) cands.push({ kind: best.kind, text: best.text.slice(0, at) + best.text.slice(at + size) })
      const rs = runAll(cands)
      const i = rs.findIndex((x, k) => pattern(cands[k]!, x) === want)
      if (i >= 0) best = cands[i]!
      else if (size > 1) size >>= 1
      else break
    }
    return best
  }

  const rng = new Rng(seed)
  const batch = Number(args.batch)
  const MAX_SHRUNK = 10
  const found = new Map<string, { c: StringCase; count: number }>()
  const tally = new Map<string, number>()
  console.log(`seed ${seed}: ${count} texts through the string APIs of ${names.join(", ")}`)
  for (let done = 0; done < count; done += batch) {
    const cases = Array.from({ length: Math.min(batch, count - done) }, () => stringCase(rng))
    const results = runAll(cases)
    results.forEach((rs, i) => {
      const c = cases[i]!
      const k = `${c.kind} ${lone(c.text) ? "lone" : "none"} ${rs[0]!.split(" ")[0]}`
      tally.set(k, (tally.get(k) ?? 0) + 1)
      const p = pattern(c, rs)
      if (p === "") return
      const f = found.get(p)
      if (f) return void f.count++
      if (found.size >= MAX_SHRUNK) return void found.set(p, { c, count: 1 })
      console.error(`disagreement: ${p}; shrinking`)
      found.set(p, { c: shrink(c, p), count: 1 })
    })
  }
  console.log(`cases (kind, lone surrogate or not, ${names[0]}'s verdict): ${[...tally].sort().map(([k, n]) => `${k}: ${n}`).join(", ")}`)
  mkdirSync(join(out, "failures"), { recursive: true })
  const reports = [...found].map(([p, f], n) => {
    const rs = runAll([f.c])[0]!
    writeFileSync(join(out, "failures", `${n}.txt`), `${f.c.kind} ${utf16Hex(f.c.text)}\n`)
    return `DISAGREEMENT ${p} (${f.count} cases; saved to ${join(out, "failures", `${n}.txt`)}):\n  ${f.c.kind} ${JSON.stringify(f.c.text)}\n${rs.map((o, i) => `  ${names[i]!.padEnd(10)} ${o.slice(0, 300)}`).join("\n")}`
  })
  writeFileSync(join(out, "failures.txt"), reports.join("\n\n") + "\n")
  if (reports.length === 0) console.log("no disagreements")
  for (const r of reports) console.log(`\n${r}`)
  return reports.length ? 1 : 0
}
