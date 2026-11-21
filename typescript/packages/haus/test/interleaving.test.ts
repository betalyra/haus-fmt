/**
 * JavaScript runs one call at a time, so threads can't race here; what can
 * go wrong is state a call leaves behind. The module-level caches (a
 * schema's compiled reader and writer, generated code, JSON forms, limits)
 * are filled once per schema and settled whatever the outcome; parsing,
 * writing and formatting keep their state in the call. These tests make
 * the first use of fresh schemas a call that throws halfway, and interleave
 * async streams over one schema, and expect what clean, sequential calls
 * give.
 */
import { describe, expect, it } from "@effect/vitest"
import { canonical, compileSchemaFile, format, hash, parseAll, parseDocument, stringify as stringifyValue, toHausJson, type Value } from "../src/index.js"
import * as h from "../src/schema.js"

const SCHEMA = `
import std/time (Instant, Date)
type Order = { id: Int, total: Decimal, placed: Instant, due?: Date, items: Array Item, status: Status, note: Maybe String, tags: Map Int, key: Secret String }
type Item = { sku: String, price: Float64, qty: Int }
type Status = < Open | Shipped Date | Cancelled { reason: String } >
`

const TEXT = `// two orders
{ id: 0x10, total: 19.90, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: 0.10, qty: 2 }], status: Shipped(Date("2026-01-03")), note: Some("leave at door"), tags: { a: 1, b: 2 }, key: "k1", extra: "x" },
{ id: 17, total: 1, placed: Instant("2026-01-02T03:04:05+01:00"), due: Date("2026-02-01"), items: [], status: Cancelled { reason: "late" }, note: None, tags: {}, key: "k2" },
`

/** Calls that throw halfway through a value: a syntax error, a type error deep inside, nesting beyond the limit, an encode error. */
const failing = (Order: h.Schema<unknown>): ReadonlyArray<() => unknown> => [
  () => h.parse(Order, '{ id: 1, total: 1, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: 1, qty: 1 }, { sku: '),
  () => h.parse(Order, '{ id: 1, total: 1, placed: Instant("2026-01-02T03:04:05Z"), items: [{ sku: "A1", price: "0.10", qty: 1 }], status: Open, note: None, tags: {}, key: "k" }'),
  () => h.parse(Order, TEXT.split("\n")[1]!.slice(0, -1), { maxDepth: 2 }),
  () => h.stringify(Order, { id: 1n, total: "1", placed: "2026-01-02T03:04:05Z", items: [{ sku: "A1", price: "no", qty: 1n }] }, { style: "minimised" }),
  () => h.fromJson(Order, '{"id":"1","total":"1","placed":"2026-01-02T03:04:05Z","items":[{"sku":"A1","price":"x","qty":"1"}]'),
  () => parseDocument("{ a: [1, 2, { b: "),
  () => parseAll('[1, 2, 3, { a: 1, a: 2 }]'),
]

const STYLES = ["pretty", "compact", "minimised"] as const

/** Every operation once on a schema: what each gave. */
const everything = (Order: h.Schema<unknown>, between: () => void = () => {}): string[] => {
  const out: string[] = []
  const add = (f: () => unknown) => {
    between()
    try {
      const r = f()
      out.push(typeof r === "string" ? r : canonical(h.encode(Order, r)))
    } catch (e) {
      out.push(`error ${String(e)}`)
    }
  }
  const values: Value[] = parseAll(TEXT)
  for (const style of STYLES) {
    add(() => {
      const { values, comments } = parseDocument(TEXT)
      return format(values, { style, width: 40, source: TEXT, comments })
    })
    add(() => format(values, { style, width: 40 }))
    add(() => values.map((v) => stringifyValue(v, { style })).join(""))
  }
  for (const [i, v] of values.entries()) {
    const line = TEXT.split("\n")[i + 1]!.slice(0, -1)
    add(() => canonical(v))
    add(() => toHausJson(v))
    add(() => h.decode(Order, v))
    add(() => h.parse(Order, line))
    add(() => h.toJson(Order, h.parse(Order, line)))
    add(() => h.fromJson(Order, h.toJson(Order, h.parse(Order, line))))
    for (const style of STYLES) add(() => h.stringify(Order, h.parse(Order, line), { style }))
  }
  return out
}

const fresh = (optimize: boolean): h.Schema<unknown> => {
  const Order = compileSchemaFile(SCHEMA).schemas["Order"] as h.Schema<unknown>
  return optimize ? h.optimize(Order) : Order
}

describe("no call leaves state behind", () => {
  for (const optimize of [false, true]) {
    it(optimize ? "with generated code" : "with the closures", () => {
      const want = everything(fresh(optimize))
      expect(want.filter((r) => r.startsWith("error"))).toEqual([])
      // A fresh schema whose first uses, and every use after, follow calls that throw halfway.
      const Order = fresh(optimize)
      const calls = failing(Order)
      let n = 0
      const got = everything(Order, () => {
        expect(calls[n++ % calls.length]!).toThrow()
      })
      expect(got).toEqual(want)
      // And the shared schema of the first run gives the same again.
      expect(everything(fresh(optimize))).toEqual(want)
    })
  }

  it("async streams over one schema, interleaved chunk by chunk", async () => {
    const Order = fresh(false)
    const want = [...parseAll(TEXT)].map((v) => canonical(h.encode(Order, h.decode(Order, v))))
    async function* chunks(): AsyncGenerator<string> {
      for (let i = 0; i < TEXT.length; i += 7) {
        await Promise.resolve()
        yield TEXT.slice(i, i + 7)
      }
    }
    const read = async (): Promise<string[]> => {
      const out: string[] = []
      for await (const order of h.decodeStream(Order, chunks())) out.push(canonical(h.encode(Order, order)))
      return out
    }
    const results = await Promise.all(Array.from({ length: 8 }, read))
    for (const r of results) expect(r).toEqual(want)
    const hashes = await Promise.all(Array.from({ length: 8 }, () => Promise.all(parseAll(TEXT).map(hash))))
    for (const r of hashes) expect(r).toEqual(hashes[0])
  })
})
