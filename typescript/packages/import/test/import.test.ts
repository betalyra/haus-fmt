import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"
import { describe, expect, it } from "vitest"
import { backend, moduleFor, packagesOf, typesFor } from "../src/generate.js"
import haus from "../src/vite.js"

const examples = join(import.meta.dirname, "../../../../examples")
const at = (name: string) => join(examples, name)
const read = (name: string) => readFileSync(at(name), "utf8")
const runtimeOf = (path: string) => pathToFileURL(join(import.meta.dirname, `../src/${path}.ts`)).href

/** Load generated module code as a real ES module. */
const load = async (code: string) => {
  const file = join(mkdtempSync(join(tmpdir(), "haus-import-")), "module.mjs")
  writeFileSync(file, code)
  return (await import(pathToFileURL(file).href)) as Record<string, unknown>
}

describe("plain target", async () => {
  const plain = await backend("plain")

  it("data without a schema: plain values, typed by the data", async () => {
    const types = typesFor(read("person.haus"), at("person.haus"), plain)
    expect(types.diagnostics).toEqual([])
    expect(types.text).toContain("export default person")
    const { code, files } = moduleFor(read("person.haus"), at("person.haus"), plain, runtimeOf)
    expect(files).toEqual([])
    expect(code).not.toContain("import")
    const value = (await load(code)).default as readonly { readonly name: string }[]
    expect(value[0]?.name).toEqual(expect.any(String))
  })

  it("schema files: types and haus schemas (Standard Schemas)", async () => {
    const types = typesFor(read("thread.schema.haus"), at("thread.schema.haus"), plain)
    expect(types.text).toContain("export declare const Comment: h$.Schema<Comment>")
    expect(types.text).not.toContain("effect")
    const { code } = moduleFor(read("thread.schema.haus"), at("thread.schema.haus"), plain, runtimeOf)
    expect(code).not.toContain("effect")
    const { Comment } = (await load(code)) as { Comment: { "~standard": { vendor: string } } }
    expect(Comment["~standard"].vendor).toBe("haus")
  })

  it("data with a schema: decoded with it", async () => {
    const { code } = moduleFor(read("thread.haus"), at("thread.haus"), plain, runtimeOf)
    const thread = (await load(code)).default as { readonly likes: bigint; readonly at: string }
    expect(typeof thread.likes).toBe("bigint")
    expect(thread.at).toBe("2026-11-01T09:00:00Z") // std/time values keep their text
  })

  it("data that doesn't match its schema fails with its position", async () => {
    const dir = mkdtempSync(join(tmpdir(), "haus-bad-"))
    writeFileSync(join(dir, "x.schema.haus"), "type Root = { n: Int }")
    writeFileSync(join(dir, "x.haus"), `{\n  n: "one",\n}`)
    const { code } = moduleFor(readFileSync(join(dir, "x.haus"), "utf8"), join(dir, "x.haus"), plain, runtimeOf)
    await expect(load(code)).rejects.toThrow(/x\.haus:2:6: expected Int/)
  })
})

describe("effect target", async () => {
  const effect = await backend("effect")

  it("data with a schema is decoded with Effect", async () => {
    const { code, files } = moduleFor(read("thread.haus"), at("thread.haus"), effect, runtimeOf)
    expect(files).toEqual([at("thread.schema.haus")])
    const thread = (await load(code)).default as { readonly likes: bigint }
    expect(typeof thread.likes).toBe("bigint")
  })

  it("schema imports are resolved when the module is generated, without absolute paths", async () => {
    const { code, files } = moduleFor(read("order.schema.haus"), at("order.schema.haus"), effect, runtimeOf)
    expect(files.length).toBeGreaterThan(1) // the schema file and the packages it imports
    expect(code).not.toContain(examples)
    const mod = await load(code)
    expect(mod.Root).toBeDefined()
    expect(mod.Status).toBeDefined()
  })
})

describe("Secret, Any and attributes", async () => {
  const SECRET = "hunter2-ZQXJ9WVK"
  const schema = `type Root = { name: String, @deprecated("use token") key?: Secret String, token?: Secret String, extra: Any }`
  /** A schema file and a data file in a fresh directory. */
  const files = (data: string) => {
    const dir = mkdtempSync(join(tmpdir(), "haus-secret-"))
    writeFileSync(join(dir, "x.schema.haus"), schema)
    writeFileSync(join(dir, "x.haus"), data)
    return { schema: join(dir, "x.schema.haus"), data: join(dir, "x.haus") }
  }
  const good = `{ name: "a", key: "${SECRET}", extra: Order { id: 1 } }`
  const bad = `{\n  name: "a",\n  key: 98765432,\n  extra: 1,\n}`

  for (const target of ["plain", "effect"] as const) {
    it(`${target}: declarations, decoding and errors without the value`, async () => {
      const b = await backend(target)
      const { schema: schemaPath, data } = files(good)
      const types = typesFor(schema, schemaPath, b).text
      expect(types).toContain(target === "plain" ? "key?: h$.Secret<string>" : "key?: Redacted$.Redacted<string>")
      expect(types).toContain(target === "plain" ? "readonly extra: h$.Value" : "readonly extra: Haus$.Value")
      expect(types).toContain("/** @deprecated use token */ readonly key?:")

      const root = (await load(moduleFor(good, data, b, runtimeOf).code)).default as { key: unknown; extra: { kind: string } }
      expect(String(root.key)).toBe("<redacted>")
      expect(JSON.stringify(root)).not.toContain(SECRET)
      expect(root.extra.kind).toBe("variant")

      const wrong = files(bad)
      const diagnostics = typesFor(bad, wrong.data, b).diagnostics
      expect(diagnostics.map((d) => d.message)).toEqual(["expected String (a Secret: the value is not shown) (x.schema.haus: Root)"])
      const failed = await load(moduleFor(bad, wrong.data, b, runtimeOf).code).then(() => "loaded", (e: Error) => e.message)
      expect(failed).toMatch(/^x\.haus:3:\d+: expected String \(a Secret: the value is not shown\)/)
      expect(failed).not.toContain("98765432")
    })
  }
})

describe("compiled codecs built ahead (plain target)", async () => {
  const plain = await backend("plain")
  const suite = join(import.meta.dirname, "../../../../test-suite/schema")
  // The haus modules the generated module's runtime loads, so that the check runs against the same ones.
  // Native Node runs these modules (not Vitest), so the runtime is the built one.
  const builtRuntime = (path: string) => pathToFileURL(join(import.meta.dirname, `../dist/${path}.js`)).href
  const hausOf = (entry: string) => pathToFileURL(realpathSync(createRequire(join(import.meta.dirname, "../dist/runtime/plain.js")).resolve(entry))).href
  /**
   * Run in a Node process of its own (one instance of each module): every
   * case of the suite decoded, and encoded again, by default (the codecs built ahead)
   * and on the generic path. Prints what differs, where each schema's
   * generated codecs came from, and how many cases were compared.
   */
  const check = (cases: string) => `
import { isDeepStrictEqual } from "node:util"
import * as m from "./module.mjs"
import * as h from ${JSON.stringify(hausOf("@haus-fmt/haus/schema"))}
import { parseAll, stringify } from ${JSON.stringify(hausOf("@haus-fmt/haus"))}
import { generatedOrigin } from ${JSON.stringify(hausOf("@haus-fmt/haus/codegen"))}
/** Own keys in order, all the way down: isDeepStrictEqual doesn't compare their order. */
const keys = (v) => v === null || typeof v !== "object" ? "" : v instanceof Map ? [...v].map(([k, x]) => k + keys(x)).join() : Reflect.ownKeys(v).map((k) => String(k) + "(" + keys(v[k]) + ")").join()
const outcome = (f) => { try { return { ok: true, value: f() } } catch (e) { return { ok: false, error: { name: e.name, message: e.message, code: e.code, path: e.path } } } }
const same = (a, b) => a.ok === b.ok && (a.ok ? isDeepStrictEqual(a.value, b.value) && keys(a.value) === keys(b.value) : isDeepStrictEqual(a.error, b.error))
const differences = []
let compared = 0
for (const c of parseAll(${JSON.stringify(cases)})) {
  const f = c.args[0].fields
  const type = f.get("type").value
  const schema = m[type]
  const text = stringify(f.get("input"), { style: "minimised" })
  const generated = outcome(() => h.parse(schema, text))
  const generic = outcome(() => h.parse(schema, text, { codec: "generic" }))
  compared++
  if (!same(generated, generic)) differences.push("decode " + type + " " + text)
  if (generic.ok) {
    const a = outcome(() => h.stringify(schema, generic.value, { style: "minimised" }))
    const b = outcome(() => h.stringify(schema, generic.value, { style: "minimised", codec: "generic" }))
    if (!same(a, b)) differences.push("encode " + type + " " + text)
  }
}
const origins = [...new Set(Object.values(m).map((s) => generatedOrigin(s) ?? "none"))]
console.log(JSON.stringify({ differences, origins, compared }))
`
  const files = readdirSync(suite).filter((f) => f.endsWith(".schema.haus"))
  it.each(files)("%s: generated when the module is built, used without eval, the same as the generic path", (file) => {
    const path = join(suite, file)
    const { code } = moduleFor(readFileSync(path, "utf8"), path, plain, builtRuntime)
    expect(code).toContain("prebuilt(schema, ")
    const dir = mkdtempSync(join(tmpdir(), "haus-codecs-"))
    writeFileSync(join(dir, "module.mjs"), code)
    writeFileSync(join(dir, "check.mjs"), check(readFileSync(path.replace(".schema.haus", ".cases.haus"), "utf8")))
    const result = JSON.parse(execFileSync(process.execPath, [join(dir, "check.mjs")], { encoding: "utf8" })) as { differences: string[]; origins: string[]; compared: number }
    expect(result.differences).toEqual([])
    expect(result.origins).toEqual(["built ahead"])
    expect(result.compared).toBeGreaterThan(0)
  })

  it("code built for other schemas is not used: the hash differs", () => {
    const dir = mkdtempSync(join(tmpdir(), "haus-codecs-"))
    writeFileSync(join(dir, "x.schema.haus"), "type Root = { n: Int }")
    const { code } = moduleFor("type Root = { n: Int }", join(dir, "x.schema.haus"), plain, builtRuntime)
    // The runtime builds `{ n: String }` from the module's text; the code was generated for `{ n: Int }`.
    const changed = code.replace(/compiled\("type Root = \{ n: Int \}"/, 'compiled("type Root = { n: String }"')
    expect(changed).not.toBe(code)
    writeFileSync(join(dir, "module.mjs"), changed)
    writeFileSync(join(dir, "check.mjs"), `
import { Root } from "./module.mjs"
import * as h from ${JSON.stringify(hausOf("@haus-fmt/haus/schema"))}
import { generatedOrigin } from ${JSON.stringify(hausOf("@haus-fmt/haus/codegen"))}
const auto = h.parse(Root, '{ n: "x" }')
const afterAuto = generatedOrigin(Root) ?? "none"
console.log(JSON.stringify([auto, afterAuto, h.parse(Root, '{ n: "x" }', { codec: "generated" }), generatedOrigin(Root) ?? "none"]))
`)
    // By default the closures, with no code generated at run time; on request, `new Function`.
    expect(JSON.parse(execFileSync(process.execPath, [join(dir, "check.mjs")], { encoding: "utf8" }))).toEqual([{ n: "x" }, "none", { n: "x" }, "new Function"])
  })
})

describe("vite plugin", () => {
  it("loads .haus files and watches their schema files", async () => {
    const plugin = haus({ target: "effect" })
    const watched: string[] = []
    const loadHook = plugin.load as (this: unknown, id: string) => Promise<{ code: string } | null>
    const ctx = { addWatchFile: (f: string) => watched.push(f) }
    expect(await loadHook.call(ctx, "/x/main.ts")).toBeNull()
    const out = await loadHook.call(ctx, `${at("thread.haus")}?import`)
    expect(out?.code).toContain('from "@haus-fmt/import/runtime/effect"')
    expect(watched).toEqual([at("thread.schema.haus")])
  })

  it("rejects an unknown target", () => {
    expect(() => haus({ target: "zod" as never })).toThrow('"plain" or "effect"')
  })
})

describe("node loader (built)", () => {
  it("imports .haus files at runtime", () => {
    const dir = mkdtempSync(join(tmpdir(), "haus-node-"))
    writeFileSync(join(dir, "data.haus"), `{ name: "Ada", total: 30.30, status: Shipped }`)
    writeFileSync(join(dir, "main.mjs"), `import data from "./data.haus"; console.log(JSON.stringify(data))`)
    const register = join(import.meta.dirname, "../dist/register/plain.js")
    const out = execFileSync(process.execPath, ["--import", pathToFileURL(register).href, join(dir, "main.mjs")], { encoding: "utf8" })
    expect(JSON.parse(out)).toEqual({ name: "Ada", total: "30.30", status: "Shipped" })
  })
})

describe("packages given explicitly", () => {
  /** A project: app/order.schema.haus (and order.haus) importing @acme/money from vendor/money and @acme/geo from the folder schemas. */
  const project = () => {
    // Real path: the files a module was built from are known by theirs.
    const root = realpathSync(mkdtempSync(join(tmpdir(), "haus-packages-")))
    const files: Record<string, string> = {
      "vendor/money/package.haus": `{ name: "@acme/money", version: "1.0.0" }`,
      "vendor/money/schema.haus": "type Money = { amount: Decimal, currency: String }",
      "schemas/geo-v1/package.haus": `{ name: "@acme/geo", version: "1.2.0" }`,
      "schemas/geo-v1/schema.haus": "type City = { name: String }",
      "app/order.schema.haus": "import @acme/money@1 (Money)\nimport @acme/geo@1 (City)\ntype Root = { total: Money, to: City }",
      "app/order.haus": `{ total: { amount: 9.50, currency: "EUR" }, to: { name: "Berlin" } }`,
    }
    for (const [path, text] of Object.entries(files)) {
      mkdirSync(dirname(join(root, path)), { recursive: true })
      writeFileSync(join(root, path), text)
    }
    return root
  }
  const given = { packages: ["vendor/money"], folders: ["schemas"] }

  for (const npm of [true, false]) {
    it(`finds them relative to the project root (npm: ${npm})`, async () => {
      const root = project()
      const b = await backend("plain", packagesOf({ ...given, npm }, root))
      const schema = join(root, "app/order.schema.haus")
      expect(typesFor(readFileSync(schema, "utf8"), schema, b).text).toContain("Money")
      const data = join(root, "app/order.haus")
      expect(typesFor(readFileSync(data, "utf8"), data, b).diagnostics).toEqual([])
      const { code, files } = moduleFor(readFileSync(data, "utf8"), data, b, runtimeOf)
      expect(files).toEqual(expect.arrayContaining([join(root, "app/order.schema.haus")]))
      const order = (await load(code)).default as { readonly total: { readonly amount: string }; readonly to: { readonly name: string } }
      expect(order.to.name).toBe("Berlin")
    })
  }

  it("without them, the imports are not found", async () => {
    const root = project()
    const b = await backend("plain", packagesOf({}, root))
    const data = join(root, "app/order.haus")
    expect(typesFor(readFileSync(data, "utf8"), data, b).diagnostics[0]?.message).toMatch(/@acme\/money/)
  })

  it("reports packages and folders that don't exist, and options that aren't paths", async () => {
    const root = project()
    await expect(backend("plain", packagesOf({ folders: ["nowhere"] }, root))).rejects.toThrow(/doesn't exist/)
    expect(() => packagesOf({ packages: "vendor/money" }, root)).toThrow(/packages must be a list of paths/)
    expect(() => haus({ npm: "yes" as never })).toThrow(/npm must be true or false/)
  })

  it("vite: relative to Vite's root", async () => {
    const root = project()
    const plugin = haus({ ...given, npm: false })
    ;(plugin.configResolved as (config: { root: string }) => void)({ root })
    const loadHook = plugin.load as (this: unknown, id: string) => Promise<{ code: string } | null>
    const watched: string[] = []
    const out = await loadHook.call({ addWatchFile: (f: string) => watched.push(f) }, join(root, "app/order.haus"))
    expect(out?.code).toContain("decodeData")
    expect(watched).toContain(join(root, "app/order.schema.haus"))
  })
})
