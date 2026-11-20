/**
 * Speed in TypeScript, with tinybench: JSON.parse / JSON.stringify against
 * the haus binding, on the same documents (convert proved each haus
 * document is the JSON document's value: the round trip).
 *
 *   speed [--quick] [--sources vega-lite]     --quick: tiny time budget, to check the harness runs
 *
 * Reads the corpus convert exported (<out>/<source>/corpus/, size/src/export.ts),
 * the same files every language's speed benchmark reads. Inputs are the
 * wire forms: minified JSON and minimised haus (enums as tags).
 *
 *   corpus    the whole corpus in one text: a JSON array (all.json), a haus stream (all.haus)
 *   per doc   every document on its own, one call each (the time is for all of them)
 *
 * Tasks:
 *   parse   JSON.parse                 vs haus parse (text → Value tree, no schema)
 *   typed   haus parse + decode with the document's schema (h.parse; text → plain JS values, checked)
 *   write   JSON.stringify(JS value)   vs haus stringify(Value), minimised and compact
 *
 * The timed functions are plain closures over the inputs, built before the
 * run: no Effect inside them. Effect prepares the inputs, runs the checks,
 * runs tinybench (one promise) and writes the results.
 *
 * Fair play: every output is consumed (its size goes into a checksum that is
 * printed), and before timing each pair is checked once: haus text parses to
 * a value that writes back to the same text, JSON.parse gives a value that
 * JSON.stringify writes back to the same text (where it doesn't, because of
 * number spelling, the count is reported), the typed decode succeeds, and
 * the corpus texts are the documents' (the same values, in order). Garbage
 * is collected before each task when the runtime exposes a collector (Host).
 *
 * Writes <source>/speed-typescript.json, one source after the other.
 */
import { compileSchemaFile, equals, format, parse, parseAll, stringify, type Value } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"
import { Console, Effect, Option } from "effect"
import { Bench } from "tinybench"
import { BenchmarkError, messageOf, SpeedCheckError } from "../../size/src/errors.ts"
import { allJson, readExport, type Exported } from "../../size/src/export.ts"
import { Host } from "../../size/src/host.ts"
import { Results, speedFile, type SpeedOut, type SpeedRow } from "../../size/src/results.ts"
import { selectSources, type Selection } from "../../size/src/sources.ts"
import { sum, utf8Length } from "../../size/src/stats.ts"

/** The harness, as recorded in the results (the version bench/package.json pins). */
const HARNESS = "tinybench 6.2.3"

/** Inputs, prepared once. */
interface Inputs {
  readonly ids: readonly string[]
  readonly schemaOf: readonly h.AnySchema[]
  readonly jsonTexts: readonly string[]
  readonly hausTexts: readonly string[]
  readonly jsonCorpus: string
  readonly hausValues: readonly Value[]
  readonly hausCorpus: string
  readonly jsValues: readonly unknown[]
}

const prepare = Effect.fn("speed.prepare")(function* (exported: Exported) {
  const docs = exported.documents
  if (docs.length === 0) return yield* new SpeedCheckError({ message: "no documents: run convert first" })
  const schemas = yield* Effect.try({ try: () => compileSchemaFile(exported.schemaText).schemas, catch: (e) => new SpeedCheckError({ message: `the schema: ${messageOf(e)}` }) })
  const schemaOf = yield* Effect.forEach(docs, (d) => {
    const s = schemas[d.root]
    return s === undefined ? Effect.fail(new SpeedCheckError({ message: `no schema ${d.root}` })) : Effect.succeed(s)
  })
  return yield* Effect.try({
    try: (): Inputs => {
      const jsonTexts = docs.map((d) => d.json)
      const hausTexts = docs.map((d) => d.haus)
      return {
        ids: docs.map((d) => d.id), schemaOf, jsonTexts, hausTexts,
        hausValues: hausTexts.map((t) => parse(t)),
        jsonCorpus: exported.allJson,
        hausCorpus: exported.allHaus,
        jsValues: jsonTexts.map((t) => JSON.parse(t) as unknown),
      }
    },
    catch: (e) => new SpeedCheckError({ message: messageOf(e) }),
  })
})

/** The checks before timing; the number of documents whose JSON doesn't round-trip through JS values. */
const check = (i: Inputs) =>
  Effect.try({
    try: () => {
      const jsonNotStable = i.ids.filter((id, k) => {
        if (stringify(i.hausValues[k]!, { style: "minimised" }) !== i.hausTexts[k]) throw new Error(`${id}: haus parse → stringify is not the same text`)
        h.decode(i.schemaOf[k]!, i.hausValues[k]!)
        return JSON.stringify(i.jsValues[k]) !== i.jsonTexts[k]
      }).length
      const corpusValues = parseAll(i.hausCorpus)
      if (corpusValues.length !== i.ids.length || !corpusValues.every((v, k) => equals(v, i.hausValues[k]!))) throw new Error("the haus corpus stream reads as other values")
      if (format(i.hausValues, { style: "minimised" }) !== i.hausCorpus) throw new Error("the haus corpus stream isn't the documents' minimised stream")
      if (allJson(i.jsonTexts) !== i.jsonCorpus) throw new Error("the JSON corpus isn't the documents' array")
      return jsonNotStable
    },
    catch: (e) => new SpeedCheckError({ message: messageOf(e) }),
  })

type Meta = Pick<SpeedRow, "group" | "input" | "format" | "impl" | "bytes" | "docs">

/**
 * The tinybench tasks. Each body is the plain library call in a loop, its
 * output consumed into `checksum`.
 */
const makeBench = (i: Inputs, options: { readonly time: number; readonly warmupTime: number; readonly gc: Option.Option<() => void> }) => {
  const { ids, schemaOf, jsonTexts, hausTexts, jsonCorpus, hausValues, hausCorpus, jsValues } = i
  const gc = Option.getOrUndefined(options.gc)
  let checksum = 0
  const bench = new Bench({ time: options.time, warmup: true, warmupTime: options.warmupTime, throws: true, setup: () => gc?.() })
  const bytes = (texts: readonly string[]) => sum(texts.map(utf8Length))
  const meta = new Map<string, Meta>()
  const task = (group: SpeedRow["group"], input: SpeedRow["input"], impl: string, size: number, fn: () => void) => {
    const name = `${group} | ${input} | ${impl}`
    meta.set(name, { group, input, format: impl.startsWith("JSON") ? "json" : "haus", impl, bytes: size, docs: ids.length })
    bench.add(name, fn)
  }

  task("parse", "corpus", "JSON.parse", utf8Length(jsonCorpus), () => {
    checksum += (JSON.parse(jsonCorpus) as unknown[]).length
  })
  task("parse", "corpus", "haus parseAll", utf8Length(hausCorpus), () => {
    checksum += parseAll(hausCorpus).length
  })
  task("parse", "per doc", "JSON.parse", bytes(jsonTexts), () => {
    for (const t of jsonTexts) checksum += JSON.parse(t) === null ? 0 : 1
  })
  task("parse", "per doc", "haus parse", bytes(hausTexts), () => {
    for (const t of hausTexts) checksum += parse(t).kind.length
  })
  task("typed", "corpus", "haus parseAll + decode", utf8Length(hausCorpus), () => {
    parseAll(hausCorpus).forEach((v, k) => {
      checksum += h.decode(schemaOf[k]!, v) === undefined ? 0 : 1
    })
  })
  task("typed", "per doc", "haus parse + decode (h.parse)", bytes(hausTexts), () => {
    hausTexts.forEach((t, k) => {
      checksum += h.parse(schemaOf[k]!, t) === undefined ? 0 : 1
    })
  })
  task("write", "corpus", "JSON.stringify", utf8Length(jsonCorpus), () => {
    checksum += JSON.stringify(jsValues).length
  })
  task("write", "corpus", "haus format minimised", utf8Length(hausCorpus), () => {
    checksum += format(hausValues, { style: "minimised" }).length
  })
  task("write", "per doc", "JSON.stringify", bytes(jsonTexts), () => {
    for (const v of jsValues) checksum += JSON.stringify(v).length
  })
  task("write", "per doc", "haus stringify minimised", bytes(hausTexts), () => {
    for (const v of hausValues) checksum += stringify(v, { style: "minimised" }).length
  })
  task("write", "per doc", "haus stringify compact", bytes(hausValues.map((v) => stringify(v, { style: "compact" }))), () => {
    for (const v of hausValues) checksum += stringify(v, { style: "compact" }).length
  })
  return { bench, meta, checksum: () => checksum }
}

/** A finished task as a row. */
const rowOf = (meta: Meta, t: Bench["tasks"][number]): Effect.Effect<SpeedRow, BenchmarkError> => {
  const r = t.result
  if (r.state !== "completed") return Effect.fail(new BenchmarkError({ task: t.name, message: `${r.state}${r.state === "errored" ? `: ${r.error.message}` : ""}` }))
  const mean = r.latency.mean
  return Effect.succeed({
    ...meta, hz: r.throughput.mean, mean_ms: mean, p75_ms: r.latency.p75, p99_ms: r.latency.p99, samples: r.latency.samplesCount,
    mb_s: meta.bytes / 1e6 / (mean / 1000), us_per_doc: (mean * 1000) / meta.docs,
  })
}

/** One line per row, for the terminal. Pure. */
export const speedLines = (out: SpeedOut): string[] => [
  `${out.machine.cpu}, ${out.machine.runtime}${out.options.quick ? " (quick: not for publishing)" : ""}`,
  ...out.rows.map((r) =>
    `${`${r.group} | ${r.input} | ${r.impl}`.padEnd(48)} ${r.mb_s.toFixed(1).padStart(8)} MB/s ${r.us_per_doc.toFixed(2).padStart(9)} µs/doc  p99 ${r.p99_ms.toFixed(2)} ms  (${r.samples} samples)`,
  ),
]

/** The speed tasks on one source's documents. */
const speedOf = Effect.fn("speed.source")(function* (source: string, quick: boolean) {
  const results = yield* Results
  const host = yield* Host
  const time = quick ? 50 : 2000
  const warmupTime = quick ? 10 : 500

  const exported = yield* readExport(source)
  const inputs = yield* prepare(exported)
  const jsonNotStable = yield* check(inputs)
  const { bench, meta, checksum } = makeBench(inputs, { time, warmupTime, gc: host.gc })
  yield* Effect.tryPromise({ try: () => bench.run(), catch: (e) => new BenchmarkError({ task: "run", message: messageOf(e) }) })
  const rows = yield* Effect.forEach(bench.tasks, (t) => rowOf(meta.get(t.name)!, t))

  const out: SpeedOut = {
    lang: "typescript",
    harness: HARNESS,
    machine: { cpu: host.cpu, cores: host.cores, memory_gb: host.memoryGb, os: host.os, runtime: `${bench.runtime} ${bench.runtimeVersion}`, gc: Option.isSome(host.gc) },
    options: { time_ms: time, warmup_ms: warmupTime, quick },
    documents: inputs.ids,
    jsonNotStable,
    rows,
    checksum: checksum(),
  }
  yield* results.write(source, speedFile("typescript"), out)
  yield* Console.log([source, ...speedLines(out)].join("\n"))
})

export const speed = Effect.fn("bench.speed")(function* (options: { readonly sources: Selection; readonly quick: boolean }) {
  const sources = yield* selectSources(options.sources)
  yield* Effect.forEach(sources, (s) => speedOf(s.name, options.quick), { discard: true })
})
