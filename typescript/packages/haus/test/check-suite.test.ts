/**
 * The checker suite (test-suite/check, spec §14, §15, §16): the warnings of
 * schema files, and the hints and errors of checking data. Both are compared
 * as multisets of (code, place): the line and column of a warning or a
 * syntax error, the path of the others. Data is checked as text, with
 * `checkText`, so a stream is read item by item as the checker reads it.
 */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { canonical, checkText, parseAll, parseSchemaFile, type CheckIssue, type Value } from "../src/index.js"

const CASES = join(import.meta.dirname, "../../../../test-suite/check/cases.haus")

const field = (v: Value, key: string): Value | undefined => (v.kind === "record" ? v.fields.get(key) : undefined)
const str = (v: Value | undefined): string => {
  if (v?.kind !== "string") throw new Error(`not a string: ${v && canonical(v)}`)
  return v.value
}
const items = (v: Value | undefined): readonly Value[] => {
  if (v?.kind !== "array") throw new Error(`not an array: ${v && canonical(v)}`)
  return v.items
}
/** `Tag(a, b, …)` as `Tag a b …`, numbers and strings as their text. */
const show = (v: Value): string => {
  if (v.kind !== "variant") throw new Error(`not an entry: ${canonical(v)}`)
  return [v.tag, ...v.args.map((a) => (a.kind === "string" ? a.value : a.kind === "number" ? a.text : canonical(a)))].join(" ")
}
/** An issue as the suite writes it. */
const entry = (i: CheckIssue): string =>
  i.path === undefined ? `Syntax ${i.code} ${i.line} ${i.column}` : `${i.severity === "hint" ? "Hint" : "Error"} ${i.code} ${i.path}`
/** A multiset, as a sorted list. */
const multiset = (xs: readonly string[]): string[] => [...xs].sort()

const all = parseAll(readFileSync(CASES, "utf8")).map((v) => {
  if (v.kind !== "variant" || (v.tag !== "Schema" && v.tag !== "Data") || v.args[0] === undefined) throw new Error(`not a case: ${canonical(v)}`)
  return { kind: v.tag, fields: v.args[0] }
})

describe("checker suite", () => {
  it("has cases", () => expect(all.length).toBeGreaterThan(0))

  const schemaCases = all.filter((c) => c.kind === "Schema").map(({ fields }) => ({ schema: str(field(fields, "schema")), want: items(field(fields, "warnings")).map(show) }))
  it.each(schemaCases)("schema $schema", ({ schema, want }) => {
    const warnings = parseSchemaFile(schema).warnings.map((w) => `Warning ${w.code} ${w.line} ${w.column}`)
    expect(multiset(warnings)).toEqual(multiset(want))
  })

  const dataCases = all.filter((c) => c.kind === "Data").map(({ fields }) => {
    const first = field(fields, "first")
    return {
      schema: str(field(fields, "schema")), type: str(field(fields, "type")), data: str(field(fields, "data")),
      first: first?.kind === "variant" && first.tag === "True",
      want: items(field(fields, "issues")).map(show),
    }
  })
  it.each(dataCases)("data $data (first: $first)", ({ schema, type, data, first, want }) => {
    const report = checkText(parseSchemaFile(schema), type, data, { first })
    expect(multiset(report.issues.map(entry))).toEqual(multiset(want))
    expect(report.stopped).toBe(false)
  })
})
