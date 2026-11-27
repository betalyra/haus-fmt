/**
 * Values built in code (spec §7, §11, §12; test-suite/README.md, "Values
 * built in code"): checked when built, with the code of the mistake; sizes
 * and depths recorded; the writers, the canonical form, hashing, equality and
 * order total; the safety net `value-changed`.
 */
import { describe, expect, it } from "vitest"
import * as haus from "../src/haus.js"
import { Result, Value, type HausError } from "../src/haus.js"
import { arr, num, parse, rec, str, variant } from "../src/index.js"
import * as h from "../src/schema.js"
import { withCodec } from "../src/codegen.js"

/** The code of a failed Result (or "ok"). */
const codeOf = (r: Result<unknown, HausError>): string | undefined => (r._tag === "Failure" ? r.failure.code ?? "config" : "ok")

/** x0 = [], x(n+1) = [xn, xn]: size 2^(n+1) - 1, n + 1 levels. */
const doubling = (n: number): Result<haus.HArray, haus.HausEncodeError> => {
  let x: Result<haus.HArray, haus.HausEncodeError> = Value.array([])
  for (let i = 0; i < n && x._tag === "Success"; i++) x = Value.array([x.success, x.success])
  return x
}

describe("constructors check what they are given, with the code of the mistake (spec §11)", () => {
  it("the value itself", () => {
    expect(codeOf(Value.variant("lower"))).toBe("invalid-tag")
    expect(codeOf(Value.variant("T\uD800"))).toBe("invalid-tag")
    expect(codeOf(Value.number("01"))).toBe("invalid-number")
    expect(codeOf(Value.number("NaN"))).toBe("invalid-number")
    expect(codeOf(Value.number(Number.NaN))).toBe("invalid-number")
    expect(codeOf(Value.record([["a", num(1)], ["a", num(2)]]))).toBe("duplicate-key")
    expect(codeOf(Value.string("a\uD800"))).toBe("cannot-encode")
    expect(codeOf(Value.record({ "\uDC00": num(1) }))).toBe("cannot-encode")
    // @ts-expect-error: an object that only looks like a value
    expect(codeOf(Value.array([{ kind: "number", text: "1" }]))).toBe("cannot-encode")
  })

  it("the default limits of spec §7, each one past them", () => {
    const max = 16 * 1024 * 1024
    expect(codeOf(Value.string("x".repeat(max + 1)))).toBe("string-too-long")
    expect(codeOf(Value.string("x".repeat(max)))).toBe("ok")
    expect(codeOf(Value.bytes(new Uint8Array(max / 2 + 1)))).toBe("string-too-long")
    expect(codeOf(Value.record({ ["k".repeat(max + 1)]: num(1) }))).toBe("key-too-long")
    expect(codeOf(Value.variant("T".repeat(max + 1)))).toBe("tag-too-long")
    expect(codeOf(Value.number(`1${"0".repeat(1000)}`))).toBe("number-too-long")
    expect(codeOf(Value.number(`1${"0".repeat(999)}`))).toBe("ok")
    expect(codeOf(Value.number(`0x${"f".repeat(840)}`))).toBe("number-too-long")
    expect(codeOf(Value.number("1e6145"))).toBe("exponent-too-large")
    expect(codeOf(Value.number("1e6144"))).toBe("ok")
    // 257 levels, counted as for values built in code: a record payload is one level.
    let deep: Result<haus.Value, haus.HausEncodeError> = Value.number(1)
    for (let i = 0; i < 256; i++) deep = i % 2 === 0 ? Value.array([deep]) : Value.variant("T", [Value.record({ a: deep })])
    expect(codeOf(deep)).toBe("ok")
    expect(deep._tag === "Success" && deep.success.depth).toBe(256)
    expect(codeOf(Value.array([deep]))).toBe("nesting-too-deep")
  })

  it("too-many-nodes where a value whose parts share each other is built", () => {
    // Size 2^26 - 1 is within 64 Mi; the next array, 2^27 - 1, is refused where it is built.
    const x25 = doubling(25)
    expect(x25._tag === "Success" && x25.success.size).toBe(2 ** 26 - 1)
    expect(codeOf(doubling(26))).toBe("too-many-nodes")
  })

  it("a part's failure is the container's", () => {
    expect(codeOf(Value.record({ a: Value.array([Value.variant("x")]) }))).toBe("invalid-tag")
    const ok = Value.record({ id: Value.number(1), status: Value.variant("Paid") })
    expect(ok._tag === "Success" && haus.stringify(ok.success, { style: "compact" })).toBe("{ id: 1, status: Paid }")
  })
})

describe("each container records its size and depth (spec §7)", () => {
  it("as written out: a shared part counts each time", () => {
    const one = num(1)
    expect(variant("T", [rec({ a: one })]).size).toBe(3)
    expect(variant("T", [one, num(2)]).size).toBe(3)
    expect(arr([arr([one])]).size).toBe(3)
    const pair = arr([one, one])
    expect(arr([pair, pair]).size).toBe(7)
    // `Tag { … }` is one level, `Tag({ … })` parsed is two, but they are one value (spec §7).
    expect(variant("Some", [rec({ a: one })]).depth).toBe(1)
    expect(parse("Some({ a: 1 })").depth).toBe(1)
    expect(arr([]).depth).toBe(1)
    expect(variant("A", [variant("B", [one])]).depth).toBe(2)
    expect(one.size).toBe(1)
    expect(one.depth).toBe(0)
    // Parsed values record them too.
    expect(parse("[[1], { a: T { b: [] } }]").size).toBe(7)
  })
})

describe("what takes a value is total (spec §11, §12)", () => {
  it("a value at every default limit is written and read back by a reader with the default limits", async () => {
    let deep: Result<haus.Value, haus.HausEncodeError> = Value.number(`9${"9".repeat(999)}`)
    for (let i = 0; i < 255; i++) deep = Value.array([deep])
    expect(deep._tag).toBe("Success")
    const v = (deep as haus.Success<haus.Value>).success
    for (const style of ["pretty", "compact", "minimised"] as const) {
      const text = haus.stringify(v, { style })
      const back = haus.parse(text)
      expect(back._tag === "Success" && haus.equals(back.success, v)).toBe(true)
    }
    expect(haus.canonical(v)).toHaveLength(1000 + 2 * 255)
    expect(await haus.hash(v)).toMatch(/^[0-9a-f]{64}$/)
    expect(await haus.hashAll([v])).toBe(await haus.hash(v))
    expect(haus.compare(v, v)).toBe(0)
    expect(haus.toHausJson(v).startsWith('{"_haus":1')).toBe(true)
  })

  it("options are checked when they are made, so writing can't fail on them", () => {
    expect(codeOf(haus.WriteOptions.make({ indent: -1 }))).toBe("config")
    expect(codeOf(haus.WriteOptions.make({ width: 1.5 }))).toBe("config")
    const o = haus.WriteOptions.make({ indent: 4 })
    expect(o._tag === "Success" && haus.stringify(rec({ a: arr([num(1), num(2)]) }), o.success)).toBe("{\n    a: [\n        1,\n        2,\n    ],\n}")
  })
})

describe("the safety net: a value changed after it was built (spec §11)", () => {
  it("an array that contains itself: value-changed, never a hang", async () => {
    const parsed = parse("[[1], 2]")
    // A parsed array isn't frozen: a cast reaches it.
    const items = (parsed as unknown as { items: haus.Value[] }).items
    items.push(parsed)
    for (const write of [() => haus.stringify(parsed), () => haus.canonical(parsed), () => haus.toHausJson(parsed), () => haus.equals(parsed, parsed), () => haus.hash(parsed)]) {
      expect(write).toThrow(expect.objectContaining({ code: "value-changed" }))
    }
  })

  it("an element added to a record's Map: value-changed", () => {
    const r = rec({ a: num(1) })
    ;(r.fields as Map<string, haus.Value>).set("b", num(2))
    expect(() => haus.stringify(r)).toThrow(expect.objectContaining({ code: "value-changed", path: [] }))
    expect(() => haus.hashAll([num(1), r])).toThrow(expect.objectContaining({ code: "value-changed", path: [1] }))
  })

  it("constructors freeze what they build: a plain assignment changes nothing", () => {
    const a = arr([num(1)])
    expect(() => (a.items as haus.Value[]).push(num(2))).toThrow(TypeError)
    expect(Object.isFrozen(str("x"))).toBe(true)
  })
})

describe("encoding the program's objects (spec §7, §15)", () => {
  type Nest = readonly Nest[]
  const Nest: h.Schema<Nest> = h.Recursive<Nest>("Nest", (self) => h.Array(self))

  it("objects that share each other: the value shares them too, and too-many-nodes at $", () => {
    let x: Nest = []
    for (let i = 0; i < 20; i++) x = [x, x]
    const v = h.encode(Nest, x)
    expect(v.size).toBe(2 ** 21 - 1)
    let y: Nest = []
    for (let i = 0; i < 26; i++) y = [y, y]
    expect(() => h.encode(Nest, y)).toThrow(expect.objectContaining({ code: "too-many-nodes", path: [] }))
  })

  it("an object that contains itself: cyclic-value", () => {
    const loop: Nest[] = []
    loop.push(loop)
    expect(() => h.encode(Nest, loop)).toThrow(expect.objectContaining({ code: "cyclic-value" }))
  })

  it("strings within the string limit: string-too-long", () => {
    expect(() => h.encode(h.String, "abcde", { maxStringLength: 4 })).toThrow(expect.objectContaining({ code: "string-too-long" }))
    expect(() => h.encode(h.Map(h.Int32), new Map([["abcde", 1]]), { maxStringLength: 4 })).toThrow(expect.objectContaining({ code: "key-too-long" }))
    expect(() => h.encode(h.Bytes, new Uint8Array(3), { maxStringLength: 4 })).toThrow(expect.objectContaining({ code: "string-too-long" }))
    expect(h.encode(h.Bytes, new Uint8Array(2), { maxStringLength: 4 }).kind).toBe("bytes")
  })

  it("every writer path checks them too: a map's keys, strings and bytes (spec §7)", () => {
    const Doc = h.Record({ m: h.Map(h.Int32), s: h.String, b: h.Bytes })
    const ok = { m: new Map([["abcd", 1]]), s: "abcd", b: new Uint8Array(2) }
    // The compact and minimised writers: the generic path, the compiled closures and the generated code.
    for (const choice of ["generic", "closures", "generated"] as const) {
      for (const style of ["compact", "minimised"] as const) {
        const four = withCodec({ maxStringLength: 4, style }, choice)
        expect(h.stringify(Doc, ok, four), `${choice} ${style}`).toBe(style === "compact" ? `{ m: { abcd: 1 }, s: "abcd", b: x"0000" }` : `{m:{abcd:1},s:"abcd",b:x"0000"}`)
        expect(() => h.stringify(Doc, { ...ok, m: new Map([["abcde", 1]]) }, four), `${choice} ${style}`).toThrow(expect.objectContaining({ code: "key-too-long", path: ["m"] }))
        expect(() => h.stringify(Doc, { ...ok, s: "abcde" }, four), `${choice} ${style}`).toThrow(expect.objectContaining({ code: "string-too-long" }))
        expect(() => h.stringify(Doc, { ...ok, b: new Uint8Array(3) }, four), `${choice} ${style}`).toThrow(expect.objectContaining({ code: "string-too-long" }))
      }
    }
  })
})
