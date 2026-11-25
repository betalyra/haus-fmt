/**
 * Differential testing of values built in code (spec §11 "Values built in
 * code", §12; Zig finding Z1): generated value trees are given to each
 * binding as build instructions, built with its constructors, and then
 * written: the canonical form, the hash and the compact writer. A value
 * that isn't a haus value (a number whose text isn't a literal, a bad tag, a
 * key twice, a string with an unpaired surrogate) must fail there with the
 * code of its mistake, whether the constructor or the writer finds it; one
 * that is must not, except on a writer's limit (§7). See ../README.md,
 * "Values built in code".
 *
 *   node fuzz/src/main.ts --build [--count N] [--seed S] [--runners lean,typescript,rust,…]
 *
 * The instructions, one case a line, in prefix order, separated by spaces:
 * `n:HEX` a number from the text of a literal, `s:HEX` a string, `b:HEX` a
 * byte string, `a:N` an array of the N values that follow, `r:N` a record of
 * N fields, each `k:HEX` and a value, `v:HEX:N` a variant, its tag and N
 * arguments. Text is hex of generalized UTF-8 (a lone surrogate as the three
 * bytes UTF-8 would give it). A runner prints `err CODE` when a constructor
 * rejects the value, else `ok C H W`: the canonical form (hex of its UTF-8),
 * the hash and the compact writer's text (hex), each `!CODE` if it fails;
 * `na` if its strings can't hold the text (a lone surrogate in Rust).
 *
 * Lean has no constructors: where every runner builds the value, its
 * canonical form must be what Lean gives for the value written as text, and
 * Lean must read the writer's text as that value too; a number literal every
 * runner rejects (`invalid-number`) must not parse in Lean, when it is
 * written as one token.
 */
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"
import { arr, bytes as hbytes, canonical, hash, num, rec, str, stringify, variant, type Value } from "../../typescript/packages/haus/dist/index.js"
import { number as validNumber, Rng, TAGS } from "./generate.ts"
import { external, fromWtf8Hex, type LineRunner, wtf8Hex } from "./lines.ts"
import { runProgram, timeoutFor } from "./spawn.ts"

const root = new URL("../..", import.meta.url).pathname

// ── the trees ────────────────────────────────────────────────

export type Tree =
  | { readonly k: "n"; readonly text: string }
  | { readonly k: "s"; readonly s: string }
  | { readonly k: "b"; readonly hex: string }
  | { readonly k: "a"; readonly items: readonly Tree[] }
  | { readonly k: "r"; readonly fields: readonly (readonly [string, Tree])[] }
  | { readonly k: "v"; readonly tag: string; readonly args: readonly Tree[] }

/** The instructions of a tree: one line. */
export function line(t: Tree): string {
  const out: string[] = []
  const go = (t: Tree): void => {
    switch (t.k) {
      case "n": return void out.push(`n:${wtf8Hex(t.text)}`)
      case "s": return void out.push(`s:${wtf8Hex(t.s)}`)
      case "b": return void out.push(`b:${t.hex}`)
      case "a": out.push(`a:${t.items.length}`); return t.items.forEach(go)
      case "r": out.push(`r:${t.fields.length}`); return t.fields.forEach(([k, v]) => (out.push(`k:${wtf8Hex(k)}`), go(v)))
      case "v": out.push(`v:${wtf8Hex(t.tag)}:${t.args.length}`); return t.args.forEach(go)
    }
  }
  go(t)
  return out.join(" ")
}

const isLoneSurrogate = (s: string) => /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(s)
const TAG_RE = /^[A-Z][A-Za-z0-9_]*$/

/** The normalized literal, as TypeScript's constructor gives it (no limits), or undefined if it rejects the text. */
const normalized = (text: string): string | undefined => {
  try {
    return num(text).text
  } catch {
    return undefined
  }
}

/**
 * What the generator knows about a tree: the codes of its mistakes (spec
 * §11; a tag with an unpaired surrogate is `invalid-tag`), places that may or
 * may not be one (a depth at the limit), and the writer's limits (§7) it
 * breaks.
 */
export interface Facts {
  readonly mistakes: string[]
  unsure: number
  readonly limits: string[]
}

/** The facts of a tree, found again from the tree (the shrinker changes trees). */
export function facts(t: Tree): Facts {
  const f: Facts = { mistakes: [], unsure: 0, limits: [] }
  const go = (t: Tree): void => {
    switch (t.k) {
      case "n": {
        const n = normalized(t.text)
        if (n === undefined) return void f.mistakes.push("invalid-number")
        // The number and exponent limits, on the normalized literal (§11).
        if (n.length > 1000) f.limits.push("number-too-long")
        const e = /e(-?\d+)$/.exec(n)
        if (e && Math.abs(Number(e[1])) > 6144) f.limits.push("exponent-too-large")
        return
      }
      case "s": if (isLoneSurrogate(t.s)) f.mistakes.push("cannot-encode"); return
      case "b": return
      case "a": return t.items.forEach(go)
      case "r": {
        const seen = new Set<string>()
        for (const [k, v] of t.fields) {
          if (isLoneSurrogate(k)) f.mistakes.push("cannot-encode")
          else if (seen.has(k)) f.mistakes.push("duplicate-key")
          seen.add(k)
          go(v)
        }
        return
      }
      case "v": {
        // A tag with an unpaired surrogate is no tag: invalid-tag, checked before it is encoded (§11).
        if (!TAG_RE.test(t.tag)) f.mistakes.push("invalid-tag")
        return t.args.forEach(go)
      }
    }
  }
  go(t)
  const d = maxDepth(t)
  if (d > 256) f.limits.push("nesting-too-deep")
  // Depth at the limit: whether a binding counts the levels right is compared, but no code asserted.
  if (d >= 255 && d <= 258) f.unsure++
  return f
}

/** The nesting depth (spec §7): arrays, records and payloads are a level each, a record payload (`Tag { … }`) one level with its record. */
export function maxDepth(t: Tree): number {
  const memo = new Map<Tree, number>()
  // Children first, without recursion: trees may be thousands deep.
  const order: Tree[] = []
  const stack: Tree[] = [t]
  while (stack.length) {
    const x = stack.pop()!
    order.push(x)
    if (x.k === "a") stack.push(...x.items)
    else if (x.k === "r") stack.push(...x.fields.map(([, y]) => y))
    else if (x.k === "v") stack.push(...x.args)
  }
  for (let i = order.length - 1; i >= 0; i--) {
    const x = order[i]!
    const max = (ys: readonly Tree[]) => ys.reduce((m, y) => Math.max(m, memo.get(y)!), 0)
    memo.set(
      x,
      x.k === "a" ? 1 + max(x.items)
      : x.k === "r" ? 1 + max(x.fields.map(([, y]) => y))
      : x.k === "v" ? (x.args.length === 0 ? 0 : x.args.length === 1 && x.args[0]!.k === "r" ? memo.get(x.args[0]!)! : 1 + max(x.args))
      : 0,
    )
  }
  return memo.get(t)!
}

// ── generating ───────────────────────────────────────────────

const STRING_PARTS = ["a", "hello", " ", "é", "é", "😀", "中文", "\n", "\t", '"', "\\", "\u0000", "\u001b", "\u007f", "\u0085", "‮", "\r", "/*", " ", "﻿", "￿", "\u{10ffff}", "'", " "]
const KEYS = ["a", "b", "id", "_x", "", "__proto__", "constructor", "toString", "x-y", "é", "é", "😀", "a b", "\u0000", "Upper", "1", "k "]
const LONE = ["\ud800", "\udbff", "\udc00", "\udfff"]
/** Text that isn't a number literal. */
const NOT_NUMBERS = ["01", "-01", "00", "NaN", "Infinity", "-Infinity", "", " 1", "1 ", "1.", ".5", "+1", "1e", "1e+", "0x", "0xG", "0b2", "1__0", "_1", "1_", "--1", "-", "1,0", "0.0.0", "1e1.5", "1E", "0x_1", "1._5", "1_.5", "١", "１", "1\n", "0X0", "0B1", "1e_5", "true", "0x1p3", "1/2", "0o7", "1.0e", "-0x", "٣"]
/** Valid literals in the spellings people use. */
const SPELLINGS = ["0", "-0", "-0.0", "0.000", "1e5", "1E+05", "1e-0", "-0e0", "0xFF", "0Xff", "0x0", "-0x0", "0b1010", "0b0", "1_000", "1_000.000_1e+0_5", "19.90", "100", "1e2", "0.1", "123456789012345678901234567890", "-1e-6144", "1e6144", "1e6145", "1e-6145", "0e9999", "1" + "0".repeat(999), "1" + "0".repeat(1000), "0x" + "f".repeat(829), "0x" + "f".repeat(830), "0." + "0".repeat(998) + "1", "1E+18446744073709551616", "1e-9223372036854775809", "1_0e0_099999999999999999999"]

function genString(r: Rng): string {
  return r.times(5, () => r.pick(STRING_PARTS)).join("")
}

function genTag(r: Rng): string {
  return r.chance(0.2) ? r.pick(["A_1", "Z9", "X" + "y".repeat(r.int(40)), "Q", "A__"]) : r.pick(TAGS)
}

function genLeaf(r: Rng): Tree {
  switch (r.int(5)) {
    case 0: case 1: return { k: "n", text: r.chance(0.3) ? r.pick(SPELLINGS) : validNumber(r) }
    case 2: case 3: return { k: "s", s: genString(r) }
    default: return { k: "b", hex: Buffer.from(Array.from({ length: r.int(6) }, () => r.int(256))).toString("hex") }
  }
}

function genTree(r: Rng, depth: number): Tree {
  if (depth <= 0 || r.chance(0.35)) return genLeaf(r)
  switch (r.int(3)) {
    case 0: return { k: "a", items: Array.from({ length: r.int(4) }, () => genTree(r, depth - 1)) }
    case 1: {
      const fields: [string, Tree][] = []
      for (const k of Array.from({ length: r.int(4) }, () => r.pick(KEYS))) if (!fields.some(([x]) => x === k)) fields.push([k, genTree(r, depth - 1)])
      return { k: "r", fields }
    }
    default: {
      const tag = genTag(r)
      const x = r.int(3)
      if (x === 0) return { k: "v", tag, args: [] }
      if (x === 1) return { k: "v", tag, args: [{ k: "r", fields: [["r", genTree(r, depth - 1)]] }] }
      return { k: "v", tag, args: Array.from({ length: 1 + r.int(3) }, () => genTree(r, depth - 1)) }
    }
  }
}

/** A chain of containers `n` deep, around a leaf. */
function deep(r: Rng, n: number): Tree {
  let t: Tree = genLeaf(r)
  for (let i = 0; i < n; i++) {
    const x = r.int(3)
    t = x === 0 ? { k: "a", items: [t] } : x === 1 ? { k: "r", fields: [["d", t]] } : { k: "v", tag: "Some", args: [t] }
  }
  return t
}

/** A lone surrogate somewhere in text (never just before a low surrogate: that would pair them in UTF-16 hosts and not in others). */
function withLone(r: Rng, s: string): string {
  const cps = [...s]
  const at = r.int(cps.length + 1)
  let lone = r.pick(LONE)
  // A high surrogate before a low one would make a pair; a low one after a high one too.
  if (lone < "\udc00" && /^[\udc00-\udfff]/.test(cps[at] ?? "")) lone = "\udc00"
  if (lone >= "\udc00" && /[\ud800-\udbff]$/.test(cps[at - 1] ?? "")) lone = "\ud800"
  cps.splice(at, 0, lone)
  return cps.join("")
}

function mutateLiteral(r: Rng, s: string): string {
  const cs = [...s]
  const at = r.int(cs.length + 1)
  switch (r.int(3)) {
    case 0: cs.splice(at, 1); break
    case 1: cs.splice(at, 0, r.pick([..."0_.eE+-xXbB9aZ "])); break
    default: cs.splice(at, 1, r.pick([..."0_.e+-x "]))
  }
  return cs.join("")
}

/** Every node of a tree with a way to replace it. */
function places(t: Tree): { node: Tree; set: (x: Tree) => Tree }[] {
  const out: { node: Tree; set: (x: Tree) => Tree }[] = []
  const go = (node: Tree, set: (x: Tree) => Tree): void => {
    out.push({ node, set })
    if (node.k === "a") node.items.forEach((c, i) => go(c, (x) => set({ ...node, items: node.items.map((y, j) => (j === i ? x : y)) })))
    else if (node.k === "r") node.fields.forEach(([k, c], i) => go(c, (x) => set({ ...node, fields: node.fields.map((f, j) => (j === i ? [k, x] as const : f)) })))
    else if (node.k === "v") node.args.forEach((c, i) => go(c, (x) => set({ ...node, args: node.args.map((y, j) => (j === i ? x : y)) })))
  }
  go(t, (x) => x)
  return out
}

/** One mistake of spec §11 (or a near miss) put into the tree. */
function inject(r: Rng, t: Tree): Tree {
  const ps = places(t)
  const of = (k: Tree["k"]) => ps.filter((p) => p.node.k === k)
  const kind = r.int(7)
  const at = (k: Tree["k"]) => {
    const xs = of(k)
    return xs.length ? r.pick(xs) : undefined
  }
  switch (kind) {
    case 0: case 1: {
      const p = at("n")
      const text = kind === 0 ? r.pick(NOT_NUMBERS) : mutateLiteral(r, p?.node.k === "n" ? p.node.text : validNumber(r))
      return p ? p.set({ k: "n", text }) : { k: "a", items: [t, { k: "n", text }] }
    }
    case 2: {
      const p = at("s")
      const s = withLone(r, p?.node.k === "s" ? p.node.s : genString(r))
      return p ? p.set({ k: "s", s }) : { k: "a", items: [{ k: "s", s }, t] }
    }
    case 3: {
      const p = at("r")
      if (!p || p.node.k !== "r" || p.node.fields.length === 0) return { k: "r", fields: [[withLone(r, r.pick(KEYS)), t]] }
      const fields = [...p.node.fields] as [string, Tree][]
      const i = r.int(fields.length)
      fields[i] = [withLone(r, fields[i]![0]), fields[i]![1]]
      return p.set({ k: "r", fields })
    }
    case 4: {
      const p = at("r")
      if (!p || p.node.k !== "r" || p.node.fields.length === 0) return { k: "r", fields: [["a", t], ["a", genLeaf(r)]] }
      const fields = [...p.node.fields] as [string, Tree][]
      const [k] = r.pick(fields)
      fields.splice(r.int(fields.length + 1), 0, [k, genLeaf(r)])
      return p.set({ k: "r", fields })
    }
    default: {
      const bad = kind === 5 ? r.pick(["lower", "", "_A", "1A", "A-B", "A B", "É", "Ä", "A\u0000", "A😀", "a", "AÉ", "A.B", "A​", "Ａ"]) : withLone(r, r.pick(TAGS))
      const p = at("v")
      if (!p || p.node.k !== "v") return { k: "v", tag: bad, args: [t] }
      return p.set({ ...p.node, tag: bad })
    }
  }
}

export function buildCase(r: Rng): Tree {
  let t = r.chance(0.05) ? deep(r, r.pick([1, 128, 250, 255, 256, 257, 258, 300, 1000])) : genTree(r, 1 + r.int(4))
  const x = r.next()
  // About half valid, a third with one mistake, the rest with several.
  const n = x < 0.5 ? 0 : x < 0.83 ? 1 : 2 + r.int(3)
  for (let i = 0; i < n; i++) t = inject(r, t)
  return t
}

// ── the runners ──────────────────────────────────────────────

/** Builds a tree from its instructions with TypeScript's constructors, and writes it. */
function tsReadLine(l: string): () => Value {
  const tokens = l.split(" ").filter((x) => x !== "")
  let i = 0
  const text = (h: string) => fromWtf8Hex(h)
  const next = (): () => Value => {
    const tok = tokens[i++]!
    const [k, a, b] = tok.split(":") as [string, string, string | undefined]
    switch (k) {
      case "n": return () => num(text(a))
      case "s": return () => str(text(a))
      case "b": return () => hbytes(new Uint8Array(Buffer.from(a, "hex")))
      case "a": {
        const items = Array.from({ length: Number(a) }, next)
        return () => arr(items.map((f) => f()))
      }
      case "r": {
        const fields = Array.from({ length: Number(a) }, () => {
          const key = tokens[i++]!.slice(2)
          return [text(key), next()] as const
        })
        return () => rec(fields.map(([k, f]) => [k, f()] as [string, Value]))
      }
      case "v": {
        const args = Array.from({ length: Number(b) }, next)
        return () => variant(text(a), args.map((f) => f()))
      }
    }
    throw new Error(`bad token ${tok}`)
  }
  return next()
}

const codeOf = (e: unknown): string => {
  const c = (e as { code?: unknown }).code
  if (typeof c === "string") return c
  throw e
}
const hexOf = (s: string) => Buffer.from(s, "utf8").toString("hex")

async function tsOne(l: string): Promise<string> {
  let v: Value
  try {
    v = tsReadLine(l)()
  } catch (e) {
    return `err ${codeOf(e)}`
  }
  const attempt = async (f: () => string | Promise<string>) => {
    try {
      return await f()
    } catch (e) {
      return `!${codeOf(e)}`
    }
  }
  return `ok ${await attempt(() => hexOf(canonical(v)))} ${await attempt(() => hash(v))} ${await attempt(() => hexOf(stringify(v, { style: "compact" })))}`
}

const typescript: LineRunner & { runAsync(lines: readonly string[]): Promise<string[]> } = {
  name: "typescript",
  run: () => {
    throw new Error("use runAsync")
  },
  async runAsync(lines) {
    const out: string[] = []
    for (const l of lines) {
      try {
        out.push(await tsOne(l))
      } catch (e) {
        out.push(`crash ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`.slice(0, 300))
      }
    }
    return out
  },
}

const ALL = ["lean", "typescript", "rust", "python", "go", "jvm"]

function runner(name: string): LineRunner {
  switch (name) {
    case "typescript": return typescript
    case "rust": return external("rust", join(root, "fuzz/schema-rust/target/release/build_runner"), [])
    case "python": return external("python", join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/api_runner.py"), "--build"])
    case "go": return external("go", join(root, "fuzz/.build/go-runner"), ["--build"])
    case "jvm": return external("jvm", join(root, "fuzz/.build/jvm-runner/bin/jvm-runner"), ["--build"])
  }
  throw new Error(`unknown runner ${name} (${ALL.join(", ")}; Zig: TODO, see fuzz/README.md)`)
}

// ── Lean, through the text of the value ──────────────────────

/** The value written as haus text, if Lean's parser can read it as that value (no unpaired surrogate, within its limits). */
export function render(t: Tree): string | undefined {
  const quote = (s: string) => {
    let out = '"'
    for (const ch of s) {
      const c = ch.codePointAt(0)!
      if (c >= 0xd800 && c <= 0xdfff) return undefined
      out += c >= 0x20 && c <= 0x7e && ch !== '"' && ch !== "\\" ? ch : `\\u{${c.toString(16)}}`
    }
    return out + '"'
  }
  if (maxDepth(t) > 250) return undefined
  const go = (t: Tree): string | undefined => {
    switch (t.k) {
      // Within the parser's limits (§7): Lean reads it then, and only then.
      case "n": return t.text.length <= 1000 && !(/^-?0[xX]/.test(t.text) && t.text.replace(/^-?0[xX]/, "").replace(/_/g, "").length > 829) ? t.text : undefined
      case "s": return quote(t.s)
      case "b": return `x"${t.hex}"`
      case "a": {
        const xs = t.items.map(go)
        return xs.includes(undefined) ? undefined : `[${xs.join(", ")}]`
      }
      case "r": {
        const xs = t.fields.map(([k, v]) => {
          const q = quote(k)
          const x = go(v)
          return q === undefined || x === undefined ? undefined : `${q}: ${x}`
        })
        return xs.includes(undefined) ? undefined : `{${xs.join(", ")}}`
      }
      case "v": {
        if (t.args.length === 0) return t.tag
        // A record payload as `Tag { … }`, one level with its record (§7), as the depth here counts it.
        if (t.args.length === 1 && t.args[0]!.k === "r") {
          const x = go(t.args[0]!)
          return x === undefined ? undefined : `${t.tag} ${x}`
        }
        const xs = t.args.map(go)
        return xs.includes(undefined) ? undefined : `${t.tag}(${xs.join(", ")})`
      }
    }
  }
  return go(t)
}

/** Lean's canonical form of each text (`--canonical-batch`): `ok <canonical>` or `err <code>`. */
function lean(dir: string, texts: readonly string[]): string[] {
  if (texts.length === 0) return []
  mkdirSync(dir, { recursive: true })
  texts.forEach((t, i) => writeFileSync(join(dir, `${String(i).padStart(5, "0")}.haus`), t))
  const p = runProgram("lean", join(root, "spec/lean/.lake/build/bin/haus-ref"), ["--canonical-batch", dir, String(texts.length)], timeoutFor(texts.length))
  const out = (p.stdout ?? "").split("\n").filter((l) => l !== "")
  if (p.status !== 0 || out.length !== texts.length) throw new Error(`lean: exit ${p.status}, ${out.length} lines for ${texts.length}: ${(p.stderr ?? "").slice(0, 300)}`)
  return out.map((l) => {
    if (l.startsWith("ok ")) {
      const vs = JSON.parse(l.slice(3)) as string[]
      return vs.length === 1 ? `ok ${hexOf(vs[0]!)}` : `ok ${vs.length} values`
    }
    const m = /^err \d+ \d+ (\S+)/.exec(l)
    return `err ${m ? m[1] : "?"}`
  })
}

// ── comparing ────────────────────────────────────────────────

/** A runner's result as three outcomes (canonical, hash, writer): a constructor's error is each of them. */
function ops(out: string): [string, string, string] | "na" | string {
  if (out === "na") return "na"
  const e = /^err (\S+)$/.exec(out)
  if (e) return [`!${e[1]}`, `!${e[1]}`, `!${e[1]}`]
  const m = /^ok (\S+) (\S+) (\S+)$/.exec(out)
  if (m) return [m[1]!, m[2]!, m[3]!]
  return out.startsWith("crash") ? out : `unexpected: ${out.slice(0, 200)}`
}

const OPS = ["canonical", "hash", "write"] as const

/**
 * Where a case goes wrong, as a pattern that names the runners and what
 * they did, but not the values (so that a shrunk case keeps it): empty if
 * nothing does.
 */
function pattern(names: readonly string[], outs: readonly string[], f: Facts): string {
  const problems: string[] = []
  const parsed = outs.map(ops)
  parsed.forEach((p, i) => {
    if (typeof p === "string" && p !== "na") problems.push(`${names[i]}: ${p.startsWith("crash") ? "crash" : "bad output"}`)
  })
  const triples = parsed.flatMap((p, i) => (Array.isArray(p) ? [[names[i]!, p] as const] : []))
  const issues = f.mistakes.length + f.unsure
  for (let op = 0; op < 3; op++) {
    // Codes are compared where there is at most one mistake (and, for the writer, limit), and nothing
    // unsure (a depth at the limit).
    const compareCodes = f.unsure === 0 && issues + (op === 2 ? f.limits.length : 0) <= 1
    const token = (x: string) => (x.startsWith("!") ? (compareCodes ? x : "!err") : "ok")
    const kinds = new Map<string, string[]>()
    for (const [n, t] of triples) kinds.set(token(t[op]!), [...(kinds.get(token(t[op]!)) ?? []), n])
    if (kinds.size > 1) {
      problems.push(`${OPS[op]}: ${[...kinds].map(([k, ns]) => `${ns.join(",")}=${k}`).join(" vs ")}`)
      continue
    }
    // All succeeded: the same text (or hash).
    const values = new Map<string, string[]>()
    for (const [n, t] of triples) if (!t[op]!.startsWith("!")) values.set(t[op]!, [...(values.get(t[op]!) ?? []), n])
    if (values.size > 1) problems.push(`${OPS[op]} differs: ${[...values.values()].map((ns) => ns.join(",")).join(" vs ")}`)
    // The spec's verdict where the generator knows it.
    const want =
      f.unsure > 0 ? undefined
      : f.mistakes.length === 1 && (op < 2 || f.limits.length === 0) ? `!${f.mistakes[0]}`
      : f.mistakes.length === 0 && op < 2 ? "ok"
      : f.mistakes.length === 0 && f.limits.length === 0 ? "ok"
      : f.mistakes.length === 0 && new Set(f.limits).size === 1 ? `!${f.limits[0]}`
      : undefined
    const got = triples.length ? token(triples[0]![1][op]!) : undefined
    if (want !== undefined && got !== undefined && got !== want && (compareCodes || want === "ok"))
      problems.push(`spec ${OPS[op]}: all=${got}, expected ${want}`)
  }
  return problems.join("; ")
}

export async function run(argv: readonly string[]): Promise<number> {
  const { values: args } = parseArgs({
    args: [...argv],
    options: {
      count: { type: "string", default: "2000" },
      seed: { type: "string", default: String(Date.now() % 1_000_000) },
      out: { type: "string", default: "fuzz/.out/build" },
      runners: { type: "string", default: ALL.join(",") },
      batch: { type: "string", default: "2000" },
      build: { type: "boolean", default: false }, // from main.ts
    },
  })
  const count = Number(args.count)
  const seed = Number(args.seed)
  const out = args.out!
  mkdirSync(out, { recursive: true })
  const wanted = args.runners!.split(",")
  const useLean = wanted.includes("lean")
  const runners = wanted.filter((n) => n !== "lean").map(runner)
  const names = runners.map((r) => r.name)
  const file = join(out, "cases.txt")

  const runAll = async (lines: readonly string[]): Promise<string[][]> => {
    const byRunner: string[][] = []
    for (const r of runners) byRunner.push(r === typescript ? await typescript.runAsync(lines) : r.run(file, lines))
    return lines.map((_, i) => byRunner.map((rs) => rs[i]!))
  }

  /** Lean's checks of a batch: a pattern per case ("" if it agrees). */
  const leanPatterns = (trees: readonly Tree[], results: readonly string[][]): string[] => {
    const pats = trees.map(() => "")
    if (!useLean) return pats
    const texts: string[] = []
    const asks: { i: number; kind: "canonical" | "written" | "reject"; want: string }[] = []
    trees.forEach((t, i) => {
      const f = facts(t)
      const triples = results[i]!.map(ops).filter((p): p is [string, string, string] => Array.isArray(p))
      if (triples.length === 0) return
      const text = render(t)
      const c = triples[0]![0]
      const agreed = triples.every((p) => p[0] === c)
      if (f.mistakes.length === 0 && f.unsure === 0 && f.limits.length === 0 && text !== undefined && agreed && !c.startsWith("!")) {
        texts.push(text)
        asks.push({ i, kind: "canonical", want: c })
        const w = triples[0]![2]
        if (!w.startsWith("!")) {
          texts.push(Buffer.from(w, "hex").toString("utf8"))
          asks.push({ i, kind: "written", want: c })
        }
      }
      // A literal that isn't one, written as one token: Lean's parser must reject it too.
      if (f.mistakes.length === 1 && f.mistakes[0] === "invalid-number" && f.unsure === 0 && text !== undefined && agreed && c === "!invalid-number") {
        const bad = places(t).find((p) => p.node.k === "n" && normalized(p.node.text) === undefined)?.node
        if (bad?.k === "n" && /^-?[0-9][0-9A-Za-z_.+]*$/.test(bad.text)) {
          texts.push(text)
          asks.push({ i, kind: "reject", want: "err" })
        }
      }
    })
    const got = lean(join(out, "lean"), texts)
    asks.forEach((a, k) => {
      const g = got[k]!
      const bad = a.kind === "reject" ? !g.startsWith("err") : g !== `ok ${a.want}`
      if (bad) pats[a.i] = (pats[a.i] ? pats[a.i] + "; " : "") + `lean ${a.kind}: ${g.startsWith("ok ") && a.kind !== "reject" ? "another canonical form" : g}`
    })
    return pats
  }

  const full = async (trees: readonly Tree[]): Promise<{ results: string[][]; pats: string[] }> => {
    const results = await runAll(trees.map(line))
    const lp = leanPatterns(trees, results)
    return { results, pats: trees.map((t, i) => [pattern(names, results[i]!, facts(t)), lp[i]].filter((x) => x).join("; ")) }
  }

  /** Smaller trees: a part removed, a container replaced by a part of it, text made shorter. */
  const smaller = (t: Tree): Tree[] => {
    const out: Tree[] = []
    for (const { node, set } of places(t)) {
      if (node.k === "a") {
        node.items.forEach((_, i) => out.push(set({ k: "a", items: node.items.filter((_, j) => j !== i) })))
        node.items.forEach((c) => out.push(set(c)))
      } else if (node.k === "r") {
        node.fields.forEach((_, i) => out.push(set({ k: "r", fields: node.fields.filter((_, j) => j !== i) })))
        node.fields.forEach(([, c]) => out.push(set(c)))
      } else if (node.k === "v") {
        node.args.forEach((_, i) => out.push(set({ ...node, args: node.args.filter((_, j) => j !== i) })))
        node.args.forEach((c) => out.push(set(c)))
      } else if (node.k === "s" && node.s.length > 0) {
        const cps = [...node.s]
        cps.forEach((_, i) => out.push(set({ k: "s", s: cps.filter((_, j) => j !== i).join("") })))
      } else if (node.k === "n" && node.text.length > 1) {
        out.push(set({ k: "n", text: node.text.slice(0, node.text.length >> 1) }), set({ k: "n", text: node.text.slice(1) }), set({ k: "n", text: node.text.slice(0, -1) }))
      }
    }
    return out
  }
  const size = (t: Tree) => line(t).length
  const shrink = async (t: Tree, want: string): Promise<Tree> => {
    let best = t
    for (let round = 0; round < 60; round++) {
      const cands = smaller(best).filter((c) => size(c) < size(best)).slice(0, 400)
      if (cands.length === 0) break
      const { pats } = await full(cands)
      const i = pats.findIndex((p) => p === want)
      if (i < 0) break
      best = cands[i]!
    }
    return best
  }

  const rng = new Rng(seed)
  const batch = Number(args.batch)
  const MAX_SHRUNK = 10
  const found = new Map<string, { tree: Tree; count: number }>()
  let built = 0
  let rejected = 0
  let na = 0
  console.log(`seed ${seed}: ${count} values built through ${[...(useLean ? ["lean (through text)"] : []), ...names].join(", ")}`)
  for (let done = 0; done < count; done += batch) {
    const trees = Array.from({ length: Math.min(batch, count - done) }, () => buildCase(rng))
    const { results, pats } = await full(trees)
    for (let i = 0; i < trees.length; i++) {
      const rs = results[i]!
      if (rs.some((x) => x === "na")) na++
      if (rs[0]!.startsWith("ok ") && !rs[0]!.includes(" !")) built++
      else rejected++
      const p = pats[i]!
      if (p === "") continue
      const f = found.get(p)
      if (f) {
        f.count++
        continue
      }
      if (found.size >= MAX_SHRUNK) {
        found.set(p, { tree: trees[i]!, count: 1 })
        continue
      }
      console.error(`disagreement: ${p}; shrinking`)
      found.set(p, { tree: await shrink(trees[i]!, p), count: 1 })
    }
  }
  console.log(`${built} written by ${names[0]} without an error, ${rejected} with one; ${na} cases some runner can't build (na)`)
  mkdirSync(join(out, "failures"), { recursive: true })
  const reports: string[] = []
  for (const [p, f] of found) {
    const { results } = await full([f.tree])
    const n = reports.length
    writeFileSync(join(out, "failures", `${n}.txt`), line(f.tree) + "\n")
    reports.push(
      `DISAGREEMENT ${p} (${f.count} cases; saved to ${join(out, "failures", `${n}.txt`)}):\n  tree: ${JSON.stringify(f.tree).slice(0, 600)}\n  text: ${JSON.stringify(render(f.tree) ?? "(not writable as text)").slice(0, 600)}\n` +
        results[0]!.map((o, i) => `  ${names[i]!.padEnd(10)} ${o.slice(0, 300)}`).join("\n"),
    )
  }
  writeFileSync(join(out, "failures.txt"), reports.join("\n\n") + "\n")
  if (reports.length === 0) console.log("no disagreements")
  for (const r of reports) console.log(`\n${r}`)
  return reports.length ? 1 : 0
}
