/**
 * Text from the language's strings and values built in code (spec §4, §12):
 * a JavaScript string can hold an unpaired surrogate, which has no UTF-8
 * form, and a value built in code can be one no text spells.
 */
import { describe, expect, it } from "vitest"
import {
  arr, canonical, compare, equals, format, hash, hashAll, num, parse, parseAll, parseDocument, parseJson, parseJsonLines, parseSchemaFile, parseStream, quoteText, rec,
  str, stringify, variant,
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

describe("writers reject what no text spells (spec §4, §12)", () => {
  const encodeError = (code: string) => expect.objectContaining({ name: "HausEncodeError", code })
  const writers: [string, (v: Parameters<typeof canonical>[0]) => unknown][] = [
    ["canonical", canonical],
    ["stringify", stringify],
    ["stringify compact", (v) => stringify(v, { style: "compact" })],
    ["format", (v) => format([v])],
    ["equals", (v) => equals(v, v)],
    ["compare", (v) => compare(v, v)],
  ]
  const bad: [string, Parameters<typeof canonical>[0], string][] = [
    ["a number that isn't a literal", num("01"), "invalid-number"],
    ["NaN", arr([num("NaN")]), "invalid-number"],
    ["an empty number", num(""), "invalid-number"],
    ["a tag that isn't a tag", variant("lower"), "invalid-tag"],
    ["a lone surrogate in a string", str("x\uD800y"), "cannot-encode"],
    ["a lone surrogate in a multi-line string", str("a\nb\uDC00"), "cannot-encode"],
    ["a lone surrogate in a key", rec(new Map([["k\uD800", num("1")]])), "cannot-encode"],
  ]
  for (const [name, write] of writers) {
    it.each(bad)(`${name}: %s`, (_, value, code) => {
      expect(() => write(value)).toThrow(encodeError(code))
    })
  }

  it("hash and hashAll", async () => {
    await expect(hash(str("x\uD800y"))).rejects.toThrow(encodeError("cannot-encode"))
    await expect(hashAll([num("1"), num("01")])).rejects.toThrow(encodeError("invalid-number"))
    // No collision with U+FFFD, which a lone surrogate became when encoded.
    expect(() => canonical(str("x\uD800y"))).toThrow()
  })

  it("normalizes a number literal built in code, so equal values hash equal (spec §2)", async () => {
    expect(canonical(num("1e+05"))).toBe("1e5")
    expect(canonical(num("1E5"))).toBe("1e5")
    expect(canonical(num("0xFF"))).toBe("255")
    expect(canonical(num("1_000"))).toBe("1000")
    expect(canonical(num("-0x0"))).toBe("-0")
    expect(equals(num("1e+05"), num("1e5"))).toBe(true)
    expect(await hash(num("1e+05"))).toBe(await hash(parse("1e5")))
    // No limits: the canonical form has none (spec §12).
    expect(canonical(num(`1e${"9".repeat(30)}`))).toBe(`1e${"9".repeat(30)}`)
    // stringify writes a valid literal as it is.
    expect(stringify(num("1e+05"))).toBe("1e+05")
  })

  it("a typed value: Any checks with the place, String through the writer", () => {
    expect(() => h.stringify(h.Any, arr([str("\uD800")]))).toThrow(expect.objectContaining({ code: "cannot-encode", path: [0] }))
    expect(() => h.stringify(h.String, "\uDC00", { style: "compact" })).toThrow(encodeError("cannot-encode"))
    expect(() => h.stringify(h.Map(h.Int32), new Map([["\uDC00", 1]]), { style: "compact" })).toThrow(encodeError("cannot-encode"))
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
