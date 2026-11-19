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
import { equals, equalsJson, HausDecodeError, importJsonValue, isJsonObject, parse, parseJson, stringify } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"
import { Array as Arr, Console, Effect, FileSystem, Option, Path, Result } from "effect"
import { corpusOf, jsonSchemaCorpus, type Corpus, type Document } from "../corpus.ts"
import { CorpusError, messageOf } from "../errors.ts"
import { listingFile } from "../listing.ts"
import { sourcePath, type CorpusSource } from "../manifest.ts"
import { compile, Converter, fromImported, Mismatch, reachable, toHaus, toJson, type EnumStyle } from "../openapi.ts"
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
  converter.convertAll()
  return converter.counts
}

/** Every document of the corpus (or the sample) in every form, round trip checked. Pure. */
export const convertCorpus = (source: CorpusSource, corpus: Corpus, limit: Option.Option<number>): Conversion => {
  const all = corpus.documents
  const docs = sample(all, limit)
  const converter = new Converter(corpus.description, corpus.converter)
  const roots = new Map(docs.map((d) => [d, converter.root(d.schema, d.responseName)]))

  // Survey: a date-time or date type stays one only if every example value there is valid.
  // (A document that fails here fails below, with its reason.)
  for (const d of docs) attempt(() => toHaus(d.json, converter.typeOf(roots.get(d)!), { enums: "tags", survey: true }))

  const rootNames = [...new Set(roots.values())]
  const schemas = { tags: converter.schemaText(rootNames, "tags", corpus.schemaFrom), strings: converter.schemaText(rootNames, "strings", corpus.schemaFrom) }
  const compiled = { tags: compile(schemas.tags), strings: compile(schemas.strings) }
  const unlisted = { count: 0 }

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
      if (!equalsJson(toJson(read, type, { enums }), d.json)) throw new Mismatch(`haus → JSON differs from the original (enums as ${enums})`, "$")
      return { min, compact, pretty }
    }
    const tags = form("tags")
    const strings = form("strings")
    const plain = importJsonValue(d.json, { maxDepth: 512 })
    const plain_min = stringify(plain, { style: "minimised" })
    const plain_pretty = stringify(plain)
    if (!equalsJson(fromImported(parse(plain_min)), d.json)) throw new Mismatch("plain haus → JSON differs from the original", "$")

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
    `unlisted members kept: ${out.unlistedMembers}`,
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

/** The documents of a source, from the files fetch stored. */
const readCorpus = Effect.fn("convert.readCorpus")(function* (source: CorpusSource) {
  const paths = yield* BenchPaths
  const fs = yield* FileSystem.FileSystem
  const p = yield* Path.Path
  const pure = (path: string, f: () => Corpus) => Effect.try({ try: f, catch: (e) => new CorpusError({ path, message: messageOf(e) }) })
  switch (source.layout._tag) {
    case "OpenApiExamples": {
      const path = paths.corpusFile(source.name, source.layout.description.path)
      const description = yield* readObject(path, "an OpenAPI description")
      return yield* pure(path, () => corpusOf(description))
    }
    case "JsonSchemaDocuments": {
      const { schema, documents } = source.layout
      const schemaPath = paths.corpusFile(source.name, schema.path)
      const dir = paths.corpusDir(source.name, documents.dir)
      const description = yield* readObject(schemaPath, "a JSON Schema")
      const names = (yield* fs.readFileString(listingFile(dir))).split("\n").filter((l) => l !== "").map((l) => l.split("\t")[0]!)
      const files = yield* Effect.forEach(names, (name) => readJson(p.join(dir, name)).pipe(Effect.map((json) => ({ name, json }))))
      return yield* pure(dir, () => jsonSchemaCorpus(description, files, `${schema.path} at ${source.repo} @ ${source.commit.slice(0, 12)} (JSON Schema)`))
    }
  }
})

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
      yield* Console.log(summary(conversion))
    }), { discard: true })
})
