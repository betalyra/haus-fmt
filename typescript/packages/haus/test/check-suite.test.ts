/**
 * The checker suite (test-suite/check, spec §14, §15, §16): the warnings of
 * schema files, and the hints and errors of checking data. `checkData` gives
 * spans, not paths, so `Data` cases compare the severity and code of each
 * issue, in the order of their places, and not the path.
 */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { canonical, checkData, parseAll, parseSchemaFile, parseWithLocations, type Value } from "../src/index.js"

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
/** `Tag(a, b, …)` as `tag a b …`, numbers and strings as their text. */
const show = (v: Value): string => {
  if (v.kind !== "variant") throw new Error(`not an entry: ${canonical(v)}`)
  return [v.tag, ...v.args.map((a) => (a.kind === "string" ? a.value : a.kind === "number" ? a.text : canonical(a)))].join(" ")
}

const all = parseAll(readFileSync(CASES, "utf8")).map((v) => {
  if (v.kind !== "variant" || (v.tag !== "Schema" && v.tag !== "Data") || v.args[0] === undefined) throw new Error(`not a case: ${canonical(v)}`)
  return { kind: v.tag, fields: v.args[0] }
})

describe("checker suite", () => {
  it("has cases", () => expect(all.length).toBeGreaterThan(0))

  const schemaCases = all.filter((c) => c.kind === "Schema").map(({ fields }) => ({ schema: str(field(fields, "schema")), want: items(field(fields, "warnings")).map(show) }))
  it.each(schemaCases)("schema $schema", ({ schema, want }) => {
    const warnings = [...parseSchemaFile(schema).warnings].sort((a, b) => a.offset - b.offset)
    expect(warnings.map((w) => `Warning ${w.code} ${w.line} ${w.column}`)).toEqual(want)
  })

  const dataCases = all.filter((c) => c.kind === "Data").map(({ fields }) => ({
    schema: str(field(fields, "schema")), type: str(field(fields, "type")), data: str(field(fields, "data")),
    // Without the path: checkData gives spans.
    want: items(field(fields, "issues")).map((i) => show(i).split(" ").slice(0, 2).join(" ")),
  }))
  it.each(dataCases)("data $data", ({ schema, type, data, want }) => {
    const issues = [...checkData(parseSchemaFile(schema), type, parseWithLocations(data))].sort((a, b) => a.start - b.start)
    expect(issues.map((i) => `${i.severity === "hint" ? "Hint" : "Error"} ${i.code}`)).toEqual(want)
  })
})
