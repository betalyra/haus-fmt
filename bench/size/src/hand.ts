/**
 * A hand-written haus schema → the converter's types (openapi.ts), for a
 * source without a schema of its own (BFCL). The JSON mapping is the
 * converter's: records, arrays, maps, `Maybe`, numbers and strings as in
 * openapi.ts; a closed variant of tags without payloads is an enum whose
 * JSON value is the tag in snake_case (`User` ↔ "user", `InProgress` ↔
 * "in_progress"), as the schema file says.
 */
import { parseSchemaFile, type Instance, type Type } from "@haus-fmt/haus"
import type { Converter, Field, HType } from "./openapi.ts"

/** `InProgress` → in_progress. */
export const snakeCase = (tag: string): string => tag.replace(/(?<=[a-z0-9])(?=[A-Z])/g, "_").toLowerCase()

const INT = new Set(["Int", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"])

/**
 * Defines every type of the schema file in `converter` (same names); returns
 * their names. Throws for what the mapping doesn't cover (payload cases,
 * generics, Bytes, Decimal).
 */
export const defineSchemaFile = (converter: Converter, text: string): string[] => {
  const file = parseSchemaFile(text)
  const toH = (t: Type): HType => {
    switch (t.kind) {
      case "builtin":
        if (t.name === "String") return { k: "string" }
        if (t.name === "Bool") return { k: "bool" }
        if (t.name === "Any") return { k: "any" }
        if (t.name === "Float64" || t.name === "Float32") return { k: "float" }
        if (INT.has(t.name)) return { k: "int" }
        throw new Error(`hand-written schema: no JSON mapping for ${t.name}`)
      case "std":
        if (t.name === "Instant" || t.name === "Date") return { k: "time", tag: t.name, valid: true }
        throw new Error(`hand-written schema: no JSON mapping for ${t.name}`)
      case "array": return { k: "array", item: toH(t.item) }
      case "map": return { k: "map", value: toH(t.value) }
      case "maybe": return { k: "maybe", item: toH(t.item) }
      case "record": {
        const fields = new Map<string, Field>(t.fields.map((f) => [f.key, { type: toH(f.type), optional: f.optional }]))
        return { k: "record", fields, spreads: [] }
      }
      case "variant": {
        if (t.open || t.cases.some((c) => c.payload.kind !== "none")) throw new Error("hand-written schema: only closed variants of tags without payloads (enums)")
        const tags = t.cases.map((c) => c.tag)
        return { k: "enum", tags, values: tags.map(snakeCase) }
      }
      case "ref": {
        const instance: Instance = t.instance
        if (instance.args.length > 0) throw new Error("hand-written schema: no generic types")
        return { k: "ref", name: instance.name, target: () => converter.typeOf(instance.name) }
      }
      case "secret":
      case "param":
        throw new Error(`hand-written schema: no JSON mapping for ${t.kind}`)
    }
  }
  return file.definitions.map((d) => converter.define(d.name, () => toH(d.template.body)))
}
