/**
 * The schema conformance suite (test-suite/schema, spec §14, §15), through the
 * Effect adapter: each schema file is compiled to Effect schemas, and each
 * case goes haus Value → Effect type (`decodeValue`) → haus Value (`encodeValue`).
 */
import { canonical, errorCode, HausSchemaFileError, parseAll, withoutAttributes, type Value } from "@haus-fmt/haus"
import { describe, expect, it } from "@effect/vitest"
import { Cause, Effect, Exit, Option } from "effect"
import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import * as Haus from "../src/index.js"

const DIR = fileURLToPath(new URL("../../../../test-suite/schema/", import.meta.url))

interface Case {
  readonly ok: boolean
  readonly type: string
  readonly input: Value
  readonly output: Value
  /** For `Err`: the error code (spec §17). */
  readonly code: string | undefined
  /** For `Err`: the place of the error (spec §15), as text: `$.items[2].price`. */
  readonly path: string | undefined
  readonly name: string
}

/** The cases of one file: `Ok { type, input, output? }` and `Err { type, input, code, path }`. */
const schemaCases = (text: string): Case[] =>
  parseAll(text).map((v) => {
    if (v.kind !== "variant" || (v.tag !== "Ok" && v.tag !== "Err") || v.args[0]?.kind !== "record") throw new Error(`not a case: ${canonical(v)}`)
    const f = v.args[0].fields
    const type = f.get("type")
    const input = f.get("input")
    if (type?.kind !== "string" || input === undefined) throw new Error(`not a case: ${canonical(v)}`)
    const code = f.get("code")
    const path = f.get("path")
    if (v.tag === "Err" && code?.kind !== "string") throw new Error(`an Err case without a code: ${canonical(v)}`)
    if (v.tag === "Err" && path?.kind !== "string") throw new Error(`an Err case without a path: ${canonical(v)}`)
    return {
      ok: v.tag === "Ok", type: type.value, input, output: f.get("output") ?? input,
      code: code?.kind === "string" ? code.value : undefined, path: path?.kind === "string" ? path.value : undefined, name: `${v.tag} ${type.value} ${canonical(input)}`,
    }
  })

const suites = readdirSync(DIR).filter((f) => f.endsWith(".schema.haus")).map((f) => f.replace(".schema.haus", ""))

describe.each(suites)("%s", (suite) => {
  const [text, cases] = [readFileSync(`${DIR}${suite}.schema.haus`, "utf8"), schemaCases(readFileSync(`${DIR}${suite}.cases.haus`, "utf8"))]

  const run = (schemas: Haus.CompiledSchemaFile["schemas"]) => (c: Case) => {
    const schema = schemas[c.type]
    if (!schema) throw new Error(`no type ${c.type}`)
    const decoded = Effect.runSyncExit(Haus.decodeValue(schema)(c.input))
    if (!c.ok) {
      expect(Exit.isFailure(decoded) && Exit.hasFails(decoded), "decoding should fail with a HausSchemaError").toBe(true)
      if (Exit.isFailure(decoded)) {
        const error = Cause.findErrorOption(decoded.cause).pipe(Option.getOrUndefined)
        expect(error?.code, error?.message).toBe(c.code)
        expect(error?._tag === "HausSchemaError" ? error.place : undefined, error?.message).toBe(c.path)
      }
      return
    }
    if (Exit.isFailure(decoded)) throw new Error(`decoding failed: ${String(decoded.cause)}`)
    const encoded = Effect.runSync(Haus.encodeValue(schema)(decoded.value))
    expect(canonical(encoded)).toBe(canonical(c.output))
  }

  const { schemas } = Haus.compileSchemaFile(text)
  for (const c of cases) it(c.name, () => run(schemas)(c))

  // Attributes don't matter (spec §15): the same results without them. Only
  // files that have attributes; for the others the text is the same.
  const stripped = withoutAttributes(text)
  if (stripped !== text) {
    describe("without attributes", () => {
      const plain = Haus.compileSchemaFile(stripped).schemas
      for (const c of cases) it(c.name, () => run(plain)(c))
    })
  }
})

const INVALID = `${DIR}invalid/`

describe("invalid", () => {
  it.each(readdirSync(INVALID).filter((f) => f.endsWith(".schema.haus")))("%s is rejected with the code in NAME.error", (file) => {
    const want = readFileSync(`${INVALID}${file.replace(/\.schema\.haus$/, ".error")}`, "utf8").trim()
    // Read as a file is: invalid UTF-8 is the decoder's error (code invalid-utf8), before parsing.
    const compile = () => Haus.compileSchemaFile(new TextDecoder("utf-8", { fatal: true }).decode(readFileSync(`${INVALID}${file}`)))
    expect(compile).toThrow(want === "invalid-utf8" ? TypeError : HausSchemaFileError)
    try {
      compile()
    } catch (e) {
      expect(errorCode(e)).toBe(want)
    }
  })
})
