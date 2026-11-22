/** The package suite (test-suite/packages, spec §13.3): file trees resolved with the Node resolver. */
import { spawnSync } from "node:child_process"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { pathToFileURL } from "node:url"
import { describe, expect, it } from "vitest"
import { canonical, HausSchemaFileError, ModuleError, parseAll, parseSchemaFile, type Value } from "../src/index.js"
import { readSchemaFile, type NodeResolverOptions } from "../src/node.js"

const CASES = join(import.meta.dirname, "../../../../test-suite/packages/cases.haus")

type Entry =
  | { readonly kind: "File"; readonly path: string; readonly text: string }
  | { readonly kind: "Package"; readonly dir: string; readonly name: string; readonly version: string; readonly schema: string }
  | { readonly kind: "Npm"; readonly dir: string; readonly json: Record<string, unknown> }
  | { readonly kind: "Link"; readonly path: string; readonly target: string }
  | { readonly kind: "Fifo"; readonly path: string }
  | { readonly kind: "Large"; readonly path: string; readonly bytes: number }
  | { readonly kind: "Mode"; readonly path: string; readonly mode: number }

/** How packages are found: given explicitly, and with `Npm` also from node_modules. */
interface Mode {
  readonly kind: "Npm" | "Explicit"
  readonly packages: readonly string[]
  readonly folders: readonly string[]
}

type Expect =
  | { readonly ok: true; readonly packages: readonly string[] }
  | { readonly ok: false; readonly code: string; readonly mentions: readonly string[]; readonly hides: readonly string[] }

type Ecosystem = "core" | "npm" | "cargo"

interface Case {
  readonly name: string
  readonly files: readonly Entry[]
  /** The entry file. */
  readonly root: string
  /** The build's root option, relative to the temporary directory. */
  readonly rootDir: string | undefined
  readonly ecosystem: Ecosystem
  /** Only on Unix (a Fifo or Mode entry). */
  readonly unix: boolean
  readonly mode: Mode
  /** A case for the version check, which implementations SHOULD make (this one does). */
  readonly should: boolean
  readonly expect: Expect
}

/** The number of cases in cases.haus, and of each ecosystem: a reader that drops some fails. */
const TOTAL = 133
const ECOSYSTEMS: Readonly<Record<Ecosystem, number>> = { core: 87, npm: 46, cargo: 0 }

/**
 * Cases that are wrong in the suite, and why: they are expected to fail here
 * until the suite is fixed (and then fail this test, so the list is kept short).
 */
const BROKEN: Readonly<Record<string, string>> = {}

// ── reading the cases ────────────────────────────────────────

const bad = (v: Value | undefined): never => {
  throw new Error(`unexpected value in cases.haus: ${v === undefined ? "none" : canonical(v)}`)
}
const fields = (v: Value | undefined): ReadonlyMap<string, Value> => (v?.kind === "record" ? v.fields : v ? bad(v) : new Map())
const string = (v: Value | undefined): string => (v?.kind === "string" ? v.value : bad(v))
const strings = (v: Value | undefined): string[] => (v === undefined ? [] : v.kind === "array" ? v.items.map(string) : bad(v))
const variant = (v: Value | undefined) => (v?.kind === "variant" ? v : bad(v))

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

/** `Npm`, `Npm { packages?, folders? }` or `Explicit { packages?, folders? }`. */
const mode = (v: Value | undefined): Mode => {
  if (v?.kind === "variant" && (v.tag === "Npm" || v.tag === "Explicit")) {
    const f = fields(v.args[0])
    return { kind: v.tag, packages: strings(f.get("packages")), folders: strings(f.get("folders")) }
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

const cases: Case[] = parseAll(readFileSync(CASES, "utf8")).map((v) => {
  const c = variant(v)
  if (c.tag !== "Case") bad(c)
  const f = fields(c.args[0])
  const ecosystem = string(f.get("ecosystem"))
  if (ecosystem !== "core" && ecosystem !== "npm" && ecosystem !== "cargo") bad(f.get("ecosystem"))
  const os = f.get("os")
  if (os !== undefined && string(os) !== "unix") bad(os)
  return {
    name: string(f.get("name")),
    files: (f.get("files")?.kind === "array" ? (f.get("files") as Extract<Value, { kind: "array" }>).items : []).map(entry),
    root: string(f.get("root")),
    rootDir: f.get("rootDir") === undefined ? undefined : string(f.get("rootDir")),
    ecosystem: ecosystem as Ecosystem,
    unix: os !== undefined,
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
  // Permissions after the whole tree is written.
  for (const e of files) if (e.kind === "Mode") chmodSync(join(root, e.path), e.mode)
  return root
}

/** Give the owner back what Mode took (`chmod u+rwx`), so the tree can be removed. */
const restore = (root: string, files: readonly Entry[]): void => {
  for (const e of files) if (e.kind === "Mode") chmodSync(join(root, e.path), e.mode | 0o700)
}

/** The resolver options of a case written to `dir`. Explicit: only the packages given, node_modules is never read. */
const optionsOf = (c: Case, dir: string): NodeResolverOptions => ({
  packages: c.mode.packages.map((p) => join(dir, p)),
  folders: c.mode.folders.map((f) => join(dir, f)),
  npm: c.mode.kind === "Npm",
  ...(c.rootDir === undefined ? {} : { root: join(dir, c.rootDir) }),
})

const DIST = join(import.meta.dirname, "../dist")

/**
 * Load the schema in a child process (the built package, dist/) that is
 * killed after a few seconds: a FIFO opened blocking would hang the build,
 * and a hang in this process could not be stopped (test-suite/README.md).
 */
const loadsWithoutBlocking = (path: string, options: NodeResolverOptions): void => {
  const index = pathToFileURL(join(DIST, "index.js")).href
  const node = pathToFileURL(join(DIST, "node.js")).href
  expect(existsSync(join(DIST, "node.js")), "build the package first (pnpm build): the FIFO cases load it in a child process").toBe(true)
  const code = `const [{ parseSchemaFile }, { readSchemaFile }] = await Promise.all([import(${JSON.stringify(index)}), import(${JSON.stringify(node)})]);
try { const { text, options } = readSchemaFile(${JSON.stringify(path)}, JSON.parse(process.argv[1])); parseSchemaFile(text, options) } catch {}`
  const child = spawnSync(process.execPath, ["--input-type=module", "-e", code, JSON.stringify(options)], { timeout: 5000, killSignal: "SIGKILL" })
  expect(child.signal, "the build blocked (killed after 5 s)").toBeNull()
  expect(child.status, String(child.stderr)).toBe(0)
}

const run = (c: Case): void => {
  const dir = write(c.files)
  try {
    const path = join(dir, c.root)
    const options = optionsOf(c, dir)
    if (c.files.some((e) => e.kind === "Fifo")) loadsWithoutBlocking(path, options)
    // Every package the schema reaches, as name@version.
    const reached = new Set<string>()
    const load = () => {
      // The entry file is read as every file of the schema is: a regular file, opened without blocking.
      const { text, options: base } = readSchemaFile(path, options)
      const resolver = base.resolver!
      return parseSchemaFile(text, {
        ...base,
        resolver: {
          resolve(module, from) {
            const r = resolver.resolve(module, from)
            if (r.package !== undefined) reached.add(`${r.package}@${r.version}`)
            return r
          },
        },
      })
    }
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
    // At an import (HausSchemaFileError), or at no place (ModuleError: a root option that doesn't contain the entry file).
    expect(error instanceof HausSchemaFileError || error instanceof ModuleError, `the schema loads, but should fail: ${String(error)}`).toBe(true)
    const e = error as HausSchemaFileError | ModuleError
    expect(e.code, e.message).toBe(c.expect.code)
    // Paths in messages are compared with "/", whatever the OS writes.
    for (const m of c.expect.mentions) expect(e.message.replaceAll("\\", "/")).toContain(m)
    for (const h of c.expect.hides) expect(e.message).not.toContain(h)
    // Messages show paths relative to the root, never the temporary directory's (spec §13.3).
    expect(e.message).not.toContain(dir)
  } finally {
    restore(dir, c.files)
  }
}

/** Why this binding skips a case here, if it does: the npm ecosystem runs core and npm cases. */
const skipped = (c: Case): string | undefined => {
  if (c.ecosystem === "cargo") return "cargo"
  if (c.unix && process.platform === "win32") return "Unix only"
  if (c.files.some((e) => e.kind === "Mode") && process.getuid?.() === 0) return "Mode as root"
  return undefined
}

const ran: Record<Ecosystem, number> = { core: 0, npm: 0, cargo: 0 }
const skips: string[] = []
const count = (e: Ecosystem) => cases.filter((c) => c.ecosystem === e).length

describe("package suite (test-suite/packages)", () => {
  for (const c of cases) {
    const name = `${c.name} (${c.ecosystem}, ${c.mode.kind}${c.should ? ", should" : ""})`
    const skip = skipped(c)
    if (skip !== undefined) {
      skips.push(`${c.name} (${skip})`)
      it.skip(`${name}: ${skip}`, () => {})
    } else if (c.name in BROKEN) {
      it.fails(`${name}: broken in the suite: ${BROKEN[c.name]}`, () => run(c))
    } else {
      it(name, () => {
        run(c)
        ran[c.ecosystem]++
      })
    }
  }

  // This binding is of the npm ecosystem and makes the version check: it runs the core and npm cases, should ones too.
  it(`ran the core and npm cases of ${TOTAL}: ${count("core")} core, ${count("npm")} npm, ${count("cargo")} cargo (${cases.filter((c) => c.should).length} should)`, () => {
    expect(cases.length).toBe(TOTAL)
    expect({ core: count("core"), npm: count("npm"), cargo: count("cargo") }).toEqual(ECOSYSTEMS)
    const broken = cases.filter((c) => c.name in BROKEN && skipped(c) === undefined)
    const expected = (e: Ecosystem) => cases.filter((c) => c.ecosystem === e && skipped(c) === undefined && !(c.name in BROKEN)).length
    expect(ran).toEqual({ core: expected("core"), npm: expected("npm"), cargo: 0 })
    console.log(
      `package suite: ${ran.core + ran.npm} of ${cases.length} cases run (${ran.core} core, ${ran.npm} npm), ` +
        `${broken.length} broken in the suite (${broken.map((c) => c.name).join(", ") || "none"}), ${skips.length} skipped${skips.length ? `: ${skips.join(", ")}` : ""}`,
    )
  })
})
