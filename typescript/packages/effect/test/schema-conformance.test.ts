/**
 * The schema conformance suite (test-suite/schema, spec §14, §15), through the
 * Effect adapter: each schema file is compiled to Effect schemas
 * (`Haus.compile`), and each case goes haus Value → Effect type
 * (`decodeValue`) → haus Value (`encodeValue`, with `revealSecrets`); then
 * again without `revealSecrets`, which must fail at a secret's place when
 * the case has `secrets` (spec §15, "Encoding a secret").
 */
import { canonical, parseAll, withoutAttributes, type Value } from "@haus-fmt/haus/internal"
import { describe, expect, it } from "@effect/vitest"
import { Cause, Effect, Exit, Option } from "effect"
import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import * as Haus from "../src/index.js"
import { compileText, compileTextEffect, failureOf } from "./support.js"

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
  /** For `Ok`: the places of the secrets in the decoded value (spec §15). */
  readonly secrets: readonly string[]
  readonly name: string
}

/** The cases of one file: `Ok { type, input, output?, secrets? }` and `Err { type, input, code, path }`. */
const schemaCases = (text: string): Case[] =>
  parseAll(text).map((v) => {
    if (v.kind !== "variant" || (v.tag !== "Ok" && v.tag !== "Err") || v.args[0]?.kind !== "record") throw new Error(`not a case: ${canonical(v)}`)
    const f = v.args[0].fields
    const type = f.get("type")
    const input = f.get("input")
    if (type?.kind !== "string" || input === undefined) throw new Error(`not a case: ${canonical(v)}`)
    const code = f.get("code")
    const path = f.get("path")
    const secrets = f.get("secrets")
    if (v.tag === "Err" && code?.kind !== "string") throw new Error(`an Err case without a code: ${canonical(v)}`)
    if (v.tag === "Err" && path?.kind !== "string") throw new Error(`an Err case without a path: ${canonical(v)}`)
    return {
      ok: v.tag === "Ok", type: type.value, input, output: f.get("output") ?? input,
      code: code?.kind === "string" ? code.value : undefined, path: path?.kind === "string" ? path.value : undefined,
      secrets: secrets?.kind === "array" ? secrets.items.map((s) => (s.kind === "string" ? s.value : canonical(s))) : [],
      name: `${v.tag} ${type.value} ${canonical(input)}`,
    }
  })

const suites = readdirSync(DIR).filter((f) => f.endsWith(".schema.haus")).map((f) => f.replace(".schema.haus", ""))

describe.each(suites)("%s", (suite) => {
  const [text, cases] = [readFileSync(`${DIR}${suite}.schema.haus`, "utf8"), schemaCases(readFileSync(`${DIR}${suite}.cases.haus`, "utf8"))]

  const run = (schemas: Haus.CompiledSchema["schemas"]) => (c: Case) => {
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
    const encoded = Effect.runSync(Haus.encodeValue(schema)(decoded.value, { revealSecrets: true }))
    expect(canonical(encoded)).toBe(canonical(c.output))
    // Without revealSecrets: a secret is refused at its place; a value without one encodes as with the option.
    if (c.secrets.length === 0) {
      expect(canonical(Effect.runSync(Haus.encodeValue(schema)(decoded.value)))).toBe(canonical(c.output))
    } else {
      const e = failureOf(Haus.encodeValue(schema)(decoded.value))
      expect(e.code, e.message).toBe("cannot-encode")
      expect(c.secrets, e.message).toContain(e._tag === "HausSchemaError" ? e.place : undefined)
    }
  }

  const { schemas } = compileText(text)
  for (const c of cases) it(c.name, () => run(schemas)(c))

  // Attributes don't matter (spec §15): the same results without them. Only
  // files that have attributes; for the others the text is the same.
  const stripped = withoutAttributes(text)
  if (stripped !== text) {
    describe("without attributes", () => {
      const plain = compileText(stripped).schemas
      for (const c of cases) it(c.name, () => run(plain)(c))
    })
  }
})

const INVALID = `${DIR}invalid/`

describe("invalid", () => {
  it.each(readdirSync(INVALID).filter((f) => f.endsWith(".schema.haus")))("%s is rejected with the code in NAME.error", (file) => {
    const want = readFileSync(`${INVALID}${file.replace(/\.schema\.haus$/, ".error")}`, "utf8").trim()
    const bytes = readFileSync(`${INVALID}${file}`)
    // Read as a file is: invalid UTF-8 is the decoder's error (code invalid-utf8), before parsing.
    if (want === "invalid-utf8") {
      expect(() => new TextDecoder("utf-8", { fatal: true }).decode(bytes)).toThrow(TypeError)
      return
    }
    const e = failureOf(compileTextEffect(new TextDecoder("utf-8", { fatal: true }).decode(bytes)))
    expect(e._tag).toBe("HausCompileError")
    expect(e._tag === "HausCompileError" ? e.code : undefined, e.message).toBe(want)
  })
})
