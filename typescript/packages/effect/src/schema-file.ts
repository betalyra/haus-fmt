/**
 * Effect schemas from haus schema files (`.schema.haus`).
 *
 *   const { text, options } = readSchemaFile(path)   // from @haus-fmt/haus/node
 *   const { schemas } = Haus.compileSchemaFile(text, options)
 *   const order = yield* Haus.decode(schemas.Order)(data)
 *
 * and the matching TypeScript declarations, for typed imports of schema files
 * (`schemaDeclarations`). Both follow the same mapping:
 *
 *   String → string            Int, Int64, UInt64 → bigint     other Int*, Float* → number
 *   Decimal → string ("19.90") Bool → boolean                   Bytes → Uint8Array
 *   Maybe a → Option<A>        Array a → readonly A[]           Map v → { [key: string]: V }
 *   { a: T, b?: T }            → { readonly a: T; readonly b?: T }   (closed { … } rejects other fields)
 *   < Debug | Info >           → "Debug" | "Info"                     (only tags without payload)
 *   < Circle { r: Float64 } | Empty > → { _tag: "Circle"; r: number } | { _tag: "Empty" }
 *   < Point Float64 Float64 > → { _tag: "Point"; values: readonly [number, number] }
 *   < Odd { _tag: Int32 } >   → { _tag: "Odd"; value: { _tag: number } } (a payload with a field _tag: nested)
 *   open variants              → … | Unknown                          (other tags kept as raw values)
 *   < >                        → string | Unknown                     (any tag: bare tags as their name)
 *   std/time types → string, the text as written
 *   Any → Haus.Value (Haus.Any: the parsed value, unchanged)
 *   Secret a → Redacted<A> (Schema.Redacted: shows <redacted>; errors never show the value)
 *
 * Attributes don't change the schemas (spec §15); `@deprecated` becomes a
 * JSDoc `@deprecated` in the declarations.
 *
 * Every default keeps the value (spec §13.4). Codecs (codec.ts) replace named
 * types: `fromSchemaFile(file, { codecs })` builds the schemas with their
 * types, and the declarations make every type a function of the codecs'
 * types (`Root<C>`, through `Lookup`). The lossy host types of Effect are
 * codecs too: `Haus.decimalAsBigDecimal` (`prelude#Decimal`),
 * `Haus.instantAsDateTime` and `Haus.zonedDateTimeAsDateTime`.
 */
import {
  definitionDoc, deprecatedDoc, describeType, parseSchemaFile, type Builtin, type Case, type Definition, type Field, type Instance, type ParseSchemaOptions,
  type SchemaFile, type StdType, type Type,
} from "@haus-fmt/haus/internal"
import { Schema } from "effect"
import { entries, idOf, setId, type AnyCodec, type CodecEntry, type Named } from "./codec.js"
import { BARE_TAG, CLOSED, NESTED, NUMBER, SECRET, STRICT, VALUES } from "./convert.js"
import { CODE, schemaErrorOf } from "./errors.js"

/** Annotation on a package rule's check: the type id whose rule it is. */
export const RULE = "hausRule"
// Circular import: only used when a schema file is compiled, after both modules have loaded.
import * as Haus from "./index.js"

export interface CompiledSchemaFile {
  readonly file: SchemaFile
  /** Effect schemas of the file's non-generic types, by name. */
  readonly schemas: Readonly<Record<string, Schema.Codec<unknown>>>
  /** Types that describe a whole file as a stream of values (`type Events = Stream Event`). */
  readonly streams: ReadonlySet<string>
}

/** A package's rule as the core compiled it (packages.md §6): why it rejects a value, or undefined. */
export type RuleCheck = (value: unknown) => string | undefined

export interface FromSchemaFileOptions {
  /** Codecs whose types replace the named types they target. */
  readonly codecs?: ReadonlyArray<AnyCodec>
  /** The package rules to check, by type id: on the value the type's schema decodes, before its codec. */
  readonly rules?: ReadonlyMap<string, RuleCheck>
}

/**
 * @internal Parse a schema file and build Effect schemas for its types,
 * without packages' rules: for tests and tools. Programs compile `Sources`
 * (`Haus.compile`), which checks the rules. Throws HausSchemaFileError.
 */
export const compileSchemaFile = (text: string, options: ParseSchemaOptions = {}): CompiledSchemaFile =>
  fromSchemaFile(parseSchemaFile(text, options))

const stdId = (name: StdType) => `std/time#${name}`

const isEnum = (cases: readonly Case[]) => cases.length > 0 && cases.every((c) => c.payload.kind === "none")

/**
 * Whether a case's record payload has a field named `_tag`, which can't go
 * beside the tag: its fields are then nested, `{ _tag: "Odd", value: { _tag: 1 } }`.
 */
const nestsPayload = (fs: readonly Field[]) => fs.some((f) => f.key === "_tag")

const INTS: Partial<Record<Builtin, readonly [number, number]>> = {
  Int8: [-128, 127],
  Int16: [-32768, 32767],
  Int32: [-2147483648, 2147483647],
  UInt8: [0, 255],
  UInt16: [0, 65535],
  UInt32: [0, 4294967295],
}

/**
 * A whole number in range, as a JS number: `1e2` and `1.0` are not whole
 * numbers (spec §15). The converter only gives whole numbers, so one that
 * isn't a safe integer is out of range.
 */
const smallInt = ([minimum, maximum]: readonly [number, number]) =>
  Schema.Number.annotate({ [NUMBER]: "Int" }).check(Schema.isInt({ [CODE]: "out-of-range" }), Schema.isBetween({ minimum, maximum }))

/** A schema file's `String`: only a haus string. */
const strictString = Schema.String.annotate({ [STRICT]: true })

const builtin = (name: Builtin): Schema.Top => {
  const range = INTS[name]
  if (range) return smallInt(range)
  switch (name) {
    case "String":
      return strictString
    case "Bytes":
      return Schema.Uint8Array
    case "Bool":
      return Schema.Boolean
    case "Decimal":
      return Haus.Decimal
    case "Int":
      return Schema.BigInt
    case "Int64":
      return Schema.BigInt.check(Schema.isBetweenBigInt({ minimum: -(2n ** 63n), maximum: 2n ** 63n - 1n }))
    case "UInt64":
      return Schema.BigInt.check(Schema.isBetweenBigInt({ minimum: 0n, maximum: 2n ** 64n - 1n }))
    case "Float32":
      return Haus.Float32
    case "Any":
      return Haus.Any
    default:
      // @effect-diagnostics-next-line schemaNumber:off -- Float64 includes NaN and the infinities (spec §15)
      return Schema.Number
  }
}

/** The id codecs use for a type of the prelude: `prelude#Int`. */
const preludeId = <N extends Builtin>(name: N): `prelude#${N}` => `prelude#${name}`

const preludeSchemas = new Map<Builtin, Schema.Top>()

/**
 * The schema of a type of the prelude, as schema files decode it: the target
 * of a codec for it (spec §13.4), which then applies to every one of its
 * values, in the types of packages too.
 *
 *   const Ints = Haus.codec(Haus.prelude("Int"), (base) => base.pipe(Schema.check(...)))
 *
 * `Decimal` is `Haus.Decimal`.
 */
export const prelude = <N extends Builtin>(name: N): Named<Schema.Top, `prelude#${N}`> => {
  let s = preludeSchemas.get(name)
  if (s === undefined) {
    // A schema of its own (annotate makes a new one), so that its id is not on a schema shared with other uses.
    s = name === "Decimal" ? Haus.Decimal : setId(builtin(name).annotate({}), preludeId(name))
    preludeSchemas.set(name, s)
  }
  return s as Named<Schema.Top, `prelude#${N}`>
}

/** `< >`, any tag: a bare tag decodes to its name, other tags to Unknown. */
const AnyTag = Schema.String.annotate({ [BARE_TAG]: true })

/** Where a schema came from: so that `withCodecs` can build it again with codecs (and the same rules). */
const sources = new WeakMap<object, { readonly file: SchemaFile; readonly name: string; readonly rules: ReadonlyMap<string, RuleCheck> | undefined }>()
const rebuilt = new WeakMap<SchemaFile, Map<string, CompiledSchemaFile>>()
const entryIds = new WeakMap<CodecEntry, number>()
let nextEntry = 0

/**
 * `schema` with codecs: built again from its schema file, with the codecs'
 * types for the named types they target (cached). A named type's own schema
 * (`Haus.Date`, a type of a schema file) takes its codec directly.
 */
export const withCodecs = (schema: Schema.Top, codecs: ReadonlyArray<AnyCodec>): Schema.Top => {
  const byId = entries(codecs)
  const source = sources.get(schema)
  if (!source) {
    const own = byId.get(idOf(schema) ?? "")
    if (own) return own.apply(schema)
    throw new Error("Haus: codecs apply to schemas of .schema.haus files (and Haus.Date & co.); this schema has no schema file")
  }
  const key = [...byId.values()].map((e) => {
    let n = entryIds.get(e)
    if (n === undefined) entryIds.set(e, (n = nextEntry++))
    return n
  }).sort().join(",")
  let cache = rebuilt.get(source.file)
  if (!cache) rebuilt.set(source.file, (cache = new Map()))
  let compiled = cache.get(key)
  if (!compiled) {
    if (cache.size > 64) cache.clear()
    compiled = fromSchemaFile(source.file, source.rules === undefined ? { codecs } : { codecs, rules: source.rules })
    cache.set(key, compiled)
  }
  return compiled.schemas[source.name]!
}

/** Build Effect schemas for an already checked schema file. */
export const fromSchemaFile = (file: SchemaFile, options: FromSchemaFileOptions = {}): CompiledSchemaFile => {
  const byId = options.codecs ? entries(options.codecs) : new Map<string, CodecEntry>()
  const built = new Map<Instance, Schema.Top>()
  const building = new Set<Instance>()

  /** A named type with its codec, if there is one. */
  const named = (id: string, base: Schema.Top): Schema.Top => {
    const c = byId.get(id)
    return c ? c.apply(base) : base
  }

  /**
   * A named type with its package's rule, if it has one: a check of the
   * value its schema decoded (and of the value encoded), failing with
   * `codec-rejected` and the rule's reason (packages.md §6, spec §17).
   */
  const checked = (id: string, base: Schema.Top): Schema.Top => {
    const rule = options.rules?.get(id)
    return rule === undefined ? base : base.check(Schema.makeFilter((value: unknown) => rule(value) ?? true, { [CODE]: "codec-rejected", [RULE]: id }))
  }

  const std = (name: StdType): Schema.Top => named(stdId(name), Haus[name])

  const ref = (inst: Instance): Schema.Top => {
    const done = built.get(inst)
    if (done) return done
    // A back edge of a recursive type.
    if (building.has(inst)) return Schema.suspend(() => built.get(inst)!)
    building.add(inst)
    let schema = build(inst.body).annotate({ identifier: inst.key })
    // Codecs and rules target named types without arguments, by id: the rule first, on what the type's schema decoded (packages.md §6).
    if (inst.args.length === 0) schema = named(inst.definition.id, setId(checked(inst.definition.id, schema), inst.definition.id))
    building.delete(inst)
    built.set(inst, schema)
    return schema
  }

  /**
   * A record case by name (`Box BoxRec`, spec §15) puts the record's fields
   * beside `_tag`, where a codec's host type for the record can't go: a codec
   * that targets the record, or an alias of it, is an error there (§13.4):
   * a HausSchemaError with the code `codec-unreachable`, thrown when the codecs are given.
   */
  const codecFreeRecord = (tag: string, t: Type): void => {
    for (; t.kind === "ref"; t = t.instance.body) {
      const { id } = t.instance.definition
      if (t.instance.args.length === 0 && byId.has(id)) {
        throw schemaErrorOf(`the codec for ${id} can't apply in the record case ${tag}: a record case's fields sit beside "_tag" in the host value (spec §15)`, "codec-unreachable")
      }
    }
  }

  const fields = (fs: readonly Field[], field: (f: Field) => Schema.Top = (f) => build(f.type)): Schema.Struct.Fields =>
    Object.fromEntries(fs.map((f) => [f.key, f.optional ? Schema.optionalKey(field(f)) : field(f)]))

  /**
   * The fields of a record case by name, built once per record. A record
   * that reaches its own case by name (`type C = { s: < S B > }`, `type B =
   * C`) gets the fields of the case inside it as suspended schemas.
   */
  const caseFields = new Map<Type, ReadonlyMap<string, Schema.Top>>()
  const buildingCase = new Set<Type>()
  const namedCaseFields = (record: Extract<Type, { kind: "record" }>): Schema.Struct.Fields => {
    if (buildingCase.has(record)) return fields(record.fields, (f) => Schema.suspend(() => caseFields.get(record)!.get(f.key)!))
    if (!caseFields.has(record)) {
      buildingCase.add(record)
      caseFields.set(record, new Map(record.fields.map((f) => [f.key, build(f.type)])))
      buildingCase.delete(record)
    }
    const done = caseFields.get(record)!
    return fields(record.fields, (f) => done.get(f.key)!)
  }

  const build = (t: Type): Schema.Top => {
    switch (t.kind) {
      case "builtin":
        // Every type of the prelude is a named type that codecs can replace (Haus.decimalAsBigDecimal, spec §13.4).
        return named(preludeId(t.name), builtin(t.name))
      case "std":
        return std(t.name)
      case "array":
        return Schema.Array(build(t.item))
      case "map":
        return Schema.Record(Schema.String, build(t.value))
      case "maybe":
        return Schema.Option(build(t.item))
      case "secret":
        // The haus type, for errors that name it without showing the value.
        return Schema.Redacted(build(t.item)).annotate({ [SECRET]: describeType(t.item) })
      case "record": {
        const s = Schema.Struct(fields(t.fields))
        return t.closed ? s.annotate({ [CLOSED]: true }) : s
      }
      case "variant": {
        if (isEnum(t.cases)) {
          const literals = Schema.Literals(t.cases.map((c) => c.tag))
          return t.open ? Haus.OpenUnion([literals]) : literals
        }
        const members = t.cases.map((c): Schema.Top => {
          switch (c.payload.kind) {
            case "none":
              return Schema.TaggedStruct(c.tag, {})
            case "record": {
              const { record, named: as } = c.payload
              if (as) codecFreeRecord(c.tag, as)
              const closed = (s: Schema.Top) => (record.closed ? s.annotate({ [CLOSED]: true }) : s)
              const fs = as ? namedCaseFields(record) : fields(record.fields)
              // A payload with a field `_tag` can't put its fields beside the tag: they go in `value`.
              if (nestsPayload(record.fields)) return Schema.TaggedStruct(c.tag, { value: closed(Schema.Struct(fs)) }).annotate({ [NESTED]: true })
              return closed(Schema.TaggedStruct(c.tag, fs))
            }
            case "positional":
              return Schema.TaggedStruct(c.tag, { values: Schema.Tuple(c.payload.items.map(build)) }).annotate({ [VALUES]: true })
          }
        })
        if (t.open) return Haus.OpenUnion(members.length === 0 ? [AnyTag] : members)
        return members.length === 1 ? members[0]! : Schema.Union(members)
      }
      case "ref":
        return ref(t.instance)
      case "param":
        throw new Error(`type parameter ${t.name} in a concrete type`)
    }
  }

  const schemas: Record<string, Schema.Codec<unknown>> = {}
  const streams = new Set<string>()
  for (const d of file.definitions) {
    if (d.params.length > 0) continue // generic types have no schema of their own
    const schema = ref(d.template)
    if (!options.codecs) sources.set(schema, { file, name: d.name, rules: options.rules })
    Object.defineProperty(schemas, d.name, { value: schema as Schema.Codec<unknown>, enumerable: true })
    if (d.template.stream) streams.add(d.name)
  }
  return { file, schemas, streams }
}

// ── TypeScript declarations ──────────────────────────────────

export interface DeclarationOptions {
  /** Module specifier to import Effect's types from (default "effect"). */
  readonly effect?: string
  /** Module specifier to import this package's types from (default "@haus-fmt/effect"). */
  readonly haus?: string
}

const KEY = /^[A-Za-z_$][A-Za-z0-9_$]*$/
const prop = (k: string) => (KEY.test(k) ? k : JSON.stringify(k))

/** JSDoc for a definition: its comment and its haus source, and `@deprecated` when it is (the core's). */
export { definitionDoc }

/** The TypeScript type of a prelude type's values, without a codec. */
const builtinType = (name: Builtin): string => {
  switch (name) {
    case "String":
    case "Decimal":
      return "string"
    case "Bytes":
      return "globalThis.Uint8Array"
    case "Bool":
      return "boolean"
    case "Int":
    case "Int64":
    case "UInt64":
      return "bigint"
    case "Any":
      return "Haus$.Value"
    default:
      return "number"
  }
}

/** The codec map parameter of every declared type. `$` can't appear in haus names, so it never clashes. */
const C = "C$"

/** Named types inside `t`; `onRef` says whether to look inside a reference's body too. `onId` gets the ids of built-in named types. */
const visitTypes = (t: Type, onRef: (inst: Instance) => boolean, onId: (id: string) => void): void => {
  switch (t.kind) {
    case "builtin":
      return onId(preludeId(t.name))
    case "std":
      return onId(stdId(t.name))
    case "array":
    case "maybe":
    case "secret":
      return visitTypes(t.item, onRef, onId)
    case "map":
      return visitTypes(t.value, onRef, onId)
    case "record":
      return t.fields.forEach((f) => visitTypes(f.type, onRef, onId))
    case "variant":
      return t.cases.forEach((c) =>
        c.payload.kind === "record" ? visitTypes(c.payload.record, onRef, onId)
        : c.payload.kind === "positional" ? c.payload.items.forEach((x) => visitTypes(x, onRef, onId))
        : undefined)
    case "ref":
      t.instance.args.forEach((a) => visitTypes(a, onRef, onId))
      if (onRef(t.instance)) visitTypes(t.instance.body, onRef, onId)
      return
    default:
      return
  }
}

/**
 * A TypeScript module declaring the file's types (`export type Order<C$ = {}> = …`)
 * and their Effect schemas (`export declare const Order: Haus.Named<…>`).
 *
 * Every type takes the map of codec types `C$` (id → type, see
 * `Haus.Lookup`); without codecs it is `{}`: the types of the schema.
 * Imported types are declared here too (not exported), so the module needs
 * no other schema module. Generic types are declared as generic type
 * aliases.
 */
export const schemaDeclarations = (file: SchemaFile, options: DeclarationOptions = {}): string => {
  const used = new Set<string>()

  // Every definition the file's types refer to, its own first.
  const defs: Definition[] = []
  const seen = new Set<Definition>()
  const visitDef = (d: Definition) => {
    if (seen.has(d)) return
    seen.add(d)
    defs.push(d)
    visitTypes(d.template.body, (inst) => (visitDef(inst.definition), false), () => undefined)
  }
  file.definitions.forEach(visitDef)

  // Names: the file's own and imported types keep theirs; other files' types get a suffix if needed.
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

  const unknownType = "Haus$.Unknown"

  const print = (t: Type): string => {
    switch (t.kind) {
      case "builtin":
        // Every type of the prelude can have a codec (spec §13.4).
        return `Haus$.Lookup<${C}, ${JSON.stringify(preludeId(t.name))}, ${builtinType(t.name)}>`
      case "std":
        return `Haus$.Lookup<${C}, ${JSON.stringify(stdId(t.name))}, string>`
      case "array":
        return `ReadonlyArray<${print(t.item)}>`
      case "map":
        return `{ readonly [key: string]: ${print(t.value)} }`
      case "maybe":
        return used.add("Option"), `Option$.Option<${print(t.item)}>`
      case "secret":
        return used.add("Redacted"), `Redacted$.Redacted<${print(t.item)}>`
      case "record":
        return record(t.fields)
      case "variant": {
        if (t.cases.length === 0 && t.open) return `string | ${unknownType}`
        const cases = isEnum(t.cases)
          ? t.cases.map((c) => deprecatedDoc(c.attributes) + JSON.stringify(c.tag))
          : t.cases.map((c) => {
            const tag = `${deprecatedDoc(c.attributes)}readonly _tag: ${JSON.stringify(c.tag)}`
            switch (c.payload.kind) {
              case "none":
                return `{ ${tag} }`
              case "record":
                return nestsPayload(c.payload.record.fields) ? `{ ${tag}; readonly value: ${record(c.payload.record.fields)} }`
                  : `{ ${[tag, ...fieldList(c.payload.record.fields)].join("; ")} }`
              case "positional":
                return `{ ${tag}; readonly values: readonly [${c.payload.items.map(print).join(", ")}] }`
            }
          })
        return [...cases, ...(t.open ? [unknownType] : [])].join(" | ") || "never"
      }
      case "ref": {
        const d = t.instance.definition
        const name = names.get(d) ?? d.name
        return `${name}<${[...t.instance.args.map(print), C].join(", ")}>`
      }
      case "param":
        return paramName(t.name)
    }
  }
  const fieldList = (fs: readonly Field[]) => fs.map((f) => `${deprecatedDoc(f.attributes)}readonly ${prop(f.key)}${f.optional ? "?" : ""}: ${print(f.type)}`)
  const record = (fs: readonly Field[]) => (fs.length === 0 ? "{}" : `{ ${fieldList(fs).join("; ")} }`)

  /** Ids of the named types a type contains (codecs may replace them), its own included. */
  const idsOf = (d: Definition): string[] => {
    const ids = new Set<string>([d.id])
    const visited = new Set<Instance>()
    visitTypes(d.template.body, (inst) => {
      if (visited.has(inst)) return false
      visited.add(inst)
      if (inst.args.length === 0) ids.add(inst.definition.id)
      return true
    }, (id) => ids.add(id))
    return [...ids]
  }

  const own = new Set(file.definitions)
  const out: string[] = []
  for (const d of defs) {
    const name = names.get(d)!
    const exported = own.has(d) ? "export " : ""
    const stream = d.template.stream ? "A stream: a file of values of this type.\n\n" : ""
    const from = own.has(d) ? "" : `From ${d.module ?? "another file"} (${d.id}).\n\n`
    const params = [...d.params.map(paramName), `${C} = {}`].join(", ")
    const body = print(d.template.body)
    // Codecs replace named types without arguments.
    const type = d.params.length === 0 ? `Haus$.Lookup<${C}, ${JSON.stringify(d.id)}, ${body}>` : body
    out.push(`${definitionDoc(d, from + stream)}${exported}type ${name}<${params}> = ${type};\n`)
    if (own.has(d) && d.params.length === 0) {
      used.add("Schema")
      const ids = idsOf(d).map((id) => JSON.stringify(id)).join(" | ")
      out.push(`interface ${name}$F extends Haus$.TypeLambda { readonly type: ${name}<this["C"]> }\n`)
      out.push(`${definitionDoc(d, `The Effect schema of ${d.name}.\n\n`)}export declare const ${name}: Haus$.Named<Schema$.Codec<${name}>, ${JSON.stringify(d.id)}, ${name}$F, ${ids}>;\n`)
    }
  }
  const imports = [...used].sort().map((n) => `${n} as ${n}$`)
  const head = (imports.length ? `import type { ${imports.join(", ")} } from ${JSON.stringify(options.effect ?? "effect")};\n` : "") +
    `import type * as Haus$ from ${JSON.stringify(options.haus ?? "@haus-fmt/effect")};\n`
  return head + out.join("")
}
