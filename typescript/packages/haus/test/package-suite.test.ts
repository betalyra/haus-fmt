/** The package suite (test-suite/packages, spec §13.3): file trees resolved with the Node resolver. */
import { existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { canonical, HausSchemaFileError, parseAll, parseSchemaFile, type Value } from "../src/index.js"
import { schemaOptions, type NodeResolverOptions } from "../src/node.js"

const CASES = join(import.meta.dirname, "../../../../test-suite/packages/cases.haus")

type Entry =
  | { readonly kind: "File"; readonly path: string; readonly text: string }
  | { readonly kind: "Package"; readonly dir: string; readonly name: string; readonly version: string; readonly schema: string }
  | { readonly kind: "Npm"; readonly dir: string; readonly json: Record<string, unknown> }
  | { readonly kind: "Link"; readonly path: string; readonly target: string }

/** How packages are found: given explicitly, and with `Npm` also from node_modules. */
interface Mode {
  readonly kind: "Npm" | "Explicit"
  readonly packages: readonly string[]
  readonly folders: readonly string[]
}

type Expect =
  | { readonly ok: true; readonly packages: readonly string[] }
  | { readonly ok: false; readonly code: string; readonly mentions: readonly string[]; readonly hides: readonly string[] }

interface Case {
  readonly name: string
  readonly files: readonly Entry[]
  readonly root: string
  readonly mode: Mode
  /** A case for the version check, which implementations SHOULD make (this one does). */
  readonly should: boolean
  readonly expect: Expect
}

/** The number of cases in cases.haus: a reader that drops some fails. */
const TOTAL = 85

// ── reading the cases ────────────────────────────────────────

const bad = (v: Value): never => {
  throw new Error(`unexpected value in cases.haus: ${canonical(v)}`)
}
const fields = (v: Value | undefined): ReadonlyMap<string, Value> => (v?.kind === "record" ? v.fields : v ? bad(v) : new Map())
const string = (v: Value | undefined): string => (v?.kind === "string" ? v.value : bad(v ?? { kind: "array", items: [] }))
const strings = (v: Value | undefined): string[] => (v === undefined ? [] : v.kind === "array" ? v.items.map(string) : bad(v))
const variant = (v: Value | undefined) => (v?.kind === "variant" ? v : bad(v ?? { kind: "array", items: [] }))

/** `Npm`'s dependency lists become objects from the names to "*". */
const DEPENDENCIES = ["dependencies", "peerDependencies", "devDependencies", "optionalDependencies"]
const packageJson = (v: Value | undefined): Record<string, unknown> =>
  Object.fromEntries([...fields(v)].map(([k, x]) => [k, DEPENDENCIES.includes(k) ? Object.fromEntries(strings(x).map((n) => [n, "*"])) : string(x)]))

const entry = (v: Value): Entry => {
  const { tag, args } = variant(v)
  const s = (i: number) => string(args[i])
  switch (tag) {
    case "File":
      return { kind: "File", path: s(0), text: s(1) }
    case "Package":
      return { kind: "Package", dir: s(0), name: s(1), version: s(2), schema: s(3) }
    case "Npm":
      return { kind: "Npm", dir: s(0), json: packageJson(args[1]) }
    case "Link":
      return { kind: "Link", path: s(0), target: s(1) }
    default:
      return bad(v)
  }
}

/** `Npm`, `Npm { packages?, folders? }` or `Explicit { packages?, folders? }`. */
const mode = (v: Value | undefined): Mode => {
  if (v?.kind === "variant" && (v.tag === "Npm" || v.tag === "Explicit")) {
    const f = fields(v.args[0])
    return { kind: v.tag, packages: strings(f.get("packages")), folders: strings(f.get("folders")) }
  }
  return bad(v ?? { kind: "array", items: [] })
}

const bool = (v: Value | undefined): boolean => (v === undefined ? false : v.kind === "variant" && (v.tag === "True" || v.tag === "False") ? v.tag === "True" : bad(v))

const expectation = (v: Value | undefined): Expect => {
  const e = variant(v)
  const f = fields(e.args[0])
  if (e.tag === "Ok") return { ok: true, packages: strings(f.get("packages")) }
  if (e.tag === "Err") return { ok: false, code: string(f.get("code")), mentions: strings(f.get("mentions")), hides: strings(f.get("hides")) }
  return bad(e)
}

const cases: Case[] = parseAll(readFileSync(CASES, "utf8")).map((v) => {
  const c = variant(v)
  if (c.tag !== "Case") bad(c)
  const f = fields(c.args[0])
  return {
    name: string(f.get("name")),
    files: (f.get("files")?.kind === "array" ? (f.get("files") as Extract<Value, { kind: "array" }>).items : []).map(entry),
    root: string(f.get("root")),
    mode: mode(f.get("mode")),
    should: bool(f.get("should")),
    expect: expectation(f.get("expect")),
  }
})

// ── running a case ───────────────────────────────────────────

/** Write the case's tree into a fresh temporary directory. */
const write = (files: readonly Entry[]): string => {
  const root = mkdtempSync(join(tmpdir(), "haus-packages-"))
  const file = (path: string, text: string) => {
    mkdirSync(dirname(join(root, path)), { recursive: true })
    writeFileSync(join(root, path), text)
  }
  for (const e of files) {
    switch (e.kind) {
      case "File":
        file(e.path, e.text)
        break
      case "Package":
        file(`${e.dir}/package.haus`, `{ name: ${JSON.stringify(e.name)}, version: ${JSON.stringify(e.version)} }`)
        file(`${e.dir}/schema.haus`, e.schema)
        break
      case "Npm":
        file(`${e.dir}/package.json`, JSON.stringify(e.json, null, 2))
        break
      case "Link":
        break
    }
  }
  // Links last, once their targets exist: on Windows a link to a directory
  // must be made as one ("dir"), which Node only does when it sees the target.
  for (const e of files) {
    if (e.kind !== "Link") continue
    const at = join(root, e.path)
    mkdirSync(dirname(at), { recursive: true })
    const target = resolve(dirname(at), e.target)
    const text = process.platform === "win32" ? e.target.replaceAll("/", "\\") : e.target
    symlinkSync(text, at, existsSync(target) && statSync(target).isDirectory() ? "dir" : "file")
  }
  return root
}

const run = (c: Case): void => {
  const dir = write(c.files)
  const path = join(dir, c.root)
  // Explicit: only the packages given, node_modules is never read.
  const options: NodeResolverOptions = {
    packages: c.mode.packages.map((p) => join(dir, p)),
    folders: c.mode.folders.map((f) => join(dir, f)),
    npm: c.mode.kind === "Npm",
  }
  const base = schemaOptions(path, options)
  // Every package the schema reaches, as name@version.
  const reached = new Set<string>()
  const resolver = base.resolver!
  const load = () =>
    parseSchemaFile(readFileSync(path, "utf8"), {
      ...base,
      resolver: {
        resolve(module, from) {
          const r = resolver.resolve(module, from)
          if (r.package !== undefined) reached.add(`${r.package}@${r.version}`)
          return r
        },
      },
    })
  if (c.expect.ok) {
    load()
    expect([...reached].sort()).toEqual(c.expect.packages)
    return
  }
  let error: unknown
  try {
    load()
  } catch (e) {
    error = e
  }
  expect(error, "the schema loads, but should fail").toBeInstanceOf(HausSchemaFileError)
  const e = error as HausSchemaFileError
  expect(e.code, e.message).toBe(c.expect.code)
  // Paths in messages are compared with "/", whatever the OS writes.
  for (const m of c.expect.mentions) expect(e.message.replaceAll("\\", "/")).toContain(m)
  for (const h of c.expect.hides) expect(e.message).not.toContain(h)
}

const ran = { Npm: 0, Explicit: 0 }
const count = (kind: Mode["kind"]) => cases.filter((c) => c.mode.kind === kind).length

describe("package suite (test-suite/packages)", () => {
  it.each(cases.map((c) => [`${c.name} (${c.mode.kind}${c.should ? ", should" : ""})`, c] as const))("%s", (_, c) => {
    run(c)
    ran[c.mode.kind]++
  })

  // This binding reads node_modules and makes the version check: it runs every case, Npm and should ones too.
  it(`ran all ${TOTAL} cases: ${count("Npm")} Npm, ${count("Explicit")} Explicit (${cases.filter((c) => c.should).length} should), 0 skipped`, () => {
    expect(cases.length).toBe(TOTAL)
    expect(count("Npm")).toBeGreaterThan(0)
    expect(count("Explicit")).toBeGreaterThan(0)
    expect(ran).toEqual({ Npm: count("Npm"), Explicit: count("Explicit") })
    console.log(`package suite: ${ran.Npm + ran.Explicit} of ${cases.length} cases run (${ran.Npm} Npm, ${ran.Explicit} Explicit), 0 skipped`)
  })
})
