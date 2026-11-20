/**
 * The converter's types (openapi.ts, hand.ts) → a JSON Schema (draft-07) of
 * the source's JSON: what the haus schema checks, said for the JSON that
 * convert reads, through the same JSON mapping (openapi.ts `toHaus`). The
 * TypeScript speed benchmark's JSON validators (Ajv, TypeBox, Zod) and its
 * schema-compiled JSON writer (fast-json-stringify) are built from it, so
 * "JSON.parse + validation" checks what haus's typed parse checks.
 *
 *   named type            definitions/<Name>, the haus type's name; `$ref` where haus refers to it
 *   String / Int / Float64 / Bool   type string / integer / number / boolean
 *   Instant / Date        type string, format date-time / date
 *   Any                   {} (anything)
 *   enum                  type string, enum [the JSON values]
 *   Maybe T               T or null: `type: [t, "null"]` (and `null` in an enum) where T has
 *                         one type, else anyOf [{ type: null }, T]
 *   Array T, Map V        type array, items T; type object, additionalProperties V
 *   record                type object, properties, required. Open: members it doesn't list are
 *                         allowed, as haus's records are here
 *   variant by a member   type object, the member required, oneOf: one branch per case, the
 *                         member a `const` beside the case's fields; `discriminator` (Ajv's
 *                         keyword: the member picks the branch)
 *   variant by keys       type object, oneOf [{ required: keys }…] (exactly one case's keys, as
 *                         convert's reader asks), allOf [{ if: { required: keys }, then: payload }…]
 *
 * Only this subset is written; `speed/ts/validators.ts` reads exactly it.
 */
import type { HType, RecordType } from "./openapi.ts"

export type JsonSchema = { readonly [key: string]: unknown }

/** A draft-07 schema file: `definitions` for every named type the roots reach. */
export interface JsonSchemaFile {
  readonly $schema: string
  readonly $comment: string
  readonly definitions: Readonly<Record<string, JsonSchema>>
}

export const DRAFT_07 = "http://json-schema.org/draft-07/schema#"
export const DEFINITIONS = "#/definitions/"

const SIMPLE = { string: "string", int: "integer", float: "number", bool: "boolean" } as const

/** The JSON Schema of the named types `roots` reach. Pure. */
export const jsonSchemaFile = (roots: readonly string[], typeOf: (name: string) => HType, from: string): JsonSchemaFile => {
  const definitions: Record<string, JsonSchema> = {}
  const pending = [...roots]
  const fieldsOf = (r: RecordType) => ({
    properties: Object.fromEntries([...r.fields].map(([k, f]) => [k, schemaOf(f.type)])),
    required: [...r.fields].filter(([, f]) => !f.optional).map(([k]) => k),
  })
  const record = (r: RecordType): JsonSchema => {
    const { properties, required } = fieldsOf(r)
    return { type: "object", properties, ...(required.length > 0 ? { required } : {}) }
  }
  const schemaOf = (t: HType): JsonSchema => {
    switch (t.k) {
      case "ref":
        if (!Object.hasOwn(definitions, t.name)) pending.push(t.name)
        return { $ref: `${DEFINITIONS}${t.name}` }
      case "string":
      case "int":
      case "float":
      case "bool":
        return { type: SIMPLE[t.k] }
      case "any":
        return {}
      case "time":
        return t.valid ? { type: "string", format: t.tag === "Instant" ? "date-time" : "date" } : { type: "string" }
      case "enum":
        return { type: "string", enum: t.values }
      case "maybe": {
        const item = schemaOf(t.item)
        if (Object.keys(item).length === 0) return item // Maybe Any: anything
        if (typeof item["type"] === "string" && item["oneOf"] === undefined) {
          const e = item["enum"]
          return { ...item, type: [item["type"], "null"], ...(Array.isArray(e) ? { enum: [...e, null] } : {}) }
        }
        return { anyOf: [{ type: "null" }, item] }
      }
      case "array":
        return { type: "array", items: schemaOf(t.item) }
      case "map":
        return { type: "object", additionalProperties: schemaOf(t.value) }
      case "record":
        return record(t)
      case "variant": {
        const cases = [...t.cases.values()]
        const member = t.member
        if (member !== undefined) {
          return {
            type: "object",
            required: [member],
            discriminator: { propertyName: member },
            oneOf: cases.map((c) => {
              if (c.payload.k !== "record") throw new Error("a case of a discriminated variant whose payload isn't a record")
              const { properties, required } = fieldsOf(c.payload)
              return { type: "object", properties: { [member]: { const: c.value }, ...properties }, required: [member, ...required] }
            }),
          }
        }
        return {
          type: "object",
          oneOf: cases.map((c) => ({ required: c.keys ?? [] })),
          allOf: cases.map((c) => ({ if: { required: c.keys ?? [] }, then: schemaOf(c.payload) })),
        }
      }
    }
  }
  while (pending.length > 0) {
    const name = pending.shift()!
    if (Object.hasOwn(definitions, name)) continue
    definitions[name] = {} // a placeholder, so a type that refers to itself isn't queued again
    definitions[name] = schemaOf(typeOf(name))
  }
  return {
    $schema: DRAFT_07,
    $comment: `Generated by bench/size/src/jsonschema.ts from the types of the haus schema (${from}) and the JSON mapping convert reads the source's JSON with.`,
    definitions,
  }
}
