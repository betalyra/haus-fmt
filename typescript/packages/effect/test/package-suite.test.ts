/**
 * The package suite (test-suite/packages, spec §13.3, packages.md) through
 * the Effect binding: each case's file tree read with `Haus.readSources`
 * (`NodeSchemaFiles`, the core's reader), the program's choices made with
 * `Haus.Package.shapeOnly` and `Haus.Package.withRule`, compiled with
 * `Haus.compile`. Runs cases.haus (where packages come from, the file rules)
 * and rules.haus (the built-in official packages, the manifest's `rules`
 * field, `missing-codec`, `shapeOnly` and `withRule`).
 */
import { canonical, OFFICIAL, parseAll, sourcesOf, type Value } from "@haus-fmt/haus/internal"
import { describe, expect, it } from "@effect/vitest"
import { Cause, Effect, Exit, Option } from "effect"
import { spawnSync } from "node:child_process"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import * as Haus from "../src/index.js"
import { NodeSchemaFiles } from "../src/node.js"

const SUITE = join(import.meta.dirname, "../../../../test-suite/packages")

type Entry =
  | { readonly kind: "File"; readonly path: string; readonly text: string }
  | { readonly kind: "Package"; readonly dir: string; readonly name: string; readonly version: string; readonly schema: string }
  | { readonly kind: "Npm"; readonly dir: string; readonly json: Record<string, unknown> }
  | { readonly kind: "Link"; readonly path: string; readonly target: string }
  | { readonly kind: "Fifo"; readonly path: string }
  | { readonly kind: "Large"; readonly path: string; readonly bytes: number }
  | { readonly kind: "Mode"; readonly path: string; readonly mode: number }

type Expect =
  | { readonly ok: true; readonly packages: readonly string[] }
  | { readonly ok: false; readonly code: string; readonly mentions: readonly string[]; readonly hides: readonly string[] }

interface Case {
  readonly name: string
  readonly files: readonly Entry[]
  readonly root: string
  readonly rootDir: string | undefined
  readonly ecosystem: string
  readonly unix: boolean
  readonly packages: readonly string[]
  readonly folders: readonly string[]
  readonly should: boolean
  readonly shapeOnly: readonly string[]
  readonly withRule: readonly string[]
  readonly expect: Expect
}

/** The number of cases in each file: a reader that drops some fails. */
const TOTALS: Readonly<Record<string, number>> = { "cases.haus": 93, "rules.haus": 22 }

// ── reading the cases ────────────────────────────────────────

const bad = (v: Value | undefined): never => {
  throw new Error(`unexpected value in the package suite: ${v === undefined ? "none" : canonical(v)}`)
}
const fields = (v: Value | undefined): ReadonlyMap<string, Value> => (v?.kind === "record" ? v.fields : v ? bad(v) : new Map())
const string = (v: Value | undefined): string => (v?.kind === "string" ? v.value : bad(v))
const strings = (v: Value | undefined): string[] => (v === undefined ? [] : v.kind === "array" ? v.items.map(string) : bad(v))
const variant = (v: Value | undefined) => (v?.kind === "variant" ? v : bad(v))
const bool = (v: Value | undefined): boolean => (v === undefined ? false : v.kind === "variant" && (v.tag === "True" || v.tag === "False") ? v.tag === "True" : bad(v))

const DEPENDENCIES = ["dependencies", "peerDependencies", "devDependencies", "optionalDependencies"]

const entry = (v: Value): Entry => {
  const { tag, args } = variant(v)
  const s = (i: number) => string(args[i])
  switch (tag) {
    case "File":
      return { kind: "File", path: s(0), text: s(1) }
    case "Package":
      return { kind: "Package", dir: s(0), name: s(1), version: s(2), schema: s(3) }
    case "Npm":
      return { kind: "Npm", dir: s(0), json: Object.fromEntries([...fields(args[1])].map(([k, x]) => [k, DEPENDENCIES.includes(k) ? Object.fromEntries(strings(x).map((n) => [n, "*"])) : string(x)])) }
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

const readCases = (file: string): Case[] =>
  parseAll(readFileSync(join(SUITE, file), "utf8")).map((v) => {
    const c = variant(v)
    if (c.tag !== "Case") bad(c)
    const f = fields(c.args[0])
    const mode = variant(f.get("mode"))
    if (mode.tag !== "Explicit") bad(mode)
    const given = fields(mode.args[0])
    const e = variant(f.get("expect"))
    const ef = fields(e.args[0])
    return {
      name: string(f.get("name")),
      files: (f.get("files")?.kind === "array" ? (f.get("files") as Extract<Value, { kind: "array" }>).items : []).map(entry),
      root: string(f.get("root")),
      rootDir: f.get("rootDir") === undefined ? undefined : string(f.get("rootDir")),
      ecosystem: string(f.get("ecosystem")),
      unix: f.get("os") !== undefined,
      packages: strings(given.get("packages")),
      folders: strings(given.get("folders")),
      should: bool(f.get("should")),
      shapeOnly: strings(f.get("shapeOnly")),
      withRule: strings(f.get("withRule")),
      expect: e.tag === "Ok"
        ? { ok: true, packages: strings(ef.get("packages")) }
        : { ok: false, code: string(ef.get("code")), mentions: strings(ef.get("mentions")), hides: strings(ef.get("hides")) },
    }
  })

// ── running a case ───────────────────────────────────────────

/** Write the case's tree into a fresh temporary directory. */
const write = (files: readonly Entry[]): string => {
  const root = mkdtempSync(join(tmpdir(), "haus-effect-packages-"))
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
    symlinkSync(process.platform === "win32" ? e.target.replaceAll("/", "\\") : e.target, at, existsSync(target) && statSync(target).isDirectory() ? "dir" : "file")
  }
  for (const e of files) if (e.kind === "Mode") chmodSync(join(root, e.path), e.mode)
  return root
}

const restore = (root: string, files: readonly Entry[]): void => {
  for (const e of files) if (e.kind === "Mode") chmodSync(join(root, e.path), e.mode | 0o700)
}

/** The program's choices of a rules.haus case: a package taken shape-only, its rules supplied (each accepting every value). */
const programOf = (c: Case) => (p: Haus.PackageType): Effect.Effect<Haus.PackageType, Haus.HausConfigError> =>
  Effect.reduce(
    c.withRule.filter((id) => id.startsWith(`${p.name}@`)),
    () => (c.shapeOnly.includes(p.name) ? Haus.Package.shapeOnly(p) : p),
    (pkg, id) => Haus.Package.withRule(pkg, id, () => true),
  )

/** Read and compile the case, as a program does: read, then make its choices, then compile. */
const compileCase = (c: Case, dir: string) =>
  Effect.gen(function* () {
    const sources = yield* Haus.readSources(join(dir, c.root), {
      packages: c.packages.map((p) => join(dir, p)),
      folders: c.folders.map((f) => join(dir, f)),
      ...(c.rootDir === undefined ? {} : { root: join(dir, c.rootDir) }),
    })
    const program = programOf(c)
    const packages = yield* Effect.forEach(sources.packages, program)
    const folders = yield* Effect.forEach(sources.folders, (f) => Effect.map(Effect.forEach(f.packages, program), (ps) => ({ ...f, packages: ps })))
    // Official packages taken shape-only are given as values: they are built in, never read.
    const official = c.shapeOnly.flatMap((n) => {
      const p = OFFICIAL.get(n)
      return p === undefined ? [] : [Haus.Package.shapeOnly(p)]
    })
    return yield* Haus.compile(sourcesOf({ ...sources, packages: [...packages, ...official], folders }))
  }).pipe(Effect.provide(NodeSchemaFiles.layer))

const run = (c: Case): void => {
  const dir = write(c.files)
  try {
    const exit = Effect.runSyncExit(compileCase(c, dir))
    if (c.expect.ok) {
      if (Exit.isFailure(exit)) throw new Error(Cause.pretty(exit.cause))
      expect([...exit.value.packages.values()].map((p) => `${p.name}@${p.version}`).sort()).toEqual([...c.expect.packages].sort())
      return
    }
    expect(Exit.isFailure(exit), "the schema compiles, but should fail").toBe(true)
    if (Exit.isSuccess(exit)) return
    const e = Option.getOrThrowWith(Cause.findErrorOption(exit.cause), () => new Error(`not a typed failure: ${Cause.pretty(exit.cause)}`))
    expect(e._tag, e.message).toBe("HausCompileError")
    expect(e._tag === "HausCompileError" ? e.code : undefined, e.message).toBe(c.expect.code)
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
  describe(`package suite through Effect (test-suite/packages/${file})`, () => {
    for (const c of cases) {
      const skip = skipped(c)
      if (skip !== undefined) {
        skips.push(`${c.name} (${skip})`)
        it.skip(`${c.name}: ${skip}`, () => {})
      } else {
        // A FIFO opened blocking would hang: the read must not (the core opens without blocking).
        it(`${c.name}${c.should ? " (should)" : ""}`, { timeout: 5000 }, () => {
          run(c)
          ran++
        })
      }
    }
    it(`ran the cases of ${file}`, () => {
      expect(cases.length).toBe(TOTALS[file])
      expect(ran).toBe(cases.filter((c) => skipped(c) === undefined).length)
      console.log(`package suite (Effect) ${file}: ${ran} of ${cases.length} cases run, ${skips.length} skipped${skips.length ? `: ${skips.join(", ")}` : ""}`)
    })
  })
}
