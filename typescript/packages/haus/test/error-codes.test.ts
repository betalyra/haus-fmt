/**
 * The error catalogue (spec §17, spec/errors.haus): the generated files are
 * up to date, every example has the error it documents, the conformance suite
 * and the Lean reference use only catalogued codes, and errors have their
 * JSON form.
 */
import { describe, expect, it } from "vitest"
import { execFileSync } from "node:child_process"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import {
  checkData, compileSchemaFile, ERROR_CODES, errorCode, errorJson, fromHausJson, HausSyntaxError, isErrorCode, parse, parseAll,
  parseSchemaFile, parseWithLocations, type Value,
} from "../src/index.js"
import * as h from "../src/schema.js"

const ROOT = join(import.meta.dirname, "../../../..")
const read = (path: string) => readFileSync(join(ROOT, path), "utf8")

interface Entry {
  readonly code: string
  readonly example: Value
}

const text = (v: Value | undefined): string => {
  if (v?.kind !== "string") throw new Error("expected a string")
  return v.value
}
const fields = (v: Value) => {
  if (v.kind !== "variant" || v.args[0]?.kind !== "record") throw new Error("expected Tag { … }")
  return v.args[0].fields
}

const catalogue: Entry[] = parseAll(read("spec/errors.haus")).map((v) => {
  const f = fields(v)
  return { code: text(f.get("code")), example: f.get("example")! }
})

/** The code of what `f` throws, or "no error". */
const thrown = (f: () => unknown): string => {
  try {
    f()
  } catch (e) {
    return errorCode(e) ?? `not a haus error: ${String(e)}`
  }
  return "no error"
}

/** The codes an example of the catalogue produces. */
function codesOf(example: Value): string[] | undefined {
  if (example.kind !== "variant") throw new Error("an example is a tag")
  const [arg] = example.args
  switch (example.tag) {
    case "Data":
      return [thrown(() => parseAll(text(arg)))]
    case "Schema": {
      const t = text(arg)
      const error = thrown(() => parseSchemaFile(t))
      return error === "no error" ? parseSchemaFile(t).warnings.map((w) => w.code) : [error]
    }
    case "HausJson":
      return [thrown(() => fromHausJson(text(arg)))]
    case "Decode": {
      const f = fields(example)
      return [thrown(() => h.decode(compileSchemaFile(text(f.get("schema"))).schemas["Root"]!, parse(text(f.get("data")))))]
    }
    case "SchemaJson": {
      const f = fields(example)
      return [thrown(() => h.fromJson(compileSchemaFile(text(f.get("schema"))).schemas["Root"]!, text(f.get("json"))))]
    }
    case "Check": {
      const f = fields(example)
      return checkData(parseSchemaFile(text(f.get("schema"))), "Root", parseWithLocations(text(f.get("data")))).map((i) => i.code)
    }
    case "Text":
      return undefined
  }
  throw new Error(`unknown example kind ${example.tag}`)
}

describe("the catalogue", () => {
  it("generated files are up to date (node spec/scripts/errors.ts)", () => {
    // Throws, with the script's message, when one is out of date.
    execFileSync(process.execPath, [join(ROOT, "spec/scripts/errors.ts"), "--check"], { stdio: "pipe" })
  })

  it("is the TypeScript table", () => {
    expect(Object.keys(ERROR_CODES)).toEqual(catalogue.map((e) => e.code))
  })

  it.each(catalogue.filter((e) => codesOf(e.example) !== undefined))("$code: the example has the error", ({ code, example }) => {
    expect(codesOf(example)).toContain(code)
  })
})

describe("codes in the conformance suite and the Lean reference are in the catalogue", () => {
  const suiteCodes = [
    ...["test-suite/invalid", "test-suite/schema/invalid"].flatMap((dir) =>
      readdirSync(join(ROOT, dir)).filter((f) => f.endsWith(".error")).map((f) => read(`${dir}/${f}`).trim())),
    ...["schema", "json"].flatMap((dir) =>
      readdirSync(join(ROOT, "test-suite", dir)).filter((f) => f.endsWith(".cases.haus"))
        .flatMap((f) => parseAll(read(`test-suite/${dir}/${f}`)))
        .flatMap((v) => (v.kind === "variant" && v.tag === "Err" ? [text(fields(v).get("code"))] : []))),
  ]
  it.each([...new Set(suiteCodes)])("suite: %s", (code) => expect(isErrorCode(code)).toBe(true))

  // `Code.name` in the Lean reference: every string it maps a code to.
  const lean = read("spec/lean/Haus/ErrorCode.lean")
  const leanCodes = [...lean.matchAll(/=> "([a-z0-9-]+)"/g)].map((m) => m[1]!)
  it("Lean has codes", () => expect(leanCodes.length).toBeGreaterThan(30))
  it.each(leanCodes)("Lean: %s", (code) => expect(isErrorCode(code)).toBe(true))
})

describe("the JSON form (spec §17)", () => {
  it("of a syntax error", () => {
    try {
      parseAll("Heartbeat\n{ at: 1 }")
      throw new Error("accepted")
    } catch (e) {
      expect(e).toBeInstanceOf(HausSyntaxError)
      expect(JSON.parse(JSON.stringify(e))).toEqual({
        code: "payload-newline",
        message: "expected ',' between top-level values, found '{'",
        line: 2,
        column: 1,
        expected: "','",
        found: "'{'",
        hint: "Put the payload on the same line as Heartbeat, or add a comma if they are two values.",
        docs: "https://haus-fmt.org/docs/errors#payload-newline",
      })
    }
  })

  it("of a decoding error: the path, and the catalogue's fix as the hint", () => {
    const schema = h.Record({ items: h.Array(h.Record({ price: h.Int })) })
    try {
      h.parse(schema, "{ items: [{ price: 1 }, { price: 1.5 }] }")
      throw new Error("accepted")
    } catch (e) {
      expect(errorJson(e)).toEqual({
        code: "not-an-integer",
        message: "expected Int, found number 1.5",
        path: "$.items[1].price",
        expected: "Int",
        found: "number 1.5",
        hint: ERROR_CODES["not-an-integer"].hint,
        docs: "https://haus-fmt.org/docs/errors#not-an-integer",
      })
    }
  })

  it("of invalid UTF-8 (the platform decoder's TypeError) and of unusable limits", () => {
    let utf8: unknown
    try {
      new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array([0x22, 0xff, 0x22]))
    } catch (e) {
      utf8 = e
    }
    expect(errorJson(utf8)).toMatchObject({ code: "invalid-utf8", docs: "https://haus-fmt.org/docs/errors#invalid-utf8" })
    expect(thrown(() => parseAll("1", { maxDepth: 100_000 }))).toBe("unsupported-depth")
    expect(errorJson(new Error("other"))).toBeUndefined()
  })

  it("schema file errors keep their quick-fix data", () => {
    try {
      parseSchemaFile("type A = { at: Date }")
      throw new Error("accepted")
    } catch (e) {
      expect(errorJson(e)).toMatchObject({ code: "unknown-type", line: 1, column: 16, hint: "Import it with: import std/time (Date)." })
    }
  })
})

describe("wrong-payload names the case (spec §15, §17)", () => {
  const SCHEMA = "type Shape = < Circle { r: Float64 } | Point Float64 Float64 | Empty | Wrap Int >\ntype Root = { shape: Shape, on: Maybe Bool }"
  const decoded = (data: string) => {
    try {
      h.decode(compileSchemaFile(SCHEMA).schemas["Root"]!, parse(data))
    } catch (e) {
      return errorJson(e)
    }
    throw new Error("accepted")
  }
  const checked = (data: string) => checkData(parseSchemaFile(SCHEMA), "Root", parseWithLocations(data))

  it("a record case with one argument that isn't a record: wrong-payload at the variant", () => {
    expect(decoded("{ shape: Circle(1.5), on: None }")).toMatchObject({
      code: "wrong-payload",
      path: "$.shape",
      hint: "Circle takes one argument, a record { r: Float64 }: write `Circle { … }`.",
    })
    expect(checked("{ shape: Circle(1.5), on: None }")).toEqual([
      { severity: "error", code: "wrong-payload", message: "Circle takes one argument, a record", hint: "Circle takes one argument, a record { r: Float64 }: write `Circle { … }`.", path: "$.shape", start: 9, end: 20 },
    ])
  })

  it("positional, bare and prelude cases", () => {
    const cases: [string, string][] = [
      ["{ shape: Point(1), on: None }", "Point takes 2 arguments (Float64, Float64): write `Point(…, …)`."],
      ["{ shape: Point { x: 1, y: 2 }, on: None }", "Point takes 2 arguments (Float64, Float64): write `Point(…, …)`."],
      ["{ shape: Empty(1), on: None }", "Empty takes no payload: write `Empty`."],
      ["{ shape: Wrap, on: None }", "Wrap takes 1 argument (Int): write `Wrap(…)`."],
      ["{ shape: Empty, on: Some }", "Some takes 1 argument (Bool): write `Some(…)`."],
      ["{ shape: Empty, on: Some(True(1)) }", "True takes no payload: write `True`."],
    ]
    for (const [data, hint] of cases) {
      expect(decoded(data), data).toMatchObject({ code: "wrong-payload", hint })
      expect(checked(data).map((i) => [i.code, i.hint]), data).toEqual([["wrong-payload", hint]])
    }
  })
})
