import { describe, expect, it } from "vitest"
import {
  canonical, compileSchemaFile, equalsJson, fromBase64, fromHausJson, fromHausJsonLines, fromHausJsonValue, HausDecodeError, HausEncodeError, HausSyntaxError,
  importJson, importJsonLines, JsonNumber, jsonObject, parse, parseJson, parseJsonLines, stringifyJson, toBase64, toHausJson, toHausJsonLines, type Json,
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

describe("self-describing (spec §16.2)", () => {
  it.each([
    `{ a: [1, "x", None], "b-c": x"0b34ff", d: Circle { r: 1.5 }, e: Point(1, -0), f: 0xFF, g: 1E+05, h: [] }`,
    String.raw`"\u{0}\u{1B}\u{202E}😀"`,
    `Tag({ x: 1 })`,
  ])("round trips %s", (text) => {
    const v = parse(text)
    expect(canonical(fromHausJson(toHausJson(v)))).toBe(canonical(v))
  })

  it("normalizes numbers built in code and checks tags", () => {
    expect(toHausJson({ kind: "number", text: "1E+05" })).toBe(`{"_haus":1,"_value":{"_num":"1e5"}}`)
    expect(() => toHausJson({ kind: "variant", tag: "lower", args: [] })).toThrow(HausEncodeError)
    expect(() => toHausJson({ kind: "number", text: "1.2.3" })).toThrow(HausEncodeError)
  })

  it.each([
    `{"_num": "1E5"}`, `{"_num": "0xFF"}`, `{"_num": "1_000"}`, `{"_num": "+1"}`, `{"_bytes": "0b 34"}`, `{"_rec": []}`, `{"_tag": "A", "_args": {}}`,
    `{"_tag": 1}`, `{"_rec": {}, "_tag": "A"}`, `{"_tag": "Circle", "_args": [1]}`, `{"num": "1"}`, `{"tag": "A", "args": ["x"]}`,
  ])("rejects %s", (json) => {
    expect(() => fromHausJson(`{"_haus": 1, "_value": ${json}}`)).toThrow(HausDecodeError)
  })

  it("the envelope: required, exactly its two members, version 1, errors at $", () => {
    expect(canonical(fromHausJson(`{"_value": [], "_haus": 1}`))).toBe("[]")
    expect(() => fromHausJson(`[]`)).toThrow(/expected the envelope .* at \$$/)
    expect(() => fromHausJson(`{"_haus": 1, "_value": [], "_x": 1}`)).toThrow(/expected the envelope/)
    expect(() => fromHausJson(`{"_haus": 1.0, "_value": []}`)).toThrow(/version the number 1\.0/)
    // Places are in the JSON, from its root, the envelope included (spec §16.3 "Places").
    expect(() => fromHausJson(`{"_haus": 1, "_value": {"_rec": {"a": [{"_num": "01"}]}}}`)).toThrow(/at \$\._value\._rec\.a\[0\]\._num$/)
    expect(() => fromHausJsonValue(jsonObject([["_haus", new JsonNumber("2")], ["_value", "x"]]))).toThrow(/version/)
  })

  it("writes DEL, C1 and bidi controls escaped, and rejects them raw", () => {
    expect(toHausJson(parse(String.raw`"\u{7F}\u{85}\u{202E}\u{2069}"`))).toBe(`{"_haus":1,"_value":"\\u007f\\u0085\\u202e\\u2069"}`)
    expect(stringifyJson({ "a\u{2066}": "\u{9F}" })).toBe(`{"a\\u2066":"\\u009f"}`)
    expect(() => fromHausJson(`{"_haus": 1, "_value": "\u{7F}"}`)).toThrow(expect.objectContaining({ code: "control-character", line: 1, column: 25 }))
    expect(() => fromHausJson(`{"_haus": 1, "_value": "\u{202A}"}`)).toThrow(expect.objectContaining({ code: "bidi-control" }))
    // Escaped, they are fine; the other readers take them raw.
    expect(canonical(fromHausJson(`{"_haus": 1, "_value": "\\u007f"}`))).toBe(canonical(parse(String.raw`"\u{7F}"`)))
    expect(canonical(importJson(`"\u{7F}\u{202E}"`))).toBe(canonical(parse(String.raw`"\u{7F}\u{202E}"`)))
    expect(h.fromJson(h.Any, `"\u{85}"`)).toEqual(parse(String.raw`"\u{85}"`))
  })

  it("writes U+2028 and U+2029 escaped, and reads them raw (spec §16)", () => {
    const v = parse(String.raw`{ "k\u{2028}": "a\u{2029}b" }`)
    expect(toHausJson(v)).toBe(`{"_haus":1,"_value":{"_rec":{"k\\u2028":"a\\u2029b"}}}`)
    expect(stringifyJson(["\u{2028}", "\u{2029}"])).toBe(`["\\u2028","\\u2029"]`)
    expect(h.toJson(h.String, "\u{2028}")).toBe(`"\\u2028"`)
    // Every reader accepts them raw, the self-describing one too.
    expect(canonical(fromHausJson(`{"_haus": 1, "_value": {"_rec": {"k\u{2028}": "a\u{2029}b"}}}`))).toBe(canonical(v))
    expect(canonical(importJson(`"\u{2028}"`))).toBe(canonical(parse(String.raw`"\u{2028}"`)))
    expect(h.fromJson(h.String, `"\u{2029}"`)).toBe("\u{2029}")
  })

  it("keeps the sign of a hex or binary zero in _num (spec §2)", () => {
    expect(toHausJson(parse("[-0x0, -0b0, 0x0]"))).toBe(`{"_haus":1,"_value":[{"_num":"-0"},{"_num":"-0"},{"_num":"0"}]}`)
  })

  it("holds values to the haus nesting limit, not JSON's", () => {
    // `Tag { … }` is one haus level but four JSON levels.
    const deep = (n: number): string => (n === 0 ? "1" : `A { x: ${deep(n - 1)} }`)
    const atLimit = parse(deep(256))
    expect(canonical(fromHausJson(toHausJson(atLimit)))).toBe(canonical(atLimit))
    // Arrays are one JSON level each: past 256, the haus limit is what rejects them.
    const envelope = (json: string) => `{"_haus": 1, "_value": ${json}}`
    expect(() => fromHausJson(envelope("[".repeat(256) + "]".repeat(256)))).not.toThrow()
    expect(() => fromHausJson(envelope("[".repeat(257) + "]".repeat(257)))).toThrow(/nesting deeper than 256/)
  })

  it("JSON Lines: an envelope per line", async () => {
    const values = [parse("1"), parse(`A { x: "y" }`)]
    const lines = await collect(toHausJsonLines(values))
    expect(lines).toEqual([`{"_haus":1,"_value":{"_num":"1"}}\n`, `{"_haus":1,"_value":{"_tag":"A","_args":[{"_rec":{"x":"y"}}]}}\n`])
    const back = await collect(fromHausJsonLines([lines.join("").slice(0, 7), lines.join("").slice(7)]))
    expect(back.map(canonical)).toEqual(values.map(canonical))
    await expect(collect(fromHausJsonLines([`${lines[0]}{"_num":"1"}\n`]))).rejects.toThrow(/expected the envelope .* at \$\[1\]$/)
  })
})

describe("import (spec §16.1)", () => {
  it("reads JSON as haus", () => {
    expect(canonical(importJson(`{"a": [true, null, 1.50], "b": {"c": "d"}}`))).toBe(`{a:[True,None,1.50],b:{c:"d"}}`)
  })

  it("nothing in the data is special: an envelope is a record", () => {
    expect(canonical(importJson(`{"_haus": 1, "_value": {"_num": "1"}}`))).toBe(`{_haus:1,_value:{_num:"1"}}`)
  })

  it("JSON Lines, in chunks of any size", async () => {
    const text = `{"a": 1}\r\n[2, "😀"]\n3\n`
    const bytes = new TextEncoder().encode(text)
    for (const size of [1, 2, 5, bytes.length]) {
      const chunks: Uint8Array[] = []
      for (let i = 0; i < bytes.length; i += size) chunks.push(bytes.subarray(i, i + size))
      expect((await collect(importJsonLines(chunks))).map(canonical)).toEqual([`{a:1}`, `[2,"😀"]`, `3`])
    }
  })

  it("JSON Lines: errors name the line, a blank line is an error, strict mode wants the last line feed", async () => {
    await expect(collect(parseJsonLines(["1\n{\n"]))).rejects.toMatchObject({ line: 2 })
    // An empty line, and a byte order mark at the start of a later line, are no JSON text (spec §16, "Streams").
    await expect(collect(parseJsonLines(["1\n\n2\n"]))).rejects.toMatchObject({ code: "json-syntax", line: 2, reason: expect.stringMatching(/line 2 is empty/) })
    await expect(collect(importJsonLines(["1\r\n\r\n2\r\n"]))).rejects.toMatchObject({ code: "json-syntax", line: 2 })
    await expect(collect(fromHausJsonLines([`{"_haus":1,"_value":"a"}\n\n`]))).rejects.toMatchObject({ code: "json-syntax", line: 2 })
    expect(await collect(parseJsonLines(["1\n2"]))).toEqual([new JsonNumber("1"), new JsonNumber("2")])
    await expect(collect(parseJsonLines(["1\n2"], { requireTerminator: true }))).rejects.toThrow(/truncated/)
    await expect(collect(parseJsonLines(["[1, 2]\n"], { maxLineLength: 3 }))).rejects.toThrow(/longer than 3/)
    // A byte order mark is ignored at the start of the stream only, as in haus streams.
    expect(await collect(parseJsonLines(["\uFEFF1\n2\n"]))).toEqual([new JsonNumber("1"), new JsonNumber("2")])
    expect(await collect(parseJsonLines([new Uint8Array([0xef, 0xbb, 0xbf, 0x31, 0x0a])]))).toEqual([new JsonNumber("1")])
    await expect(collect(parseJsonLines(["1\n\uFEFF2\n"]))).rejects.toMatchObject({ code: "json-syntax", line: 2, reason: expect.stringMatching(/byte order mark at the start of line 2/) })
    await expect(collect(h.decodeJsonLines(h.Int32, ["1\n2\n\uFEFF3\n"]))).rejects.toMatchObject({ code: "json-syntax", line: 3 })
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

describe("schema-based (spec §16.3), hand-written schemas", () => {
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
    expect(h.toJson(Shape, unknown)).toBe(`{"_tag":"Hexagon","_args":[{"_rec":{"side":{"_num":"1"}}}]}`)
    expect(h.fromJson(Shape, `{"_tag":"Hexagon","_args":[{"_rec":{"side":{"_num":"1"}}}]}`)).toEqual(unknown)
  })

  it.each([
    [`{"_tag":"Empty","x":1}`, /unexpected member/],
    [`{"_tag":"Label","value":"a","x":1}`, /unexpected member/],
    [`{"_tag":"Label"}`, /needs a member "value"/],
    [`{"_tag":"Hexagon","_args":[]}`, /non-empty/],
    [`{"_tag":"Hexagon","_args":[{"_haus":1,"_value":"a"}]}`, /not a self-describing form/],
    [`{"_tag":"hexagon"}`, /not a tag name/],
    [`{"_tag":1}`, /_tag/],
  ])("rejects %s", (text, message) => {
    expect(() => h.fromJson(Shape, text)).toThrow(message)
  })

  it("an unknown tag with other members than _args: a newer writer's record payload, imported", () => {
    expect(canonical(h.encode(Shape, h.fromJson(Shape, `{"_tag":"Hexagon","side":1,"_args":[true]}`)))).toBe(`Hexagon{_args:[True],side:1}`)
    expect(canonical(h.encode(Shape, h.fromJson(Shape, `{"_tag":"Run","args":[1,2]}`)))).toBe(`Run{args:[1,2]}`)
    expect(canonical(h.encode(Shape, h.fromJson(Shape, `{"_tag":"Hexagon"}`)))).toBe(`Hexagon`)
  })

  it("`< >` writes every tag as an unknown value", () => {
    expect(h.toJson(h.AnyTag, "EUR")).toBe(`{"_tag":"EUR"}`)
    expect(h.fromJson(h.AnyTag, `{"_tag":"EUR"}`)).toBe("EUR")
  })

  it("a record payload with a field named _tag or _args has no schema-based form", () => {
    const Bad = h.Variant({ A: h.Record({ _tag: h.String }) })
    expect(() => h.toJson(Bad, h.decode(Bad, parse(`A { _tag: "x" }`)))).toThrow(HausEncodeError)
    expect(() => h.fromJson(Bad, `{"_tag":"A"}`)).toThrow(/_tag/)
    const Args = h.Variant({ A: h.Record({ _args: h.String }), B: h.Unit })
    expect(() => h.toJson(Args, h.decode(Args, parse(`A { _args: "x" }`)))).toThrow(/'A' has a field named _args/)
    expect(() => h.fromJson(Args, `{"_tag":"A","_args":"x"}`)).toThrow(/'A' has a field named _args/)
    // Its other cases are fine.
    expect(h.fromJson(Args, h.toJson(Args, { _tag: "B" }))).toEqual({ _tag: "B" })
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

  it("Any is its self-describing form without the envelope; an Any can't be confused with JSON null", () => {
    expect(h.toJson(h.Maybe(h.Any), h.Maybe.some(parse("None")))).toBe(`{"_tag":"None"}`)
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

  it("a schema without a schema-based form says so", () => {
    const Custom = h.withStandard<string, Omit<h.Schema<string>, "~standard">>({
      expected: "Custom",
      decode: (v, at) => (v.kind === "string" ? v.value : at.fail("expected a string")),
      encode: (s) => ({ kind: "string", value: s }),
    })
    expect(() => h.toJson(h.Record({ c: Custom }), { c: "x" })).toThrow(/Custom has no schema-based JSON form at \$\.c/)
    const WithJson = h.withStandard<string, Omit<h.Schema<string>, "~standard">>({ ...Custom, json: { kind: "string" } })
    expect(h.toJson(WithJson, "x")).toBe(`"x"`)
  })

  it("JSON Lines", async () => {
    const Event = h.Variant({ A: h.Record({ n: h.Int }), B: h.Unit })
    const lines = await collect(h.encodeJsonLines(Event, [{ _tag: "A" as const, n: 1n }, { _tag: "B" as const }]))
    expect(lines).toEqual([`{"_tag":"A","n":"1"}\n`, `{"_tag":"B"}\n`])
    expect(await collect(h.decodeJsonLines(Event, [lines.join("")]))).toEqual([{ _tag: "A", n: 1n }, { _tag: "B" }])
    await expect(collect(h.decodeJsonLines(Event, [`{"_tag":"B"}\n{"_tag":"C"}\n`]))).rejects.toThrow(/at \$\[1\]/)
    // Places start with the line's index, then the place in the line's JSON (spec §16.3 "Places"),
    // also for what the schema finds after reading (a range).
    const Line = h.Record({ price: h.Int32, at: h.Variant({ P: h.Tuple(h.Int32, h.Int32) }) })
    const line = (price: string) => `{"price": ${price}, "at": {"_tag": "P", "values": [1, 2]}}\n`
    await expect(collect(h.decodeJsonLines(Line, [line("1") + line("2") + line("3") + line("1.5")]))).rejects.toMatchObject({ code: "not-an-integer", path: [3, "price"] })
    await expect(collect(h.decodeJsonLines(Line, [line("1") + `{"price": 1, "at": {"_tag": "P", "values": [1, 3000000000]}}\n`]))).rejects.toMatchObject({ code: "out-of-range", path: [1, "at", "values", 1] })
  })

  it("compares as data", () => {
    expect(equalsJson(parseJson(`{"a": 1, "b": [2]}`), parseJson(`{"b":[2],"a":1}`))).toBe(true)
    expect(equalsJson(parseJson(`1.0`), parseJson(`1`))).toBe(false)
  })
})
