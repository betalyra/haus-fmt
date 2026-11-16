/**
 * The formatter fuzzer's generator (format-gen.ts) and its checks of spec
 * §11 (format.ts): the documents are mostly valid haus with comments in
 * every place the formatter treats differently, and the checks pass the
 * format suite's expected files and catch what breaks the rules.
 *
 *   node --test fuzz/src/
 */
import assert from "node:assert/strict"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { parseAll } from "../../typescript/packages/haus/dist/index.js"
import { document, sprinkle } from "./format-gen.ts"
import { commentTexts, layoutFailures, layoutRules, mask, trailingBlanks, type Options, type Style } from "./format.ts"
import { Rng } from "./generate.ts"

const DEFAULT: Options = { indent: 2, width: 80 }
const docs = (seed: number, n: number) => {
  const r = new Rng(seed)
  return Array.from({ length: n }, () => document(r))
}

test("documents are repeatable and mostly valid", () => {
  assert.deepEqual(docs(7, 20), docs(7, 20))
  const valid = docs(1, 500).filter((t) => {
    try {
      parseAll(t)
      return true
    } catch {
      return false
    }
  })
  assert.ok(valid.length > 450, `${valid.length} of 500 valid`)
})

test("documents have comments in every place the formatter treats differently", () => {
  const all = docs(2, 2000)
  const comment = String.raw`(?:\/\*[^]*?\*\/|\/\/[^\n]*\n)`
  const places: Record<string, RegExp> = {
    "on its own line": new RegExp(String.raw`\n[ \t]*${comment}`),
    "after an entry's comma": new RegExp(String.raw`, ?${comment}`),
    "before a closing bracket": new RegExp(String.raw`${comment}\s*[\]})]`),
    "between a key and its value": new RegExp(String.raw`(?:[a-z_]|")\s*${comment}\s*:|:\s*${comment}`),
    "inside Tag( … ) outside the braces": new RegExp(String.raw`[A-Z]\w*\s*\(\s*${comment}\s*\{`),
    "between top-level items": new RegExp(String.raw`^[^]*?\n,\s*${comment}|^[^\n]*,[ \t]*\/\/`),
    "blank line": /\n[ \t]*\r?\n/,
    "CR LF": /\r\n/,
    "byte order mark": /^\uFEFF/,
    "spelling 0xFF_ff": /0xFF_ff/,
    "block string with a blank at a line's end": /"""[^]*?[ \t]\r?\n[^]*?"""/,
    "stream": /,\s*\S/,
  }
  for (const [place, re] of Object.entries(places)) assert.ok(all.some((t) => re.test(t)), place)
})

test("sprinkle inserts whitespace and comments, repeatably", () => {
  const text = "{ a: [1, 2], b: Tag(3) }"
  const once = sprinkle(new Rng(3), text)
  assert.equal(sprinkle(new Rng(3), text), once)
  assert.ok(once.length > text.length)
})

test("comment texts, trailing blanks and masks", () => {
  const text = "[ // a\r\n  1, /* b\r\n c */\n]"
  assert.deepEqual(commentTexts(text), ["// a", "/* b\n c */"])
  assert.deepEqual(trailingBlanks("[\n  1, \n  2, // x \n]\n"), [6])
  assert.equal(mask("ab/*c*/d", [[2, 7]], "c"), "abcccccd")
})

/** The format suite's expected files: every one keeps the rules the fuzzer checks. */
test("the format suite's expected files keep the rules", () => {
  const suite = new URL("../../test-suite/format", import.meta.url).pathname
  let checked = 0
  for (const group of ["cases", "examples", "valid"]) {
    const dir = join(suite, group)
    for (const f of readdirSync(dir).filter((f) => f.endsWith(".pretty"))) {
      const name = join(dir, f.slice(0, -".pretty".length))
      const options = existsSync(`${name}.options`) ? optionsOf(readFileSync(`${name}.options`, "utf8")) : DEFAULT
      for (const style of ["pretty", "compact", "minimised"] as const satisfies readonly Style[]) {
        const out = readFileSync(`${name}.${style}`, "utf8")
        assert.deepEqual(layoutRules(style, out, options), [], `${group}/${f} ${style}`)
        if (group !== "valid") {
          const input = new TextDecoder("utf-8", { ignoreBOM: true }).decode(readFileSync(`${name}.haus`))
          assert.deepEqual(layoutFailures(style, input, out, options), [], `${group}/${f} ${style}`)
        }
        checked++
      }
    }
  }
  assert.ok(checked > 150)
})

function optionsOf(text: string): Options {
  const [v] = parseAll(text)
  const int = (k: string, d: number) => {
    const x = v?.kind === "record" ? v.fields.get(k) : undefined
    return x?.kind === "number" ? Number(x.text) : d
  }
  return { indent: int("indent", 2), width: int("width", 80) }
}

test("the checks catch what breaks the rules", () => {
  const rules = (style: Style, out: string, options = DEFAULT) => layoutRules(style, out, options).map(([check]) => check)
  assert.deepEqual(rules("pretty", "Point(\n  1,\n  2,\n)\n"), ["width"])
  assert.deepEqual(rules("pretty", 'Point("aaaaaaaaaaaaaaaaaaaa", 2)\n', { indent: 2, width: 20 }), ["width"])
  assert.deepEqual(rules("pretty", "[1, 2]\n"), ["containers"])
  assert.deepEqual(rules("pretty", "[\n  1,\n\n\n  2,\n]\n"), ["blank lines"])
  assert.deepEqual(rules("pretty", "[\n   1,\n]\n"), ["indentation"])
  assert.deepEqual(rules("pretty", '{\n  "a": 1,\n}\n'), ["keys"])
  assert.deepEqual(rules("pretty", "[\n  1,\n],\n2,\n"), ["stream"])
  assert.deepEqual(rules("pretty", "1,\n"), ["stream"])
  assert.deepEqual(rules("pretty", '"\u2028"\n'), ["separators"])
  assert.deepEqual(rules("compact", "Tag (1)\n"), ["spacing"])
  assert.deepEqual(rules("compact", "{a: 1}\n"), ["spacing"])
  assert.deepEqual(rules("minimised", "[1, 2]\n"), ["spacing"])
  assert.deepEqual(rules("minimised", 'x"9f 86"\n'), [])

  const checks = (style: Style, input: string, out: string) => layoutFailures(style, input, out, DEFAULT).map((f) => f.check)
  assert.deepEqual(checks("pretty", "[1, // a\n 2]", "[\n  1,\n  2,\n]\n"), ["comments: pretty"])
  assert.deepEqual(checks("pretty", "[1, 2]", "[\n  1, \n  2,\n]\n"), ["spacing: pretty", "trailing blanks: pretty"])
  assert.deepEqual(checks("compact", "[1, 2], 3", "[1, 2], 3,\n"), ["lines: compact", "lines: compact"])
  assert.deepEqual(checks("compact", "[1, 2]", "[1, 3]\n"), ["values: compact"])
})
