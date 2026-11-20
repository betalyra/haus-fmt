/**
 * JSON → haus for every document of each source, with the schema generated
 * from the source's own schema (GitHub's OpenAPI description, Vega-Lite's
 * JSON Schema; openapi.ts), and the round trip checked per document.
 *
 *   convert [--limit N] [--sources a,b]     N: a fixed sample of N documents (every k-th), for a quick run
 *
 * Writes, into the source's results directory (<out>/<source>/):
 *   corpus.json                    every document in every form measured, the schemas, the counts
 *   <source>.schema.haus           the schema, enums as tags (the main, idiomatic form)
 *   <source>-strings.schema.haus   the same, enums as strings (exact §16.3 mapping for enums)
 *   <source>.haus                  all documents in the idiomatic form, pretty, for reading
 *   corpus/                        the documents that round-trip, as plain files, for every language's
 *                                  speed benchmark (export.ts: index.haus, NNNN.haus, NNNN.json, …)
 *
 * Round trip, per document and per enum style (a failure excludes the
 * document from every number, with its reason):
 *   1. the minimised, compact and pretty haus texts parse to the same value;
 *   2. that value decodes with the compiled schema (`h.decode`);
 *   3. written back to JSON with the same type, it equals the original
 *      (`equalsJson`: member order ignored, numbers compared by their exact
 *      text, strings exactly);
 *   4. the plain haus (the import of spec §16.1, no schema) parses and maps
 *      back to the same JSON too.
 *
 * `convertCorpus` is the whole conversion, pure; the step around it reads
 * the description and writes the results.
 */
import {
  equals, equalsJson, HausDecodeError, importJsonValue, isJsonObject, jsonObject, JsonNumber, normalizeNumber, parse, parseJson, stringify, type Json,
} from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"
import { Array as Arr, Console, Effect, FileSystem, Option, Path, Result } from "effect"
import { gunzipSync } from "node:zlib"
import {
  corpusOf, fixturesCorpus, functionCallCorpus, geoJsonCorpus, ghArchiveCorpus, jsonSchemaCorpus, kubernetesCorpus, type Corpus, type Document, type TextFile,
} from "../corpus.ts"
import { CorpusError, messageOf } from "../errors.ts"
import { writeExport } from "../export.ts"
import { defineSchemaFile } from "../hand.ts"
import { listingFile, parseListing } from "../listing.ts"
import { sourcePath, type CorpusSource } from "../manifest.ts"
import { compile, Converter, fromImported, Mismatch, reachable, RESERVED, toHaus, toJson, type EnumStyle } from "../openapi.ts"
import { BenchPaths } from "../paths.ts"
import { CORPUS, Results, type Converted, type CorpusOut, type Excluded } from "../results.ts"
import { selectSources, type Selection } from "../sources.ts"
import { tally, utf8Length } from "../stats.ts"

/** `f()`, or what it threw. */
const attempt = <A>(f: () => A): Result.Result<A, unknown> => {
  try {
    return Result.succeed(f())
  } catch (e) {
    return Result.fail(e)
  }
}

/** A fixed sample: every k-th document, so it spreads over the whole API. */
export const sample = <A>(all: readonly A[], limit: Option.Option<number>): readonly A[] =>
  Option.match(Option.filter(limit, (n) => n < all.length), {
    onNone: () => all,
    onSome: (n) => Array.from({ length: n }, (_, i) => all[Math.floor((i * all.length) / n)]!),
  })

/** JSON with every number in haus's normalized spelling (`1e-09` → `1e-9`, `1E5` → `1e5`; spec §3). */
const normalizedNumbers = (j: Json): Json =>
  j instanceof JsonNumber ? new JsonNumber(normalizeNumber(j.text) ?? j.text)
  : Array.isArray(j) ? j.map(normalizedNumbers)
  : j !== null && typeof j === "object" ? jsonObject(Object.entries(j).map(([k, v]) => [k, normalizedNumbers(v)] as const))
  : j

/**
 * The same JSON, numbers compared by their normalized text: haus keeps a
 * number's digits and scale but writes its exponent one way (`1e-9`), so
 * `1e-09` comes back as `1e-9` (counted as respelled).
 */
const sameJson = (a: Json, b: Json): boolean => equalsJson(a, b) || equalsJson(normalizedNumbers(a), normalizedNumbers(b))

const reasonOf = (e: unknown): { reason: string; path: string } =>
  e instanceof Mismatch ? { reason: e.reason, path: e.path }
  : e instanceof HausDecodeError ? { reason: `decode: ${e.code}`, path: e.path.join(".") }
  : { reason: messageOf(e), path: "" }

export interface Conversion {
  readonly out: CorpusOut
  /** The documents in the idiomatic form, pretty, one after the other: for reading. */
  readonly readable: string
}

/** The converter's decisions over every named type of the corpus's schema. Pure. */
export const schemaWide = (corpus: Corpus): Record<string, number> => {
  const converter = new Converter(corpus.description, corpus.converter)
  corpus.prepare?.(converter)
  converter.convertAll()
  return converter.counts
}

/** Every document of the corpus (or the sample) in every form, round trip checked. Pure. */
export const convertCorpus = (source: CorpusSource, corpus: Corpus, limit: Option.Option<number>): Conversion => {
  const all = corpus.documents
  const docs = sample(all, limit)
  const converter = new Converter(corpus.description, corpus.converter)
  corpus.prepare?.(converter)
  const roots = new Map(docs.map((d) => [d, d.root ?? converter.root(d.schema, d.responseName)]))

  // Survey: a date-time or date type stays one only if every example value there is valid.
  // (A document that fails here fails below, with its reason.)
  for (const d of docs) attempt(() => toHaus(d.json, converter.typeOf(roots.get(d)!), { enums: "tags", survey: true }))

  const rootNames = [...new Set(roots.values())]
  // The documents as one file (spec §6): a stream of the root type.
  const stream = corpus.stream !== undefined && rootNames.length === 1 ? `\n// The documents as one file.\ntype ${corpus.stream} = Stream ${rootNames[0]}\n` : ""
  const schemas = {
    tags: (corpus.schemaText ?? converter.schemaText(rootNames, "tags", corpus.schemaFrom)) + stream,
    strings: converter.schemaText(rootNames, "strings", corpus.schemaFrom) + stream,
  }
  const compiled = { tags: compile(schemas.tags), strings: compile(schemas.strings) }
  const unlisted = { count: 0 }
  const respelled = { count: 0 }

  const convertDocument = (d: Document): Converted => {
    const root = roots.get(d)!
    const type = converter.typeOf(root)
    const form = (enums: EnumStyle) => {
      const value = toHaus(d.json, type, enums === "tags" ? { enums, unlisted } : { enums })
      const min = stringify(value, { style: "minimised" })
      const compact = stringify(value, { style: "compact" })
      const pretty = stringify(value)
      const read = parse(min)
      if (!equals(read, value) || !equals(parse(compact), value) || !equals(parse(pretty), value)) throw new Mismatch("the haus text reads as another value", "$")
      h.decode(compiled[enums][root]!, read)
      if (!sameJson(toJson(read, type, { enums }), d.json)) throw new Mismatch(`haus → JSON differs from the original (enums as ${enums})`, "$")
      return { min, compact, pretty }
    }
    const tags = form("tags")
    const strings = form("strings")
    const plain = importJsonValue(d.json, { maxDepth: 512 })
    const plain_min = stringify(plain, { style: "minimised" })
    const plain_pretty = stringify(plain)
    const back = fromImported(parse(plain_min))
    if (!sameJson(back, d.json)) throw new Mismatch("plain haus → JSON differs from the original", "$")
    if (!equalsJson(back, d.json)) respelled.count++

    // JSON as people write it: JSON.stringify, numbers exactly as in the source (JsonNumber → JSON.rawJSON).
    const json_min = JSON.stringify(d.json)
    const json_pretty = JSON.stringify(d.json, null, 2)
    if (!equalsJson(parseJson(json_min), d.json) || !equalsJson(parseJson(json_pretty), d.json)) throw new Mismatch("JSON.stringify changed the document", "$")
    return {
      id: d.id, kind: d.kind, root, json_min, json_pretty,
      haus_min: tags.min, haus_compact: tags.compact, haus_pretty: tags.pretty,
      str_min: strings.min, str_pretty: strings.pretty,
      plain_min, plain_pretty,
    }
  }

  const [documents, excluded] = Arr.partition(docs, (d) =>
    Result.mapError(attempt(() => convertDocument(d)), (e): Excluded => ({ id: d.id, ...reasonOf(e) })),
  )

  const positions: Record<string, number> = {}
  for (const t of reachable(rootNames.map((n) => converter.typeOf(n)))) {
    const name: string = t.k === "time" ? (t.valid ? t.tag : `${t.tag} → String (an example isn't one)`) : t.k
    if (t.k !== "ref") positions[name] = (positions[name] ?? 0) + 1
  }

  const out: CorpusOut = {
    source: { name: source.name, repo: source.repo, commit: source.commit, path: sourcePath(source), license: source.license, category: source.category, unit: corpus.unit },
    examples: all.length + Object.values(corpus.skipped).reduce((a, b) => a + b, 0),
    found: all.length,
    ...(docs.length < all.length ? { sample: docs.length } : {}),
    skipped: corpus.skipped,
    documents,
    excluded,
    schemas,
    decisions: converter.counts,
    schemaWide: schemaWide(corpus),
    positions,
    unlistedMembers: unlisted.count,
    ...(respelled.count > 0 ? { respelledNumbers: respelled.count } : {}),
    notes: converter.notes,
  }
  return { out, readable: documents.map((d) => `// ${d.id} (${d.root})\n${d.haus_pretty},\n`).join("\n") }
}

/** The summary printed after a conversion. Pure. */
export const summary = ({ out }: Conversion): string => {
  const bytes = (k: keyof Converted) => out.documents.reduce((n, d) => n + utf8Length(d[k]), 0)
  return [
    `${out.source.name}: ${out.found} documents from ${out.examples} examples (skipped: ${JSON.stringify(out.skipped)})${out.sample ? `, sample of ${out.sample}` : ""}`,
    `round trip: ${out.documents.length} ok, ${out.excluded.length} excluded`,
    ...tally(out.excluded.map((e) => e.reason)).map(([reason, n]) => `  ${String(n).padStart(4)}  ${reason}`),
    `types reachable: ${JSON.stringify(out.positions)}`,
    `decisions: ${JSON.stringify(out.decisions)}`,
    `unlisted members kept: ${out.unlistedMembers}${out.respelledNumbers ? `; documents with numbers in haus's spelling (1e-09 → 1e-9): ${out.respelledNumbers}` : ""}`,
    `bytes: JSON min ${bytes("json_min")}, pretty ${bytes("json_pretty")} | haus min ${bytes("haus_min")}, compact ${bytes("haus_compact")}, pretty ${bytes("haus_pretty")} | enums as strings min ${bytes("str_min")} | plain min ${bytes("plain_min")}`,
  ].join("\n")
}

/** Reads a JSON file, numbers exact. */
const readJson = Effect.fn("convert.readJson")(function* (path: string) {
  const fs = yield* FileSystem.FileSystem
  const text = yield* fs.readFileString(path)
  return yield* Effect.try({
    try: () => parseJson(text, { maxDepth: 512 }),
    catch: (e) => new CorpusError({ path, message: messageOf(e) }),
  })
})

const readObject = Effect.fn("convert.readObject")(function* (path: string, what: string) {
  const json = yield* readJson(path)
  return isJsonObject(json) ? json : yield* new CorpusError({ path, message: `not ${what}` })
})

/** The files of a pinned directory fetch stored, in the listing's order, as text. */
const readListed = Effect.fn("convert.readListed")(function* (dir: string) {
  const fs = yield* FileSystem.FileSystem
  const p = yield* Path.Path
  const names = parseListing(yield* fs.readFileString(listingFile(dir))).map((e) => e.name)
  return yield* Effect.forEach(names, (name) => fs.readFileString(p.join(dir, name)).pipe(Effect.map((text): TextFile => ({ name, text }))))
})

/** Parses JSON text read from a file (an object), numbers exact. */
const jsonOf = (path: string, text: string, what: string) =>
  Effect.try({ try: () => parseJson(text, { maxDepth: 512 }), catch: (e) => new CorpusError({ path, message: messageOf(e) }) }).pipe(
    Effect.filterOrFail(isJsonObject, () => new CorpusError({ path, message: `not ${what}` })),
  )

/** The documents of a source, from the files fetch stored. */
const readCorpus = Effect.fn("convert.readCorpus")(function* (source: CorpusSource) {
  const paths = yield* BenchPaths
  const fs = yield* FileSystem.FileSystem
  const path = yield* Path.Path
  const p = (dir: string, name: string) => path.join(dir, name)
  const pure = (path: string, f: () => Corpus) => Effect.try({ try: f, catch: (e) => new CorpusError({ path, message: messageOf(e) }) })
  const at = (path: string, repo = source.repo, commit = source.commit) => `${path} at ${repo} @ ${commit.slice(0, 12)}`
  const l = source.layout
  switch (l._tag) {
    case "OpenApiExamples": {
      const path = paths.corpusFile(source.name, l.description.path)
      const description = yield* readObject(path, "an OpenAPI description")
      return yield* pure(path, () => corpusOf(description))
    }
    case "OpenApiFixtures": {
      const path = paths.corpusFile(source.name, l.description.path)
      const description = yield* readObject(path, "an OpenAPI description")
      const fixtures = yield* readObject(paths.corpusFile(source.name, l.fixtures.path), "a fixtures file")
      return yield* pure(path, () => fixturesCorpus(description, fixtures, `${at(l.description.path)} (OpenAPI ${String(description["openapi"])})`))
    }
    case "JsonSchemaDocuments": {
      const { schema, documents } = l
      const schemaPath = paths.corpusFile(source.name, schema.path)
      const dir = paths.corpusDir(source.name, documents.dir)
      const description = yield* readObject(schemaPath, "a JSON Schema")
      const files = yield* readListed(dir)
      const docs = yield* Effect.forEach(files, (f) =>
        Effect.try({ try: () => ({ name: f.name, json: parseJson(f.text, { maxDepth: 512 }) }), catch: (e) => new CorpusError({ path: p(dir, f.name), message: messageOf(e) }) }))
      return yield* pure(dir, () => jsonSchemaCorpus(description, docs, `${at(schema.path)} (JSON Schema)`))
    }
    case "KubernetesManifests": {
      const dir = paths.corpusDir(source.name, l.documents.dir)
      const specDir = paths.corpusDir(source.name, l.schema.files.dir)
      const specs = yield* Effect.forEach(yield* readListed(specDir), (f) => jsonOf(p(specDir, f.name), f.text, "an OpenAPI description"))
      const files = yield* readListed(dir)
      const from = l.schema.from
      return yield* pure(dir, () => kubernetesCorpus(specs, files, `${at(`${l.schema.files.dir}/*${l.schema.files.suffixes.join("")}`, from.repo, from.commit)}${from.tag ? ` (${from.tag})` : ""}, merged`, RESERVED))
    }
    case "FunctionCalls": {
      const schemaPath = p(paths.root, l.schema)
      const schemaText = yield* fs.readFileString(schemaPath)
      const questions = yield* readListed(paths.corpusDir(source.name, l.questions.dir))
      const answers = yield* readListed(paths.corpusDir(source.name, l.answers.dir))
      return yield* pure(schemaPath, () => functionCallCorpus(questions, answers, l.categories, schemaText, `bench/${l.schema} (hand-written)`, (c, text) => void defineSchemaFile(c, text)))
    }
    case "GeoJsonFeatures": {
      const path = paths.corpusFile(source.name, l.documents.path)
      const collection = yield* readObject(path, "a GeoJSON FeatureCollection")
      const schemaPath = paths.packageFile(l.schema.package, l.schema.file)
      const schema = yield* readObject(schemaPath, "a JSON Schema")
      return yield* pure(path, () => geoJsonCorpus(collection, schema, `${l.schema.file} of the npm package ${l.schema.package}@${l.schema.version} (GeoJSON JSON Schema, draft-07)`))
    }
    case "GhArchiveEvents": {
      const archive = paths.corpusFile(source.name, l.archive.url)
      const lines = yield* fs.readFile(archive).pipe(
        Effect.flatMap((gz) => Effect.try({ try: () => new TextDecoder().decode(gunzipSync(gz)), catch: (e) => new CorpusError({ path: archive, message: messageOf(e) }) })),
      )
      const descriptionPath = paths.corpusFile(source.name, l.schema.description.path)
      const description = yield* readObject(descriptionPath, "an OpenAPI description")
      const from = l.schema.from
      return yield* pure(archive, () => ghArchiveCorpus(description, lines, l.sample, l.seed, `the event schemas of ${at(l.schema.description.path, from.repo, from.commit)} (OpenAPI 3.1)`))
    }
  }
}, (effect, source) => Effect.map(effect, (corpus): Corpus => ({ ...corpus, converter: { ...corpus.converter, ...source.rules } })))

/** The results files of one conversion, by name, in the source's results directory. */
export const conversionFiles = (source: CorpusSource, c: Conversion): [string, string][] => [
  [`${source.name}.schema.haus`, c.out.schemas.tags],
  [`${source.name}-strings.schema.haus`, c.out.schemas.strings],
  [`${source.name}.haus`, c.readable],
]

export const convert = Effect.fn("bench.convert")(function* (options: { readonly sources: Selection; readonly limit: Option.Option<number> }) {
  const results = yield* Results
  const sources = yield* selectSources(options.sources)
  yield* Effect.forEach(sources, (source) =>
    Effect.gen(function* () {
      const conversion = convertCorpus(source, yield* readCorpus(source), options.limit)
      yield* results.write(source.name, CORPUS, conversion.out)
      yield* Effect.forEach(conversionFiles(source, conversion), ([file, text]) => results.writeText([source.name, file], text))
      yield* writeExport(conversion.out)
      yield* Console.log(summary(conversion))
    }), { discard: true })
})
