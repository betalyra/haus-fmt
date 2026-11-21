/** The positions suite (test-suite/positions, spec §8): the code, line and column of an error. */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { canonical, HausSyntaxError, parse, parseAll, type Value } from "../src/index.js"

const CASES = join(import.meta.dirname, "../../../../test-suite/positions/cases.haus")

const field = (v: Value, key: string): Value | undefined => (v.kind === "record" ? v.fields.get(key) : undefined)

const cases = parseAll(readFileSync(CASES, "utf8")).map((v) => {
  const text = field(v, "text")
  const code = field(v, "code")
  const line = field(v, "line")
  const column = field(v, "column")
  if (text?.kind !== "string" || code?.kind !== "string" || line?.kind !== "number" || column?.kind !== "number") throw new Error(`not a case: ${canonical(v)}`)
  // `document: True`: the text is one document (`parse`), not a sequence of values.
  const document = field(v, "document")
  return { text: text.value, document: document?.kind === "variant" && document.tag === "True", want: `${code.value} ${line.text}:${column.text}` }
})

describe("positions suite", () => {
  it("has cases", () => expect(cases.length).toBeGreaterThan(0))
  it.each(cases)("$text", ({ text, document, want }) => {
    let got = "parsed"
    try {
      if (document) parse(text)
      else parseAll(text)
    } catch (e) {
      got = e instanceof HausSyntaxError ? `${e.code} ${e.line}:${e.column}` : String(e)
    }
    expect(got).toBe(want)
  })
})

// The suite has no case for it yet (spec §8): after the opening quotes and their blanks, or at the end of the input.
describe("block-string-opening", () => {
  it.each([['"""', 1, 4], ['"""x', 1, 4], ['"""  x', 1, 6], ['["""', 1, 5], ['"""  ', 1, 6], ['"""\r', 1, 4]] as const)("%j at %i:%i", (text, line, column) => {
    expect(() => parseAll(text)).toThrow(expect.objectContaining({ code: "block-string-opening", line, column }))
  })
})
