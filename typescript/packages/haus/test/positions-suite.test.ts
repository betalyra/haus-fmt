/** The positions suite (test-suite/positions, spec §8): the code, line and column of an error. */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { canonical, HausSyntaxError, parseAll, type Value } from "../src/index.js"

const CASES = join(import.meta.dirname, "../../../../test-suite/positions/cases.haus")

const field = (v: Value, key: string): Value | undefined => (v.kind === "record" ? v.fields.get(key) : undefined)

const cases = parseAll(readFileSync(CASES, "utf8")).map((v) => {
  const text = field(v, "text")
  const code = field(v, "code")
  const line = field(v, "line")
  const column = field(v, "column")
  if (text?.kind !== "string" || code?.kind !== "string" || line?.kind !== "number" || column?.kind !== "number") throw new Error(`not a case: ${canonical(v)}`)
  return { text: text.value, want: `${code.value} ${line.text}:${column.text}` }
})

describe("positions suite", () => {
  it("has cases", () => expect(cases.length).toBeGreaterThan(0))
  it.each(cases)("$text", ({ text, want }) => {
    let got = "parsed"
    try {
      parseAll(text)
    } catch (e) {
      got = e instanceof HausSyntaxError ? `${e.code} ${e.line}:${e.column}` : String(e)
    }
    expect(got).toBe(want)
  })
})
