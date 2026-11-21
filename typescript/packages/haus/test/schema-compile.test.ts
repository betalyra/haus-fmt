import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { canonical, compileSchemaFile, HausSchemaFileError, parseSchemaFile, schemaDeclarations, type Codec, type StandardSchemaV1 } from "../src/index.js"
import { nodeResolver, schemaOptions } from "../src/node.js"
import * as h from "../src/schema.js"

const examples = join(import.meta.dirname, "../../../../examples")
const read = (name: string) => readFileSync(join(examples, name), "utf8")
const compile = (name: string) => compileSchemaFile(read(name), schemaOptions(join(examples, name)))

describe("schemas from schema files", () => {
  it("compile a record that reaches its own record case by name (found by the schema-file fuzzer)", () => {
    const { schemas } = compileSchemaFile("type C = { s: < S B | N > }\ntype B = C")
    const c = schemas.C!
    const v = h.parse(c, "{ s: S { s: S { s: N } } }")
    expect(canonical(h.encode(c, v))).toBe("{s:S{s:S{s:N}}}")
    expect(() => h.parse(c, "{ s: S { s: 1 } }")).toThrow()
  })

  it("decode data the way the declarations say", () => {
    const { schemas } = compile("thread.schema.haus")
    const thread = h.parse(schemas.Root!, read("thread.haus")) as { author: string; likes: bigint; at: string; replies: unknown[] }
    expect(typeof thread.author).toBe("string")
    expect(typeof thread.likes).toBe("bigint")
    expect(thread.at).toBe("2026-11-01T09:00:00Z") // std/time values keep their text
    expect(Array.isArray(thread.replies)).toBe(true)
  })

  it("resolve imported schema packages", () => {
    const { schemas } = compile("order.schema.haus")
    const order = h.parse(schemas.Root!, read("order.haus")) as { status: unknown }
    expect(order.status).toEqual(expect.objectContaining({ _tag: expect.any(String) }))
  })

  it("know which types are streams", () => {
    const { schemas, streams } = compile("logs.schema.haus")
    const name = [...streams][0]!
    expect(schemas[name]).toBeDefined()
  })

  it("map every kind of type", () => {
    const { schemas } = compileSchemaFile(`
      import std/time (Date, Duration)
      type Level = closed < Debug | Info >
      type Event = < Click { x: Int32, y: Int32 } | Key String | Tick >
      type Root = closed {
        level: Level,
        events: Array Event,
        price: Decimal,
        big: Int64,
        note?: Maybe String,
        tags: Map Bool,
        day: Date,
        wait: Duration,
      }
    `)
    const root = h.parse(schemas.Root!, `{
      level: Info,
      events: [Click { x: 1, y: 2 }, Key("a"), Tick, Scroll(3)],
      price: 19.90,
      big: 9007199254740993,
      note: None,
      tags: { a: True },
      day: Date("2026-11-12"),
      wait: Duration("PT48H"),
    }`) as Record<string, unknown>
    expect(root.level).toBe("Info")
    expect(root.events).toEqual([
      { _tag: "Click", x: 1, y: 2 },
      { _tag: "Key", values: ["a"] },
      { _tag: "Tick" },
      expect.objectContaining({ _tag: "@unknown", tag: "Scroll" }),
    ])
    expect(root.price).toBe("19.90")
    expect(root.big).toBe(9007199254740993n)
    expect(root.note).toEqual({ _tag: "None" })
    expect(root.tags).toEqual(new Map([["a", true]]))
    expect(root.day).toBe("2026-11-12")
    expect(root.wait).toBe("PT48H")
  })

  it("decode Int as a bigint of any size, and write it back unchanged", () => {
    const { schemas } = compileSchemaFile(`type Root = Int`)
    const text = "340282366920938463463374607431768211457" // 2^128 + 1
    expect(h.parse(schemas.Root!, text)).toBe(2n ** 128n + 1n)
    expect(h.stringify(schemas.Root!, h.parse(schemas.Root!, text))).toBe(text)
  })

  it("enforce ranges and closed records", () => {
    const { schemas } = compileSchemaFile(`type Root = closed { n: UInt8 }`)
    expect(() => h.parse(schemas.Root!, `{ n: 300 }`)).toThrow("out of range for UInt8")
    expect(() => h.parse(schemas.Root!, `{ n: 1, extra: 2 }`)).toThrow("unexpected field")
  })

  it("handle recursive and generic types", () => {
    const { schemas } = compileSchemaFile(`
      type List a = < Nil | Cons a (List a) >
      type Root = List Int
    `)
    expect(h.parse(schemas.Root!, "Cons(1, Cons(2, Nil))")).toEqual({
      _tag: "Cons", values: [1n, { _tag: "Cons", values: [2n, { _tag: "Nil" }] }],
    })
  })

  it("treat a case whose one argument names a record as a record case (spec §15)", () => {
    const { schemas, file } = compileSchemaFile(`
      type Rec = { w: Int32, tags?: Array String }
      type Alias = Rec
      type Alias2 = Alias
      type Page a = { w: a, tags?: Array String }
      type Inline = < Box { w: Int32, tags?: Array String } | Empty >
      type Paren = < Box ({ w: Int32, tags?: Array String }) | Empty >
      type Named = < Box Rec | Empty >
      type Chain = < Box Alias2 | Empty >
      type Applied = < Box (Page Int32) | Empty >
      type Id a = a
      type ById = < Box (Id Rec) | Empty >
      type Nat = < Z | S Nat >
      type Spread = < ...Named | Other >
      type GenBox a = < Box a | Empty >
      type Gen = GenBox Rec
    `)
    for (const text of ["Box { w: 1 }", "Box({ w: 1, tags: [\"a\"] })", "Box { w: 1, extra: 2 }", "Empty"]) {
      const value = (name: string) => h.parse(schemas[name]!, text)
      const json = (name: string) => h.toJson(schemas[name]!, value(name))
      for (const name of ["Paren", "Named", "Chain", "Applied", "ById", "Spread"]) {
        expect(value(name), `${name}: ${text}`).toEqual(value("Inline"))
        expect(json(name), `${name}: ${text}`).toBe(json("Inline"))
        expect(h.fromJson(schemas[name]!, json("Inline"))).toEqual(value("Inline"))
      }
    }
    expect(h.toJson(schemas.Named!, h.parse(schemas.Named!, "Box { w: 1 }"))).toBe(`{"_tag":"Box","w":1}`)
    // A recursive case resolves once every type is known.
    expect(h.parse(schemas.Nat!, "S(S(Z))")).toEqual({ _tag: "S", values: [{ _tag: "S", values: [{ _tag: "Z" }] }] })
    // A type parameter is never a record, even where its argument is one.
    expect(h.parse(schemas.Gen!, "Box { w: 1 }")).toEqual({ _tag: "Box", values: [{ w: 1 }] })
    expect(h.toJson(schemas.Gen!, h.parse(schemas.Gen!, "Box { w: 1 }"))).toBe(`{"_tag":"Box","value":{"w":1}}`)
    // The declarations agree: the record's fields beside the tag.
    const decl = schemaDeclarations(file)
    const box = `{ readonly _tag: "Box"; readonly w: number; readonly tags?: ReadonlyArray<string> }`
    for (const name of ["Inline", "Paren", "Named", "Chain", "Applied", "ById"]) expect(decl).toContain(`export type ${name} = ${box} | { readonly _tag: "Empty" } | h$.Unknown;`)
  })

  it("agree with hand-written schemas where a Recursive record is a case's one argument (spec §15)", () => {
    const { schemas } = compileSchemaFile(`
      type Node = { name: String, next?: Node, then: Maybe Event }
      type Event = < Start Node | Odd Weird | Stop >
      type Weird = { n: Int32 }
    `)
    interface Node { readonly name: string; readonly next?: Node; readonly then: h.Maybe<Event> }
    type Event = ({ readonly _tag: "Start" } & Node) | { readonly _tag: "Odd"; readonly n: number } | { readonly _tag: "Stop" } | h.Unknown
    // Built when first used: Event is defined below, and Node is a record only once it is built.
    const Node = h.Recursive<Node>("Node", (self) => h.Record({ name: h.String, next: h.Optional(self), then: h.Maybe(Event) }))
    const Weird = h.Recursive<{ readonly n: number }>("Weird", () => h.Recursive("Inner", () => h.Record({ n: h.Int32 })))
    const Event: h.Schema<Event> = h.OpenVariant({ Start: Node, Odd: Weird, Stop: h.Unit })
    // The case's type has the record's fields beside the tag.
    const start: h.Infer<typeof Event> = { _tag: "Start", name: "x", then: { _tag: "None" } }
    expect(h.toJson(Event, start)).toBe(`{"_tag":"Start","name":"x","then":null}`)
    for (const text of [
      `Start { name: "a", next: { name: "b", then: None }, then: Some(Stop) }`,
      `Start { name: "a", then: Some(Start { name: "c", then: Some(Odd { n: 3 }) }), extra: 1 }`,
      `Odd { n: 1 }`,
      `Stop`,
      `Later(1)`,
    ]) {
      const written = h.parse(Event, text)
      const fromFile = h.parse(schemas.Event!, text)
      expect(written, text).toEqual(fromFile)
      const json = h.toJson(schemas.Event!, fromFile)
      expect(h.toJson(Event, written), text).toBe(json)
      expect(h.fromJson(Event, json), text).toEqual(written)
      expect(h.stringify(Event, written)).toBe(h.stringify(schemas.Event!, fromFile))
    }
    expect(h.toJson(Event, h.parse(Event, `Odd { n: 1 }`))).toBe(`{"_tag":"Odd","n":1}`)
    // A record case takes a record, as the schema file's does.
    for (const text of [`Start("a")`, `Odd(1)`]) {
      expect(() => h.parse(Event, text)).toThrow(/expects a record payload/)
      expect(() => h.parse(schemas.Event!, text)).toThrow(/expects a record payload/)
    }
    // A Recursive that isn't a record stays a positional case.
    const Ints = h.Recursive<readonly number[]>("Ints", () => h.Array(h.Int32))
    expect(h.parse(h.Variant({ L: Ints }), "L([1])")).toEqual({ _tag: "L", value: [1] })
  })

  it("are Standard Schemas", () => {
    const { schemas } = compileSchemaFile(`type Root = { id: Int }`)
    const s = schemas.Root as StandardSchemaV1<unknown, unknown>
    expect(s["~standard"].validate(`{ id: "x" }`)).toEqual({ issues: [expect.objectContaining({ path: ["id"] })] })
  })
})

describe("codecs", () => {
  const repo = join(import.meta.dirname, "../../../..")
  const packages = { "@haus-fmt/money": join(repo, "extensions/money") }
  const capitals: Codec = {
    id: "@haus-fmt/money@1#Currency",
    apply: (base) => h.refine(base, (c) => (typeof c === "string" && /^[A-Z]{3}$/.test(c) ? undefined : "a currency is three letters A–Z")),
  }
  const order = (codecs: readonly Codec[]) =>
    compileSchemaFile(`import @haus-fmt/money (Money)\ntype Order = { total: Money, paid: Array Money }`, { resolver: nodeResolver({ packages }), codecs }).schemas.Order!

  it("apply wherever their type occurs, inside imported packages too", () => {
    const text = `{ total: Money(19.90, EUR), paid: [Money(1, USD)] }`
    expect(h.stringify(order([capitals]), h.parse(order([capitals]), text), { style: "compact" })).toBe(text)
    expect(() => h.parse(order([]), text.replace("USD", "Usd"))).not.toThrow()
    expect(() => h.parse(order([capitals]), text.replace("USD", "Usd"))).toThrow(/three letters A–Z at \$\.paid\[0\]\[1\]/)
    // Encoding checks the rule too.
    expect(() => h.stringify(order([capitals]), { total: { _tag: "Money", values: ["1", "eur"] }, paid: [] })).toThrow(/three letters/)
  })

  it("for types the schema doesn't contain are ignored; two for one type are an error", () => {
    const other: Codec = { id: "@haus-fmt/geo@1#LatLng", apply: (base) => base }
    expect(() => order([capitals, other])).not.toThrow()
    expect(() => order([capitals, capitals])).toThrow("two codecs for @haus-fmt/money@1#Currency")
  })

  it("apply to recursive types", () => {
    const shallow: Codec = { id: "Tree", apply: (base) => h.refine(base, (t) => ((t as { kids: unknown[] }).kids.length <= 1 ? undefined : "at most one child")) }
    const { schemas } = compileSchemaFile(`type Tree = { kids: Array Tree }`, { codecs: [shallow] })
    expect(() => h.parse(schemas.Tree!, `{ kids: [{ kids: [] }] }`)).not.toThrow()
    expect(() => h.parse(schemas.Tree!, `{ kids: [{ kids: [{ kids: [] }, { kids: [] }] }] }`)).toThrow(/at most one child at \$\.kids\[0\]/)
  })

  it("can't apply to a record case by name: codec-unreachable", () => {
    const rec: Codec = { id: "R", apply: (base) => base }
    expect(() => compileSchemaFile(`type R = { w: Int32 }\ntype V = < Box R >`, { codecs: [rec] })).toThrow(expect.objectContaining({ code: "codec-unreachable" }))
  })
})

describe("declarations", () => {
  it("declare types and schemas", () => {
    const decl = schemaDeclarations(parseSchemaFile(`
      import std/time (Date, Instant)
      // a level
      type Level = closed < Debug | Info >
      type List a = < Nil | Cons a (List a) >
      type Root = { level: Level, n: List Int, at: Instant, when?: Maybe Date }
    `))
    expect(decl).toContain(`export type Level = "Debug" | "Info";`)
    expect(decl).toContain(`export type List<A> = { readonly _tag: "Nil" } | { readonly _tag: "Cons"; readonly values: readonly [A, List<A>] } | h$.Unknown;`)
    expect(decl).toContain(`export type Root = { readonly level: Level; readonly n: List<bigint>; readonly at: string; readonly when?: h$.Maybe<string> };`)
    expect(decl).toContain(`export declare const Root: h$.Schema<Root>;`)
    expect(decl).not.toContain("export declare const List")
  })
})

describe("comments, whitespace and strings are those of data files (spec §14)", () => {
  const codeAt = (text: string): [string, number, number] => {
    try {
      parseSchemaFile(text)
    } catch (e) {
      if (!(e instanceof HausSchemaFileError)) throw e
      return [e.code, e.line, e.column]
    }
    throw new Error("accepted")
  }

  it.each([
    ['type A = { "x: Int }', "unterminated-string", 1, 12],
    ["type A = Int /* never closed", "unterminated-comment", 1, 14],
    ["type A = Int\rtype B = Int", "lone-carriage-return", 1, 13],
    ["// a\rb\ntype A = Int", "lone-carriage-return", 1, 5],
    ["// a\x07b\ntype A = Int", "control-character", 1, 5],
    ["/* a\x7fb */ type A = Int", "control-character", 1, 5],
    ["// a\x85b\ntype A = Int", "control-character", 1, 5],
    ["// access\u202e denied\ntype A = Int", "bidi-control", 1, 10],
    ['type A = { "a\u2066b": Int }', "bidi-control", 1, 14],
    ['type A = { "a\x07b": Int }', "control-character", 1, 14],
    ['type A = { "a\nb": Int }', "string-line-break", 1, 14],
    ['type A = { "a\\x41": Int }', "invalid-escape", 1, 14],
    ['type A = { "a\\u{D800}": Int }', "invalid-unicode-escape", 1, 14],
    // A string is read only where one may be (as Lean): a '"' anywhere else is a syntax error, whatever follows it.
    ['type A = { "a: Int, b: "" }\n', "schema-syntax", 1, 25],
    ['type A = { a: "b\n }', "schema-syntax", 1, 15],
  ])("%j: %s", (text, code, line, column) => {
    expect(codeAt(text)).toEqual([code, line, column])
  })

  it("a byte order mark at the start, CRLF line breaks and tabs in comments are fine", () => {
    expect(() => parseSchemaFile("\ufeff// a\tb\r\ntype A = Int\r\n")).not.toThrow()
  })

  it("quoted keys take every escape of data strings", () => {
    const { schemas } = compileSchemaFile('type A = closed { "tab\\there": Int, "cr\\r": Int, "\\u{1F600}": Int, "q\\"\\\\": Int }')
    expect(h.parse(schemas.A!, '{ "tab\\there": 1, "cr\\r": 2, "😀": 3, "q\\"\\\\": 4 }')).toEqual({ "tab\there": 1n, "cr\r": 2n, "😀": 3n, 'q"\\': 4n })
  })
})
