/**
 * Mutated documents for the spot check before timing: each JSON validator
 * must reject them. A mutation is made where the document's JSON Schema
 * (size/src/jsonschema.ts) types a value, at a place where convert's reader
 * (openapi.ts `toHaus`) rejects it too, so haus's typed parse rejects the
 * same document:
 *
 *   type      a typed value replaced by one of another JSON type (a string by 12345, a
 *             number or boolean by "x", an object or array by "x")
 *   missing   a required member removed
 *   enum      an enum value replaced by one the enum doesn't list
 *   format    a date-time or date replaced by "not a date"
 *
 * Pure.
 */
import { DEFINITIONS, type JsonSchema, type JsonSchemaFile } from "../../size/src/jsonschema.ts"

export type MutationKind = "type" | "missing" | "enum" | "format"
export const MUTATION_KINDS: readonly MutationKind[] = ["type", "missing", "enum", "format"]

type Json = null | boolean | number | string | Json[] | { [k: string]: Json }
type Path = readonly (string | number)[]
interface Site { readonly kind: MutationKind; readonly path: Path; readonly key?: string; readonly value?: Json }

const isObject = (v: unknown): v is Record<string, Json> => typeof v === "object" && v !== null && !Array.isArray(v)

/** The places in `value` where each kind of mutation can be made (the first few of each kind). */
const sitesOf = (file: JsonSchemaFile, root: string, value: Json, limit = 4): Site[] => {
  const sites: Site[] = []
  const count = (k: MutationKind) => sites.filter((s) => s.kind === k).length
  const add = (s: Site) => {
    // (not the whole document replaced: too easy to reject)
    if (count(s.kind) < limit && (s.kind === "missing" || s.path.length > 0)) sites.push(s)
  }
  const resolve = (s: JsonSchema): JsonSchema => {
    for (let i = 0; typeof s["$ref"] === "string" && i < 64; i++) s = file.definitions[(s["$ref"] as string).slice(DEFINITIONS.length)]!
    return s
  }
  const walk = (schema: JsonSchema, v: Json, path: Path, depth: number): void => {
    if (depth > 40) return
    const s = resolve(schema)
    if (Object.keys(s).length === 0 || v === null) return // Any, or a null where null is allowed
    if (Array.isArray(s["anyOf"])) return walk((s["anyOf"] as JsonSchema[])[1]!, v, path, depth + 1)
    const types = Array.isArray(s["type"]) ? (s["type"] as string[]) : [s["type"] as string]
    const type = types.find((t) => t !== "null")
    if (type === "string") {
      if (Array.isArray(s["enum"])) add({ kind: "enum", path, value: "not-a-value-of-the-enum" })
      if (s["format"] !== undefined) add({ kind: "format", path, value: "not a date" })
      add({ kind: "type", path, value: 12345 })
      return
    }
    if (type === "integer" || type === "number" || type === "boolean") return add({ kind: "type", path, value: "x" })
    if (type === "array" && Array.isArray(v)) {
      add({ kind: "type", path, value: "x" })
      v.slice(0, 3).forEach((x, i) => walk(s["items"] as JsonSchema, x, [...path, i], depth + 1))
      return
    }
    if (type !== "object" || !isObject(v)) return
    add({ kind: "type", path, value: "x" })
    if (s["additionalProperties"] !== undefined) {
      for (const [k, x] of Object.entries(v).slice(0, 3)) walk(s["additionalProperties"] as JsonSchema, x, [...path, k], depth + 1)
      return
    }
    const discriminator = s["discriminator"] as { propertyName: string } | undefined
    if (discriminator !== undefined) {
      const member = discriminator.propertyName
      const branch = (s["oneOf"] as JsonSchema[]).find((b) => ((b["properties"] as Record<string, JsonSchema>)[member]!)["const"] === v[member])
      return branch === undefined ? undefined : walk(branch, v, path, depth + 1)
    }
    if (Array.isArray(s["allOf"])) {
      const c = (s["allOf"] as JsonSchema[]).find((x) => ((x["if"] as JsonSchema)["required"] as string[]).every((k) => Object.hasOwn(v, k)))
      return c === undefined ? undefined : walk(c["then"] as JsonSchema, v, path, depth + 1)
    }
    const props = (s["properties"] ?? {}) as Record<string, JsonSchema>
    for (const k of (s["required"] ?? []) as string[]) if (Object.hasOwn(v, k)) add({ kind: "missing", path, key: k })
    for (const [k, p] of Object.entries(props)) if (Object.hasOwn(v, k)) walk(p, v[k]!, [...path, k], depth + 1)
  }
  walk({ $ref: `${DEFINITIONS}${root}` }, value, [], 0)
  return sites
}

const apply = (value: Json, site: Site): Json => {
  const copy = structuredClone(value)
  const parentPath = site.kind === "missing" ? site.path : site.path.slice(0, -1)
  const parent = parentPath.reduce<Json>((at, k) => (at as Record<string | number, Json>)[k]!, copy) as Record<string | number, Json>
  if (site.kind === "missing") delete parent[site.key!]
  else parent[site.path.at(-1)!] = site.value!
  return copy
}

export interface Mutated { readonly kind: MutationKind; readonly doc: number; readonly where: string; readonly value: unknown }

/** Up to `perKind` mutated documents of each kind, from the first documents that have such a place. */
export const mutations = (file: JsonSchemaFile, roots: readonly string[], values: readonly unknown[], perKind = 5): Mutated[] => {
  const out: Mutated[] = []
  for (const [doc, v] of values.entries()) {
    if (MUTATION_KINDS.every((k) => out.filter((m) => m.kind === k).length >= perKind)) break
    for (const site of sitesOf(file, roots[doc]!, v as Json)) {
      if (out.filter((m) => m.kind === site.kind).length >= perKind) continue
      out.push({ kind: site.kind, doc, where: `$${site.path.map((k) => `.${k}`).join("")}${site.key ? `.${site.key}` : ""}`, value: apply(v as Json, site) })
      break // one mutation per document
    }
  }
  return out
}
