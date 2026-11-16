/**
 * The deepest nesting the binding supports (spec §7): every path works at
 * MAX_SUPPORTED_DEPTH, and a larger configured `maxDepth` is a RangeError
 * naming the maximum, not a stack overflow on deep input.
 */
import { describe, expect, it } from "vitest"
import * as h from "../src/schema.js"
import {
  arr, canonical, format, fromHausJson, fromHausJsonLines, fromHausJsonValue, hash, hausJsonDepth, HausSyntaxError, importJson, importJsonLines, importJsonValue, jsonDepth,
  JsonNumber, jsonObject, MAX_SUPPORTED_DEPTH, parse, parseAll, parseDocument, parseJson, parseJsonLines, parseStream, parseWithLocations, rec, StreamReader, stringify,
  stringifyJson, toHausJson, toHausJsonLines, toHausJsonValue, variant, type Json, type Value,
} from "../src/index.js"

const MAX = MAX_SUPPORTED_DEPTH
const limits = { maxDepth: MAX }

/** `n` levels of arrays, as text and as a value built in code. */
const nested = (n: number) => "[".repeat(n) + "]".repeat(n)
const nestedValue = (n: number): Value => Array.from({ length: n - 1 }).reduce<Value>((inner) => arr([inner]), arr([]))
/** `n` levels of `T { a: … }`: one level each in haus, four in self-describing JSON. */
const tagged = (n: number) => "T { a: ".repeat(n) + "1" + " }".repeat(n)

type Nest = readonly Nest[]
const Nest: h.Schema<Nest> = h.Recursive<Nest>("Nest", (self) => h.Array(self))
const nestedArray = (n: number): Nest => Array.from({ length: n - 1 }).reduce<Nest>((inner) => [inner], [])
interface Tree { readonly _tag: "Node"; readonly kids: readonly Tree[] }
const Tree: h.Schema<Tree> = h.Recursive<Tree>("Tree", (self) => h.Variant({ Node: h.Record({ kids: h.Array(self) }) }))
/** `n` nodes: 2n levels (a `Node { … }` and its array). */
const tree = (n: number): Tree => Array.from({ length: n - 1 }).reduce<Tree>((inner) => ({ _tag: "Node", kids: [inner] }), { _tag: "Node", kids: [] })

/** Deep equality of plain data without recursion in the test runner (vitest's `toEqual` overflows at these depths). */
const same = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b)

const collect = async <A>(xs: AsyncIterable<A>): Promise<A[]> => {
  const out: A[] = []
  for await (const x of xs) out.push(x)
  return out
}

const errorOf = async (f: () => unknown): Promise<Error> => {
  try {
    await f()
  } catch (e) {
    return e as Error
  }
  throw new Error("expected an error")
}

describe("MAX_SUPPORTED_DEPTH", () => {
  it("is 512", () => {
    expect(MAX).toBe(512)
  })

  it("parses at it, as text, with locations and as a stream", async () => {
    expect(parse(nested(MAX), limits).kind).toBe("array")
    expect(parse(tagged(MAX), limits).kind).toBe("variant")
    expect(parse("A(".repeat(MAX) + "1" + ")".repeat(MAX), limits).kind).toBe("variant")
    expect(parseWithLocations(nested(MAX), limits)).toHaveLength(1)
    const reader = new StreamReader({ limits })
    expect(reader.push(`${tagged(MAX)},`)).toHaveLength(1)
    expect(await collect(parseStream([nested(MAX), ",", nested(MAX)], { limits }))).toHaveLength(2)
    expect(() => parse(nested(MAX + 1), limits)).toThrow(`nesting deeper than ${MAX} levels`)
  })

  it("formats, writes canonically and hashes at it", async () => {
    const value = parse(tagged(MAX), limits)
    expect(stringify(value, { style: "compact" })).toBe(tagged(MAX))
    expect(canonical(parse(stringify(value), limits))).toBe(canonical(value))
    const { values, comments } = parseDocument(`// deep\n${tagged(MAX)}`, limits)
    expect(format(values, { source: `// deep\n${tagged(MAX)}`, comments })).toContain("// deep")
    expect(canonical(value)).toBe("T{a:".repeat(MAX) + "1" + "}".repeat(MAX))
    expect(await hash(value)).toMatch(/^[0-9a-f]{64}$/)
  })

  it("decodes and encodes with a schema at it", async () => {
    expect(same(h.decode(Nest, nestedValue(MAX), limits), nestedArray(MAX))).toBe(true)
    expect(same(h.parse(Nest, nested(MAX), limits), nestedArray(MAX))).toBe(true)
    expect(canonical(h.encode(Nest, nestedArray(MAX), limits))).toBe(canonical(nestedValue(MAX)))
    expect(h.stringify(Nest, nestedArray(MAX), { style: "compact", ...limits })).toBe(nested(MAX))
    expect(same(h.parse(Tree, h.stringify(Tree, tree(MAX / 2), limits), limits), tree(MAX / 2))).toBe(true)
    expect(same(await collect(h.decodeStream(Tree, [`${h.stringify(Tree, tree(MAX / 2), { style: "compact", ...limits })},`], limits)), [tree(MAX / 2)])).toBe(true)
    expect(await collect(h.encodeStream(Nest, [nestedArray(MAX)], limits))).toEqual([`${nested(MAX)},\n`])
    expect(() => h.encode(Nest, nestedArray(MAX + 1), limits)).toThrow(`deeper than ${MAX} levels`)
    expect(() => h.decode(Nest, nestedValue(MAX + 1), limits)).toThrow(`deeper than ${MAX} levels`)
  })

  it("maps to and from JSON at it: schema-based, self-describing (2050 JSON levels) and import", async () => {
    const json = h.toJson(Tree, tree(MAX / 2), limits)
    expect(same(h.fromJson(Tree, json, limits), tree(MAX / 2))).toBe(true)
    expect(same(h.fromJsonValue(Tree, h.toJsonValue(Tree, tree(MAX / 2), limits), limits), tree(MAX / 2))).toBe(true)
    expect(same(await collect(h.decodeJsonLines(Tree, [`${json}\n`], limits)), [tree(MAX / 2)])).toBe(true)
    expect(await collect(h.encodeJsonLines(Tree, [tree(MAX / 2)], limits))).toEqual([`${json}\n`])

    const value = parse(tagged(MAX), limits)
    const self = toHausJson(value, limits)
    expect(self.startsWith('{"_haus":1,"_value":' + '{"_tag":"T","_args":[{"_rec":{"a":'.repeat(2))).toBe(true)
    expect(canonical(fromHausJson(self, limits))).toBe(canonical(value))
    expect(canonical(fromHausJsonValue(toHausJsonValue(value, limits), limits))).toBe(canonical(value))
    const lines = await collect(toHausJsonLines([value], limits))
    expect((await collect(fromHausJsonLines(lines, { limits }))).map(canonical)).toEqual([canonical(value)])
    // An array at every level: one JSON level each, and the envelope.
    const arrays = `{"_haus":1,"_value":${nested(MAX)}}`
    expect(canonical(fromHausJson(arrays, limits))).toBe(nested(MAX))
    expect(() => fromHausJson(`{"_haus":1,"_value":${nested(hausJsonDepth(MAX))}}`, limits)).toThrow(`nesting deeper than ${hausJsonDepth(MAX)} levels`)

    expect(canonical(importJson(nested(MAX), limits))).toBe(nested(MAX))
    expect(canonical(importJsonValue(parseJson(nested(MAX), limits), limits))).toBe(nested(MAX))
    expect((await collect(importJsonLines([`${nested(MAX)}\n`], { limits }))).map(canonical)).toEqual([nested(MAX)])
    // Raw JSON counts its own levels: up to hausJsonDepth(MAX), as self-describing JSON needs.
    const deepest = nested(hausJsonDepth(MAX))
    expect(stringifyJson(parseJson(deepest, { maxDepth: hausJsonDepth(MAX) }))).toBe(deepest)
    expect(await collect(parseJsonLines([deepest], { limits: { maxDepth: hausJsonDepth(MAX) } }))).toHaveLength(1)
    expect(jsonDepth(MAX)).toBe(2049)
  })

  it("formatting, the canonical form and JSON writing don't recurse: values built in code of any depth", () => {
    const deep = Array.from({ length: 20_000 }).reduce<Value>((inner) => variant("T", [rec(new Map([["a", inner]]))]), arr([]))
    expect(stringify(deep, { style: "compact" })).toHaveLength(20_000 * "T { a:  }".length + 2)
    expect(canonical(deep)).toHaveLength(20_000 * "T{a:}".length + 2)
    // 2001 levels, one bracket per line but the innermost `[]`.
    expect(stringify(Array.from({ length: 2_000 }).reduce<Value>((inner) => arr([inner]), arr([]))).split("\n")).toHaveLength(4_001)
    const json = Array.from({ length: 20_000 }).reduce<Json>((inner) => [inner], [])
    expect(stringifyJson(json)).toBe(nested(20_001))
  })

  it("JSON that contains itself is an error, not an endless loop", () => {
    const cyclic: Json[] = []
    cyclic.push(cyclic)
    expect(() => stringifyJson(cyclic)).toThrow("JSON contains itself")
    const shared: Json = ["x"]
    expect(stringifyJson([shared, shared])).toBe('[["x"],["x"]]')
  })
})

describe("a maxDepth above MAX_SUPPORTED_DEPTH", () => {
  const over = { maxDepth: MAX + 1 }
  const message = "maxDepth 513 is above 512, the deepest nesting this binding supports (spec §7)"

  it("is a RangeError naming the maximum, wherever limits are given", async () => {
    const calls: (() => unknown)[] = [
      () => parseAll("[]", over),
      () => parse("[]", over),
      () => parseWithLocations("[]", over),
      () => parseDocument("[]", over),
      () => new StreamReader({ limits: over }),
      () => collect(parseStream(["[]"], { limits: over })),
      () => h.decode(Nest, arr([]), over),
      () => h.parse(Nest, "[]", over),
      () => h.encode(Nest, [], over),
      () => h.stringify(Nest, [], over),
      () => h.formatAll(Nest, [], over),
      () => collect(h.decodeStream(Nest, ["[],"], over)),
      () => collect(h.encodeStream(Nest, [[]], over)),
      () => h.toJson(Nest, [], over),
      () => h.toJsonValue(Nest, [], over),
      () => h.fromJson(Nest, "[]", over),
      () => h.fromJsonValue(Nest, [], over),
      () => collect(h.decodeJsonLines(Nest, ["[]\n"], over)),
      () => collect(h.encodeJsonLines(Nest, [[]], over)),
      () => importJson("[]", over),
      () => importJsonValue([], over),
      () => collect(importJsonLines(["[]\n"], { limits: over })),
      () => toHausJson(arr([]), over),
      () => toHausJsonValue(arr([]), over),
      () => fromHausJson(`{"_haus":1,"_value":[]}`, over),
      () => fromHausJsonValue(jsonObject([["_haus", new JsonNumber("1")], ["_value", []]]), over),
      () => collect(toHausJsonLines([arr([])], over)),
      () => collect(fromHausJsonLines([`{"_haus":1,"_value":[]}\n`], { limits: over })),
    ]
    for (const call of calls) {
      const e = await errorOf(call)
      expect(e).toBeInstanceOf(RangeError)
      expect(e.message).toBe(message)
    }
  })

  it("raw JSON is limited to hausJsonDepth(MAX_SUPPORTED_DEPTH) JSON levels", async () => {
    const jsonOver = { maxDepth: hausJsonDepth(MAX) + 1 }
    const jsonMessage = "maxDepth 2051 is above 2050, the deepest JSON nesting this binding supports (spec §7)"
    for (const call of [() => parseJson("[]", jsonOver), () => collect(parseJsonLines(["[]"], { limits: jsonOver }))]) {
      const e = await errorOf(call)
      expect(e).toBeInstanceOf(RangeError)
      expect(e.message).toBe(jsonMessage)
    }
  })

  it("so is a maxDepth that isn't a whole number", () => {
    for (const maxDepth of [-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(() => parseAll("[]", { maxDepth })).toThrow(RangeError)
    }
    expect(() => parseAll("[]", { maxDepth: Number.NaN })).toThrow("maxDepth must be a whole number from 0 to 512, not NaN")
  })
})

describe("the string limit counts record keys and tags too (spec §7)", () => {
  const four = { maxStringLength: 4 }
  const syntaxError = (f: () => unknown) => {
    try {
      f()
    } catch (e) {
      return e as HausSyntaxError
    }
    throw new Error("expected an error")
  }

  it("in text: a key or tag of exactly the limit is accepted, one more is an error at its start", () => {
    expect(parse("{ abcd: Abcd, a: Abcd(1), b: Abcd { c: 1 } }", four).kind).toBe("record")
    const key = syntaxError(() => parse("{ a: 1,\n  abcde: 1 }", four))
    expect([key.reason, key.line, key.column]).toEqual(["key longer than 4 characters", 2, 3])
    for (const [text, column] of [["Abcde", 1], ["[1, Abcde(1)]", 5], ["{ a: Abcde { b: 1 } }", 6]] as const) {
      const tag = syntaxError(() => parse(text, four))
      expect([tag.reason, tag.column]).toEqual(["tag longer than 4 characters", column])
    }
    // A quoted key is a string: the string error, at its quote.
    const quoted = syntaxError(() => parse('{ "abcde": 1 }', four))
    expect([quoted.reason, quoted.column]).toEqual(["string longer than 4 characters", 3])
  })

  it("in streams, at the key's or tag's place in the stream", async () => {
    expect(await collect(parseStream(["{ abcd: Abcd },\n"], { limits: four }))).toHaveLength(1)
    const key = (await errorOf(() => collect(parseStream(["1,\n{ ab", "cde: 1 },"], { limits: four })))) as HausSyntaxError
    expect([key.reason, key.line, key.column]).toEqual(["key longer than 4 characters", 2, 3])
    const tag = (await errorOf(() => new StreamReader({ limits: four }).push("1,\n2,\n  Abcde,"))) as HausSyntaxError
    expect([tag.reason, tag.line, tag.column]).toEqual(["tag longer than 4 characters", 3, 3])
  })

  it("in values built in code, encoded raw (Any) or as self-describing JSON", () => {
    const keyed = (k: string) => rec(new Map([[k, arr([])]]))
    expect(h.encode(h.Any, variant("Abcd", [keyed("abcd")]), four).kind).toBe("variant")
    expect(toHausJson(variant("Abcd", [keyed("abcd")]), four)).toBe('{"_haus":1,"_value":{"_tag":"Abcd","_args":[{"_rec":{"abcd":[]}}]}}')
    for (const write of [(v: Value) => h.encode(h.Any, v, four), (v: Value) => toHausJsonValue(v, four)]) {
      expect(() => write(keyed("abcde"))).toThrow("key longer than 4 characters")
      expect(() => write(arr([variant("Abcde")]))).toThrow("tag longer than 4 characters")
      expect(() => write(variant("Abcde", [keyed("a")]))).toThrow("tag longer than 4 characters")
    }
  })

  it("in JSON: member names and tags read from JSON values are keys and tags; in JSON text, they are strings first", () => {
    expect(() => importJsonValue({ abcde: [] } as Json, four)).toThrow("key longer than 4 characters")
    expect(canonical(importJsonValue({ abcd: [] } as Json, four))).toBe("{abcd:[]}")
    const envelope = (value: Json): Json => jsonObject([["_haus", new JsonNumber("1")], ["_value", value]])
    expect(() => fromHausJsonValue(envelope({ _rec: { abcde: [] } }), four)).toThrow("key longer than 4 characters")
    expect(() => fromHausJsonValue(envelope({ _tag: "Abcde" }), four)).toThrow("tag longer than 4 characters")
    expect(canonical(fromHausJsonValue(envelope({ _tag: "Abcd", _args: [{ _rec: { abcd: [] } }] }), four))).toBe("Abcd{abcd:[]}")
    const Open = h.OpenVariant({ Known: h.Unit })
    expect(() => h.fromJsonValue(Open, { _tag: "Abcde" } as Json, four)).toThrow("tag longer than 4 characters")
    expect(() => h.fromJsonValue(Open, { _tag: "Abcd", abcde: 1 } as unknown as Json, four)).toThrow("key longer than 4 characters")
    expect(h.fromJsonValue(Open, { _tag: "Abcd" } as Json, four)).toMatchObject({ tag: "Abcd" })
    // JSON text: the reader limits every JSON string, member names and tags included.
    expect(() => importJson('{"abcde": []}', four)).toThrow("JSON: string longer than 4 characters")
    expect(() => fromHausJson('{"_haus": 1, "_value": {"_tag": "Abcde"}}', four)).toThrow("JSON: string longer than 4 characters")
  })
})
