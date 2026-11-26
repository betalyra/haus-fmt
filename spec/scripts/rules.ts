/**
 * The spec-to-test map: which normative rules of the specification no
 * conformance-suite case covers.
 *
 * Rule IDs are comments before each rule in the spec files:
 *
 *   spec/README.md, spec/packages.md,
 *   spec/std/time.md                   <!-- rule: limits.depth.default -->
 *   spec/grammar.ebnf                  (* rule: grammar.lexical.number *)
 *
 * The cases that cover a rule are listed in test-suite/rules.haus, one record
 * per rule:
 *
 *   { rule: "limits.depth.default", cases: ["valid/limits-boundary", "invalid/too-deep"] },
 *   { rule: "security.signatures", cases: [], untestable: True, note: "advice on signing" },
 *
 * Case paths are relative to test-suite/ and name a case as the suite READMEs
 * do, without extension (`valid/numbers`, `schema/invalid/row-parameter`,
 * `format/cases/width`); `packages/cases#NAME` names one case of the package
 * suite. Schema suite files may also say which rules they cover, with a
 * comment line `// rule: ID` (test-suite/schema/**.haus).
 *
 *   node spec/scripts/rules.ts                    the uncovered rules, by section
 *   node spec/scripts/rules.ts --check            exit 1 on any error, on an uncovered rule that
 *                                                 spec/scripts/rules-uncovered.txt doesn't list, or on a
 *                                                 listed rule that is covered now (the list only shrinks)
 *   node spec/scripts/rules.ts --write-uncovered  rewrite rules-uncovered.txt with the uncovered rules
 *
 * Reads test-suite/rules.haus with the TypeScript binding's parser
 * (typescript/packages/haus, built to dist/ by `pnpm build`; set
 * HAUS_TS_DIST to use another build).
 */
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { basename, dirname, join, relative, resolve } from "node:path"

const root = resolve(import.meta.dirname, "../..")
const dist = process.env.HAUS_TS_DIST ?? join(root, "typescript/packages/haus/dist")
const { parseAll } = (await import(join(dist, "index.js"))) as typeof import("../../typescript/packages/haus/src/index.ts")
type Value = ReturnType<typeof parseAll>[number]

const SUITE = join(root, "test-suite")
const MANIFEST = join(SUITE, "rules.haus")
const ALLOWLIST = join(root, "spec/scripts/rules-uncovered.txt")

/** The spec files, the comment syntax of each, and the prefix their IDs must have. */
const SOURCES = [
  { file: "spec/README.md", comment: /<!--\s*rule:\s*(.*?)\s*-->/g, prefix: null },
  { file: "spec/packages.md", comment: /<!--\s*rule:\s*(.*?)\s*-->/g, prefix: null },
  { file: "spec/std/time.md", comment: /<!--\s*rule:\s*(.*?)\s*-->/g, prefix: "time" },
  { file: "spec/grammar.ebnf", comment: /\(\*\s*rule:\s*(.*?)\s*\*\)/g, prefix: "grammar" },
] as const

/** The first segment of a README rule: the section, by topic. */
const SECTIONS = [
  "data", "equality", "numbers", "strings", "variants", "streams", "limits", "positions", "security",
  "versions", "format", "canonical", "prelude", "packages", "codecs", "schema", "decode", "json", "errors",
]
/** Dotted lowercase, at least section.topic.rule; segments may hold hyphens. */
const ID = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*(?:\.[a-z0-9]+(?:-[a-z0-9]+)*){2,}$/

const errors: string[] = []
const error = (message: string) => errors.push(message)

interface Rule {
  readonly id: string
  readonly where: string
}

/** Every rule ID of the spec files, in order, checked for form and uniqueness. */
function specRules(): Rule[] {
  const rules: Rule[] = []
  const seen = new Map<string, string>()
  for (const { file, comment, prefix } of SOURCES) {
    const lines = readFileSync(join(root, file), "utf8").split("\n")
    lines.forEach((line, i) => {
      const where = `${file}:${i + 1}`
      for (const [, id] of line.matchAll(comment)) {
        if (!ID.test(id!)) error(`${where}: malformed rule ID ${JSON.stringify(id)}`)
        const section = id!.split(".")[0]!
        if (prefix ? section !== prefix : !SECTIONS.includes(section))
          error(`${where}: rule ${id} must start with ${prefix ?? `one of ${SECTIONS.join(", ")}`}`)
        const first = seen.get(id!)
        if (first) error(`${where}: rule ${id} is defined twice (first at ${first})`)
        else seen.set(id!, where)
        rules.push({ id: id!, where })
      }
      // A comment that mentions "rule:" but doesn't match the form would be silently ignored.
      if (/rule:/.test(line) && !line.match(comment)) error(`${where}: a rule comment the script can't read`)
    })
  }
  return rules
}

interface Entry {
  readonly rule: string
  readonly cases: readonly string[]
  readonly untestable: boolean
  readonly note?: string
}

const str = (v: Value | undefined, what: string): string | undefined => {
  if (v === undefined) return undefined
  if (v.kind === "string") return v.value
  error(`test-suite/rules.haus: ${what} is not a string`)
  return undefined
}

/** The records of test-suite/rules.haus. */
function manifest(): Entry[] {
  let values: Value[]
  try {
    values = parseAll(readFileSync(MANIFEST, "utf8"))
  } catch (e) {
    error(`test-suite/rules.haus: ${(e as Error).message}`)
    return []
  }
  const entries: Entry[] = []
  values.forEach((v, i) => {
    const at = `test-suite/rules.haus, value ${i + 1}`
    if (v.kind !== "record") return error(`${at}: not a record`)
    for (const key of v.fields.keys())
      if (!["rule", "cases", "note", "untestable"].includes(key)) error(`${at}: unknown field ${key}`)
    const rule = str(v.fields.get("rule"), `${at}: rule`)
    if (rule === undefined) return error(`${at}: no rule`)
    const casesValue = v.fields.get("cases")
    const cases: string[] = []
    if (casesValue === undefined || casesValue.kind !== "array") error(`${at} (${rule}): cases is not an array`)
    else for (const c of casesValue.items) {
      const path = str(c, `${at} (${rule}): a case`)
      if (path !== undefined) cases.push(path)
    }
    const flag = v.fields.get("untestable")
    let untestable = false
    if (flag !== undefined) {
      if (flag.kind === "variant" && flag.args.length === 0 && (flag.tag === "True" || flag.tag === "False")) untestable = flag.tag === "True"
      else error(`${at} (${rule}): untestable is not True or False`)
    }
    const note = str(v.fields.get("note"), `${at} (${rule}): note`)
    if (untestable && cases.length > 0) error(`${at} (${rule}): untestable, but lists cases`)
    if (untestable && !note) error(`${at} (${rule}): untestable needs a note saying why`)
    if (!untestable && cases.length === 0) error(`${at} (${rule}): no cases (list the rule in spec/scripts/rules-uncovered.txt instead)`)
    entries.push({ rule, cases, untestable, ...(note ? { note } : {}) })
  })
  return entries
}

/** Every `// rule: ID` comment line in the schema suite, with the case it is in. */
function caseComments(): { rule: string; casePath: string; where: string }[] {
  const found: { rule: string; casePath: string; where: string }[] = []
  const walk = (dir: string) => {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name)
      if (statSync(path).isDirectory()) walk(path)
      else if (name.endsWith(".haus")) {
        const casePath = relative(SUITE, path).replaceAll("\\", "/").replace(/\.(schema|cases)\.haus$|\.haus$/, "")
        readFileSync(path, "utf8").split("\n").forEach((line, i) => {
          const m = /^\s*\/\/\s*rule:\s*(\S+)\s*$/.exec(line)
          if (m) found.push({ rule: m[1]!, casePath, where: `${relative(root, path)}:${i + 1}` })
        })
      }
    }
  }
  walk(join(SUITE, "schema"))
  return found
}

const caseNames = new Map<string, Set<string>>()
/** Whether `path` (relative to test-suite/, without extension, optionally `#name`) names an existing case. */
function caseExists(path: string): boolean {
  const [file, name] = path.split("#") as [string, string | undefined]
  const full = resolve(SUITE, file)
  const dir = dirname(full)
  if (!existsSync(dir) || !statSync(dir).isDirectory()) return false
  const files = readdirSync(dir).filter((f) => f.startsWith(`${basename(full)}.`))
  if (files.length === 0) return false
  if (name === undefined) return true
  const haus = files.find((f) => f.endsWith(".haus"))
  if (!haus) return false
  const key = join(dir, haus)
  if (!caseNames.has(key))
    caseNames.set(key, new Set([...readFileSync(key, "utf8").matchAll(/^\s*name:\s*"([^"]*)"/gm)].map((m) => m[1]!)))
  return caseNames.get(key)!.has(name)
}

function readAllowlist(): string[] {
  if (!existsSync(ALLOWLIST)) return []
  return readFileSync(ALLOWLIST, "utf8")
    .split("\n")
    .map((l) => l.replace(/#.*/, "").trim())
    .filter((l) => l !== "")
}

// ── main ──

const args = process.argv.slice(2)
const check = args.includes("--check")
const write = args.includes("--write-uncovered")

const rules = specRules()
const known = new Set(rules.map((r) => r.id))
const entries = manifest()
const comments = caseComments()

const covered = new Map<string, Set<string>>()
const untestable = new Set<string>()
const listed = new Set<string>()
for (const e of entries) {
  if (listed.has(e.rule)) error(`test-suite/rules.haus: rule ${e.rule} is listed twice`)
  listed.add(e.rule)
  if (!known.has(e.rule)) error(`test-suite/rules.haus: rule ${e.rule} is not in the spec`)
  if (e.untestable) untestable.add(e.rule)
  for (const c of e.cases) {
    if (!caseExists(c)) error(`test-suite/rules.haus: rule ${e.rule}: no case ${c}`)
    if (!covered.has(e.rule)) covered.set(e.rule, new Set())
    covered.get(e.rule)!.add(c)
  }
}
for (const { rule, casePath, where } of comments) {
  if (!known.has(rule)) error(`${where}: rule ${rule} is not in the spec`)
  if (untestable.has(rule)) error(`${where}: rule ${rule} is marked untestable in test-suite/rules.haus`)
  if (!covered.has(rule)) covered.set(rule, new Set())
  covered.get(rule)!.add(casePath)
}

const uncovered = rules.filter((r) => !covered.has(r.id) && !untestable.has(r.id))
const section = (id: string) => id.split(".")[0]!

if (write) {
  const header = [
    "# Rules of the spec that no conformance-suite case covers yet (spec/scripts/rules.ts).",
    "# This list may only shrink: `node spec/scripts/rules.ts --check` fails on an uncovered rule",
    "# that isn't listed, and on a listed rule that is covered now.",
  ]
  writeFileSync(ALLOWLIST, [...header, ...uncovered.map((r) => r.id), ""].join("\n"))
}

// Summary: per section, the rules, covered, untestable and uncovered.
const order = [...new Set(rules.map((r) => section(r.id)))]
const rows = order.map((s) => {
  const ids = rules.filter((r) => section(r.id) === s).map((r) => r.id)
  return [s, ids.length, ids.filter((id) => covered.has(id)).length, ids.filter((id) => untestable.has(id)).length, ids.filter((id) => !covered.has(id) && !untestable.has(id)).length] as const
})
const total = rows.reduce((a, r) => [a[0] + r[1], a[1] + r[2], a[2] + r[3], a[3] + r[4]], [0, 0, 0, 0])
const pad = (s: string | number, n: number) => String(s).padStart(n)
console.log(`${"section".padEnd(10)} ${pad("rules", 5)} ${pad("covered", 7)} ${pad("untestable", 10)} ${pad("uncovered", 9)}`)
for (const [s, n, c, u, x] of rows) console.log(`${s.padEnd(10)} ${pad(n, 5)} ${pad(c, 7)} ${pad(u, 10)} ${pad(x, 9)}`)
console.log(`${"total".padEnd(10)} ${pad(total[0], 5)} ${pad(total[1], 7)} ${pad(total[2], 10)} ${pad(total[3], 9)}`)

if (!check) {
  console.log(`\nRules without a case (${uncovered.length}):`)
  for (const s of order) {
    const ids = uncovered.filter((r) => section(r.id) === s)
    if (ids.length === 0) continue
    console.log(`\n${s}`)
    for (const r of ids) console.log(`  ${r.id.padEnd(48)} ${r.where}`)
  }
}

if (check) {
  const allow = readAllowlist()
  const allowed = new Set(allow)
  const seenAllow = new Set<string>()
  for (const id of allow) {
    if (seenAllow.has(id)) error(`spec/scripts/rules-uncovered.txt: ${id} is listed twice`)
    seenAllow.add(id)
    if (!known.has(id)) error(`spec/scripts/rules-uncovered.txt: ${id} is not a rule of the spec (remove it)`)
    else if (covered.has(id)) error(`spec/scripts/rules-uncovered.txt: ${id} is covered now (remove it from the list)`)
    else if (untestable.has(id)) error(`spec/scripts/rules-uncovered.txt: ${id} is marked untestable (remove it from the list)`)
  }
  for (const r of uncovered)
    if (!allowed.has(r.id)) error(`${r.where}: rule ${r.id} has no case: add one to test-suite/rules.haus, or mark it untestable with a note`)
}

if (errors.length > 0) {
  console.error(`\n${errors.length} error${errors.length === 1 ? "" : "s"}:`)
  for (const e of errors) console.error(`  ${e}`)
  process.exit(1)
}
if (check) console.log(`\nok: ${rules.length} rules, ${uncovered.length} uncovered, all listed in spec/scripts/rules-uncovered.txt`)
