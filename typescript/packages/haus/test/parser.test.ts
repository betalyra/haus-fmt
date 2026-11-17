import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import { MAX_DEPTH, parse, parseAll, parseStream, StreamReader } from "../src/index.js"
import { maxHexDigits } from "../src/parser.js"
import { suiteJson } from "./suite-json.js"
import { parseText, syntax } from "./haus.js"

describe("error messages and positions", () => {
  it.effect.each([
    ["{ ok: true }", "booleans are the variants True / False", 1, 7],
    ["{ x: null }", "use the variant None", 1, 6],
    ["{ Name: 1 }", 'quote it: "Name"', 1, 3],
    ["{\n  a: 1,\n  a: 2,\n}", "duplicate key 'a'", 3, 3],
    ["{ a: 1 b: 2 }", "expected ',' or '}'", 1, 8],
    ['"a\nb"', "line break in string", 1, 3],
    ["007", "invalid number '007'", 1, 1],
    ["Some()", "write 'Some' without parentheses", 1, 5],
    ['"""\n    a\n  b\n    """', "indented less than the closing", 3, 1],
  ] as const)("%j", ([src, message, line, column]) =>
    Effect.gen(function* () {
      const e = yield* Effect.flip(parseText(src))
      expect(e.message).toContain(message)
      expect([e.line, e.column]).toEqual([line, column])
    }))

  it.effect("stream reader reports absolute positions", () =>
    Effect.gen(function* () {
      const r = new StreamReader()
      r.push("A,\nB,\n")
      const e = yield* Effect.flip(syntax(() => r.push("{ ok: true },")))
      expect([e.line, e.column]).toEqual([3, 7])
    }))

  // Design review S18: the stream reader skipped a leading byte order mark
  // without counting it, so its columns on line 1 were one too small.
  it.effect.each(["\ufeff{ ok: true }", "\ufeff\u001b", '\ufeff","x'])("stream positions after a byte order mark: %j", (src) =>
    Effect.gen(function* () {
      const whole = yield* Effect.flip(parseText(src))
      const r = new StreamReader()
      const e = yield* Effect.flip(syntax(() => [...r.push(src), ...r.end()]))
      expect(whole.line).toBe(1)
      expect([e.line, e.column, e.offset]).toEqual([whole.line, whole.column, whole.offset])
    }))

  // An empty item between commas: the stream reader reported "found end of
  // input"; it must report what the whole-text parser reports, at the same place.
  it.effect.each(["1,,2", "1, ,2", "1,/*c*/,2", ",1", "1,\n// c\n,2", "1,,"])("stream errors for an empty item match the whole text: %j", (src) =>
    Effect.gen(function* () {
      const whole = yield* Effect.flip(parseText(src))
      expect([whole.code, whole.reason]).toEqual(["expected-value", "expected a value, found ','"])
      const at = (e: typeof whole) => [e.code, e.reason, e.line, e.column, e.offset, e.expected, e.found]
      const r = new StreamReader()
      expect(at(yield* Effect.flip(syntax(() => [...r.push(src), ...r.end()])))).toEqual(at(whole))
      // Also with the text arriving one character at a time.
      const chars = new StreamReader()
      expect(at(yield* Effect.flip(syntax(() => [...[...src].flatMap((c) => chars.push(c)), ...chars.end()])))).toEqual(at(whole))
    }))

  it.effect(`rejects nesting deeper than ${MAX_DEPTH}`, () =>
    Effect.gen(function* () {
      const nest = (n: number) => "[".repeat(n) + "]".repeat(n)
      yield* parseText(nest(MAX_DEPTH))
      const e = yield* Effect.flip(parseText(nest(MAX_DEPTH + 1)))
      expect(e.message).toContain("nesting deeper")
    }))
})

describe("StreamReader", () => {
  it("emits each value as soon as its comma arrives", () => {
    const r = new StreamReader()
    expect(r.push("UserCreated { id: 1 ")).toEqual([])
    expect(r.push("}")).toEqual([]) // a payload could still follow
    expect(r.push(",\nHeart").map(suiteJson)).toEqual([
      { _tag: "UserCreated", _args: [{ _rec: { id: { _num: "1" } } }] },
    ])
    expect(r.push("beat")).toEqual([])
    expect(r.end().map(suiteJson)).toEqual([{ _tag: "Heartbeat" }])
  })

  it("does not split on commas inside strings, comments or payloads", () => {
    const r = new StreamReader()
    const out = [...r.push('"a,b", /* , */ Pair(1, 2), // ,\n"""\n  x,\n  """,'), ...r.end()]
    expect(out.map(suiteJson)).toEqual(["a,b", { _tag: "Pair", _args: [{ _num: "1" }, { _num: "2" }] }, "x,"])
  })

  it("skips a byte order mark only at the start, not after a comma (found by fuzz/)", () => {
    const read = (text: string) => {
      const r = new StreamReader()
      return [...r.push(text), ...r.end()]
    }
    expect(read("\uFEFFA, B")).toHaveLength(2)
    expect(() => read("A,\uFEFF")).toThrow()
    expect(() => read("A,\uFEFF B, C")).toThrow()
  })

  it("parseStream skips one byte order mark, not two (found by fuzz/)", async () => {
    const all = async (bytes: number[]) => {
      const out = []
      for await (const v of parseStream([Uint8Array.from(bytes)])) out.push(v)
      return out
    }
    expect(await all([0xef, 0xbb, 0xbf, 0x31])).toHaveLength(1)
    await expect(all([0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf, 0x31])).rejects.toThrow()
  })

  it("reads comments between values, split anywhere", () => {
    const text = '// header, with a comma\nA { x: 1 }, // after A, [unbalanced\n/* block, with } and " and /* nested, */ */\nB(2),\n\n// before C\nC { s: "// not a comment" } /* before the comma */ ,\n// trailing comment, {'
    const whole = parseAll(text).map(suiteJson)
    expect(whole).toHaveLength(3)
    for (let k = 0; k <= text.length; k++) {
      const r = new StreamReader()
      const out = [...r.push(text.slice(0, k)), ...r.push(text.slice(k)), ...r.end()]
      expect(out.map(suiteJson)).toEqual(whole)
    }
  })
})

describe("parse", () => {
  it("accepts exactly one value", () => {
    expect(suiteJson(parse("{ a: 1 },"))).toEqual({ _rec: { a: { _num: "1" } } })
  })

  it.effect.each(["1, 2", "// empty"])("rejects %j", (src) =>
    Effect.gen(function* () {
      const e = yield* Effect.flip(syntax(() => parse(src)))
      expect(e.message).toContain("exactly one value")
    }))
})

describe("parseAll", () => {
  it("returns the top-level sequence", () => {
    expect(parseAll("A, B,").map(suiteJson)).toEqual([{ _tag: "A" }, { _tag: "B" }])
  })
})

describe("limits and stream safety", () => {
  it.effect("limits are configurable", () =>
    Effect.gen(function* () {
      const e = yield* Effect.flip(syntax(() => parseAll("123456", { maxNumberLength: 5 })))
      expect(e.message).toContain("number literal longer than 5")
      const s = yield* Effect.flip(syntax(() => parseAll('"abcdef"', { maxStringLength: 3 })))
      expect(s.message).toContain("string longer than 3")
    }))

  it.effect("a hex literal has at most as many hex digits as fit the number limit in decimal (spec §7)", () =>
    Effect.gen(function* () {
      expect(maxHexDigits(1000)).toBe(829)
      // The largest h with 16^h ≤ 10^(n−1), checked against exact powers.
      for (let n = 1; n <= 1500; n++) {
        const h = maxHexDigits(n)
        expect(16n ** BigInt(h) <= 10n ** BigInt(n - 1) && 16n ** BigInt(h + 1) > 10n ** BigInt(n - 1)).toBe(true)
      }
      const f = "f".repeat(829)
      expect(parse(`[0x${f}, -0x${f}]`)).toEqual(parse(`[${16n ** 829n - 1n}, -${16n ** 829n - 1n}]`))
      // `_` doesn't count; leading zeros do.
      expect(() => parse(`0x${f.slice(1)}_f`)).not.toThrow()
      const e = yield* Effect.flip(syntax(() => parse(`[1, 0x${f}f]`)))
      expect(e.code).toBe("number-too-long")
      expect([e.line, e.column]).toEqual([1, 5])
      expect(e.message).toContain("more than 829 hex digits")
      expect((yield* Effect.flip(syntax(() => parse(`-0x0${f}`)))).code).toBe("number-too-long")
      expect((yield* Effect.flip(syntax(() => parse("0x" + "f".repeat(15) + "f", { maxNumberLength: 20 })))).code).toBe("number-too-long")
      expect(parse("0b" + "1".repeat(998)).kind).toBe("number")
    }))

  it.effect("requireTerminator reports a cut-off last value", () =>
    Effect.gen(function* () {
      const r = new StreamReader({ requireTerminator: true })
      expect(r.push("1000,\n100").length).toBe(1)
      const e = yield* Effect.flip(syntax(() => r.end()))
      expect(e.message).toContain("truncated")
    }))

  it.effect("maxValueLength bounds memory for a value that never ends", () =>
    Effect.gen(function* () {
      const r = new StreamReader({ maxValueLength: 100 })
      const e = yield* Effect.flip(syntax(() => r.push("[" + "1, ".repeat(100))))
      expect(e.message).toContain("value longer than 100")
    }))

  it("error columns count code points, not UTF-16 units", () => {
    // "😀" is two UTF-16 units but one column.
    try {
      parseAll('["😀", x]')
    } catch (e) {
      expect((e as { column: number }).column).toBe(7)
    }
  })
})

describe("string length limit", () => {
  it("counts characters, not UTF-16 units", () => {
    const emoji = "😀".repeat(3) // 3 characters, 6 UTF-16 units
    expect(parseAll(`"${emoji}"`, { maxStringLength: 3 }).length).toBe(1)
    expect(() => parseAll(`"${emoji}x"`, { maxStringLength: 3 })).toThrow("longer than 3 characters")
  })
})
