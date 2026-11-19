/**
 * Speed in TypeScript, with tinybench: JSON.parse / JSON.stringify against
 * the haus binding, on the same documents (convert proved each haus
 * document is the JSON document's value: the round trip).
 *
 *   speed [--quick] [--sources vega-lite]     --quick: tiny time budget, to check the harness runs
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
 * The timed functions are plain closures over the inputs, built before the
 * run: no Effect inside them. Effect prepares the inputs, runs the checks,
 * runs tinybench (one promise) and writes the results.
 *
 * Fair play: every output is consumed (its size goes into a checksum that is
 * printed), and before timing each pair is checked once: haus text parses to
 * a value that writes back to the same text, JSON.parse gives a value that
 * JSON.stringify writes back to the same text (where it doesn't, because of
 * number spelling, the count is reported), the typed decode succeeds. Garbage
 * is collected before each task when the runtime exposes a collector (Host).
 *
 * Writes <source>/speed.json, one source after the other.
 */
import { compileSchemaFile, equals, format, parse, parseAll, stringify, type Value } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"
import { Console, Effect, Option } from "effect"
import { Bench } from "tinybench"
import { BenchmarkError, messageOf, SpeedCheckError } from "../errors.ts"
import { Host } from "../host.ts"
import { CORPUS, Results, SPEED, type Converted, type SpeedOut, type SpeedRow } from "../results.ts"
import { selectSources, type Selection } from "../sources.ts"
import { sum, utf8Length } from "../stats.ts"

/** Inputs, prepared once. */
interface Inputs {
  readonly docs: readonly Converted[]
  readonly schemaOf: readonly h.AnySchema[]
  readonly jsonTexts: readonly string[]
  readonly hausTexts: readonly string[]
  readonly jsonCorpus: string
  readonly hausValues: readonly Value[]
  readonly hausCorpus: string
  readonly jsValues: readonly unknown[]
}

const prepare = Effect.fn("speed.prepare")(function* (docs: readonly Converted[], schemaText: string) {
  if (docs.length === 0) return yield* new SpeedCheckError({ message: "no documents: run convert first" })
  const schemas = yield* Effect.try({ try: () => compileSchemaFile(schemaText).schemas, catch: (e) => new SpeedCheckError({ message: `the schema: ${messageOf(e)}` }) })
  const schemaOf = yield* Effect.forEach(docs, (d) => {
    const s = schemas[d.root]
    return s === undefined ? Effect.fail(new SpeedCheckError({ message: `no schema ${d.root}` })) : Effect.succeed(s)
  })
  return yield* Effect.try({
    try: (): Inputs => {
      const jsonTexts = docs.map((d) => d.json_min)
      const hausTexts = docs.map((d) => d.haus_min)
      const hausValues = hausTexts.map((t) => parse(t))
      return {
        docs, schemaOf, jsonTexts, hausTexts, hausValues,
        jsonCorpus: `[${jsonTexts.join(",")}]`,
        hausCorpus: format(hausValues, { style: "minimised" }),
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
      const jsonNotStable = i.docs.filter((d, k) => {
        if (stringify(i.hausValues[k]!, { style: "minimised" }) !== d.haus_min) throw new Error(`${d.id}: haus parse → stringify is not the same text`)
        h.decode(i.schemaOf[k]!, i.hausValues[k]!)
        return JSON.stringify(i.jsValues[k]) !== d.json_min
      }).length
      const corpusValues = parseAll(i.hausCorpus)
      if (corpusValues.length !== i.docs.length || !corpusValues.every((v, k) => equals(v, i.hausValues[k]!))) throw new Error("the haus corpus stream reads as other values")
      if ((JSON.parse(i.jsonCorpus) as unknown[]).length !== i.docs.length) throw new Error("the JSON corpus array has the wrong length")
      return jsonNotStable
    },
    catch: (e) => new SpeedCheckError({ message: messageOf(e) }),
  })

type Meta = Pick<SpeedRow, "group" | "input" | "impl" | "bytes" | "docs">

/**
 * The tinybench tasks. Each body is the plain library call in a loop, its
 * output consumed into `checksum`.
 */
const makeBench = (i: Inputs, options: { readonly time: number; readonly warmupTime: number; readonly gc: Option.Option<() => void> }) => {
  const { docs, schemaOf, jsonTexts, hausTexts, jsonCorpus, hausValues, hausCorpus, jsValues } = i
  const gc = Option.getOrUndefined(options.gc)
  let checksum = 0
  const bench = new Bench({ time: options.time, warmup: true, warmupTime: options.warmupTime, throws: true, setup: () => gc?.() })
  const bytes = (texts: readonly string[]) => sum(texts.map(utf8Length))
  const meta = new Map<string, Meta>()
  const task = (group: SpeedRow["group"], input: SpeedRow["input"], impl: string, size: number, fn: () => void) => {
    const name = `${group} | ${input} | ${impl}`
    meta.set(name, { group, input, impl, bytes: size, docs: docs.length })
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
  task("write", "per doc", "haus stringify compact", bytes(docs.map((d) => d.haus_compact)), () => {
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
  const corpus = yield* results.read(source, CORPUS, "convert")
  const time = quick ? 50 : 2000
  const warmupTime = quick ? 10 : 500

  const inputs = yield* prepare(corpus.documents, corpus.schemas.tags)
  const jsonNotStable = yield* check(inputs)
  const { bench, meta, checksum } = makeBench(inputs, { time, warmupTime, gc: host.gc })
  yield* Effect.tryPromise({ try: () => bench.run(), catch: (e) => new BenchmarkError({ task: "run", message: messageOf(e) }) })
  const rows = yield* Effect.forEach(bench.tasks, (t) => rowOf(meta.get(t.name)!, t))

  const out: SpeedOut = {
    machine: { cpu: host.cpu, cores: host.cores, memory_gb: host.memoryGb, os: host.os, runtime: `${bench.runtime} ${bench.runtimeVersion}`, gc: Option.isSome(host.gc) },
    options: { time_ms: time, warmup_ms: warmupTime, quick },
    documents: corpus.documents.map((d) => d.id),
    jsonNotStable,
    rows,
    checksum: checksum(),
  }
  yield* results.write(source, SPEED, out)
  yield* Console.log([source, ...speedLines(out)].join("\n"))
})

export const speed = Effect.fn("bench.speed")(function* (options: { readonly sources: Selection; readonly quick: boolean }) {
  const sources = yield* selectSources(options.sources)
  yield* Effect.forEach(sources, (s) => speedOf(s.name, options.quick), { discard: true })
})
