import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { fileURLToPath } from "node:url"
import { checkData, compileSchemaFile, parseSchemaFile, parseWithLocations } from "../src/index.js"
import * as h from "../src/schema.js"
import { schemaOptions } from "../src/node.js"

const repo = (path: string) => fileURLToPath(new URL(`../../../../${path}`, import.meta.url))
const read = (path: string) => readFileSync(repo(path), "utf8")
/** Options for a schema file of the repo: official extensions come from extensions/. */
const options = (path: string) => schemaOptions(repo(path), { packages: { "@haus-fmt/money": repo("extensions/money") } })

/** Issues as "severity text-at-location: message". */
const issues = (schema: string, data: string, type = "Root") =>
  checkData(parseSchemaFile(schema), type, parseWithLocations(data)).map((i) => `${i.severity} ${data.slice(i.start, i.end)}: ${i.message}`)

describe("checkData", () => {
  it("reports every error by default, and only the first with `first` (spec §14, \"Every error\")", () => {
    const file = parseSchemaFile("type Root = { a: Int, b: String, c: Array Int8, k: Secret { x: Int } }")
    const data = parseWithLocations(`{ nb: 1, a: "x", c: [1, 300, "y"], k: { x: "z" } }`)
    const all = checkData(file, "Root", data)
    expect(all.map((i) => `${i.severity} ${i.code}`)).toEqual([
      "error missing-field", "hint unlisted-field", "error type-mismatch", "error out-of-range", "error type-mismatch", "error invalid-secret",
    ])
    const first = checkData(file, "Root", data, { first: true })
    expect(first.filter((i) => i.severity === "error")).toHaveLength(1)
    // The first error is one of all of them.
    expect(all).toContainEqual(first.find((i) => i.severity === "error"))
    // A secret's error stays one error at the secret, in either mode.
    const secret = checkData(parseSchemaFile("type Root = { k: Secret { x: Int, y: Int } }"), "Root", parseWithLocations(`{ k: { x: "a", y: "b" } }`), { first: true })
    expect(secret.map((i) => i.code)).toEqual(["invalid-secret"])
  })

  it("accepts the examples", () => {
    for (const name of ["thread", "syntax-tour"]) {
      const path = `examples/${name}.schema.haus`
      const found = checkData(parseSchemaFile(read(path), options(path)), "Root", parseWithLocations(read(`examples/${name}.haus`)))
      expect(found.filter((i) => i.severity === "error")).toEqual([])
    }
  })

  it("reports errors at the wrong value", () => {
    const schema = `
      import std/time (Date)
      type Status = closed < Pending | Shipped { tracking: String } >
      type Root = { id: Int, qty: UInt8, day: Date, status: Status, tags: Array String }`
    expect(issues(schema, `{ id: "7", qty: 300, day: Date("2026-02-30"), status: Shiped, tags: ["a", 1] }`)).toEqual([
      `error "7": expected Int, found the string "7"`,
      `error 300: 300 is out of range for UInt8 (0 to 255)`,
      `error "2026-02-30": "2026-02-30" is not a valid Date: 2026-02 has no day 30`,
      `error Shiped: Shiped is not allowed here: expected one of Pending, Shipped. Did you mean Shipped?`,
      `error 1: expected String, found the number 1`,
    ])
    expect(issues(schema, `{ id: 1 }`)[0]).toBe("error {: missing fields qty, day, status, tags")
  })

  it("open types: unknown fields and tags are hints; closed ones are errors", () => {
    const schema = `
      type Line = { product: String, quantity?: UInt8 }
      type Strict = closed { product: String }
      type Theme = < Light | Dark >
      type Root = { line: Line, strict: Strict, theme: Theme }`
    expect(issues(schema, `{ line: { product: "a", quantiy: 2 }, strict: { product: "b", extra: 1 }, theme: Sepia }`)).toEqual([
      "hint quantiy: quantiy is not in the schema; a reader ignores it. Did you mean quantity?",
      "error extra: extra is not a field of this closed record.",
      "hint Sepia: Sepia is not in the schema; a reader keeps it as an unknown value.",
    ])
  })

  it("< > means any tag: no hint for the tags it holds", () => {
    const schema = `
      type Currency = < >
      type Root = { currency: Currency }`
    expect(issues(schema, `{ currency: EUR }`)).toEqual([])
  })

  it("streams, positional payloads, Maybe and recursion", () => {
    const schema = `
      type Point = closed < Point Float64 Float64 >
      type Tree = closed < Node { value: Int, children: Array Tree } >
      type Item = { at: Point, tree: Tree, nick: Maybe String }
      type Root = Stream Item`
    expect(issues(schema, `{ at: Point(1, 2), tree: Node { value: 1, children: [] }, nick: None },\n{ at: Point(1), tree: Node { value: 1, children: [Node { value: "x", children: [] }] }, nick: "n" },`)).toEqual([
      "error Point(1): Point takes 2 arguments (Float64, Float64), found 1",
      `error "x": expected Int, found the string "x"`,
      `error "n": expected None or Some(…) (Maybe String), found the string "n"`,
    ])
  })

  it("a float literal too large for its type is out of range, as when decoding (spec §15)", () => {
    const schema = `type Root = { f64: Float64, f32: Float32 }`
    const codes = (data: string) => checkData(parseSchemaFile(schema), "Root", parseWithLocations(data)).map((i) => `${i.code} ${data.slice(i.start, i.end)}`)
    expect(codes(`{ f64: 1e400, f32: 1e39 }`)).toEqual(["out-of-range 1e400", "out-of-range 1e39"])
    expect(codes(`{ f64: -1.7976931348623159e308, f32: 3.4028236e38 }`)).toEqual(["out-of-range -1.7976931348623159e308", "out-of-range 3.4028236e38"])
    // The largest values, NaN and the infinities are fine; a tiny number rounds to zero.
    expect(codes(`{ f64: 1.7976931348623157e308, f32: 3.4028235e38 }`)).toEqual([])
    expect(codes(`{ f64: Infinity, f32: NaN }`)).toEqual([])
    expect(codes(`{ f64: 1e-400, f32: -1e-50 }`)).toEqual([])
    expect(issues(schema, `{ f64: 1e400, f32: 1 }`)).toEqual(["error 1e400: 1e400 is too large for Float64"])
  })

  it("a Decimal may be written in hex or binary: the same number (spec §2), decoded alike", () => {
    const schema = `type Root = { d: Decimal, e: Decimal, f: Decimal }`
    const data = `{ d: 0xFF, e: -0b101, f: 1_000.50 }`
    expect(issues(schema, data)).toEqual([])
    expect(h.decode(compileSchemaFile(schema).schemas.Root!, parseWithLocations(data)[0]!)).toEqual({ d: "255", e: "-5", f: "1000.50" })
    expect(issues(schema, `{ d: "0xFF", e: 1, f: 1 }`)).toEqual([`error "0xFF": expected Decimal, found the string "0xFF"`])
  })
})

describe("@deprecated hints (spec §14)", () => {
  const schema = `
    type Root = { lines: Array Line }
    type Line = { @deprecated("use quantity") count?: Int, quantity?: Int, shape?: Shape }
    type Shape = < Circle { r: Float64 } | @deprecated("use Circle") Round Float64 >
  `
  const located = (data: string) =>
    checkData(parseSchemaFile(schema), "Root", parseWithLocations(data)).map((i) => [i.severity, i.code, data.slice(i.start, i.end)])

  it("are at the field (its name in the data, as unlisted-field is) or at the tagged value's tag, wherever they are", () => {
    const data = `{ lines: [{ quantity: 1 }, { count: 2, extra: 1, shape: Round(1.5) }] }`
    expect(located(data)).toEqual([
      ["hint", "deprecated", "count"],
      ["hint", "unlisted-field", "extra"],
      ["hint", "deprecated", "Round"],
    ])
  })
})
