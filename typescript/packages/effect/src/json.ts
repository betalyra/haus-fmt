/**
 * The plain JSON form (spec §16.3) of an Effect schema: a `JsonType` built
 * from the schema's encoded side, the same AST the converters of convert.ts
 * read. A value is written by encoding it to a haus value and that to JSON
 * (the core's `toPlainJson`), and read the other way round, so Effect's own
 * decoder and encoder still run, with their filters and transformations.
 *
 *   Schema.String → "…"              Haus.Date & co. → "2026-11-13"        Haus.Decimal, Schema.BigDecimal → "19.90"
 *   Schema.Number → 1.5, "NaN", …    integer numbers of schema files → 12  Schema.BigInt → "12"
 *   Schema.Boolean → true / false    Schema.Uint8Array → base64            Haus.Any → its lossless form
 *   Schema.Option(X) → null / x      (tagged when X's JSON can be null)     Schema.Redacted(X) → as X
 *   Schema.Literals(["Debug", "Info"]) → "Debug"                           TaggedStruct("Circle", { r }) → {"_tag": "Circle", "r": 1.5}
 *   Haus.OpenUnion([...]): other tags → {"_tag": "Hexagon", "args": [lossless…]}
 */
import type { JsonCase, JsonRecordType, JsonType } from "@haus-fmt/haus"
import { Option, SchemaAST } from "effect"
import { BARE_TAG, CLOSED, DECIMAL, declarationId, members, NESTED, NUMBER, POSITIONAL, PRELUDE_TAG, SECRET, tagOf, UNKNOWN_TAG, VALUE, VALUES } from "./convert.js"

type AST = SchemaAST.AST

const TAG_NAME = /^[A-Z][A-Za-z0-9_]*$/

const none = (expected: string): JsonType => ({ kind: "none", expected })

const unit: JsonCase = { kind: "unit" }

const cache = new WeakMap<AST, JsonType>()

/** The plain JSON form of an encoded-side AST (memoised; a `Schema.suspend` is a lazy link). */
export const jsonTypeOf = (ast: AST): JsonType => {
  const cached = cache.get(ast)
  if (cached) return cached
  if (ast._tag === "Suspend") {
    let target: JsonType | undefined
    // The same object every time: a recursive schema's JSON form is a finite graph.
    const lazy: JsonType = { kind: "lazy", get: () => (target ??= jsonTypeOf(ast.thunk())) }
    cache.set(ast, lazy)
    return lazy
  }
  const built = ast.annotations?.[VALUE] === true ? { kind: "any" as const } : build(ast)
  cache.set(ast, built)
  return built
}

/** Whether a bigint schema has both bounds (`isBetweenBigInt`, as Int64 and UInt64 in schema files). */
const hasRange = (ast: AST): boolean =>
  (ast.checks ?? []).some((c) => (c.annotations?.["representation"] as { readonly id?: unknown } | undefined)?.id === "effect/schema/isBetweenBigInt")

const build = (ast: AST): JsonType => {
  switch (ast._tag) {
    case "String": {
      const tag = ast.annotations?.[PRELUDE_TAG]
      if (typeof tag === "string") return { kind: "time", tag }
      if (ast.annotations?.[DECIMAL] === true) return { kind: "decimal" }
      // `< >` on its own: every tag is an unknown value.
      if (ast.annotations?.[BARE_TAG] === true) return { kind: "variant", open: true, cases: new Map() }
      return { kind: "string" }
    }
    case "TemplateLiteral":
      return { kind: "string" }
    case "Number":
      return ast.annotations?.[NUMBER] === "Int" ? { kind: "integer", quoted: false } : { kind: "float" }
    case "BigInt":
      return { kind: "integer", quoted: true, bounded: hasRange(ast) }
    case "Boolean":
      return { kind: "bool" }
    case "Literal":
      return literal(ast.literal)
    case "Enum": {
      const values = ast.enums.map(([, v]) => v)
      return values.every((v): v is string => typeof v === "string" && TAG_NAME.test(v))
        ? { kind: "variant", open: false, cases: new Map(values.map((v) => [v, unit])) }
        : none("an Enum whose values aren't all tag names")
    }
    case "Arrays": {
      if (ast.rest.length > 1) return none("an array with elements after its rest")
      const rest = ast.rest[0]
      if (ast.elements.length === 0 && rest !== undefined) return { kind: "array", item: jsonTypeOf(rest) }
      return { kind: "tuple", items: ast.elements.map(jsonTypeOf), rest: rest && jsonTypeOf(rest) }
    }
    case "Objects":
      return objects(ast)
    case "Union":
      return union(ast)
    case "Declaration":
      return declaration(ast)
    default:
      return none(`Schema ${ast._tag} (use Haus.Any for any haus value)`)
  }
}

/** A literal as the haus value convert.ts writes: a tag-like string is a tag (`"EUR"` → `EUR`). */
const literal = (lit: SchemaAST.LiteralValue): JsonType => {
  switch (typeof lit) {
    case "string":
      return TAG_NAME.test(lit) ? { kind: "variant", open: false, cases: new Map([[lit, unit]]) } : { kind: "string" }
    case "number":
      return { kind: "float" }
    case "boolean":
      return { kind: "bool" }
    case "bigint":
      return { kind: "integer", quoted: true }
    default:
      return none(`the literal ${String(lit)}`)
  }
}

/** A struct's fields; a tagged struct's without its `_tag`. */
const record = (ast: SchemaAST.Objects, tagged: boolean): JsonRecordType => ({
  kind: "record",
  fields: new Map(ast.propertySignatures.filter((p) => !tagged || p.name !== "_tag").map((p) => [String(p.name), jsonTypeOf(p.type)])),
  closed: ast.annotations?.[CLOSED] === true,
})

const objects = (ast: SchemaAST.Objects): JsonType =>
  Option.match(tagOf(ast), {
    onSome: (tag) => (tag === UNKNOWN_TAG ? none("Haus.Unknown outside an OpenUnion") : { kind: "variant", open: false, cases: new Map([[tag, variantCase(ast)]]) }),
    onNone: (): JsonType => {
      if (ast.indexSignatures.length === 0) return record(ast, false)
      const [index] = ast.indexSignatures
      // `Schema.Record(Schema.String, V)`: a haus `Map v`.
      return ast.propertySignatures.length === 0 && ast.indexSignatures.length === 1 ? { kind: "map", value: jsonTypeOf(index!.type) }
        : none("a struct with both fields and an index signature")
    },
  })

/** A tagged struct as the case convert.ts writes: no payload, positional arguments, or a record payload. */
const variantCase = (ast: SchemaAST.Objects): JsonCase => {
  const props = ast.propertySignatures.filter((p) => p.name !== "_tag")
  if (ast.annotations?.[VALUES] === true) {
    // A schema file's `Tag T1 … Tn`: `{ _tag, values: [ … ] }`.
    const values = props.find((p) => p.name === "values")?.type
    return values?._tag === "Arrays" && values.rest.length === 0 ? { kind: "positional", items: values.elements.map(jsonTypeOf) }
      : { kind: "positional", items: [none("a positional case without a values tuple")] }
  }
  if (ast.annotations?.[NESTED] === true) {
    // A schema file's case whose record payload has a field `_tag`: `{ _tag, value: { … } }`. Its
    // JSON form is the record's (beside `_tag`), which the converters report as having none (§16.3).
    const value = props.find((p) => p.name === "value")?.type
    const payload = value === undefined ? undefined : jsonTypeOf(value)
    return payload?.kind === "record" ? { kind: "record", record: payload } : { kind: "positional", items: [none("a nested case without a record")] }
  }
  if (props.length === 0 && ast.indexSignatures.length === 0) return unit
  if (ast.annotations?.[POSITIONAL] === true) return { kind: "positional", items: props.map((p) => jsonTypeOf(p.type)) }
  return { kind: "record", record: record(ast, true) }
}

/** A union of tagged structs and tag literals is a haus variant, open with `Haus.OpenUnion`. */
const union = (ast: SchemaAST.Union): JsonType => {
  const all = members(ast)
  if (all.length === 1) return jsonTypeOf(all[0]!)
  const cases = new Map<string, JsonCase>()
  let open = false
  const others: AST[] = []
  for (const m of all) {
    const tag = Option.getOrUndefined(tagOf(m))
    if (tag === UNKNOWN_TAG) open = true
    else if (tag !== undefined && m._tag === "Objects") cases.set(tag, variantCase(m))
    else if (m._tag === "Literal" && typeof m.literal === "string" && TAG_NAME.test(m.literal)) cases.set(m.literal, unit)
    else if (m._tag === "String" && m.annotations?.[BARE_TAG] === true) open = true
    else others.push(m)
  }
  if (others.length === 0) return { kind: "variant", open, cases }
  // Literals that aren't tags (`"a b"`), or other strings: a string.
  if (cases.size === 0 && !open && others.every((m) => jsonTypeOf(m).kind === "string")) return { kind: "string" }
  return none("a union that isn't a haus variant (tagged structs and tag literals)")
}

const declaration = (ast: SchemaAST.Declaration): JsonType => {
  const id = Option.getOrUndefined(declarationId(ast))
  const [param] = ast.typeParameters
  switch (id) {
    case "effect/schema/Uint8Array":
      return { kind: "bytes" }
    case "effect/schema/BigDecimal":
      return { kind: "decimal" }
    case "effect/schema/DateTimeUtc":
      return { kind: "time", tag: "Instant" }
    case "effect/schema/DateTimeZoned":
      return { kind: "time", tag: "ZonedDateTime" }
    case "effect/schema/Option":
      return param ? { kind: "maybe", item: jsonTypeOf(param) } : none("Schema.Option without its type")
    case "effect/schema/Redacted": {
      const type = ast.annotations?.[SECRET]
      return param ? { kind: "secret", item: jsonTypeOf(param), expected: typeof type === "string" ? type : "a valid value" } : none("Schema.Redacted without its type")
    }
    default:
      return none(`the declaration ${String(id)}`)
  }
}
