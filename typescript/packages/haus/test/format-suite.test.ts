/**
 * The format conformance suite (test-suite/format/README.md): every input,
 * formatted in the pretty and the compact layout, must give the expected
 * files byte for byte, and formatting the output again must change nothing.
 *
 * The TypeScript formatter is the reference: run with HAUS_UPDATE_FORMAT=1 to
 * (re)write the expected files from it, then review the diff against spec §11.
 */
import { describe, expect, it } from "@effect/vitest"
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { format, parseAll, parseDocument, type FormatOptions } from "../src/index.js"
import { suiteJson } from "./suite-json.js"

const SUITE = join(import.meta.dirname, "../../../../test-suite")
const FORMAT = join(SUITE, "format")
const UPDATE = process.env["HAUS_UPDATE_FORMAT"] === "1"

interface Case {
  readonly name: string
  readonly input: string
  /** Where NAME.pretty, NAME.compact (and NAME.options) are, without the extension. */
  readonly expected: string
}

/** The `.haus` files of `dir`, sorted. */
const hausFiles = (dir: string) =>
  readdirSync(dir)
    .filter((f) => f.endsWith(".haus"))
    .sort()
    .map((f) => f.slice(0, -".haus".length))

const cases: Case[] = [
  ...["cases", "examples"].flatMap((group) =>
    hausFiles(join(FORMAT, group)).map((name) => ({
      name: `${group}/${name}`,
      input: join(FORMAT, group, `${name}.haus`),
      expected: join(FORMAT, group, name),
    }))),
  ...hausFiles(join(SUITE, "valid")).map((name) => ({
    name: `valid/${name}`,
    input: join(SUITE, "valid", `${name}.haus`),
    expected: join(FORMAT, "valid", name),
  })),
]

// The parser skips a byte order mark itself: the decoder must keep it.
const decode = (bytes: Uint8Array) => new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes)

/** NAME.options: a record `{ indent: 4, width: 40 }`, applied to both layouts. */
const optionsOf = (c: Case): FormatOptions => {
  const file = `${c.expected}.options`
  if (!existsSync(file)) return {}
  const [options] = parseAll(readFileSync(file, "utf8"))
  if (options?.kind !== "record") throw new Error(`${file}: expected a record`)
  const int = (k: string) => {
    const v = options.fields.get(k)
    return v?.kind === "number" ? { [k]: Number(v.text) } : {}
  }
  return { ...int("indent"), ...int("width") }
}

const run = (text: string, options: FormatOptions, style: "pretty" | "compact") => {
  const { values, comments } = parseDocument(text)
  return format(values, { ...options, style, source: text, comments })
}

describe("format suite", () => {
  it("has cases", () => {
    expect(cases.length).toBeGreaterThan(0)
  })

  for (const style of ["pretty", "compact"] as const) {
    describe(style, () => {
      it.each(cases)("$name", (c) => {
        const input = decode(readFileSync(c.input))
        const options = optionsOf(c)
        const out = run(input, options, style)
        const file = `${c.expected}.${style}`
        if (UPDATE) writeFileSync(file, out)
        expect(existsSync(file), `${file} is missing: run with HAUS_UPDATE_FORMAT=1`).toBe(true)
        expect(out).toBe(decode(readFileSync(file)))
        // LF line endings only, idempotent, and the same data.
        expect(out).not.toContain("\r")
        expect(run(out, options, style)).toBe(out)
        expect(parseAll(out).map(suiteJson)).toEqual(parseAll(input).map(suiteJson))
      })
    })
  }
})
