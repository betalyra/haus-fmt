import { describe, expect, it } from "vitest"
import {
  canonical, compileSchemaFile, equalsJson, fromBase64, fromJson, fromJsonLines, fromLosslessJson, fromLosslessJsonLines, HausDecodeError, HausEncodeError,
  HausSyntaxError, JsonNumber, jsonObject, parse, parseJson, parseJsonLines, stringifyJson, toBase64, toLosslessJson, toLosslessJsonLines, type Json,
} from "../src/index.js"
import * as h from "../src/schema.js"

const collect = async <T>(it: AsyncIterable<T>): Promise<T[]> => {
  const out: T[] = []
  for await (const x of it) out.push(x)
  return out
}

describe("reading JSON (I-JSON)", () => {
  it("keeps numbers exactly as written", () => {
    const j = parseJson(`{"a": 19.90, "b": 1E+05, "c": 123456789012345678901234567890, "d": -0}`) as Record<string, JsonNumber>
    expect([j.a!.text, j.b!.text, j.c!.text, j.d!.text]).toEqual(["19.90", "1E+05", "123456789012345678901234567890", "-0"])
  })

  it.each([
    ["duplicate member names", `{"a": 1, "a": 2}`],
    ["an unpaired high surrogate escape", `"\\ud83d"`],
    ["an unpaired low surrogate escape", `"\\ude00"`],
    ["a reversed pair", `"\\ude00\\ud83d"`],
    ["a trailing comma", `[1,]`],
    ["a trailing comma in an object", `{"a": 1,}`],
    ["NaN", `NaN`],
    ["a leading zero", `01`],
    ["a plus sign", `+1`],
    ["a bare fraction", `.5`],
    ["single quotes", `'a'`],
    ["a raw control character", `"a\u0001b"`],
    ["a raw line feed in a string", `"a\nb"`],
    ["an invalid escape", `"\\x41"`],
    ["two values", `1 2`],
    ["an empty text", ``],
    ["a comment", `1 // no`],
    ["an unterminated string", `"abc`],
  ])("rejects %s", (_, text) => {
    expect(() => parseJson(text)).toThrow(HausSyntaxError)
  })

  it("rejects a raw unpaired surrogate", () => {
    expect(() => parseJson(`"\ud83d"`)).toThrow(/unpaired surrogate/)
    expect(parseJson(`"😀"`)).toBe("\u{1F600}")
  })

  it("reports line and column", () => {
    const e = (() => {
      try {
        parseJson(`{\n  "a": 1,\n  "a": 2\n}`)
      } catch (e) {
        return e as HausSyntaxError
      }
      throw new Error("no error")
    })()
    expect([e.line, e.column]).toEqual([3, 3])
  })

  it("enforces the limits of spec §7", () => {
    expect(() => parseJson("1" + "0".repeat(999))).not.toThrow()
    expect(() => parseJson("1" + "0".repeat(1000))).toThrow(/longer than 1000/)
    expect(() => parseJson("1e6144")).not.toThrow()
    expect(() => parseJson("1e-6145")).toThrow(/exponent/)
    expect(() => parseJson("1e00006144")).not.toThrow()
    expect(() => parseJson("[".repeat(256) + "]".repeat(256))).not.toThrow()
    expect(() => parseJson("[".repeat(257) + "]".repeat(257))).toThrow(/nesting/)
    expect(() => parseJson(`"${"x".repeat(11)}"`, { maxStringLength: 10 })).toThrow(/longer than 10/)
    expect(() => parseJson(`"${"😀".repeat(10)}"`, { maxStringLength: 10 })).not.toThrow()
  })

  it("keeps __proto__ as data", () => {
    const j = parseJson(`{"__proto__": {"admin": true}}`) as Record<string, Json>
    expect(Object.keys(j)).toEqual(["__proto__"])
    expect((j as { admin?: unknown }).admin).toBeUndefined()
  })

  it("ignores a leading byte order mark", () => {
    expect(parseJson("﻿[1]")).toEqual([new JsonNumber("1")])
  })
})

describe("writing JSON", () => {
  it("writes compact JSON, numbers as their text", () => {
    expect(stringifyJson(jsonObject([["a", [new JsonNumber("1E+05"), "x\n\"", null, true]]]))).toBe(`{"a":[1E+05,"x\\n\\"",null,true]}`)
  })

  it("rejects what isn't I-JSON", () => {
    expect(() => stringifyJson("\ud800")).toThrow(HausEncodeError)
    expect(() => stringifyJson(new JsonNumber("0x1"))).toThrow(HausEncodeError)
  })

  it("JSON.stringify writes a JsonNumber exactly where JSON.rawJSON exists", () => {
    if (!("rawJSON" in JSON)) return
    expect(JSON.stringify({ n: new JsonNumber("19.90") })).toBe(`{"n":19.90}`)
  })
})

describe("lossless (spec §16.2)", () => {
  it.each([
    `{ a: [1, "x", None], "b-c": x"0b34ff", d: Circle { r: 1.5 }, e: Point(1, -0), f: 0xFF, g: 1E+05, h: [] }`,
    String.raw`"\u{0}\u{1B}\u{202E}😀"`,
    `Tag({ x: 1 })`,
  ])("round trips %s", (text) => {
    const v = parse(text)
    expect(canonical(fromLosslessJson(toLosslessJson(v)))).toBe(canonical(v))
  })

  it("normalizes numbers built in code and checks tags", () => {
    expect(toLosslessJson({ kind: "number", text: "1E+05" })).toBe(`{"num":"1e5"}`)
    expect(() => toLosslessJson({ kind: "variant", tag: "lower", args: [] })).toThrow(HausEncodeError)
    expect(() => toLosslessJson({ kind: "number", text: "1.2.3" })).toThrow(HausEncodeError)
  })

  it.each([
    `{"num": "1E5"}`, `{"num": "0xFF"}`, `{"num": "1_000"}`, `{"num": "+1"}`, `{"bytes": "0b 34"}`, `{"rec": []}`, `{"tag": "A", "args": {}}`,
    `{"tag": 1}`, `{"rec": {}, "tag": "A"}`, `{"tag": "Circle", "args": [1]}`,
  ])("rejects %s", (json) => {
    expect(() => fromLosslessJson(json)).toThrow(HausDecodeError)
  })

  it("holds values to the haus nesting limit, not JSON's", () => {
    // `Tag { … }` is one haus level but four JSON levels.
    const deep = (n: number): string => (n === 0 ? "1" : `A { x: ${deep(n - 1)} }`)
    const atLimit = parse(deep(256))
    expect(canonical(fromLosslessJson(toLosslessJson(atLimit)))).toBe(canonical(atLimit))
    // Arrays are one JSON level each: past 256, the haus limit is what rejects them.
    expect(() => fromLosslessJson("[".repeat(256) + "]".repeat(256))).not.toThrow()
    expect(() => fromLosslessJson("[".repeat(257) + "]".repeat(257))).toThrow(/nesting deeper than 256/)
  })

  it("JSON Lines", async () => {
    const values = [parse("1"), parse(`A { x: "y" }`)]
    const lines = await collect(toLosslessJsonLines(values))
    expect(lines).toEqual([`{"num":"1"}\n`, `{"tag":"A","args":[{"rec":{"x":"y"}}]}\n`])
    const back = await collect(fromLosslessJsonLines([lines.join("").slice(0, 7), lines.join("").slice(7)]))
    expect(back.map(canonical)).toEqual(values.map(canonical))
  })
})

describe("without a schema (spec §16.1)", () => {
  it("reads JSON as haus", () => {
    expect(canonical(fromJson(`{"a": [true, null, 1.50], "b": {"c": "d"}}`))).toBe(`{a:[True,None,1.50],b:{c:"d"}}`)
  })

  it("JSON Lines, in chunks of any size", async () => {
    const text = `{"a": 1}\r\n[2, "😀"]\n3\n`
    const bytes = new TextEncoder().encode(text)
    for (const size of [1, 2, 5, bytes.length]) {
      const chunks: Uint8Array[] = []
      for (let i = 0; i < bytes.length; i += size) chunks.push(bytes.subarray(i, i + size))
      expect((await collect(fromJsonLines(chunks))).map(canonical)).toEqual([`{a:1}`, `[2,"😀"]`, `3`])
    }
  })

  it("JSON Lines: errors name the line, a blank line is an error, strict mode wants the last line feed", async () => {
    await expect(collect(parseJsonLines(["1\n{\n"]))).rejects.toMatchObject({ line: 2 })
    await expect(collect(parseJsonLines(["1\n\n2\n"]))).rejects.toThrow(HausSyntaxError)
    expect(await collect(parseJsonLines(["1\n2"]))).toEqual([new JsonNumber("1"), new JsonNumber("2")])
    await expect(collect(parseJsonLines(["1\n2"], { requireTerminator: true }))).rejects.toThrow(/truncated/)
    await expect(collect(parseJsonLines(["[1, 2]\n"], { maxLineLength: 3 }))).rejects.toThrow(/longer than 3/)
    // A byte order mark is ignored at the start of the stream only, as in haus streams.
    expect(await collect(parseJsonLines(["\uFEFF1\n2\n"]))).toEqual([new JsonNumber("1"), new JsonNumber("2")])
    expect(await collect(parseJsonLines([new Uint8Array([0xef, 0xbb, 0xbf, 0x31, 0x0a])]))).toEqual([new JsonNumber("1")])
    await expect(collect(parseJsonLines(["1\n\uFEFF2\n"]))).rejects.toMatchObject({ line: 2 })
    await expect(collect(parseJsonLines(["\uFEFF\uFEFF1\n"]))).rejects.toThrow(HausSyntaxError)
  })
})

describe("base64", () => {
  it("round trips with padding", () => {
    for (let n = 0; n < 8; n++) {
      const data = new Uint8Array(n).map((_, i) => (i * 37 + 250) & 255)
      expect(fromBase64(toBase64(data))).toEqual(data)
    }
    expect(toBase64(new Uint8Array([0x0b, 0x34]))).toBe("CzQ=")
  })

  it.each(["CzQ", "CzR=", "Cz==", "C===", "Cz Q=", "CzQ=CzQ=", "Cz-_"])("rejects %s", (s) => {
    expect(fromBase64(s)).toBeUndefined()
  })
})

describe("plain (spec §16.3), hand-written schemas", () => {
  const Shape = h.OpenVariant({
    Circle: h.Record({ r: h.Float64 }),
    Point: h.Tuple(h.Float64, h.Float64),
    Label: h.String,
    Empty: h.Unit,
  })
  const Order = h.Record({
    id: h.Int,
    count: h.UInt8,
    total: h.Decimal,
    when: h.Date,
    raw: h.Bytes,
    shape: Shape,
    level: h.Enum("Debug", "Info"),
    note: h.Optional(h.Maybe(h.String)),
    nested: h.Maybe(h.Maybe(h.Int32)),
    tags: h.Map(h.Array(h.Bool)),
    key: h.Secret(h.String),
  })
  const order = {
    id: 9007199254740993n,
    count: 7,
    total: "19.90",
    when: "2026-11-13",
    raw: new Uint8Array([0x0b, 0x34]),
    shape: { _tag: "Point" as const, values: [1, 2.5] as const },
    level: "Info" as const,
    note: h.Maybe.none,
    nested: h.Maybe.some(h.Maybe.none),
    tags: new Map([["a", [true, false]]]),
    key: h.Secret.make("sk-1"),
  }
  const json = `{"id":"9007199254740993","count":7,"total":"19.90","when":"2026-11-13","raw":"CzQ=","shape":{"_tag":"Point","values":[1,2.5]},` +
    `"level":"Info","note":null,"nested":{"_tag":"Some","value":null},"tags":{"a":[true,false]},"key":"sk-1"}`

  it("writes and reads", () => {
    expect(h.toJson(Order, order)).toBe(json)
    const back = h.fromJson(Order, json)
    expect(h.stringify(Order, back)).toBe(h.stringify(Order, order))
    expect(back.key.expose()).toBe("sk-1")
  })

  it("a missing optional field is a missing member, never null", () => {
    const { note: _, ...rest } = order
    expect(h.toJson(Order, rest)).not.toContain("note")
    expect("note" in h.fromJson(Order, h.toJson(Order, rest))).toBe(false)
  })

  it("variant forms", () => {
    expect(h.toJson(Shape, { _tag: "Circle", r: 1 })).toBe(`{"_tag":"Circle","r":1}`)
    expect(h.toJson(Shape, { _tag: "Label", value: "a" })).toBe(`{"_tag":"Label","value":"a"}`)
    expect(h.toJson(Shape, { _tag: "Empty" })).toBe(`{"_tag":"Empty"}`)
    const unknown = h.parse(Shape, `Hexagon { side: 1 }`)
    expect(h.toJson(Shape, unknown)).toBe(`{"_tag":"Hexagon","args":[{"rec":{"side":{"num":"1"}}}]}`)
    expect(h.fromJson(Shape, `{"_tag":"Hexagon","args":[{"rec":{"side":{"num":"1"}}}]}`)).toEqual(unknown)
  })

  it.each([
    [`{"_tag":"Empty","x":1}`, /unexpected member/],
    [`{"_tag":"Label","value":"a","x":1}`, /unexpected member/],
    [`{"_tag":"Label"}`, /needs a member "value"/],
    [`{"_tag":"Hexagon","args":[]}`, /non-empty/],
    [`{"_tag":"hexagon"}`, /not a tag name/],
    [`{"_tag":1}`, /_tag/],
  ])("rejects %s", (text, message) => {
    expect(() => h.fromJson(Shape, text)).toThrow(message)
  })

  it("an unknown tag with other members than args: a newer writer's record payload, read without a schema", () => {
    expect(canonical(h.encode(Shape, h.fromJson(Shape, `{"_tag":"Hexagon","side":1,"args":[true]}`)))).toBe(`Hexagon{args:[True],side:1}`)
    expect(canonical(h.encode(Shape, h.fromJson(Shape, `{"_tag":"Hexagon"}`)))).toBe(`Hexagon`)
  })

  it("`< >` writes every tag as an unknown value", () => {
    expect(h.toJson(h.AnyTag, "EUR")).toBe(`{"_tag":"EUR"}`)
    expect(h.fromJson(h.AnyTag, `{"_tag":"EUR"}`)).toBe("EUR")
  })

  it("a record payload with a field named _tag has no plain form", () => {
    const Bad = h.Variant({ A: h.Record({ _tag: h.String }) })
    expect(() => h.toJson(Bad, h.decode(Bad, parse(`A { _tag: "x" }`)))).toThrow(HausEncodeError)
    expect(() => h.fromJson(Bad, `{"_tag":"A"}`)).toThrow(/_tag/)
  })

  it("errors name the JSON path", () => {
    expect(() => h.fromJson(Order, json.replace(`"values":[1,2.5]`, `"values":[1,"x"]`))).toThrow(/\$\.shape\.values\[1\]/)
  })

  it("errors inside a secret never show the value or a path into it", () => {
    const Config = h.Record({ keys: h.Secret(h.Map(h.Int32)) })
    for (const run of [
      () => h.fromJson(Config, `{"keys": {"sk-live-123": "x"}}`),
      () => h.fromJson(Config, `{"keys": {"sk-live-123": 1.5}}`),
      () => h.toJson(Config, { keys: h.Secret.make(new Map([["sk-live-123", 1.5]])) }),
    ]) {
      expect(run).toThrow(/at \$\.keys$/)
      expect(run).not.toThrow(/sk-live/)
    }
  })

  it("Any is its lossless form; an Any can't be confused with JSON null", () => {
    expect(h.toJson(h.Maybe(h.Any), h.Maybe.some(parse("None")))).toBe(`{"tag":"None"}`)
    expect(h.toJson(h.Maybe(h.Any), h.Maybe.none)).toBe("null")
  })

  it("Maybe is tagged when its value's JSON can be null, through named types and Secret", () => {
    const Inner = h.Secret(h.Maybe(h.Int32))
    const Outer = h.Maybe(Inner)
    expect(h.toJson(Outer, h.Maybe.none)).toBe(`{"_tag":"None"}`)
    expect(h.toJson(Outer, h.Maybe.some(h.Secret.make(h.Maybe.none)))).toBe(`{"_tag":"Some","value":null}`)
  })

  it("a recursive type", () => {
    interface Tree { readonly name: string; readonly children: readonly Tree[] }
    const Tree: h.Schema<Tree> = h.Recursive<Tree>("Tree", (self) => h.Record({ name: h.String, children: h.Array(self) }))
    const tree = { name: "a", children: [{ name: "b", children: [] }] }
    expect(h.fromJson(Tree, h.toJson(Tree, tree))).toEqual(tree)
  })

  it("a Maybe that contains only itself is tagged (spec §16.3 has no consistent answer for it)", () => {
    const { schemas } = compileSchemaFile(`type L = Maybe L\ntype A = Maybe B\ntype B = Maybe A`)
    const two = parse("Some(Some(None))")
    for (const s of [schemas.L!, schemas.A!, schemas.B!]) {
      const json = h.toJson(s, h.decode(s, two))
      expect(json).toBe(`{"_tag":"Some","value":{"_tag":"Some","value":{"_tag":"None"}}}`)
      expect(canonical(h.encode(s, h.fromJson(s, json)))).toBe(canonical(two))
    }
  })

  it("a schema without a plain form says so", () => {
    const Custom = h.withStandard<string, Omit<h.Schema<string>, "~standard">>({
      expected: "Custom",
      decode: (v, at) => (v.kind === "string" ? v.value : at.fail("expected a string")),
      encode: (s) => ({ kind: "string", value: s }),
    })
    expect(() => h.toJson(h.Record({ c: Custom }), { c: "x" })).toThrow(/Custom has no plain JSON form at \$\.c/)
    const WithJson = h.withStandard<string, Omit<h.Schema<string>, "~standard">>({ ...Custom, json: { kind: "string" } })
    expect(h.toJson(WithJson, "x")).toBe(`"x"`)
  })

  it("JSON Lines", async () => {
    const Event = h.Variant({ A: h.Record({ n: h.Int }), B: h.Unit })
    const lines = await collect(h.encodeJsonLines(Event, [{ _tag: "A" as const, n: 1n }, { _tag: "B" as const }]))
    expect(lines).toEqual([`{"_tag":"A","n":"1"}\n`, `{"_tag":"B"}\n`])
    expect(await collect(h.decodeJsonLines(Event, [lines.join("")]))).toEqual([{ _tag: "A", n: 1n }, { _tag: "B" }])
    await expect(collect(h.decodeJsonLines(Event, [`{"_tag":"B"}\n{"_tag":"C"}\n`]))).rejects.toThrow(/at \$\[1\]/)
  })

  it("compares as data", () => {
    expect(equalsJson(parseJson(`{"a": 1, "b": [2]}`), parseJson(`{"b":[2],"a":1}`))).toBe(true)
    expect(equalsJson(parseJson(`1.0`), parseJson(`1`))).toBe(false)
  })
})
