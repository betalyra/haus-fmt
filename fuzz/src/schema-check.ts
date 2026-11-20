/**
 * Differential testing of the schema-file checkers (spec §14): generated
 * schema files (schema-check-gen.ts) through the Lean reference
 * (`Haus.SchemaFile.load`) and every binding's checker. They must agree on
 * accepting or rejecting every file; on a file with exactly one mistake (a
 * file Lean accepts, with one mistake added), on the error code too (§17:
 * which error a file with several reports is not fixed). Positions are not
 * compared: Lean reports none. See ../README.md.
 *
 *   node fuzz/src/main.ts --schema-check [--count N] [--seed S] [--out DIR] [--runners lean,typescript,…]
 */
import { spawnSync } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"
import { pathToFileURL } from "node:url"
import { compileSchemaFile } from "../../typescript/packages/haus/dist/index.js"
import { Rng } from "./generate.ts"
import { schemaFile, type SchemaFileCase } from "./schema-check-gen.ts"

const root = new URL("../..", import.meta.url).pathname

/** `ok`, `err` with the code of spec §17, or a crash. */
type Outcome = { readonly kind: "ok" } | { readonly kind: "err"; readonly code: string; readonly reason: string } | { readonly kind: "crash"; readonly reason: string }

interface Runner {
  readonly name: string
  run(file: string, cases: readonly Uint8Array[]): Outcome[]
}

const hex = (b: Uint8Array) => Buffer.from(b).toString("hex")

/** A runner's line: `ok`, or `err [LINE COLUMN] CODE REASON` (Lean prints no position). */
function parseOutcome(line: string, positions: boolean): Outcome {
  if (line === "ok") return { kind: "ok" }
  const m = (positions ? /^err \d+ \d+ (\S+) ?(.*)$/s : /^err (\S+) ?(.*)$/s).exec(line)
  return m ? { kind: "err", code: m[1]!, reason: m[2]! } : { kind: "crash", reason: `unexpected output: ${line.slice(0, 200)}` }
}

/**
 * A runner that is a separate program, `program [...args] FILE` with a file
 * of lines `HEX`. When it crashes or hangs, the cases are split in halves
 * until the ones that crash it are found.
 */
function external(name: string, program: string, args: readonly string[], positions = true): Runner {
  const run = (file: string, cases: readonly Uint8Array[]): Outcome[] => {
    const part = `${file}.${name}`
    writeFileSync(part, cases.map((c) => hex(c) + "\n").join(""))
    const p = spawnSync(program, [...args, part], { maxBuffer: 1 << 30, encoding: "utf8", timeout: 600_000 })
    const lines = (p.stdout ?? "").split("\n").filter((l) => l !== "")
    if (p.status === 0 && lines.length === cases.length) return lines.map((l) => parseOutcome(l, positions))
    if (cases.length === 1) {
      const why = p.error ? String(p.error) : p.signal ? `signal ${p.signal}` : `exit ${p.status}, ${lines.length} lines`
      return [{ kind: "crash", reason: `CRASH (${why}): ${(p.stderr ?? "").trim().split("\n").slice(0, 3).join(" ").slice(0, 300)}` }]
    }
    const mid = cases.length >> 1
    return [...run(file, cases.slice(0, mid)), ...run(file, cases.slice(mid))]
  }
  return { name, run }
}

const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })

/** A checker in this process: `compile` throws an error with a `code` for a file it rejects. */
function inProcess(name: string, compile: (text: string) => unknown): Runner {
  return {
    name,
    run: (_file, cases) =>
      cases.map((c) => {
        let text: string
        try {
          text = utf8.decode(c)
        } catch {
          return { kind: "err", code: "invalid-utf8", reason: "invalid UTF-8" }
        }
        try {
          compile(text)
          return { kind: "ok" }
        } catch (e) {
          const code = (e as { code?: unknown }).code
          if (typeof code === "string") return { kind: "err", code, reason: (e as Error).message }
          return { kind: "crash", reason: `CRASH: ${e instanceof Error ? `${e.name}: ${e.message}` : String(e)}`.slice(0, 300) }
        }
      }),
  }
}

/** @haus-fmt/effect's `Haus.compileSchemaFile`: the TypeScript parser and checker, its own schema builder. */
async function effectRunner(): Promise<Runner> {
  const dir = join(root, "typescript/packages/effect")
  const Haus = await import(pathToFileURL(join(dir, "dist/index.js")).href)
  return inProcess("effect", (t) => Haus.compileSchemaFile(t))
}

const ALL_RUNNERS = ["lean", "typescript", "effect", "rust", "python", "go", "swift"]

async function runner(name: string): Promise<Runner> {
  switch (name) {
    case "lean": return external("lean", join(root, "spec/lean/.lake/build/bin/haus-ref"), ["--schema-check-batch"], false)
    case "typescript": return inProcess("typescript", (t) => compileSchemaFile(t))
    case "effect": return effectRunner()
    case "rust": return external("rust", join(root, "fuzz/schema-rust/target/release/schema_check_runner"), [])
    case "python": return external("python", join(root, "python/.venv/bin/python"), [join(root, "python/fuzz/schema_check_runner.py")])
    case "go": return external("go", join(root, "fuzz/.build/go-runner"), ["--schema-check"])
    case "swift": return external("swift", join(root, "fuzz/.build/swift-runner"), ["--schema-check"])
  }
  throw new Error(`unknown runner ${name} (${ALL_RUNNERS.join(", ")}; Roc has no schema-file checker of its own)`)
}

/**
 * Disagreements with Lean that are known and reported, not counted as
 * failures (fuzz/README.md, "Schema files"). None today: add one only while
 * the spec decides it, with a test that matches exactly that disagreement.
 */
const KNOWN: readonly { readonly name: string; readonly test: (rs: readonly Outcome[]) => boolean }[] = []

const show = (o: Outcome) => (o.kind === "ok" ? "ok" : o.kind === "err" ? `err [${o.code}] ${o.reason.slice(0, 200)}` : o.reason)
const verdict = (o: Outcome) => (o.kind === "crash" ? "crash" : o.kind)

export async function run(argv: readonly string[]): Promise<number> {
  const { values: args } = parseArgs({
    args: [...argv],
    options: {
      count: { type: "string", default: "2000" },
      seed: { type: "string", default: String(Date.now() % 1_000_000) },
      out: { type: "string", default: "fuzz/.out/schema-check" },
      runners: { type: "string", default: ALL_RUNNERS.join(",") },
      batch: { type: "string", default: "2000" },
      "schema-check": { type: "boolean", default: false }, // from main.ts
    },
  })
  const count = Number(args.count)
  const seed = Number(args.seed)
  const out = args.out!
  mkdirSync(out, { recursive: true })
  const wanted = args.runners!.split(",")
  if (wanted[0] !== "lean") throw new Error("--runners must start with lean, the reference")
  const runners: Runner[] = []
  for (const name of wanted) runners.push(await runner(name))
  const file = join(out, "cases.txt")

  /** results[case][runner] */
  const runAll = (cases: readonly Uint8Array[]): Outcome[][] => {
    const byRunner = runners.map((r) => r.run(file, cases))
    return cases.map((_, i) => byRunner.map((rs) => rs[i]!))
  }
  /** Who disagrees with Lean on accepting or rejecting (crashes included): empty if all agree. */
  const pattern = (rs: readonly Outcome[]) =>
    rs.slice(1).flatMap((o, i) => (verdict(o) === verdict(rs[0]!) ? [] : [`${runners[i + 1]!.name}: ${verdict(o)}`])).join(", ") || (rs[0]!.kind === "crash" ? "lean: crash" : "")
  /** Who reports another code than Lean (for a file with one mistake). */
  const codePattern = (rs: readonly Outcome[]) => {
    const lean = rs[0]!
    if (lean.kind !== "err") return ""
    return rs.slice(1).flatMap((o, i) => (o.kind === "err" && o.code !== lean.code ? [`${runners[i + 1]!.name}: ${o.code}, lean ${lean.code}`] : [])).join(", ")
  }

  /** The shortest text with the same pattern of disagreement, by removing ever smaller slices. */
  const shrink = (bytes: Uint8Array, want: string): Uint8Array => {
    let best = bytes
    let size = Math.max(1, best.length >> 1)
    for (let round = 0; round < 300 && best.length > 1; round++) {
      const candidates: Uint8Array[] = []
      for (let at = 0; at < best.length; at += size) candidates.push(Uint8Array.from([...best.subarray(0, at), ...best.subarray(at + size)]))
      // Runners read one case a line: an empty file is a line of its own only as hex, so leave it out.
      const ok = candidates.filter((c) => c.length > 0)
      const i = runAll(ok).findIndex((rs) => pattern(rs) === want)
      if (i >= 0) best = ok[i]!
      else if (size > 1) size >>= 1
      else break
    }
    return best
  }

  const rng = new Rng(seed)
  const batch = Number(args.batch)
  const found = new Map<string, { bytes: Uint8Array; results: Outcome[]; count: number }>()
  let accepted = 0
  let single = 0
  let compared = 0
  const known = new Map<string, number>()
  console.log(`seed ${seed}: ${count} schema files through ${runners.map((r) => r.name).join(", ")}`)
  for (let done = 0; done < count; done += batch) {
    const cases: SchemaFileCase[] = Array.from({ length: Math.min(batch, count - done) }, () => schemaFile(rng)).map((c) =>
      c.bytes.length === 0 ? { bytes: Uint8Array.of(0x20) } : c)
    const results = runAll(cases.map((c) => c.bytes))
    // The bases of the files with one mistake: every checker must accept them for the codes to be compared.
    const withBase = cases.flatMap((c, i) => (c.base ? [i] : []))
    const bases = runAll(withBase.map((i) => (cases[i]!.base!.length ? cases[i]!.base! : Uint8Array.of(0x20))))
    const oneMistake = new Set(withBase.filter((_, k) => bases[k]!.every((o) => o.kind === "ok")))
    results.forEach((rs, i) => {
      if (rs[0]!.kind === "ok") accepted++
      const p = pattern(rs)
      const k = p === "" ? undefined : KNOWN.find((x) => x.test(rs))
      if (k) {
        known.set(k.name, (known.get(k.name) ?? 0) + 1)
        return
      }
      if (p !== "") {
        const f = found.get(p)
        if (f) {
          f.count++
          return
        }
        const small = shrink(cases[i]!.bytes, p)
        found.set(p, { bytes: small, results: runAll([small])[0]!, count: 1 })
        return
      }
      if (!oneMistake.has(i) || rs[0]!.kind !== "err") return
      single++
      compared += rs.slice(1).filter((o) => o.kind === "err").length
      const c = codePattern(rs)
      if (c === "") return
      const f = found.get(c)
      if (!f) found.set(c, { bytes: cases[i]!.bytes, results: rs, count: 1 })
      else {
        f.count++
        if (cases[i]!.bytes.length < f.bytes.length) Object.assign(f, { bytes: cases[i]!.bytes, results: rs })
      }
    })
  }
  console.log(`${accepted} accepted, ${count - accepted} rejected (by lean); ${single} with one mistake, ${compared} error codes compared`)
  for (const [name, n] of known) console.log(`known, not counted: ${name}: ${n} cases`)

  mkdirSync(join(out, "failures"), { recursive: true })
  const reports = [...found].map(([p, f], n) => {
    writeFileSync(join(out, "failures", `${n}.schema.haus`), f.bytes)
    return `DISAGREEMENT ${p} (${f.count} cases; smallest saved to ${join(out, "failures", `${n}.schema.haus`)}):\n  file: ${JSON.stringify(Buffer.from(f.bytes).toString("utf8"))}\n${f.results.map((o, i) => `  ${runners[i]!.name.padEnd(10)} ${show(o)}`).join("\n")}`
  })
  writeFileSync(join(out, "failures.txt"), reports.join("\n\n") + "\n")
  if (reports.length === 0) console.log("no disagreements")
  for (const r of reports) console.log(`\n${r}`)
  return reports.length ? 1 : 0
}
