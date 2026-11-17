import { execFileSync } from "node:child_process"
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { describe, expect, it } from "vitest"
import { HausSchemaFileError, ModuleError, parseSchemaFile } from "../src/index.js"
import { identify, isSchemaFile, nodeResolver, schemaOptions } from "../src/node.js"
import { quoteText } from "../src/schema-file.js"

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

/** An app (app/main.schema.haus with `main`, declaring @acme/evil) and `files` around it; secret/ must never be read. */
const app = (files: Record<string, string>, main = "import @acme/evil (Money)\ntype Root = { m: Money }") =>
  tree({
    "secret/creds.txt": SECRET,
    "secret/creds.schema.haus": SECRET,
    "app/package.json": JSON.stringify({ name: "app", dependencies: { "@acme/evil": "*" } }),
    "app/main.schema.haus": main,
    ...files,
  })

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
    expect(rejected(root)).toMatch(/its schema.haus .* is a symbolic link/)
  })

  it("rejects a manifest that is a symbolic link to a file outside the package", () => {
    const root = app({ [`${PKG}/schema.haus`]: money })
    symlinkSync(join(root, "secret/creds.txt"), join(root, PKG, "package.haus"))
    expect(rejected(root)).toMatch(/the manifest .* is a symbolic link/)
  })

  it("follows a symbolic link to the package directory (pnpm), never one to a package's file", () => {
    const root = app({ "store/evil/package.haus": manifest("@acme/evil"), "store/evil/schema.haus": money })
    mkdirSync(join(root, "app/node_modules/@acme"), { recursive: true })
    symlinkSync(join(root, "store/evil"), join(root, PKG))
    expect(load(root).imported.get("Money")?.id).toBe("@acme/evil@1#Money")
    // schema.haus a link inside the package: not read either (spec §13.3).
    const inside = app({ "store/evil/package.haus": manifest("@acme/evil"), "store/evil/real.haus": money })
    symlinkSync(join(inside, "store/evil/real.haus"), join(inside, "store/evil/schema.haus"))
    mkdirSync(join(inside, "app/node_modules/@acme"), { recursive: true })
    symlinkSync(join(inside, "store/evil"), join(inside, PKG))
    expect(rejected(inside)).toMatch(/its schema.haus .* is a symbolic link/)
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

describe("package names in imports are lowercase (spec §13.3)", () => {
  it.each(["@Acme/x", "@acme/X", "@acme/.x", "@-acme/x"])("%s is unknown-module", (name) => {
    try {
      parseSchemaFile(`import ${name} (X)\ntype A = X`)
      throw new Error("accepted")
    } catch (e) {
      expect(e).toBeInstanceOf(HausSchemaFileError)
      expect((e as HausSchemaFileError).code).toBe("unknown-module")
    }
  })
})

describe("node resolver options", () => {
  const vendored = () =>
    tree({
      "app/main.schema.haus": "import @acme/evil (Money)\ntype Root = { m: Money }",
      "vendor/evil/package.haus": manifest("@acme/evil"),
      "vendor/evil/schema.haus": money,
    })
  const loadWith = (root: string, options: Parameters<typeof schemaOptions>[1]) => {
    const path = join(root, "app/main.schema.haus")
    return parseSchemaFile(readFileSync(path, "utf8"), schemaOptions(path, options))
  }

  it("takes packages by name (the older form), by directory, and folders of packages", () => {
    const root = vendored()
    for (const options of [{ packages: { "@acme/evil": join(root, "vendor/evil") } }, { packages: [join(root, "vendor/evil")] }, { folders: [join(root, "vendor")] }]) {
      expect(loadWith(root, options).imported.get("Money")?.id).toBe("@acme/evil@1#Money")
    }
    // Relative to the root file's directory.
    expect(loadWith(root, { packages: ["../vendor/evil"] }).imported.get("Money")?.id).toBe("@acme/evil@1#Money")
  })

  it("says when a package given by name holds another package", () => {
    const root = vendored()
    expect(() => loadWith(root, { packages: { "@acme/evil": join(root, "app") } })).toThrow(/is not a schema package/)
    writeFileSync(join(root, "vendor/evil/package.haus"), manifest("@acme/other"))
    expect(() => loadWith(root, { packages: { "@acme/evil": join(root, "vendor/evil") } })).toThrow(/holds the package @acme\/other, not @acme\/evil/)
  })

  it("reads a manifest again when it changes (a long-running language server)", () => {
    const root = vendored()
    const options = { packages: [join(root, "vendor/evil")] }
    expect(() => loadWith(root, options)).not.toThrow()
    writeFileSync(join(root, "vendor/evil/package.haus"), `{ name: "@acme/evil", version: "2.10.0" }`)
    const path = join(root, "app/main.schema.haus")
    writeFileSync(path, "import @acme/evil@1 (Money)\ntype Root = { m: Money }")
    expect(() => loadWith(root, options)).toThrow(/wants major version 1, but version 2.10.0 was found/)
  })
})

describe("files and limits (spec §13.3)", () => {
  const pkg = (files: Record<string, string>) => app({ [`${PKG}/package.haus`]: manifest("@acme/evil"), [`${PKG}/schema.haus`]: money, ...files })

  it("doesn't read a schema file or package.json larger than 1 MiB", () => {
    const big = `// ${"x".repeat(1024 * 1024)}\n`
    expect(rejected(pkg({ [`${PKG}/schema.haus`]: big + money }), "file-too-large")).not.toContain("xxxx")
    expect(rejected(pkg({ [`${PKG}/package.json`]: `{ "version": "1.2.0", "x": "${"x".repeat(1024 * 1024)}" }` }), "file-too-large")).toContain("package.json")
    expect(rejected(app({ "app/big.schema.haus": big + money }, "import ./big (Money)\ntype Root = Money"), "file-too-large")).toContain("big.schema.haus")
  })

  // Unix only: no FIFOs, and no write permission for everyone, on Windows.
  it.skipIf(process.platform === "win32")("doesn't open a FIFO as a package file, and doesn't block on it", () => {
    const root = pkg({})
    unlinkSync(join(root, PKG, "schema.haus"))
    execFileSync("mkfifo", [join(root, PKG, "schema.haus")])
    expect(rejected(root)).toMatch(/its schema.haus .* is not a regular file/)
  })

  it("counts schema files: at most 256, the root included", () => {
    const chain = (n: number) =>
      Object.fromEntries(Array.from({ length: n }, (_, i) => [`app/f${i}.schema.haus`, i === n - 1 ? `type T${i} = Int` : `import ./f${i + 1} (T${i + 1})\ntype T${i} = T${i + 1}`]))
    expect(() => load(app(chain(255), "import ./f0 (T0)\ntype Root = T0"))).not.toThrow()
    rejected(app(chain(256), "import ./f0 (T0)\ntype Root = T0"), "too-many-files")
  })

  it("opens each file once, by its real path, also a file in two roles", () => {
    const root = tree({
      "app/a.schema.haus": "import ./x (X)\nimport @acme/evil (Money)\ntype Root = { x: X, m: Money }",
      "app/x.schema.haus": "type X = Int",
      "vendor/evil/package.haus": manifest("@acme/evil"),
      "vendor/evil/schema.haus": money,
    })
    // The project's package.json is the schema file x: read as one (not JSON, so it declares nothing) and imported.
    symlinkSync("x.schema.haus", join(root, "app/package.json"))
    const opened: string[] = []
    const path = join(root, "app/a.schema.haus")
    const file = parseSchemaFile(readFileSync(path, "utf8"), schemaOptions(path, { packages: [join(root, "vendor/evil")], onOpen: (p) => opened.push(p) }))
    expect(file.imported.get("X")?.id).toMatch(/x#X$/)
    expect(file.imported.get("Money")?.id).toBe("@acme/evil@1#Money")
    const x = realpathSync(join(root, "app/x.schema.haus"))
    expect(opened.filter((p) => p === x)).toEqual([x])
    expect(new Set(opened).size).toBe(opened.length)
    expect(opened).toEqual(expect.arrayContaining([x, realpathSync(join(root, "vendor/evil/package.haus")), realpathSync(join(root, "vendor/evil/schema.haus"))]))
  })

  it("takes an invalid package.json as declaring nothing", () => {
    const root = pkg({ "app/package.json": `{ "name": "app", "dependencies": { "@acme/evil": "*" } ` })
    rejected(root, "undeclared-package")
  })

  it("says a file outside any npm project should be given its packages explicitly", () => {
    const root = tree({ "app/main.schema.haus": "import @acme/evil (Money)\ntype Root = { m: Money }" })
    expect(rejected(root, "undeclared-package")).toMatch(/no package.json above .* declares @acme\/evil: give the package explicitly/)
  })

  // Unix only: no FIFOs, and no write permission for everyone, on Windows.
  it.skipIf(process.platform === "win32")("never looks in a node_modules of a directory everyone may write to", () => {
    const root = tree({
      "shared/node_modules/@acme/evil/package.haus": manifest("@acme/evil"),
      "shared/node_modules/@acme/evil/schema.haus": money,
      "shared/app/package.json": JSON.stringify({ name: "app", dependencies: { "@acme/evil": "*" } }),
      "shared/app/main.schema.haus": "import @acme/evil (Money)\ntype Root = { m: Money }",
    })
    const path = join(root, "shared/app/main.schema.haus")
    expect(() => parseSchemaFile(readFileSync(path, "utf8"), schemaOptions(path))).not.toThrow()
    chmodSync(join(root, "shared"), 0o777)
    expect(() => parseSchemaFile(readFileSync(path, "utf8"), schemaOptions(path))).toThrow(/package not found/)
  })

  it("reports packages and folders that don't exist when the resolver is set up", () => {
    const root = tree({ "vendor/empty/x": "" })
    for (const options of [{ packages: [join(root, "vendor/empty")] }, { folders: [join(root, "nowhere")] }]) {
      try {
        nodeResolver(options)
        throw new Error("accepted")
      } catch (e) {
        expect(e).toBeInstanceOf(ModuleError)
        expect((e as ModuleError).code).toBe("import-not-found")
      }
    }
  })

  it("doesn't scan a folder of packages with more than 4096 entries", () => {
    const root = tree({ "vendor/keep": "" })
    for (let i = 0; i < 4097; i++) writeFileSync(join(root, "vendor", `f${i}`), "")
    expect(() => nodeResolver({ folders: [join(root, "vendor")] })).toThrow(/more than 4096/)
  })

  it("escapes and shortens text it quotes from files", () => {
    // A bidirectional override, written as an escape in the manifest (raw ones are a syntax error).
    const root = pkg({ [`${PKG}/package.haus`]: `{ name: "@acme/EVIL\\u{202e}${"x".repeat(60)}", version: "1.2.0" }` })
    const message = rejected(root, "package-manifest")
    expect(message).toContain("\\u{202e}")
    expect(message).not.toContain("‮")
    expect(message).toContain("…")
    expect(message).not.toContain("x".repeat(41))
    expect(quoteText("a\u0007b")).toBe("a\\u{7}b")
  })
})

describe("identical copies (spec §13.3)", () => {
  const npmPkg = (dir: string, name: string, version: string, schema: string, deps: string[] = []) => ({
    [`${dir}/package.haus`]: `{ name: "${name}", version: "${version}" }`,
    [`${dir}/schema.haus`]: schema,
    [`${dir}/package.json`]: JSON.stringify({ name, version, dependencies: Object.fromEntries(deps.map((d) => [d, "*"])) }),
  })
  const orders = "import @acme/common@1 (Address)\ntype Order = { to: Address }"
  // Two identical copies of orders; their imports of common reach 1.4.0 and 1.2.0.
  const copies = (main: string) =>
    tree({
      "app/package.json": JSON.stringify({ name: "app", dependencies: { "@acme/orders": "*", "@acme/billing": "*" } }),
      "app/main.schema.haus": main,
      ...npmPkg("app/node_modules/@acme/orders", "@acme/orders", "1.0.0", orders, ["@acme/common"]),
      ...npmPkg("app/node_modules/@acme/common", "@acme/common", "1.4.0", "type Address = { city: String, zip?: String }"),
      ...npmPkg("app/node_modules/@acme/billing", "@acme/billing", "1.0.0", "import @acme/orders@1 (Order)\ntype Bill = { order: Order }", ["@acme/orders"]),
      ...npmPkg("app/node_modules/@acme/billing/node_modules/@acme/orders", "@acme/orders", "1.0.0", orders, ["@acme/common"]),
      ...npmPkg("app/node_modules/@acme/billing/node_modules/@acme/common", "@acme/common", "1.2.0", "type Address = { city: String }"),
    })

  it.each([
    ["orders first", "import @acme/orders@1 (Order)\nimport @acme/billing@1 (Bill)\ntype Root = { order: Order, bill: Bill }"],
    ["billing first", "import @acme/billing@1 (Bill)\nimport @acme/orders@1 (Order)\ntype Root = { order: Order, bill: Bill }"],
  ])("are two packages when their imports differ, whichever comes first (%s)", (_, main) => {
    const message = rejected(copies(main), "duplicate-package")
    expect(message).toContain("1.2.0")
    expect(message).toContain("1.4.0")
  })
})
