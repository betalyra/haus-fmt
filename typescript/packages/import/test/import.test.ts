import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"
import { describe, expect, it } from "vitest"
import { compileSchemaFile } from "@haus-fmt/haus"
import { schemaOptions } from "@haus-fmt/haus/node"
import { backend, moduleFor, optimizeOf, packagesOf, typesFor } from "../src/generate.js"
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
      // Effect: every type of the prelude can have a codec (spec §13.4), so its declaration is a Lookup.
      expect(types).toContain(target === "plain" ? "key?: h$.Secret<string>" : `key?: Redacted$.Redacted<Haus$.Lookup<C$, "prelude#String", string>>`)
      expect(types).toContain(target === "plain" ? "readonly extra: h$.Value" : `readonly extra: Haus$.Lookup<C$, "prelude#Any", Haus$.Value>`)
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

describe("generated code built ahead (plain target, optimize)", async () => {
  const suite = join(import.meta.dirname, "../../../../test-suite/schema")
  // The haus modules the generated module's runtime loads, so that the checks run against the same ones.
  // Native Node runs these modules (not Vitest), so the runtime is the built one.
  const builtRuntime = (path: string) => pathToFileURL(join(import.meta.dirname, `../dist/${path}.js`)).href
  const hausOf = (entry: string) => pathToFileURL(realpathSync(createRequire(join(import.meta.dirname, "../dist/runtime/plain.js")).resolve(entry))).href
  const imports = `
import { isDeepStrictEqual } from "node:util"
import * as m from "./module.mjs"
import * as h from ${JSON.stringify(hausOf("@haus-fmt/haus/schema"))}
import { parseAll, stringify } from ${JSON.stringify(hausOf("@haus-fmt/haus"))}
import { generatedOrigin, readerFor, withCodec } from ${JSON.stringify(hausOf("@haus-fmt/haus/codegen"))}
/** Own keys in order, all the way down: isDeepStrictEqual doesn't compare their order. */
const keys = (v) => v === null || typeof v !== "object" ? "" : v instanceof Map ? [...v].map(([k, x]) => k + keys(x)).join() : Reflect.ownKeys(v).map((k) => String(k) + "(" + keys(v[k]) + ")").join()
const outcome = (f) => { try { return { ok: true, value: f() } } catch (e) { return { ok: false, error: { name: e.name, message: e.message, code: e.code, path: e.path } } } }
const same = (a, b) => a.ok === b.ok && (a.ok ? isDeepStrictEqual(a.value, b.value) && keys(a.value) === keys(b.value) : isDeepStrictEqual(a.error, b.error))
const origin = (s) => generatedOrigin(s) ?? "none"
`
  /** Run `script` in a Node process of its own (one instance of each module) next to the module `code`; what it prints, as JSON. */
  const run = (code: string, script: string): unknown => {
    const dir = mkdtempSync(join(tmpdir(), "haus-codecs-"))
    writeFileSync(join(dir, "module.mjs"), code)
    writeFileSync(join(dir, "check.mjs"), imports + script)
    return JSON.parse(execFileSync(process.execPath, [join(dir, "check.mjs")], { encoding: "utf8" }))
  }
  /**
   * Every case of the suite decoded, and encoded again, as the module loads
   * them (every type listed in `optimize`, so marked: the code built ahead),
   * against the generic path. Prints what differs, where the generated code
   * came from, and how many cases were compared.
   */
  const check = (cases: string) => `
const differences = []
let compared = 0
for (const c of parseAll(${JSON.stringify(cases)})) {
    const f = c.args[0].fields
    const type = f.get("type").value
    const schema = m[type]
    const text = stringify(f.get("input"), { style: "minimised" })
    const generic = outcome(() => h.parse(schema, text, withCodec({}, "generic")))
    compared++
    if (!same(outcome(() => h.parse(schema, text)), generic)) differences.push("decode " + type + " " + text)
    if (generic.ok) {
      const a = outcome(() => h.stringify(schema, generic.value, { style: "minimised" }))
      const b = outcome(() => h.stringify(schema, generic.value, withCodec({ style: "minimised" }, "generic")))
      if (!same(a, b)) differences.push("encode " + type + " " + text)
    }
}
const origins = [...new Set(Object.values(m).map(origin))]
console.log(JSON.stringify({ differences, origins, compared }))
`
  /** A schema file in a fresh directory (its real path: the files a module was built from are known by theirs). */
  const schemaFile = (text: string) => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "haus-optimize-")))
    mkdirSync(join(dir, "src"))
    writeFileSync(join(dir, "src/github.schema.haus"), text)
    return { root: dir, path: join(dir, "src/github.schema.haus") }
  }
  const GITHUB = "type Issue = { title: String, user: User, labels: Array String }\ntype User = { login: String }\ntype Other = { unrelatedField: Int }"

  const files = readdirSync(suite).filter((f) => f.endsWith(".schema.haus"))
  it.each(files)("%s: built for every type, used without eval or h.optimize, the same as the generic path", async (file) => {
    const path = join(suite, file)
    const types = Object.keys(compileSchemaFile(readFileSync(path, "utf8"), schemaOptions(path)).schemas)
    const b = await backend("plain", {}, optimizeOf({ optimize: { [file]: types } }, suite))
    const { code } = moduleFor(readFileSync(path, "utf8"), path, b, builtRuntime)
    expect(code).toContain("prebuilt(schema, ")
    const result = run(code, check(readFileSync(path.replace(".schema.haus", ".cases.haus"), "utf8"))) as { differences: string[]; origins: string[]; compared: number }
    expect(result.differences).toEqual([])
    expect(result.origins).toEqual(["built ahead"])
    expect(result.compared).toBeGreaterThan(0)
  })

  it("only for the types listed (used without h.optimize) and the types they reach (with it); the others get new Function after h.optimize, the closures without", async () => {
    const { root, path } = schemaFile(GITHUB)
    const b = await backend("plain", {}, optimizeOf({ optimize: { "src/github.schema.haus": ["Issue"] } }, root))
    const { code } = moduleFor(GITHUB, path, b, builtRuntime)
    const built = code.slice(code.indexOf("prebuilt(schema, "))
    expect(built).toMatch(/^prebuilt\(schema, \["Issue"\], /)
    expect(built).toContain("login") // User, reached by Issue
    expect(built).not.toContain("unrelatedField")
    expect(run(code, `
const issue = '{ title: "t", user: { login: "ada" }, labels: ["bug"] }'
const value = h.parse(m.Issue, issue, withCodec({}, "generic"))
const optimized = h.parse(m.Issue, issue)
h.parse(m.User, '{ login: "x" }')
h.parse(m.Other, "{ unrelatedField: 1 }")
// User's code is there (reached by Issue) but not used until h.optimize marks it.
const before = [origin(m.Issue), readerFor(m.User) === readerFor(m.User, "closures") ? "closures" : "generated", origin(m.Other)]
h.optimize(m.User)
h.optimize(m.Other)
h.parse(m.User, '{ login: "x" }')
h.parse(m.Other, "{ unrelatedField: 1 }")
console.log(JSON.stringify({ before, after: [origin(m.Issue), origin(m.User), origin(m.Other)], same: same({ ok: true, value }, { ok: true, value: optimized }), text: h.stringify(m.Issue, optimized, { style: "compact" }) }))
`)).toEqual({ before: ["built ahead", "closures", "none"], after: ["built ahead", "built ahead", "new Function"], same: true, text: '{ title: "t", user: { login: "ada" }, labels: ["bug"] }' })
  })

  it("without the option, a module has no generated code", async () => {
    const { path } = schemaFile(GITHUB)
    const { code } = moduleFor(GITHUB, path, await backend("plain"), builtRuntime)
    expect(code).not.toContain("prebuilt")
    expect(code).not.toContain("function (rt, env)")
    expect(run(code, `h.optimize(m.Issue); h.parse(m.Issue, '{ title: "t", user: { login: "a" }, labels: [] }'); console.log(JSON.stringify(origin(m.Issue)))`)).toBe("new Function")
  })

  it("code built for other schemas is not used: the source differs", async () => {
    const { root, path } = schemaFile("type Root = { n: Int }")
    const b = await backend("plain", {}, optimizeOf({ optimize: { "src/github.schema.haus": ["Root"] } }, root))
    const { code } = moduleFor("type Root = { n: Int }", path, b, builtRuntime)
    // The runtime builds `{ n: String }` from the module's text; the code was generated for `{ n: Int }`.
    const changed = code.replace(/compiled\("type Root = \{ n: Int \}"/, 'compiled("type Root = { n: String }"')
    expect(changed).not.toBe(code)
    // Root is marked as the module loads; the code built ahead is not it, so `new Function`.
    expect(run(changed, `console.log(JSON.stringify([h.parse(m.Root, '{ n: "x" }'), origin(m.Root)]))`)).toEqual([{ n: "x" }, "new Function"])
  })

  it("reports schema files and types that don't exist, a wrong shape, and the Effect target", async () => {
    const { root } = schemaFile(GITHUB + "\ntype Box a = { item: a }")
    const at = (optimize: unknown) => optimizeOf({ optimize }, root)
    await expect(backend("plain", {}, at({ "src/nope.schema.haus": ["Issue"] }))).rejects.toThrow(/optimize: the schema file src\/nope\.schema\.haus doesn't exist/)
    await expect(backend("plain", {}, at({ "src/github.schema.haus": ["Issues"] }))).rejects.toThrow(/optimize: src\/github\.schema\.haus has no type Issues/)
    await expect(backend("plain", {}, at({ "src/github.schema.haus": ["Box"] }))).rejects.toThrow(/Box has type parameters/)
    await expect(backend("effect", {}, at({ "src/github.schema.haus": ["Issue"] }))).rejects.toThrow(/optimize is for the plain target/)
    expect(() => at(["Issue"])).toThrow(/optimize must map schema files to lists of type names/)
    expect(() => haus({ optimize: { "src/github.schema.haus": "Issue" } as never })).toThrow(/optimize must map/)
  })

  it("vite: relative to Vite's root", async () => {
    const { root, path } = schemaFile(GITHUB)
    const plugin = haus({ optimize: { "src/github.schema.haus": ["Issue"] } })
    ;(plugin.configResolved as (config: { root: string }) => void)({ root })
    const loadHook = plugin.load as (this: unknown, id: string) => Promise<{ code: string } | null>
    const out = await loadHook.call({ addWatchFile: () => undefined }, path)
    expect(out?.code).toContain('prebuilt(schema, ["Issue"], ')
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
