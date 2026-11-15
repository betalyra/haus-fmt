/** The schema conformance suite (test-suite/schema, spec §14, §15). */
import { describe, expect, it } from "@effect/vitest"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { canonical, compileSchemaFile, errorCode, HausSchemaFileError, parseAll, withoutAttributes, type Value } from "../src/index.js"
import * as h from "../src/schema.js"

const DIR = join(import.meta.dirname, "../../../../test-suite/schema")

interface Case {
  readonly ok: boolean
  readonly type: string
  readonly input: Value
  readonly output: Value
  /** For `Err`: the error code (spec §17). */
  readonly code: string | undefined
  readonly name: string
}

/** The cases of one file: `Ok { type, input, output? }` and `Err { type, input }`. */
export const schemaCases = (text: string): Case[] =>
  parseAll(text).map((v) => {
    if (v.kind !== "variant" || (v.tag !== "Ok" && v.tag !== "Err") || v.args[0]?.kind !== "record") throw new Error(`not a case: ${canonical(v)}`)
    const f = v.args[0].fields
    const type = f.get("type")
    const input = f.get("input")
    if (type?.kind !== "string" || input === undefined) throw new Error(`not a case: ${canonical(v)}`)
    const code = f.get("code")
    if (v.tag === "Err" && code?.kind !== "string") throw new Error(`an Err case without a code: ${canonical(v)}`)
    return {
      ok: v.tag === "Ok", type: type.value, input, output: f.get("output") ?? input,
      code: code?.kind === "string" ? code.value : undefined, name: `${v.tag} ${type.value} ${canonical(input)}`,
    }
  })

const suites = readdirSync(DIR).filter((f) => f.endsWith(".schema.haus")).map((f) => f.replace(".schema.haus", ""))

const run = (schemas: Readonly<Record<string, h.Schema<unknown>>>, c: Case) => {
  const schema = schemas[c.type]
  if (!schema) throw new Error(`no type ${c.type}`)
  if (c.ok) expect(canonical(h.encode(schema, h.decode(schema, c.input)))).toBe(canonical(c.output))
  else {
    expect(() => h.decode(schema, c.input)).toThrow(h.HausDecodeError)
    try {
      h.decode(schema, c.input)
    } catch (e) {
      expect(errorCode(e)).toBe(c.code)
    }
  }
}

describe.each(suites)("%s", (suite) => {
  const text = readFileSync(join(DIR, `${suite}.schema.haus`), "utf8")
  const cases = schemaCases(readFileSync(join(DIR, `${suite}.cases.haus`), "utf8"))
  const { schemas } = compileSchemaFile(text)
  it.each(cases)("$name", (c) => run(schemas, c))

  // Attributes don't matter (spec §15): the same results without them. Only
  // files that have attributes; for the others the text is the same.
  const stripped = withoutAttributes(text)
  if (stripped !== text) {
    describe("without attributes", () => {
      const plain = compileSchemaFile(stripped).schemas
      it("has no attributes left", () => expect(withoutAttributes(stripped)).toBe(stripped))
      it.each(cases)("$name", (c) => run(plain, c))
    })
  }
})

const INVALID = join(DIR, "invalid")
const invalid = readdirSync(INVALID).filter((f) => f.endsWith(".schema.haus"))

describe("invalid", () => {
  it.each(invalid)("%s is rejected with the code in NAME.error", (file) => {
    const text = readFileSync(join(INVALID, file), "utf8")
    expect(() => compileSchemaFile(text)).toThrow(HausSchemaFileError)
    try {
      compileSchemaFile(text)
    } catch (e) {
      expect(errorCode(e)).toBe(readFileSync(join(INVALID, file.replace(/\.schema\.haus$/, ".error")), "utf8").trim())
    }
  })
})
