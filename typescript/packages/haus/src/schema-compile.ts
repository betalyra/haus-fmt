/**
 * Schemas from schema files: the types of a `.schema.haus` file as haus
 * schemas (schema.ts), which are also Standard Schemas.
 *
 *   const { text, options } = readSchemaFile(path)   // from @haus-fmt/haus/node
 *   const { schemas } = compileSchemaFile(text, options)
 *   const order = h.parse(schemas.Order, data)
 *
 * and the matching TypeScript declarations (`schemaDeclarations`), for typed
 * imports of schema files. Both follow the same mapping, close to the plain
 * view of data without a schema:
 *
 *   String → string             Int, Int64, UInt64 → bigint                    Int8 … UInt32 → number
 *   Decimal → string ("19.90")  Float32, Float64 → number                     Bool → boolean
 *   Bytes → Uint8Array          Array a → readonly A[]
 *   Maybe a → Maybe<A>: { _tag: "None" } | { _tag: "Some"; value: A }   (tagged, like other variants)
 *   Map v → ReadonlyMap<string, V>                                            std/time types → string (as written)
 *   { a: T, b?: T } → { readonly a: T; readonly b?: T }                       (closed { … } rejects other fields)
 *   < Debug | Info > → "Debug" | "Info"                                       (closed, only tags without payload)
 *   < Circle { r: Float64 } | Empty > → { _tag: "Circle"; r: number } | { _tag: "Empty" }
 *   < Point Float64 Float64 > → { _tag: "Point"; values: readonly [number, number] }
 *   < Odd { _tag: Int32 } > → { _tag: "Odd"; value: { _tag: number } }        (a payload with a field _tag: nested)
 *   open variants → … | Unknown                                               (other tags kept as raw values)
 *   < > → string | Unknown                                                    (any tag: a bare tag as its name)
 *   Any → Value (the parsed value, unchanged)                                 Secret a → Secret<A> (shows <redacted>; expose())
 *
 * Attributes don't change the schemas (spec §15). `@deprecated` becomes a
 * JSDoc `@deprecated` in the declarations.
 *
 * Codecs (spec §13.4) choose another host type for named types, by id:
 *
 *   compileSchemaFile(text, { ...options, codecs: iso })   // iso from @haus-fmt/money
 */
import { groupSchemas } from "./codegen.js"
import { unusedCodecs, type CodecWarning } from "./codec-ids.js"
import * as h from "./schema.js"
import {
  deprecation, HausSchemaFileError, parseSchemaFile, type Attribute, type Builtin, type Case, type Definition, type Field, type Instance, type ParseSchemaOptions, type SchemaFile, type Type,
} from "./schema-file.js"

export interface CompiledSchemaFile {
  readonly file: SchemaFile
  /** Schemas of the file's non-generic types, by name. */
  readonly schemas: Readonly<Record<string, h.Schema<unknown>>>
  /** Types that describe a whole file as a stream of values (`type Events = Stream Event`). */
  readonly streams: ReadonlySet<string>
  /**
   * Warnings about the codecs given (spec §13.4): `unused-codec` for each
   * codec whose id no type has (`@haus-fmt/money@2#Money` when the schema
   * imports major 1), which never runs. The warnings of the schema text
   * itself are `file.warnings`.
   */
  readonly warnings: readonly CodecWarning[]
  /** The schema of any instance of the file's types (an imported package's type too), with its rules and codecs. */
  readonly schemaOf: (inst: Instance) => h.AnySchema
}

/**
 * A codec (spec §13.4): the application's host type for the named type `id`
 * (`@haus-fmt/money@1#Currency`, the same id in every language), built from
 * the schema the type has without it. It runs after that schema, so it can
 * reject more values, never fewer, and it encodes back to that schema's values.
 */
export interface Codec {
  readonly id: string
  readonly apply: (base: h.AnySchema) => h.AnySchema
}

export interface FromSchemaFileOptions {
  /**
   * Codecs, applied wherever their type occurs, inside imported packages too,
   * and to the prelude's and std/time's types (`prelude#Decimal`,
   * `std/time#Instant`). A codec for an id no type has never runs: the
   * warning `unused-codec`; two for one type are an error.
   *
   * An outer codec (for `Money`) is given the host value of a part that has a
   * codec of its own (your `Currency` host type), as built inside out
   * (spec §13.4).
   */
  readonly codecs?: readonly Codec[] | undefined
  /**
   * The package rules to check (packages.md §6), by type id: each a check of
   * the value the type's schema decoded, before its codec, giving why it
   * rejects the value or undefined. A value it rejects is `codec-rejected`
   * when decoding, `cannot-encode` when encoding.
   */
  readonly rules?: ReadonlyMap<string, (value: unknown) => string | undefined> | undefined
}

export interface CompileOptions extends ParseSchemaOptions, FromSchemaFileOptions {}

/** Parse a schema file and build haus schemas for its types. Throws HausSchemaFileError. */
export const compileSchemaFile = (text: string, options: CompileOptions = {}): CompiledSchemaFile =>
  fromSchemaFile(parseSchemaFile(text, options), options)

/** The codecs by id; two for one type are an error. */
const codecsById = (codecs: readonly Codec[]): ReadonlyMap<string, Codec> => {
  const byId = new Map<string, Codec>()
  for (const c of codecs) {
    if (byId.has(c.id)) throw new Error(`two codecs for ${c.id}`)
    byId.set(c.id, c)
  }
  return byId
}

const isEnum = (cases: readonly Case[]) => cases.length > 0 && cases.every((c) => c.payload.kind === "none")

const builtin = (name: Builtin): h.AnySchema => {
  switch (name) {
    case "String": return h.String
    case "Bytes": return h.Bytes
    case "Bool": return h.Bool
    case "Decimal": return h.Decimal
    case "Int": return h.Int
    case "Int8": return h.Int8
    case "Int16": return h.Int16
    case "Int32": return h.Int32
    case "Int64": return h.Int64
    case "UInt8": return h.UInt8
    case "UInt16": return h.UInt16
    case "UInt32": return h.UInt32
    case "UInt64": return h.UInt64
    case "Float32": return h.Float32
    case "Float64": return h.Float64
    case "Any": return h.Any
  }
}

/** Build haus schemas for an already checked schema file. */
export const fromSchemaFile = (file: SchemaFile, options: FromSchemaFileOptions = {}): CompiledSchemaFile => {
  const byId = codecsById(options.codecs ?? [])
  const rules = options.rules ?? new Map<string, (value: unknown) => string | undefined>()
  const built = new Map<Instance, h.AnySchema>()
  const building = new Set<Instance>()
  /** The schema with the codec for `id` applied, if one is set. */
  const withCodec = (id: string, schema: h.AnySchema): h.AnySchema => byId.get(id)?.apply(schema) ?? schema

  const ref = (inst: Instance): h.AnySchema => {
    const done = built.get(inst)
    if (done) return done
    // A back edge of a recursive type (the checker made sure it is guarded),
    // limited only by the call's nesting depth (spec §9.9).
    if (building.has(inst)) return h.Recursive(inst.key, () => built.get(inst)!)
    building.add(inst)
    // Rules and codecs target named types without arguments, by id: the rule on the value the schema decoded, then the codec.
    const body = build(inst.body)
    const rule = inst.args.length === 0 ? rules.get(inst.definition.id) : undefined
    const checked = rule === undefined ? body : h.refine(body, rule)
    const schema = inst.args.length === 0 ? withCodec(inst.definition.id, checked) : checked
    building.delete(inst)
    built.set(inst, schema)
    return schema
  }

  /**
   * A record case by name (`Box BoxRec`, spec §15) puts the record's fields
   * beside `_tag`, where a codec's host type for the record can't go: a codec
   * for the record, or an alias of it, is `codec-unreachable` (§13.4).
   */
  const codecFreeRecord = (tag: string, named: Type): void => {
    for (let t = named; t.kind === "ref"; t = t.instance.body) {
      const { id } = t.instance.definition
      if (t.instance.args.length === 0 && byId.has(id)) {
        throw new HausSchemaFileError(`the codec for ${id} can't apply in the record case ${tag}: a record case's fields sit beside "_tag" in the host value (spec §15)`, 0, 1, 1, "codec-unreachable")
      }
    }
  }

  const fields = (fs: readonly Field[]): h.Fields =>
    Object.fromEntries(fs.map((f) => [f.key, f.optional ? h.Optional(build(f.type)) : build(f.type)]))

  // One schema per type object: arguments are shared, not copied, so a type written once can be
  // reached along exponentially many paths (`P a a` inside `P a a` …) and is built once.
  const builtTypes = new WeakMap<Type, h.AnySchema>()
  const build = (t: Type): h.AnySchema => {
    if (t.kind === "ref") return ref(t.instance)
    const known = builtTypes.get(t)
    if (known) return known
    const schema = buildNew(t)
    builtTypes.set(t, schema)
    return schema
  }
  const buildNew = (t: Exclude<Type, { kind: "ref" }>): h.AnySchema => {
    switch (t.kind) {
      // The prelude's and std/time's types take codecs too (spec §13.4): a codec for `prelude#Decimal` applies to every Decimal.
      case "builtin":
        return withCodec(`prelude#${t.name}`, builtin(t.name))
      case "std":
        return withCodec(`std/time#${t.name}`, t.name === "Date" ? h.Date : h.StdTime(t.name))
      case "array":
        return h.Array(build(t.item))
      case "map":
        return h.Map(build(t.value))
      case "maybe":
        return h.Maybe(build(t.item))
      case "secret":
        return h.Secret(build(t.item))
      case "record":
        return h.Record(fields(t.fields), { closed: t.closed })
      case "variant": {
        if (isEnum(t.cases) && !t.open) return h.Enum(...t.cases.map((c) => c.tag))
        // `< >` accepts any tag; a closed variant with no tags (`closed < ...E >`, E empty) accepts none.
        if (t.cases.length === 0) return t.open ? h.AnyTag : h.Enum<string[]>()
        const cases = Object.fromEntries(t.cases.map((c) => {
          switch (c.payload.kind) {
            case "none":
              return [c.tag, h.Unit]
            case "record":
              // A record case by name is the named record's schema (a Recursive
              // record while it is being built), so a record that reaches its own
              // case by name (`type C = { s: < S B > }`, `type B = C`) ends.
              if (c.payload.named) {
                codecFreeRecord(c.tag, c.payload.named)
                return [c.tag, build(c.payload.named)]
              }
              return [c.tag, h.Record(fields(c.payload.record.fields), { closed: c.payload.record.closed })]
            case "positional":
              return [c.tag, h.Tuple(...c.payload.items.map(build))]
          }
        }))
        return (t.open ? h.OpenVariant(cases) : h.Variant(cases))
      }
      case "param":
        throw new Error(`type parameter ${t.name} in a concrete type`)
    }
  }

  const schemas: Record<string, h.Schema<unknown>> = {}
  const streams = new Set<string>()
  for (const d of file.definitions) {
    if (d.params.length > 0) continue // generic types have no schema of their own
    Object.defineProperty(schemas, d.name, { value: ref(d.template), enumerable: true })
    if (d.template.stream) streams.add(d.name)
  }
  // Generated together when one of them is first used (codegen.ts).
  groupSchemas(schemas)
  return { file, schemas, streams, warnings: unusedCodecs(file, byId.keys()), schemaOf: ref }
}

// ── TypeScript declarations ──────────────────────────────────

const KEY = /^[A-Za-z_$][A-Za-z0-9_$]*$/
const prop = (k: string) => (KEY.test(k) ? k : JSON.stringify(k))
const escapeDoc = (text: string) => text.replaceAll("*/", "*\\/")
const comment = (body: string) => `/**\n * ${escapeDoc(body).split("\n").join("\n * ")}\n */\n`

/** The JSDoc tag for `@deprecated` attributes, or "". */
const deprecatedTag = (attributes: readonly Attribute[] | undefined): string => {
  const message = deprecation(attributes)
  return message === undefined ? "" : `@deprecated${message ? ` ${message}` : ""}`
}

/** An inline JSDoc `/** @deprecated … *\/ ` for a deprecated field or case, or "". */
export const deprecatedDoc = (attributes: readonly Attribute[] | undefined): string => {
  const tag = deprecatedTag(attributes)
  return tag ? `/** ${escapeDoc(tag)} */ ` : ""
}

/** JSDoc for a definition: its comment and its haus source, and `@deprecated` when it is. */
export const definitionDoc = (d: Definition, extra = ""): string => {
  const tag = deprecatedTag(d.attributes)
  return comment(`${extra}${"```haus-schema\n"}${d.source}\n${"```"}${tag ? `\n${tag}` : ""}`)
}

/** The definitions a type refers to. */
const referenced = (t: Type, onRef: (d: Definition) => void): void => {
  switch (t.kind) {
    case "array":
    case "maybe":
    case "secret":
      return referenced(t.item, onRef)
    case "map":
      return referenced(t.value, onRef)
    case "record":
      return t.fields.forEach((f) => referenced(f.type, onRef))
    case "variant":
      return t.cases.forEach((c) =>
        c.payload.kind === "record" ? referenced(c.payload.record, onRef)
        : c.payload.kind === "positional" ? c.payload.items.forEach((x) => referenced(x, onRef))
        : undefined)
    case "ref":
      t.instance.args.forEach((a) => referenced(a, onRef))
      return onRef(t.instance.definition)
    default:
      return
  }
}

export interface DeclarationOptions {
  /** Module specifier to import this package's types from (default "@haus-fmt/haus"). */
  readonly haus?: string
}

/**
 * A TypeScript module declaring the file's types and their handles:
 *
 *   export type Order<H$ = {}> = { readonly placed: h$.Host<H$, "std/time#Instant", string>; … }
 *   export interface Order$ extends h$.TypeLambda { readonly type: h$.Host<this["hosts"], "app/order#Order", Order<this["hosts"]>> }
 *   export declare const Order: h$.Type<Order$, "app/order#Order">
 *
 * Each type takes the codecs' host types `H$` (by type id), so that
 * `Schema.decode(schema, Order)` with a codec for `std/time#Instant` gives
 * its host type wherever an `Instant` is. Imported types are declared too
 * (not exported), so the module needs no other schema module. Generic types
 * are generic type aliases, `H$` first. A stream type has a `StreamType`.
 */
export const schemaDeclarations = (file: SchemaFile, options: DeclarationOptions = {}): string => {
  const defs: Definition[] = []
  const seen = new Set<Definition>()
  const visit = (d: Definition) => {
    if (seen.has(d)) return
    seen.add(d)
    defs.push(d)
    referenced(d.template.body, visit)
  }
  file.definitions.forEach(visit)

  // The file's own and imported types keep their names; other files' types get a suffix if needed.
  const names = new Map<Definition, string>()
  const taken = new Set<string>()
  for (const d of file.definitions) names.set(d, d.name), taken.add(d.name)
  for (const [name, d] of file.imported) names.set(d, name), taken.add(name)
  for (const d of defs) {
    if (names.has(d)) continue
    let n = d.name
    for (let i = 1; taken.has(n); i++) n = `${d.name}$${i}`
    names.set(d, n)
    taken.add(n)
  }
  const paramName = (p: string) => {
    const n = p[0]!.toUpperCase() + p.slice(1)
    return taken.has(n) ? `${n}_` : n
  }

  /** `type` as the host type of a codec for `id` would replace it. */
  const host = (id: string, type: string) => `h$.Host<H$, ${JSON.stringify(id)}, ${type}>`
  const builtinType = (name: Builtin): string => {
    switch (name) {
      case "String": case "Decimal": return "string"
      case "Bytes": return "Uint8Array"
      case "Bool": return "boolean"
      case "Int": case "Int64": case "UInt64": return "bigint"
      case "Any": return "h$.Value"
      default: return "number"
    }
  }
  const print = (t: Type): string => {
    switch (t.kind) {
      case "builtin":
        return host(`prelude#${t.name}`, builtinType(t.name))
      case "std":
        return host(`std/time#${t.name}`, "string")
      case "array":
        return `ReadonlyArray<${print(t.item)}>`
      case "map":
        return `ReadonlyMap<string, ${print(t.value)}>`
      case "maybe":
        return `h$.Maybe<${print(t.item)}>`
      case "secret":
        return `h$.Secret<${print(t.item)}>`
      case "record":
        return record(t.fields)
      case "variant": {
        if (isEnum(t.cases) && !t.open) return t.cases.map((c) => deprecatedDoc(c.attributes) + JSON.stringify(c.tag)).join(" | ")
        if (t.cases.length === 0) return t.open ? "string | h$.Unknown" : "never"
        const cases = t.cases.map((c) => {
          const tag = `${deprecatedDoc(c.attributes)}readonly _tag: ${JSON.stringify(c.tag)}`
          switch (c.payload.kind) {
            case "none": return `{ ${tag} }`
            // A payload with a field `_tag` is nested (h.Variant): its fields can't go beside the tag.
            case "record": return c.payload.record.fields.some((f) => f.key === "_tag") ? `{ ${tag}; readonly value: ${record(c.payload.record.fields)} }`
              : `{ ${[tag, ...fieldList(c.payload.record.fields)].join("; ")} }`
            case "positional": return `{ ${tag}; readonly values: readonly [${c.payload.items.map(print).join(", ")}] }`
          }
        })
        return [...cases, ...(t.open ? ["h$.Unknown"] : [])].join(" | ") || "never"
      }
      case "ref": {
        const d = t.instance.definition
        const name = names.get(d) ?? d.name
        // A codec applies to a named type without arguments (spec §13.4), not to a stream.
        if (t.instance.args.length > 0) return `${name}<H$, ${t.instance.args.map(print).join(", ")}>`
        return d.template.stream ? `${name}<H$>` : host(d.id, `${name}<H$>`)
      }
      case "param":
        return paramName(t.name)
    }
  }
  const fieldList = (fs: readonly Field[]) => fs.map((f) => `${deprecatedDoc(f.attributes)}readonly ${prop(f.key)}${f.optional ? "?" : ""}: ${print(f.type)}`)
  const record = (fs: readonly Field[]) => (fs.length === 0 ? "{}" : `{ ${fieldList(fs).join("; ")} }`)

  const own = new Set(file.definitions)
  const out: string[] = [`import type * as h$ from ${JSON.stringify(options.haus ?? "@haus-fmt/haus")};\n`]
  for (const d of defs) {
    const name = names.get(d)!
    const exported = own.has(d) ? "export " : ""
    const stream = d.template.stream ? "A stream: a file of values of this type.\n\n" : ""
    const from = own.has(d) ? "" : `From ${d.module ?? "another file"} (${d.id}).\n\n`
    const params = d.params.length ? `<H$, ${d.params.map(paramName).join(", ")}>` : "<H$ = {}>"
    out.push(`${definitionDoc(d, from + stream)}${exported}type ${name}${params} = ${print(d.template.body)};\n`)
    if (own.has(d) && d.params.length === 0) {
      const id = JSON.stringify(d.id)
      const lambda = d.template.stream ? `${name}<this["hosts"]>` : `h$.Host<this["hosts"], ${id}, ${name}<this["hosts"]>>`
      out.push(`/** The type function of ${d.name}: its type with the codecs' host types. */\nexport interface ${name}$ extends h$.TypeLambda { readonly type: ${lambda} }\n`)
      out.push(`${definitionDoc(d, `The handle of ${d.name}${d.template.stream ? ", a stream" : ""}.\n\n`)}export declare const ${name}: h$.${d.template.stream ? "StreamType" : "Type"}<${name}$, ${id}>;\n`)
    }
  }
  return out.join("")
}
