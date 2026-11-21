import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import { format, inferSchema, parse, parseAll, parseDocument, parseWithLocations, stringify, infer, printShape } from "../src/index.js"
import { suiteJson } from "./suite-json.js"
import { decode, fixtures, repoFile } from "./haus.js"

const files = [
  ...fixtures("valid").map(({ name, bytes }) => ({ name, bytes })),
  ...["syntax-tour.haus", "events.haus", "person.haus", "thread.haus", "filesystem.haus", "settings-ui.haus", "user-update.haus"].map((name) => ({ name, bytes: repoFile(name) })),
]

describe("format: round trip and idempotence", () => {
  it.effect.each(files)("$name", ({ bytes }) =>
    Effect.gen(function* () {
      const src = yield* decode(bytes)
      const values = parseAll(src)
      for (const out of [format(values), format(parseWithLocations(src), { source: src })]) {
        // Same data after formatting…
        expect(parseAll(out).map(suiteJson)).toEqual(values.map(suiteJson))
        // …and formatting the output again changes nothing.
        expect(format(parseWithLocations(out), { source: out })).toBe(out)
      }
    }))
})

describe("format: comments are kept", () => {
  const withComments = (src: string) => {
    const { values, comments } = parseDocument(src)
    return { out: format(values, { source: src, comments }), values, comments }
  }
  const commentTexts = (src: string) => {
    const { comments } = parseDocument(src)
    // The output has LF line endings, in comments too.
    return comments.map(([s, e]) => src.slice(s, e).replaceAll("\r", ""))
  }

  it.effect.each(files)("$name", ({ bytes }) =>
    Effect.gen(function* () {
      const src = yield* decode(bytes)
      const { out, values } = withComments(src)
      expect(parseAll(out).map(suiteJson)).toEqual(values.map(suiteJson))
      expect(commentTexts(out)).toEqual(commentTexts(src))
      expect(withComments(out).out).toBe(out)
    }))

  it("places leading, trailing and dangling comments", () => {
    const src = `// header

{
  // about name
  name: "Jan", // trailing
  /* inline */ age: 3,

  tags: [
    1, // one
    // end of list
  ],
  // end of record
}
`
    expect(withComments(src).out).toBe(`// header

{
  // about name
  name: "Jan", // trailing
  /* inline */
  age: 3,

  tags: [
    1, // one
    // end of list
  ],
  // end of record
}
`)
  })

  it("keeps a block comment after an entry", () => {
    expect(withComments("{ a: 1 /* why */, b: 2 }").out).toBe("{\n  a: 1, /* why */\n  b: 2,\n}\n")
  })

  it("keeps a comment-only file", () => {
    expect(withComments("// nothing\n").out).toBe("// nothing\n")
  })
})

describe("format: pretty (default)", () => {
  const fmt = (src: string) => format(parseAll(src))

  it("puts every record and array entry on its own line, keeps positional payloads inline", () => {
    expect(fmt('Person { name: "John Doe", tags: ["a"], price: Money(7.90, EUR), empty: {}, none: [] },')).toBe(
      'Person {\n  name: "John Doe",\n  tags: [\n    "a",\n  ],\n  price: Money(7.90, EUR),\n  empty: {},\n  none: [],\n}\n',
    )
  })

  it("writes streams with a comma after every item and a blank line between multi-line items", () => {
    expect(fmt("A, B { x: 1 }, C")).toBe("A,\nB {\n  x: 1,\n},\n\nC,\n")
  })

  it("quotes keys only when needed and escapes minimally", () => {
    expect(fmt('{ "content-type": "a\\"b", ok: "\\u{202E}" }')).toBe('{\n  "content-type": "a\\"b",\n  ok: "\\u{202E}",\n}\n')
  })

  it("uses block strings for multi-line text, escaping quote runs", () => {
    const src = '{ text: "line 1\\nsay \\"\\"\\"hi\\"\\"\\"\\n" }'
    const out = fmt(src)
    expect(out).toBe('{\n  text: """\n    line 1\n    say \\"""hi\\"""\n\n    """,\n}\n')
    expect(parseAll(out).map(suiteJson)).toEqual(parseAll(src).map(suiteJson))
  })

  it("ends no block-string line in a space or tab: the last one is an escape (spec §11)", () => {
    const value = parse(String.raw`"a \nb  \n   \nc\t\n\t\nd \t\ne"`)
    expect(format([value])).toBe('"""\n  a\\u{20}\n  b \\u{20}\n    \\u{20}\n  c\\t\n  \\t\n  d \\t\n  e\n  """\n')
    expect(parse(format([value]).replace(/[ \t]+$/gm, ""))).toEqual(value)
  })

  it("escapes U+2028 and U+2029 in every layout, also in a kept spelling (spec §11)", () => {
    const src = '{ "k\u{2028}": "a\u{2029}", b: "x\u{2028}\\ny" }'
    const { values, comments } = parseDocument(src)
    for (const style of ["pretty", "compact", "minimised"] as const) {
      for (const out of [format(values, { style, source: src, comments }), format(parseAll(src), { style })]) {
        expect(out).not.toMatch(/[\u2028\u2029]/)
        expect(parseAll(out).map(suiteJson)).toEqual(parseAll(src).map(suiteJson))
      }
    }
    expect(format(values, { style: "minimised", source: src })).toBe(String.raw`{"k\u{2028}":"a\u{2029}",b:"x\u{2028}\ny"}` + "\n")
  })

  it("breaks a long positional payload", () => {
    expect(format(parseAll('Pair("aaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbb")'), { width: 30 })).toBe(
      'Pair(\n  "aaaaaaaaaaaaaaaaaaaa",\n  "bbbbbbbbbbbbbbbbbbbb",\n)\n',
    )
  })

  it("keeps the original spelling of numbers and strings when given the source", () => {
    const src = '{a:0xFF,b:1_000,c:"\\u{41}"}'
    expect(format(parseWithLocations(src), { source: src })).toBe('{\n  a: 0xFF,\n  b: 1_000,\n  c: "\\u{41}",\n}\n')
    expect(format(parseAll(src))).toBe('{\n  a: 255,\n  b: 1000,\n  c: "A",\n}\n')
  })
})

describe("format: compact (one item per line)", () => {
  it.effect.each(files)("$name round-trips with one item per line", ({ bytes }) =>
    Effect.gen(function* () {
      const values = parseAll(yield* decode(bytes))
      const out = format(values, { style: "compact" })
      expect(parseAll(out).map(suiteJson)).toEqual(values.map(suiteJson))
      expect(format(parseAll(out), { style: "compact" })).toBe(out)
      expect(out.split("\n").filter(Boolean)).toHaveLength(values.length)
    }))

  it("writes each item on one readable line", () => {
    expect(format(parseAll('Person { name: "John Doe", age: 30, type: Engineer }, Person { name: "Jane", text: """\n  a\n  b\n  """ }'), { style: "compact" })).toBe(
      'Person { name: "John Doe", age: 30, type: Engineer },\nPerson { name: "Jane", text: "a\\nb" },\n',
    )
  })

  it("stringify", () => {
    expect(stringify(parseAll('{ a: [1, 2], b: Some("y"), c: {} }')[0]!, { style: "compact" })).toBe('{ a: [1, 2], b: Some("y"), c: {} }')
  })
})

describe("format: minimised (compact without whitespace)", () => {
  it("writes the spec's example", () => {
    const src = 'Person { name: "John Doe", age: 30, type: Engineer }, Person { name: "Jane Smith", age: 28, type: Designer }'
    expect(format(parseAll(src), { style: "minimised" })).toBe('Person{name:"John Doe",age:30,type:Engineer},\nPerson{name:"Jane Smith",age:28,type:Designer},\n')
  })

  it("keeps spellings, drops comments", () => {
    const src = '// c\n{ a: 1_000, /* c */ b: 0xFf, c: x"9f86 d081", d: Pair(1, [2, 3]), e: Tag { x: {} } } // c\n'
    const { values, comments } = parseDocument(src)
    expect(format(values, { style: "minimised", source: src, comments })).toBe('{a:1_000,b:0xFf,c:x"9f86 d081",d:Pair(1,[2,3]),e:Tag{x:{}}}\n')
  })

  it("writes values with no source text as compact does", () => {
    const v = parse('{ a: 1_000, b: 0xFF, c: x"0B 34", d: "a\\nb", "x-y": [] }')
    expect(stringify(v, { style: "minimised" })).toBe('{a:1000,b:255,c:x"0b34",d:"a\\nb","x-y":[]}')
    expect(stringify(v, { style: "minimised" })).toBe(stringify(v, { style: "compact" }).replace(/(?<=[,:{]) | (?=})/g, ""))
  })
})

describe("infer", () => {
  it("unifies variants seen at the same position", () => {
    const values = parseAll('Person { name: "John", age: 30, type: Engineer }, Person { name: "Jane", age: 28, type: Designer }')
    const { root } = infer(values)
    expect(printShape(root)).toBe("< Person { name: String, age: Int, type: < Engineer | Designer > } >")
  })

  it("handles deep nesting and names std/time types", () => {
    const values = parseAll(`
      A { jobs: [Job { from: Date("2020-01-01"), to: None, pay: Money(1.50, EUR), role: Dev { langs: [Rust] } }] },
      A { jobs: [Job { from: Date("2021-01-01"), to: Some(Date("2022-01-01")), pay: Money(2, GBP), role: Ops { oncall: True } }] },
    `)
    expect(printShape(infer(values).root, { width: 200 })).toBe(
      "< A { jobs: Array < Job { from: Date, to: Maybe Date, pay: < Money Decimal < EUR | GBP > >, role: < Dev { langs: Array < Rust > } | Ops { oncall: Bool } > } > } >",
    )
  })

  it("marks fields missing somewhere as optional, detects Bool, Maybe and Decimal", () => {
    const values = parseAll("{ a: 1, ok: True, n: None }, { a: 1.5, ok: False, n: Some(2), extra: [\"x\"] }")
    expect(printShape(infer(values).root)).toBe("{ a: Decimal, ok: Bool, n: Maybe Int, extra?: Array String }")
  })

  it("maps every value to the shape of its position", () => {
    const values = parseAll("{ type: Engineer }, { type: Designer }")
    const { shapeOf } = infer(values)
    const first = values[0]!
    const type = first.kind === "record" ? first.fields.get("type")! : first
    expect(printShape(shapeOf.get(type)!)).toBe("< Engineer | Designer >")
  })

  it("writes a schema document", () => {
    expect(inferSchema(parseAll("A, B"))).toContain("type Root = Stream Item")
  })
})

describe("format options are taken literally (spec §11)", () => {
  const pretty = (text: string, options: { indent?: number; width?: number }) => format(parseAll(text), options)
  it("indent and width 0 mean 0", () => {
    expect(pretty("{ a: { b: [1] } }", { indent: 0 })).toBe("{\na: {\nb: [\n1,\n],\n},\n}\n")
    expect(pretty("Point(1, 2)", { width: 0 })).toBe("Point(\n  1,\n  2,\n)\n")
    expect(pretty("Point(1, 2)", { indent: 0, width: 0 })).toBe("Point(\n1,\n2,\n)\n")
    expect(pretty("{ a: Point(1, 2) }", { width: 0 })).toBe("{\n  a: Point(\n    1,\n    2,\n  ),\n}\n")
  })

  it.each([{ width: -1 }, { indent: -1 }, { indent: -2, width: 40 }, { indent: 1.5 }, { width: 0.5 }, { width: NaN }, { indent: Infinity }])(
    "rejects %j, a misuse (no §17 code)",
    (options) => {
      expect(() => pretty("{ a: Point(1, 2) }", options)).toThrow(RangeError)
      expect(() => stringify(parse("{ a: Point(1, 2) }"), options)).toThrow(/must be a whole number of at least 0/)
    },
  )
})
