import { describe, expect, it } from "vitest"
import { parseAll } from "../src/index.js"
import { parsePlain, plainDeclarations, toPlain } from "../src/plain.js"

describe("plain view", () => {
  it("decodes every whole number as a bigint, whatever its size", () => {
    const text = `{ id: 340282366920938463463374607431768211457, n: 1, total: 19.90 },\n{ id: 1, n: 2, total: 5.00 },`
    const [a, b] = toPlain(parseAll(text)) as Array<Record<string, unknown>>
    expect(a).toEqual({ id: 2n ** 128n + 1n, n: 1n, total: "19.90" })
    expect(b).toEqual({ id: 1n, n: 2n, total: "5.00" })
    const types = plainDeclarations(text)
    expect(types).toContain("id: bigint")
    expect(types).toContain("n: bigint")
    expect(types).toContain("total: string")
  })

  it("decodes each number by itself: a value's type never depends on the others", () => {
    const text = `{ x: 1 },\n{ x: 1.5 },`
    expect(toPlain(parseAll(text))).toEqual([{ x: 1n }, { x: "1.5" }])
    expect(plainDeclarations(text)).toContain("x: bigint | string")
  })
})

describe("plain view: Maybe", () => {
  it("is tagged like h.Maybe, so Some(None) stays apart from None", () => {
    const text = `None,\nSome(None),\nSome(Some(1)),`
    expect(toPlain(parseAll(text))).toEqual([
      { _tag: "None" },
      { _tag: "Some", value: { _tag: "None" } },
      { _tag: "Some", value: { _tag: "Some", value: 1n } },
    ])
    const types = plainDeclarations(text)
    expect(types).not.toContain("null")
    expect(types).toContain(`{ readonly _tag: "None" } | { readonly _tag: "Some"; readonly value: { readonly _tag: "None" } | { readonly _tag: "Some"; readonly value: bigint } }`)
    expect(types).toContain("Maybe (Maybe Int)")
  })

  it("None and Some with other payloads are ordinary variants", () => {
    const text = `Some(1, 2),\nNone,`
    expect(toPlain(parseAll(text))).toEqual([{ _tag: "Some", values: [1n, 2n] }, { _tag: "None" }])
    expect(plainDeclarations(text)).not.toContain("Maybe")
  })
})

describe("a payload field named _tag", () => {
  it("is nested, so it can't replace the tag", () => {
    expect(parsePlain("[Circle { _tag: 1, r: 2 }, Circle { r: 3 }]")).toEqual([
      { _tag: "Circle", value: { _tag: 1n, r: 2n } },
      { _tag: "Circle", value: { r: 3n } },
    ])
    expect(parsePlain("Square { side: 1 }")).toEqual({ _tag: "Square", side: 1n })
    expect(plainDeclarations("[Circle { _tag: 1, r: 2 }]")).toContain('readonly value: {')
  })
})
