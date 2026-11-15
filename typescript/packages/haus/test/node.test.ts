import { mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { describe, expect, it } from "vitest"
import { HausSchemaFileError, parseSchemaFile } from "../src/index.js"
import { identify, isSchemaFile, schemaOptions } from "../src/node.js"

/** A directory with these files (paths relative to it). */
const tree = (files: Record<string, string>): string => {
  const root = mkdtempSync(join(tmpdir(), "haus-node-"))
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true })
    writeFileSync(join(root, path), text)
  }
  return root
}

const SECRET = "API_TOKEN=hunter2"
const money = "type Money = closed < Money Decimal Currency >\ntype Currency = < >"
const manifest = (name: string) => `{ name: "${name}", version: "1.2.0" }`
const PKG = "app/node_modules/@acme/evil"

/** An app (app/main.schema.haus with `main`) and `files` around it; secret/ must never be read. */
const app = (files: Record<string, string>, main = "import @acme/evil (Money)\ntype Root = { m: Money }") =>
  tree({ "secret/creds.txt": SECRET, "secret/creds.schema.haus": SECRET, "app/main.schema.haus": main, ...files })

const load = (root: string) => {
  const path = join(root, "app/main.schema.haus")
  return parseSchemaFile(readFileSync(path, "utf8"), schemaOptions(path))
}

const rejected = (root: string, code = "package-path"): string => {
  try {
    load(root)
  } catch (e) {
    if (!(e instanceof HausSchemaFileError)) throw e
    expect(e.code).toBe(code)
    expect(e.message).not.toContain("API_TOKEN")
    expect(e.message).not.toContain("hunter2")
    return e.message
  }
  throw new Error("accepted")
}

describe("node resolver: a package is package.haus and schema.haus (spec §13.3)", () => {
  it("imports a package's schema.haus, with the id from its manifest", () => {
    const root = app({ [`${PKG}/package.haus`]: manifest("@acme/evil"), [`${PKG}/schema.haus`]: money })
    expect(load(root).imported.get("Money")?.id).toBe("@acme/evil@1#Money")
    expect(identify(join(root, PKG, "schema.haus"))).toBe("@acme/evil@1")
  })

  it("ignores other manifest fields, a former `schema` among them", () => {
    const root = app({
      [`${PKG}/package.haus`]: `{ name: "@acme/evil", version: "1.2.0", schema: "../../../../secret/creds.txt", description: "x" }`,
      [`${PKG}/schema.haus`]: money,
    })
    expect(load(root).imported.get("Money")?.id).toBe("@acme/evil@1#Money")
  })

  it("rejects a package without schema.haus", () => {
    const root = app({ [`${PKG}/package.haus`]: manifest("@acme/evil") })
    expect(rejected(root, "import-not-found")).toMatch(/has no schema.haus/)
  })

  it("rejects a schema.haus that is a symbolic link to a file outside the package", () => {
    const root = app({ [`${PKG}/package.haus`]: manifest("@acme/evil") })
    symlinkSync(join(root, "secret/creds.schema.haus"), join(root, PKG, "schema.haus"))
    expect(rejected(root)).toMatch(/schema.haus is a symbolic link to a file outside the package/)
  })

  it("rejects a manifest that is a symbolic link to a file outside the package", () => {
    const root = app({ [`${PKG}/schema.haus`]: money })
    symlinkSync(join(root, "secret/creds.txt"), join(root, PKG, "package.haus"))
    expect(rejected(root)).toMatch(/the manifest .* is a symbolic link/)
  })

  it("follows symbolic links to the package directory (pnpm) and inside it", () => {
    const root = app({ "store/evil/package.haus": manifest("@acme/evil"), "store/evil/real.haus": money })
    symlinkSync(join(root, "store/evil/real.haus"), join(root, "store/evil/schema.haus"))
    mkdirSync(join(root, "app/node_modules/@acme"), { recursive: true })
    symlinkSync(join(root, "store/evil"), join(root, PKG))
    expect(load(root).imported.get("Money")?.id).toBe("@acme/evil@1#Money")
  })

  it("rejects relative imports in a package's schema", () => {
    for (const imp of ["./money", "../../../../secret/creds"]) {
      const root = app({
        [`${PKG}/package.haus`]: manifest("@acme/evil"),
        [`${PKG}/schema.haus`]: `import ${imp} (Money)\ntype M = Money`,
        [`${PKG}/money.schema.haus`]: money,
      })
      expect(rejected(root)).toMatch(/the schema of @acme\/evil can't import files, only packages by name/)
    }
  })

  it("rejects relative imports of app files into a package directory, also through links", () => {
    const vendor = "app/vendor/evil"
    const files = { [`${vendor}/package.haus`]: manifest("@acme/evil"), [`${vendor}/schema.haus`]: money, [`${vendor}/sub/extra.schema.haus`]: money }
    const direct = app(files, "import ./vendor/evil/sub/extra (Money)\ntype Root = Money")
    expect(rejected(direct)).toMatch(/is in the package directory .*: import the package by its name/)
    const linked = app(files, "import ./link/extra (Money)\ntype Root = Money")
    symlinkSync(join(linked, vendor, "sub"), join(linked, "app/link"))
    expect(rejected(linked)).toMatch(/is in the package directory/)
  })

  it("keeps relative imports of app files, always to .schema.haus files", () => {
    const root = app({ "shared/money.schema.haus": money }, "import ../shared/money (Money)\ntype Root = { m: Money }")
    expect(load(root).imported.get("Money")).toBeDefined()
    // The extension is always added: `./x.schema.haus` is x.schema.haus.schema.haus.
    const twice = app({ "shared/money.schema.haus": money }, "import ../shared/money.schema.haus (Money)\ntype Root = Money")
    expect(rejected(twice, "import-not-found")).toMatch(/money.schema.haus.schema.haus/)
  })

  it("knows schema files by name", () => {
    const names = ["a/order.schema.haus", "a/schema.haus", "a/package.haus", "a/x.haus"]
    expect(names.map(isSchemaFile)).toEqual([true, true, false, false])
  })
})

describe("import versions (spec §13.3)", () => {
  it.each(["1.1", "1.1.0", "01", "x", ""])("@%s is import-version, with a hint", (v) => {
    try {
      parseSchemaFile(`import @haus-fmt/money@${v} (Money)\ntype A = Money`)
      throw new Error("accepted")
    } catch (e) {
      expect(e).toBeInstanceOf(HausSchemaFileError)
      expect((e as HausSchemaFileError).code).toBe("import-version")
      if (v === "1.1") {
        expect((e as HausSchemaFileError).message).toContain("(@haus-fmt/money@1)")
        expect((e as HausSchemaFileError).hint).toContain("dependency range")
      }
    }
  })
})
