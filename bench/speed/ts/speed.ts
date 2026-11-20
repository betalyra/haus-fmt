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
 *   typed   haus parse + decode with the document's schema (h.parse; text → plain JS values, checked),
 *           against JSON.parse + a validator built from the same schema (validators.ts: Zod, Ajv,
 *           TypeBox), which checks what haus checks, on the JSON side
 *   write   JSON.stringify(JS value)   vs haus stringify(Value), minimised and compact;
 *           typed: fast-json-stringify (compiled from the same schema) vs haus h.stringify of
 *           the decoded values, minimised
 *
 * The baseline of a task (the report's "vs JSON") is the first JSON task of
 * its group and input: JSON.parse (for typed too) and JSON.stringify, which
 * are added first.
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
 * the corpus texts are the documents' (the same values, in order). The JSON
 * baselines: every validator accepts every document and rejects every
 * mutated one (mutate.ts); fast-json-stringify writes JSON of the value Zod
 * gives (the members the schema lists); the typed haus write reads back as
 * the same values. Garbage is collected before each task when the runtime
 * exposes a collector (Host).
 *
 * Writes <source>/speed-typescript.json, one source after the other.
 */
import { compileSchemaFile, equals, format, parse, parseAll, stringify, type Value } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"
import type { ValidateFunction } from "ajv"
import { Console, Effect, Option } from "effect"
import { Bench } from "tinybench"
import type { z } from "zod"
import { BenchmarkError, messageOf, SpeedCheckError } from "../../size/src/errors.ts"
import { allJson, readExport, type Exported } from "../../size/src/export.ts"
import { Host } from "../../size/src/host.ts"
import { Results, speedFile, type SpeedOut, type SpeedRow } from "../../size/src/results.ts"
import { selectSources, type Selection } from "../../size/src/sources.ts"
import { sum, utf8Length } from "../../size/src/stats.ts"
import { mutations, MUTATION_KINDS } from "./mutate.ts"
import { ajvValidators, jsonWriters, typeboxValidator, VERSIONS, zodSchemas, type JsonWriter } from "./validators.ts"

/** The harness, as recorded in the results (the version bench/package.json pins). */
const HARNESS = "tinybench 6.2.3"

const MIN = { style: "minimised" } as const

type TypeboxValidator = ReturnType<typeof typeboxValidator>

/** Inputs, prepared once. */
interface Inputs {
  readonly ids: readonly string[]
  readonly roots: readonly string[]
  readonly schemaOf: readonly h.AnySchema[]
  readonly jsonTexts: readonly string[]
  readonly hausTexts: readonly string[]
  readonly jsonCorpus: string
  readonly hausValues: readonly Value[]
  readonly hausCorpus: string
  readonly jsValues: readonly unknown[]
  /** h.parse of each document: the typed values haus's typed write writes. */
  readonly decoded: readonly unknown[]
  readonly zod: readonly z.ZodType[]
  readonly ajv: readonly ValidateFunction[]
  readonly typebox: readonly TypeboxValidator[]
  readonly jsonWriter: readonly ((value: unknown) => string)[]
  /** Roots whose fast-json-stringify writer writes variants by keys as JSON.stringify does (validators.ts `JsonWriter`). */
  readonly keyedAsAny: readonly string[]
  readonly exported: Exported
}

/** One per document, built once per root type. */
const perRoot = <A>(roots: readonly string[], make: (root: string) => A): A[] => {
  const byRoot = new Map<string, A>()
  return roots.map((r) => {
    const known = byRoot.get(r)
    if (known !== undefined) return known
    const made = make(r)
    byRoot.set(r, made)
    return made
  })
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
      const roots = docs.map((d) => d.root)
      const file = exported.jsonSchema
      const zodOf = zodSchemas(file)
      const ajvOf = ajvValidators(file)
      const writers: JsonWriter[] = perRoot(roots, jsonWriters(file))
      return {
        ids: docs.map((d) => d.id), roots, schemaOf, jsonTexts, hausTexts,
        hausValues: hausTexts.map((t) => parse(t)),
        jsonCorpus: exported.allJson,
        hausCorpus: exported.allHaus,
        jsValues: jsonTexts.map((t) => JSON.parse(t) as unknown),
        decoded: hausTexts.map((t, k) => h.parse(schemaOf[k]!, t)),
        zod: perRoot(roots, zodOf),
        ajv: perRoot(roots, ajvOf),
        typebox: perRoot(roots, (r) => typeboxValidator(file, r)),
        jsonWriter: writers.map((w) => w.write),
        keyedAsAny: [...new Set(roots.filter((_, k) => writers[k]!.keyedAsAny))],
        exported,
      }
    },
    catch: (e) => new SpeedCheckError({ message: `preparing the inputs: ${messageOf(e)}` }),
  })
})

/** Equal as JSON values, member order aside. */
const sameJson = (a: unknown, b: unknown): boolean => {
  if (a === b) return true
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false
  if (Array.isArray(a) !== Array.isArray(b)) return false
  if (Array.isArray(a)) return a.length === (b as unknown[]).length && a.every((x, i) => sameJson(x, (b as unknown[])[i]))
  const ka = Object.keys(a)
  return ka.length === Object.keys(b).length && ka.every((k) => Object.hasOwn(b, k) && sameJson((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]))
}

interface Checked {
  readonly jsonNotStable: number
  readonly typedBaselines: NonNullable<SpeedOut["typedBaselines"]>
}

/** The checks before timing. */
const check = (i: Inputs) =>
  Effect.try({
    try: (): Checked => {
      const jsonNotStable = i.ids.filter((id, k) => {
        if (stringify(i.hausValues[k]!, MIN) !== i.hausTexts[k]) throw new Error(`${id}: haus parse → stringify is not the same text`)
        h.decode(i.schemaOf[k]!, i.hausValues[k]!)
        return JSON.stringify(i.jsValues[k]) !== i.jsonTexts[k]
      }).length
      const corpusValues = parseAll(i.hausCorpus)
      if (corpusValues.length !== i.ids.length || !corpusValues.every((v, k) => equals(v, i.hausValues[k]!))) throw new Error("the haus corpus stream reads as other values")
      if (format(i.hausValues, MIN) !== i.hausCorpus) throw new Error("the haus corpus stream isn't the documents' minimised stream")
      if (allJson(i.jsonTexts) !== i.jsonCorpus) throw new Error("the JSON corpus isn't the documents' array")

      // The JSON baselines accept every document.
      let jsonWriterOtherText = 0
      let typedWriteOtherText = 0
      i.ids.forEach((id, k) => {
        const v = i.jsValues[k]
        const z = i.zod[k]!.safeParse(v)
        if (!z.success) throw new Error(`${id}: Zod rejects the document: ${z.error.issues.slice(0, 3).map((x) => `${x.path.join(".")}: ${x.message}`).join("; ")}`)
        const ajv = i.ajv[k]!
        if (!ajv(v)) throw new Error(`${id}: Ajv rejects the document: ${JSON.stringify(ajv.errors?.slice(0, 3))}`)
        if (!i.typebox[k]!.Check(v)) throw new Error(`${id}: TypeBox rejects the document: ${JSON.stringify([...i.typebox[k]!.Errors(v)].slice(0, 3))}`)
        // fast-json-stringify writes the members the schema lists: JSON of what Zod gives
        // (or, where it writes variants by keys as JSON.stringify does, the document as it is, or that).
        const written = i.jsonWriter[k]!(v)
        const back = JSON.parse(written) as unknown
        if (!sameJson(back, z.data) && !(i.keyedAsAny.includes(i.roots[k]!) && sameJson(back, v))) throw new Error(`${id}: fast-json-stringify wrote another value than Zod's: ${written.slice(0, 200)}`)
        if (written !== i.jsonTexts[k]) jsonWriterOtherText++
        // The typed haus write reads back as the same values (and writes the same text again).
        const typed = h.stringify(i.schemaOf[k]!, i.decoded[k], MIN)
        if (h.stringify(i.schemaOf[k]!, h.parse(i.schemaOf[k]!, typed), MIN) !== typed) throw new Error(`${id}: the typed haus write doesn't read back as the same values`)
        if (typed !== i.hausTexts[k]) typedWriteOtherText++
      })

      // And reject documents haus rejects.
      const mutated = mutations(i.exported.jsonSchema, i.roots, i.jsValues)
      const rejected = Object.fromEntries(MUTATION_KINDS.map((kind) => [kind, 0]))
      for (const m of mutated) {
        const accepted = [
          ["Zod", i.zod[m.doc]!.safeParse(m.value).success],
          ["Ajv", i.ajv[m.doc]!(m.value)],
          ["TypeBox", i.typebox[m.doc]!.Check(m.value)],
        ].filter(([, ok]) => ok === true).map(([name]) => name)
        if (accepted.length > 0) throw new Error(`${i.ids[m.doc]}: ${accepted.join(", ")} accept${accepted.length === 1 ? "s" : ""} a mutated document (${m.kind} at ${m.where})`)
        rejected[m.kind]!++
      }
      return {
        jsonNotStable,
        typedBaselines: { versions: { ...VERSIONS }, rejected, typedWriteOtherText, jsonWriterOtherText, ...(i.keyedAsAny.length > 0 ? { jsonWriterKeyedAsAny: i.keyedAsAny } : {}) },
      }
    },
    catch: (e) => new SpeedCheckError({ message: messageOf(e) }),
  })

type Meta = Pick<SpeedRow, "group" | "input" | "format" | "impl" | "bytes" | "docs">

/**
 * The tinybench tasks. Each body is the plain library call in a loop, its
 * output consumed into `checksum`. JSON.parse and JSON.stringify are each
 * group's first JSON task: the baseline.
 */
const makeBench = (i: Inputs, options: { readonly time: number; readonly warmupTime: number; readonly gc: Option.Option<() => void> }) => {
  const { ids, schemaOf, jsonTexts, hausTexts, jsonCorpus, hausValues, hausCorpus, jsValues, decoded, zod, ajv, typebox, jsonWriter } = i
  const gc = Option.getOrUndefined(options.gc)
  let checksum = 0
  const bench = new Bench({ time: options.time, warmup: true, warmupTime: options.warmupTime, throws: true, setup: () => gc?.() })
  const bytes = (texts: readonly string[]) => sum(texts.map(utf8Length))
  const meta = new Map<string, Meta>()
  const task = (group: SpeedRow["group"], input: SpeedRow["input"], format: SpeedRow["format"], impl: string, size: number, fn: () => void) => {
    const name = `${group} | ${input} | ${impl}`
    meta.set(name, { group, input, format, impl, bytes: size, docs: ids.length })
    bench.add(name, fn)
  }
  const invalid = (k: number) => {
    throw new Error(`${ids[k]}: invalid`)
  }
  const validators: readonly [string, (v: unknown, k: number) => void][] = [
    ["JSON.parse + Zod", (v, k) => void zod[k]!.parse(v)],
    ["JSON.parse + Ajv", (v, k) => void (ajv[k]!(v) || invalid(k))],
    ["JSON.parse + TypeBox", (v, k) => void (typebox[k]!.Check(v) || invalid(k))],
  ]
  // The texts the typed writers write (bytes written).
  const jsonWritten = jsValues.map((v, k) => jsonWriter[k]!(v))
  const typedWritten = decoded.map((v, k) => h.stringify(schemaOf[k]!, v, MIN))

  task("parse", "corpus", "json", "JSON.parse", utf8Length(jsonCorpus), () => {
    checksum += (JSON.parse(jsonCorpus) as unknown[]).length
  })
  task("parse", "corpus", "haus", "haus parseAll", utf8Length(hausCorpus), () => {
    checksum += parseAll(hausCorpus).length
  })
  task("parse", "per doc", "json", "JSON.parse", bytes(jsonTexts), () => {
    for (const t of jsonTexts) checksum += JSON.parse(t) === null ? 0 : 1
  })
  task("parse", "per doc", "haus", "haus parse", bytes(hausTexts), () => {
    for (const t of hausTexts) checksum += parse(t).kind.length
  })
  for (const [impl, validate] of validators) {
    task("typed", "corpus", "json", impl, utf8Length(jsonCorpus), () => {
      ;(JSON.parse(jsonCorpus) as unknown[]).forEach((v, k) => {
        validate(v, k)
        checksum++
      })
    })
  }
  task("typed", "corpus", "haus", "haus parseAll + decode", utf8Length(hausCorpus), () => {
    parseAll(hausCorpus).forEach((v, k) => {
      checksum += h.decode(schemaOf[k]!, v) === undefined ? 0 : 1
    })
  })
  for (const [impl, validate] of validators) {
    task("typed", "per doc", "json", impl, bytes(jsonTexts), () => {
      jsonTexts.forEach((t, k) => {
        validate(JSON.parse(t), k)
        checksum++
      })
    })
  }
  task("typed", "per doc", "haus", "haus parse + decode (h.parse)", bytes(hausTexts), () => {
    hausTexts.forEach((t, k) => {
      checksum += h.parse(schemaOf[k]!, t) === undefined ? 0 : 1
    })
  })
  task("write", "corpus", "json", "JSON.stringify", utf8Length(jsonCorpus), () => {
    checksum += JSON.stringify(jsValues).length
  })
  task("write", "corpus", "json", "fast-json-stringify", utf8Length(`[${jsonWritten.join(",")}]`), () => {
    let out = "["
    jsValues.forEach((v, k) => {
      out += (k === 0 ? "" : ",") + jsonWriter[k]!(v)
    })
    checksum += (out + "]").length
  })
  task("write", "corpus", "haus", "haus format minimised", utf8Length(hausCorpus), () => {
    checksum += format(hausValues, MIN).length
  })
  task("write", "corpus", "haus", "haus h.stringify minimised (typed)", bytes(typedWritten.map((t) => `${t},\n`)), () => {
    let out = ""
    decoded.forEach((v, k) => {
      out += `${h.stringify(schemaOf[k]!, v, MIN)},\n`
    })
    checksum += out.length
  })
  task("write", "per doc", "json", "JSON.stringify", bytes(jsonTexts), () => {
    for (const v of jsValues) checksum += JSON.stringify(v).length
  })
  task("write", "per doc", "json", "fast-json-stringify", bytes(jsonWritten), () => {
    jsValues.forEach((v, k) => {
      checksum += jsonWriter[k]!(v).length
    })
  })
  task("write", "per doc", "haus", "haus stringify minimised", bytes(hausTexts), () => {
    for (const v of hausValues) checksum += stringify(v, MIN).length
  })
  task("write", "per doc", "haus", "haus h.stringify minimised (typed)", bytes(typedWritten), () => {
    decoded.forEach((v, k) => {
      checksum += h.stringify(schemaOf[k]!, v, MIN).length
    })
  })
  task("write", "per doc", "haus", "haus stringify compact", bytes(hausValues.map((v) => stringify(v, { style: "compact" }))), () => {
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
    `${`${r.group} | ${r.input} | ${r.impl}`.padEnd(52)} ${r.mb_s.toFixed(1).padStart(8)} MB/s ${r.us_per_doc.toFixed(2).padStart(9)} µs/doc  p99 ${r.p99_ms.toFixed(2)} ms  (${r.samples} samples)`,
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
  const { jsonNotStable, typedBaselines } = yield* check(inputs)
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
    typedBaselines,
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
