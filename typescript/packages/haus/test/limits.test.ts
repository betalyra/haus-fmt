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
    expect(stringify(value, { style: "compact", limits })).toBe(tagged(MAX))
    expect(canonical(parse(stringify(value, { limits }), limits))).toBe(canonical(value))
    const { values, comments } = parseDocument(`// deep\n${tagged(MAX)}`, limits)
    expect(format(values, { source: `// deep\n${tagged(MAX)}`, comments, limits })).toContain("// deep")
    // A writer checks the depth with its own limits (spec §11): the default 256 is less.
    expect(() => stringify(value)).toThrow(expect.objectContaining({ code: "nesting-too-deep" }))
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
    expect((await collect(fromHausJsonLines(lines, { limits }))).map((v) => canonical(v))).toEqual([canonical(value)])
    // An array at every level: one JSON level each, and the envelope.
    const arrays = `{"_haus":1,"_value":${nested(MAX)}}`
    expect(canonical(fromHausJson(arrays, limits))).toBe(nested(MAX))
    expect(() => fromHausJson(`{"_haus":1,"_value":${nested(hausJsonDepth(MAX))}}`, limits)).toThrow(`nesting deeper than ${hausJsonDepth(MAX)} levels`)

    expect(canonical(importJson(nested(MAX), limits))).toBe(nested(MAX))
    expect(canonical(importJsonValue(parseJson(nested(MAX), limits), limits))).toBe(nested(MAX))
    expect((await collect(importJsonLines([`${nested(MAX)}\n`], { limits }))).map((v) => canonical(v))).toEqual([nested(MAX)])
    // Raw JSON counts its own levels: up to hausJsonDepth(MAX), as self-describing JSON needs.
    const deepest = nested(hausJsonDepth(MAX))
    expect(stringifyJson(parseJson(deepest, { maxDepth: hausJsonDepth(MAX) }))).toBe(deepest)
    expect(await collect(parseJsonLines([deepest], { limits: { maxDepth: hausJsonDepth(MAX) } }))).toHaveLength(1)
    expect(jsonDepth(MAX)).toBe(2049)
  })

  it("formatting, the canonical form and JSON writing don't recurse: values built in code of any depth", () => {
    const deep = Array.from({ length: 20_000 }).reduce<Value>((inner) => variant("T", [rec(new Map([["a", inner]]))]), arr([]))
    // Writers take any depth they are given (they don't use the call stack); the canonical form has no depth limit.
    expect(stringify(deep, { style: "compact", limits: { maxDepth: 20_001 } })).toHaveLength(20_000 * "T { a:  }".length + 2)
    expect(() => stringify(deep, { style: "compact", limits: { maxDepth: 20_000 } })).toThrow(expect.objectContaining({ code: "nesting-too-deep" }))
    expect(canonical(deep)).toHaveLength(20_000 * "T{a:}".length + 2)
    // 2001 levels, one bracket per line but the innermost `[]`.
    expect(stringify(Array.from({ length: 2_000 }).reduce<Value>((inner) => arr([inner]), arr([])), { limits: { maxDepth: 2_001 } }).split("\n")).toHaveLength(4_001)
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
    // JSON text: the same, counted on the value (spec §16, Limits), not as JSON strings.
    expect(() => importJson('{"abcde": []}', four)).toThrow("key longer than 4 characters")
    expect(() => fromHausJson('{"_haus": 1, "_value": {"_tag": "Abcde"}}', four)).toThrow("tag longer than 4 characters")
  })
})

describe("JSON lengths count on the resulting haus value, not the JSON text (spec §16, Limits)", () => {
  const four = { maxStringLength: 4 }
  const codeOf = (f: () => unknown): string | undefined => {
    try {
      f()
    } catch (e) {
      return (e as { code?: string }).code
    }
    return undefined
  }
  /** `n` times é, each written as the escape é (six JSON characters, one haus character). */
  const escaped = (n: number) => `"${"\\u00e9".repeat(n)}"`
  const lines = (text: string) => [`${text}\n`]

  it("a string's characters after its escapes are read: exactly the limit is accepted, one more is an error", async () => {
    const readers: [string, (json: string) => unknown][] = [
      ["import", (j) => importJson(j, four)],
      ["self-describing", (j) => fromHausJson(`{"_haus": 1, "_value": ${j}}`, four)],
      ["schema-based", (j) => h.fromJson(h.String, j, four)],
    ]
    for (const [name, read] of readers) {
      expect([name, codeOf(() => read(escaped(4)))]).toEqual([name, undefined])
      expect([name, codeOf(() => read(escaped(5)))]).toEqual([name, "string-too-long"])
    }
    expect(importJson(escaped(4), four)).toEqual({ kind: "string", value: "éééé" })
    expect(await collect(importJsonLines(lines(escaped(4)), { limits: four }))).toHaveLength(1)
    expect((await errorOf(() => collect(importJsonLines(lines(escaped(5)), { limits: four })))) as unknown as { code: string }).toMatchObject({ code: "string-too-long" })
    expect(await collect(h.decodeJsonLines(h.String, lines(escaped(4)), four))).toEqual(["éééé"])
    expect((await errorOf(() => collect(h.decodeJsonLines(h.String, lines(escaped(5)), four)))) as unknown as { code: string }).toMatchObject({ code: "string-too-long" })
  })

  it("keys and tags count as haus keys and tags, escapes read", () => {
    expect(canonical(importJson(`{"\\u0061bcd": []}`, four))).toBe("{abcd:[]}")
    expect(codeOf(() => importJson(`{"\\u0061bcde": []}`, four))).toBe("key-too-long")
    expect(canonical(fromHausJson(`{"_haus": 1, "_value": {"_tag": "\\u0041bcd"}}`, four))).toBe("Abcd")
    expect(codeOf(() => fromHausJson(`{"_haus": 1, "_value": {"_tag": "\\u0041bcde"}}`, four))).toBe("tag-too-long")
  })

  it("bytes count two characters per byte, in base64 (schema-based) and in hex (_bytes)", () => {
    // 4 characters: 2 bytes. Base64 "AAE=" is 4 JSON characters either way; 3 bytes, "AAEC", are 6.
    expect(h.fromJson(h.Bytes, '"AAE="', four)).toEqual(new Uint8Array([0, 1]))
    expect(codeOf(() => h.fromJson(h.Bytes, '"AAEC"', four))).toBe("string-too-long")
    // With 8: 4 bytes are accepted, 5 (base64 "AAECAwQ=", only 8 JSON characters) are not.
    const eight = { maxStringLength: 8 }
    expect(h.fromJson(h.Bytes, '"AAECAw=="', eight)).toEqual(new Uint8Array([0, 1, 2, 3]))
    expect(codeOf(() => h.fromJson(h.Bytes, '"AAECAwQ="', eight))).toBe("string-too-long")
    const hex = (digits: string) => `{"_haus": 1, "_value": {"_bytes": "${digits}"}}`
    expect(fromHausJson(hex("00010203"), eight)).toEqual({ kind: "bytes", bytes: new Uint8Array([0, 1, 2, 3]) })
    expect(codeOf(() => fromHausJson(hex("0001020304"), eight))).toBe("string-too-long")
  })

  it("a JSON string that is a number is limited as a number, not as a string", () => {
    const long = "123456789"
    expect(h.fromJson(h.Decimal, `"${long}"`, four)).toBe(long)
    expect(canonical(fromHausJson(`{"_haus": 1, "_value": {"_num": "${long}"}}`, four))).toBe(long)
    expect(codeOf(() => h.fromJson(h.Decimal, `"${long}"`, { maxNumberLength: 8 }))).toBe("number-too-long")
    expect(h.fromJson(h.Int64, `"${long}"`, four)).toBe(123456789n)
  })

  it("structural member names are no haus strings: a tiny string limit doesn't reject them", () => {
    const one = { maxStringLength: 1 }
    // "_haus", "_value", "_bytes", "_num", "_rec", "_tag", "_args" are longer than 1.
    expect(canonical(fromHausJson(`{"_haus": 1, "_value": [{"_bytes": ""}, {"_num": "12"}, {"_rec": {"a": "b"}}, {"_tag": "A", "_args": ["c"]}]}`, one))).toBe('[x"",12,{a:"b"},A("c")]')
    const Shape = h.Variant({ C: h.Record({ r: h.Int32 }), P: h.Tuple(h.Int32, h.Int32) })
    expect(h.fromJson(h.Array(Shape), `[{"_tag": "C", "r": 1}, {"_tag": "P", "values": [1, 2]}]`, one)).toEqual([{ _tag: "C", r: 1 }, { _tag: "P", values: [1, 2] }])
  })

  it("a map's member names are keys", () => {
    expect(h.fromJson(h.Map(h.Int32), `{"\\u0061bcd": 1}`, four)).toEqual(new Map([["abcd", 1]]))
    expect(codeOf(() => h.fromJson(h.Map(h.Int32), `{"abcde": 1}`, four))).toBe("key-too-long")
  })

  it("schema-based: a variant's \"_tag\" and an enum's string are tags, a record's listed member names keys; ignored members don't count", () => {
    const six = { maxStringLength: 6 }
    const Open = h.OpenVariant({ A: h.Unit })
    expect(codeOf(() => h.fromJson(Open, `{"_tag": "Abcdefg"}`, six))).toBe("tag-too-long")
    expect(codeOf(() => h.fromJson(Open, `{"_tag": "Abcdef"}`, six))).toBe(undefined)
    const Known = h.OpenVariant({ Abcdefg: h.Unit, Abcdef: h.Unit })
    expect(codeOf(() => h.fromJson(Known, `{"_tag": "Abcdefg"}`, six))).toBe("tag-too-long")
    expect(h.fromJson(Known, `{"_tag": "Abcdef"}`, six)).toEqual({ _tag: "Abcdef" })
    const Enum = h.Enum("A", "Abcdefg", "Abcdef")
    expect(codeOf(() => h.fromJson(Enum, `"Abcdefg"`, six))).toBe("tag-too-long")
    expect(h.fromJson(Enum, `"Abcdef"`, six)).toBe("Abcdef")
    expect(codeOf(() => h.fromJson(h.Record({ abcdefg: h.Int32 }), `{"abcdefg": 1}`, six))).toBe("key-too-long")
    const R = h.Record({ a: h.String })
    expect(h.fromJson(R, `{"a": "x", "abcdefg": 1}`, six)).toEqual({ a: "x" })
    expect(h.fromJson(R, `{"a": "x", "b": "abcdefg"}`, six)).toEqual({ a: "x" })
  })

  it("raw JSON (parseJson) still limits its strings as JSON strings", () => {
    expect(codeOf(() => parseJson(escaped(5), four))).toBe("string-too-long")
    expect(parseJson(escaped(4), four)).toBe("éééé")
  })
})

describe("an empty record, array or payload is a level, built in code as parsed (spec §7)", () => {
  const two = { maxDepth: 2 }
  const empty = new Map<string, Value>()
  // Each needs three levels: an empty container innermost.
  const built: [string, Value][] = [
    ["[[[]]]", arr([arr([arr([])])])],
    ["{ a: { b: {} } }", rec(new Map([["a", rec(new Map([["b", rec(empty)]]))]]))],
    ["A(B(C {}))", variant("A", [variant("B", [variant("C", [rec(empty)])])])],
    ["A([{}])", variant("A", [arr([rec(empty)])])],
  ]

  it.each(built)("%s: parsing, checks and writers agree", (text, value) => {
    expect(() => parse(text, two)).toThrow(expect.objectContaining({ code: "nesting-too-deep" }))
    expect(() => parse(text, { maxDepth: 3 })).not.toThrow()
    expect(canonical(parse(text))).toBe(canonical(value))
    // Decoding a value built in code, writing it raw (Any) and as self-describing JSON.
    for (const f of [() => h.decode(h.Any, value, two), () => h.encode(h.Any, value, two), () => toHausJson(value, two)]) {
      expect(f).toThrow(expect.objectContaining({ code: "nesting-too-deep" }))
    }
    expect(() => h.decode(h.Any, value, { maxDepth: 3 })).not.toThrow()
    expect(() => h.encode(h.Any, value, { maxDepth: 3 })).not.toThrow()
    expect(() => toHausJson(value, { maxDepth: 3 })).not.toThrow()
  })

  it("schemas encode an empty array, record or record payload as a level", () => {
    const Arrays = h.Array(h.Array(h.Array(h.Int32)))
    expect(() => h.encode(Arrays, [[[]]], two)).toThrow(expect.objectContaining({ code: "nesting-too-deep" }))
    expect(() => h.encode(Arrays, [[]], two)).not.toThrow()
    const Records = h.Record({ a: h.Record({ b: h.Record({}) }) })
    expect(() => h.encode(Records, { a: { b: {} } }, two)).toThrow(expect.objectContaining({ code: "nesting-too-deep" }))
    expect(() => h.encode(Records, { a: { b: {} } }, { maxDepth: 3 })).not.toThrow()
    const Payloads = h.Array(h.Array(h.Variant({ C: h.Record({}) })))
    expect(() => h.encode(Payloads, [[{ _tag: "C" as const }]], two)).toThrow(expect.objectContaining({ code: "nesting-too-deep" }))
    expect(() => h.encode(Payloads, [[{ _tag: "C" as const }]], { maxDepth: 3 })).not.toThrow()
  })
})
