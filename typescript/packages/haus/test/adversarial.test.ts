/**
 * Hostile inputs and broken schemas: everything here must end quickly, with
 * an error where one is due, never with a hang, a stack overflow or a blowup.
 */
import { readFileSync } from "node:fs"
import { HausSchemaFileError } from "../src/schema-file.js"
import { describe, expect, it } from "vitest"
import * as h from "../src/schema.js"
import { arr, compileSchemaFile, format, fromHausJson, importJson, infer, inferSchema, num, parseAll, parseDocument, parseStream, printShape, type Value } from "../src/index.js"

/** Run `f` and fail the test if it takes longer than `ms`. */
const within = <A>(ms: number, f: () => A): A => {
  const start = performance.now()
  const out = f()
  expect(performance.now() - start).toBeLessThan(ms)
  return out
}

const errorOf = (f: () => unknown): Error => {
  try {
    f()
  } catch (e) {
    return e as Error
  }
  throw new Error("expected an error")
}

interface Tree {
  readonly name: string
  readonly children: readonly Tree[]
}
const Tree: h.Schema<Tree> = h.Recursive<Tree>("Tree", (self) => h.Record({ name: h.String, children: h.Array(self) }))

const nestedTree = (depth: number): string =>
  `{ name: "n", children: [`.repeat(depth) + `{ name: "leaf", children: [] }` + `] }`.repeat(depth)

describe("recursive schemas", () => {
  it("decode and encode a tree", () => {
    const tree = h.parse(Tree, `{ name: "root", children: [{ name: "a", children: [] }, { name: "b", children: [] }] }`)
    expect(tree.children.map((c) => c.name)).toEqual(["a", "b"])
    expect(h.stringify(Tree, tree, { style: "compact" })).toBe(
      `{ name: "root", children: [{ name: "a", children: [] }, { name: "b", children: [] }] }`,
    )
    expect(Tree.expected).toBe("Tree")
  })

  it("recursive variants", () => {
    type Expr = { _tag: "Num"; value: string } | { _tag: "Add"; values: readonly [Expr, Expr] }
    const Expr: h.Schema<Expr> = h.Recursive<Expr>("Expr", (self) => h.Variant({ Num: h.Decimal, Add: h.Tuple(self, self) }))
    const e = h.parse(Expr, "Add(Num(1), Add(Num(2), Num(3)))")
    expect(h.stringify(Expr, e)).toBe("Add(Num(1), Add(Num(2), Num(3)))")
  })

  it("recursive types are limited by the call's depth limit, and optionally a smaller one of their own", () => {
    // Each level of the tree is two levels of the value (the record and its array).
    expect(h.parse(Tree, nestedTree(127)).name).toBe("n")
    expect(errorOf(() => h.parse(Tree, nestedTree(128))).message).toContain("nesting deeper than 256 levels")
    // The same when encoding a tree built in code.
    let deep: Tree = { name: "leaf", children: [] }
    for (let i = 0; i < 127; i++) deep = { name: "n", children: [deep] }
    expect(h.stringify(Tree, deep, { style: "compact" })).toBe(nestedTree(127))
    const deeper: Tree = { name: "n", children: [deep] }
    const e = errorOf(() => h.encode(Tree, deeper))
    expect(e).toBeInstanceOf(h.HausEncodeError)
    expect(e.message).toContain("nesting deeper than 256 levels")
    expect(errorOf(() => h.parse(Tree, nestedTree(20), { maxDepth: 30 })).message).toContain("nesting deeper than 30 levels")
    const Shallow = h.Recursive<Tree>("Shallow", (self) => h.Record({ name: h.String, children: h.Array(self) }), { maxDepth: 3 })
    expect(errorOf(() => h.parse(Shallow, nestedTree(3))).message).toContain("Shallow nested deeper than 3 levels")
  })

  it("a schema that is only itself is rejected when first used", () => {
    const Loop = h.Recursive<number>("Loop", (self) => self)
    expect(() => h.parse(Loop, "1")).toThrow("unguarded recursion")
  })

  it("recursion without consuming input fails instead of looping", () => {
    // A wrapper that decodes the same value with its inner schema never moves on.
    const same = <A>(inner: h.Schema<A>): h.Schema<A> => ({ "~standard": inner["~standard"], expected: inner.expected, decode: inner.decode, encode: inner.encode })
    const P = h.Recursive<unknown>("P", (self) => same(self))
    expect(within(100, () => errorOf(() => h.parse(P, "1"))).message).toContain("unguarded recursion in P")
    // Maybe(self) consumes Some(…) when decoding and its value when encoding; a cycle fails.
    const M = h.Recursive<unknown>("M", (self) => h.Maybe(self) as h.Schema<unknown>)
    expect(h.parse(M, "Some(Some(None))")).toEqual(h.Maybe.some(h.Maybe.some(h.Maybe.none)))
    const cyclic: { _tag: "Some"; value: unknown } = { _tag: "Some", value: undefined }
    cyclic.value = cyclic
    expect(errorOf(() => h.encode(M, cyclic)).message).toContain("cyclic value")
  })

  it("mutual recursion", () => {
    interface A { readonly b: h.Maybe<B> }
    interface B { readonly a: A }
    const A: h.Schema<A> = h.Recursive<A>("A", () => h.Record({ b: h.Maybe(B) }))
    const B: h.Schema<B> = h.Record({ a: A })
    expect(h.parse(A, "{ b: Some({ a: { b: None } }) }")).toEqual({ b: { _tag: "Some", value: { a: { b: { _tag: "None" } } } } })
  })
})

describe("work budget", () => {
  it("normal decoding stays well inside the budget", () => {
    const wide = `{ name: "root", children: [${Array.from({ length: 20000 }, (_, i) => `{ name: "${i}", children: [] }`).join(", ")}] }`
    expect(within(2000, () => h.parse(Tree, wide)).children).toHaveLength(20000)
  })

  it("a schema doing exponential work is stopped", () => {
    // A buggy combinator that decodes everything twice: 2^depth work on nested arrays.
    const twice = <A>(s: h.Schema<A>): h.Schema<A> => ({
      "~standard": s["~standard"],
      expected: s.expected,
      decode: (v, at) => {
        s.decode(v, at)
        return s.decode(v, at)
      },
      encode: s.encode,
    })
    type Nest = readonly Nest[]
    const Nest: h.Schema<Nest> = h.Recursive<Nest>("Nest", (self) => twice(h.Array(self)))
    const text = "[".repeat(40) + "]".repeat(40)
    const e = within(1000, () => errorOf(() => h.parse(Nest, text)))
    expect(e).toBeInstanceOf(h.HausDecodeError)
    expect(e.message).toContain("decode budget")
  })

  it("encoding shared sub-objects (a DAG) can't expand without bound", () => {
    type Nest = readonly Nest[]
    const Nest: h.Schema<Nest> = h.Recursive<Nest>("Nest", (self) => h.Array(self), { maxDepth: 100 })
    let x: Nest = []
    for (let i = 0; i < 50; i++) x = [x, x] // 2^50 nodes when written out
    const e = within(5000, () => errorOf(() => h.encode(Nest, x, { maxSteps: 100_000 })))
    expect(e).toBeInstanceOf(h.HausEncodeError)
    expect(e.message).toContain("encode budget")
  })
})

describe("encoding hostile JS values", () => {
  it("cycles are reported, not followed", () => {
    const node: { name: string; children: Tree[] } = { name: "loop", children: [] }
    node.children.push(node)
    const e = errorOf(() => h.encode(Tree, node))
    expect(e).toBeInstanceOf(h.HausEncodeError)
    expect(e.message).toContain("cyclic value")
    expect((e as h.HausEncodeError).path).toEqual(["children", 0])
  })

  it("shared (non-cyclic) objects are fine", () => {
    const leaf = { name: "x", children: [] }
    expect(h.stringify(Tree, { name: "r", children: [leaf, leaf] }, { style: "compact" })).toContain(`[{ name: "x", children: [] }, { name: "x"`)
  })

  it("error messages never call the value's methods", () => {
    const bare = Object.create(null) as unknown
    expect(errorOf(() => h.encode(h.Int, bare as bigint)).message).toBe("expected a bigint, got an object at $")
    const huge = "x".repeat(1_000_000)
    expect(errorOf(() => h.encode(h.Int, huge as unknown as bigint)).message.length).toBeLessThan(100)
  })

  it("the raw value of an Unknown is checked before it is written", () => {
    const Event = h.OpenVariant({ Ping: h.Unit })
    const cyclic = arr([]) as { kind: "array"; items: Value[] }
    cyclic.items.push(cyclic)
    const fake = { _tag: "@unknown", tag: "X", value: cyclic } as unknown as h.Unknown
    expect(errorOf(() => h.encode(Event, fake)).message).toContain("nesting deeper than 256")
    const notAValue = { _tag: "@unknown", tag: "X", value: { evil: true } } as unknown as h.Unknown
    expect(errorOf(() => h.encode(Event, notAValue)).message).toContain("expected a haus value")
  })
})

describe("decoding values built in code", () => {
  it("a cyclic Value is rejected before decoding", () => {
    const cyclic = arr([]) as { kind: "array"; items: Value[] }
    cyclic.items.push(cyclic)
    expect(errorOf(() => h.decode(h.Array(h.Int), cyclic)).message).toContain("nested deeper than 256")
  })

  it("depth is limited even for schemas without recursion", () => {
    let v: Value = num("1")
    for (let i = 0; i < 300; i++) v = arr([v])
    expect(errorOf(() => h.decode(h.Array(h.Int), v)).message).toContain("nested deeper than 256")
  })
})

describe("duplicate keys stay linear (spec §7)", () => {
  // Every check is a Map, a Set or an Object.create(null) lookup: V8 hashes strings and
  // array indices with a seed chosen at random per process, so keys can't be crafted to
  // collide. Names (k0 …) and array indices ("0" …) are kept apart by V8, so both are tried.
  const N = 100_000
  const names = Array.from({ length: N }, (_, i) => `k${i}`)
  const indices = Array.from({ length: N }, (_, i) => `${i}`)
  const record = (keys: readonly string[], extra = "") => `{ ${keys.map((k) => `${JSON.stringify(k)}: 1`).join(", ")}${extra} }`
  const object = (keys: readonly string[], extra = "", value = "1") => `{${keys.map((k) => `${JSON.stringify(k)}: ${value}`).join(",")}${extra}}`
  const Counts = h.Map(h.Int32)

  it("haus records with many keys, and a duplicate found at the end", () => {
    for (const keys of [names, indices]) {
      expect(within(3000, () => parseAll(record(keys)))[0]).toMatchObject({ kind: "record" })
      expect(within(3000, () => errorOf(() => parseAll(record(keys, `, ${JSON.stringify(keys[0])}: 2`)))).message).toContain("duplicate key")
      expect(within(3000, () => h.parse(Counts, record(keys))).size).toBe(N)
    }
  })

  it("JSON objects with many members: parsing, schema-based, self-describing and the import", () => {
    for (const keys of [names, indices]) {
      expect(within(3000, () => errorOf(() => importJson(object(keys, `,${JSON.stringify(keys[0])}:2`)))).message).toContain("duplicate member name")
      expect(within(3000, () => importJson(object(keys)))).toMatchObject({ kind: "record" })
      expect(within(3000, () => h.fromJson(Counts, object(keys))).size).toBe(N)
      expect(within(3000, () => fromHausJson(`{"_haus":1,"_value":{"_rec":${object(keys, "", `"v"`)}}}`))).toMatchObject({ kind: "record" })
    }
  })
})

describe("generic types can't grow without bound (spec §9.10)", () => {
  const codeOf = (text: string): string | undefined => {
    const e = errorOf(() => compileSchemaFile(text))
    expect(e).toBeInstanceOf(HausSchemaFileError)
    return (e as HausSchemaFileError).code
  }

  it("instances that double through another definition are rejected before any is made", () => {
    const text = [
      "type P a b = { l: a, r: b }",
      "type A a = < X (B (P a a)) | Done >",
      "type B a = < Y (A (P a a)) | Stop >",
      "type Root = A Int",
    ].join("\n")
    const e = within(1000, () => errorOf(() => compileSchemaFile(text))) as HausSchemaFileError
    expect(e.code).toBe("growing-recursion")
    expect([e.line, e.column]).toEqual([2, 17])
    expect(e.message).toContain("A refers to B, which refers back to A")
  })

  it("and through three definitions, with the growing argument only on the way back", () => {
    const text = [
      "type P a b = { l: a, r: b }",
      "type A a = < X (B a) | Done >",
      "type B a = < Y (C a) | Stop >",
      "type C a = < Z (A (P a a)) | End >",
      "type Root = A Int",
    ].join("\n")
    const e = within(1000, () => errorOf(() => compileSchemaFile(text))) as HausSchemaFileError
    expect(e.code).toBe("growing-recursion")
    expect([e.line, e.column]).toEqual([4, 17])
    expect(e.message).toContain("C refers to A")
  })

  it("definitions that refer to each other with their own parameters are fine", () => {
    within(1000, () => compileSchemaFile("type GTree a = { value: a, kids: Forest a }\ntype Forest a = Array (GTree a)\ntype Swap a b = < S (Pair b a) | E >\ntype Pair a b = { p: Swap a b, q: Swap b a }\ntype Root = GTree (Pair Int String)"))
    expect(codeOf("type L a = < Nil | Cons a (L (Array a)) >")).toBe("growing-recursion")
  })

  it("arguments nested 30 levels deep in non-recursive generics compile quickly", () => {
    const levels = 30
    const chain = (step: string) =>
      [`type G0 a = { v: a }`, ...Array.from({ length: levels - 1 }, (_, k) => `type G${k + 1} a = G${k} (${step})`), `type Root = G${levels - 1} Int`].join("\n")
    const nested = `type P a b = { l: a, r: b }\ntype Root = ${"P (".repeat(levels)}P Int Int${") Int".repeat(levels)}`
    for (const text of [`type P a b = { l: a, r: b }\n${chain("P a a")}`, chain("{ l: a, r: a }"), chain("< L a | R a >"), nested]) {
      const { schemas } = within(1000, () => compileSchemaFile(text))
      expect(schemas.Root).toBeDefined()
    }
  })
})

describe("tooling stays linear on hostile files", () => {
  it("schema inference on deeply nested records and variants", () => {
    const key = "k".repeat(80)
    within(500, () => inferSchema(parseAll(`{ ${key}: `.repeat(250) + "1" + " }".repeat(250))))
    within(500, () => inferSchema(parseAll(`${"T".repeat(80)} { x: `.repeat(250) + "1" + " }".repeat(250))))
  })

  it("formatting a file with many comments", () => {
    const text = "[\n" + Array.from({ length: 20000 }, (_, i) => `  [${i}], // c${i}\n`).join("") + "]\n"
    const doc = parseDocument(text)
    within(1500, () => format(doc.values, { source: text, comments: doc.comments }))
  })

  it("formatting deeply nested positional payloads", () => {
    within(500, () => format(parseAll("A(".repeat(250) + `"${"x".repeat(1000)}"` + ")".repeat(250))))
  })

  it("a large value arriving in tiny chunks", async () => {
    const text = "[" + Array.from({ length: 100000 }, (_, i) => `${i}`).join(",") + "],"
    async function* chunks() {
      for (let i = 0; i < text.length; i += 7) yield text.slice(i, i + 7)
    }
    const start = performance.now()
    for await (const v of parseStream(chunks())) expect(v.kind).toBe("array")
    expect(performance.now() - start).toBeLessThan(2000)
  })
})

describe("inferring recursive types", () => {
  const thread = (depth: number, extra = (_: number) => "") =>
    Array.from({ length: depth }, (_, i) => `Comment { text: "t", ${extra(i)}replies: [`).join("") +
    `Comment { text: "end", replies: [] }` + "] }".repeat(depth)

  it("a type nested in itself gets a name instead of being unrolled", () => {
    const values = parseAll(thread(15))
    const { root, shapeOf } = infer(values)
    expect(printShape(root)).toBe("Comment\n\ntype Comment = < Comment { text: String, replies: Array Comment } >")
    const replies = (values[0] as Extract<Value, { kind: "variant" }>).args[0] as Extract<Value, { kind: "record" }>
    // Hovering part of the file uses the same names.
    expect(printShape(shapeOf.get(replies.fields.get("replies")!)!, { context: root })).toBe(
      "Array Comment\n\ntype Comment = < Comment { text: String, replies: Array Comment } >",
    )
  })

  it("records nested in records with the same keys, and Maybe links", () => {
    expect(inferSchema(parseAll(`{ name: "r", children: [{ name: "a", children: [] }] }`))).toContain(
      "type Node =\n  { name: String, children: Array Node }",
    )
    expect(inferSchema(parseAll(`{ value: 1, next: Some({ value: 2, next: None }) }`))).toContain(
      "type Node =\n  { value: Int, next: Maybe Node }",
    )
    expect(printShape(infer(parseAll("Some(Some(1))")).root)).toBe("Maybe (Maybe Int)")
  })

  it("fields that only some levels have become optional", () => {
    const text = thread(3, (i) => (i === 1 ? "edited: True, " : ""))
    expect(printShape(infer(parseAll(text)).root)).toContain("edited?: Bool")
  })

  it("types nested in each other in turns, with different fields per level (examples/filesystem.haus)", () => {
    const schema = inferSchema(parseAll(readFileSync(new URL("../../../../examples/filesystem.haus", import.meta.url), "utf8")))
    expect(schema).toContain("type Root =\n  Node\n")
    for (const part of [
      "children: Array Node", // Folder
      "contents: Array Node", // Archive, merged with the folder entries
      "root: Node", // Mount
      "owner?: String", // only some folders
      "size: Decimal", // one size is 0.5
      "checksum?: < Sha256 String >",
      "| Link < Path String >",
      "format: < Zip | Tar { compressed: Maybe < Gzip > } >",
    ]) expect(schema).toContain(part)
  })

  it("a deep view tree reached through several fields (examples/settings-ui.haus)", () => {
    const text = readFileSync(new URL("../../../../examples/settings-ui.haus", import.meta.url), "utf8")
    const schema = within(200, () => inferSchema(parseAll(text)))
    for (const part of [
      "< Screen { route: String, root: Node } >",
      "children: Array Node",
      "| When { condition: < FeatureFlag String >, then: Node, else: Node }",
      "onClick: < Reset | Open < Url String > | Navigate String >",
      "style?: { padding: Int, font: { size: Decimal, weight: < Bold | Regular > } }",
    ]) expect(schema).toContain(part)
  })

  it("unifying stays linear: deep, wide and with a new field at every level", () => {
    // 120 levels (240 brackets, near the parser's limit of 256), each adding its own field.
    within(500, () => inferSchema(parseAll(thread(120, (i) => `f${i}: ${i}, `))))
    // Two types nested in each other in turns, 20,000 values in all.
    const ab = (depth: number): string =>
      depth === 0 ? "Leaf" : depth % 2 ? `A { x: [${ab(depth - 1)}, Leaf, "s"] }` : `B { y: [${ab(depth - 1)}, 1, Leaf] }`
    const many = Array.from({ length: 1000 }, () => ab(20)).join(",\n")
    const schema = within(1500, () => inferSchema(parseAll(many)))
    expect(schema).toContain("type Node =\n  String | < B { y: Array (Int | < A { x: Array Node } | Leaf >) } | Leaf >")
  })
})
