/**
 * Schema files for the schema-file fuzzer (schema-check.ts): files written
 * with varied formatting, and near misses with one mistake of §14 each (a
 * name, an arity, a spread, an attribute, an import, recursion, a lexical
 * error, nesting at the limit), some edited at random as text.
 */
import { Rng } from "./generate.ts"

const BUILTINS = ["String", "Bytes", "Bool", "Decimal", "Int", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Float32", "Float64", "Any"]
const GENERIC: readonly (readonly [string, number])[] = [["Array", 1], ["Map", 1], ["Maybe", 1], ["Result", 2], ["Secret", 1]]
const TIME = ["Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone"]
/** The names a file defines; the mistakes below use other names (Q, R, S, …). */
const NAMES = ["A", "B", "C", "Node", "Tree", "Expr", "Event", "Order", "Line", "Shape", "Pair", "List", "Box", "Swap", "Wrap", "Meta", "Root", "Item", "T1", "T_2"]
const PARAMS = ["a", "b", "c", "elem", "t0"]
const TAGS = ["None2", "Some2", "Circle", "Square", "Point", "Empty", "Nil", "Cons", "X", "Y", "Z", "Ok2", "Leaf", "Br"]
const KEYS = ["id", "name", "x", "y", "_tag", "items", "next", "value", "a_b", "kids"]
const QUOTED = ['"x-y"', '"é"', '"\\u{41}b"', '""', '"a\\"b"', '"\\n"', '"type"', '"😀"', '"id"']

/** A definition, decided on before it is written. */
interface Def {
  readonly name: string
  readonly params: readonly string[]
  readonly kind: "record" | "variant" | "alias" | "stream"
}

const COMMENTS = ["// c\n", "/* c */", "/* a /* b */ c */", "// é 😀\n", "/*\n*/", "// x\r\n"]

/** Whitespace that may be empty; sometimes a line break or a comment. */
function ws0(r: Rng): string {
  const x = r.next()
  if (x < 0.55) return ""
  if (x < 0.8) return " "
  if (x < 0.9) return r.pick(["\n", "\n  ", "\t", "\r\n", "  "])
  return r.pick([" ", "\n"]) + r.pick(COMMENTS) + r.pick([" ", "\n"])
}

/** Whitespace that separates two words. */
const ws1 = (r: Rng) => (r.chance(0.85) ? " " : r.pick(["\n  ", "\t", " /* c */ ", "\n// c\n", "  "]))

/** What a type can refer to while one definition is written. */
interface Scope {
  readonly defs: readonly Def[]
  readonly params: readonly string[]
  readonly time: readonly string[]
}

class Writer {
  private readonly r: Rng
  constructor(r: Rng) {
    this.r = r
  }

  /** A type: an application or an atom. */
  type(s: Scope, depth: number): string {
    const r = this.r
    if (depth > 4) return r.pick(BUILTINS)
    if (r.chance(0.25)) return this.atom(s, depth)
    const named = s.defs.filter((d) => d.kind !== "stream")
    const x = r.next()
    if (x < 0.35 && named.length > 0) {
      const d = r.pick(named)
      return this.apply(d.name, d.params.length, s, depth)
    }
    if (x < 0.75) {
      const [g, n] = r.pick(GENERIC)
      return this.apply(g, n, s, depth)
    }
    return this.atom(s, depth)
  }

  apply(name: string, arity: number, s: Scope, depth: number): string {
    return name + Array.from({ length: arity }, () => ws1(this.r) + this.argument(s, depth + 1)).join("")
  }

  /** An argument of an application: an atom, a parameter more often in generic types. */
  argument(s: Scope, depth: number): string {
    const r = this.r
    if (s.params.length > 0 && r.chance(0.4)) return r.pick(s.params)
    if (r.chance(0.3)) return `(${ws0(r)}${this.type(s, depth)}${ws0(r)})`
    return this.atom(s, depth)
  }

  atom(s: Scope, depth: number): string {
    const r = this.r
    const x = r.next()
    if (x < 0.15 && s.params.length > 0) return r.pick(s.params)
    if (x < 0.35) return r.pick(BUILTINS)
    if (x < 0.4 && s.time.length > 0) return r.pick(s.time)
    if (x < 0.55) {
      const plain = s.defs.filter((d) => d.params.length === 0 && d.kind !== "stream")
      if (plain.length > 0) return r.pick(plain).name
    }
    if (x < 0.65) {
      const generic = s.defs.filter((d) => d.params.length > 0)
      if (generic.length > 0) {
        const d = r.pick(generic)
        return `(${this.apply(d.name, d.params.length, s, depth)})`
      }
    }
    if (depth > 3) return r.pick(BUILTINS)
    if (x < 0.8) return this.record(s, depth + 1)
    if (x < 0.95) return this.variant(s, depth + 1)
    return `(${ws0(r)}${this.type(s, depth + 1)}${ws0(r)})`
  }

  /** Sometimes attributes: defined ones with the arguments they take, and ones this version doesn't define. */
  attributes(): string {
    const r = this.r
    if (!r.chance(0.15)) return ""
    return r.pick(["@deprecated", '@deprecated("use x")', '@deprecated("a",)', '@since("1.2")', "@x(1, [2], { a: 3 })", "@internal", "@internal @deprecated"]) + ws1(r)
  }

  key(): string {
    return this.r.chance(0.15) ? this.r.pick(QUOTED) : this.r.pick(KEYS)
  }

  record(s: Scope, depth: number): string {
    const r = this.r
    const spreadable = this.spreadable(s, "record")
    const keys = new Set<string>()
    const members: string[] = []
    for (let n = r.int(4); n > 0; n--) {
      if (r.chance(0.12) && spreadable.length > 0) {
        members.push(`...${r.pick(spreadable)}`)
        continue
      }
      const key = this.key()
      // Keys that could be the same field (a quoted "id" and id) are left out.
      const bare = key.replaceAll('"', "")
      if (keys.has(bare)) continue
      keys.add(bare)
      members.push(`${this.attributes()}${key}${r.chance(0.3) ? "?" : ""}${ws0(r)}:${ws0(r)}${this.type(s, depth)}`)
    }
    return this.braces(r.chance(0.2), "{", "}", members, ",")
  }

  variant(s: Scope, depth: number): string {
    const r = this.r
    const spreadable = this.spreadable(s, "variant")
    const tags = new Set<string>()
    const alts: string[] = []
    for (let n = r.int(4) + (r.chance(0.9) ? 1 : 0); n > 0; n--) {
      if (r.chance(0.12) && spreadable.length > 0) {
        alts.push(`...${r.pick(spreadable)}`)
        continue
      }
      const tag = r.pick(TAGS)
      if (tags.has(tag)) continue
      tags.add(tag)
      const x = r.next()
      const payload =
        x < 0.4 ? ""
        : x < 0.7 ? ws1(r) + this.record(s, depth)
        : Array.from({ length: 1 + r.int(2) }, () => ws1(r) + this.argument(s, depth + 1)).join("")
      alts.push(`${this.attributes()}${tag}${payload}`)
    }
    return this.braces(alts.length > 0 && r.chance(0.25), "<", ">", alts, " |", r.chance(0.2) ? "| " : "")
  }

  braces(closed: boolean, open: string, close: string, items: readonly string[], sep: string, lead = ""): string {
    const r = this.r
    const body = items.join(`${sep}${r.chance(0.5) ? " " : ws0(r)}`)
    const trailing = items.length > 0 && sep === "," && r.chance(0.2) ? "," : ""
    return `${closed ? "closed" + ws1(r) : ""}${open}${ws0(r)}${items.length > 0 ? lead : ""}${body}${trailing}${ws0(r)}${close}`
  }

  /** Named records or variants without parameters: what a spread can copy. */
  spreadable(s: Scope, kind: Def["kind"]): string[] {
    return s.defs.filter((d) => d.kind === kind && d.params.length === 0).map((d) => d.name)
  }

  definition(d: Def, s: Scope): string {
    const r = this.r
    const scope = { ...s, params: d.params }
    const body =
      d.kind === "record" ? this.record(scope, 0)
      : d.kind === "variant" ? this.variant(scope, 0)
      : d.kind === "stream" ? `Stream${ws1(r)}${this.argument({ ...scope, defs: s.defs.filter((x) => x.kind !== "stream") }, 1)}`
      : this.type(scope, 0)
    const doc = r.chance(0.15) ? "// The type.\n" : ""
    return `${doc}${this.attributes()}type${ws1(r)}${d.name}${d.params.map((p) => ws1(r) + p).join("")}${ws0(r)}=${ws0(r)}${body}`
  }
}

/** A file's parts: what it imports and defines (recursion in it may still be unguarded or growing). */
interface Parts {
  readonly defs: Def[]
  readonly imports: string[]
  readonly texts: string[]
}

function parts(r: Rng): Parts {
  const time = r.chance(0.3) ? TIME.filter(() => r.chance(0.4)).slice(0, 4) : []
  const imports = time.length > 0 ? [`import${ws1(r)}std/time${ws1(r)}(${ws0(r)}${time.join(`,${ws0(r)}`)}${r.chance(0.2) ? "," : ""}${ws0(r)})`] : []
  const names = [...NAMES].sort(() => r.next() - 0.5).slice(0, 1 + r.int(6))
  const defs: Def[] = names.map((name) => {
    const params = r.chance(0.3) ? PARAMS.slice(0, 1 + r.int(2)) : []
    const x = r.next()
    const kind = x < 0.4 ? "record" : x < 0.8 ? "variant" : x < 0.96 || params.length > 0 ? "alias" : "stream"
    return { name, params, kind }
  })
  const w = new Writer(r)
  const texts = defs.map((d) => w.definition(d, { defs, params: [], time }))
  // Sometimes every generic type is used too, so that instances of it are checked; unused ones are checked all the same (§14).
  const generic = defs.filter((d) => d.params.length > 0)
  if (generic.length > 0 && r.chance(0.5)) texts.push(`type Uses = { ${generic.map((d, i) => `u${i}: ${d.name}${" Int".repeat(d.params.length)}`).join(", ")} }`)
  return { defs, imports, texts }
}

/** One mistake of §14 each, as a change to the file's parts. */
const MISTAKES: readonly ((r: Rng, f: Parts) => void)[] = [
  // names
  (r, f) => f.texts.push(`type ${r.pick(f.defs).name} = Int`), // duplicate-type
  (r, f) => f.texts.push(`type ${r.pick([...BUILTINS, "Maybe", "Result", "Stream", "Array", "Secret"])} = Int`), // redefine-prelude
  (r, f) => f.texts.push(`type Q = { x: ${r.pick(["Strng", "Foo", "Q2", "Date", "Instant"])} }`), // unknown-type (std/time types unless imported)
  (r, f) => f.texts.push(`type Q = ${r.pick(["Array", "Map Int Int", "Result Int", "Secret", "Any Int", "Int String", "Maybe", "Array Int Int", "{ x: Maybe }", "Stream", "Stream Int Int", "{ x: Stream }", "Array Stream"])}`), // wrong-arity (Stream's arity before its place)
  (r, f) => {
    const g = f.defs.find((d) => d.params.length > 0)
    f.texts.push(g ? `type Q = { x: ${g.name}${r.chance(0.5) ? "" : " Int".repeat(g.params.length + 1)} }` : "type Q = { x: b }")
  },
  (r, f) => f.texts.push(r.pick(["type P a a = { x: a }", "type P _a = { x: _a }", "type P a = { x: _ }", "type P closed = Int", "type P type = Int", "type P A = Int", "type P a = { x: b }", "type Q = _"])),
  // fields, tags, spreads
  (r, f) => f.texts.push(r.pick(["type Q = { x: Int, x: String }", 'type Q = { x: Int, "x": String }', 'type Q = { "\\u{78}": Int, x: String }', "type Q = < X | X Int >", "type Q = closed < >", "type Q = closed <>", "type Q = < >", "type Q = closed { }", "type Q = < X | >", "type Q = < | X | >", "type Q = closed < X | Y | >", "type Q = < | >"])),
  (r, f) => {
    const rec = f.defs.find((d) => d.kind === "record" && d.params.length === 0)?.name
    const vrt = f.defs.find((d) => d.kind === "variant" && d.params.length === 0)?.name
    const stream = f.defs.find((d) => d.kind === "stream")?.name
    f.texts.push(r.pick([
      `type Q = { ...${rec ?? "Int"} }`,
      `type Q = < ...${rec ?? "String"} >`,
      `type Q = { ...${vrt ?? "Int"} }`,
      `type Q = { ...${stream ?? "Q"} }`,
      "type Q = { ...r }",
      "type Q = < ...a >",
      "type Q = { ...Q }",
      "type Q = < ...R >\ntype R = < ...Q >",
      "type Q = { x: { ...R } }\ntype R = { y: { ...Q } }",
      "type Q = { x: Array { ...R } }\ntype R = { y: < Y { ...S } > }\ntype S = Q",
      "type Q = < X { ...R } >\ntype R = { y: Maybe { ...Q } }",
      "type G a = { x: a }\ntype Q = { ...G }",
      "type G a = { x: a }\ntype Q = { ...G Int }",
      "type R = { x: Int }\ntype Q = { ...R, ...R }",
      "type R = < X >\ntype Q = closed < X | ...R >",
    ]))
  },
  // attributes
  (r, f) => f.texts.push(r.pick([
    "@deprecated(1) type Q = Int", '@deprecated("a", "b") type Q = Int', "@deprecated @deprecated type Q = Int", '@deprecated ("x") type Q = Int',
    "@ deprecated type Q = Int", "type Q = { @deprecated(true) x: Int }", "type Q = < @deprecated @deprecated X >", "type R = { a: Int }\ntype Q = { @deprecated ...R }",
    "type Q = { @x(1) @x(2) a: Int }", "@deprecated(x) type Q = Int", '@deprecated("x" type Q = Int', "@Deprecated type Q = Int",
  ])),
  // streams
  (r, f) => f.texts.push(r.pick(["type Q = { e: Stream Int }", "type S = Stream Int\ntype Q = { e: S }", "type S = Stream Int\ntype Q = S", "type Q = Array (Stream Int)", "type Q a = Stream a", "type S = Stream (Stream Int)"])),
  // recursion: unguarded, growing (§9.9, §9.10), and fine
  (r, f) => f.texts.push(r.pick([
    "type Q = R\ntype R = Q", "type Q = Secret Q", "type I a = a\ntype Q = I Q", "type Q = Maybe Q", "type Q = Array Q", "type Q = Map Q", "type Q = Result Q Q",
    "type L a = < Nil | Cons a (L (L a)) >\ntype Q = L Int", "type P a b = { l: a, r: b }\ntype T a = < X (T (P a a)) | E >", "type L a = < X (L (Array a)) | E >",
    "type S a b = < X a (S b (Array a)) | E >", "type A1 a = < X (B1 a) | E >\ntype B1 b = < Y (C1 (Array b)) >\ntype C1 c = < Z (A1 c) >",
    "type Sw a b = < S a (Sw b a) | E >\ntype Q = Sw Int String", "type Q a = { x: Q (Maybe a) }", "type Q a = { x: Maybe (Q a) }",
    "type Q a = < N | C (Q a) >\ntype R = Q (Q Int)", "type Q = { x: Secret (Maybe Q) }", "type Q a = Q a\ntype U = { u: Q Int }", "type Q a = Secret (Q a)\ntype U = { u: Q Int }", "type Q a = Q a", "type Q a = Secret (Q a)",
    "type Q a b = R b a\ntype R a b = Q a b", "type I a = a\ntype Q a = I (Q a)",
    "type Q a = { kids: Array (Q (Q a)) }", "type Nd a = { value: a, meta: Mt }\ntype Mt = { history: Nd String }", "type Q a = { x: R a }\ntype R b = { y: Q (Array b) }",
  ])),
  // imports
  (r, f) => f.imports.push(r.pick([
    "import std/time (Date, Date)", "import std/money (Money)", "import std/time (Day)", "import ./common (A9)", "import ../x/y (A9)",
    "import @haus-fmt/money@1 (Money)", "import @haus-fmt/money@1.1 (Money)", "import @haus-fmt/money@01 (Money)", "import @haus-fmt/money@ (Money)",
    "import @haus-fmt/money (Money)", "import std/time ()", "import std/time", "import std/time (date)",
    "import @Haus/money@1 (Money)", "import @haus-fmt/node_modules (Money)", "import @haus-fmt (Money)", "import .x (A9)", "import @a/b/c (A9)",
    "import std/ time (Date)", "import std /time (Date)", "import std/time/x (Date)", "import std (Date)", "import foo/bar (A9)", "import @a/b@1~x (A9)",
    "import std/time (Date)\nimport std/time (Date)", "import std/time(Date)", "import std/time (Date) import std/time (Time)",
  ])),
  // lexical errors, as in data, and syntax
  (r, f) => {
    const t = r.pick([
      'type Q = { "a\\q": Int }', 'type Q = { "a: Int }', "/* open\ntype Q = Int", "// a\u0007b\ntype Q = Int", "/* ‮ */ type Q = Int",
      'type Q = { "‮": Int }', "type Q = Int\r", 'type Q = { "a\u0001": Int }', "type Q = Int // \u0085\n", 'type Q = { "\\u{D800}": Int }',
      'type Q = { """\n""": Int }', "type Q = Int /", "type Q = { x: Int } }", "type Q = { x: Int", "type Q =", "type = Int", "type q = Int",
      "type Q = < x >", "type Q = < X y >", "type Q = { X: Int }", "type Q = 1", "type Q = Int,", "type Q = { x: Int y: Int }", "type Q = < X, Y >",
    ])
    f.texts.splice(r.int(f.texts.length + 1), 0, t)
  },
  // nesting at the limit (128)
  (r, f) => {
    const n = r.pick([126, 127, 128, 129, 200])
    f.texts.push(r.pick([`type Q = ${"{ a: ".repeat(n)}Int${" }".repeat(n)}`, `type Q = ${"(".repeat(n)}Int${")".repeat(n)}`, `type Q = ${"Array (".repeat(n)}Int${")".repeat(n)}`, `type Q = ${"< X ".repeat(n)}${" >".repeat(n)}`]))
  },
]

/** Random edits of the text, as for data (generate.ts). */
const SNIPPETS = ["{", "}", "<", ">", "(", ")", "|", ",", ":", "?", "...", "@", "=", "type ", "closed ", '"', "\\", "/*", "//", "\n", "\r", "\u0000", "﻿", "‮", "Int", "a", "_", " "]

function mutateText(r: Rng, text: string): string {
  let cs = [...text]
  for (let n = 1 + r.int(3); n > 0; n--) {
    const at = r.int(cs.length + 1)
    switch (r.int(4)) {
      case 0: cs = [...cs.slice(0, at), ...cs.slice(at + 1 + r.int(3))]; break
      case 1:
      case 2: cs = [...cs.slice(0, at), ...r.pick(SNIPPETS), ...cs.slice(at)]; break
      default: {
        const end = Math.min(cs.length, at + 1 + r.int(8))
        cs = [...cs.slice(0, end), ...cs.slice(at, end), ...cs.slice(end)]
      }
    }
  }
  return cs.join("")
}

const enc = new TextEncoder()

/**
 * A generated schema file. `base` is the file before its one mistake, when
 * it has exactly one (no text edits): if Lean accepts the base, the file has
 * that one mistake, and the error codes must agree.
 */
export interface SchemaFileCase {
  readonly bytes: Uint8Array
  readonly base?: Uint8Array | undefined
}

function write(r: Rng, f: Parts): string {
  const sep = () => r.pick(["\n", "\n\n", "\r\n", "\n// between\n", " ", "\n/* x */\n"])
  const text = [...f.imports, ...f.texts].map((t, i) => (i > 0 ? sep() : "") + t).join("") + r.pick(["", "\n", "\n\n", " // end", "\n// end\n"])
  return r.chance(0.03) ? "﻿" + text : text
}

/** A schema file: half with one mistake, a sixth edited as text, a few with invalid UTF-8. */
export function schemaFile(r: Rng): SchemaFileCase {
  const f = parts(r)
  if (r.chance(0.5)) {
    const base = { defs: f.defs, imports: [...f.imports], texts: [...f.texts] }
    r.pick(MISTAKES)(r, f)
    // The same random choices for the base, so it is the file without the mistake.
    const state = r.next()
    const baseText = write(withSeed(state), base)
    const text = write(withSeed(state), f)
    return { bytes: enc.encode(text), base: enc.encode(baseText) }
  }
  let text = write(r, f)
  if (r.chance(0.3)) text = mutateText(r, text)
  const bytes = enc.encode(text)
  if (r.chance(0.02)) {
    const at = r.int(bytes.length + 1)
    return { bytes: Uint8Array.from([...bytes.subarray(0, at), r.pick([0xff, 0xc0, 0xed, 0x80]), ...bytes.subarray(at)]) }
  }
  return { bytes }
}

/** A generator for the layout of both files of a case, from a number in [0, 1). */
const withSeed = (x: number) => new Rng(Math.floor(x * 4294967296))
