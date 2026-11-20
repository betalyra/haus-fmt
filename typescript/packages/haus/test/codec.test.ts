/**
 * The compiled codecs (codec.ts) against the generic path (parse to a Value,
 * then decode; encode to a Value, then format): the same values, the same
 * texts and the same errors (code, message, place, details).
 *
 * - Every type of the schema suites (test-suite/schema, fuzz/schema) on the
 *   suite's cases, in every layout, and on mutations of them (syntax errors,
 *   decode errors, both in one text).
 * - Encoding the decoded values, and values changed to be wrong.
 * - Cases the suites don't reach: Recursive schemas, schemas written by hand,
 *   refinements, keys of the prototype chain, payload forms, limits.
 */
import { describe, expect, it } from "@effect/vitest"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { compileSchemaFile, parse, stringify as stringifyValue, type Value } from "../src/index.js"
import { decodeCompiled, encodeCompiled } from "../src/codec.js"
import { generatedOrigin, readerFor, withCodec, writerFor, type CodecChoice } from "../src/codegen.js"
import * as h from "../src/schema.js"
import { schemaCases } from "./schema-conformance.test.js"

// ── comparing outcomes ───────────────────────────────────────

/** The first difference between two values, or undefined: types, prototypes, own keys in order, descriptors, frozenness. */
const difference = (a: unknown, b: unknown, at = "$"): string | undefined => {
  if (typeof a !== typeof b) return `${at}: ${typeof a} vs ${typeof b}`
  if (typeof a !== "object" || a === null || b === null) return Object.is(a, b) ? undefined : `${at}: ${String(a)} vs ${String(b)}`
  const x = a as object
  const y = b as object
  if (Object.getPrototypeOf(x) !== Object.getPrototypeOf(y)) return `${at}: another prototype`
  if (Object.isFrozen(x) !== Object.isFrozen(y) || Object.isExtensible(x) !== Object.isExtensible(y)) return `${at}: frozen or not`
  if (h.Secret.is(x)) return difference(x.expose(), (y as h.Secret<unknown>).expose(), `${at}.expose()`)
  if (x instanceof Uint8Array) return Buffer.from(x).equals(Buffer.from(y as Uint8Array)) ? undefined : `${at}: other bytes`
  if (x instanceof Map) {
    const xs = [...x]
    const ys = [...(y as Map<unknown, unknown>)]
    if (xs.length !== ys.length) return `${at}: ${xs.length} vs ${ys.length} entries`
    for (let i = 0; i < xs.length; i++) {
      const d = difference(xs[i]![0], ys[i]![0], `${at}.keys[${i}]`) ?? difference(xs[i]![1], ys[i]![1], `${at}.get(${String(xs[i]![0])})`)
      if (d !== undefined) return d
    }
    return undefined
  }
  const kx = Reflect.ownKeys(x)
  const ky = Reflect.ownKeys(y)
  if (kx.join("\u0000") !== ky.join("\u0000")) return `${at}: keys ${kx.map(String).join(",")} vs ${ky.map(String).join(",")}`
  for (const k of kx) {
    const dx = Object.getOwnPropertyDescriptor(x, k)!
    const dy = Object.getOwnPropertyDescriptor(y, k)!
    if (dx.writable !== dy.writable || dx.enumerable !== dy.enumerable || dx.configurable !== dy.configurable || "get" in dx || "get" in dy) return `${at}.${String(k)}: another descriptor`
    const d = difference(dx.value, dy.value, `${at}.${String(k)}`)
    if (d !== undefined) return d
  }
  return undefined
}

type Outcome = { readonly ok: true; readonly value: unknown } | { readonly ok: false; readonly error: unknown }

const outcome = (f: () => unknown): Outcome => {
  try {
    return { ok: true, value: f() }
  } catch (error) {
    return { ok: false, error }
  }
}

/** An error as far as a caller can see it: its class, message and own properties (code, path, place, details). */
const errorView = (e: unknown) =>
  e instanceof Error ? { class: e.constructor.name, message: e.message, ...Object.fromEntries(Object.entries(e)) } : { thrown: e }

/** The compiled codecs: generated code and closures. */
const COMPILED = ["generated", "closures"] as const

/** Generated code, closures and the generic path give the same outcome. */
const expectSame = (run: (codec: CodecChoice) => unknown): Outcome => {
  const generic = outcome(() => run("generic"))
  for (const codec of COMPILED) {
    const compiled = outcome(() => run(codec))
    if (compiled.ok && generic.ok) expect(difference(compiled.value, generic.value), codec).toBeUndefined()
    else {
      expect(compiled.ok, compiled.ok ? `${codec}: succeeded where the generic path failed` : "").toBe(false)
      expect(generic.ok, generic.ok ? `${codec}: failed: ${String((compiled as { error: unknown }).error)}` : "").toBe(false)
      expect(errorView((compiled as { error: unknown }).error), codec).toEqual(errorView((generic as { error: unknown }).error))
    }
  }
  return generic
}

/**
 * Decoding `text`: the same outcome on every path. And the compiled codecs
 * don't give up on what the generic path accepts (that would be correct, but
 * slow): giving up is for errors only.
 */
const decodeSame = (schema: h.AnySchema, text: string, limits: h.Limits = {}): Outcome => {
  const generic = expectSame((c) => h.parse(schema, text, withCodec(limits, c)))
  for (const codec of COMPILED) {
    const read = readerFor(schema, codec)
    if (generic.ok && read !== undefined) expect(decodeCompiled(read, text, limits), `${codec}: the reader gave up on ${text}`).toBeDefined()
  }
  return generic
}

/** Encoding `value`: the same outcome on every path, and the compiled writers don't give up on what the generic path writes. */
const encodeSame = (schema: h.AnySchema, value: unknown, limits: h.Limits = {}): void => {
  for (const style of ["compact", "minimised"] as const) {
    const generic = expectSame((c) => h.stringify(schema, value, withCodec({ style, ...limits }, c)))
    for (const codec of COMPILED) {
      const write = writerFor(schema, codec)
      if (generic.ok && write !== undefined) expect(encodeCompiled(write, value, limits, style), `${codec}: the writer gave up`).toBeDefined()
    }
    expectSame((c) => h.formatAll(schema, [value, value], withCodec({ style, ...limits }, c)))
  }
}

// ── mutations ────────────────────────────────────────────────

/** A small deterministic generator (mulberry32). */
const random = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

const PIECES = ["{", "}", "[", "]", "(", ")", ",", ":", '"', " ", "\n", "/", "x", "A", "a", "_", "0", "-", ".", "e", "Some", "None", "{}", "‮", "\r"]

/** `n` texts near `text`: a character deleted, a piece inserted, a slice doubled or cut off. */
const mutations = (text: string, n: number, seed: number): string[] => {
  const next = random(seed)
  const at = () => Math.floor(next() * (text.length + 1))
  return Array.from({ length: n }, () => {
    const i = at()
    switch (Math.floor(next() * 4)) {
      case 0: return text.slice(0, i) + text.slice(i + 1)
      case 1: return text.slice(0, i) + PIECES[Math.floor(next() * PIECES.length)]! + text.slice(i)
      case 2: {
        const j = at()
        return text.slice(0, Math.max(i, j)) + text.slice(Math.min(i, j))
      }
      default: return text.slice(0, i)
    }
  })
}

/** Values near `value`: one place inside it replaced by something else. */
const changed = (value: unknown, seed: number): unknown[] => {
  const next = random(seed)
  const others = [undefined, null, "x", 1, 1.5, 1n, -1n, true, [], {}, new Map(), h.Maybe.none, { _tag: "Nope" }, { _tag: "@unknown", value: 1 }]
  const replace = (v: unknown, depth: number): unknown => {
    if (depth > 0 && next() < 0.3) return others[Math.floor(next() * others.length)]
    if (Array.isArray(v)) {
      if (v.length === 0) return v
      const i = Math.floor(next() * v.length)
      return v.map((x, k) => (k === i ? replace(x, depth + 1) : x))
    }
    if (v instanceof Map) {
      const entries = [...v]
      if (entries.length === 0) return v
      const i = Math.floor(next() * entries.length)
      return new Map(entries.map(([k, x], j) => [k, j === i ? replace(x, depth + 1) : x]))
    }
    if (typeof v === "object" && v !== null && Object.getPrototypeOf(v) === Object.prototype) {
      const keys = Object.keys(v)
      if (keys.length === 0) return v
      const k = keys[Math.floor(next() * keys.length)]!
      return { ...v, [k]: replace((v as Record<string, unknown>)[k], depth + 1) }
    }
    return others[Math.floor(next() * others.length)]
  }
  return Array.from({ length: 6 }, () => replace(value, 0))
}

// ── the suites ───────────────────────────────────────────────

const ROOT = join(import.meta.dirname, "../../../..")
const SUITE = join(ROOT, "test-suite/schema")

describe.each(readdirSync(SUITE).filter((f) => f.endsWith(".schema.haus")).map((f) => f.replace(".schema.haus", "")))("%s", (suite) => {
  const { schemas } = compileSchemaFile(readFileSync(join(SUITE, `${suite}.schema.haus`), "utf8"))
  const cases = schemaCases(readFileSync(join(SUITE, `${suite}.cases.haus`), "utf8"))
  it("compiles every type", () => {
    for (const [name, schema] of Object.entries(schemas)) {
      for (const codec of COMPILED) {
        expect(readerFor(schema, codec), `${codec} ${name}`).toBeDefined()
        expect(writerFor(schema, codec), `${codec} ${name}`).toBeDefined()
      }
    }
  })
  it.each(cases)("$name", (c) => {
    const schema = schemas[c.type]!
    const texts = (["pretty", "compact", "minimised"] as const).map((style) => stringifyValue(c.input, { style }))
    texts.forEach((text, k) => {
      const decoded = decodeSame(schema, text)
      for (const m of mutations(text, 25, text.length * 7 + k)) decodeSame(schema, m)
      if (decoded.ok && k === 0) {
        encodeSame(schema, decoded.value)
        changed(decoded.value, text.length).forEach((v) => encodeSame(schema, v))
      }
    })
  })
})

describe("fuzz/schema", () => {
  const { schemas } = compileSchemaFile(readFileSync(join(ROOT, "fuzz/schema/fuzz.schema.haus"), "utf8"))
  const texts: Record<string, readonly string[]> = {
    Nested: ["None", "Some(None)", "Some(Some(5))", "Some(Some(5.5))", "Some {}"],
    Gen: ["One(1)", "Two(1, \"a\")", "Rec { a: 1 }", "Rec { a: 1, b: \"x\" }", "Rec({ a: 1 })", "Rec { b: \"x\", a: 2 }", "One { a: 1 }", "Two(1)"],
    Tree: ["Leaf", "Node(Leaf, Wrap { inner: Some(Leaf) })", "Wrap { inner: None }", "Wrap { inner: Some(Node(Leaf, Leaf)), x: 1 }", "Node(Leaf)"],
    Hidden: ['{ user: "ada", pin: 1234 }', '{ user: "ada", pin: 99999 }', '{ pin: 1, user: "b" }'],
    Floats: ["{ f32: 1.5, f64: NaN }", "{ f32: 1e40, f64: 1 }", "{ f32: Infinity, f64: NegInfinity, all: [1, 2.5, NaN] }"],
    Mixed: [
      '{ list: [None, Some(1.50)], map: { a: x"00ff" }, result: Ok(1) }',
      '{ list: [], map: {}, result: Err(["a"]), at: Instant("2026-11-07T10:00:00Z"), any: { "k": Foo { a: [1] } } }',
      '{ list: [], map: {}, result: Ok(1), extra: 1 }',
      '{ list: [], map: { a: x"00", a: x"01" }, result: Ok(1) }',
    ],
    Names: ["One { value: 1 }", "Many {}", "Many { values: [1, 2] }", "Pos(3)", "Pos { value: 3 }"],
    NameKeys: ['{ _tag: "a" }', '{ _tag: "a", value: Some(1), args: Foo }', '{ value: None, _tag: "b" }'],
  }
  it.each(Object.entries(texts))("%s", (type, list) => {
    const schema = schemas[type]!
    list.forEach((text, k) => {
      const decoded = decodeSame(schema, text)
      for (const m of mutations(text, 40, k)) decodeSame(schema, m)
      if (decoded.ok) {
        encodeSame(schema, decoded.value)
        changed(decoded.value, k).forEach((v) => encodeSame(schema, v))
      }
    })
  })
})

// ── what the suites don't reach ──────────────────────────────

describe("schemas in code", () => {
  interface Node {
    readonly name: string
    readonly children: readonly Node[]
  }
  const Tree: h.Schema<Node> = h.Recursive<Node>("Tree", (self) => h.Record({ name: h.String, children: h.Array(self) }))
  const Shallow = h.Recursive<Node>("Shallow", (self) => h.Record({ name: h.String, children: h.Array(self) }), { maxDepth: 2 })
  const Expr: h.Schema<unknown> = h.Recursive<unknown>("Expr", (self) => h.Variant({ Lit: h.Int, Add: h.Tuple(self, self), Neg: self, Let: h.Record({ name: h.String, body: self }) }) as h.Schema<unknown>)
  /** A record case by a Recursive (a named record in a schema file). */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const Item = h.Recursive<any>("Item", (self) => h.Record({ id: h.Int, next: h.Maybe(h.Variant({ Item: self, End: h.Unit })) }))
  const Wrapped = h.Variant({ Item, Other: h.Unit })
  const Currency = h.refine(h.AnyTag, (c) => (typeof c === "string" && /^[A-Z]{3}$/.test(c) ? undefined : "three letters"))
  /** Written by hand: no shape, decoded by its own decode. */
  const Even: h.Schema<number> = h.withStandard<number, Omit<h.Schema<number>, "~standard">>({
    expected: "an even Int32",
    decode: (v, at) => {
      const n = h.Int32.decode(v, at)
      return n % 2 === 0 ? n : at.fail("odd")
    },
    encode: (n, at) => (n % 2 === 0 ? h.Int32.encode(n, at) : at.fail("odd")),
  })
  /** A copy of a built-in schema with its decoder replaced: not the built-in's shape. */
  const Shouting: h.Schema<string> = { ...h.String, decode: (v, at) => h.String.decode(v, at).toUpperCase() }
  const Protos = h.Record({ __proto__: h.Int32, toString: h.String, constructor: h.Optional(h.Bool), "1": h.Int32, a: h.Int32 } as h.Fields)
  const Closed = h.Record({ a: h.Int32, b: h.Optional(h.String) }, { closed: true })
  const Open = h.OpenVariant({ A: h.Unit, B: h.Tuple(h.Int32), C: h.Record({ _tag: h.Int32 }), D: h.Tuple(), E: h.Tuple(h.Any) })
  const Everything = h.Record({
    s: h.String, i: h.Int, i8: h.Int8, u64: h.UInt64, f: h.Float64, f32: h.Float32, d: h.Decimal, b: h.Bool, by: h.Bytes, date: h.Date,
    at: h.InstantAsDate, time: h.StdTime("Time"), e: h.Enum("X", "Y"), t: h.AnyTag, any: h.Any, secret: h.Secret(h.Maybe(h.Map(h.Bytes))),
    opt: h.Optional(h.Maybe(h.String)), cur: Currency, even: Even, shout: Shouting,
  })

  const decodes: readonly (readonly [string, h.AnySchema, readonly string[]])[] = [
    ["Tree", Tree, ['{ name: "a", children: [{ name: "b", children: [] }] }', '{ children: [], name: "x" }', '{ name: "a", children: [{ name: "b" }] }']],
    ["Shallow", Shallow, ['{ name: "a", children: [{ name: "b", children: [] }] }', '{ name: "a", children: [{ name: "b", children: [{ name: "c", children: [] }] }] }']],
    ["Expr", Expr, ["Add(Lit(1), Neg(Let { name: \"x\", body: Lit(2) }))", "Neg(Neg(Neg(Lit(0))))", "Let({ name: \"y\", body: Lit(1) })", "Add(Lit(1))"]],
    ["Item", Wrapped, ["Item { id: 1, next: Some(Item { id: 2, next: Some(End) }) }", "Item { id: 1, next: None, extra: [1] }", "Other", "Item(1)"]],
    ["Currency", Currency, ["EUR", "Eur", "XAU(1)"]],
    ["Protos", Protos, ['{ __proto__: 1, toString: "s", "1": 2, a: 3 }', '{ a: 3, "1": 2, toString: "s", __proto__: 1, constructor: True }', '{ __proto__: 1 }']],
    ["Closed", Closed, ["{ a: 1 }", '{ b: "x", a: 1 }', "{ a: 1, c: 2 }", "{ a: 1, a: 2 }", '{ a: 1, b: "x", b: "y" }']],
    ["Open", Open, ["A", "B(1)", "C { _tag: 1 }", "D", "E { x: 1 }", "E(Foo)", "Z(1, [2])", "Z { a: 1 }", "Z", "B { x: 1 }", "D()"]],
    ["Everything", Everything, [
      `{ s: "x", i: 123456789012345678901234567890, i8: -128, u64: 18446744073709551615, f: 1e308, f32: 3.4e38, d: 1_000.50, b: True, by: x"0b 34ff",
         date: Date("2026-02-28"), at: Instant("2026-11-07T10:00:00.250+01:00"), time: Time("09:30:00"), e: Y, t: Foo(1), any: [1, { a: x"" }],
         secret: Some({ k: x"01" }), opt: None, cur: EUR, even: 4, shout: "hi" }`,
      `{ s: "x", i: 0x1F, i8: 0b101, u64: 0, f: -0, f32: 0.1, d: -0, b: False, by: x"", date: Date("2026-02-30"), at: Instant("2026-11-07T10:00:00Z"),
         time: Time("25:00:00"), e: X, t: Bar, any: None, secret: None, cur: USD, even: 3, shout: "a" }`,
    ]],
  ]
  it.each(decodes)("%s", (_, schema, texts) => {
    texts.forEach((text, k) => {
      const decoded = decodeSame(schema, text)
      for (const m of mutations(text, 60, k + 1)) decodeSame(schema, m)
      if (decoded.ok) {
        encodeSame(schema, decoded.value)
        changed(decoded.value, k).forEach((v) => encodeSame(schema, v))
      }
    })
  })

  it("takes the compiled path where it can (the same values, from a reader, not from a Value)", () => {
    // A string field that is a raw tab fails the generic parse; reading it compiled can't succeed either.
    expect(h.parse(Tree, '{ name: "a", children: [] }')).toEqual({ name: "a", children: [] })
  })

  it("keeps the generic path's order of errors: a syntax error late in the text wins", () => {
    const text = '{ name: 1, children: [] } }'
    const e = decodeSame(Tree, text)
    expect(e.ok).toBe(false)
    expect(h.errorCode((e as { error: unknown }).error)).toBe("unexpected-closer")
  })

  it("texts of zero, one and two values; byte order mark, trailing comma, version directive", () => {
    for (const text of ["", "  ", '{ name: "a", children: [] },', '{ name: "a", children: [] }, { name: "b", children: [] }', '﻿{ name: "a", children: [] }', "#haus 2\n{}", "// c\n{ /* d */ name: \"a\", children: [] } // e"]) {
      decodeSame(Tree, text)
    }
  })

  it("limits: depth, string, number and step budget", () => {
    const deep = (n: number) => `${"Neg(".repeat(n)}Lit(1)${")".repeat(n)}`
    for (const n of [3, 4, 5, 254, 255, 256, 300]) decodeSame(Expr, deep(n))
    for (const limits of [{ maxDepth: 3 }, { maxDepth: 4 }, { maxDepth: 5 }, { maxSteps: 3 }, { maxSteps: 9 }, { maxSteps: 10 }, { maxDepth: 600 }]) {
      decodeSame(Expr, deep(3), limits)
      encodeSame(Expr, h.parse(Expr, deep(3)), limits)
    }
    decodeSame(Everything, `{ s: "${"x".repeat(20)}" }`, { maxStringLength: 10 })
    decodeSame(h.Int, "1".repeat(30), { maxNumberLength: 20 })
    decodeSame(h.Decimal, "1e100", { maxExponent: 10 })
    encodeSame(h.Int, 10n ** 30n, { maxNumberLength: 20 })
    encodeSame(h.Decimal, "1e100", { maxExponent: 10 })
  })

  it("encodes cyclic values and arrays with holes as the generic path does", () => {
    const cyclic: { name: string; children: unknown[] } = { name: "a", children: [] }
    cyclic.children.push(cyclic)
    encodeSame(Tree, cyclic)
    // eslint-disable-next-line no-sparse-arrays
    encodeSame(h.Array(h.Optional(h.Int32)), [1, , 3])
    encodeSame(h.Array(h.Any), [parse("{ a: 1 }"), parse("Foo { b: [] }")])
    encodeSame(Open, { _tag: "@unknown", tag: "Z", value: parse("Z(1)") })
    encodeSame(Open, { _tag: "@unknown", tag: "A", value: parse("A") })
    encodeSame(Expr, { _tag: "Let", name: "x", body: { _tag: "Lit", value: 1n } })
    const hidden = Object.defineProperty({ _tag: "Let", body: { _tag: "Lit", value: 1n } }, "name", { value: "x", enumerable: false })
    encodeSame(Expr, hidden)
  })

  it("records: optional fields first or absent, nested; fields in another order, extra, inherited, hidden or getters", () => {
    const Inner = h.Record({ a: h.Optional(h.String), b: h.Int32, c: h.Optional(h.Maybe(h.Bool)) })
    const Outer = h.Record({ x: h.Optional(h.Int32), inner: Inner, list: h.Array(Inner), m: h.Maybe(h.String) })
    for (const text of ['{ inner: { b: 1 }, list: [{ b: 2 }, { a: "s", b: 3, c: Some(True) }], m: None }', '{ x: 1, inner: { c: None, b: 1, a: "z" }, list: [], m: Some("q") }']) {
      const decoded = decodeSame(Outer, text)
      expect(decoded.ok).toBe(true)
      encodeSame(Outer, (decoded as { value: unknown }).value)
    }
    encodeSame(Inner, Object.assign(Object.create({ a: "inherited", c: h.Maybe.none }), { b: 1 }))
    encodeSame(Inner, { c: h.Maybe.none, b: 1, a: "x" })
    encodeSame(Inner, { b: 1, extra: 2, a: "x" })
    encodeSame(Inner, Object.defineProperty({ b: 1 }, "a", { value: "hidden", enumerable: false }))
    encodeSame(Inner, new (class { b = 1; get a() { return "got" } })())
    const Cases = h.Variant({ R: Inner, N: h.Unit })
    encodeSame(Cases, { _tag: "R", b: 1, a: "x" })
    encodeSame(Cases, { b: 1, _tag: "R" })
    encodeSame(Cases, Object.defineProperty({ _tag: "R", b: 1 }, "a", { value: "hidden", enumerable: false }))
    encodeSame(Cases, Object.assign(Object.create({ a: "inherited" }), { _tag: "R", b: 1 }))
  })

  it("a schema that is only itself fails on first use as it does on the generic path", () => {
    // Built ahead by the compiler, a failing build is tried again on the generic path. (Each path
    // gets its own schema: on both, a second use says "used while it is being built" instead.)
    const loop = () => h.Recursive<number>("Loop", (self) => self)
    const compiled = outcome(() => h.parse(loop(), "1"))
    const generic = outcome(() => h.parse(loop(), "1", withCodec({}, "generic")))
    expect(errorView((compiled as { error: unknown }).error)).toEqual(errorView((generic as { error: unknown }).error))
    expect(String((generic as { error: unknown }).error)).toContain("unguarded recursion")
    const Again = h.Recursive<unknown>("Again", (self) => h.Secret(self) as h.Schema<unknown>)
    decodeSame(Again, "1")
    encodeSame(Again, h.Secret.make(1))
  })
})

describe("decodeStream", () => {
  const Event = h.Record({ id: h.Int32, kind: h.Enum("A", "B"), note: h.Optional(h.Maybe(h.String)) })
  /** Every value yielded before the end, and the error it ended with (if any). */
  const streamOf = async (schema: h.AnySchema, text: string, size: number, codec: CodecChoice) => {
    const chunks = Array.from({ length: Math.ceil(text.length / size) }, (_, i) => text.slice(i * size, (i + 1) * size))
    const values: unknown[] = []
    try {
      for await (const v of h.decodeStream(schema, chunks, withCodec({}, codec))) values.push(v)
      return { values, error: undefined }
    } catch (e) {
      return { values, error: errorView(e) }
    }
  }
  const texts = [
    "{ id: 1, kind: A }, { id: 2, kind: B, note: Some(\"x\") },\n{ id: 3, kind: A }",
    "{ id: 1, kind: A },\n{ id: 2, kind: C },\n{ id: 3, kind: A },",
    // A mismatch in the first item, a syntax error in the second: in one chunk, the syntax error wins.
    '{ id: "one", kind: A }, { id: 2 kind: B },',
    "{ id: 1, kind: A }, , { id: 2, kind: B }",
    "﻿{ id: 1, kind: A },\n// the end\n",
    "{ id: 1, kind: A, id: 2 },",
    "",
  ]
  it.each(texts)("%j", async (text) => {
    for (const size of [1, 3, 7, 1000]) {
      const generic = await streamOf(Event, text, size, "generic")
      for (const codec of COMPILED) {
        const compiled = await streamOf(Event, text, size, codec)
        expect(difference(compiled.values, generic.values), `${codec}, chunks of ${size}`).toBeUndefined()
        expect(compiled.error, `${codec}, chunks of ${size}`).toEqual(generic.error)
      }
    }
  })
})

/** Decoded values must not carry anything of the reader. */
it("decoded Any values are the generic parser's", () => {
  const v = h.parse(h.Any, "Foo { a: [1, 2.50] }") as Value
  expect(v).toEqual(parse("Foo { a: [1, 2.50] }"))
})

describe("h.optimize", () => {
  const text = '{ id: 1, tags: ["a", "b"], owner: { login: "ada" }, state: Open }'
  const make = () => {
    const { schemas } = compileSchemaFile("type Issue = { id: Int, tags: Array String, owner: User, state: < Open | Closed > }\ntype User = { login: String }\ntype Other = { n: Int }")
    return schemas as Record<"Issue" | "User" | "Other", h.Schema<unknown>>
  }

  it("by default, no code is generated: the closures", () => {
    const { Issue } = make()
    h.stringify(Issue, h.parse(Issue, text), { style: "minimised" })
    expect(generatedOrigin(Issue)).toBeUndefined()
    expect(readerFor(Issue)).toBe(readerFor(Issue, "closures"))
    expect(writerFor(Issue)).toBe(writerFor(Issue, "closures"))
  })

  it("marks the schema itself, once; generated code gives the same values and texts", () => {
    const { Issue, Other } = make()
    const closures = h.parse(Issue, text)
    expect(h.optimize(Issue)).toBe(Issue)
    expect(h.optimize(h.optimize(Issue))).toBe(Issue)
    const optimized = h.parse(Issue, text)
    expect(generatedOrigin(Issue)).toBe("new Function") // nothing built ahead here
    expect(readerFor(Issue)).toBe(readerFor(Issue, "generated"))
    expect(writerFor(Issue)).toBe(writerFor(Issue, "generated"))
    expect(difference(optimized, closures)).toBeUndefined()
    expect(h.stringify(Issue, optimized, { style: "compact" })).toBe(h.stringify(Issue, closures, withCodec({ style: "compact" }, "generic")))
    h.parse(Other, "{ n: 1 }")
    expect(generatedOrigin(Other)).toBeUndefined() // only what is marked
  })
})
