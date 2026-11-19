/**
 * OpenAPI 3.1 / JSON Schema (the subset GitHub's description uses) → haus
 * schema types, and the JSON ↔ haus mapping those types give GitHub's JSON.
 *
 * Types:
 *
 *   components/schemas/<name>   type <PascalName> = …   (kebab/snake → PascalCase; collisions get a number)
 *   $ref                        a reference to that name
 *   properties                  a record: `field` if required, `field?` if not. Records are open,
 *                               as in haus by default: a member the description doesn't list is
 *                               kept, as imported JSON (spec §16.1), and decoding ignores it
 *   additionalProperties only   Map v                (no properties and no additionalProperties: Map Any)
 *   type [T, "null"], nullable, an `anyOf`/`oneOf` branch `{type: null}`   Maybe T
 *   enum (strings)              a closed variant of tags, spelled by a convention:
 *                               `open` → Open, `in_progress` → InProgress, `read-only` → ReadOnly,
 *                               `+1` → Plus1, `OWNER` stays (already a tag). Each enum keeps its
 *                               map from tags to values; an enum whose values give the same tag
 *                               twice stays String (counted)
 *   integer → Int, number → Float64, boolean → Bool, string → String
 *   format date-time → Instant, format date → Date (std/time), but String where an example
 *                               value at that type isn't one (counted)
 *   allOf                       a record: `...Name` spreads for referenced records, their fields
 *                               merged otherwise; one branch alone is that branch
 *   oneOf/anyOf + discriminator a closed variant: the discriminator value is the tag (same
 *                               convention), the branch's other fields its record payload
 *   oneOf/anyOf without one     Any (counted), unless all branches but one are `null`
 *   several types, no type      Any (counted)
 *
 * JSON mapping (for the round trip): spec §16.3 with the reader options the
 * benchmark plan names (benchmarks.md §4.2), because GitHub's JSON isn't
 * schema-based JSON: an enum is its value (`"in_progress"`), integers are
 * JSON numbers (§16.3 quotes `Int`), a variant's tag is the discriminator
 * member (`"user_view_type": "public"`) instead of `"_tag"`, and unlisted
 * members are kept. `Any` maps as the import (§16.1) and back. With
 * `enums: "strings"` an enum is a String instead: the exact §16.3 mapping.
 */
import {
  arr, checkStdTime, compileSchemaFile, importJsonValue, isJsonObject, JsonNumber, jsonObject, normalizeNumber, num, rec, str, variant,
  type Json, type JsonObject, type Value,
} from "@haus-fmt/haus"
import type * as h from "@haus-fmt/haus/schema"

// ── types ────────────────────────────────────────────────────

export interface Field {
  readonly type: HType
  readonly optional: boolean
}

export interface RecordType {
  readonly k: "record"
  /** Every field, those copied by spreads included. */
  readonly fields: Map<string, Field>
  /** Named records spread into this one (`...Name`); their fields are in `fields` too. */
  readonly spreads: string[]
}

export type HType =
  | { readonly k: "string" | "int" | "float" | "bool" | "any" }
  /** `valid` turns false when an example value isn't one; the type is then String. */
  | { readonly k: "time"; readonly tag: "Instant" | "Date"; valid: boolean }
  /** `tags[i]` is the tag of `values[i]`. */
  | { readonly k: "enum"; readonly values: readonly string[]; readonly tags: readonly string[] }
  | { readonly k: "maybe"; readonly item: HType }
  | { readonly k: "array"; readonly item: HType }
  | { readonly k: "map"; readonly value: HType }
  | RecordType
  /** A discriminated union: `member` holds the tag's value in JSON. */
  | { readonly k: "variant"; readonly member: string; readonly cases: ReadonlyMap<string, { readonly value: string; readonly record: RecordType }> }
  | { readonly k: "ref"; readonly name: string; readonly target: () => HType }

/** How enums are written in haus: as tags (the idiomatic form) or as the JSON strings. */
export type EnumStyle = "tags" | "strings"

const TAG = /^[A-Z][A-Za-z0-9_]*$/

/** `open` → Open, `in_progress` → InProgress, `+1` → Plus1, `OWNER` → OWNER. */
export const tagName = (value: string): string => {
  if (TAG.test(value)) return value
  const words = value.replace(/^\+/, "plus ").replace(/^-/, "minus ").split(/[^A-Za-z0-9]+/).filter(Boolean)
  if (words.length === 0) return "Empty"
  const tag = words.map((w) => w[0]!.toUpperCase() + w.slice(1)).join("")
  return /^[0-9]/.test(tag) ? `N${tag}` : tag
}

/** `pull-request-simple` → PullRequestSimple. */
const typeName = (key: string): string => {
  const name = key.split(/[^A-Za-z0-9]+/).filter(Boolean).map((w) => w[0]!.toUpperCase() + w.slice(1)).join("")
  return /^[A-Z]/.test(name) ? name : `T${name}`
}

/** Names a schema type can't take: built-in and std/time types. */
const RESERVED = new Set([
  "String", "Bytes", "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Float32", "Float64", "Decimal",
  "Any", "Array", "Map", "Maybe", "Result", "Secret", "Stream", "Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone",
])

const unref = (t: HType): HType => {
  for (let i = 0; t.k === "ref"; i++) {
    if (i > 64) throw new Error("reference chain too long")
    t = t.target()
  }
  return t
}

// ── OpenAPI → types ──────────────────────────────────────────

const asObject = (j: Json | undefined): JsonObject | undefined => (j !== undefined && isJsonObject(j) ? j : undefined)
const list = (j: Json | undefined): readonly Json[] => (Array.isArray(j) ? j : [])
const isNullSchema = (s: Json) => {
  const o = asObject(s)
  return o !== undefined && (o["type"] === "null" || (Array.isArray(o["type"]) && o["type"].length === 1 && o["type"][0] === "null"))
}
/** A branch that only constrains (`{ required: [...] }`): it adds no type. */
const isConstraintOnly = (s: Json) => {
  const o = asObject(s)
  return o !== undefined && !["type", "$ref", "properties", "items", "enum", "allOf", "oneOf", "anyOf", "additionalProperties"].some((k) => k in o)
}

/** Why a position is `Any`, and other mapping decisions, counted. */
export type Counts = Record<string, number>

export class Converter {
  /** Named types, by component key. */
  private readonly named = new Map<string, { readonly name: string; type: HType | undefined }>()
  private readonly usedNames = new Set<string>(RESERVED)
  /** Named types for inline response schemas, by name, and the name of each such schema. */
  private readonly extra = new Map<string, HType>()
  private readonly inlineNames = new Map<Json, string>()
  readonly counts: Counts = {}
  /** Messages about decisions worth reading (enum collisions, name collisions). */
  readonly notes: string[] = []

  private readonly description: JsonObject

  constructor(description: JsonObject) {
    this.description = description
  }

  private count(what: string) {
    this.counts[what] = (this.counts[what] ?? 0) + 1
  }

  private freshName(base: string): string {
    let name = base
    for (let i = 2; this.usedNames.has(name); i++) name = `${base}${i}`
    if (name !== base) this.notes.push(`type name ${base} taken: using ${name}`)
    this.usedNames.add(name)
    return name
  }

  /** A reference to the component schema `key`, converting it on first use. */
  ref(key: string): HType {
    let entry = this.named.get(key)
    if (!entry) {
      const schema = asObject(asObject(asObject(this.description["components"])?.["schemas"])?.[key])
      if (schema === undefined) throw new Error(`no component schema ${key}`)
      entry = { name: this.freshName(typeName(key)), type: undefined }
      this.named.set(key, entry)
      entry.type = this.convert(schema)
    }
    const e = entry
    return { k: "ref", name: e.name, target: () => e.type ?? { k: "any" } }
  }

  /** The type of a document whose response has `schema`: a named type, for decoding. */
  root(schema: Json | undefined, fallbackName: string): string {
    const r = asObject(schema)?.["$ref"]
    if (typeof r === "string" && r.startsWith("#/components/schemas/")) {
      const t = this.ref(r.slice("#/components/schemas/".length))
      return (t as { name: string }).name
    }
    const key = schema ?? {}
    const known = this.inlineNames.get(key)
    if (known !== undefined) return known
    const name = this.freshName(typeName(fallbackName))
    this.inlineNames.set(key, name)
    this.extra.set(name, this.convert(key))
    return name
  }

  /** The type of a named type (component or response). */
  typeOf(name: string): HType {
    const extra = this.extra.get(name)
    if (extra) return extra
    for (const e of this.named.values()) if (e.name === name) return e.type ?? { k: "any" }
    throw new Error(`no type ${name}`)
  }

  private any(why: string): HType {
    this.count(`Any: ${why}`)
    return { k: "any" }
  }

  convert(schema: Json): HType {
    const s = asObject(schema)
    if (s === undefined) return this.any("schema is not an object")
    const ref = s["$ref"]
    if (typeof ref === "string") {
      if (!ref.startsWith("#/components/schemas/")) return this.any(`reference outside components/schemas`)
      return this.ref(ref.slice("#/components/schemas/".length))
    }
    let types = Array.isArray(s["type"]) ? s["type"].filter((t): t is string => typeof t === "string") : typeof s["type"] === "string" ? [s["type"]] : []
    let nullable = types.includes("null") || s["nullable"] === true || list(s["enum"]).includes(null)
    types = types.filter((t) => t !== "null")
    const wrap = (inner: HType): HType => {
      if (!nullable) return inner
      if (unref(inner).k === "maybe") return inner
      this.count("Maybe")
      return { k: "maybe", item: inner }
    }

    for (const key of ["oneOf", "anyOf"] as const) {
      const branches = list(s[key])
      if (branches.length === 0) continue
      const nonNull = branches.filter((b) => !isNullSchema(b))
      if (nonNull.length < branches.length) nullable = true
      if (nonNull.every(isConstraintOnly)) continue // only constraints: the type is the rest of `s`
      if (nonNull.length === 1) return wrap(this.convert(nonNull[0]!))
      const discriminator = asObject(s["discriminator"])
      if (discriminator !== undefined) return wrap(this.variant(discriminator, nonNull))
      return wrap(this.any(`${key} without a discriminator`))
    }

    if (s["allOf"] !== undefined) {
      const branches = list(s["allOf"]).filter((b) => !isNullSchema(b))
      if (branches.length === 1 && s["properties"] === undefined) return wrap(this.convert(branches[0]!))
      return wrap(this.allOf(s, branches))
    }

    const values = list(s["enum"]).filter((v): v is string => typeof v === "string")
    if (values.length > 0) return wrap(this.enumType(values))

    if (types.length > 1) return wrap(this.any("several types"))
    switch (types[0]) {
      case "string":
        if (s["format"] === "date-time") return wrap({ k: "time", tag: "Instant", valid: true })
        if (s["format"] === "date") return wrap({ k: "time", tag: "Date", valid: true })
        return wrap({ k: "string" })
      case "integer":
        return wrap({ k: "int" })
      case "number":
        return wrap({ k: "float" })
      case "boolean":
        return wrap({ k: "bool" })
      case "array":
        return wrap({ k: "array", item: s["items"] === undefined ? this.any("array without items") : this.convert(s["items"]) })
      case "object":
        return wrap(this.objectType(s))
      case undefined:
        if (s["properties"] !== undefined || s["additionalProperties"] !== undefined) return wrap(this.objectType(s))
        if (s["items"] !== undefined) return wrap({ k: "array", item: this.convert(s["items"]) })
        return nullable ? wrap(this.any("only null")) : this.any("no type")
      default:
        return wrap(this.any(`type ${types[0]}`))
    }
  }

  private enumType(values: readonly string[]): HType {
    const tags = values.map(tagName)
    if (new Set(tags).size !== tags.length) {
      this.notes.push(`enum [${values.join(", ")}]: two values give the same tag; kept as String`)
      this.count("enum kept as String: tag collision")
      return { k: "string" }
    }
    this.count("enum")
    return { k: "enum", values, tags }
  }

  private objectType(s: JsonObject): HType {
    const properties = asObject(s["properties"])
    if (properties === undefined) {
      const additional = s["additionalProperties"]
      if (additional === undefined || additional === true || (asObject(additional) !== undefined && Object.keys(asObject(additional)!).length === 0)) {
        this.count("Map Any (free-form object)")
        return { k: "map", value: { k: "any" } }
      }
      if (additional === false) return { k: "record", fields: new Map(), spreads: [] }
      this.count("Map")
      return { k: "map", value: this.convert(additional) }
    }
    const required = new Set(list(s["required"]).filter((r): r is string => typeof r === "string"))
    const fields = new Map<string, Field>()
    for (const [key, p] of Object.entries(properties)) fields.set(key, { type: this.convert(p), optional: !required.has(key) })
    this.count("record")
    return { k: "record", fields, spreads: [] }
  }

  /**
   * `allOf`: a record. A referenced record is spread (`...Name`) when its
   * fields are copied unchanged; otherwise its fields are merged in.
   */
  private allOf(s: JsonObject, branches: readonly Json[]): HType {
    const fields = new Map<string, Field>()
    const spreads: { name: string; keys: string[] }[] = []
    const inline = new Set<string>()
    const add = (key: string, f: Field) => {
      if (fields.has(key)) inline.add(key) // defined twice: the later definition wins, merged
      fields.set(key, f)
    }
    for (const b of [...branches, { type: "object", properties: s["properties"] ?? {}, required: s["required"] ?? [] } as JsonObject]) {
      const t = this.convert(b)
      const u = unref(t)
      if (u.k === "record") {
        if (t.k === "ref") spreads.push({ name: t.name, keys: [...u.fields.keys()] })
        else for (const key of u.fields.keys()) inline.add(key)
        for (const [key, f] of u.fields) add(key, f)
      } else if (u.k === "map" && u.value.k === "any") {
        // `{type: object}` adds nothing
      } else {
        return this.any(`allOf of something other than records`)
      }
    }
    // `required` beside the branches makes their optional fields required.
    for (const r of [...list(s["required"]), ...branches.flatMap((b) => list(asObject(b)?.["required"]))]) {
      if (typeof r !== "string") continue
      const f = fields.get(r)
      if (f?.optional) {
        fields.set(r, { ...f, optional: false })
        inline.add(r)
      }
    }
    const kept = spreads.filter((sp) => sp.keys.every((k) => !inline.has(k)) && spreads.filter((o) => o !== sp).every((o) => o.keys.every((k) => !sp.keys.includes(k))))
    this.count("record (allOf)")
    if (kept.length > 0) this.count("spread")
    return { k: "record", fields, spreads: kept.map((sp) => sp.name) }
  }

  private variant(discriminator: JsonObject, branches: readonly Json[]): HType {
    const member = discriminator["propertyName"]
    if (typeof member !== "string") return this.any("discriminator without propertyName")
    const mapping = asObject(discriminator["mapping"])
    const pairs: [string, Json][] = mapping
      ? Object.entries(mapping).map(([value, r]) => [value, { $ref: r } as JsonObject])
      : branches.flatMap((b) => {
          const r = asObject(b)?.["$ref"]
          return typeof r === "string" ? [[r.split("/").at(-1)!, b] as [string, Json]] : []
        })
    const cases = new Map<string, { value: string; record: RecordType }>()
    for (const [value, schema] of pairs) {
      const u = unref(this.convert(schema))
      if (u.k !== "record") return this.any(`discriminated union with a case that isn't a record`)
      const tag = tagName(value)
      if (cases.has(tag)) return this.any(`discriminated union whose values give the same tag`)
      const fields = new Map([...u.fields].filter(([k]) => k !== member))
      cases.set(tag, { value, record: { k: "record", fields, spreads: [] } })
    }
    this.count("variant (discriminated union)")
    return { k: "variant", member, cases }
  }

  // ── schema text ────────────────────────────────────────────

  /** `.schema.haus` text for the named types the given roots reach. */
  schemaText(roots: readonly string[], enums: EnumStyle): string {
    const done = new Set<string>()
    const order: string[] = []
    const pending = [...roots]
    const time = new Set<string>()
    const print = (t: HType, ind: string): string => {
      switch (t.k) {
        case "ref":
          if (!done.has(t.name)) pending.push(t.name)
          return t.name
        case "string": return "String"
        case "int": return "Int"
        case "float": return "Float64"
        case "bool": return "Bool"
        case "any": return "Any"
        case "time":
          if (!t.valid) return "String"
          time.add(t.tag)
          return t.tag
        case "enum": return enums === "strings" ? "String" : `closed < ${t.tags.join(" | ")} >`
        case "maybe": return `Maybe ${paren(print(t.item, ind))}`
        case "array": return `Array ${paren(print(t.item, ind))}`
        case "map": return `Map ${paren(print(t.value, ind))}`
        case "record": return printRecord(t, ind)
        case "variant": {
          const cases = [...t.cases].map(([tag, c]) => `${ind}  | ${tag} ${printRecord(c.record, ind + "    ")}\n`)
          return `closed <\n${cases.join("")}${ind}>`
        }
      }
    }
    const printRecord = (r: RecordType, ind: string): string => {
      const spread = new Set(r.spreads.flatMap((name) => {
        const u = unref(this.typeOf(name))
        return u.k === "record" ? [...u.fields.keys()] : []
      }))
      for (const name of r.spreads) if (!done.has(name)) pending.push(name)
      const inner = ind + "  "
      const lines = [
        ...r.spreads.map((name) => `${inner}...${name},\n`),
        ...[...r.fields].filter(([k]) => !spread.has(k)).map(([k, f]) => `${inner}${fieldKey(k)}${f.optional ? "?" : ""}: ${print(f.type, inner)},\n`),
      ]
      return lines.length === 0 ? "{}" : `{\n${lines.join("")}${ind}}`
    }
    const definitions: string[] = []
    while (pending.length > 0) {
      const name = pending.shift()!
      if (done.has(name)) continue
      done.add(name)
      order.push(name)
      definitions.push(`type ${name} = ${print(this.typeOf(name), "")}\n`)
    }
    const imports = time.size > 0 ? `import std/time (${[...time].sort().join(", ")})\n\n` : ""
    return `// Generated by bench/openapi.ts from GitHub's REST API description (OpenAPI 3.1).\n// Enums: ${enums === "tags" ? "closed variants of tags" : "strings"}.\n\n${imports}${definitions.join("\n")}`
  }
}

const BARE_KEY = /^[a-z_][A-Za-z0-9_]*$/
const fieldKey = (k: string) => (BARE_KEY.test(k) ? k : JSON.stringify(k))
const atomic = (s: string) => /^\w+$/.test(s) || (s.startsWith("{") && s.endsWith("}")) || (s.startsWith("<") && s.endsWith(">"))
const paren = (s: string) => (atomic(s) ? s : `(${s})`)

export const compile = (text: string): Readonly<Record<string, h.AnySchema>> => compileSchemaFile(text).schemas

// ── JSON ↔ haus ──────────────────────────────────────────────

/** A document that doesn't fit its type. `reason` has no path, to group failures by. */
export class Mismatch extends Error {
  readonly reason: string
  readonly path: string

  constructor(reason: string, path: string) {
    super(`${path}: ${reason}`)
    this.reason = reason
    this.path = path
  }
}
const fail = (reason: string, path: string): never => {
  throw new Mismatch(reason, path)
}

const NONE = variant("None")
const TRUE = variant("True")
const FALSE = variant("False")
const LIMITS = { maxDepth: 512 }

export interface MapOptions {
  readonly enums: EnumStyle
  /** Survey mode: a std/time value that isn't one marks its type invalid (String) instead of failing. */
  readonly survey?: boolean
  /** Counts members kept that the description doesn't list. */
  readonly unlisted?: { count: number }
}

/** GitHub's JSON as the haus value of type `t`. Throws Mismatch when the JSON doesn't fit. */
export const toHaus = (json: Json, t: HType, o: MapOptions, path = "$"): Value => {
  switch (t.k) {
    case "ref":
      return toHaus(json, t.target(), o, path)
    case "any":
      return importJsonValue(json, LIMITS)
    case "maybe":
      return json === null ? NONE : variant("Some", [toHaus(json, t.item, o, path)])
    case "string":
      return typeof json === "string" ? str(json) : fail("expected a string", path)
    case "time":
      if (typeof json !== "string") return fail(`expected a ${t.tag} string`, path)
      if (o.survey && checkStdTime(t.tag, json) !== undefined) t.valid = false
      if (!t.valid) return str(json)
      return checkStdTime(t.tag, json) === undefined ? variant(t.tag, [str(json)]) : fail(`not a valid ${t.tag}`, path)
    case "enum": {
      const i = typeof json === "string" ? t.values.indexOf(json) : -1
      if (i < 0) return fail("a value the enum doesn't list", path)
      return o.enums === "tags" ? variant(t.tags[i]!) : str(json as string)
    }
    case "bool":
      return json === true ? TRUE : json === false ? FALSE : fail("expected a boolean", path)
    case "int":
    case "float":
      if (!(json instanceof JsonNumber)) return fail("expected a number", path)
      if (t.k === "int" && !/^-?\d+$/.test(json.text)) return fail("an integer with a fraction or exponent", path)
      return num(normalizeNumber(json.text) ?? fail("not a number", path))
    case "array":
      return Array.isArray(json) ? arr(json.map((x, i) => toHaus(x, t.item, o, `${path}[${i}]`))) : fail("expected an array", path)
    case "map":
      if (json === null || !isJsonObject(json)) return fail("expected an object", path)
      return rec(new Map(Object.entries(json).map(([k, x]) => [k, toHaus(x, t.value, o, `${path}.${k}`)])))
    case "record":
      if (json === null || !isJsonObject(json)) return fail("expected an object", path)
      return recordToHaus(json, t, o, path)
    case "variant": {
      if (json === null || !isJsonObject(json)) return fail("expected an object", path)
      const value = json[t.member]
      const entry = [...t.cases].find(([, c]) => c.value === value)
      if (!entry) return fail(`a discriminator value the union doesn't list`, path)
      const rest = jsonObject(Object.entries(json).filter(([k]) => k !== t.member))
      return variant(entry[0], [recordToHaus(rest, entry[1].record, o, path)])
    }
  }
}

const recordToHaus = (json: JsonObject, t: RecordType, o: MapOptions, path: string): Value => {
  const fields = new Map<string, Value>()
  for (const [key, member] of Object.entries(json)) {
    const f = t.fields.get(key)
    if (f === undefined && o.unlisted) o.unlisted.count++
    fields.set(key, f === undefined ? importJsonValue(member, LIMITS) : toHaus(member, f.type, o, `${path}.${key}`))
  }
  for (const [key, f] of t.fields) if (!f.optional && !fields.has(key)) fail(`required field \`${key}\` missing`, path)
  return rec(fields)
}

/** The inverse of the import (spec §16.1), for `Any` and unlisted members. */
export const fromImported = (v: Value): Json => {
  switch (v.kind) {
    case "string": return v.value
    case "number": return new JsonNumber(v.text)
    case "array": return v.items.map(fromImported)
    case "record": return jsonObject([...v.fields].map(([k, x]) => [k, fromImported(x)] as const))
    case "variant":
      if (v.args.length === 0 && v.tag === "None") return null
      if (v.args.length === 0 && v.tag === "True") return true
      if (v.args.length === 0 && v.tag === "False") return false
      return fail(`no JSON for the tag ${v.tag}`, "")
    case "bytes": return fail("no JSON for bytes", "")
  }
}

/** The haus value of type `t` as GitHub's JSON. */
export const toJson = (v: Value, t: HType, o: MapOptions, path = "$"): Json => {
  switch (t.k) {
    case "ref":
      return toJson(v, t.target(), o, path)
    case "any":
      return fromImported(v)
    case "maybe":
      if (v.kind === "variant" && v.tag === "None" && v.args.length === 0) return null
      if (v.kind === "variant" && v.tag === "Some" && v.args.length === 1) return toJson(v.args[0]!, t.item, o, path)
      return fail("expected None or Some", path)
    case "string":
      return v.kind === "string" ? v.value : fail("expected a string", path)
    case "time":
      if (!t.valid) return v.kind === "string" ? v.value : fail("expected a string", path)
      return v.kind === "variant" && v.tag === t.tag && v.args[0]?.kind === "string" ? v.args[0].value : fail(`expected ${t.tag}`, path)
    case "enum": {
      if (o.enums === "strings") return v.kind === "string" ? v.value : fail("expected a string", path)
      const i = v.kind === "variant" && v.args.length === 0 ? t.tags.indexOf(v.tag) : -1
      return i >= 0 ? t.values[i]! : fail("expected a tag of the enum", path)
    }
    case "bool":
      return v.kind === "variant" && v.tag === "True" ? true : v.kind === "variant" && v.tag === "False" ? false : fail("expected a Bool", path)
    case "int":
    case "float":
      return v.kind === "number" ? new JsonNumber(v.text) : fail("expected a number", path)
    case "array":
      return v.kind === "array" ? v.items.map((x, i) => toJson(x, t.item, o, `${path}[${i}]`)) : fail("expected an array", path)
    case "map":
      return v.kind === "record" ? jsonObject([...v.fields].map(([k, x]) => [k, toJson(x, t.value, o, `${path}.${k}`)] as const)) : fail("expected a record", path)
    case "record":
      return v.kind === "record" ? recordToJson(v.fields, t, o, path) : fail("expected a record", path)
    case "variant": {
      const c = v.kind === "variant" && v.args.length === 1 && v.args[0]!.kind === "record" ? t.cases.get(v.tag) : undefined
      if (!c || v.kind !== "variant" || v.args[0]!.kind !== "record") return fail("expected a case of the union", path)
      return jsonObject([[t.member, c.value], ...Object.entries(recordToJson(v.args[0]!.fields, c.record, o, path))])
    }
  }
}

const recordToJson = (fields: ReadonlyMap<string, Value>, t: RecordType, o: MapOptions, path: string): JsonObject =>
  jsonObject([...fields].map(([k, x]) => {
    const f = t.fields.get(k)
    return [k, f === undefined ? fromImported(x) : toJson(x, f.type, o, `${path}.${k}`)] as const
  }))

/** Every type a type reaches (each once), for counting positions. */
export const reachable = (roots: readonly HType[]): HType[] => {
  const seen = new Set<HType>()
  const stack = [...roots]
  while (stack.length > 0) {
    const t = stack.pop()!
    if (seen.has(t)) continue
    seen.add(t)
    if (t.k === "ref") stack.push(t.target())
    else if (t.k === "maybe" || t.k === "array") stack.push(t.item)
    else if (t.k === "map") stack.push(t.value)
    else if (t.k === "record") for (const f of t.fields.values()) stack.push(f.type)
    else if (t.k === "variant") for (const c of t.cases.values()) for (const f of c.record.fields.values()) stack.push(f.type)
  }
  return [...seen]
}
