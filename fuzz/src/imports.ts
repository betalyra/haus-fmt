/**
 * Differential testing of relative imports on real file trees (spec §13.3,
 * "Resolution", "The root", "Files read"): generated trees of schema files
 * that import each other with `.` and `..`, through nested directories,
 * names spelled in another case or Unicode normalization, symbolic links to
 * files and directories, packages' directories and a `root` option, written
 * into a fresh directory under $TMPDIR. Each binding builds the schema of an
 * entry file; they must agree with each other and with the Lean reference
 * (its resolver on a model of the same tree, `haus-ref --packages-batch`)
 * on the outcome: built, or the error code. Unix only: links need it.
 * See ../README.md, "Relative imports".
 *
 *   node fuzz/src/main.ts --imports [--count N] [--seed S] [--runners lean,typescript,rust,…]
 *
 * A runner reads lines `ENTRY ROOT`, the entry file's absolute path and the
 * build's `root` option (`-` for none), each as hex of its UTF-8, and prints
 * `ok OWN IMPORTED` (the entry file's own type names and those it imports,
 * sorted and joined by `,`, `-` for none) or `err CODE` (spec §17).
 */
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"
import { parseArgs } from "node:util"
import { parseSchemaFile } from "../../typescript/packages/haus/dist/index.js"
import { readSchemaFile } from "../../typescript/packages/haus/dist/node.js"
import { Rng } from "./generate.ts"
import { external, inProcess, type LineRunner } from "./lines.ts"
import { runProgram, timeoutFor } from "./spawn.ts"

const root = new URL("../..", import.meta.url).pathname

export type Entry =
  | { readonly kind: "File"; readonly path: string; readonly text: string }
  | { readonly kind: "Link"; readonly path: string; readonly target: string }
  | { readonly kind: "Package"; readonly dir: string; readonly schema: string }

export interface ImportCase {
  readonly files: readonly Entry[]
  /** The entry file, relative to the case's directory. */
  readonly entry: string
  /** The build's `root` option, relative to the case's directory. */
  readonly rootDir?: string
  /** Imports that may fail (spelled wrong, through a link, into a package…): codes are compared where there is at most one. */
  readonly suspects: number
}

// ── generating ───────────────────────────────────────────────

// Paths are ASCII (grammar.ebnf, `path_name`): a name in another script can't be imported (misspell writes such paths).
const NAMES = ["common", "x", "y", "util", "money", "Common", "X", "a-b", "_z", "9", "v1.2"]
const NOT_ASCII = ["café", "café", "a-b", "_z", "9"]
const DIRS = ["sub", "lib", "shared", "Lib", "inner", "deep/er", "x.schema.haus"]

/** `to` (a file without `.schema.haus`) as a relative import from the directory `from`. */
function relative(from: string, to: string): string {
  const f = from === "" ? [] : from.split("/")
  const t = to.split("/")
  let i = 0
  while (i < f.length && i < t.length - 1 && f[i] === t[i]) i++
  const up = f.length - i
  return (up === 0 ? "./" : "../".repeat(up)) + t.slice(i).join("/")
}

/** A path spelled wrong in one of the ways §13.3 rules out, or that names another file. */
function misspell(r: Rng, path: string): string {
  const names = path.split("/")
  const named = names.map((n, i) => (n !== "." && n !== ".." ? i : -1)).filter((i) => i >= 0)
  const at = r.pick(named)
  const swap = (f: (n: string) => string) => names.map((n, i) => (i === at ? f(n) : n)).join("/")
  switch (r.int(12)) {
    case 0: return swap((n) => (n[0] === n[0]!.toUpperCase() ? n.toLowerCase() : n[0]!.toUpperCase() + n.slice(1)))
    case 1: return swap(() => r.pick(NOT_ASCII))
    case 2: return path + "/"
    case 3: return path.replace("/", "//")
    case 4: return names.slice(0, -1).join("/") + "/./" + names[names.length - 1]
    case 5: return names.slice(0, -1).join("/") + "/../" + names.slice(-1)[0]
    case 6: return "./" + path
    case 7: return path.replace(/^\.\//, "")
    case 8: return path + ".schema.haus"
    case 9: return "../" + path.replace(/^\.\//, "")
    case 10: return r.pick(["./", "../", "./.", "..", ".", "../..", "./..", "./ x"])
    default: return "../".repeat(1 + r.int(4)) + names.filter((n) => n !== "." && n !== "..").join("/")
  }
}

export function importCase(r: Rng): ImportCase {
  const files: Entry[] = []
  /** Names already in each directory, as a file system that ignores case and normalization sees them. */
  const taken = new Map<string, Set<string>>()
  /** What each path is: a directory or a file (a link counts as a file). */
  const claimed = new Map<string, "dir" | "file">()
  /** Claims `path` for a file, and its parents for directories; false if that clashes with what is there. */
  const claim = (path: string): boolean => {
    const parts = path.split("/")
    const wants = parts.map((_, i) => [parts.slice(0, i + 1).join("/"), i === parts.length - 1 ? "file" : "dir"] as const)
    for (const [full, kind] of wants) {
      const dir = dirname(full) === "." ? "" : dirname(full)
      const key = full.split("/").pop()!.normalize("NFC").toLowerCase()
      const had = claimed.get(full)
      // A name already there must be this very name, and a directory on the way; nothing spelled otherwise.
      if (had !== undefined ? had !== kind || kind === "file" : taken.get(dir)?.has(key)) return false
    }
    for (const [full, kind] of wants) {
      const dir = dirname(full) === "." ? "" : dirname(full)
      taken.set(dir, (taken.get(dir) ?? new Set()).add(full.split("/").pop()!.normalize("NFC").toLowerCase()))
      claimed.set(full, kind)
    }
    return true
  }

  const base = r.pick(["", "proj/", "w/proj/"])
  const entryDir = base + r.pick(["app", "app/sub", "a/b/c", "src", "app/Lib"])
  const parent = dirname(entryDir) === "." ? "" : dirname(entryDir)
  const at = (d: string, n: string) => (d === "" ? n : `${d}/${n}`)
  const spots = [entryDir, at(entryDir, r.pick(DIRS)), parent, at(parent, r.pick(DIRS)), at(base.replace(/\/$/, ""), "shared"), "outside", at(entryDir, "deep/er/still")]

  // The entry file first: the other files' directories must not clash with its own.
  const entryName = r.pick(["a", "main", "é", "Root"])
  const entry = `${entryDir}/${entryName}.schema.haus`
  claim(entry)
  // The schema files other than the entry file (without .schema.haus), each defining T1, T2, …
  const targets: string[] = []
  const k = 1 + r.int(4)
  for (let i = 0; i < k * 2 && targets.length < k; i++) {
    const t = at(r.pick(spots), r.pick(NAMES))
    if (targets.includes(t) || !claim(t + ".schema.haus")) continue
    targets.push(t)
  }
  let suspects = 0
  const texts = new Map<string, string[]>()
  const link = (path: string, target: string): boolean => {
    if (!claim(path)) return false
    files.push({ kind: "Link", path, target })
    return true
  }
  /** An import of target j from the directory `from`, spelled right or not. */
  const importOf = (from: string, j: number): string => {
    let p = relative(from, targets[j]!)
    if (r.chance(0.12)) (p = misspell(r, p)), suspects++
    else reached.push(targets[j]!)
    return `import ${p} (T${j + 1})`
  }
  /** The files imports spelled right reach: one outside the root is a mistake too (counted below). */
  const reached: string[] = []
  targets.forEach((t, j) => {
    const lines: string[] = []
    const deps = targets.map((_, m) => m).filter((m) => m > j && r.chance(0.3))
    // Now and then a cycle: back to an earlier file.
    if (j > 0 && r.chance(0.03)) deps.push(0)
    for (const m of deps) lines.push(importOf(dirname(t) === "." ? "" : dirname(t), m))
    lines.push(deps.length ? `type T${j + 1} = { ${deps.map((m) => `f${m + 1}: T${m + 1}`).join(", ")} }` : `type T${j + 1} = Int`)
    texts.set(t, lines)
  })
  const uses = targets.map((_, j) => j).filter(() => r.chance(0.6))
  if (uses.length === 0 && targets.length) uses.push(0)
  const entryLines = uses.map((j) => importOf(entryDir, j))

  // Links: a directory or a file on an import's path, a dangling one; the entry file or the root through a link.
  let entryPath = entry
  // Imports through links name types no other import names: two imports of one name is another mistake (duplicate-import).
  const free = targets.map((_, j) => j).filter((j) => !uses.includes(j))
  if (r.chance(0.25)) {
    const kind = r.int(5)
    if (kind === 0 && free.length) {
      // A link to the directory of a target, and an import through it.
      const j = r.pick(free)
      const lnk = at(entryDir, "lnk")
      if (link(lnk, relative(entryDir, dirname(targets[j]!) + "/_").replace(/\/_$/, "").replace(/^\.\//, "") || ".")) {
        entryLines.push(`import ./lnk/${targets[j]!.split("/").pop()} (T${j + 1})`)
        uses.push(j)
        suspects++
      }
    } else if (kind === 1 && free.length) {
      const j = r.pick(free)
      if (link(at(entryDir, "l.schema.haus"), relative(entryDir, targets[j]!).replace(/^\.\//, "") + ".schema.haus")) {
        entryLines.push(`import ./l (T${j + 1})`)
        uses.push(j)
        suspects++
      }
    } else if (kind === 2) {
      if (link(at(entryDir, "gone.schema.haus"), "nowhere.schema.haus")) {
        entryLines.push("import ./gone (G)")
        suspects++
      }
    } else if (kind === 3) {
      // The entry file is a link: it is resolved to its real path once, at the start.
      if (link(at(entryDir, "entry.schema.haus"), `${entryName}.schema.haus`)) entryPath = at(entryDir, "entry.schema.haus")
    } else if (link("cur",entryDir.split("/").length === 1 ? entryDir : relative("", entryDir).replace(/^\.\//, ""))) {
      entryPath = `cur/${entryName}.schema.haus`
    }
  }
  // A package's directory with a schema file next to its schema.haus: importing it is package-path.
  if (r.chance(0.06)) {
    const dir = at(r.pick([entryDir, parent]), "vendor")
    if (claim(`${dir}/package.haus`) && claim(`${dir}/schema.haus`) && claim(`${dir}/extra.schema.haus`)) {
      files.push({ kind: "Package", dir, schema: "type P = Int" })
      files.push({ kind: "File", path: `${dir}/extra.schema.haus`, text: "type E = Int" })
      entryLines.push(`import ${relative(entryDir, `${dir}/extra`)} (E)`)
      suspects++
    }
  }
  // A directory where a file should be.
  if (r.chance(0.04) && claim(at(entryDir, "d.schema.haus/inner.txt"))) {
    files.push({ kind: "File", path: at(entryDir, "d.schema.haus/inner.txt"), text: "a directory" })
    entryLines.push("import ./d (D)")
    suspects++
  }
  entryLines.push(`type Root = { ${uses.map((j) => `f${j + 1}: T${j + 1}`).join(", ") || "n: Int"} }`)
  texts.set(entry.replace(/\.schema\.haus$/, ""), entryLines)
  for (const [t, lines] of texts) files.unshift({ kind: "File", path: `${t}.schema.haus`, text: lines.join("\n") + "\n" })

  // The root option: an ancestor of the entry file, sometimes not one, sometimes through a link.
  let rootDir: string | undefined
  const x = r.next()
  const ancestors = entryDir.split("/").map((_, i, a) => a.slice(0, i + 1).join("/"))
  if (x < 0.45) rootDir = ancestors[0]
  else if (x < 0.6) rootDir = r.pick(ancestors)
  else if (x < 0.65) (rootDir = r.pick(["outside", at(entryDir, "sub"), "elsewhere"])), suspects++
  else if (x < 0.72 && link("ws", ancestors[0]!)) rootDir = "ws"
  const top = rootDir === "ws" ? ancestors[0]! : (rootDir ?? entryDir)
  suspects += reached.filter((t) => !t.startsWith(`${top}/`)).length
  return { files, entry: entryPath, ...(rootDir === undefined ? {} : { rootDir }), suspects }
}

// ── writing the trees ────────────────────────────────────────

function write(dir: string, c: ImportCase): void {
  mkdirSync(dir, { recursive: true })
  const file = (path: string, text: string) => {
    mkdirSync(dirname(join(dir, path)), { recursive: true })
    writeFileSync(join(dir, path), text)
  }
  for (const e of c.files) {
    if (e.kind === "File") file(e.path, e.text)
    else if (e.kind === "Package") {
      file(`${e.dir}/package.haus`, '{ name: "@acme/p", version: "1.0.0" }')
      file(`${e.dir}/schema.haus`, e.schema)
    }
  }
  for (const e of c.files) {
    if (e.kind !== "Link") continue
    mkdirSync(dirname(join(dir, e.path)), { recursive: true })
    symlinkSync(e.target, join(dir, e.path))
  }
  // The root option may name a directory nothing else made.
  if (c.rootDir !== undefined) mkdirSync(join(dir, c.rootDir), { recursive: true })
}

/** The case in the package suite's format (test-suite/README.md), for Lean. */
function leanCase(c: ImportCase, n: number): string {
  const q = (s: string) => JSON.stringify(s)
  const entries = c.files.map((e) =>
    e.kind === "File" ? `File(${q(e.path)}, ${q(e.text)})`
    : e.kind === "Link" ? `Link(${q(e.path)}, ${q(e.target)})`
    : `Package(${q(e.dir)}, "@acme/p", "1.0.0", ${q(e.schema)})`)
  // A root option that is a directory of its own: Lean's tree has only what its entries make.
  if (c.rootDir !== undefined && !c.files.some((e) => (e.kind === "File" && e.path.startsWith(c.rootDir + "/")) || (e.kind === "Link" && e.path === c.rootDir)))
    entries.push(`File(${q(`${c.rootDir}/.keep`)}, "")`)
  const rootDir = c.rootDir === undefined ? "" : `rootDir: ${q(c.rootDir)}, `
  return `Case { name: "c${n}", ${rootDir}files: [${entries.join(", ")}], root: ${q(c.entry)}, ecosystem: "core", mode: Explicit {}, expect: Ok { packages: [] } },\n`
}

// ── the runners ──────────────────────────────────────────────

const hex = (s: string) => Buffer.from(s, "utf8").toString("hex")
const unhex = (h: string) => Buffer.from(h, "hex").toString("utf8")

const names = (xs: Iterable<string>) => [...xs].sort().join(",") || "-"

type Compile = (text: string, options: ReturnType<typeof readSchemaFile>["options"]) => { definitions: readonly { name: string }[]; imported: ReadonlyMap<string, unknown> }

/** The Node resolver's entry file (`readSchemaFile`), and its schema compiled by `compile`. */
const inThisProcess = (name: string, compile: Compile): LineRunner =>
  inProcess(name, (l) => {
    const [entry, rootOpt] = l.split(" ") as [string, string]
    try {
      const { text, options } = readSchemaFile(unhex(entry), { packages: [], folders: [], npm: false, ...(rootOpt === "-" ? {} : { root: unhex(rootOpt) }) })
      const f = compile(text, options)
      return `ok ${names(f.definitions.map((d) => d.name))} ${names(f.imported.keys())}`
    } catch (e) {
      const code = (e as { code?: unknown }).code
      if (typeof code === "string") return `err ${code}`
      throw e
    }
  })

/** @haus-fmt/effect's `Haus.compileSchemaFile`, with the options of TypeScript's Node resolver. */
async function effectRunner(): Promise<LineRunner> {
  const Haus = await import(pathToFileURL(join(root, "typescript/packages/effect/dist/index.js")).href)
  return inThisProcess("effect", (text, options) => Haus.compileSchemaFile(text, options).file)
}

const ALL = ["lean", "typescript", "effect", "rust", "python", "go", "jvm"]

async function runner(name: string): Promise<LineRunner> {
  switch (name) {
    case "typescript": return inThisProcess("typescript", parseSchemaFile)
    case "effect": return effectRunner()
    case "rust": return external("rust", join(root, "fuzz/schema-rust/target/release/import_runner"), [])
    case "python": return external("python", join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/api_runner.py"), "--imports"])
    case "go": return external("go", join(root, "fuzz/.build/go-runner"), ["--imports"])
    case "jvm": return external("jvm", join(root, "fuzz/.build/jvm-runner/bin/jvm-runner"), ["--imports"])
  }
  throw new Error(`unknown runner ${name} (${ALL.join(", ")}; Zig: TODO, see fuzz/README.md)`)
}

function lean(file: string, cases: readonly ImportCase[]): string[] {
  writeFileSync(file, cases.map(leanCase).join(""))
  const p = runProgram("lean", join(root, "spec/lean/.lake/build/bin/haus-ref"), ["--packages-batch", file], timeoutFor(cases.length))
  const out = (p.stdout ?? "").split("\n").filter((l) => l !== "")
  if (p.status !== 0 || out.length !== cases.length) throw new Error(`lean: exit ${p.status}, ${out.length} lines for ${cases.length}: ${(p.stderr ?? "").slice(0, 300)}`)
  // Lean reports the packages reached; here, where none are, only whether it built.
  return out.map((l) => (l.startsWith("ok ") ? "ok" : l))
}

// ── comparing ────────────────────────────────────────────────

const verdict = (o: string) => (o.startsWith("ok") ? "ok" : o.startsWith("err ") ? o : o.startsWith("crash") ? "crash" : `bad output`)

/** Who disagrees, by verdict (codes only where compared), and the type names of those that built it: empty if none. */
function pattern(names: readonly string[], outs: readonly string[], codes: boolean): string {
  const kinds = new Map<string, string[]>()
  outs.forEach((o, i) => {
    const v = verdict(o)
    const k = !codes && v.startsWith("err ") ? "err" : v
    kinds.set(k, [...(kinds.get(k) ?? []), names[i]!])
  })
  if (kinds.size > 1) return [...kinds].map(([k, ns]) => `${ns.join(",")}=${k}`).join(" vs ")
  // The same types, among those that report them (not Lean).
  const types = new Map<string, string[]>()
  outs.forEach((o, i) => {
    if (o.startsWith("ok ")) types.set(o, [...(types.get(o) ?? []), names[i]!])
  })
  return types.size > 1 ? `types differ: ${[...types.values()].map((ns) => ns.join(",")).join(" vs ")}` : ""
}

export async function run(argv: readonly string[]): Promise<number> {
  const { values: args } = parseArgs({
    args: [...argv],
    options: {
      count: { type: "string", default: "2000" },
      seed: { type: "string", default: String(Date.now() % 1_000_000) },
      out: { type: "string", default: "fuzz/.out/imports" },
      runners: { type: "string", default: ALL.join(",") },
      batch: { type: "string", default: "1000" },
      imports: { type: "boolean", default: false }, // from main.ts
    },
  })
  if (process.platform === "win32") {
    console.log("relative imports: skipped on Windows (the trees have symbolic links)")
    return 0
  }
  const count = Number(args.count)
  const seed = Number(args.seed)
  const out = args.out!
  mkdirSync(out, { recursive: true })
  const wanted = args.runners!.split(",")
  const useLean = wanted.includes("lean")
  const runners: LineRunner[] = []
  for (const n of wanted.filter((n) => n !== "lean")) runners.push(await runner(n))
  const allNames = [...(useLean ? ["lean"] : []), ...runners.map((r) => r.name)]
  // Each run's trees in a directory of their own, which nothing deletes (the system cleans $TMPDIR).
  const trees = mkdtempSync(join(process.env.TMPDIR ?? tmpdir(), "haus-imports-"))
  const file = join(out, "cases.txt")
  let written = 0

  const runAll = (cases: readonly ImportCase[]): string[][] => {
    const lines = cases.map((c) => {
      const dir = join(trees, String(written++))
      write(dir, c)
      return `${hex(join(dir, c.entry))} ${c.rootDir === undefined ? "-" : hex(join(dir, c.rootDir))}`
    })
    const byRunner = [...(useLean ? [lean(join(out, "lean.cases.haus"), cases)] : []), ...runners.map((r) => r.run(file, lines))]
    return cases.map((_, i) => byRunner.map((rs) => rs[i]!))
  }
  const patternOf = (c: ImportCase, rs: readonly string[]) => pattern(allNames, rs, c.suspects <= 1)

  /** Smaller cases: an entry of the tree or a line of a file removed, the root option dropped. */
  const smaller = (c: ImportCase): ImportCase[] => {
    const out: ImportCase[] = []
    c.files.forEach((e, i) => {
      if (e.kind === "File" && e.path === c.entry) return
      out.push({ ...c, files: c.files.filter((_, j) => j !== i) })
    })
    c.files.forEach((e, i) => {
      if (e.kind !== "File") return
      const lines = e.text.split("\n").filter((l) => l !== "")
      lines.forEach((_, k) => out.push({ ...c, files: c.files.map((f, j) => (j === i ? { ...e, text: lines.filter((_, m) => m !== k).join("\n") + "\n" } : f)) }))
    })
    if (c.rootDir !== undefined) {
      const { rootDir: _, ...rest } = c
      out.push(rest)
    }
    return out
  }
  const shrink = (c: ImportCase, want: string): ImportCase => {
    let best = c
    for (let round = 0; round < 40; round++) {
      const cands = smaller(best)
      if (cands.length === 0) break
      const rs = runAll(cands)
      const i = rs.findIndex((x, k) => patternOf(cands[k]!, x) === want)
      if (i < 0) break
      best = cands[i]!
    }
    return best
  }

  const rng = new Rng(seed)
  const batch = Number(args.batch)
  const MAX_SHRUNK = 10
  const found = new Map<string, { c: ImportCase; count: number }>()
  const outcomes = new Map<string, number>()
  console.log(`seed ${seed}: ${count} file trees (in ${trees}) through ${allNames.join(", ")}`)
  for (let done = 0; done < count; done += batch) {
    const cases = Array.from({ length: Math.min(batch, count - done) }, () => importCase(rng))
    const results = runAll(cases)
    results.forEach((rs, i) => {
      const v = verdict(rs[0]!)
      outcomes.set(v, (outcomes.get(v) ?? 0) + 1)
      const p = patternOf(cases[i]!, rs)
      if (p === "") return
      const f = found.get(p)
      if (f) return void f.count++
      if (found.size >= MAX_SHRUNK) return void found.set(p, { c: cases[i]!, count: 1 })
      console.error(`disagreement: ${p}; shrinking`)
      found.set(p, { c: shrink(cases[i]!, p), count: 1 })
    })
  }
  console.log(`outcomes (${allNames[0]}): ${[...outcomes].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k} ${n}`).join(", ")}`)
  mkdirSync(join(out, "failures"), { recursive: true })
  const reports = [...found].map(([p, f], n) => {
    const rs = runAll([f.c])[0]!
    writeFileSync(join(out, "failures", `${n}.cases.haus`), leanCase(f.c, n))
    return `DISAGREEMENT ${p} (${f.count} cases; saved to ${join(out, "failures", `${n}.cases.haus`)}):\n  ${leanCase(f.c, n).trim()}\n${rs.map((o, i) => `  ${allNames[i]!.padEnd(10)} ${o.slice(0, 300)}`).join("\n")}`
  })
  writeFileSync(join(out, "failures.txt"), reports.join("\n\n") + "\n")
  if (reports.length === 0) console.log("no disagreements")
  for (const r of reports) console.log(`\n${r}`)
  return reports.length ? 1 : 0
}
