/**
 * Differential testing: the same generated inputs through every haus parser,
 * reporting where they disagree. See ../README.md.
 *
 *   node fuzz/src/main.ts [--count N] [--seed S] [--out DIR] [--canonical]
 *   node fuzz/src/main.ts --schema [--count N] [--seed S] [--runners …]   schema decoding (schema.ts)
 *   node fuzz/src/main.ts --json [--count N] [--seed S] [--modes …] [--runners …]   the JSON mappings (json.ts)
 */
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { parseArgs } from "node:util"
import { input, Rng } from "./generate.ts"
import { activeRunners, runAll, useCanonical, type Result } from "./runners.ts"
import { run as runJson } from "./json.ts"
import { run as runSchema } from "./schema.ts"

const { values: args } = parseArgs({
  options: {
    count: { type: "string", default: "2000" },
    seed: { type: "string", default: String(Date.now() % 1_000_000) },
    out: { type: "string", default: "fuzz/.out" },
    // Compare the canonical forms (spec §12) instead of the parsed values.
    canonical: { type: "boolean", default: false },
    // Decode generated values with the schema suite's types instead (schema.ts).
    schema: { type: "boolean", default: false },
    // The JSON mappings instead (json.ts).
    json: { type: "boolean", default: false },
    modes: { type: "string" },
    runners: { type: "string" },
    batch: { type: "string" },
  },
})
if (args.canonical) useCanonical()
const runners = activeRunners()
const count = Number(args.count)
const seed = Number(args.seed)
const out = args.out!
const BATCH = 5000

/** What must agree: accepted with these values, or rejected. A crash (line -1) never agrees. */
const outcome = (r: Result) => (r.ok ? `ok ${r.json}` : r.line < 0 ? "crash" : "err")
/**
 * Error codes (spec §17) must agree too, among the runners that report them,
 * wherever they report an error at the same position (which error a parser
 * finds first is not fixed, §8; one at the same place is the same mistake).
 */
const codesByPosition = (rs: readonly Result[]) => {
  const byPosition = new Map<string, string[]>()
  for (const r of rs) {
    if (r.ok || r.code === undefined) continue
    const at = `${r.line}:${r.column}`
    byPosition.set(at, [...(byPosition.get(at) ?? []), r.code])
  }
  return [...byPosition.values()]
}
const codesDisagree = (rs: readonly Result[]) => codesByPosition(rs).some((codes) => new Set(codes).size > 1)
/** Whether two runners' codes were compared for this case. */
const codesCompared = (rs: readonly Result[]) => codesByPosition(rs).some((codes) => codes.length > 1)
const disagrees = (rs: readonly Result[]) => new Set(rs.map(outcome)).size > 1 || codesDisagree(rs)
/** Positions of the errors, where every parser reports one (line 0: no position, e.g. invalid UTF-8). */
const positionsDiffer = (rs: readonly Result[]) =>
  rs.every((r) => !r.ok && r.line > 0) && new Set(rs.map((r) => (r.ok ? "" : `${r.line}:${r.column}`))).size > 1

/**
 * The smallest input that still disagrees, found by removing ever smaller
 * slices (delta debugging). Each round runs every parser once on a batch of
 * candidates.
 */
function shrink(bytes: Uint8Array): Uint8Array {
  let best = bytes
  let size = Math.max(1, best.length >> 1)
  for (let round = 0; round < 400 && best.length > 1; round++) {
    const candidates: Uint8Array[] = []
    for (let at = 0; at < best.length; at += size) {
      candidates.push(Uint8Array.from([...best.subarray(0, at), ...best.subarray(at + size)]))
    }
    const results = runAll(join(out, "shrink"), candidates)
    const i = results.findIndex(disagrees)
    if (i >= 0) best = candidates[i]!
    else if (size > 1) size >>= 1
    else break
  }
  return best
}

const show = (bytes: Uint8Array) => JSON.stringify(Buffer.from(bytes).toString("utf8"))

function describe(bytes: Uint8Array): string {
  const rs = runAll(join(out, "shrink"), [bytes])[0]!
  return [
    `input: ${show(bytes)}`,
    ...rs.map((r, i) => `  ${runners[i]!.name.padEnd(10)} ${r.ok ? `ok ${r.json}` : `err ${r.line}:${r.column} ${r.code === undefined ? "" : `[${r.code}] `}${r.reason}`}`),
  ].join("\n")
}

// ── run ──────────────────────────────────────────────────────

if (args.schema) process.exitCode = await runSchema(process.argv.slice(2))
else if (args.json) process.exitCode = await runJson(process.argv.slice(2))
else runParsers()

function runParsers() {
  const suite = join(new URL("../..", import.meta.url).pathname, "test-suite")
  const seeds = ["valid", "invalid"].flatMap((d) =>
    readdirSync(join(suite, d)).filter((f) => f.endsWith(".haus")).map((f) => new Uint8Array(readFileSync(join(suite, d, f)))))

  const rng = new Rng(seed)
  const failures: Uint8Array[] = []
  const seen = new Set<string>()
  let accepted = 0
  let positionMismatches = 0
  let compared = 0
  const positionExamples: Uint8Array[] = []

  console.log(`seed ${seed}: ${count} cases through ${runners.map((r) => r.name).join(", ")}`)
  for (let done = 0; done < count; done += BATCH) {
    const cases = Array.from({ length: Math.min(BATCH, count - done) }, () => input(rng, seeds))
    const results = runAll(join(out, "cases"), cases)
    results.forEach((rs, i) => {
      if (rs[0]!.ok) accepted++
      if (codesCompared(rs)) compared++
      if (disagrees(rs)) {
        const small = shrink(cases[i]!)
        const key = show(small)
        if (!seen.has(key)) {
          seen.add(key)
          failures.push(small)
        }
      } else if (positionsDiffer(rs)) {
        positionMismatches++
        if (positionExamples.length < 5) positionExamples.push(cases[i]!)
      }
    })
  }

  console.log(`${accepted} accepted, ${count - accepted} rejected (by lean); error codes compared in ${compared}`)
  mkdirSync(join(out, "failures"), { recursive: true })
  if (failures.length === 0) console.log("no disagreements")
  failures.forEach((f, i) => {
    const report = describe(f)
    writeFileSync(join(out, "failures", `${i}.haus`), f)
    writeFileSync(join(out, "failures", `${i}.txt`), report + "\n")
    console.log(`\nDISAGREEMENT ${i} (shrunk, saved to ${join(out, "failures", `${i}.haus`)}):\n${report}`)
  })
  console.log(`\n${positionMismatches} cases rejected by all, at different positions`)
  for (const p of positionExamples) console.log(describe(p))
  process.exitCode = failures.length ? 1 : 0
}
