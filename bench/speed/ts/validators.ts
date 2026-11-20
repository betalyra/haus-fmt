/**
 * The JSON baselines of the typed tasks: validators and a schema-compiled
 * writer, built from the JSON Schema convert exports beside the haus schema
 * (`<source>.schema.json`, size/src/jsonschema.ts: the haus schema's types,
 * said for the source's JSON through convert's JSON mapping). Each reads
 * exactly the subset that file is written in, and throws on anything else.
 *
 *   Zod 4           the schema translated to Zod: z.object (open: unknown members dropped,
 *                   as haus's decoder drops them), z.int(), z.iso.datetime({ offset: true }),
 *                   z.iso.date(), z.enum, z.discriminatedUnion for a variant by a member, and
 *                   z.union of the cases with a check that exactly one case's keys are there for
 *                   a variant by keys
 *   Ajv 8           the schema as it is, with ajv-formats (date-time, date) and Ajv's
 *                   `discriminator` keyword
 *   TypeBox 1       the schema as it is, `Schema.Compile` (its own formats)
 *   fast-json-stringify  the schema for writing: records write the members they list; a variant
 *                   by keys becomes anyOf of its cases, which fast-json-stringify picks with Ajv
 *                   (or `{}` where it can't build them: `JsonWriter.keyedAsAny`)
 *
 * Pure: no Effect here; the speed step calls these while preparing.
 */
import { Ajv, type ValidateFunction } from "ajv"
import addFormatsModule from "ajv-formats"
import build from "fast-json-stringify"
import Schema from "typebox/schema"
import { z } from "zod"
import { DEFINITIONS, type JsonSchema, type JsonSchemaFile } from "../../size/src/jsonschema.ts"

/** ajv-formats is CommonJS with `exports.default`: what Node's ESM import gives depends on the runtime. */
type AddFormats = (ajv: Ajv, formats: readonly string[]) => Ajv
const addFormats: AddFormats = ((m: unknown) => (typeof m === "function" ? m : (m as { default: unknown }).default))(addFormatsModule) as AddFormats

/** The versions bench/package.json pins, as recorded in the results. */
export const VERSIONS = { zod: "4.6.7", ajv: "8.20.0", "ajv-formats": "3.0.1", typebox: "1.4.4", "fast-json-stringify": "7.3.1" } as const

const rootRef = (root: string): JsonSchema => ({ $ref: `${DEFINITIONS}${root}` })
const nameOf = (ref: unknown): string => {
  if (typeof ref !== "string" || !ref.startsWith(DEFINITIONS)) throw new Error(`a $ref outside the definitions: ${String(ref)}`)
  return ref.slice(DEFINITIONS.length)
}
const array = (x: unknown): readonly JsonSchema[] => (Array.isArray(x) ? (x as JsonSchema[]) : [])
const strings = (x: unknown): readonly string[] => (Array.isArray(x) ? (x as string[]) : [])
const isNullSchema = (s: JsonSchema) => s["type"] === "null" && Object.keys(s).length === 1
/** `{}` (anything), itself or through `$ref`s: a case of a variant by keys whose payload is Any. */
const isAny = (file: JsonSchemaFile, s: JsonSchema): boolean => {
  for (let i = 0; s["$ref"] !== undefined && i < 64; i++) s = file.definitions[nameOf(s["$ref"])] ?? {}
  return Object.keys(s).length === 0
}
/** A variant by keys: `oneOf: [{ required }…], allOf: [{ if: { required }, then }…]`. */
const keyedCases = (s: JsonSchema): { keys: readonly string[]; then: JsonSchema }[] | undefined =>
  s["allOf"] === undefined ? undefined : array(s["allOf"]).map((c) => ({ keys: strings((c["if"] as JsonSchema)["required"]), then: c["then"] as JsonSchema }))

// ── Zod ──────────────────────────────────────────────────────

/** A Zod schema per named type of the file, built on first use. */
export const zodSchemas = (file: JsonSchemaFile): ((root: string) => z.ZodType) => {
  const built = new Map<string, z.ZodType>()
  const building = new Set<string>()
  const ref = (name: string): z.ZodType => {
    const done = built.get(name)
    if (done !== undefined) return done
    // A type that refers to itself: lazily, the only place a z.lazy is needed.
    if (building.has(name)) return z.lazy(() => built.get(name)!)
    const def = file.definitions[name]
    if (def === undefined) throw new Error(`no definition ${name}`)
    building.add(name)
    const s = of(def)
    building.delete(name)
    built.set(name, s)
    return s
  }
  const shape = (s: JsonSchema, except?: string): Record<string, z.ZodType> => {
    const required = new Set(strings(s["required"]))
    const props = (s["properties"] ?? {}) as Record<string, JsonSchema>
    return Object.fromEntries(Object.entries(props).filter(([k]) => k !== except).map(([k, p]) => [k, required.has(k) ? of(p) : of(p).optional()]))
  }
  const of = (s: JsonSchema): z.ZodType => {
    if (s["$ref"] !== undefined) return ref(nameOf(s["$ref"]))
    if (Object.keys(s).length === 0) return z.unknown()
    if (s["anyOf"] !== undefined) {
      const [a, b, ...rest] = array(s["anyOf"])
      if (a === undefined || b === undefined || rest.length > 0 || !isNullSchema(a)) throw new Error("anyOf other than [null, T]")
      return of(b).nullable()
    }
    if (Array.isArray(s["type"])) {
      const types = (s["type"] as string[]).filter((t) => t !== "null")
      if (types.length !== 1 || s["type"].length !== 2) throw new Error(`type ${JSON.stringify(s["type"])}`)
      const e = s["enum"]
      return of({ ...s, type: types[0], ...(Array.isArray(e) ? { enum: e.filter((v) => v !== null) } : {}) }).nullable()
    }
    const discriminator = s["discriminator"] as { propertyName: string } | undefined
    if (discriminator !== undefined) {
      const member = discriminator.propertyName
      const cases = array(s["oneOf"]).map((b) => {
        const fields = shape(b, member)
        const value = ((b["properties"] as Record<string, JsonSchema>)[member]!)["const"] as string
        return z.object({ ...fields, [member]: z.literal(value) })
      })
      return z.discriminatedUnion(member, cases as [z.ZodObject, ...z.ZodObject[]])
    }
    const keyed = keyedCases(s)
    if (keyed !== undefined) {
      // Each option requires its case's keys (a record case requires them as fields; a case
      // whose payload is Any, here); the check asks for exactly one case's keys, as haus does.
      const options = keyed.map((c) =>
        isAny(file, c.then) ? z.looseObject(Object.fromEntries(c.keys.map((k) => [k, z.unknown()]))) : of(c.then))
      const keySets = keyed.map((c) => c.keys)
      return z.union(options).check(z.refine((v) => keySets.filter((ks) => ks.every((k) => Object.hasOwn(v as object, k))).length === 1, "exactly one case's keys"))
    }
    switch (s["type"]) {
      case "string": {
        if (Array.isArray(s["enum"])) return z.enum(s["enum"] as [string, ...string[]])
        if (s["format"] === "date-time") return z.iso.datetime({ offset: true })
        if (s["format"] === "date") return z.iso.date()
        if (s["format"] !== undefined) throw new Error(`format ${String(s["format"])}`)
        return z.string()
      }
      case "integer": return z.int()
      case "number": return z.number()
      case "boolean": return z.boolean()
      case "array": return z.array(of(s["items"] as JsonSchema))
      case "object":
        if (s["additionalProperties"] !== undefined) return z.record(z.string(), of(s["additionalProperties"] as JsonSchema))
        return z.object(shape(s))
      default:
        throw new Error(`a schema the Zod translation doesn't read: ${JSON.stringify(s).slice(0, 200)}`)
    }
  }
  return ref
}

// ── Ajv, TypeBox ─────────────────────────────────────────────

const AJV_KEY = "haus"

/** Ajv's validators: one Ajv instance per file, a compiled validator per named type. */
export const ajvValidators = (file: JsonSchemaFile): ((root: string) => ValidateFunction) => {
  // strictTypes off: the keyed variants' `{ required }` branches have no `type` (the parent's is object).
  const ajv = new Ajv({ discriminator: true, allowUnionTypes: true, strictTypes: false, allErrors: false })
  addFormats(ajv, ["date-time", "date"])
  ajv.addSchema(file, AJV_KEY)
  return (root) => {
    const v = ajv.getSchema(`${AJV_KEY}${DEFINITIONS}${root}`)
    if (v === undefined) throw new Error(`Ajv: no schema ${root}`)
    return v
  }
}

/** TypeBox's compiled validator of a named type (the file's definitions beside the root). */
export const typeboxValidator = (file: JsonSchemaFile, root: string) => Schema.Compile({ ...rootRef(root), definitions: file.definitions } as never)

// ── fast-json-stringify ──────────────────────────────────────

/**
 * The schema for writing: a variant by keys as anyOf of its cases (or, with
 * `keyedAsAny`, as `{}`: JSON.stringify of that value); Ajv's
 * `discriminator` left out.
 */
const forWriting = (file: JsonSchemaFile, s: JsonSchema, keyedAsAny: boolean): JsonSchema => {
  const keyed = keyedCases(s)
  if (keyed !== undefined) {
    if (keyedAsAny) return {}
    return {
      anyOf: keyed.map((c) => (isAny(file, c.then) ? { type: "object", required: c.keys, additionalProperties: true } : forWriting(file, c.then, keyedAsAny))),
    }
  }
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(s)) {
    if (k === "discriminator") continue
    if (k === "properties") out[k] = Object.fromEntries(Object.entries(v as Record<string, JsonSchema>).map(([p, x]) => [p, forWriting(file, x, keyedAsAny)]))
    else if (k === "items" || k === "additionalProperties") out[k] = forWriting(file, v as JsonSchema, keyedAsAny)
    else if (k === "anyOf" || k === "oneOf") out[k] = array(v).map((x) => forWriting(file, x, keyedAsAny))
    else out[k] = v
  }
  return out
}

export interface JsonWriter {
  readonly write: (value: unknown) => string
  /**
   * fast-json-stringify 7.3 can't build a variant by keys whose cases refer
   * back to it (Vega-Lite's specs: its schema merging recurses without end,
   * "Maximum call stack size exceeded"); such a root is built with every
   * variant by keys written as `{}`, JSON.stringify of that value.
   */
  readonly keyedAsAny: boolean
}

/** fast-json-stringify's writer of a named type. */
export const jsonWriters = (file: JsonSchemaFile): ((root: string) => JsonWriter) => {
  const definitionsOf = (keyedAsAny: boolean) => Object.fromEntries(Object.entries(file.definitions).map(([k, v]) => [k, forWriting(file, v, keyedAsAny)]))
  const exact = definitionsOf(false)
  return (root) => {
    try {
      return { write: build({ ...rootRef(root), definitions: exact } as never) as (value: unknown) => string, keyedAsAny: false }
    } catch (e) {
      if (!(e instanceof RangeError)) throw e
      return { write: build({ ...rootRef(root), definitions: definitionsOf(true) } as never) as (value: unknown) => string, keyedAsAny: true }
    }
  }
}
