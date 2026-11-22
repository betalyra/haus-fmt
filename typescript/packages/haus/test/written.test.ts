/**
 * What writers check of a value built in code (spec §7, §11), and the one
 * limit of the canonical form and hashing, the node limit (§12). The
 * constructors check validity only, never a limit (§11).
 */
import { describe, expect, it } from "vitest"
import {
  arr, bytes, canonical, compare, equals, format, hash, hashAll, num, parse, rec, str, stringify, toHausJson, variant, type Value,
} from "../src/index.js"
import * as h from "../src/schema.js"

/** An array of `depth` levels whose two items are the same value: 2^(depth+1) - 1 nodes written, depth + 1 objects. */
const shared = (depth: number): Value => {
  let v: Value = num("1")
  for (let i = 0; i < depth; i++) v = arr([v, v])
  return v
}

/** A value built in code `levels` deep: arrays and variants with record payloads, in turn. */
const deep = (levels: number, innermost: string): Value => {
  let v: Value = str(innermost)
  for (let i = 0; i < levels; i++) v = i % 2 === 0 ? arr([v]) : variant("T", [rec([["a", v]])])
  return v
}

describe("the canonical form, hashing, equality and order at any depth (spec §12)", () => {
  it("handle a value 100,000 levels deep", async () => {
    const [a, b, c] = [deep(100_000, "x"), deep(100_000, "x"), deep(100_000, "y")]
    expect(canonical(a)).toBe("T{a:[".repeat(50_000) + '"x"' + "]}".repeat(50_000))
    expect(await hash(a)).toBe(await hash(b))
    expect(await hashAll([a])).toBe(await hash(a))
    expect(equals(a, b)).toBe(true)
    expect(equals(a, c)).toBe(false)
    expect(compare(a, b)).toBe(0)
    expect(compare(a, c)).toBe(-1)
    expect(compare(c, a)).toBe(1)
  })
})

const code = (code: string, path?: readonly (string | number)[]) => expect.objectContaining(path === undefined ? { code } : { code, path })

describe("constructors check validity only, never a limit", () => {
  it("take any length and exponent", () => {
    expect(num("1".repeat(5000)).text).toHaveLength(5000)
    expect(num("1e99999").text).toBe("1e99999")
    expect(str("x".repeat(100)).value).toHaveLength(100)
    expect(variant("T".repeat(100)).tag).toHaveLength(100)
    expect(rec([["k".repeat(100), num("1")]]).fields.size).toBe(1)
    expect(shared(64).kind).toBe("array")
  })
})

describe("writers check every limit (spec §11)", () => {
  const four = { maxStringLength: 4 }
  it("the length of strings, keys, tags and byte strings, in code points, at their place", () => {
    expect(stringify(arr([str("abcd")]), { style: "minimised", limits: four })).toBe('["abcd"]')
    expect(stringify(str("😀😀😀😀"), { limits: four })).toBe('"😀😀😀😀"')
    expect(() => stringify(arr([str("abcde")]), { limits: four })).toThrow(code("string-too-long", [0]))
    expect(() => stringify(rec([["a", rec([["abcde", num("1")]])]]), { limits: four })).toThrow(code("key-too-long", ["a"]))
    expect(() => stringify(variant("Abcde"), { limits: four })).toThrow(code("tag-too-long", []))
    expect(() => stringify(bytes(new Uint8Array(3)), { limits: four })).toThrow(code("string-too-long", []))
    expect(stringify(bytes(new Uint8Array(2)), { limits: four })).toBe('x"0000"')
  })

  it("number literals and exponents", () => {
    expect(() => stringify(num("1".repeat(1001)))).toThrow(code("number-too-long", []))
    expect(() => stringify(rec([["n", num("1e6145")]]))).toThrow(code("exponent-too-large", ["n"]))
    expect(stringify(num("1e6145"), { limits: { maxExponent: 6145 } })).toBe("1e6145")
  })

  it("the depth, counted as for values built in code: a record payload is one level, an empty container is one", () => {
    const one = { maxDepth: 1 }
    expect(stringify(variant("T", [rec([["a", num("1")]])]), { style: "compact", limits: one })).toBe("T { a: 1 }")
    expect(stringify(arr([]), { limits: one })).toBe("[]")
    expect(() => stringify(arr([arr([])]), { limits: one })).toThrow(code("nesting-too-deep", [0]))
    expect(() => stringify(variant("T", [arr([])]), { limits: one })).toThrow(code("nesting-too-deep", [0]))
    expect(() => stringify(variant("T", [rec([])]), { limits: { maxDepth: 0 } })).toThrow(code("nesting-too-deep", []))
  })

  // The default limit takes 64 Mi steps to reach (about a second): a generous timeout under load.
  it("the node limit, each value counted as often as it is written", { timeout: 60_000 }, () => {
    // shared(3): 15 nodes.
    expect(stringify(shared(3), { style: "minimised", limits: { maxNodes: 15 } })).toBe("[[[1,1],[1,1]],[[1,1],[1,1]]]")
    expect(() => stringify(shared(3), { limits: { maxNodes: 14 } })).toThrow(code("too-many-nodes", []))
    expect(() => stringify(shared(64))).toThrow(code("too-many-nodes", []))
    expect(() => toHausJson(shared(64), { maxNodes: 1000 })).toThrow(code("too-many-nodes", []))
    expect(() => h.stringify(h.Any, shared(64))).toThrow(code("too-many-nodes"))
  })

  it("each value of a stream on its own, its errors at its index, in a stream of one value too", async () => {
    expect(format([shared(3), shared(3)], { style: "compact", limits: { maxNodes: 15 } })).toBe("[[[1, 1], [1, 1]], [[1, 1], [1, 1]]],\n[[[1, 1], [1, 1]], [[1, 1], [1, 1]]],\n")
    for (const style of ["pretty", "compact"] as const) {
      expect(() => format([num("1"), shared(3)], { style, limits: { maxNodes: 14 } })).toThrow(code("too-many-nodes", [1]))
      expect(() => format([num("1"), arr([str("abcde")])], { style, limits: { maxStringLength: 4 } })).toThrow(code("string-too-long", [1, 0]))
      expect(() => format([shared(3)], { style, limits: { maxNodes: 14 } })).toThrow(code("too-many-nodes", [0]))
      expect(() => format([arr([str("abcde")])], { style, limits: { maxStringLength: 4 } })).toThrow(code("string-too-long", [0, 0]))
    }
    const errorOf = async (chunks: AsyncIterable<string>) => {
      try {
        for await (const _ of chunks);
      } catch (e) {
        return e
      }
    }
    expect(await errorOf(h.encodeStream(h.Any, [arr([str("abcde")])], { maxStringLength: 4 }))).toEqual(code("string-too-long", [0, 0]))
    expect(await errorOf(h.encodeStream(h.Any, [num("1"), shared(3)], { maxNodes: 14 }))).toEqual(code("too-many-nodes", [1]))
    // Inside a value encoded or decoded with a schema: at the value given, `$` or `$[i]` (spec §15).
    const Holder = h.Record({ x: h.Any })
    expect(() => h.encode(Holder, { x: shared(64) })).toThrow(code("too-many-nodes", []))
    expect(() => h.decode(Holder, rec([["x", shared(64)]]))).toThrow(code("too-many-nodes", []))
    expect(await errorOf(h.encodeStream(Holder, [{ x: num("1") }, { x: shared(3) }], { maxNodes: 14 }))).toEqual(code("too-many-nodes", [1]))
    expect(() => h.formatAll(h.Any, [arr([str("abcde")])], { maxStringLength: 4 })).toThrow(code("string-too-long", [0, 0]))
  })

  it("checked as written, in every layout: the error is the one found checking the value first", () => {
    const four = { maxStringLength: 4 }
    const long = rec([["a", arr([num("1"), variant("T", [rec([["b", str("abcde")]])])])]])
    for (const style of ["pretty", "compact", "minimised"] as const) {
      expect(() => stringify(long, { style, limits: four })).toThrow(code("string-too-long", ["a", 1, 0, "b"]))
      // Two errors: written.ts's order (containers last pushed first), not the order written.
      expect(() => stringify(arr([arr([str("abcde")]), arr([str("abcde")])]), { style, limits: four })).toThrow(code("string-too-long", [1, 0]))
      expect(() => stringify(arr([arr([arr([])]), str("abcde")]), { style, limits: { maxStringLength: 4, maxDepth: 2 } })).toThrow(code("string-too-long", [1]))
      expect(() => stringify(variant("T", [arr([arr([])])]), { style, limits: { maxDepth: 2 } })).toThrow(code("nesting-too-deep", [0, 0]))
      expect(() => stringify(variant("T", [rec([["a", arr([])]])]), { style, limits: { maxDepth: 2 } })).not.toThrow()
      expect(() => stringify(variant("T", [rec([["a", arr([arr([])])]])]), { style, limits: { maxDepth: 2 } })).toThrow(code("nesting-too-deep", [0, "a", 0]))
    }
    // Pretty: on one line where it fits, broken over lines where it doesn't, checked the same.
    const wide = arr([str("x".repeat(100)), rec([["k", variant("A" + "b".repeat(100))]])])
    expect(() => stringify(wide, { limits: four })).toThrow(code("string-too-long", [0]))
    expect(() => stringify(wide, { limits: { maxStringLength: 100 } })).toThrow(code("tag-too-long", [1, "k"]))
    expect(stringify(wide, { limits: { maxStringLength: 101, maxNodes: 4 } })).toContain("Abbb")
    expect(() => stringify(wide, { limits: { maxStringLength: 101, maxNodes: 3 } })).toThrow(code("too-many-nodes", []))
  })

  it("a value of more than a million values written: counted all once, written if within the node limit", () => {
    // shared(20): 2^21 - 1 values written.
    expect(stringify(shared(20), { style: "minimised" })).toHaveLength(4 * 2 ** 20 - 3)
    expect(() => stringify(shared(20), { style: "minimised", limits: { maxNodes: 2 ** 21 - 2 } })).toThrow(code("too-many-nodes", []))
    expect(() => format([num("1"), shared(20)], { limits: { maxNodes: 2 ** 21 - 2 } })).toThrow(code("too-many-nodes", [1]))
  })
})

describe("the canonical form and hashing: only the node limit (spec §12)", () => {
  it("no other limit: deeper or longer than a writer's limits still has a canonical form", () => {
    const deep = Array.from({ length: 300 }).reduce<Value>((v) => arr([v]), num("1"))
    expect(canonical(deep)).toHaveLength(601)
    expect(canonical(num("1e99999"))).toBe("1e99999")
    expect(() => stringify(deep)).toThrow(code("nesting-too-deep"))
  })

  it("the node limit, configurable", { timeout: 60_000 }, async () => {
    expect(canonical(shared(3), { maxNodes: 15 })).toBe("[[[1,1],[1,1]],[[1,1],[1,1]]]")
    expect(() => canonical(shared(3), { maxNodes: 14 })).toThrow(code("too-many-nodes", []))
    expect(() => canonical(shared(64))).toThrow(code("too-many-nodes", []))
    expect(() => equals(shared(64), num("1"), { maxNodes: 1000 })).toThrow(code("too-many-nodes", []))
    expect(() => compare(shared(64), num("1"), { maxNodes: 1000 })).toThrow(code("too-many-nodes", []))
    // The message says which operand (spec §12).
    expect(() => equals(num("1"), shared(64))).toThrow(/second/)
    expect(() => compare(shared(64), num("1"))).toThrow(/first/)
    expect(equals(shared(3), parse("[[[1,1],[1,1]],[[1,1],[1,1]]]"), { maxNodes: 15 })).toBe(true)
    await expect(hash(shared(64), { maxNodes: 1000 })).rejects.toThrow(code("too-many-nodes", []))
    expect(await hash(shared(3), { maxNodes: 15 })).toBe(await hash(parse("[[[1,1],[1,1]],[[1,1],[1,1]]]")))
    // Each value on its own, at its index.
    expect(await hashAll([shared(3), shared(3)], { maxNodes: 15 })).toMatch(/^[0-9a-f]{64}$/)
    await expect(hashAll([num("1"), shared(3)], { maxNodes: 14 })).rejects.toThrow(code("too-many-nodes", [1]))
  })
})
