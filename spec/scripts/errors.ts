/**
 * Generates the error catalogue's readable and code forms from its single
 * source, spec/errors.haus (spec §17):
 *
 *   spec/errors.md                                  the catalogue, as tables per category
 *   docs/errors.md                                  the docs page, one `## code` section per code
 *   typescript/packages/haus/src/error-codes.ts     the TypeScript binding's table
 *
 *   node spec/scripts/errors.ts            write them
 *   node spec/scripts/errors.ts --check    exit 1 if one is out of date (the TypeScript tests run this)
 *
 * Reads spec/errors.haus with the TypeScript binding's parser
 * (typescript/packages/haus, built to dist/ by `pnpm build`; set
 * HAUS_TS_DIST to use another build).
 */
import { readFileSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const root = resolve(import.meta.dirname, "../..")
const dist = process.env.HAUS_TS_DIST ?? join(root, "typescript/packages/haus/dist")
const { parseAll } = (await import(join(dist, "index.js"))) as typeof import("../../typescript/packages/haus/src/index.ts")
type Value = ReturnType<typeof parseAll>[number]

/** The categories, in order: the tag in errors.haus, its id in code, its title. */
export const CATEGORIES = [
  ["Syntax", "syntax", "Syntax", "Reading haus text (§1–§5, [grammar.ebnf](grammar.ebnf))."],
  ["Limits", "limits", "Limits", "The resource limits of §7. Each can be configured; the defaults are in §7."],
  ["Streams", "streams", "Streams", "Sequences of values (§6)."],
  ["SchemaFiles", "schema-files", "Schema files", "Schema files that implementations must reject (§14)."],
  ["Imports", "imports", "Imports", "Standard modules, schema packages and files (§13.3)."],
  ["Decoding", "decoding", "Decoding and encoding", "Values that don't fit a schema type (§15), and values a program can't encode."],
  ["Json", "json", "JSON", "The JSON mappings (§16)."],
  ["Hints", "hints", "Hints and warnings", "Reported by checkers and editors without failing (§14)."],
] as const

export type Example =
  | { readonly kind: "Data" | "Schema" | "Lossless" | "Text"; readonly text: string }
  | { readonly kind: "Decode" | "Check"; readonly schema: string; readonly data: string }
  | { readonly kind: "Plain"; readonly schema: string; readonly json: string }

export interface Entry {
  readonly code: string
  readonly category: (typeof CATEGORIES)[number][1]
  readonly means: string
  readonly example: Example
  readonly fix: string
}

const fail = (message: string): never => {
  throw new Error(`spec/errors.haus: ${message}`)
}

const field = (v: Value, key: string): Value => {
  if (v.kind !== "record") return fail("expected a record")
  return v.fields.get(key) ?? fail(`missing field ${key}`)
}
const text = (v: Value, what: string): string => (v.kind === "string" ? v.value : fail(`${what}: expected a string`))

const example = (v: Value, code: string): Example => {
  if (v.kind !== "variant" || v.args.length !== 1) return fail(`${code}: example is a tag with one argument`)
  const [arg] = v.args
  switch (v.tag) {
    case "Data":
    case "Schema":
    case "Lossless":
    case "Text":
      return { kind: v.tag, text: text(arg!, code) }
    case "Decode":
    case "Check":
      return { kind: v.tag, schema: text(field(arg!, "schema"), code), data: text(field(arg!, "data"), code) }
    case "Plain":
      return { kind: v.tag, schema: text(field(arg!, "schema"), code), json: text(field(arg!, "json"), code) }
  }
  return fail(`${code}: unknown example kind ${v.tag}`)
}

/** The entries of spec/errors.haus, checked: unique kebab-case codes in known categories. */
export function readCatalogue(source = readFileSync(join(root, "spec/errors.haus"), "utf8")): Entry[] {
  const seen = new Set<string>()
  return parseAll(source).map((v) => {
    if (v.kind !== "variant" || v.tag !== "Code" || v.args[0]?.kind !== "record") return fail("every entry is Code { … }")
    const r = v.args[0]
    const code = text(field(r, "code"), "code")
    if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(code)) fail(`${code}: codes are lowercase kebab-case`)
    if (seen.has(code)) fail(`${code} appears twice`)
    seen.add(code)
    const cat = field(r, "category")
    const category = CATEGORIES.find(([tag]) => cat.kind === "variant" && cat.tag === tag)?.[1] ?? fail(`${code}: unknown category`)
    return { code, category, means: text(field(r, "means"), code), example: example(field(r, "example"), code), fix: text(field(r, "fix"), code) }
  })
}

export const DOCS = "https://haus-fmt.org/docs/errors"

// ── spec/errors.md ───────────────────────────────────────────

/** Inline code that can hold backticks; line breaks shown as ⏎. */
const code = (s: string) => {
  const t = s.replaceAll("\n", " ⏎ ")
  const ticks = "`".repeat(Math.max(0, ...[...t.matchAll(/`+/g)].map((m) => m[0].length)) + 1)
  return ticks.length > 1 ? `${ticks} ${t} ${ticks}` : `\`${t}\``
}
const cell = (s: string) => s.replaceAll("|", "\\|")

const inlineExample = (e: Example): string => {
  switch (e.kind) {
    case "Data":
    case "Schema":
    case "Lossless":
      return code(e.text)
    case "Text":
      return e.text
    case "Decode":
    case "Check":
      return `${code(e.data)} with ${code(e.schema)}`
    case "Plain":
      return `${code(e.json)} with ${code(e.schema)}`
  }
}

export function specMarkdown(entries: readonly Entry[]): string {
  const out = [
    "<!-- Generated from errors.haus by scripts/errors.ts. Don't edit: edit errors.haus and run `node spec/scripts/errors.ts`. -->",
    "",
    "# Error codes",
    "",
    "The catalogue of the error codes of [§17](README.md#17-error-codes). Every implementation reports these codes, the same in",
    "every binding; a code is never renamed, removed or reused after 1.0, only added. Each code has a page section at",
    `\`${DOCS}#<code>\`. The machine-readable source is [\`errors.haus\`](errors.haus).`,
    "",
    `${entries.length} codes in ${CATEGORIES.length} categories:`,
    "",
    ...CATEGORIES.map(([, id, title]) => `- [${title}](#${id}): ${entries.filter((e) => e.category === id).length}`),
  ]
  for (const [, id, title, intro] of CATEGORIES) {
    out.push("", `## ${title}`, "", `<a id="${id}"></a>${intro}`, "", "| Code | Meaning | Example | Fix |", "|---|---|---|---|")
    for (const e of entries.filter((x) => x.category === id)) {
      out.push(`| \`${e.code}\` | ${cell(e.means)} | ${cell(inlineExample(e.example))} | ${cell(e.fix)} |`)
    }
  }
  return out.join("\n") + "\n"
}

// ── docs/errors.md ───────────────────────────────────────────

const fence = (lang: string, s: string) => {
  const ticks = "`".repeat(Math.max(3, ...[...s.matchAll(/`+/g)].map((m) => m[0].length + 1)))
  return `${ticks}${lang}\n${s}\n${ticks}`
}

const docsExample = (e: Example): string => {
  switch (e.kind) {
    case "Data":
      return fence("haus", e.text)
    case "Schema":
      return fence("haus-schema", e.text)
    case "Lossless":
      return `Read as lossless JSON:\n\n${fence("json", e.text)}`
    case "Text":
      return `For example: ${e.text}.`
    case "Decode":
    case "Check":
      return `${fence("haus-schema", e.schema)}\n\n${fence("haus", e.data)}`
    case "Plain":
      return `${fence("haus-schema", e.schema)}\n\n${fence("json", e.json)}`
  }
}

export function docsMarkdown(entries: readonly Entry[]): string {
  const out = [
    "---",
    "title: Error codes",
    "description: Every error haus reports, with its stable code, an example and the fix.",
    "---",
    "",
    "<!-- Generated from spec/errors.haus by spec/scripts/errors.ts. Don't edit: edit spec/errors.haus and run `node spec/scripts/errors.ts`. -->",
    "",
    "Every error haus reports has a **code**: a short name such as `payload-newline` that is the same in every binding and never changes. Look it up here, or match on it in code. The specification defines them in [§17](/docs/spec#17-error-codes).",
    "",
    "Bindings also give each error as JSON, so tools and agents can act on it:",
    "",
    fence("json", JSON.stringify({
      code: "payload-newline",
      message: "expected ',' between top-level values, found '{'",
      line: 2,
      column: 1,
      expected: "','",
      found: "'{'",
      hint: "Put the payload on the tag's line, or add a comma if they are two values.",
      docs: `${DOCS}#payload-newline`,
    }, null, 2)),
    "",
    "`hint` is the fix below, unless a binding knows a better one for the case at hand. `path` (`$.items[2].price`) says where in the value a schema error is.",
    "",
    ...CATEGORIES.flatMap(([, id, title]) => [`**${title}:** ${entries.filter((e) => e.category === id).map((e) => `[${e.code}](#${e.code})`).join(", ")}`, ""]),
  ]
  for (const e of entries) {
    const category = CATEGORIES.find(([, id]) => id === e.category)![2]
    out.push(`## ${e.code}`, "", `*${category}.* ${e.means}`, "", docsExample(e.example), "", `**Fix:** ${e.fix}`, "")
  }
  return out.join("\n")
}

// ── typescript/packages/haus/src/error-codes.ts ──────────────

export function typescriptTable(entries: readonly Entry[]): string {
  return [
    "// Generated from spec/errors.haus by spec/scripts/errors.ts. Don't edit: edit spec/errors.haus and run `node spec/scripts/errors.ts`.",
    "",
    "/** Every error code (spec §17), with its category and the fix reported as the hint. */",
    "export const ERROR_CODES = {",
    ...entries.map((e) => `  ${JSON.stringify(e.code)}: { category: ${JSON.stringify(e.category)}, hint: ${JSON.stringify(e.fix)} },`),
    "} as const",
    "",
    "/** An error code (spec §17): stable, the same in every binding. */",
    "export type ErrorCode = keyof typeof ERROR_CODES",
    "",
    "/** The category of an error code. */",
    `export type ErrorCategory = ${CATEGORIES.map(([, id]) => JSON.stringify(id)).join(" | ")}`,
    "",
  ].join("\n")
}

// ── main ─────────────────────────────────────────────────────

if (import.meta.main) {
  const entries = readCatalogue()
  const outputs: [string, string][] = [
    ["spec/errors.md", specMarkdown(entries)],
    ["docs/errors.md", docsMarkdown(entries)],
    ["typescript/packages/haus/src/error-codes.ts", typescriptTable(entries)],
  ]
  if (process.argv.includes("--check")) {
    const stale = outputs.filter(([file, content]) => {
      try {
        return readFileSync(join(root, file), "utf8") !== content
      } catch {
        return true
      }
    })
    for (const [file] of stale) console.error(`${file} is out of date: run node spec/scripts/errors.ts`)
    process.exitCode = stale.length > 0 ? 1 : 0
  } else {
    for (const [file, content] of outputs) writeFileSync(join(root, file), content)
    console.log(`${entries.length} codes: wrote ${outputs.map(([f]) => f).join(", ")}`)
  }
}
