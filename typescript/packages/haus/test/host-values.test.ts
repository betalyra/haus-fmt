/**
 * Text from the language's strings and values built in code (spec §4, §11,
 * §12): a JavaScript string can hold an unpaired surrogate, which has no
 * UTF-8 form, and the constructors reject what no text spells, so what takes
 * a value can't fail for it.
 */
import { describe, expect, it } from "vitest"
import {
  arr, bytes, canonical, compare, equals, format, hash, hashAll, isValue, num, parse, parseAll, parseDocument, parseJson, parseJsonLines, parseSchemaFile, parseStream,
  quoteText, rec, str, stringify, variant, type Value,
} from "../src/index.js"
import * as h from "../src/schema.js"

const collect = async <T>(it: AsyncIterable<T>): Promise<T[]> => {
  const out: T[] = []
  for await (const x of it) out.push(x)
  return out
}

describe("text with an unpaired surrogate is invalid-utf8, at the first one (spec §4)", () => {
  const at = (line: number, column: number) => ({ code: "invalid-utf8", line, column })
  it.each([
    ['"x\uD800y"', at(1, 3)],
    ['"x\uDC00"', at(1, 3)],
    ['{ a: 1,\n  "😀 x\uDC00": 2 }', at(2, 7)],
    ["1 // \uD800 in a comment", at(1, 6)],
    // Before any other error, wherever it is: the text is checked first, as bytes are.
    ["{ a: ,\n \uD83D", at(2, 2)],
  ])("%j", (text, error) => {
    expect(() => parseAll(text)).toThrow(expect.objectContaining(error))
    expect(() => parseDocument(text)).toThrow(expect.objectContaining(error))
    expect(() => h.parse(h.Any, text)).toThrow(expect.objectContaining(error))
  })

  it("accepts surrogate pairs", () => {
    expect(parse('"😀"')).toEqual(str("😀"))
  })

  it("in streams, JSON and schema files", async () => {
    await expect(collect(parseStream(["1,\n", '"\uD800"'.slice(0, 2), '"']))).rejects.toMatchObject(at(2, 2))
    await expect(collect(parseStream(["1, \uD83D", "\uDE00 x"]))).rejects.toMatchObject({ code: "expected-value", message: expect.stringContaining("found '😀'") })
    expect(() => parseJson('["\uDC00"]')).toThrow(expect.objectContaining(at(1, 3)))
    await expect(collect(parseJsonLines(['1\n"\uDC00"\n']))).rejects.toMatchObject(at(2, 2))
    expect(() => parseSchemaFile("// \uD800\ntype A = String")).toThrow(expect.objectContaining(at(1, 4)))
  })
})

describe("constructors build only haus values (spec §11, values built in code)", () => {
  const encodeError = (code: string) => expect.objectContaining({ name: "HausEncodeError", code, path: [] })
  const one = num("1")
  it.each<[string, () => unknown, string]>([
    ["a number that isn't a literal", () => num("01"), "invalid-number"],
    ["NaN", () => num("NaN"), "invalid-number"],
    ["an empty number", () => num(""), "invalid-number"],
    ["a number with spaces", () => num(" 1"), "invalid-number"],
    ["two numbers", () => num("1 2"), "invalid-number"],
    ["a number that isn't text, a JS number or a bigint", () => num({} as unknown as string), "cannot-encode"],
    ["a tag that isn't a tag", () => variant("lower"), "invalid-tag"],
    ["an empty tag", () => variant(""), "invalid-tag"],
    ["a tag with a lone surrogate", () => variant("A\uD800"), "invalid-tag"],
    ["a tag that is a lone surrogate", () => variant("\uD800"), "invalid-tag"],
    ["a tag that isn't text", () => variant(1 as unknown as string), "cannot-encode"],
    ["a key given twice", () => rec([["a", one], ["a", str("x")]]), "duplicate-key"],
    ["a lone surrogate in a string", () => str("x\uD800y"), "cannot-encode"],
    ["a lone surrogate in a multi-line string", () => str("a\nb\uDC00"), "cannot-encode"],
    ["a lone surrogate in a key", () => rec(new Map([["k\uD800", one]])), "cannot-encode"],
    ["a lone surrogate in a key of an object", () => rec({ "k\uDC00": one }), "cannot-encode"],
    ["an object that looks like a value", () => arr([{ kind: "number", text: "1" } as unknown as Value]), "cannot-encode"],
    ["an empty object as an item", () => arr([{} as unknown as Value]), "cannot-encode"],
    ["something else as an argument", () => variant("Some", [1 as unknown as Value]), "cannot-encode"],
    ["something else as a field", () => rec({ a: "x" as unknown as Value }), "cannot-encode"],
    ["bytes that aren't a Uint8Array", () => bytes([1, 2] as unknown as Uint8Array), "cannot-encode"],
    ["a string that isn't text", () => str(undefined as unknown as string), "cannot-encode"],
  ])("%s", (_, build, code) => {
    expect(build).toThrow(encodeError(code))
  })

  it("normalizes a number literal as the parser does, then applies the number limits (spec §7)", () => {
    expect(num("1e+05").text).toBe("1e5")
    expect(num("1E5").text).toBe("1e5")
    expect(num("0xFF").text).toBe("255")
    expect(num("1_000").text).toBe("1000")
    expect(num("-0x0").text).toBe("-0")
    expect(num("19.90").text).toBe("19.90")
    expect(num(255).text).toBe("255")
    expect(num(10n ** 30n).text).toBe(`1${"0".repeat(30)}`)
    expect(() => num(`1e${"9".repeat(30)}`)).toThrow(expect.objectContaining({ code: "exponent-too-large" }))
    expect(() => num("7".repeat(3000))).toThrow(expect.objectContaining({ code: "number-too-long" }))
    expect(num("1e+05")).toEqual(parse("1e5"))
  })

  it("accepts a Map, [key, value] pairs or an object, in their order", () => {
    const fromMap = rec(new Map<string, Value>([["b", one], ["a", str("x")]]))
    const fromPairs = rec([["b", one], ["a", str("x")]])
    const fromObject = rec({ b: one, a: str("x") })
    for (const r of [fromMap, fromPairs, fromObject]) expect([...r.fields.keys()]).toEqual(["b", "a"])
    expect(stringify(fromObject, { style: "compact" })).toBe('{ b: 1, a: "x" }')
    expect(stringify(rec({ __proto__: one } as unknown as Record<string, Value>), { style: "compact" })).toBe("{}")
    expect(stringify(rec([["__proto__", one]]), { style: "compact" })).toBe("{ __proto__: 1 }")
  })

  it("copies what it is given, so a built value can't change", () => {
    const items: Value[] = [one]
    const a = arr(items)
    items.push(str("later"))
    expect(a.items).toEqual([one])
    expect(Object.isFrozen(a.items)).toBe(true)
    expect(() => (a.items as Value[]).push(a)).toThrow(TypeError)
    const fields = new Map<string, Value>([["a", one]])
    const r = rec(fields)
    fields.set("b", one)
    expect([...r.fields.keys()]).toEqual(["a"])
    const args: Value[] = [one]
    const v = variant("Some", args)
    args[0] = str("later")
    expect(v.args).toEqual([one])
    const data = new Uint8Array([1, 2])
    const b = bytes(data)
    data[0] = 9
    expect(b.bytes).toEqual(new Uint8Array([1, 2]))
  })

  it("isValue: built or parsed values only", () => {
    expect(isValue(one)).toBe(true)
    expect(isValue(parse("{ a: [1, X] }"))).toBe(true)
    expect(isValue({ kind: "number", text: "1" })).toBe(false)
    expect(isValue(structuredClone(one))).toBe(false)
    expect(isValue(null)).toBe(false)
  })

  it("an object literal is not a Value (types)", () => {
    // @ts-expect-error: a Value is built by a constructor, not written as an object
    const forged: Value = { kind: "number", text: "01" }
    // @ts-expect-error: the same inside a container
    const inside = () => arr([{ kind: "string", value: "x" }])
    expect(forged.kind).toBe("number")
    expect(inside).toThrow(expect.objectContaining({ code: "cannot-encode" }))
  })
})

describe("what takes a value can't fail for it (spec §12)", () => {
  const built = rec([
    ["n", num("1e+05")],
    ["x", num("0xFF")],
    ["s", str("😀 a\nb")],
    ["k-y", arr([bytes(new Uint8Array([0, 255])), variant("None"), variant("Point", [num("1"), num("-0")])])],
    // A part parsed with larger limits keeps them (spec §7): constructors refuse such a number themselves.
    ["big", parse("9".repeat(1500), { maxNumberLength: 2000 })],
  ])

  it("canonical, equals, compare, hash and hashAll", async () => {
    expect(canonical(built)).toBe(`{big:${"9".repeat(1500)},"k-y":[x"00ff",None,Point(1,-0)],n:1e5,s:"😀 a\\nb",x:255}`)
    const parsed = parse(`{ x: 255, n: 1e5, s: "😀 a\\nb", "k-y": [x"00ff", None, Point(1, -0)], big: ${"9".repeat(1500)} }`, { maxNumberLength: 2000 })
    expect(equals(built, parsed)).toBe(true)
    expect(compare(built, parsed)).toBe(0)
    expect(await hash(built)).toBe(await hash(parsed))
    expect(await hashAll([built, num("1")])).toBe(await hashAll([parsed, parse("1")]))
    expect(equals(num("1e+05"), num("1e5"))).toBe(true)
    expect(await hash(num("1e+05"))).toBe(await hash(parse("1e5")))
  })

  it("writers write the normalized number, and never fail (spec §11)", () => {
    expect(stringify(num("1e+05"))).toBe("1e5")
    expect(stringify(num("0xFF"), { style: "minimised" })).toBe("255")
    // A number parsed with larger limits is written as it is.
    expect(format([built, num("1")], { style: "compact" })).toContain("big: 9999")
  })

  it("constructors check every number against the number limits on its normalized form, a decimal or an exponent too (spec §7)", () => {
    expect(() => num(`1.${"0".repeat(2000)}`)).toThrow(expect.objectContaining({ code: "number-too-long" }))
    expect(() => num("1e9999")).toThrow(expect.objectContaining({ code: "exponent-too-large" }))
    expect(() => num(`1${"0".repeat(1000)}`)).toThrow(expect.objectContaining({ code: "number-too-long" }))
    expect(() => num(`0x${"f".repeat(840)}`)).toThrow(expect.objectContaining({ code: "number-too-long" }))
    expect(num(`1${"_0".repeat(600)}`).text).toBe(`1${"0".repeat(600)}`)
    expect(stringify(num("1e6144"))).toBe("1e6144")
    expect(stringify(num(`1${"0".repeat(999)}`))).toHaveLength(1000)
    // An encoder checks with its own limits (spec §7).
    expect(() => h.stringify(h.Any, num("1e100"), { maxExponent: 99 })).toThrow(expect.objectContaining({ code: "exponent-too-large" }))
    const long = parse(`1.${"0".repeat(2000)}`, { maxNumberLength: 2002 })
    expect(h.stringify(h.Any, long, { maxNumberLength: 2002 })).toBe(long.kind === "number" ? long.text : "")
    // The canonical form has no limits (spec §12).
    expect(canonical(long)).toBe(long.kind === "number" ? long.text : "")
  })

  it("a typed value: Any checks the limits with the place, String and Map keys with the place", () => {
    expect(() => h.stringify(h.Any, arr([str("x".repeat(20))]), { maxStringLength: 10 })).toThrow(expect.objectContaining({ code: "string-too-long", path: [0] }))
    // Forged: a parsed array (not frozen) changed with a cast.
    const forged = parse("[1]") as unknown as { items: unknown[] }
    forged.items[0] = { kind: "string", value: "x" }
    expect(() => h.stringify(h.Any, forged as unknown as Value)).toThrow(expect.objectContaining({ code: "cannot-encode", path: [0] }))
    expect(() => h.stringify(h.String, "\uDC00", { style: "compact" })).toThrow(expect.objectContaining({ code: "cannot-encode", path: [] }))
    expect(() => h.stringify(h.Record({ a: h.String }), { a: "x\uD800" })).toThrow(expect.objectContaining({ code: "cannot-encode", path: ["a"] }))
    expect(() => h.stringify(h.Map(h.Int32), new Map([["\uDC00", 1]]), { style: "compact" })).toThrow(expect.objectContaining({ code: "cannot-encode" }))
    expect(() => h.encode(h.Map(h.Int32), new Map([["\uDC00", 1]]))).toThrow(expect.objectContaining({ code: "cannot-encode", path: [] }))
  })
})

describe("quoting in messages (spec §9.2)", () => {
  it("escapes, then cuts within 40 characters as shown", () => {
    expect(quoteText("a‮b\u0007")).toBe("a\\u{202E}b\\u{7}")
    expect(quoteText("x".repeat(100))).toBe(`${"x".repeat(39)}…`)
    expect(quoteText(`${"😀".repeat(39)}x`)).toBe("😀".repeat(39) + "x")
    expect(quoteText("😀".repeat(41))).toBe(`${"😀".repeat(39)}…`)
  })

  it("the data parser quotes what it shows", () => {
    expect(() => parse(`{ ${"k".repeat(100)}: 1, ${"k".repeat(100)}: 2 }`)).toThrow(`duplicate key '${"k".repeat(39)}…'`)
    expect(() => parse("{ a: ‮ }")).toThrow("found '\\u{202E}'")
    expect(() => parse('"\\‮"')).toThrow("invalid escape '\\\\u{202E}'")
    expect(() => parse("😀")).toThrow("found '😀'")
  })
})
