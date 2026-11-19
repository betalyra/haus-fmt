import { describe, expect, it } from "vitest"
import { hoverAt, hoverContext, hoverMarkdown, hoverText, parseSchemaFile } from "../src/index.js"

const data = `{
  order: 1042,
  total: 30.30,
  status: Shipped { at: Instant("2026-11-08T09:12:00Z") },
}`
const at = (needle: string) => data.indexOf(needle)

describe("hover", () => {
  it("shows the inferred type of a key's value", () => {
    const info = hoverAt(hoverContext(data), at("total"))!
    expect(info.key).toBe("total")
    expect(data.slice(info.start, info.end)).toBe("total")
    expect(hoverText(info)).toBe("total: Decimal")
  })

  it("explains tags of the prelude and std/time", () => {
    const info = hoverAt(hoverContext(data), at("Instant"))!
    expect(data.slice(info.start, info.end)).toBe("Instant")
    expect(hoverText(info)).toBe("Instant\nstd/time: an exact point in time (RFC 3339)")
  })

  it("prefers the schema's type, with the definition's doc comment", () => {
    const file = parseSchemaFile(`
      import std/time (Instant)
      // Where an order is.
      type Status = closed < Pending | Shipped { at: Instant } >
      type Root = { order: Int, total: Decimal, status: Status }
    `)
    const ctx = hoverContext(data, { file, type: "Root" })
    expect(hoverText(hoverAt(ctx, at("status"))!)).toBe("status: Status\nWhere an order is.\ntype Status = closed < Pending | Shipped { at: Instant } >")
    expect(hoverText(hoverAt(ctx, at("order"))!)).toBe("order: Int")
    expect(hoverMarkdown(hoverAt(ctx, at("status"))!)).toContain("type Status = closed <")
  })

  it("shows a recursive type's definition at its tag, and cuts a long one", () => {
    const file = parseSchemaFile(`type Comment = closed < Comment { text: String, replies: Array Comment } >\ntype Root = Comment\ntype Holder = { l: Long }\ntype Long = {\n${Array.from({ length: 20 }, (_, i) => `  f${i}: Int,`).join("\n")}\n}`)
    const text = `Comment { text: "a", replies: [] }`
    const ctx = hoverContext(text, { file, type: "Root" })
    expect(hoverText(hoverAt(ctx, 0)!)).toBe("Comment\ntype Comment = closed < Comment { text: String, replies: Array Comment } >")
    const long = hoverText(hoverAt(hoverContext("{ l: {} }", { file, type: "Holder" }), 2)!).split("\n")
    expect(long.length).toBe(13)
    expect(long.at(-1)).toBe("…")
  })

  it("has nothing outside values", () => {
    expect(hoverAt(hoverContext(data), data.length)).toBeUndefined()
  })
})

describe("number notes", () => {
  const noteOf = (n: string) => hoverAt(hoverContext(`{ n: ${n} }`), 5)?.note
  it("only for numbers a float can't hold exactly", () => {
    expect(noteOf("30.30")).toBeUndefined()
    expect(noteOf("1042")).toBeUndefined()
    expect(noteOf("0.1")).toBeUndefined()
    expect(noteOf("9007199254740993")).toContain("not exact")
    expect(noteOf("0.10000000000000000001")).toContain("not exact")
  })
})
