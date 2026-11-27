import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"
import { describe, expect, it } from "vitest"
import { Schema, type Schema as SchemaValue } from "@haus-fmt/haus/internal"
import { readSourcesSync } from "@haus-fmt/haus/node"
import { backend, moduleFor, optimizeOf, packagesOf, typesFor } from "../src/generate.js"
import haus from "../src/vite.js"

const examples = join(import.meta.dirname, "../../../../examples")
const at = (name: string) => join(examples, name)
const read = (name: string) => readFileSync(at(name), "utf8")
const runtimeOf = (path: string) => pathToFileURL(join(import.meta.dirname, `../src/${path}.ts`)).href
const none = (root = process.cwd()) => packagesOf({}, root)

/** Load generated module code as a real ES module. */
const load = async (code: string) => {
  const file = join(mkdtempSync(join(tmpdir(), "haus-import-")), "module.mjs")
  writeFileSync(file, code)
  return (await import(pathToFileURL(file).href)) as Record<string, unknown>
}

describe("plain target", async () => {
  const plain = await backend("plain", none())

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

  it("schema files: types, handles and the compiled schema", async () => {
    const types = typesFor(read("thread.schema.haus"), at("thread.schema.haus"), plain)
    expect(types.text).toContain("export declare const Comment: h$.Type<Comment$, ")
    expect(types.text).toContain("export declare const schema: import(")
    expect(types.text).not.toContain("effect")
    const { code } = moduleFor(read("thread.schema.haus"), at("thread.schema.haus"), plain, runtimeOf)
    expect(code).not.toContain("effect")
    expect(code).not.toContain(examples)
    const m = (await load(code)) as { schema: SchemaValue; Root: never }
    const thread = Schema.decode(m.schema, m.Root, read("thread.haus"))
    expect(thread._tag).toBe("Success")
  })

  it("the official packages are built in: order.schema.haus imports @haus-fmt/money and @haus-fmt/geo with no option", async () => {
    const { code } = moduleFor(read("order.schema.haus"), at("order.schema.haus"), plain, runtimeOf)
    const m = (await load(code)) as { schema: SchemaValue; Root: never }
    expect([...m.schema.packages.keys()]).toEqual(["@haus-fmt/geo", "@haus-fmt/money"])
    // Their rules are on: Eur is not a currency of the rule iso.
    const decoded = Schema.decode(m.schema, m.Root, read("order.haus").replace("EUR", "Eur"))
    expect(decoded._tag === "Failure" && decoded.failure.code).toBe("codec-rejected")
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

describe("Secret, Any and attributes (plain target)", async () => {
  const SECRET = "hunter2-ZQXJ9WVK"
  const schema = `type Root = { name: String, @deprecated("use token") key?: Secret String, token?: Secret String, extra: Any }`
  const files = (data: string) => {
    const dir = mkdtempSync(join(tmpdir(), "haus-secret-"))
    writeFileSync(join(dir, "x.schema.haus"), schema)
    writeFileSync(join(dir, "x.haus"), data)
    return { schema: join(dir, "x.schema.haus"), data: join(dir, "x.haus") }
  }
  const good = `{ name: "a", key: "${SECRET}", extra: Order { id: 1 } }`
  const bad = `{\n  name: "a",\n  key: 98765432,\n  extra: 1,\n}`

  it("declarations, decoding and errors without the value", async () => {
    const b = await backend("plain", none())
    const { schema: schemaPath, data } = files(good)
    const types = typesFor(schema, schemaPath, b).text
    expect(types).toContain(`key?: h$.Secret<h$.Host<H$, "prelude#String", string>>`)
    expect(types).toContain(`readonly extra: h$.Host<H$, "prelude#Any", h$.Value>`)
    expect(types).toContain("/** @deprecated use token */ readonly key?:")
    const root = (await load(moduleFor(good, data, b, runtimeOf).code)).default as { key: unknown; extra: { kind: string } }
    expect(String(root.key)).toBe("<redacted>")
    expect(JSON.stringify(root)).not.toContain(SECRET)
    expect(root.extra.kind).toBe("variant")
    const wrong = files(bad)
    expect(typesFor(bad, wrong.data, b).diagnostics.map((d) => d.message)).toEqual(["expected String (a Secret: the value is not shown) (x.schema.haus: Root)"])
    const failed = await load(moduleFor(bad, wrong.data, b, runtimeOf).code).then(() => "loaded", (e: Error) => e.message)
    expect(failed).toMatch(/^x\.haus:3:\d+: expected String \(a Secret: the value is not shown\)/)
    expect(failed).not.toContain("98765432")
  })
})

describe("generated code built ahead (plain target, optimize)", async () => {
  const suite = join(import.meta.dirname, "../../../../test-suite/schema")
  // Native Node runs these modules (not Vitest), so the runtime is the built one.
  const builtRuntime = (path: string) => pathToFileURL(join(import.meta.dirname, `../dist/${path}.js`)).href
  const hausOf = (entry: string) => pathToFileURL(realpathSync(createRequire(join(import.meta.dirname, "../dist/runtime/plain.js")).resolve(entry))).href
  const imports = `
import { isDeepStrictEqual } from "node:util"
import * as m from "./module.mjs"
import { h, parseAll, stringify } from ${JSON.stringify(hausOf("@haus-fmt/haus/internal"))}
import { generatedOrigin, readerFor, withCodec } from ${JSON.stringify(hausOf("@haus-fmt/haus/codegen"))}
const engine = m.schema.engine().schemas
const keys = (v) => v === null || typeof v !== "object" ? "" : v instanceof Map ? [...v].map(([k, x]) => k + keys(x)).join() : Reflect.ownKeys(v).map((k) => String(k) + "(" + keys(v[k]) + ")").join()
const outcome = (f) => { try { return { ok: true, value: f() } } catch (e) { return { ok: false, error: { name: e.name, message: e.message, code: e.code, path: e.path } } } }
const same = (a, b) => a.ok === b.ok && (a.ok ? isDeepStrictEqual(a.value, b.value) && keys(a.value) === keys(b.value) : isDeepStrictEqual(a.error, b.error))
const origin = (s) => generatedOrigin(s) ?? "none"
const reveal = { revealSecrets: true }
`
  const run = (code: string, script: string): unknown => {
    const dir = mkdtempSync(join(tmpdir(), "haus-codecs-"))
    writeFileSync(join(dir, "module.mjs"), code)
    writeFileSync(join(dir, "check.mjs"), imports + script)
    return JSON.parse(execFileSync(process.execPath, [join(dir, "check.mjs")], { encoding: "utf8" }))
  }
  /** Every case decoded and encoded again with the code built ahead, against the generic path. */
  const check = (cases: string) => `
const differences = []
let compared = 0
for (const c of parseAll(${JSON.stringify(cases)})) {
    const f = c.args[0].fields
    const type = f.get("type").value
    const schema = engine[type]
    const text = stringify(f.get("input"), { style: "minimised" })
    const generic = outcome(() => h.parse(schema, text, withCodec({}, "generic")))
    compared++
    if (!same(outcome(() => h.parse(schema, text)), generic)) differences.push("decode " + type + " " + text)
    if (generic.ok) {
      const a = outcome(() => h.stringify(schema, generic.value, { style: "minimised", ...reveal }))
      const b = outcome(() => h.stringify(schema, generic.value, withCodec({ style: "minimised", ...reveal }, "generic")))
      if (!same(a, b)) differences.push("encode " + type + " " + text)
    }
}
const origins = [...new Set(Object.values(engine).map(origin))]
console.log(JSON.stringify({ differences, origins, compared }))
`
  const schemaFile = (text: string) => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "haus-optimize-")))
    mkdirSync(join(dir, "src"))
    writeFileSync(join(dir, "src/github.schema.haus"), text)
    return { root: dir, path: join(dir, "src/github.schema.haus") }
  }
  const GITHUB = "type Issue = { title: String, user: User, labels: Array String }\ntype User = { login: String }\ntype Other = { unrelatedField: Int }"

  const files = readdirSync(suite).filter((f) => f.endsWith(".schema.haus"))
  it.each(files)("%s: built for every type, used without eval, the same as the generic path", async (file) => {
    const path = join(suite, file)
    const sources = readSourcesSync(path)
    const compiled = sources._tag === "Success" ? Schema.compile(sources.success) : sources
    if (compiled._tag === "Failure") throw compiled.failure
    const types = compiled.success.file.definitions.filter((d) => d.params.length === 0).map((d) => d.name)
    const b = await backend("plain", none(suite), optimizeOf({ optimize: { [file]: types } }, suite))
    const { code } = moduleFor(readFileSync(path, "utf8"), path, b, builtRuntime)
    expect(code).toContain("prebuilt(schema, ")
    const result = run(code, check(readFileSync(path.replace(".schema.haus", ".cases.haus"), "utf8"))) as { differences: string[]; origins: string[]; compared: number }
    expect(result.differences).toEqual([])
    expect(result.origins).toEqual(["built ahead"])
    expect(result.compared).toBeGreaterThan(0)
  })

  it("only for the types listed and the types they reach", async () => {
    const { root, path } = schemaFile(GITHUB)
    const b = await backend("plain", none(root), optimizeOf({ optimize: { "src/github.schema.haus": ["Issue"] } }, root))
    const { code } = moduleFor(GITHUB, path, b, builtRuntime)
    const built = code.slice(code.indexOf("prebuilt(schema, "))
    expect(built).toMatch(/^prebuilt\(schema, \["Issue"\], /)
    expect(built).toContain("login") // User, reached by Issue
    expect(built).not.toContain("unrelatedField")
    expect(run(code, `
const issue = '{ title: "t", user: { login: "ada" }, labels: ["bug"] }'
const value = h.parse(engine.Issue, issue, withCodec({}, "generic"))
const optimized = h.parse(engine.Issue, issue)
h.parse(engine.User, '{ login: "x" }')
const before = [origin(engine.Issue), readerFor(engine.User) === readerFor(engine.User, "closures") ? "closures" : "generated", origin(engine.Other)]
h.optimize(engine.User)
h.optimize(engine.Other)
h.parse(engine.User, '{ login: "x" }')
h.parse(engine.Other, "{ unrelatedField: 1 }")
console.log(JSON.stringify({ before, after: [origin(engine.Issue), origin(engine.User), origin(engine.Other)], same: same({ ok: true, value }, { ok: true, value: optimized }) }))
`)).toEqual({ before: ["built ahead", "closures", "none"], after: ["built ahead", "built ahead", "new Function"], same: true })
  })

  it("without the option, a module has no generated code", async () => {
    const { root, path } = schemaFile(GITHUB)
    const { code } = moduleFor(GITHUB, path, await backend("plain", none(root)), builtRuntime)
    expect(code).not.toContain("prebuilt")
    expect(run(code, `h.optimize(engine.Issue); h.parse(engine.Issue, '{ title: "t", user: { login: "a" }, labels: [] }'); console.log(JSON.stringify(origin(engine.Issue)))`)).toBe("new Function")
  })

  it("code built for other schemas is not used: the source differs", async () => {
    const { root, path } = schemaFile("type Root = { n: Int }")
    const b = await backend("plain", none(root), optimizeOf({ optimize: { "src/github.schema.haus": ["Root"] } }, root))
    const { code } = moduleFor("type Root = { n: Int }", path, b, builtRuntime)
    const changed = code.replace(`"type Root = { n: Int }"`, `"type Root = { n: String }"`)
    expect(changed).not.toBe(code)
    expect(run(changed, `console.log(JSON.stringify([h.parse(engine.Root, '{ n: "x" }'), origin(engine.Root)]))`)).toEqual([{ n: "x" }, "new Function"])
  })

  it("reports schema files and types that don't exist, a wrong shape, and the Effect target", async () => {
    const { root } = schemaFile(GITHUB + "\ntype Box a = { item: a }")
    const opt = (optimize: unknown) => optimizeOf({ optimize }, root)
    await expect(backend("plain", none(root), opt({ "src/nope.schema.haus": ["Issue"] }))).rejects.toThrow(/optimize: the schema file src\/nope\.schema\.haus doesn't exist/)
    await expect(backend("plain", none(root), opt({ "src/github.schema.haus": ["Issues"] }))).rejects.toThrow(/optimize: src\/github\.schema\.haus has no type Issues/)
    await expect(backend("plain", none(root), opt({ "src/github.schema.haus": ["Box"] }))).rejects.toThrow(/Box has type parameters/)
    await expect(backend("effect", none(root), opt({ "src/github.schema.haus": ["Issue"] }))).rejects.toThrow(/optimize is for the plain target/)
    expect(() => opt(["Issue"])).toThrow(/optimize must map schema files to lists of type names/)
  })
})

describe("vite plugin", () => {
  it("loads .haus files and watches their schema files", async () => {
    const plugin = haus({})
    const watched: string[] = []
    const loadHook = plugin.load as (this: unknown, id: string) => Promise<{ code: string } | null>
    const ctx = { addWatchFile: (f: string) => watched.push(f) }
    expect(await loadHook.call(ctx, "/x/main.ts")).toBeNull()
    const out = await loadHook.call(ctx, `${at("thread.haus")}?import`)
    expect(out?.code).toContain('from "@haus-fmt/import/runtime/plain"')
    expect(watched).toEqual([at("thread.schema.haus")])
  })

  it("rejects an unknown target, and the npm option that is gone", () => {
    expect(() => haus({ target: "zod" as never })).toThrow('"plain" or "effect"')
    expect(() => haus({ npm: true } as never)).toThrow(/the npm option is gone/)
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

describe("packages given explicitly, and bundles", () => {
  /** A project: app/order.schema.haus importing @acme/money from vendor/money and @acme/geo from the folder schemas. */
  const project = () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "haus-packages-")))
    const files: Record<string, string> = {
      "vendor/money/package.haus": `{ name: "@acme/money", version: "1.0.0" }`,
      "vendor/money/schema.haus": "type Money = { amount: Decimal, currency: String }",
      "schemas/geo-v1/package.haus": `{ name: "@acme/geo", version: "1.2.0" }`,
      "schemas/geo-v1/schema.haus": "type City = { name: String }",
      "app/order.schema.haus": "import @acme/money@1 (Money)\nimport @acme/geo@1 (City)\ntype Root = { total: Money, to: City }",
      "app/order.haus": `{ total: { amount: 9.50, currency: "EUR" }, to: { name: "Berlin" } }`,
      // A library publishing @acme/ids as a bundle, with its rule.
      "package.json": `{ "name": "app", "type": "module" }`,
      "node_modules/acme-ids/package.json": `{ "name": "acme-ids", "type": "module", "exports": "./index.js" }`,
      "node_modules/acme-ids/index.js": `import { Package, Result } from ${JSON.stringify(pathToFileURL(join(import.meta.dirname, "../../haus/dist/haus.js")).href)}
const made = Package.make({ manifest: '{ name: "@acme/ids", version: "1.0.0", rules: { "Id": "ulid" } }', schema: "type Id = String", rules: { Id: (s) => (/^[0-9A-Z]{26}$/.test(s) ? Result.succeed(s) : Result.fail("not a ULID")) } })
export default made.success
`,
      "app/user.schema.haus": "import @acme/ids (Id)\ntype Root = { id: Id }",
      "app/user.haus": `{ id: "01ARZ3NDEKTSV4RRFFQ69G5FAV" }`,
    }
    for (const [path, text] of Object.entries(files)) {
      mkdirSync(dirname(join(root, path)), { recursive: true })
      writeFileSync(join(root, path), text)
    }
    return root
  }
  const given = { packages: ["vendor/money"], folders: ["schemas"] }

  it("finds packages and folders relative to the project root", async () => {
    const root = project()
    const b = await backend("plain", packagesOf(given, root))
    const schema = join(root, "app/order.schema.haus")
    expect(typesFor(readFileSync(schema, "utf8"), schema, b).text).toContain("Money")
    const data = join(root, "app/order.haus")
    expect(typesFor(readFileSync(data, "utf8"), data, b).diagnostics).toEqual([])
    const { code, files } = moduleFor(readFileSync(data, "utf8"), data, b, runtimeOf)
    expect(files).toEqual(expect.arrayContaining([join(root, "app/order.schema.haus")]))
    const order = (await load(code)).default as { readonly to: { readonly name: string } }
    expect(order.to.name).toBe("Berlin")
  })

  it("never looks in node_modules: without them the imports are not found", async () => {
    const root = project()
    const b = await backend("plain", packagesOf({}, root))
    const data = join(root, "app/order.haus")
    expect(typesFor(readFileSync(data, "utf8"), data, b).diagnostics[0]?.message).toMatch(/@acme\/money/)
    const user = join(root, "app/user.haus")
    expect(typesFor(readFileSync(user, "utf8"), user, b).diagnostics[0]?.message).toMatch(/@acme\/ids/)
  })

  it("a bundle is imported as the program imports it, with its rules", async () => {
    const root = project()
    const b = await backend("plain", packagesOf({ bundles: ["acme-ids"] }, root))
    const user = join(root, "app/user.haus")
    expect(typesFor(readFileSync(user, "utf8"), user, b).diagnostics).toEqual([])
    const { code } = moduleFor(readFileSync(user, "utf8"), user, b, runtimeOf)
    expect(code).toContain(`import b0 from "acme-ids"`)
    await expect(backend("plain", packagesOf({ bundles: ["not-installed"] }, root))).rejects.toThrow(/can't be imported/)
  })

  it("reports packages and folders that don't exist, and options that aren't paths", async () => {
    const root = project()
    await expect(backend("plain", packagesOf({ folders: ["nowhere"] }, root))).rejects.toThrow(/doesn't exist/)
    expect(() => packagesOf({ packages: "vendor/money" }, root)).toThrow(/packages must be a list of paths/)
  })

  it("vite: relative to Vite's root", async () => {
    const root = project()
    const plugin = haus(given)
    ;(plugin.configResolved as (config: { root: string }) => void)({ root })
    const loadHook = plugin.load as (this: unknown, id: string) => Promise<{ code: string } | null>
    const watched: string[] = []
    const out = await loadHook.call({ addWatchFile: (f: string) => watched.push(f) }, join(root, "app/order.haus"))
    expect(out?.code).toContain("decodeData")
    expect(watched).toContain(join(root, "app/order.schema.haus"))
  })
})
