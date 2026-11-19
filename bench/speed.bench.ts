/**
 * Speed in TypeScript, with tinybench: JSON.parse / JSON.stringify against
 * the haus binding, on the same documents (convert.ts proved each haus
 * document is the JSON document's value: the round trip).
 *
 *   node --expose-gc speed.bench.ts [--quick]     --quick: tiny time budget, to check the harness runs
 *
 * Inputs are the wire forms: minified JSON and minimised haus (enums as tags).
 *
 *   corpus    the whole corpus in one text: a JSON array, a haus stream
 *   per doc   every document on its own, one call each (the time is for all of them)
 *
 * Tasks:
 *   parse   JSON.parse                 vs haus parse (text → Value tree, no schema)
 *   typed   haus parse + decode with the document's schema (h.parse; text → plain JS values, checked)
 *   write   JSON.stringify(JS value)   vs haus stringify(Value), minimised and compact
 *
 * Fair play: every output is consumed (its size goes into a checksum that is
 * printed), and before timing each pair is checked once: haus text parses to
 * a value that writes back to the same text, JSON.parse gives a value that
 * JSON.stringify writes back to the same text (where it doesn't, because of
 * number spelling, the count is reported), the typed decode succeeds. Garbage
 * is collected before each task when Node runs with --expose-gc.
 *
 * Writes .out/speed.json.
 */
import { readFileSync, writeFileSync } from "node:fs"
import { arch, cpus, platform, release, totalmem } from "node:os"
import { parseArgs } from "node:util"
import { compileSchemaFile, equals, format, parse, parseAll, stringify, type Value } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"
import { Bench } from "tinybench"
import { CORPUS_OUT, SPEED_OUT } from "./lib/paths.ts"
import type { CorpusOut, SpeedOut, SpeedRow } from "./lib/results.ts"

const { values: args } = parseArgs({ args: process.argv.slice(2).filter((a) => a !== "--"), options: { quick: { type: "boolean", default: false } } })
const quick = args.quick ?? false
const time = quick ? 50 : 2000
const warmupTime = quick ? 10 : 500

const corpus = JSON.parse(readFileSync(CORPUS_OUT, "utf8")) as CorpusOut
const docs = corpus.documents
if (docs.length === 0) throw new Error("no documents: run convert.ts first")
const schemas = compileSchemaFile(corpus.schemas.tags).schemas
const schemaOf = docs.map((d) => schemas[d.root] ?? (() => { throw new Error(`no schema ${d.root}`) })())

const jsonTexts = docs.map((d) => d.json_min)
const hausTexts = docs.map((d) => d.haus_min)
const jsonCorpus = `[${jsonTexts.join(",")}]`
const hausValues: Value[] = hausTexts.map((t) => parse(t))
const hausCorpus = format(hausValues, { style: "minimised" })
const jsValues: unknown[] = jsonTexts.map((t) => JSON.parse(t))

// ── checks, once, before timing ──────────────────────────────
let jsonNotStable = 0
docs.forEach((d, i) => {
  if (stringify(hausValues[i]!, { style: "minimised" }) !== d.haus_min) throw new Error(`${d.id}: haus parse → stringify is not the same text`)
  if (JSON.stringify(jsValues[i]) !== d.json_min) jsonNotStable++
  h.decode(schemaOf[i]!, hausValues[i]!)
})
const corpusValues = parseAll(hausCorpus)
if (corpusValues.length !== docs.length || !corpusValues.every((v, i) => equals(v, hausValues[i]!))) throw new Error("the haus corpus stream reads as other values")
if ((JSON.parse(jsonCorpus) as unknown[]).length !== docs.length) throw new Error("the JSON corpus array has the wrong length")

// ── tasks ────────────────────────────────────────────────────
let checksum = 0
const gc = (globalThis as { gc?: () => void }).gc
const bench = new Bench({ time, warmup: true, warmupTime, throws: true, setup: () => gc?.() })
const bytes = (texts: readonly string[]) => texts.reduce((n, t) => n + Buffer.byteLength(t), 0)
const meta = new Map<string, Pick<SpeedRow, "group" | "input" | "impl" | "bytes" | "docs">>()
const task = (group: SpeedRow["group"], input: SpeedRow["input"], impl: string, size: number, fn: () => void) => {
  const name = `${group} | ${input} | ${impl}`
  meta.set(name, { group, input, impl, bytes: size, docs: docs.length })
  bench.add(name, fn)
}

task("parse", "corpus", "JSON.parse", Buffer.byteLength(jsonCorpus), () => {
  checksum += (JSON.parse(jsonCorpus) as unknown[]).length
})
task("parse", "corpus", "haus parseAll", Buffer.byteLength(hausCorpus), () => {
  checksum += parseAll(hausCorpus).length
})
task("parse", "per doc", "JSON.parse", bytes(jsonTexts), () => {
  for (const t of jsonTexts) checksum += JSON.parse(t) === null ? 0 : 1
})
task("parse", "per doc", "haus parse", bytes(hausTexts), () => {
  for (const t of hausTexts) checksum += parse(t).kind.length
})
task("typed", "corpus", "haus parseAll + decode", Buffer.byteLength(hausCorpus), () => {
  parseAll(hausCorpus).forEach((v, i) => {
    checksum += h.decode(schemaOf[i]!, v) === undefined ? 0 : 1
  })
})
task("typed", "per doc", "haus parse + decode (h.parse)", bytes(hausTexts), () => {
  hausTexts.forEach((t, i) => {
    checksum += h.parse(schemaOf[i]!, t) === undefined ? 0 : 1
  })
})
task("write", "corpus", "JSON.stringify", Buffer.byteLength(jsonCorpus), () => {
  checksum += JSON.stringify(jsValues).length
})
task("write", "corpus", "haus format minimised", Buffer.byteLength(hausCorpus), () => {
  checksum += format(hausValues, { style: "minimised" }).length
})
task("write", "per doc", "JSON.stringify", bytes(jsonTexts), () => {
  for (const v of jsValues) checksum += JSON.stringify(v).length
})
task("write", "per doc", "haus stringify minimised", bytes(hausTexts), () => {
  for (const v of hausValues) checksum += stringify(v, { style: "minimised" }).length
})
task("write", "per doc", "haus stringify compact", bytes(docs.map((d) => d.haus_compact)), () => {
  for (const v of hausValues) checksum += stringify(v, { style: "compact" }).length
})

await bench.run()

const rows: SpeedRow[] = bench.tasks.map((t) => {
  const m = meta.get(t.name)!
  const r = t.result
  if (r.state !== "completed") throw new Error(`${t.name}: ${r.state}${r.state === "errored" ? `: ${r.error.message}` : ""}`)
  const mean = r.latency.mean
  return {
    ...m, hz: r.throughput.mean, mean_ms: mean, p75_ms: r.latency.p75, p99_ms: r.latency.p99, samples: r.latency.samplesCount,
    mb_s: m.bytes / 1e6 / (mean / 1000), us_per_doc: (mean * 1000) / m.docs,
  }
})

const out: SpeedOut = {
  machine: {
    cpu: cpus()[0]?.model ?? "unknown", cores: cpus().length, memory_gb: Math.round(totalmem() / 2 ** 30), os: `${platform()} ${release()} ${arch()}`,
    runtime: `${bench.runtime} ${bench.runtimeVersion}`, gc: gc !== undefined,
  },
  options: { time_ms: time, warmup_ms: warmupTime, quick },
  documents: docs.map((d) => d.id),
  jsonNotStable,
  rows,
  checksum,
}
writeFileSync(SPEED_OUT, JSON.stringify(out, null, 2))
console.log(`${out.machine.cpu}, ${out.machine.runtime}${quick ? " (quick: not for publishing)" : ""}`)
for (const r of rows) {
  console.log(`${`${r.group} | ${r.input} | ${r.impl}`.padEnd(48)} ${r.mb_s.toFixed(1).padStart(8)} MB/s ${r.us_per_doc.toFixed(2).padStart(9)} µs/doc  p99 ${r.p99_ms.toFixed(2)} ms  (${r.samples} samples)`)
}
