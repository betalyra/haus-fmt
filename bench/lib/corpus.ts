/**
 * The GitHub corpus: every example response in the REST API description,
 * one document per example.
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
import { readFileSync } from "node:fs"
import { isJsonObject, parseJson, stringifyJson, type Json, type JsonObject } from "@haus-fmt/haus"

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
}

export interface Corpus {
  readonly description: JsonObject
  readonly documents: readonly Document[]
  /** Examples left out, by reason. */
  readonly skipped: Readonly<Record<string, number>>
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

export const readCorpus = (path: string): Corpus => {
  const description = parseJson(readFileSync(path, "utf8"), { maxDepth: 512 })
  if (!isJsonObject(description)) throw new Error(`${path}: not an OpenAPI description`)
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
  return { description, documents, skipped }
}
