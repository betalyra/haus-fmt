import { describe, expect, it } from "vitest"
import { HausSchemaFileError, importEdits, missingImports, moduleOfType, parseSchemaFile, type ImportEdit } from "../src/index.js"

/** The text with the edits applied (they don't overlap). */
const apply = (text: string, edits: readonly ImportEdit[]): string =>
  [...edits].sort((a, b) => b.start - a.start).reduce((t, e) => t.slice(0, e.start) + e.newText + t.slice(e.end), text)

const fixed = (text: string, module: string, names: readonly string[]) => apply(text, importEdits(text, module, names))

const schemaError = (text: string): HausSchemaFileError => {
  try {
    parseSchemaFile(text)
  } catch (e) {
    if (e instanceof HausSchemaFileError) return e
    throw e
  }
  throw new Error("no error")
}

describe("missing imports", () => {
  it("the error names the module, and a package says to install it", () => {
    const date = schemaError("type A = { at: Date }")
    expect(date.reason).toBe("unknown type Date; import it with: import std/time (Date)")
    expect(date.missingImport).toEqual({ module: "std/time", name: "Date" })
    expect(date.offset).toBe(15)

    const geo = schemaError("type A = { at: LatLng }")
    expect(geo.reason).toBe("unknown type LatLng; import it with: import @haus-fmt/geo (LatLng), and install @haus-fmt/geo with your package manager")
    expect(geo.missingImport).toEqual({ module: "@haus-fmt/geo", name: "LatLng" })

    expect(schemaError("type A = Strin").missingImport).toBeUndefined()
  })

  it("knows the standard modules and the official extensions", () => {
    expect(moduleOfType("Instant")).toBe("std/time")
    expect(moduleOfType("Currency")).toBe("@haus-fmt/money")
    expect(moduleOfType("BBox")).toBe("@haus-fmt/geo")
    expect(moduleOfType("Strin")).toBeUndefined()
  })

  it("lists the known types used without an import, once each", () => {
    const text = "import std/time (Date)\ntype A = { a: Date, b: Instant, c: Money, d: Array Instant, e: Duration, f: Strin }\ntype Money = String"
    expect(missingImports(text).map((m) => `${m.module} ${m.name}`)).toEqual(["std/time Instant", "std/time Duration"])
    expect(missingImports("type A = {")).toEqual([])
  })

  it("a spread of an imported standard, built-in or prelude type says it isn't a record or variant, not that it is unknown", () => {
    const variant = schemaError("import std/time (Date)\ntype T = < ...Date >")
    expect([variant.code, variant.reason, variant.line, variant.column]).toEqual(["invalid-spread", "Date is not a variant, so it can't be spread here", 2, 15])
    expect(variant.missingImport).toBeUndefined()
    const spreads: [string, string][] = [
      ["import std/time (Date)\ntype T = { ...Date }", "Date is not a record, so it can't be spread here"],
      ["type T = { ...Int32 }", "Int32 is not a record, so it can't be spread here"],
      ["type T = { ...Array }", "Array is not a record, so it can't be spread here"],
      ["type T = < ...Maybe >", "Maybe is not a variant, so it can't be spread here"],
      ["type T = < ...Bool >", "Bool is not a variant, so it can't be spread here"],
    ]
    for (const [text, reason] of spreads) expect([schemaError(text).code, schemaError(text).reason]).toEqual(["invalid-spread", reason])
    // Not imported: then it is unknown, with the import hint.
    const unknown = schemaError("type T = { ...Date }")
    expect([unknown.code, unknown.missingImport]).toEqual(["unknown-type", { module: "std/time", name: "Date" }])
  })

  it("an imported record or variant can be spread; anything else says why not", () => {
    const other = `type R = { a: Int32 }\ntype V = < X | Y Int32 >\ntype G a = { g: a }\ntype S = Stream R`
    const resolver = { resolve: (module: string) => ({ key: module, id: module, text: other }) }
    const parse = (text: string) => parseSchemaFile(text, { resolver })
    expect(parse(`import ./other (R)\ntype T = { ...R, b: String }`).definition("T")).toBeDefined()
    expect(parse(`import @acme/shapes (V)\ntype T = < ...V | Z >`).definition("T")).toBeDefined()
    const failing: [string, string][] = [
      [`import ./other (V)\ntype T = { ...V }`, "V is not a record, so it can't be spread here"],
      [`import ./other (G)\ntype T = { ...G }`, "G has parameters (G a); only a type without parameters can be spread"],
      [`import ./other (S)\ntype T = { ...S }`, "S is a Stream and can't be spread"],
    ]
    for (const [text, reason] of failing) {
      try {
        parse(text)
        expect.unreachable(text)
      } catch (e) {
        expect(e).toBeInstanceOf(HausSchemaFileError)
        expect([(e as HausSchemaFileError).code, (e as HausSchemaFileError).reason]).toEqual(["invalid-spread", reason])
      }
    }
  })
})

describe("import edits", () => {
  it("adds a name to the end of an existing list", () => {
    expect(fixed("import std/time (Instant, Date)\ntype A = Duration", "std/time", ["Duration"]))
      .toBe("import std/time (Instant, Date, Duration)\ntype A = Duration")
    expect(fixed("import std/time (Instant)\ntype A = Date", "std/time", ["Date"]))
      .toBe("import std/time (Instant, Date)\ntype A = Date")
  })

  it("keeps a sorted list sorted", () => {
    expect(fixed("import std/time (Date, Instant)\ntype A = { a: Time, b: Duration, c: ZonedDateTime }", "std/time", ["Time", "Duration", "ZonedDateTime"]))
      .toBe("import std/time (Date, Duration, Instant, Time, ZonedDateTime)\ntype A = { a: Time, b: Duration, c: ZonedDateTime }")
  })

  it("keeps a list with one name per line", () => {
    const text = "import std/time (\n  Date,\n  Instant,\n)\ntype A = { a: Time, b: Duration }"
    expect(fixed(text, "std/time", ["Time", "Duration"]))
      .toBe("import std/time (\n  Date,\n  Duration,\n  Instant,\n  Time,\n)\ntype A = { a: Time, b: Duration }")
  })

  it("extends a versioned package import", () => {
    expect(fixed("import @haus-fmt/money@1 (Money)\ntype A = Currency", "@haus-fmt/money", ["Currency"]))
      .toBe("import @haus-fmt/money@1 (Money, Currency)\ntype A = Currency")
  })

  it("adds a new import after the last one", () => {
    expect(fixed("import std/time (Date) // when\ntype A = { at: Date, total: Money }", "@haus-fmt/money", ["Money"]))
      .toBe("import std/time (Date) // when\nimport @haus-fmt/money (Money)\ntype A = { at: Date, total: Money }")
  })

  it("adds a new import above the first type, after the file's header comment", () => {
    const text = "// Orders.\n\n// One order.\ntype Order = { at: Date, where: LatLng, box: BBox }\n"
    expect(fixed(text, "@haus-fmt/geo", ["LatLng", "BBox"]))
      .toBe("// Orders.\n\nimport @haus-fmt/geo (LatLng, BBox)\n\n// One order.\ntype Order = { at: Date, where: LatLng, box: BBox }\n")
    expect(fixed("type A = Date", "std/time", ["Date"])).toBe("import std/time (Date)\n\ntype A = Date")
  })

  it("the fixed file parses", () => {
    const text = "// Orders.\n\ntype Order = { placed: Date, at: Instant }\n"
    const missing = missingImports(text)
    const result = fixed(text, "std/time", missing.map((m) => m.name))
    expect(result).toBe("// Orders.\n\nimport std/time (Date, Instant)\n\ntype Order = { placed: Date, at: Instant }\n")
    expect(parseSchemaFile(result).definition("Order")).toBeDefined()
  })

  it("does nothing for names already in scope or a file that doesn't parse", () => {
    expect(importEdits("import std/time (Date)\ntype A = Date", "std/time", ["Date"])).toEqual([])
    expect(importEdits("type A = {", "std/time", ["Date"])).toEqual([])
  })
})
