/**
 * Hostile inputs and broken schemas through the Effect adapter: everything
 * must end quickly, with an error where one is due.
 */
import { describe, expect, it } from "vitest"
import { BigDecimal, Cause, DateTime, Effect, Exit, Option, Redacted, Schema, Stream } from "effect"
import { arr, h, parse, uncheckedArr, type Value } from "@haus-fmt/haus/internal"
import * as Haus from "../src/index.js"
import { compileText } from "./support.js"

interface TA { readonly _tag: "A"; readonly a: ReadonlyArray<TA | TB> }
interface TB { readonly _tag: "B"; readonly a: ReadonlyArray<TA | TB>; readonly b: string }
const TA: Schema.Codec<TA> = Schema.TaggedStruct("A", { a: Schema.Array(Schema.suspend(() => Schema.Union([TB, TA]))) })
const TB: Schema.Codec<TB> = Schema.TaggedStruct("B", { a: Schema.Array(Schema.suspend(() => Schema.Union([TB, TA]))), b: Schema.String })

describe("recursive schemas", () => {
  it("tagged recursive unions decode in linear time up to the depth limit", () => {
    const text = "A { a: [".repeat(127) + `B { a: [], b: "x" }` + "] }".repeat(127)
    const start = performance.now()
    const tree = Effect.runSync(Haus.decode(TA)(text))
    expect(performance.now() - start).toBeLessThan(1000)
    expect(tree._tag).toBe("A")
  })

  it("recursive values are limited only by the nesting depth (spec §9.9)", () => {
    const { schemas } = compileText(
      "type Ints = < Nil | Cons Int Ints >\ntype Tree = { children: Array Tree }\ntype Chain = { next: Maybe (Array (Maybe Chain)) }",
    )
    const ints = "Cons(1, ".repeat(255) + "Nil" + ")".repeat(255)
    const tree = "{ children: [".repeat(127) + "{ children: [] }" + "] }".repeat(127)
    // Three levels of the value per Chain, and more schema wrappers than that.
    const chain = "{ next: Some([Some ".repeat(84) + "{ next: None }" + "]) }".repeat(84)
    for (const [schema, text] of [[schemas.Ints!, ints], [schemas.Tree!, tree], [schemas.Chain!, chain]] as const) {
      const decoded = Effect.runSync(Haus.decode(schema)(text))
      expect(Effect.runSync(Haus.encode(schema)(decoded, { style: "compact" }))).toBe(text)
    }
  })

  it("recursive unions whose members can't be told apart are rejected up front", () => {
    // Effect tries union members in turn: with recursion that is exponential.
    interface A { readonly a: ReadonlyArray<A | B> }
    interface B { readonly a: ReadonlyArray<A | B>; readonly b: string }
    const A: Schema.Codec<A> = Schema.Struct({ a: Schema.Array(Schema.suspend(() => Schema.Union([B, A]))) })
    const B: Schema.Codec<B> = Schema.Struct({ a: Schema.Array(Schema.suspend(() => Schema.Union([B, A]))), b: Schema.String })
    expect(() => Haus.decode(A)).toThrow("can't be told apart")
    expect(() => Haus.encode(A)).toThrow("can't be told apart")
  })

  it("ambiguous unions without recursion are allowed (bounded by the schema)", () => {
    const S = Schema.Union([Schema.Struct({ x: Schema.Number }), Schema.Struct({ y: Schema.String })])
    expect(Effect.runSync(Haus.decode(S)("{ y: \"a\" }"))).toEqual({ y: "a" })
  })
})

/** A HausSchemaError, as the error of an encoder (whose type also allows a HausLimitsError). */
const schemaError = (e: unknown): Haus.HausSchemaError => {
  expect(e).toBeInstanceOf(Haus.HausSchemaError)
  return e as Haus.HausSchemaError
}

describe("values built in code", () => {
  it("what the core's constructors reject is a HausSchemaError with its code, not a defect (spec §11)", () => {
    const lower = Effect.runSync(Effect.flip(Haus.encodeValue(Schema.TaggedStruct("lower", {}))({ _tag: "lower" })))
    expect(lower).toMatchObject({ _tag: "HausSchemaError", code: "invalid-tag" })
    const lone = Effect.runSync(Effect.flip(Haus.encode(Schema.Struct({ s: Schema.String }))({ s: "x\uD800" })))
    expect(lone).toMatchObject({ _tag: "HausSchemaError", code: "cannot-encode" })
    const key = Effect.runSync(Effect.flip(Haus.encode(Schema.Record(Schema.String, Schema.Finite))({ "k\uDC00": 1 })))
    expect(key).toMatchObject({ _tag: "HausSchemaError", code: "cannot-encode" })
  })

  it("a forged cyclic Value fails instead of looping", () => {
    // The constructors can't build one (they copy and freeze): a parsed array changed with a cast.
    const forged = parse("[]") as unknown as { items: unknown[] }
    forged.items.push(forged)
    const cyclic = forged as unknown as Value
    const exit = Effect.runSyncExit(Haus.decodeValue(Schema.Array(Schema.Unknown))(cyclic))
    expect(Exit.isFailure(exit)).toBe(true)
    if (Exit.isFailure(exit)) expect(Cause.pretty(exit.cause)).toContain("nested deeper than 256")
  })

  it("a shared Value (a DAG) counts each time it is reached, but fails at once beyond the limit", () => {
    // 2^41 − 1 values when expanded, 41 objects in memory: the core and the adapter both fail with too-many-nodes.
    // The constructors refuse to build it (too-many-nodes, spec §7); the readers' unchecked ones stand in for a forged value.
    expect(() => Array.from({ length: 40 }).reduce<Value>((x) => arr([x, x]), arr([]))).toThrow(expect.objectContaining({ code: "too-many-nodes" }))
    const dag = Array.from({ length: 40 }).reduce<Value>((x) => uncheckedArr([x, x]), uncheckedArr([]))
    const [codes, ms] = timed(() => [
      Effect.runSync(Effect.flip(Haus.decodeValue(Tree)(dag))).code,
      Effect.runSync(Effect.flip(Haus.decodeValue(Haus.Any)(dag))).code,
    ])
    expect(ms).toBeLessThan(1000)
    expect(codes).toEqual(["too-many-nodes", "too-many-nodes"])
    // Within the limits, a shared Value decodes as the tree it expands to, and is held to maxDepth along every path.
    const small = Array.from({ length: 9 }).reduce<Value>((x) => arr([x, x]), arr([]))
    expect(Effect.runSync(Haus.decodeValue(Tree)(small))).toEqual(sharedTree(10))
    expect(h.decode(h.Any, small)).toBe(small)
    expect(Effect.runSync(Effect.flip(Haus.decodeValue(Tree)(small, { maxDepth: 9 }))).code).toBe("nesting-too-deep")
    expect(Effect.runSync(Haus.decodeValue(Tree)(small, { maxDepth: 10 }))).toEqual(sharedTree(10))
  })

  it("a cyclic object fails when encoding instead of looping, before Effect's encoder sees it", () => {
    const node: { _tag: "A"; a: TA[] } = { _tag: "A", a: [] }
    node.a.push(node)
    const e = schemaError(Effect.runSync(Effect.flip(Haus.encode(TA)(node))))
    expect(e.code).toBe("cyclic-value")
    expect(e.place).toBe("$.a[0]")
    // Also where the schema doesn't recurse, and in every encoder.
    const loop = {} as { self: unknown }
    loop.self = loop
    const Loose = Schema.Struct({ self: Schema.Unknown })
    const errors = [
      Effect.runSync(Effect.flip(Haus.encode(Loose)(loop))),
      Effect.runSync(Effect.flip(Haus.encodeValue(Loose)(loop))),
      Effect.runSync(Effect.flip(Haus.toJson(Loose)(loop))),
      Effect.runSync(Effect.flip(Haus.convert(Loose)(loop))),
    ]
    for (const e of errors.map(schemaError)) expect([e.code, e.place]).toEqual(["cyclic-value", "$.self"])
  })
})

/** A tree of arrays (`[[], [[]]]`), the shape a DAG expands into. */
type Tree = ReadonlyArray<Tree>
const Tree: Schema.Codec<Tree> = Schema.Array(Schema.suspend(() => Tree))
interface Bin { readonly a?: Bin; readonly b?: Bin }
const Bin: Schema.Codec<Bin> = Schema.Struct({ a: Schema.optionalKey(Schema.suspend(() => Bin)), b: Schema.optionalKey(Schema.suspend(() => Bin)) })

/** `n` levels of one object referenced twice: 2^n − 1 nodes when expanded, n objects in memory. */
const sharedTree = (n: number): Tree => Array.from({ length: n - 1 }).reduce<Tree>((x) => [x, x], [])
const sharedBin = (n: number): Bin => Array.from({ length: n - 1 }).reduce<Bin>((x) => ({ a: x, b: x }), {})

/** Run `f` and how long it took, in milliseconds. */
const timed = <A>(f: () => A): [A, number] => {
  const start = performance.now()
  const a = f()
  return [a, performance.now() - start]
}

describe("values built in code: Effect's encoder sees them only within the limits (spec §9.8)", () => {
  it("objects shared 2^31 times fail fast with step-budget, in every encoder", () => {
    // Effect's encoder alone would visit 2^31 − 1 nodes (≈ 0.5 s at 2^18 of them, so hours).
    const tree = sharedTree(31)
    const bin = sharedBin(31)
    const [errors, ms] = timed(() => [
      Effect.runSync(Effect.flip(Haus.encode(Tree)(tree))),
      Effect.runSync(Effect.flip(Haus.encodeValue(Tree)(tree))),
      Effect.runSync(Effect.flip(Haus.toJson(Tree)(tree))),
      Effect.runSync(Effect.flip(Haus.toJsonValue(Tree)(tree))),
      Effect.runSync(Effect.flip(Haus.convert(Tree)(tree))),
      Effect.runSync(Effect.flip(Stream.runCollect(Haus.encodeStream(Tree)(Stream.make(tree))))),
      Effect.runSync(Effect.flip(Stream.runCollect(Haus.encodeJsonLines(Tree)(Stream.make(tree))))),
      Effect.runSync(Effect.flip(Haus.encode(Bin)(bin))),
    ])
    expect(ms).toBeLessThan(1000)
    for (const e of errors) {
      expect(e).toBeInstanceOf(Haus.HausSchemaError)
      expect(e.code).toBe("step-budget")
      expect(e.message).toContain(`encode budget of ${16 * 1024 * 1024} steps exceeded`)
    }
  })

  it("the walk follows the schema into classes, Options, Redacteds and Maps, and union members by tag", () => {
    // @effect-diagnostics-next-line schemaClassMissingBrand:off -- a test class, never confused with another
    class Node extends Schema.Class<Node>("Node")({
      kids: Schema.Array(Schema.Option(Schema.suspend((): Schema.Codec<Node> => Node))),
      secret: Schema.optionalKey(Schema.Redacted(Schema.suspend((): Schema.Codec<Node> => Node))),
      byName: Schema.optionalKey(Schema.ReadonlyMap(Schema.String, Schema.suspend((): Schema.Codec<Node> => Node))),
    }) {}
    const leaf = new Node({ kids: [] })
    const shapes = (n: number) => Array.from({ length: n }).reduce<Node>((x) => new Node({ kids: [Option.some(x), Option.some(x)] }), leaf)
    const secrets = (n: number) => Array.from({ length: n }).reduce<Node>((x) => new Node({ kids: [Option.some(x)], secret: Redacted.make(x) }), leaf)
    const maps = (n: number) => Array.from({ length: n }).reduce<Node>((x) => new Node({ kids: [], byName: new Map([["a", x], ["b", x]]) }), leaf)
    const [errors, ms] = timed(() => [shapes(40), secrets(40), maps(40)].map((v) => schemaError(Effect.runSync(Effect.flip(Haus.encode(Node)(v))))))
    expect(ms).toBeLessThan(1000)
    for (const e of errors) expect(e.code).toBe("step-budget")
    // Small ones encode as before.
    expect(Effect.runSync(Haus.encode(Node)(shapes(1), { style: "compact" }))).toBe("{ kids: [Some { kids: [] }, Some { kids: [] }] }")
    // A tagged union: only the member the tag names is followed.
    const [e, tms] = timed(() => schemaError(Effect.runSync(Effect.flip(Haus.encode(TA)(Array.from({ length: 40 }).reduce<TA>((x) => ({ _tag: "A", a: [x, x] }), { _tag: "A", a: [] }))))))
    expect(tms).toBeLessThan(1000)
    expect(e.code).toBe("step-budget")
  })

  it("properties outside the schema aren't walked: back-references and caches there are no error", () => {
    interface Entity { readonly name: string; readonly children: ReadonlyArray<Entity> }
    const Entity: Schema.Codec<Entity> = Schema.Struct({ name: Schema.String, children: Schema.Array(Schema.suspend(() => Entity)) })
    const root = { name: "root", children: [] as Array<Entity>, parent: undefined as unknown, cache: {} as Record<string, unknown> }
    const child = { name: "child", children: [], parent: root }
    root.children.push(child)
    root.parent = root
    root.cache["self"] = root.cache
    root.cache["huge"] = sharedTree(40) // 2^40 nodes when expanded, outside the schema
    const [text, ms] = timed(() => Effect.runSync(Haus.encode(Entity)(root, { style: "compact" })))
    expect(ms).toBeLessThan(1000)
    expect(text).toBe(`{ name: "root", children: [{ name: "child", children: [] }] }`)
    // Where the schema says `Unknown`, the haus converter walks everything: a cycle there is one.
    const Loose = Schema.Struct({ name: Schema.String, meta: Schema.Unknown })
    expect(schemaError(Effect.runSync(Effect.flip(Haus.encode(Loose)({ name: "x", meta: root })))).code).toBe("cyclic-value")
  })

  it("maxSteps is the budget: values counted each time they are reached", () => {
    const tree = sharedTree(10) // 1023 arrays when expanded
    expect(Effect.runSync(Haus.encodeValue(Tree)(tree, { maxSteps: 1023 })).kind).toBe("array")
    const e = Effect.runSync(Effect.flip(Haus.encodeValue(Tree)(tree, { maxSteps: 1022 })))
    expect(e.code).toBe("step-budget")
    expect(e.message).toContain("encode budget of 1022 steps exceeded")
  })

  it("shared objects within the budget encode as the tree they expand to", () => {
    const shared = [[]] as Tree
    expect(Effect.runSync(Haus.encode(Tree)([shared, shared, [shared]], { style: "compact" }))).toBe("[[[]], [[]], [[[]]]]")
    const text = Effect.runSync(Haus.encode(Tree)(sharedTree(12), { style: "minimised" }))
    expect(text).toBe(Effect.runSync(Haus.encode(Tree)(Effect.runSync(Haus.decode(Tree)(text)), { style: "minimised" })))
    // Two brackets per array, a comma per pair.
    expect(text.length).toBe(2 * (2 ** 12 - 1) + (2 ** 11 - 1))
    expect(Effect.runSync(Haus.encode(Bin)(sharedBin(3), { style: "compact" }))).toBe("{ a: { a: {}, b: {} }, b: { a: {}, b: {} } }")
  })

  it("values nested too deeply for Effect's encoder fail with nesting-too-deep, not a stack overflow", () => {
    const deep = (n: number): Tree => Array.from({ length: n - 1 }).reduce<Tree>((x) => [x], [])
    for (const n of [529, 5000, 100_000]) {
      const e = Effect.runSync(Effect.flip(Haus.encode(Tree)(deep(n))))
      expect(e.code).toBe("nesting-too-deep")
      expect(e.message).toContain("value nested deeper than 528 levels of objects (twice maxDepth 256, plus 16)")
    }
    // Within that, the value itself is held to maxDepth, as before.
    const e = Effect.runSync(Effect.flip(Haus.encode(Tree)(deep(528))))
    expect([e.code, e.message]).toEqual(["nesting-too-deep", "value nested deeper than 256 levels (or cyclic)"])
    expect(Effect.runSync(Haus.encode(Tree)(deep(8), { style: "compact" }))).toBe("[".repeat(8) + "]".repeat(8))
    // A lowered maxDepth lowers the bound on objects too.
    expect(Effect.runSync(Effect.flip(Haus.encode(Tree)(deep(21), { limits: { maxDepth: 2 } }))).message).toContain("deeper than 20 levels of objects")
  })

  it("a cycle inside a secret is reported at the secret, without a path into it", () => {
    const S = Schema.Struct({ key: Schema.Redacted(Schema.Struct({ next: Schema.Unknown })) })
    const inner = {} as { next: unknown }
    inner.next = inner
    const e = schemaError(Effect.runSync(Effect.flip(Haus.encode(S)({ key: Redacted.make(inner) }))))
    expect([e.code, e.place]).toEqual(["cyclic-value", "$.key"])
  })

  it("ordinary values encode unchanged", () => {
    const Order = Schema.Struct({
      id: Schema.BigInt,
      at: Haus.InstantAsDateTime,
      total: Haus.DecimalAsBigDecimal,
      tags: Schema.Array(Schema.String),
      note: Schema.Option(Schema.String),
      bytes: Schema.Uint8Array,
      key: Schema.Redacted(Schema.String),
      raw: Haus.Any,
      shape: Schema.Union([Schema.TaggedStruct("Circle", { r: Schema.Finite }), Schema.TaggedStruct("Square", { side: Schema.Finite })]),
    })
    const raw = Effect.runSync(Haus.decode(Haus.Any)("T { a: [1, Some(x\"00ff\")] }"))
    // A BigDecimal caches its normal form, which refers to itself: a cycle of host data, not of the value.
    const total = BigDecimal.fromStringUnsafe("19.90")
    const normal = BigDecimal.normalize(total)
    expect([(total as unknown as { normalized: unknown }).normalized, (normal as unknown as { normalized: unknown }).normalized]).toEqual([normal, normal])
    const order = {
      id: 7n,
      at: DateTime.makeUnsafe(0),
      total,
      tags: ["a", "b"],
      note: Option.some("hi"),
      bytes: new Uint8Array([0, 255]),
      key: Redacted.make("s3cret"),
      raw,
      shape: { _tag: "Circle", r: 1.5 } as const,
    }
    expect(Effect.runSync(Haus.encode(Order)(order, { style: "compact", revealSecrets: true }))).toBe(
      `{ id: 7, at: Instant("1970-01-01T00:00:00Z"), total: 19.90, tags: ["a", "b"], note: Some("hi"), bytes: x"00ff", key: "s3cret", raw: T { a: [1, Some(x"00ff")] }, shape: Circle { r: 1.5 } }`,
    )
    // Without revealSecrets, the secret is refused at its place (spec §15).
    expect(Effect.runSync(Effect.flip(Haus.encode(Order)(order)))).toMatchObject({ code: "cannot-encode", place: "$.key" })
  })
})
