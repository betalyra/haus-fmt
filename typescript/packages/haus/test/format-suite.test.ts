/**
 * The format conformance suite (test-suite/format/README.md): every input,
 * formatted in the pretty, the compact and the minimised layout, must give
 * the expected files byte for byte, and formatting the output again must
 * change nothing.
 *
 * The TypeScript formatter is the reference: run with HAUS_UPDATE_FORMAT=1 to
 * (re)write the expected files from it, then review the diff against spec §11.
 */
import { describe, expect, it } from "@effect/vitest"
import { Arbitrary, Schema } from "effect"
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { arr, format, parseAll, parseDocument, rec, str, variant, type FormatOptions, type FormatStyle, type Value } from "../src/index.js"
import { suiteJson } from "./suite-json.js"

const SUITE = join(import.meta.dirname, "../../../../test-suite")
const FORMAT = join(SUITE, "format")
const UPDATE = process.env["HAUS_UPDATE_FORMAT"] === "1"
const STYLES = ["pretty", "compact", "minimised"] as const satisfies readonly FormatStyle[]

interface Case {
  readonly name: string
  readonly input: string
  /** Where NAME.pretty, NAME.compact, NAME.minimised (and NAME.options) are, without the extension. */
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

/** The options a case record gives: `indent` and `width` (numbers) and `stream` (`True` or `False`); unset ones are left out. */
const givenOptions = (fields: ReadonlyMap<string, Value>): FormatOptions => {
  const int = (k: string) => {
    const v = fields.get(k)
    return v?.kind === "number" ? { [k]: Number(v.text) } : {}
  }
  const stream = fields.get("stream")
  if (stream !== undefined && !(stream.kind === "variant" && stream.args.length === 0 && (stream.tag === "True" || stream.tag === "False"))) {
    throw new Error("stream: expected True or False")
  }
  return { ...int("indent"), ...int("width"), ...(stream === undefined ? {} : { stream: stream.tag === "True" }) }
}

/** NAME.options: a record `{ indent: 4, width: 40 }` or `{ stream: True }`, applied to every layout. */
const optionsOf = (c: Case): FormatOptions => {
  const file = `${c.expected}.options`
  if (!existsSync(file)) return {}
  const [options] = parseAll(readFileSync(file, "utf8"))
  if (options?.kind !== "record") throw new Error(`${file}: expected a record`)
  return givenOptions(options.fields)
}

/** Reformat a document in `style`, keeping comments where the layout does. */
const run = (text: string, options: FormatOptions, style: FormatStyle) => {
  const { values, comments } = parseDocument(text)
  return format(values, { ...options, style, source: text, comments })
}

const same = (a: string, b: string) => expect(parseAll(a).map(suiteJson)).toEqual(parseAll(b).map(suiteJson))

/** What an editor that trims trailing whitespace makes of a text. */
const trimLines = (text: string) => text.replace(/[ \t]+$/gm, "")

/** The offsets of the last character of the lines that end in a space or tab outside a comment. */
const trailingBlanks = (text: string): number[] => {
  const { comments } = parseDocument(text)
  const inComment = (i: number) => comments.some(([s, e]) => s <= i && i < e)
  return [...text.matchAll(/[ \t](?=\n|$)/g)].map((m) => m.index).filter((i) => !inComment(i))
}

const withoutBlankLines = (text: string) => text.split("\n").filter((l) => l !== "").join("\n")

describe("format suite", () => {
  it("has cases", () => {
    expect(cases.length).toBeGreaterThan(0)
  })

  for (const style of STYLES) {
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
        same(out, input)
        // Strings never carry a raw line or paragraph separator (spec §11);
        // comments, kept by pretty, may.
        if (style !== "pretty") expect(out).not.toMatch(/[\u2028\u2029]/)
      })
    })
  }

  describe("minimised", () => {
    it.each(cases)("$name has no whitespace between tokens", (c) => {
      const out = run(decode(readFileSync(c.input)), optionsOf(c), "minimised")
      // Outside strings and byte strings, every space or tab is gone.
      const outside = out.replace(/x?"(?:[^"\\]|\\.)*"/g, "")
      expect(outside).not.toMatch(/[ \t]/)
    })

    it.each(cases)("$name, formatted as pretty, is the pretty file without comments and blank lines", (c) => {
      const input = decode(readFileSync(c.input))
      const options = optionsOf(c)
      const back = run(run(input, options, "minimised"), options, "pretty")
      expect(back).toBe(run(run(input, options, "compact"), options, "pretty"))
      const { values } = parseDocument(input)
      const withoutComments = format(values, { ...options, style: "pretty", source: input, comments: [] })
      expect(withoutBlankLines(back)).toBe(withoutBlankLines(withoutComments))
    })
  })

  describe("pretty survives trimming trailing whitespace (spec §11)", () => {
    it.each(cases)("$name", (c) => {
      const input = decode(readFileSync(c.input))
      const out = run(input, optionsOf(c), "pretty")
      expect(trailingBlanks(out)).toEqual([])
      same(trimLines(out), input)
    })

    // Strings made of pieces that end lines in blanks, next to the characters a block string escapes.
    const piece = Arbitrary.schema(Schema.Literals(["a", "é", "😀", " ", "  ", "\t", " \t", "\n", "\r\n", "\r", '"', '""', '"""', "\\", "\u2028", "\u2029", "\u0001", "\u202e", "\\u{20}"]))
    const text = Arbitrary.map(Arbitrary.array(piece, { maxLength: 24 }), (pieces) => pieces.join(""))

    it.prop("generated strings", [text], ([s]) => {
      const values: Value[] = [str(s), rec(new Map<string, Value>([["note", str(s)], ["list", arr([str(s), str(`${s}\n`)])]])), variant("Note", [str(s), str(s)])]
      for (const out of [format(values), format(values.slice(0, 1)), format(values.slice(1, 2), { indent: 4 })]) {
        expect(trailingBlanks(out)).toEqual([])
        const back = parseAll(trimLines(out)).map(suiteJson)
        expect(back).toEqual(parseAll(out).map(suiteJson))
      }
      expect(parseAll(trimLines(format(values))).map(suiteJson)).toEqual(values.map(suiteJson))
      for (const style of STYLES) {
        const out = format(values, { style })
        expect(format(parseAll(out), { style })).toBe(out)
        expect(run(out, {}, style)).toBe(out)
        expect(parseAll(out).map(suiteJson)).toEqual(values.map(suiteJson))
      }
    }, { arbitrary: { runs: 500 } })
  })
})

/** options.cases.haus: the pretty layout's indent and width, 0 and negative, and the stream option (spec §11). */
describe("format options", () => {
  const options = parseAll(readFileSync(join(FORMAT, "options.cases.haus"), "utf8")).map((v) => {
    if (v.kind !== "record") throw new Error("expected a record")
    const input = v.fields.get("input")
    const result = v.fields.get("result")
    if (input?.kind !== "string" || result?.kind !== "variant") throw new Error("not a case")
    const ok = result.tag === "Ok" && result.args[0]?.kind === "string" ? result.args[0].value : undefined
    const options = givenOptions(v.fields)
    return { input: input.value, options, ok, name: `${JSON.stringify(input.value)} ${JSON.stringify(options)}` }
  })
  it.each(options)("$name", ({ input, options, ok }) => {
    const out = () => run(input, options, "pretty")
    if (ok === undefined) expect(out).toThrow()
    else {
      expect(out()).toBe(ok)
      // The inputs have no comments: the writer of values gives the same text.
      expect(format(parseAll(input), options)).toBe(ok)
    }
  })
})
