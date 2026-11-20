/**
 * The corpora, from the files fetch stored. Pure: the callers read the files.
 *
 * OpenAPI examples (GitHub): every example response in the REST API
 * description, one document per example.
 *
 * Examples are found where the description puts them: under a response's
 * `content.<media type>.examples`, either inline (`value`) or as a `$ref`
 * into `components.examples`. Only JSON media types count, and only objects
 * and arrays (a few examples are `null` or a bare string, for empty or
 * non-JSON bodies). An example used by several operations is one document;
 * two examples with the same JSON are one document too.
 *
 * Each document keeps its response schema (converted to a haus type by
 * openapi.ts) and a **kind** for listings: the schema's name (`issue`,
 * `repository`, …; an array of X counts as X), or the operation for an
 * inline schema.
 */
import { isJsonObject, jsonObject, JsonNumber, parseJson, stringifyJson, type Json, type JsonObject } from "@haus-fmt/haus"
import { parseAllDocuments } from "yaml"
import { JSON_SCHEMA, OPENAPI, typeName, type Converter, type ConverterOptions } from "./openapi.ts"

export interface Document {
  /** Stable name: the component example's name, or `METHOD path status#example` for an inline one. */
  readonly id: string
  readonly kind: string
  /** The response schema (OpenAPI, with `$ref`s into the description). */
  readonly schema: Json | undefined
  /** The response is an array (`[issue]`). */
  readonly array: boolean
  /** A name for the response's type when its schema is inline: the operation and status (`repos/get-content 200`). */
  readonly responseName: string
  /** The example, numbers exactly as written. */
  readonly json: Json
  /** The named type of the document, when the corpus defines it (`prepare`) rather than the schema. */
  readonly root?: string
}

export interface Corpus {
  /** What the documents' schemas `$ref` into: the OpenAPI description, the JSON Schema. */
  readonly description: JsonObject
  /** How to read the schemas. */
  readonly converter: ConverterOptions
  /** What the generated schema is generated from, for its header. */
  readonly schemaFrom: string
  /** What a document is, for the report: "example responses", "specifications". */
  readonly unit: string
  readonly documents: readonly Document[]
  /** Examples left out, by reason. */
  readonly skipped: Readonly<Record<string, number>>
  /** Defines the named types the corpus makes itself (a root union, a hand-written schema's types). */
  readonly prepare?: (c: Converter) => void
  /** The idiomatic schema, when it is hand-written: used as it is. */
  readonly schemaText?: string
  /** The documents as a file: `type <stream> = Stream <root>` is added to the schema. */
  readonly stream?: string
}

const obj = (j: Json | undefined): JsonObject | undefined => (j !== undefined && isJsonObject(j) ? j : undefined)
const entries = (j: Json | undefined): [string, Json][] => Object.entries(obj(j) ?? {})

/** Follows `#/components/...` references. */
export const deref = (description: JsonObject, j: Json | undefined): Json | undefined => {
  for (let i = 0; i < 64; i++) {
    const ref = obj(j)?.["$ref"]
    if (typeof ref !== "string") return j
    if (!ref.startsWith("#/")) return undefined
    j = ref.slice(2).split("/").reduce<Json | undefined>((at, key) => obj(at)?.[key.replaceAll("~1", "/").replaceAll("~0", "~")], description)
  }
  throw new Error("reference chain too long")
}

/** `issue` for `$ref: #/components/schemas/issue` and for an array of it; undefined for an inline schema. */
const schemaName = (schema: Json | undefined): string | undefined => {
  const o = obj(schema)
  const ref = o?.["$ref"]
  if (typeof ref === "string") return ref.split("/").at(-1)
  if (o?.["type"] === "array") return schemaName(o["items"])
  return undefined
}

/** The documents of an OpenAPI description (parsed with `parseJson`, numbers exact). Pure. */
export const corpusOf = (description: JsonObject): Corpus => {
  const examples = obj(obj(description["components"])?.["examples"]) ?? {}
  const documents: Document[] = []
  const seenNames = new Set<string>()
  const seenJson = new Set<string>()
  const skipped: Record<string, number> = {}
  const skip = (why: string) => (skipped[why] = (skipped[why] ?? 0) + 1)

  for (const [path, item] of entries(description["paths"])) {
    for (const [method, op] of entries(item)) {
      for (const [status, response] of entries(obj(op)?.["responses"])) {
        for (const [mediaType, media] of entries(obj(deref(description, response))?.["content"])) {
          if (!/json/.test(mediaType)) continue
          const schema = obj(media)?.["schema"]
          for (const [exampleName, example] of entries(obj(media)?.["examples"])) {
            const ref = obj(example)?.["$ref"]
            const name = typeof ref === "string" ? ref.split("/").at(-1)! : `${method.toUpperCase()} ${path} ${status}#${exampleName}`
            if (seenNames.has(name)) continue
            seenNames.add(name)
            const json = typeof ref === "string" ? obj(examples[name])?.["value"] : obj(example)?.["value"]
            if (json === undefined || json === null || typeof json !== "object") {
              skip("not an object or array")
              continue
            }
            const text = stringifyJson(json)
            if (seenJson.has(text)) {
              skip("same JSON as another example")
              continue
            }
            seenJson.add(text)
            const resolved = obj(deref(description, schema))
            const array = Array.isArray(json) && resolved?.["type"] === "array"
            const kind = schemaName(schema) ?? `${method.toUpperCase()} ${path} ${status}`
            const operationId = obj(op)?.["operationId"]
            const responseName = `${typeof operationId === "string" ? operationId : `${method} ${path}`} ${status}`
            documents.push({ id: name, kind, schema, array, responseName, json })
          }
        }
      }
    }
  }
  return { description, converter: OPENAPI, schemaFrom: "GitHub's REST API description (OpenAPI 3.1)", unit: "example responses", documents, skipped }
}

/** What a Vega-Lite specification is, for listings: its composition, or `unit`. */
const COMPOSITIONS = ["layer", "facet", "repeat", "concat", "hconcat", "vconcat"]

/**
 * JSON Schema documents (Vega-Lite): one document per file, all of the type
 * the schema's root `$ref` names. A file that isn't an object or array, or
 * repeats another file's JSON, is left out (counted).
 */
export const jsonSchemaCorpus = (schema: JsonObject, files: readonly { readonly name: string; readonly json: Json }[], schemaFrom: string): Corpus => {
  const root = schema["$ref"]
  const seenJson = new Set<string>()
  const skipped: Record<string, number> = {}
  const skip = (why: string) => (skipped[why] = (skipped[why] ?? 0) + 1)
  const documents: Document[] = []
  for (const { name, json } of files) {
    if (json === null || typeof json !== "object") {
      skip("not an object or array")
      continue
    }
    const text = stringifyJson(json)
    if (seenJson.has(text)) {
      skip("same JSON as another file")
      continue
    }
    seenJson.add(text)
    const kind = COMPOSITIONS.find((c) => obj(json)?.[c] !== undefined) ?? "unit"
    documents.push({ id: name, kind, schema: typeof root === "string" ? { $ref: root } : schema, array: false, responseName: "Document", json })
  }
  return { description: schema, converter: JSON_SCHEMA, schemaFrom, unit: "specifications", documents, skipped }
}

const list = (j: Json | undefined): readonly Json[] => (Array.isArray(j) ? j : [])
const byName = ([a]: readonly [string, ...unknown[]], [b]: readonly [string, ...unknown[]]) => (a < b ? -1 : a > b ? 1 : 0)

/** Reasons documents were left out, counted, and one document per distinct JSON. */
const collector = () => {
  const skipped: Record<string, number> = {}
  const seen = new Set<string>()
  const skip = (why: string, n = 1) => {
    skipped[why] = (skipped[why] ?? 0) + n
  }
  /** False (counted) when the JSON repeats an earlier document's. */
  const fresh = (json: Json, why: string) => {
    const text = stringifyJson(json)
    if (seen.has(text)) {
      skip(why)
      return false
    }
    seen.add(text)
    return true
  }
  return { skipped, skip, fresh }
}

// ── Stripe: fixtures ────────────────────────────────────────

/**
 * The example objects of an OpenAPI description's fixtures file (Stripe's
 * `fixtures3.json`: `{ resources: { <component>: example } }`), each of the
 * component schema of its name. A fixture without a component of that
 * name is left out (counted).
 */
export const fixturesCorpus = (description: JsonObject, fixtures: JsonObject, schemaFrom: string): Corpus => {
  const schemas = obj(obj(description["components"])?.["schemas"]) ?? {}
  const { skipped, skip, fresh } = collector()
  const documents: Document[] = []
  for (const [name, json] of entries(fixtures["resources"])) {
    if (schemas[name] === undefined) {
      skip("no component schema of the fixture's name")
      continue
    }
    if (json === null || typeof json !== "object") {
      skip("not an object or array")
      continue
    }
    if (!fresh(json, "same JSON as another fixture")) continue
    const object = obj(json)?.["object"]
    documents.push({ id: name, kind: typeof object === "string" ? object : name, schema: { $ref: `#/components/schemas/${name}` }, array: false, responseName: name, json })
  }
  return { description, converter: OPENAPI, schemaFrom, unit: "fixtures", documents, skipped }
}

// ── Kubernetes: YAML manifests ──────────────────────────────

export interface TextFile {
  /** Its path, below the pinned directory. */
  readonly name: string
  readonly text: string
}

/** A YAML value JSON has no form for. */
class NotJson extends Error {}

/**
 * A YAML value (parsed with `mapAsMap`) as JSON: numbers as JavaScript writes
 * them, timestamps (YAML 1.1) as ISO strings. A key that isn't a scalar (a
 * template's `{{ x }}`), `.inf`/`.nan` and binary have no JSON form.
 */
export const yamlToJson = (v: unknown): Json => {
  if (v === null || v === undefined) return null
  if (typeof v === "string" || typeof v === "boolean") return v
  if (typeof v === "number") {
    if (!Number.isFinite(v)) throw new NotJson("a number JSON has no form for (.inf, .nan)")
    return new JsonNumber(JSON.stringify(v))
  }
  if (typeof v === "bigint") return new JsonNumber(v.toString())
  if (v instanceof Date) return v.toISOString()
  if (Array.isArray(v)) return v.map(yamlToJson)
  if (v instanceof Map) {
    return jsonObject([...v].map(([k, x]): [string, Json] => {
      if (typeof k !== "string" && typeof k !== "number" && typeof k !== "boolean" && k !== null) throw new NotJson("a map key that isn't a scalar (a template)")
      return [String(k), yamlToJson(x)]
    }))
  }
  throw new NotJson(`a YAML value JSON has no form for (${Object.prototype.toString.call(v)})`)
}

/**
 * The haus names of Kubernetes' schema keys: the kind alone (`Deployment`)
 * where no other key ends in it and it isn't a built-in or std/time name,
 * else with its group and version (`MetaV1Time`), else all of it.
 */
export const kubernetesNames = (keys: readonly string[], reserved: ReadonlySet<string>): ((key: string) => string) => {
  const tail = (key: string, n: number) => typeName(key.split(".").slice(-n).join("."))
  const counts = [1, 3].map((n) => keys.reduce((m, k) => m.set(tail(k, n), (m.get(tail(k, n)) ?? 0) + 1), new Map<string, number>()))
  return (key) => {
    for (const [i, n] of [1, 3].entries()) {
      const name = tail(key, n)
      if (counts[i]!.get(name) === 1 && !reserved.has(name)) return name
    }
    return typeName(key)
  }
}

/**
 * Kubernetes manifests: every YAML document of every file (YAML 1.1, as
 * Kubernetes reads them: `0644` is octal, `yes` a boolean), as JSON, one
 * document each, typed by the merged OpenAPI v3 description of a release.
 *
 * A document's type is the schema whose `x-kubernetes-group-version-kind`
 * names its `apiVersion` and `kind`; the root type is a closed variant by
 * `kind` (tag = kind, the member `kind` in JSON), one case per kind the
 * corpus uses; `apiVersion` stays a field. Left out, counted: YAML errors,
 * empty documents, what isn't a Kubernetes object, what JSON can't hold,
 * kinds without a schema in the release (custom resources, removed API
 * versions), repeated documents.
 */
export const kubernetesCorpus = (specs: readonly JsonObject[], files: readonly TextFile[], schemaFrom: string, reserved: ReadonlySet<string>): Corpus => {
  const schemas: Record<string, Json> = {}
  const byGvk = new Map<string, string>()
  const kinds = new Set<string>()
  for (const spec of specs) {
    for (const [key, schema] of entries(obj(spec["components"])?.["schemas"])) {
      schemas[key] ??= schema
      for (const g of list(obj(schema)?.["x-kubernetes-group-version-kind"])) {
        const gvk = obj(g)
        const [group, version, kind] = [gvk?.["group"], gvk?.["version"], gvk?.["kind"]]
        if (typeof version !== "string" || typeof kind !== "string") continue
        const apiVersion = typeof group === "string" && group !== "" ? `${group}/${version}` : version
        if (!byGvk.has(`${apiVersion} ${kind}`)) byGvk.set(`${apiVersion} ${kind}`, key)
        kinds.add(kind)
      }
    }
  }
  const description = jsonObject([["components", jsonObject([["schemas", jsonObject(Object.entries(schemas))]])]])
  const { skipped, skip, fresh } = collector()
  const documents: Document[] = []
  /** The kinds the corpus uses, with their apiVersion and schema. */
  const used = new Map<string, { readonly apiVersion: string; readonly key: string }>()
  for (const file of files) {
    for (const [i, doc] of parseAllDocuments(file.text, { version: "1.1" }).entries()) {
      if (doc.errors.length > 0) {
        skip(`YAML error (${doc.errors[0]!.code})`)
        continue
      }
      let json: Json
      try {
        json = yamlToJson(doc.toJS({ mapAsMap: true, maxAliasCount: -1 }))
      } catch (e) {
        if (!(e instanceof NotJson)) throw e
        skip(e.message)
        continue
      }
      if (json === null) {
        skip("empty YAML document")
        continue
      }
      const o = obj(json)
      const apiVersion = o?.["apiVersion"]
      const kind = o?.["kind"]
      if (typeof apiVersion !== "string" || typeof kind !== "string") {
        skip("not a Kubernetes object (no apiVersion and kind)")
        continue
      }
      const key = byGvk.get(`${apiVersion} ${kind}`)
      if (key === undefined) {
        const group = apiVersion.includes("/") ? apiVersion.split("/")[0]! : ""
        const builtIn = kinds.has(kind) || group === "" || group.endsWith(".k8s.io") || !group.includes(".")
        skip(builtIn ? "an API version Kubernetes v1.37 doesn't serve (removed)" : "a custom resource (CRD) without a schema")
        continue
      }
      const seen = used.get(kind)
      if (seen !== undefined && seen.apiVersion !== apiVersion) {
        skip("a kind already used with another apiVersion (one case per kind)")
        continue
      }
      if (!fresh(json, "same JSON as another document")) continue
      used.set(kind, { apiVersion, key })
      documents.push({ id: `${file.name}#${i}`, kind, schema: undefined, array: false, responseName: "Manifest", json, root: "Manifest" })
    }
  }
  const prefix = "#/components/schemas/"
  return {
    description,
    converter: { prefix, constDiscriminators: true, keyedUnions: true, typeName: kubernetesNames(Object.keys(schemas), reserved) },
    schemaFrom,
    unit: "YAML documents",
    documents,
    skipped,
    prepare: (c) => {
      const cases = [...used].sort(byName)
      c.define("Manifest", () => c.variantOf("kind", cases.map(([kind, u]) => [kind, jsonObject([["$ref", `${prefix}${u.key}`]])] as const), "variant (Kubernetes kind)", cases.map(([kind]) => kind)))
    },
  }
}

// ── BFCL: function calls ────────────────────────────────────

/** The category of a BFCL file: `BFCL_v4_live_simple.json` → live_simple. */
const bfclCategory = (name: string): string => name.replace(/^BFCL_v\d+_/, "").replace(/\.json$/, "")

/** JSON Lines, numbers exact. */
const jsonLines = (text: string): Json[] => text.split("\n").filter((l) => l.trim() !== "").map((l) => parseJson(l, { maxDepth: 512 }))

/**
 * BFCL entries: each entry of a question file (`id`, `question`,
 * `function`) of the given categories, with its possible answer's
 * `ground_truth` added, as one document of the hand-written schema's
 * `Entry`. The other categories (multi-turn, relevance, memory, web search:
 * another shape, or no call) are left out, counted by category.
 */
export const functionCallCorpus = (
  questions: readonly TextFile[],
  answers: readonly TextFile[],
  categories: readonly string[],
  schemaText: string,
  schemaFrom: string,
  define: (c: Converter, text: string) => void,
): Corpus => {
  const { skipped, skip, fresh } = collector()
  const documents: Document[] = []
  const answerFiles = new Map(answers.map((f) => [bfclCategory(f.name), f]))
  for (const file of questions) {
    const category = bfclCategory(file.name)
    if (!categories.includes(category)) {
      // format_sensitivity is one object (ids by category), not entries
      skip(`category ${category}`, category === "format_sensitivity" ? 1 : jsonLines(file.text).length)
      continue
    }
    const truth = new Map(jsonLines(answerFiles.get(category)?.text ?? "").map((a) => [obj(a)?.["id"], obj(a)?.["ground_truth"]] as const))
    for (const entry of jsonLines(file.text)) {
      const o = obj(entry)
      const id = o?.["id"]
      const call = truth.get(id)
      if (o === undefined || typeof id !== "string" || call === undefined) {
        skip("no possible answer")
        continue
      }
      const json = jsonObject([...Object.entries(o), ["ground_truth", call]])
      if (!fresh(json, "same JSON as another entry")) continue
      documents.push({ id, kind: category, schema: undefined, array: false, responseName: "Entry", json, root: "Entry" })
    }
  }
  return {
    description: jsonObject([]),
    converter: JSON_SCHEMA,
    schemaFrom,
    unit: "entries",
    documents,
    skipped,
    schemaText,
    prepare: (c) => define(c, schemaText),
  }
}

// ── GeoJSON: features ───────────────────────────────────────

/** The features of a GeoJSON FeatureCollection, one document each, of the GeoJSON Feature JSON Schema (its root). */
export const geoJsonCorpus = (collection: JsonObject, schema: JsonObject, schemaFrom: string): Corpus => {
  const { skipped, skip, fresh } = collector()
  const documents: Document[] = []
  for (const [i, feature] of list(collection["features"]).entries()) {
    const o = obj(feature)
    if (o === undefined) {
      skip("not an object")
      continue
    }
    if (!fresh(feature, "same JSON as another feature")) continue
    const name = obj(o["properties"])?.["NAME"]
    const kind = obj(o["geometry"])?.["type"]
    documents.push({ id: `${i}${typeof name === "string" ? ` ${name}` : ""}`, kind: typeof kind === "string" ? kind : "null", schema, array: false, responseName: "Feature", json: feature })
  }
  return { description: schema, converter: JSON_SCHEMA, schemaFrom, unit: "features", documents, skipped }
}

// ── GH Archive: events ──────────────────────────────────────

/** A seeded generator (mulberry32): the same sample on every run. */
const random = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

/**
 * A stratified sample of about `n` items by `key`: from each group, its share
 * of `n` (at least `floor` items, or all it has), the first of a seeded
 * shuffle; kept in the input's order. Pure.
 */
export const stratified = <A>(items: readonly A[], key: (a: A) => string, n: number, seed: number, floor = 20): A[] => {
  const groups = new Map<string, number[]>()
  items.forEach((a, i) => groups.set(key(a), [...(groups.get(key(a)) ?? []), i]))
  const next = random(seed)
  const keep = new Set<number>()
  for (const [, idx] of [...groups].sort(byName)) {
    const shuffled = [...idx]
    for (let i = shuffled.length - 1; i > 0; i--) {
      const j = Math.floor(next() * (i + 1))
      ;[shuffled[i], shuffled[j]] = [shuffled[j]!, shuffled[i]!]
    }
    const quota = Math.min(idx.length, Math.max(floor, Math.round((n * idx.length) / items.length)))
    for (const i of shuffled.slice(0, quota)) keep.add(i)
  }
  return items.filter((_, i) => keep.has(i))
}

/** `PullRequestReviewEvent` → pull-request-review-event (the payload's component in GitHub's description). */
const kebab = (name: string): string => name.replace(/(?<=[a-z0-9])(?=[A-Z])/g, "-").toLowerCase()

/**
 * GH Archive events (the lines of an hour's JSON Lines file), a stratified
 * sample by event type, typed by GitHub's description: the root is a closed
 * variant by `type` (tag = the event type, the member `type` in JSON), each
 * case the `event` schema with its `payload` the component of the type's
 * name (`IssuesEvent` → `issues-event`), or `Any` when there is none.
 */
export const ghArchiveCorpus = (description: JsonObject, lines: string, sample: number, seed: number, schemaFrom: string): Corpus => {
  const { skipped, skip, fresh } = collector()
  const events = jsonLines(lines)
  const schemas = obj(obj(description["components"])?.["schemas"]) ?? {}
  const event = obj(schemas["event"]) ?? {}
  const typeOf = (e: Json) => {
    const t = obj(e)?.["type"]
    return typeof t === "string" ? t : ""
  }
  const picked = stratified(events, typeOf, sample, seed)
  skip("not in the sample", events.length - picked.length)
  const documents: Document[] = []
  const types = new Set<string>()
  for (const e of picked) {
    const id = obj(e)?.["id"]
    if (typeof id !== "string" || typeOf(e) === "") {
      skip("not an event (no id and type)")
      continue
    }
    if (!fresh(e, "same JSON as another event")) continue
    types.add(typeOf(e))
    documents.push({ id, kind: typeOf(e), schema: undefined, array: false, responseName: "GhEvent", json: e, root: "GhEvent" })
  }
  const prefix = "#/components/schemas/"
  return {
    description,
    converter: OPENAPI,
    schemaFrom,
    unit: "events",
    documents,
    skipped,
    stream: "GhEvents",
    prepare: (c) => {
      const cases = [...types].sort()
      const caseSchema = (type: string): JsonObject => {
        const payload = schemas[kebab(type)] !== undefined ? jsonObject([["$ref", `${prefix}${kebab(type)}`]]) : jsonObject([])
        return jsonObject(Object.entries(event).map(([k, v]) => [k, k === "properties" ? jsonObject([...Object.entries(obj(v) ?? {}), ["payload", payload]]) : v] as const))
      }
      c.define("GhEvent", () => c.variantOf("type", cases.map((t) => [t, caseSchema(t)] as const), "variant (event type)", cases))
    },
  }
}
