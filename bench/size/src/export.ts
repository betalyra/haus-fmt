/**
 * The corpus every language's speed benchmark reads: convert exports the
 * documents it measured (those that round-trip) as plain files, so that
 * TypeScript, Rust and the bindings to come read exactly the same bytes.
 *
 *   <out>/<source>/corpus/
 *     index.haus             the documents, in convert's order: `{ source, schema, documents: [{ id, root, file }] }`
 *     <source>.schema.haus   the schema (enums as tags): `root` is a type of it
 *     NNNN.haus              document NNNN, idiomatic haus, minimised (the wire form)
 *     NNNN.pretty.haus       the same, pretty
 *     NNNN.json              the same document, minified JSON (numbers as written in the source)
 *     all.haus               every document in one haus stream, minimised (each item followed by `,` and a line feed)
 *     all.json               every document in one JSON array, minified
 *
 * Every file holds exactly the text that is measured: no trailing newline is
 * added. `file` is the document's number, zero-padded to four digits, so the
 * names sort in index order.
 */
import * as Haus from "@haus-fmt/effect"
import { format, parse } from "@haus-fmt/haus"
import { Effect, FileSystem, Path, Schema } from "effect"
import { CorpusError, messageOf, ResultsFileError } from "./errors.ts"
import { BenchPaths } from "./paths.ts"
import type { Converted, CorpusOut } from "./results.ts"

export const CorpusDocument = Schema.Struct({
  id: Schema.String,
  /** The document's type in the schema file. */
  root: Schema.String,
  /** The files' common name: `<file>.haus`, `<file>.pretty.haus`, `<file>.json`. */
  file: Schema.String,
})
export type CorpusDocument = typeof CorpusDocument.Type

export const CorpusIndex = Schema.Struct({
  source: Schema.String,
  /** The schema file, beside the index. */
  schema: Schema.String,
  documents: Schema.Array(CorpusDocument),
})
export type CorpusIndex = typeof CorpusIndex.Type

/** The directory of the export, in a source's results directory. */
export const CORPUS_DIR = "corpus"
export const INDEX = "index.haus"
export const ALL_HAUS = "all.haus"
export const ALL_JSON = "all.json"

const fileOf = (i: number): string => String(i).padStart(4, "0")

/** The corpus inputs as one text: a JSON array, a haus stream. Pure. */
export const allJson = (texts: readonly string[]): string => `[${texts.join(",")}]`
export const allHaus = (texts: readonly string[]): string => format(texts.map((t) => parse(t)), { style: "minimised" })

const encodeIndex = Haus.encode(CorpusIndex)
const decodeIndex = Haus.decode(CorpusIndex)

/** The files of the export, by name in the corpus directory. */
export const exportFiles = Effect.fn("export.files")(function* (out: CorpusOut) {
  const name = out.source.name
  const schema = `${name}.schema.haus`
  const index: CorpusIndex = { source: name, schema, documents: out.documents.map((d, i) => ({ id: d.id, root: d.root, file: fileOf(i) })) }
  const indexText = yield* encodeIndex(index).pipe(Effect.orDie)
  const perDocument = out.documents.flatMap((d: Converted, i): [string, string][] => [
    [`${fileOf(i)}.haus`, d.haus_min],
    [`${fileOf(i)}.pretty.haus`, d.haus_pretty],
    [`${fileOf(i)}.json`, d.json_min],
  ])
  const files: [string, string][] = [
    [INDEX, `// The documents of ${name} that bench convert measured, in order (written by bench/size/src/export.ts).\n${indexText}\n`],
    [schema, out.schemas.tags],
    [ALL_HAUS, allHaus(out.documents.map((d) => d.haus_min))],
    [ALL_JSON, allJson(out.documents.map((d) => d.json_min))],
    ...perDocument,
  ]
  return files
})

/**
 * Writes the export of one source, and removes the files of an earlier
 * export that this one doesn't have (a run with `--limit` after a full one).
 */
export const writeExport = Effect.fn("export.write")(function* (out: CorpusOut) {
  const paths = yield* BenchPaths
  const fs = yield* FileSystem.FileSystem
  const path = yield* Path.Path
  const dir = paths.outFile(out.source.name, CORPUS_DIR)
  const files = yield* exportFiles(out)
  yield* Effect.gen(function* () {
    yield* fs.makeDirectory(dir, { recursive: true })
    yield* Effect.forEach(files, ([file, text]) => fs.writeFileString(path.join(dir, file), text), { concurrency: 16, discard: true })
    const keep = new Set(files.map(([file]) => file))
    const stale = (yield* fs.readDirectory(dir)).filter((file) => !keep.has(file))
    yield* Effect.forEach(stale, (file) => fs.remove(path.join(dir, file)), { discard: true })
  }).pipe(Effect.catchTag("PlatformError", (e) => Effect.fail(new ResultsFileError({ path: dir, message: e.message }))))
  return dir
})

/** One document of the export, with its texts. */
export interface ExportedDocument extends CorpusDocument {
  readonly haus: string
  readonly json: string
}

export interface Exported {
  readonly index: CorpusIndex
  readonly schemaText: string
  readonly documents: readonly ExportedDocument[]
  readonly allHaus: string
  readonly allJson: string
}

/** Reads the export of one source (what convert wrote). */
export const readExport = Effect.fn("export.read")(function* (source: string) {
  const paths = yield* BenchPaths
  const fs = yield* FileSystem.FileSystem
  const path = yield* Path.Path
  const dir = paths.outFile(source, CORPUS_DIR)
  const fail = (e: { readonly message: string }) => Effect.fail(new CorpusError({ path: dir, message: `${e.message} (run convert first)` }))
  const read = (file: string) => fs.readFileString(path.join(dir, file)).pipe(Effect.catchTag("PlatformError", fail))
  const index = yield* read(INDEX).pipe(
    Effect.flatMap((text) => decodeIndex(text)),
    Effect.catchTag(["HausParseError", "HausSchemaError", "HausLimitsError"], (e) => Effect.fail(new CorpusError({ path: path.join(dir, INDEX), message: messageOf(e) }))),
  )
  const documents = yield* Effect.forEach(index.documents, (d) =>
    Effect.all({ haus: read(`${d.file}.haus`), json: read(`${d.file}.json`) }).pipe(Effect.map((t): ExportedDocument => ({ ...d, ...t }))),
    { concurrency: 16 })
  const exported: Exported = {
    index,
    schemaText: yield* read(index.schema),
    documents,
    allHaus: yield* read(ALL_HAUS),
    allJson: yield* read(ALL_JSON),
  }
  return exported
})
