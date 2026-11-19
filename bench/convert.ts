/**
 * JSON → haus for every document, with the schemas generated from GitHub's
 * OpenAPI description (openapi.ts), and the round trip checked per document.
 *
 *   node convert.ts [--limit N]     N: a fixed sample of N documents (every k-th), for a quick run
 *
 * Writes:
 *   .out/corpus.json                 every document in every form measured, the schemas, the counts
 *   .out/github.schema.haus          the schema, enums as tags (the main, idiomatic form)
 *   .out/github-strings.schema.haus  the same, enums as strings (exact §16.3 mapping for enums)
 *   .out/github-rest.haus            all documents in the idiomatic form, pretty, for reading
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
 */
import { writeFileSync } from "node:fs"
import { parseArgs } from "node:util"
import { equals, equalsJson, HausDecodeError, importJsonValue, parse, parseJson, stringify } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"
import { readCorpus } from "./lib/corpus.ts"
import { readManifest } from "./lib/manifest.ts"
import { CORPUS_OUT, corpusFile, ensureDir, OUT } from "./lib/paths.ts"
import type { Converted, CorpusOut } from "./lib/results.ts"
import { compile, Converter, fromImported, Mismatch, reachable, toHaus, toJson, type EnumStyle } from "./openapi.ts"

const { values: args } = parseArgs({ args: process.argv.slice(2).filter((a) => a !== "--"), options: { limit: { type: "string" } } })
const limit = args.limit === undefined ? undefined : Number(args.limit)

const [source] = readManifest().corpus
if (!source) throw new Error("sources.haus lists no corpus")
const corpus = readCorpus(corpusFile(source.name, source.path))
const all = corpus.documents
// A fixed sample: every k-th document, so it spreads over the whole API.
const docs = limit === undefined || limit >= all.length ? all : Array.from({ length: limit }, (_, i) => all[Math.floor((i * all.length) / limit)]!)

const converter = new Converter(corpus.description)
const roots = new Map(docs.map((d) => [d, converter.root(d.schema, d.responseName)]))

// Survey: a date-time or date type stays one only if every example value there is valid.
for (const d of docs) {
  try {
    toHaus(d.json, converter.typeOf(roots.get(d)!), { enums: "tags", survey: true })
  } catch {
    // the document fails below, with its reason
  }
}

const rootNames = [...new Set(roots.values())]
const schemaText = { tags: converter.schemaText(rootNames, "tags"), strings: converter.schemaText(rootNames, "strings") }
const compiled = { tags: compile(schemaText.tags), strings: compile(schemaText.strings) }

const reasonOf = (e: unknown): { reason: string; path: string } =>
  e instanceof Mismatch ? { reason: e.reason, path: e.path }
  : e instanceof HausDecodeError ? { reason: `decode: ${e.code}`, path: e.path.join(".") }
  : { reason: e instanceof Error ? e.message : String(e), path: "" }

const unlisted = { count: 0 }
const documents: Converted[] = []
const excluded: { id: string; reason: string; path: string }[] = []
for (const d of docs) {
  const root = roots.get(d)!
  const type = converter.typeOf(root)
  try {
    const forms = {} as Record<EnumStyle, { min: string; compact: string; pretty: string }>
    for (const enums of ["tags", "strings"] as const) {
      const value = toHaus(d.json, type, enums === "tags" ? { enums, unlisted } : { enums })
      const min = stringify(value, { style: "minimised" })
      const compact = stringify(value, { style: "compact" })
      const pretty = stringify(value)
      const read = parse(min)
      if (!equals(read, value) || !equals(parse(compact), value) || !equals(parse(pretty), value)) throw new Mismatch("the haus text reads as another value", "$")
      h.decode(compiled[enums][root]!, read)
      if (!equalsJson(toJson(read, type, { enums }), d.json)) throw new Mismatch(`haus → JSON differs from the original (enums as ${enums})`, "$")
      forms[enums] = { min, compact, pretty }
    }
    const plain = importJsonValue(d.json, { maxDepth: 512 })
    const plain_min = stringify(plain, { style: "minimised" })
    const plain_pretty = stringify(plain)
    if (!equalsJson(fromImported(parse(plain_min)), d.json)) throw new Mismatch("plain haus → JSON differs from the original", "$")

    // JSON as people write it: JSON.stringify, numbers exactly as in the source (JsonNumber → JSON.rawJSON).
    const json_min = JSON.stringify(d.json)
    const json_pretty = JSON.stringify(d.json, null, 2)
    if (!equalsJson(parseJson(json_min), d.json) || !equalsJson(parseJson(json_pretty), d.json)) throw new Mismatch("JSON.stringify changed the document", "$")
    documents.push({
      id: d.id, kind: d.kind, root, json_min, json_pretty,
      haus_min: forms.tags.min, haus_compact: forms.tags.compact, haus_pretty: forms.tags.pretty,
      str_min: forms.strings.min, str_pretty: forms.strings.pretty,
      plain_min, plain_pretty,
    })
  } catch (e) {
    excluded.push({ id: d.id, ...reasonOf(e) })
  }
}

const positions: Record<string, number> = {}
for (const t of reachable(rootNames.map((n) => converter.typeOf(n)))) {
  const name: string = t.k === "time" ? (t.valid ? t.tag : `${t.tag} → String (an example isn't one)`) : t.k
  if (t.k !== "ref") positions[name] = (positions[name] ?? 0) + 1
}

const out: CorpusOut = {
  source: { name: source.name, repo: source.repo, commit: source.commit, path: source.path, license: source.license, category: source.category },
  examples: all.length + Object.values(corpus.skipped).reduce((a, b) => a + b, 0),
  found: all.length,
  sample: docs.length < all.length ? docs.length : undefined,
  skipped: corpus.skipped,
  documents,
  excluded,
  schemas: schemaText,
  decisions: converter.counts,
  positions,
  unlistedMembers: unlisted.count,
  notes: converter.notes,
}
ensureDir(OUT)
writeFileSync(CORPUS_OUT, JSON.stringify(out))
writeFileSync(`${OUT}github.schema.haus`, schemaText.tags)
writeFileSync(`${OUT}github-strings.schema.haus`, schemaText.strings)
writeFileSync(`${OUT}${source.name}.haus`, documents.map((d) => `// ${d.id} (${d.root})\n${d.haus_pretty},\n`).join("\n"))

const reasons = new Map<string, number>()
for (const e of excluded) reasons.set(e.reason, (reasons.get(e.reason) ?? 0) + 1)
const bytes = (k: keyof Converted) => documents.reduce((n, d) => n + Buffer.byteLength(d[k]), 0)
console.log(`${source.name}: ${all.length} documents from ${out.examples} examples (skipped: ${JSON.stringify(corpus.skipped)})${out.sample ? `, sample of ${out.sample}` : ""}`)
console.log(`round trip: ${documents.length} ok, ${excluded.length} excluded`)
for (const [reason, n] of [...reasons].sort((a, b) => b[1] - a[1])) console.log(`  ${String(n).padStart(4)}  ${reason}`)
console.log(`types reachable: ${JSON.stringify(positions)}`)
console.log(`decisions: ${JSON.stringify(converter.counts)}`)
console.log(`unlisted members kept: ${unlisted.count}`)
console.log(`bytes: JSON min ${bytes("json_min")}, pretty ${bytes("json_pretty")} | haus min ${bytes("haus_min")}, compact ${bytes("haus_compact")}, pretty ${bytes("haus_pretty")} | enums as strings min ${bytes("str_min")} | plain min ${bytes("plain_min")}`)
