/**
 * Packages and their rules through the Effect binding (packages.md §3–§7,
 * D3/D4/D7 of the packages round): the official packages built in with their
 * rules on by default, checked before any codec and whatever the codecs;
 * `missing-codec` at compile for a reached type whose rule the program
 * doesn't implement; `Package.shapeOnly` and `Package.withRule`; Sources and
 * Package values from plain data; reading as an Effect that needs
 * `SchemaFiles`, compiling as one that needs nothing.
 */
import { canonical, parseAll, type Value } from "@haus-fmt/haus/internal"
import { describe, expect, it } from "@effect/vitest"
import { Effect, Exit, Layer, Schema } from "effect"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { geo, wgs84Types } from "../src/geo.js"
import * as Haus from "../src/index.js"
import { currencyAsString, money } from "../src/money.js"
import { NodeSchemaFiles } from "../src/node.js"
import { uuid, uuidAsString } from "../src/uuid.js"
import { compileText, compileTextEffect, failureOf } from "./support.js"

const REPO = join(import.meta.dirname, "../../../..")
const EXTENSIONS = join(REPO, "extensions")

const ALL = `import @haus-fmt/money (Money, Currency)
import @haus-fmt/geo (LatLng, BBox)
import @haus-fmt/uuid (Uuid)
type All = { m: Money, c: Currency, l: LatLng, b: BBox, u: Uuid }`

/** The official packages' types, as their own named Effect schemas (from a schema that imports them). */
const typesOf = (packages: readonly Haus.PackageType[] = []) => {
  const text = `${ALL}\ntype M = Money\ntype C = Currency\ntype L = LatLng\ntype B = BBox\ntype U = Uuid`
  const { schemas } = compileText(text, { packages })
  return { Money: schemas.M!, Currency: schemas.C!, LatLng: schemas.L!, BBox: schemas.B!, Uuid: schemas.U! } as Readonly<Record<string, Schema.Codec<unknown>>>
}

const field = (v: Value, key: string): Value | undefined => (v.kind === "record" ? v.fields.get(key) : undefined)
const text = (v: Value | undefined): string => (v?.kind === "string" ? v.value : "")

// ── the official packages' rules, on by default ──────────────

for (const [name, rule, pkg] of [["money", "iso", money], ["geo", "wgs84", geo], ["uuid", "rfc9562", uuid]] as const) {
  describe(`the rule ${rule} of @haus-fmt/${name}, on by default: its vectors`, () => {
    const vectors = parseAll(readFileSync(join(EXTENSIONS, name, `profiles/${rule}.vectors.haus`), "utf8"))
    const checked = typesOf()
    const shapeOnly = typesOf([Haus.Package.shapeOnly(pkg)])
    for (const v of vectors) {
      if (v.kind !== "variant") throw new Error("a vector is Accept { … } or Reject { … }")
      const fields = v.args[0]!
      const type = text(field(fields, "type"))
      const value = text(field(fields, "value"))
      const note = text(field(fields, "note"))
      it(`${v.tag} ${type}: ${value}${note ? ` (${note})` : ""}`, () => {
        const schema = checked[type]!
        if (v.tag === "Accept") {
          const decoded = Effect.runSync(Haus.decode(schema)(value))
          expect(Effect.runSync(Haus.encode(schema)(decoded, { style: "compact" }))).toBe(text(field(fields, "output")) || value)
          return
        }
        // The shape is valid (shape-only, it decodes), and the rule rejects it: codec-rejected.
        expect(Exit.isSuccess(Effect.runSyncExit(Haus.decode(shapeOnly[type]!)(value)))).toBe(true)
        expect(failureOf(Haus.decode(schema)(value)).code).toBe("codec-rejected")
        // A looser codec of the application's doesn't change that: the rule runs before any codec (D3).
        const looser = field(fields, "looser")
        if (looser?.kind === "array") {
          const accepting = Haus.codecs(...looser.items.map((t) => Haus.codec(checked[text(t)] as Haus.Named<Schema.Codec<unknown>, string>, (base) => base)))
          expect(failureOf(Haus.decode(schema, accepting)(value)).code, canonical(v)).toBe("codec-rejected")
        }
      })
    }
  })
}

describe("rules on by default (packages.md §6)", () => {
  const { schemas } = compileText(ALL)
  const All = schemas.All!
  const ok = `{ m: Money(19.90, EUR), c: CHF, l: LatLng(38.7, -9.1), b: BBox(LatLng(1, 2), LatLng(3, 4)), u: Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57") }`

  it("checks every reached type of an official package, in any package's types, at its place", () => {
    expect(Exit.isSuccess(Effect.runSyncExit(Haus.decode(All)(ok)))).toBe(true)
    for (const [bad, place] of [
      [ok.replace("EUR", "Eur"), "$.m[1]"],
      [ok.replace("CHF", "Chf"), "$.c"],
      [ok.replace("38.7", "91"), "$.l"],
      [ok.replace("LatLng(1, 2)", "LatLng(5, 2)"), "$.b"],
      [ok.replace("0190c7a8", "0190C7A8"), "$.u"],
    ] as const) {
      expect(failureOf(Haus.decode(All)(bad))).toMatchObject({ _tag: "HausSchemaError", code: "codec-rejected", place })
    }
  })

  it("checks what is encoded too", () => {
    const value = Effect.runSync(Haus.decode(All)(ok)) as { readonly c: string }
    expect(failureOf(Haus.encode(All)({ ...value, c: "eur" }))).toMatchObject({ code: "cannot-encode", place: "$.c" })
  })

  it("is checked before the codecs, which only choose host types", () => {
    const typed = Effect.runSync(Haus.decode(All, currencyAsString, wgs84Types, uuidAsString)(ok)) as { readonly u: string; readonly c: string }
    expect(typed.u).toBe("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57")
    expect(typed.c).toBe("CHF")
    // An application's codec that accepts everything doesn't let a value through the rule (D3).
    const C = compileText(`import @haus-fmt/money (Currency)\ntype C = Currency`).schemas.C as Haus.Named<Schema.Codec<unknown>, "@haus-fmt/money@1#Currency">
    const anything = Haus.codec(C, (base) => base)
    expect(failureOf(Haus.decode(C, anything)("Eur")).code).toBe("codec-rejected")
  })

  it("shape-only: the program takes an official package without its rule (packages.md §7)", () => {
    const loose = compileText(ALL, { packages: [Haus.Package.shapeOnly(money)] }).schemas.All!
    expect(Exit.isSuccess(Effect.runSyncExit(Haus.decode(loose)(ok.replace("EUR", "Eur"))))).toBe(true)
    // Only that package: the others are still checked.
    expect(failureOf(Haus.decode(loose)(ok.replace("38.7", "91"))).code).toBe("codec-rejected")
  })

  it("an official package can't be replaced: a differing copy is duplicate-package", () =>
    Effect.gen(function* () {
      const copy = yield* Haus.Package.make({ manifest: money.manifest, schema: `${money.schema}\ntype Extra = Int` })
      const e = yield* Effect.flip(compileTextEffect(ALL, { packages: [copy] }))
      expect(e).toMatchObject({ _tag: "HausCompileError", code: "duplicate-package" })
    }).pipe(Effect.runSync))
})

// ── third-party packages: missing-codec, shapeOnly, withRule ──

const CODES = { manifest: `{ name: "@acme/codes", version: "1.0.0", rules: { "Code": "upper" } }`, schema: "type Code = < >\ntype Label = String" }
const APP = `import @acme/codes (Code)\ntype Root = { code: Code }`

describe("a third-party package's rules (packages.md §7)", () => {
  it("missing-codec at compile, once per reached type, when the program has no implementation", () =>
    Effect.gen(function* () {
      const codes = yield* Haus.Package.make(CODES)
      const e = yield* Effect.flip(compileTextEffect(APP, { packages: [codes] }))
      expect(e._tag).toBe("HausCompileError")
      expect(e).toMatchObject({ code: "missing-codec" })
      expect(e.message).toContain("@acme/codes@1#Code")
      expect(e.message).toContain("shapeOnly")
      // A rule of a type the schema doesn't reach is not required.
      const label = yield* compileTextEffect(`import @acme/codes (Label)\ntype Root = { label: Label }`, { packages: [codes] })
      expect([...label.packages.keys()]).toContain("@acme/codes")
    }).pipe(Effect.runSync))

  it("shapeOnly: compiles, the type checked for its shape only", () =>
    Effect.gen(function* () {
      const codes = Haus.Package.shapeOnly(yield* Haus.Package.make(CODES))
      const { schemas } = yield* compileTextEffect(APP, { packages: [codes] })
      expect(yield* Haus.decode(schemas.Root!)(`{ code: "abc" }`).pipe(Effect.flip, Effect.map((e) => e.code))).toBe("type-mismatch")
      expect(yield* Haus.decode(schemas.Root!)(`{ code: Lower }`)).toEqual({ code: "Lower" })
    }).pipe(Effect.runSync))

  it("withRule: the program's implementation, a filter, checked as an official rule is", () =>
    Effect.gen(function* () {
      const upper = (code: unknown) => (typeof code === "string" && /^[A-Z]+$/.test(code)) || "a Code is capital letters"
      const codes = yield* Haus.Package.make(CODES).pipe(Effect.flatMap(Haus.Package.withRule("Code", upper)))
      const { schemas } = yield* compileTextEffect(APP, { packages: [codes] })
      expect(yield* Haus.decode(schemas.Root!)(`{ code: EUR }`)).toEqual({ code: "EUR" })
      const e = yield* Effect.flip(Haus.decode(schemas.Root!)(`{ code: Eur }`))
      expect(e).toMatchObject({ code: "codec-rejected", place: "$.code", message: expect.stringContaining("a Code is capital letters") })
      // The rules given with the data are the same thing.
      const bundled = yield* Haus.Package.make({ ...CODES, rules: { Code: upper } })
      const again = yield* compileTextEffect(APP, { packages: [bundled] })
      expect((yield* Effect.flip(Haus.decode(again.schemas.Root!)(`{ code: Eur }`))).code).toBe("codec-rejected")
    }).pipe(Effect.runSync))

  it("a rule for a type the manifest gives none is a HausConfigError", () =>
    Effect.gen(function* () {
      const codes = yield* Haus.Package.make(CODES)
      const e = yield* Effect.flip(Haus.Package.withRule(codes, "Label", () => true))
      expect(e._tag).toBe("HausConfigError")
      expect(e.message).toContain("Label")
    }).pipe(Effect.runSync))

  it("a broken rules field is package-manifest, at compile", () =>
    Effect.gen(function* () {
      const broken = yield* Haus.Package.make({ manifest: `{ name: "@acme/codes", version: "1.0.0", rules: { "Nope": "upper" } }`, schema: CODES.schema })
      expect(yield* Effect.flip(compileTextEffect(APP, { packages: [broken] }))).toMatchObject({ code: "package-manifest" })
      // A manifest that isn't one fails when the package is made.
      expect(yield* Effect.flip(Haus.Package.make({ manifest: "{ name: 1 }", schema: "" }))).toMatchObject({ _tag: "HausCompileError", code: "package-manifest" })
    }).pipe(Effect.runSync))
})

// ── values, reading, compiling ───────────────────────────────

describe("Sources and Package values; reading and compiling", () => {
  it("Sources.make: from plain data, with the checks of reading but the file system's", () =>
    Effect.gen(function* () {
      const sources = yield* Haus.Sources.make("app/order.schema.haus", { "app/order.schema.haus": "import ./common (Tag)\ntype Order = { tag: Tag }", "app/common.schema.haus": "type Tag = String" })
      const { schemas } = yield* Haus.compile(sources)
      expect(yield* Haus.decode(schemas.Order!)(`{ tag: "a" }`)).toEqual({ tag: "a" })
      expect(yield* Effect.flip(Haus.Sources.make("x.schema.haus", { "../x.schema.haus": "" }))).toMatchObject({ _tag: "HausCompileError", code: "import-not-found" })
    }).pipe(Effect.runSync))

  it("a schema file's error is a HausCompileError at its line and column", () => {
    const e = failureOf(compileTextEffect("type A = {\n  a: Nope\n}"))
    expect(e).toMatchObject({ _tag: "HausCompileError", line: 2 })
    expect(Haus.errorJson(e)).toMatchObject({ code: e.code, line: 2, docs: expect.stringContaining(e.code) })
  })

  it("reading needs SchemaFiles; NodeSchemaFiles reads with the core's file rules", async () =>
    Effect.gen(function* () {
      const sources = yield* Haus.readSources(join(REPO, "examples/syntax-tour.schema.haus"))
      const { schemas, packages } = yield* Haus.compile(sources)
      expect(schemas.Root).toBeDefined()
      expect([...packages.keys()]).toContain("@haus-fmt/money")
      const pkg = yield* Haus.readPackage(join(EXTENSIONS, "money"))
      expect(pkg.name).toBe("@haus-fmt/money")
      const missing = yield* Effect.flip(Haus.readSources(join(REPO, "no-such.schema.haus")))
      expect(missing).toMatchObject({ _tag: "HausCompileError", code: "import-not-found" })
    }).pipe(Effect.provide(NodeSchemaFiles.layer), Effect.runPromise))

  it("SchemaFiles is a service: a program can read from anywhere (here, memory)", () =>
    Effect.gen(function* () {
      const memory = Layer.succeed(Haus.SchemaFiles, Haus.SchemaFiles.of({
        readSources: (path) => Haus.Sources.make(path, { [path]: "type Note = { text: String }" }),
        readPackage: () => Haus.Package.make(CODES).pipe(Effect.orDie),
        readPackages: (folder) => Effect.succeed({ path: folder, packages: [], skipped: [] }),
      }))
      const { schemas } = yield* Haus.readSources("note.schema.haus").pipe(Effect.flatMap(Haus.compile), Effect.provide(memory))
      expect(yield* Haus.decode(schemas.Note!)(`{ text: "hi" }`)).toEqual({ text: "hi" })
    }).pipe(Effect.runSync))

  it("fromSchema: the Effect schemas of a schema @haus-fmt/haus compiled, with its rules", async () => {
    const core = await import("@haus-fmt/haus")
    const sources = core.Sources.make("a.schema.haus", { "a.schema.haus": "import @haus-fmt/money (Currency)\ntype C = Currency" })
    const schema = core.Result.flatMap(sources, core.Schema.compile)
    if (schema._tag === "Failure") throw schema.failure
    const { schemas } = Haus.fromSchema(schema.success)
    expect(failureOf(Haus.decode(schemas.C!)("Eur")).code).toBe("codec-rejected")
  })
})
