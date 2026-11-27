/**
 * The package suite (test-suite/packages, spec §13.3, packages.md): file
 * trees read with `readSources` and compiled with `Schema.compile`. Runs
 * cases.haus (where packages come from, the file rules) and rules.haus (the
 * built-in official packages, the manifest's `rules` field, `missing-codec`,
 * `shapeOnly` and `withRule`).
 */
import { spawnSync } from "node:child_process"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { pathToFileURL } from "node:url"
import { describe, expect, it } from "vitest"
import { canonical, money, OFFICIAL, Package, parseAll, Result, Schema, Sources, sourcesOf, type HausError, type Value } from "../src/index.js"
import { readSourcesSync, type ReadSourcesOptions } from "../src/node.js"

const SUITE = join(import.meta.dirname, "../../../../test-suite/packages")

type Entry =
  | { readonly kind: "File"; readonly path: string; readonly text: string }
  | { readonly kind: "Package"; readonly dir: string; readonly name: string; readonly version: string; readonly schema: string }
  | { readonly kind: "Npm"; readonly dir: string; readonly json: Record<string, unknown> }
  | { readonly kind: "Link"; readonly path: string; readonly target: string }
  | { readonly kind: "Fifo"; readonly path: string }
  | { readonly kind: "Large"; readonly path: string; readonly bytes: number }
  | { readonly kind: "Mode"; readonly path: string; readonly mode: number }

/** The packages given explicitly (no other kind is left: no implementation searches, packages.md §2). */
interface Mode {
  readonly packages: readonly string[]
  readonly folders: readonly string[]
}

type Expect =
  | { readonly ok: true; readonly packages: readonly string[] }
  | { readonly ok: false; readonly code: string; readonly mentions: readonly string[]; readonly hides: readonly string[] }

type Ecosystem = "core" | "cargo"

interface Case {
  readonly file: string
  readonly name: string
  readonly files: readonly Entry[]
  readonly root: string
  readonly rootDir: string | undefined
  readonly ecosystem: Ecosystem
  readonly unix: boolean
  readonly mode: Mode
  readonly should: boolean
  /** rules.haus: the packages the program takes shape-only, and the type ids whose rule it supplies. */
  readonly shapeOnly: readonly string[]
  readonly withRule: readonly string[]
  readonly expect: Expect
}

/** The number of cases in each file: a reader that drops some fails. */
const TOTALS: Readonly<Record<string, number>> = { "cases.haus": 93, "rules.haus": 22 }

/** Cases that are wrong in the suite, and why (kept short: they fail this test once fixed). */
const BROKEN: Readonly<Record<string, string>> = {}

// ── reading the cases ────────────────────────────────────────

const bad = (v: Value | undefined): never => {
  throw new Error(`unexpected value in the package suite: ${v === undefined ? "none" : canonical(v)}`)
}
const fields = (v: Value | undefined): ReadonlyMap<string, Value> => (v?.kind === "record" ? v.fields : v ? bad(v) : new Map())
const string = (v: Value | undefined): string => (v?.kind === "string" ? v.value : bad(v))
const strings = (v: Value | undefined): string[] => (v === undefined ? [] : v.kind === "array" ? v.items.map(string) : bad(v))
const variant = (v: Value | undefined) => (v?.kind === "variant" ? v : bad(v))

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
    case "Fifo":
      return { kind: "Fifo", path: s(0) }
    case "Large":
      return { kind: "Large", path: s(0), bytes: args[1]?.kind === "number" ? Number(args[1].text) : bad(args[1]) }
    case "Mode":
      return { kind: "Mode", path: s(0), mode: Number.parseInt(s(1), 8) }
    default:
      return bad(v)
  }
}

const mode = (v: Value | undefined): Mode => {
  if (v?.kind === "variant" && v.tag === "Explicit") {
    const f = fields(v.args[0])
    return { packages: strings(f.get("packages")), folders: strings(f.get("folders")) }
  }
  return bad(v)
}

const bool = (v: Value | undefined): boolean => (v === undefined ? false : v.kind === "variant" && (v.tag === "True" || v.tag === "False") ? v.tag === "True" : bad(v))

const expectation = (v: Value | undefined): Expect => {
  const e = variant(v)
  const f = fields(e.args[0])
  if (e.tag === "Ok") return { ok: true, packages: strings(f.get("packages")) }
  if (e.tag === "Err") return { ok: false, code: string(f.get("code")), mentions: strings(f.get("mentions")), hides: strings(f.get("hides")) }
  return bad(e)
}

const readCases = (file: string): Case[] =>
  parseAll(readFileSync(join(SUITE, file), "utf8")).map((v) => {
    const c = variant(v)
    if (c.tag !== "Case") bad(c)
    const f = fields(c.args[0])
    const ecosystem = string(f.get("ecosystem"))
    if (ecosystem !== "core" && ecosystem !== "cargo") bad(f.get("ecosystem"))
    const os = f.get("os")
    if (os !== undefined && string(os) !== "unix") bad(os)
    return {
      file,
      name: string(f.get("name")),
      files: (f.get("files")?.kind === "array" ? (f.get("files") as Extract<Value, { kind: "array" }>).items : []).map(entry),
      root: string(f.get("root")),
      rootDir: f.get("rootDir") === undefined ? undefined : string(f.get("rootDir")),
      ecosystem: ecosystem as Ecosystem,
      unix: os !== undefined,
      mode: mode(f.get("mode")),
      should: bool(f.get("should")),
      shapeOnly: strings(f.get("shapeOnly")),
      withRule: strings(f.get("withRule")),
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
      case "Large":
        file(e.path, " ".repeat(e.bytes))
        break
      case "Fifo": {
        mkdirSync(dirname(join(root, e.path)), { recursive: true })
        const made = spawnSync("mkfifo", [join(root, e.path)])
        if (made.status !== 0) throw new Error(`mkfifo ${e.path} failed: ${made.stderr}`)
        break
      }
      case "Link":
      case "Mode":
        break
    }
  }
  for (const e of files) {
    if (e.kind !== "Link") continue
    const at = join(root, e.path)
    mkdirSync(dirname(at), { recursive: true })
    const target = resolve(dirname(at), e.target)
    const text = process.platform === "win32" ? e.target.replaceAll("/", "\\") : e.target
    symlinkSync(text, at, existsSync(target) && statSync(target).isDirectory() ? "dir" : "file")
  }
  for (const e of files) if (e.kind === "Mode") chmodSync(join(root, e.path), e.mode)
  return root
}

const restore = (root: string, files: readonly Entry[]): void => {
  for (const e of files) if (e.kind === "Mode") chmodSync(join(root, e.path), e.mode | 0o700)
}

/** The read options of a case written to `dir`: the packages and folders given, the root option. */
const optionsOf = (c: Case, dir: string): ReadSourcesOptions => ({
  packages: c.mode.packages.map((p) => join(dir, p)),
  folders: c.mode.folders.map((f) => join(dir, f)),
  ...(c.rootDir === undefined ? {} : { root: join(dir, c.rootDir) }),
})

const DIST = join(import.meta.dirname, "../dist")

/** Read and compile in a child process (the built package) killed after a few seconds: a FIFO opened blocking would hang. */
const readsWithoutBlocking = (path: string, options: ReadSourcesOptions): void => {
  const internal = pathToFileURL(join(DIST, "index.js")).href
  const node = pathToFileURL(join(DIST, "node.js")).href
  expect(existsSync(join(DIST, "node.js")), "build the package first (pnpm build): the FIFO cases read in a child process").toBe(true)
  const code = `const [{ Result, Schema }, { readSourcesSync }] = await Promise.all([import(${JSON.stringify(internal)}), import(${JSON.stringify(node)})]);
Result.flatMap(readSourcesSync(${JSON.stringify(path)}, JSON.parse(process.argv[1])), Schema.compile)`
  const child = spawnSync(process.execPath, ["--input-type=module", "-e", code, JSON.stringify(options)], { timeout: 5000, killSignal: "SIGKILL" })
  expect(child.signal, "the build blocked (killed after 5 s)").toBeNull()
  expect(child.status, String(child.stderr)).toBe(0)
}

/** The program's choices of a rules.haus case: packages taken shape-only, rules supplied (each accepting every value). */
const programOf = (c: Case) => (p: Package): Package => {
  let out = c.shapeOnly.includes(p.name) ? Package.shapeOnly(p) : p
  for (const id of c.withRule.filter((i) => i.startsWith(`${p.name}@`))) {
    const r = Package.withRule(out, id, () => Result.succeed(undefined))
    if (r._tag === "Failure") throw r.failure
    out = r.success
  }
  return out
}

/** Read and compile the case: the schema, or the first error. */
const compileCase = (c: Case, path: string, options: ReadSourcesOptions): Result<Schema, HausError> =>
  Result.flatMap(readSourcesSync(path, options), (sources) => {
    const program = programOf(c)
    // Official packages taken shape-only are given as values (they are built in, never read).
    const official = c.shapeOnly.filter((n) => OFFICIAL.has(n)).map((n) => Package.shapeOnly(n === money.name ? money : OFFICIAL.get(n)!))
    return Schema.compile(sourcesOf({
      ...sources,
      packages: [...sources.packages.map(program), ...official],
      folders: sources.folders.map((f) => ({ ...f, packages: f.packages.map(program) })),
    }))
  })

const run = (c: Case): void => {
  const dir = write(c.files)
  try {
    const path = join(dir, c.root)
    const options = optionsOf(c, dir)
    if (c.files.some((e) => e.kind === "Fifo")) readsWithoutBlocking(path, options)
    const result = compileCase(c, path, options)
    if (c.expect.ok) {
      if (result._tag === "Failure") throw result.failure
      expect([...result.success.packages.values()].map((p) => `${p.name}@${p.version}`).sort()).toEqual([...c.expect.packages].sort())
      return
    }
    expect(result._tag, "the schema compiles, but should fail").toBe("Failure")
    const e = (result as Extract<typeof result, { _tag: "Failure" }>).failure
    expect(e.code, e.message).toBe(c.expect.code)
    for (const m of c.expect.mentions) expect(e.message.replaceAll("\\", "/")).toContain(m)
    for (const h of c.expect.hides) expect(e.message).not.toContain(h)
    // Messages show paths relative to the root, never the temporary directory's (spec §13.3).
    expect(e.message).not.toContain(dir)
  } finally {
    restore(dir, c.files)
  }
}

const skipped = (c: Case): string | undefined => {
  if (c.ecosystem === "cargo") return "cargo"
  if (c.unix && process.platform === "win32") return "Unix only"
  if (c.files.some((e) => e.kind === "Mode") && process.getuid?.() === 0) return "Mode as root"
  return undefined
}

for (const file of Object.keys(TOTALS)) {
  const cases = readCases(file)
  let ran = 0
  const skips: string[] = []
  describe(`package suite (test-suite/packages/${file})`, () => {
    for (const c of cases) {
      const name = `${c.name}${c.should ? " (should)" : ""}`
      const skip = skipped(c)
      if (skip !== undefined) {
        skips.push(`${c.name} (${skip})`)
        it.skip(`${name}: ${skip}`, () => {})
      } else if (c.name in BROKEN) {
        it.fails(`${name}: broken in the suite: ${BROKEN[c.name]}`, () => run(c))
      } else {
        it(name, () => {
          run(c)
          ran++
        })
      }
    }
    it(`ran the cases of ${file}`, () => {
      expect(cases.length).toBe(TOTALS[file])
      expect(ran).toBe(cases.filter((c) => skipped(c) === undefined && !(c.name in BROKEN)).length)
      console.log(`package suite ${file}: ${ran} of ${cases.length} cases run, ${skips.length} skipped${skips.length ? `: ${skips.join(", ")}` : ""}`)
    })
  })
}

// Sources and Package values from plain data compile as files do (packages.md §3).
describe("packages as values", () => {
  it("compiles sources and a package made from data, with no file system", () => {
    const acme = Package.make({ manifest: `{ name: "@acme/ids", version: "1.2.0" }`, schema: "type Id = String" })
    const sources = Result.map(Sources.make("app.schema.haus", { "app.schema.haus": "import @acme/ids (Id)\nimport ./shared (Tag)\ntype Root = { id: Id, tag: Tag }", "shared.schema.haus": "type Tag = String" }), (s) =>
      Result.match(acme, { onSuccess: (p) => Sources.withPackage(s, p), onFailure: () => s }))
    const schema = Result.flatMap(sources, Schema.compile)
    expect(schema._tag).toBe("Success")
    expect([...(schema as Extract<typeof schema, { _tag: "Success" }>).success.packages.keys()]).toEqual(["@acme/ids"])
  })
})
