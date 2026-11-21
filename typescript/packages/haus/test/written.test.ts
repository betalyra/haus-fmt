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

  it("each value of a stream on its own, its errors at its index", () => {
    expect(format([shared(3), shared(3)], { style: "compact", limits: { maxNodes: 15 } })).toBe("[[[1, 1], [1, 1]], [[1, 1], [1, 1]]],\n[[[1, 1], [1, 1]], [[1, 1], [1, 1]]],\n")
    expect(() => format([num("1"), shared(3)], { limits: { maxNodes: 14 } })).toThrow(code("too-many-nodes", [1]))
    expect(() => format([num("1"), arr([str("abcde")])], { limits: { maxStringLength: 4 } })).toThrow(code("string-too-long", [1, 0]))
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
    expect(() => equals(shared(64), num("1"), { maxNodes: 1000 })).toThrow(code("too-many-nodes"))
    expect(() => compare(shared(64), num("1"), { maxNodes: 1000 })).toThrow(code("too-many-nodes"))
    expect(equals(shared(3), parse("[[[1,1],[1,1]],[[1,1],[1,1]]]"), { maxNodes: 15 })).toBe(true)
    await expect(hash(shared(64), { maxNodes: 1000 })).rejects.toThrow(code("too-many-nodes", []))
    expect(await hash(shared(3), { maxNodes: 15 })).toBe(await hash(parse("[[[1,1],[1,1]],[[1,1],[1,1]]]")))
    // Each value on its own, at its index.
    expect(await hashAll([shared(3), shared(3)], { maxNodes: 15 })).toMatch(/^[0-9a-f]{64}$/)
    await expect(hashAll([num("1"), shared(3)], { maxNodes: 14 })).rejects.toThrow(code("too-many-nodes", [1]))
  })
})
