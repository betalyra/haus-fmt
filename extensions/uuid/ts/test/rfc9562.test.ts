import { compileSchemaFile, parseAll } from "@haus-fmt/haus"
import { nodeResolver, schemaOptions } from "@haus-fmt/haus/node"
import * as h from "@haus-fmt/haus/schema"
import * as Haus from "@haus-fmt/effect"
import { Effect, Exit, Schema } from "effect"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, expectTypeOf, it } from "vitest"
import { isUuid, rfc9562, Uuid } from "../src/index.js"
import { rfc9562 as rfc9562Effect } from "../src/effect.js"

const root = join(import.meta.dirname, "../..")
const schemaPath = join(root, "schema.haus")
const text = readFileSync(schemaPath, "utf8")

// ── the vectors (profiles/rfc9562.vectors.haus) ──

const Vector = h.Variant({
  Accept: h.Record({ type: h.String, value: h.String, output: h.Optional(h.String), note: h.Optional(h.String) }),
  Reject: h.Record({ type: h.String, value: h.String, note: h.Optional(h.String) }),
})
const vectors = parseAll(readFileSync(join(root, "profiles/rfc9562.vectors.haus"), "utf8")).map((v) => h.decode(Vector, v))
const name = (v: h.Infer<typeof Vector>) => `${v._tag} ${v.type} ${v.value}${v.note ? ` (${v.note})` : ""}`

/** The value's text in the one spelling of its type (spec §15), decoded with the schema alone. */
const base = compileSchemaFile(text, schemaOptions(schemaPath)).schemas
const normal = (type: string, value: string) => h.stringify(base[type]!, h.parse(base[type]!, value), { style: "compact" })

describe("the rfc9562 vectors", () => {
  it("are read", () => {
    expect(vectors.some((v) => v._tag === "Accept") && vectors.some((v) => v._tag === "Reject")).toBe(true)
  })

  describe("with haus schemas", () => {
    const coded = compileSchemaFile(text, { ...schemaOptions(schemaPath), codecs: rfc9562 }).schemas
    for (const v of vectors) {
      it(name(v), () => {
        const schema = coded[v.type]!
        // Every vector is valid under the schema: what a codec rejects, the profile rejects.
        expect(() => h.parse(base[v.type]!, v.value)).not.toThrow()
        if (v._tag === "Reject") {
          // The schema accepts it and the profile's codec doesn't (spec §13.4, §17).
          expect(() => h.parse(schema, v.value)).toThrow(expect.objectContaining({ name: "HausDecodeError", code: "codec-rejected" }))
          return
        }
        const decoded = h.parse(schema, v.value)
        const encoded = h.stringify(schema, decoded, { style: "compact" })
        expect(encoded).toBe(normal(v.type, v.output ?? v.value))
        // The codec changes no value: it writes what the schema alone decodes; decode, encode, decode is decode.
        expect(encoded).toBe(normal(v.type, v.value))
        expect(h.parse(schema, encoded)).toEqual(decoded)
      })
    }
  })

  describe("with Effect", () => {
    const schemas = Haus.compileSchemaFile(text, schemaOptions(schemaPath)).schemas
    for (const v of vectors) {
      it(name(v), () => {
        const schema = schemas[v.type]!
        const exit = Effect.runSyncExit(Haus.decode(schema, rfc9562Effect)(v.value))
        if (v._tag === "Reject") {
          expect(Exit.isFailure(exit)).toBe(true)
          expect(Effect.runSync(Effect.flip(Haus.decode(schema, rfc9562Effect)(v.value)))).toMatchObject({ code: "codec-rejected" })
          return
        }
        const decoded = Effect.runSync(Haus.decode(schema, rfc9562Effect)(v.value))
        const encoded = Effect.runSync(Haus.encode(schema, rfc9562Effect)(decoded, { style: "compact" }))
        expect(encoded).toBe(normal(v.type, v.output ?? v.value))
        expect(encoded).toBe(normal(v.type, v.value))
        expect(Effect.runSync(Haus.decode(schema, rfc9562Effect)(encoded))).toEqual(decoded)
      })
    }
  })
})

// ── the rule's edge cases ──

const id = "0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57"
const resolver = nodeResolver({ packages: { "@haus-fmt/uuid": root } })
const user = `import @haus-fmt/uuid (Uuid)\ntype User = { id: Uuid, friends: Array Uuid }`

const rejected = [
  id.toUpperCase(), `{${id}}`, `urn:uuid:${id}`, id.replaceAll("-", ""), id.slice(1), `${id}0`, ` ${id}`, `${id}\n`, `${id.slice(0, 35)}٧`, "",
  // A hyphen moved, a digit where a hyphen goes, the letter after f.
  "0190c7a-85b6e-7d3f-9a41-6c2e8f1b0d57", id.replace("-", "0"), id.replace("d", "g"),
]

describe("the rfc9562 codec", () => {
  const User = compileSchemaFile(user, { resolver, codecs: rfc9562 }).schemas.User!

  it("gives the text, and writes it back", () => {
    const s = `{ id: Uuid("${id}"), friends: [Uuid("00000000-0000-0000-0000-000000000000"), Uuid("ffffffff-ffff-ffff-ffff-ffffffffffff")] }`
    expect(h.parse(User, s)).toEqual({ id, friends: ["00000000-0000-0000-0000-000000000000", "ffffffff-ffff-ffff-ffff-ffffffffffff"] })
    expect(h.stringify(User, h.parse(User, s), { style: "compact" })).toBe(s)
  })

  it("applies inside imported types, at the UUID's place", () => {
    expect(() => h.parse(User, `{ id: Uuid("${id}"), friends: [Uuid("${id.toUpperCase()}")] }`)).toThrow(
      expect.objectContaining({ code: "codec-rejected", path: ["friends", 0] }),
    )
  })

  it("rejects every other spelling, and checks no version", () => {
    for (const t of rejected) expect(isUuid(t), JSON.stringify(t)).toBe(false)
    for (const t of rejected) expect(() => h.parse(User, `{ id: Uuid(${JSON.stringify(t)}), friends: [] }`), t).toThrow(h.HausDecodeError)
    for (const version of "0123456789abcdef") expect(isUuid(`0190c7a8-5b6e-${version}d3f-${version}a41-6c2e8f1b0d57`)).toBe(true)
  })

  it("checks what it encodes too", () => {
    expect(() => h.stringify(User, { id: id.toUpperCase(), friends: [] })).toThrow(h.HausEncodeError)
    expect(() => h.stringify(User, { id: 42, friends: [] })).toThrow(h.HausEncodeError)
  })

  it("Uuid as an h.* schema", () => {
    expectTypeOf(h.parse(Uuid, `Uuid("${id}")`)).toEqualTypeOf<string>()
    expect(h.parse(Uuid, `Uuid("${id}")`)).toBe(id)
    expect(() => h.parse(Uuid, `Uuid("${id.toUpperCase()}")`)).toThrow(expect.objectContaining({ code: "codec-rejected" }))
    expect(h.stringify(Uuid, id, { style: "compact" })).toBe(`Uuid("${id}")`)
    expect(() => h.stringify(Uuid, `{${id}}`)).toThrow(h.HausEncodeError)
  })
})

type UuidOf<C> = Haus.Lookup<C, "@haus-fmt/uuid@1#Uuid", { readonly _tag: "Uuid"; readonly values: readonly [string] }>
type UserOf<C> = { readonly id: UuidOf<C>; readonly friends: ReadonlyArray<UuidOf<C>> }
interface UserF extends Haus.TypeLambda {
  readonly type: UserOf<this["C"]>
}

describe("the Effect codec", () => {
  // Typed as the content mapper declares it (schemaDeclarations).
  const User = Haus.compileSchemaFile(user, { resolver }).schemas.User as unknown as Haus.Named<
    Schema.Codec<UserOf<{}>>,
    "User",
    UserF,
    "User" | "@haus-fmt/uuid@1#Uuid"
  >
  const decode = Haus.decode(User, rfc9562Effect)
  const encode = Haus.encode(User, rfc9562Effect)

  it("gives the text, and writes it back", () => {
    const s = `{ id: Uuid("${id}"), friends: [] }`
    const v = Effect.runSync(decode(s))
    expectTypeOf(v.id).toEqualTypeOf<string>()
    expect(v).toEqual({ id, friends: [] })
    expect(Effect.runSync(encode(v, { style: "compact" }))).toBe(s)
  })

  it("rejects every other spelling, inside imported types too", () => {
    for (const t of rejected) expect(Exit.isFailure(Effect.runSyncExit(decode(`{ id: Uuid(${JSON.stringify(t)}), friends: [] }`))), t).toBe(true)
    const e = Effect.runSync(Effect.flip(decode(`{ id: Uuid("${id}"), friends: [Uuid("${id.toUpperCase()}")] }`)))
    expect(e).toMatchObject({ code: "codec-rejected", place: "$.friends[0]" })
    // Without the codec, the schema takes it.
    expect(Exit.isSuccess(Effect.runSyncExit(Haus.decode(User)(`{ id: Uuid("${id.toUpperCase()}"), friends: [] }`)))).toBe(true)
  })

  it("checks what it encodes too", () => {
    expect(Exit.isFailure(Effect.runSyncExit(encode({ id: id.toUpperCase(), friends: [] })))).toBe(true)
  })
})
