/** The equality suite (test-suite/equality, spec §2, §12): `equals` and `compare`, both ways. */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { canonical, compare, equals, parseAll, type Value } from "../src/index.js"

const CASES = join(import.meta.dirname, "../../../../test-suite/equality/cases.haus")

const field = (v: Value, key: string): Value | undefined => (v.kind === "record" ? v.fields.get(key) : undefined)

const cases = parseAll(readFileSync(CASES, "utf8")).map((v) => {
  const a = field(v, "a")
  const b = field(v, "b")
  const equal = field(v, "equal")
  const order = field(v, "order")
  if (a === undefined || b === undefined || equal?.kind !== "variant" || order?.kind !== "number") throw new Error(`not a case: ${canonical(v)}`)
  return { a, b, equal: equal.tag === "True", order: Number(order.text), name: `${canonical(a)} ${canonical(b)}` }
})

describe("equality suite", () => {
  it("has cases", () => expect(cases.length).toBeGreaterThan(0))
  it.each(cases)("$name", ({ a, b, equal, order }) => {
    expect([equals(a, b), equals(b, a), Math.sign(compare(a, b)), Math.sign(compare(b, a))]).toEqual([equal, equal, order, -order || 0])
  })
})
