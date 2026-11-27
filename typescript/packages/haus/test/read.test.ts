/**
 * Reading from the file system (packages.md §2, "Reading is separate from
 * compiling"): `readSources`, `readPackage`, `readPackages`. What the package
 * suite doesn't check: each file read once, a relative import that can't be
 * read reported at the import when compiling, file ids, no lookup.
 */
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { describe, expect, it } from "vitest"
import { Result, Schema, type HausError } from "../src/haus.js"
import { readPackage, readPackages, readSources } from "../src/node.js"

const tree = (files: Readonly<Record<string, string>>): string => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "haus-read-")))
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true })
    writeFileSync(join(root, path), text)
  }
  return root
}

const ok = <A>(r: Result<A, HausError>): A => {
  if (r._tag === "Failure") throw new Error(r.failure.message)
  return r.success
}

describe("readSources", () => {
  it("reads the entry file and its relative imports, each once, as plain data", async () => {
    const root = tree({
      "app/order.schema.haus": "import ./common (Address)\nimport ./more (Note)\ntype Root = { to: Address, note: Note }",
      "app/common.schema.haus": "type Address = { city: String }",
      "app/more.schema.haus": "import ./common (Address)\ntype Note = { at: Address }",
    })
    const opened: string[] = []
    const sources = ok(await readSources(join(root, "app/order.schema.haus"), { onOpen: (p) => opened.push(p) }))
    expect(sources.entry).toBe("order.schema.haus")
    expect([...sources.files.keys()].sort()).toEqual(["common.schema.haus", "more.schema.haus", "order.schema.haus"])
    expect(opened.sort()).toEqual(["common", "more", "order"].map((n) => join(root, "app", `${n}.schema.haus`)))
    const schema = ok(Schema.compile(sources))
    // A file's id is its path from the build's root (spec §13.3, "Identity").
    expect(schema.file.typeIds.has("common#Address")).toBe(true)
  })

  it("a relative import it can't read is reported at the import when compiling", async () => {
    const root = tree({ "order.schema.haus": "type A = Int\nimport ../outside (X)\n" })
    const sources = ok(await readSources(join(root, "order.schema.haus")))
    const compiled = Schema.compile(sources)
    expect(compiled._tag).toBe("Failure")
    const e = (compiled as Extract<typeof compiled, { _tag: "Failure" }>).failure
    expect(e.code).toBe("import-outside-root")
    expect("line" in e && e.line).toBe(2)
  })

  it("never looks for a package: one not given is import-not-found, even in node_modules beside it", async () => {
    const root = tree({
      "order.schema.haus": "import @acme/ids (Id)\ntype Root = { id: Id }",
      "node_modules/@acme/ids/package.haus": `{ name: "@acme/ids", version: "1.0.0" }`,
      "node_modules/@acme/ids/schema.haus": "type Id = String",
      "package.json": `{ "name": "app", "dependencies": { "@acme/ids": "1.0.0" } }`,
    })
    const compiled = Result.flatMap(await readSources(join(root, "order.schema.haus")), Schema.compile)
    expect(compiled._tag === "Failure" && compiled.failure.code).toBe("import-not-found")
    // Given explicitly, it is used.
    const given = Result.flatMap(await readSources(join(root, "order.schema.haus"), { packages: [join(root, "node_modules/@acme/ids")] }), Schema.compile)
    expect(ok(given).packages.has("@acme/ids")).toBe(true)
  })
})

describe("readPackage and readPackages", () => {
  it("give package values with the rule documents they have", async () => {
    const root = tree({
      "codes/package.haus": `{ name: "@acme/codes", version: "1.2.0", rules: { "Code": "iso" } }`,
      "codes/schema.haus": "type Code = < >",
      "codes/rules/iso.md": "three capitals",
      "folder/a/package.haus": `{ name: "@acme/a", version: "1.0.0" }`,
      "folder/a/schema.haus": "type A = Int",
      "folder/broken/package.haus": "not a manifest",
    })
    const codes = ok(await readPackage(join(root, "codes")))
    expect([codes.name, codes.version, [...(codes.documents ?? [])]]).toEqual(["@acme/codes", "1.2.0", ["iso"]])
    const folder = ok(await readPackages(join(root, "folder")))
    expect(folder.packages.map((p) => p.name)).toEqual(["@acme/a"])
    expect(folder.skipped).toEqual([expect.stringContaining("folder/broken")])
    const missing = await readPackage(join(root, "nowhere"))
    expect(missing._tag === "Failure" && missing.failure.code).toBe("import-not-found")
  })
})
