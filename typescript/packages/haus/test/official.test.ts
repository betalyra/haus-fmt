/**
 * The official packages built in (packages.md §3): their files byte for byte
 * those of extensions/<name>/, and their rules pass the test vectors
 * (extensions/<name>/profiles/<rule>.vectors.haus, packages.md §6).
 */
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { Codec, Package, Result, Schema, Sources, type HausError, type Type } from "../src/haus.js"
import { BBox, geo, LatLng } from "../src/geo.js"
import { Currency, money, Money } from "../src/money.js"
import { uuid, Uuid } from "../src/uuid.js"
import { canonical, parseAll, type Value } from "../src/index.js"

const EXTENSIONS = join(import.meta.dirname, "../../../../extensions")
const file = (name: string, path: string) => readFileSync(join(EXTENSIONS, name, path), "utf8")

describe("the built-in packages are the files of extensions/ (packages.md §3)", () => {
  for (const [name, pkg] of [["money", money], ["geo", geo], ["uuid", uuid]] as const) {
    it(`@haus-fmt/${name}: package.haus and schema.haus byte for byte`, () => {
      expect(pkg.manifest).toBe(file(name, "package.haus"))
      expect(pkg.schema).toBe(file(name, "schema.haus"))
    })
  }
})

const ok = <A>(r: Result<A, HausError>): A => {
  if (r._tag === "Failure") throw new Error(r.failure.message)
  return r.success
}

const SCHEMA = `import @haus-fmt/money (Money, Currency)
import @haus-fmt/geo (LatLng, BBox)
import @haus-fmt/uuid (Uuid)
type All = { m: Money, c: Currency, l: LatLng, b: BBox, u: Uuid }`

const compile = (...packages: readonly Package[]) =>
  ok(Schema.compile(packages.reduce((s, p) => Sources.withPackage(s, p), ok(Sources.make("v.schema.haus", { "v.schema.haus": SCHEMA })))))

const HANDLES: Readonly<Record<string, Type>> = { Money, Currency, LatLng, BBox, Uuid }

/** A codec that accepts every value of its type (looser than any rule). */
const accepting = (type: Type) => Codec.make(type, { decode: (a: unknown) => Result.succeed(a), encode: (b: unknown) => Result.succeed(b) })

const field = (v: Value, key: string): Value | undefined => (v.kind === "record" ? v.fields.get(key) : undefined)
const text = (v: Value | undefined): string => (v?.kind === "string" ? v.value : "")

for (const [name, rule] of [["money", "iso"], ["geo", "wgs84"], ["uuid", "rfc9562"]] as const) {
  describe(`the rule ${rule} of @haus-fmt/${name}: its vectors`, () => {
    const vectors = parseAll(file(name, `profiles/${rule}.vectors.haus`))
    const schema = compile()
    const shapeOnly = compile(Package.shapeOnly(name === "money" ? money : name === "geo" ? geo : uuid))
    for (const v of vectors) {
      if (v.kind !== "variant") throw new Error("a vector is Accept { … } or Reject { … }")
      const fields = v.args[0]!
      const type = HANDLES[text(field(fields, "type"))]!
      const value = text(field(fields, "value"))
      const note = text(field(fields, "note"))
      it(`${v.tag} ${type.name}: ${value}${note ? ` (${note})` : ""}`, () => {
        if (v.tag === "Accept") {
          const decoded = ok(Schema.decode(schema, type)(value))
          expect(ok(Schema.stringify(schema, type)(decoded, { style: "compact" }))).toBe(text(field(fields, "output")) || value)
          return
        }
        // The shape is valid, and the rule rejects it: codec-rejected.
        expect(Schema.decode(shapeOnly, type)(value)._tag).toBe("Success")
        const rejected = Schema.decode(schema, type)(value)
        expect(rejected._tag === "Failure" && rejected.failure.code).toBe("codec-rejected")
        // A looser codec of the application's doesn't change that (spec §13.4).
        const looser = field(fields, "looser")
        if (looser?.kind === "array") {
          const s = looser.items.reduce((acc, t) => ok(Schema.withCodec(acc, accepting(HANDLES[text(t)]!))), schema)
          const again = Schema.decode(s, type)(value)
          expect(again._tag === "Failure" && again.failure.code, canonical(v)).toBe("codec-rejected")
        }
      })
    }
  })
}
