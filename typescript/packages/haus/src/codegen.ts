/**
 * Generated codecs: the compiled codecs of codec.ts written out as JavaScript
 * source, one function per record, array, map, Maybe, variant, Secret,
 * refinement and Recursive, calling each other directly. Leaves (strings,
 * numbers, tags, `Any`, schemas written by hand) are codec.ts's closures.
 * Over the closures alone, this gives every record its own code: an object
 * literal of a fixed shape, keys matched in place in the schema's order (a
 * `switch` on the next expected field), fields written as constant text, and
 * call sites that each see one schema.
 *
 * The source is run in one of two ways:
 * - built ahead: @haus-fmt/import generates it for a schema file's schemas
 *   together, puts it in the module it builds as a function, and registers it
 *   (`registerCodecs`) with the hash of the source. No `eval`. At first use
 *   the source is generated again from the schemas, which also gives the
 *   runtime objects it refers to (the `env`); the built-ahead function is
 *   used only if the hashes agree.
 * - at runtime with `new Function`, when the platform allows it (tried once),
 *   schema by schema as each is first used, calling the functions generated
 *   before for the types they share.
 *
 * The contract is codec.ts's, unchanged: the same values, texts and errors as
 * the generic path, step counts as `decode` and `encode` count them, and on
 * any error the generic path runs again and reports it. A schema the closures
 * can't compile isn't generated either.
 *
 * `readerFor` and `writerFor` pick the path (`Options.codec`): by default the
 * code built ahead where there is some, else the closures.
 */
import { quote, toHex } from "./format.js"
import { argumentForm, checkChain, compiledReader, compiledWriter, fail, HOLE, isEnumerable, isMaybe, Out, ReadCompiler, unknownOf, WriteCompiler, type Read, type Write } from "./codec.js"
import { readValue, readVariantAfter } from "./parser.js"
import { ARGS, ARRAY, CLOSE_ARGS, CLOSE_ARRAY, NO_PAYLOAD, PAYLOAD_RECORD, RECORD, VARIANT } from "./reader.js"
import { At, checkedValue, recursionOf, shapeOf, type AnySchema, type CaseShape, type Shape } from "./schema.js"
import { Secret } from "./secret.js"
import { Sha256 } from "./sha256.js"

/** The helpers generated code calls, as `rt`. Built on first use: schema.ts may still be loading when this module is. */
const runtime = () => ({
  fail,
  HOLE,
  readValue,
  readVariantAfter,
  recursionOf,
  unknownOf,
  At,
  checkedValue,
  isMaybe,
  isEnumerable,
  hasOwn: Object.hasOwn,
  /** A new own data property, as `setOwn` in schema.ts makes one for a key of the prototype chain. */
  define: (o: object, key: string, value: unknown) => Object.defineProperty(o, key, { value, enumerable: true, writable: true, configurable: true }),
  Out,
  Secret,
  quote,
  keyText,
})

let rt: ReturnType<typeof runtime> | undefined

/** A record key as the formatter writes it: bare if it can be, else quoted. */
const keyText = (k: string) => (BARE_KEY.test(k) ? k : quote(k))

const PRELUDE = `"use strict"\nconst { fail, HOLE, readValue, readVariantAfter, recursionOf, unknownOf, At, checkedValue, isMaybe, isEnumerable, hasOwn, define, Out, Secret, quote, keyText } = rt\n`

/**
 * A function made from the generated source: `(rt, env) => { roots, made }`,
 * `roots` the reader and writer of each root (in order), `made` every
 * function the source defines (in the order `Generated.made` lists them).
 */
export type Factory = (rt: unknown, env: readonly unknown[]) => { readonly roots: readonly (readonly [Read, Write])[]; readonly made: readonly unknown[] }

/** What a generated function is: a reader, a record's fields reader, a writer or a record's fields writer, of a schema. */
type Kind = "read" | "fields" | "write" | "fieldWrite"

/** Generated source for some schemas, the runtime objects it refers to (`env`), its hash, and the functions it defines. */
export interface Generated {
  readonly source: string
  readonly env: readonly unknown[]
  readonly hash: string
  readonly made: readonly (readonly [Kind, AnySchema])[]
}

/**
 * The generated functions that exist, by kind and schema: a later generation
 * calls them instead of generating them again (runtime generation goes
 * schema by schema, as each is first used).
 */
const published: Record<Kind, WeakMap<AnySchema, unknown>> = { read: new WeakMap(), fields: new WeakMap(), write: new WeakMap(), fieldWrite: new WeakMap() }

const BARE_KEY = /^[a-z_][A-Za-z0-9_]*$/
const IDENTIFIER = /^[A-Za-z_$][A-Za-z0-9_$]*$/
const STEP = "if (++cx.steps > cx.maxSteps) fail()"

/** Shapes read and written by codec.ts's closures (no structure to generate). */
const LEAVES: ReadonlySet<Shape["kind"]> = new Set(["string", "int", "smallInt", "bigInt", "float", "decimal", "bool", "bytes", "tagged", "enum", "anyTag", "any"])

/** A leaf as the source names it, so that the hash covers what each runtime object is. */
const leafNote = (s: AnySchema, shape: Shape | undefined): string => {
  if (shape === undefined) return `written by hand: ${s.expected}`
  switch (shape.kind) {
    case "smallInt":
    case "bigInt":
      return `${shape.kind} ${shape.min}..${shape.max}`
    case "float":
      return shape.name
    case "tagged":
      return `${shape.tag} ${shape.format.source}`
    case "enum":
      return `enum ${[...shape.tags].join(" ")}`
    default:
      return shape.kind
  }
}

/** `o.key` (or `o["key"]`) in source. */
const member = (key: string) => (IDENTIFIER.test(key) ? `.${key}` : `[${JSON.stringify(key)}]`)

/** A property of an object literal: a quoted key, `__proto__` computed (a plain `__proto__:` would set the prototype). */
const literalKey = (key: string) => (key === "__proto__" ? `["__proto__"]` : JSON.stringify(key))

type RecursiveShape = Extract<Shape, { kind: "recursive" }>

/**
 * One generation: the functions of every schema the roots reach, once. With
 * `reuse`, functions generated before are called, not generated again.
 */
class Generator {
  readonly env: unknown[] = []
  /** The functions defined, in order, and what each is. */
  readonly made: [Kind, AnySchema][] = []
  private readonly madeNames: string[] = []
  private readonly notes: string[] = []
  private readonly envNames = new Map<unknown, string>()
  private readonly functions: string[] = []
  private readonly readers = new Map<AnySchema, string>()
  private readonly fieldReaders = new Map<AnySchema, string>()
  private readonly writers = new Map<AnySchema, string>()
  private readonly fieldWriters = new Map<AnySchema, string>()
  private readonly leafReaders = new ReadCompiler()
  private readonly leafWriters = new WriteCompiler()
  private count = 0

  constructor(private readonly reuse: boolean) {}

  /** The source of the generated module body (see `Factory`); `roots` are `[read, write]` pairs of names. */
  source(roots: readonly string[]): string {
    const env = this.notes.map((note, i) => `const e${i} = env[${i}] // ${note}\n`).join("")
    return `${PRELUDE}${env}${this.functions.join("")}return { roots: [${roots.join(", ")}], made: [${this.madeNames.join(", ")}] }\n`
  }

  /** A function of this kind for `s` generated before (with `reuse`), as a name. */
  private earlier(kind: Kind, s: AnySchema): string | undefined {
    const f = this.reuse ? published[kind].get(s) : undefined
    return f === undefined ? undefined : this.ref(f, `generated before: ${kind} ${s.expected}`)
  }

  /** Define the function `name` (the `kind` of `s`). */
  private define(kind: Kind, s: AnySchema, name: string, params: string, body: string): void {
    this.functions.push(`function ${name}(${params}) {\n${body}\n}\n`)
    this.made.push([kind, s])
    this.madeNames.push(name)
  }

  /** A runtime object the source refers to, by name; `note` says in the source what it is. */
  private ref(x: unknown, note: string): string {
    const known = this.envNames.get(x)
    if (known !== undefined) return known
    const name = `e${this.env.length}`
    this.env.push(x)
    this.notes.push(JSON.stringify(note))
    this.envNames.set(x, name)
    return name
  }

  private name(prefix: string): string {
    return `${prefix}${this.count++}`
  }

  // ── readers ────────────────────────────────────────────────

  /** The name of `s`'s reader `(r, cx, depth) => value`. */
  read(s: AnySchema): string {
    const known = this.readers.get(s)
    if (known !== undefined) return known
    const shape = shapeOf(s)
    if (shape === undefined || LEAVES.has(shape.kind)) {
      const name = this.ref(this.leafReaders.read(s), `read ${leafNote(s, shape)}`)
      this.readers.set(s, name)
      return name
    }
    const before = this.earlier("read", s)
    if (before !== undefined) {
      this.readers.set(s, before)
      return before
    }
    const name = this.name("r")
    // Named before its body is generated: a Recursive refers back to it.
    this.readers.set(s, name)
    this.define("read", s, name, "r, cx, depth", this.readBody(s, shape))
    return name
  }

  private readBody(s: AnySchema, shape: Shape): string {
    switch (shape.kind) {
      case "array": {
        const item = this.read(shape.item)
        return `  ${STEP}
  if (r.next() !== ${ARRAY}) fail()
  r.openList()
  const out = []
  while (r.more(${CLOSE_ARRAY})) {
    out.push(${item}(r, cx, depth + 1))
    r.endItem(${CLOSE_ARRAY})
  }
  return out`
      }
      case "map": {
        const value = this.read(shape.value)
        return `  ${STEP}
  if (r.next() !== ${RECORD}) fail()
  r.openRecord()
  const out = new Map()
  for (let key = r.key(); key !== undefined; key = r.key()) {
    const size = out.size
    out.set(key, ${value}(r, cx, depth + 1))
    if (out.size === size) fail()
    r.endField()
  }
  return out`
      }
      case "maybe": {
        const inner = this.read(shape.inner)
        const none = this.ref(shape.none, "None")
        return `  ${STEP}
  if (r.next() !== ${VARIANT}) fail()
  const tag = r.tag()
  const p = r.payload(tag)
  if (tag === "None" && p === ${NO_PAYLOAD}) return ${none}
  if (tag !== "Some") fail()
${oneArgument("value", inner)}
  return { _tag: "Some", value }`
      }
      case "record": {
        const fields = this.fields(s)
        return `  ${STEP}
  if (r.next() !== ${RECORD}) fail()
  return ${fields}(r, cx, depth, undefined)`
      }
      case "variant":
        return this.variantBody(shape.open, shape.cases())
      case "secret": {
        checkChain(s)
        const inner = this.read(shape.inner)
        return `  ${STEP}\n  return new Secret(${inner}(r, cx, depth))`
      }
      case "refine": {
        checkChain(s)
        const inner = this.read(shape.inner)
        const check = this.ref(shape.check, "a refinement's check")
        return `  const a = ${inner}(r, cx, depth)\n  return ${check}(a) === undefined ? a : fail()`
      }
      case "recursive": {
        checkChain(s)
        const body = this.read(shape.body())
        return `${this.enterRecursive(shape)}
  const out = ${body}(r, cx, depth)
  state.depth--
  return out`
      }
      default:
        throw new Error(`no generated reader for ${shape.kind}`)
    }
  }

  /** Entering a Recursive (codec.ts `enterRecursive`): a step, and one level more of it within its limit; `state.depth--` after. */
  private enterRecursive(shape: RecursiveShape): string {
    const self = this.ref(shape.self, "a Recursive")
    return `  ${STEP}
  const state = recursionOf(cx, ${self})
  if (state.depth >= ${shape.maxDepth}) fail()
  state.depth++`
  }

  /**
   * The name of a record's fields reader `(r, cx, depth, tag) => object` (at
   * its counted `{`): a RecordSchema's, or a Recursive's that is a record case.
   */
  private fields(s: AnySchema): string {
    const known = this.fieldReaders.get(s) ?? this.earlier("fields", s)
    if (known !== undefined) return known
    const shape = shapeOf(s)
    const name = this.name("f")
    this.fieldReaders.set(s, name)
    let body: string
    if (shape?.kind === "recursive") {
      const inner = this.fields(shape.body())
      body = `${this.enterRecursive(shape)}
  const out = ${inner}(r, cx, depth, tag)
  state.depth--
  return out`
    } else if (shape?.kind === "record") body = this.fieldsBody(shape)
    else throw new Error("a record case written by hand")
    this.define("fields", s, name, "r, cx, depth, tag", body)
    return name
  }

  /**
   * A record's fields into locals (any order; a duplicate, a missing field, or
   * an unknown one of a closed record fails), then the object in the schema's
   * order: one literal when every field is there, else field by field.
   */
  private fieldsBody(shape: Extract<Shape, { kind: "record" }>): string {
    const entries = shape.entries
    const keys = entries.map(([k]) => k)
    const optional = entries.map(([, schema]) => schema.optional === true)
    const readers = entries.map(([, schema]) => this.read(schema))
    const index = this.ref(new Map(keys.map((k, i) => [k, i])), `the keys ${JSON.stringify(keys)}`)
    const n = keys.length
    const v = (i: number) => `v${i}`
    const lines: string[] = []
    lines.push("  r.openRecord()")
    if (n > 0) lines.push(`  let ${keys.map((_, i) => `${v(i)} = HOLE`).join(", ")}`)
    lines.push("  let next = 0, unknown")
    lines.push("  for (;;) {")
    lines.push("    let i = -1")
    // The next field in order, compared in place (bare keys only).
    const inOrder = keys.map((k, i) => (BARE_KEY.test(k) ? `      case ${i}: if (r.keyIs(${JSON.stringify(k)})) i = ${i}; break\n` : "")).join("")
    if (inOrder !== "") lines.push(`    switch (next) {\n${inOrder}    }`)
    lines.push("    if (i < 0) {")
    lines.push("      const key = r.key()")
    lines.push("      if (key === undefined) break")
    lines.push(`      i = ${index}.get(key) ?? -1`)
    lines.push("      if (i < 0) {")
    if (shape.closed) lines.push("        fail()")
    else {
      lines.push("        if (unknown === undefined) unknown = new Set()")
      lines.push("        const size = unknown.size")
      lines.push("        unknown.add(key)")
      lines.push("        if (unknown.size === size) fail()")
      lines.push("        readValue(r)")
      lines.push("        r.endField()")
      lines.push("        continue")
    }
    lines.push("      }")
    lines.push("    }")
    if (n > 0) {
      lines.push("    switch (i) {")
      keys.forEach((_, i) => lines.push(`      case ${i}: if (${v(i)} !== HOLE) fail(); ${v(i)} = ${readers[i]}(r, cx, depth + 1); break`))
      lines.push("    }")
    }
    lines.push("    next = i + 1")
    lines.push("    r.endField()")
    lines.push("  }")
    const required = keys.map((_, i) => i).filter((i) => !optional[i])
    if (required.length > 0) lines.push(`  if (${required.map((i) => `${v(i)} === HOLE`).join(" || ")}) fail()`)
    // Every field there: one literal, the same shape every time.
    const literal = (tagged: boolean) => `{ ${[...(tagged ? ["_tag: tag"] : []), ...keys.map((k, i) => `${literalKey(k)}: ${v(i)}`)].join(", ")} }`
    const whole = `tag === undefined ? ${literal(false)} : ${literal(true)}`
    const optionals = keys.map((_, i) => i).filter((i) => optional[i])
    if (optionals.length === 0) lines.push(`  return ${whole}`)
    else {
      lines.push(`  if (${optionals.map((i) => `${v(i)} !== HOLE`).join(" && ")}) return ${whole}`)
      lines.push("  const out = tag === undefined ? {} : { _tag: tag }")
      keys.forEach((k, i) => {
        // A key of the prototype chain (`__proto__`, `toString`, …) is defined, as `setOwn` does.
        const set = k in {} ? `define(out, ${JSON.stringify(k)}, ${v(i)})` : `out${member(k)} = ${v(i)}`
        lines.push(optional[i] ? `  if (${v(i)} !== HOLE) ${set}` : `  ${set}`)
      })
      lines.push("  return out")
    }
    return lines.join("\n")
  }

  private variantBody(open: boolean, shapes: ReadonlyMap<string, CaseShape>): string {
    const tags = [...shapes.keys()]
    const index = this.ref(new Map(tags.map((t, i) => [t, i])), `the tags ${JSON.stringify(tags)}`)
    const cases = [...shapes.values()].map((c, i) => `    case ${i}: {\n${this.caseRead(c)}\n    }\n`).join("")
    return `  ${STEP}
  if (r.next() !== ${VARIANT}) fail()
  const tag = r.tag()
  switch (${index}.get(tag)) {
${cases}  }
  ${open ? "return unknownOf(readVariantAfter(r, tag))" : "return fail()"}`
  }

  /** A case's payload, after the tag, as codec.ts's `case` reads it. */
  private caseRead(c: CaseShape): string {
    switch (c.kind) {
      case "unit":
        return `      return r.payload(tag) === ${NO_PAYLOAD} ? { _tag: tag } : fail()`
      case "record": {
        const fields = this.fields(c.schema)
        const of = c.nests ? "undefined" : "tag"
        return `      const p = r.payload(tag)
      let out
      if (p === ${PAYLOAD_RECORD}) {
        if (r.next() !== ${RECORD}) fail()
        out = ${fields}(r, cx, depth, ${of})
      } else {
        if (p !== ${ARGS} || r.next() !== ${RECORD}) fail()
        out = ${fields}(r, cx, depth, ${of})
        r.endItem(${CLOSE_ARGS})
        if (r.more(${CLOSE_ARGS})) fail()
      }
      return ${c.nests ? "{ _tag: tag, value: out }" : "out"}`
      }
      case "tuple": {
        const items = c.items.map((s) => this.read(s))
        if (items.length === 0) return `      return r.payload(tag) === ${NO_PAYLOAD} ? { _tag: tag, values: [] } : fail()`
        if (items.length === 1) return `      const p = r.payload(tag)\n${oneArgument("value", items[0]!, "      ")}\n      return { _tag: tag, values: [value] }`
        const reads = items.map((item, i) => `${i > 0 ? `      if (!r.more(${CLOSE_ARGS})) fail()\n` : ""}      const x${i} = ${item}(r, cx, depth + 1)\n      r.endItem(${CLOSE_ARGS})`).join("\n")
        return `      if (r.payload(tag) !== ${ARGS}) fail()
${reads}
      if (r.more(${CLOSE_ARGS})) fail()
      return { _tag: tag, values: [${items.map((_, i) => `x${i}`).join(", ")}] }`
      }
      case "value": {
        const inner = this.read(c.schema)
        return `      const p = r.payload(tag)\n${oneArgument("value", inner, "      ")}\n      return { _tag: tag, value }`
      }
    }
  }

  // ── writers ────────────────────────────────────────────────

  /** The name of `s`'s writer `(w, a, cx, depth) => void`. */
  write(s: AnySchema): string {
    const known = this.writers.get(s)
    if (known !== undefined) return known
    const shape = shapeOf(s)
    if (shape === undefined || LEAVES.has(shape.kind)) {
      const name = this.ref(this.leafWriters.write(s), `write ${leafNote(s, shape)}`)
      this.writers.set(s, name)
      return name
    }
    const before = this.earlier("write", s)
    if (before !== undefined) {
      this.writers.set(s, before)
      return before
    }
    const name = this.name("w")
    this.writers.set(s, name)
    this.define("write", s, name, "w, a, cx, depth", this.writeBody(s, shape))
    return name
  }

  private writeBody(s: AnySchema, shape: Shape): string {
    switch (shape.kind) {
      case "array": {
        const item = this.write(shape.item)
        return `  ${STEP}
  if (!Array.isArray(a) || depth >= cx.maxDepth) fail()
  w.s += "["
  for (let i = 0; i < a.length; i++) {
    if (i > 0) w.s += w.comma
    const x = a[i]
    if (x === undefined && !(i in a)) fail()
    ${item}(w, x, cx, depth + 1)
  }
  w.s += "]"`
      }
      case "map": {
        const value = this.write(shape.value)
        return `  ${STEP}
  if (!(a instanceof Map) || depth >= cx.maxDepth) fail()
  if (a.size === 0) { w.s += "{}"; return }
  const colon = w.tight ? ":" : ": "
  let first = true
  for (const [k, x] of a) {
    if (typeof k !== "string") fail()
    w.s += (first ? w.open : w.comma) + keyText(k) + colon
    first = false
    ${value}(w, x, cx, depth + 1)
  }
  w.s += w.close`
      }
      case "maybe": {
        const inner = this.argument(shape.inner, "a.value", "  ")
        return `  ${STEP}
  if (!isMaybe(a)) fail()
  if (a._tag === "None") { w.s += "None"; return }
  if (depth >= cx.maxDepth) fail()
  w.s += "Some"
${inner}`
      }
      case "record": {
        const fields = this.fieldWriter(s)
        return `  ${STEP}\n  ${fields}(w, a, cx, depth, false)`
      }
      case "variant":
        return this.variantWriteBody(shape.open, shape.cases())
      case "secret": {
        checkChain(s)
        const inner = this.write(shape.inner)
        return `  ${STEP}\n  if (!(a instanceof Secret)) fail()\n  ${inner}(w, a.expose(), cx, depth)`
      }
      case "refine": {
        checkChain(s)
        const inner = this.write(shape.inner)
        const check = this.ref(shape.check, "a refinement's check")
        return `  if (${check}(a) !== undefined) fail()\n  ${inner}(w, a, cx, depth)`
      }
      case "recursive": {
        checkChain(s)
        const body = this.write(shape.body())
        return `${this.enterRecursive(shape)}\n  ${body}(w, a, cx, depth)\n  state.depth--`
      }
      default:
        throw new Error(`no generated writer for ${shape.kind}`)
    }
  }

  /** `s` written as a variant's one argument (the value is `value`, one level deeper), after its tag: ` { … }` or `(…)`. */
  private argument(s: AnySchema, value: string, indent: string): string {
    const inner = this.write(s)
    switch (argumentForm(s)) {
      case "record":
        return `${indent}w.s += w.tag\n${indent}${inner}(w, ${value}, cx, depth + 1)`
      case "other":
        return `${indent}w.s += "("\n${indent}${inner}(w, ${value}, cx, depth + 1)\n${indent}w.s += ")"`
      case "either":
        // Written apart first: a record is the only value that starts with `{`.
        return `${indent}const part = new Out(w.style)
${indent}${inner}(part, ${value}, cx, depth + 1)
${indent}w.s += part.s.startsWith("{") ? w.tag + part.s : "(" + part.s + ")"`
    }
  }

  /** The name of a record's fields writer `(w, a, cx, depth, enumerable)`: a RecordSchema's, or a Recursive's that is a record case. */
  private fieldWriter(s: AnySchema): string {
    const known = this.fieldWriters.get(s) ?? this.earlier("fieldWrite", s)
    if (known !== undefined) return known
    const shape = shapeOf(s)
    const name = this.name("g")
    this.fieldWriters.set(s, name)
    let body: string
    if (shape?.kind === "recursive") {
      const inner = this.fieldWriter(shape.body())
      body = `${this.enterRecursive(shape)}\n  ${inner}(w, a, cx, depth, enumerable)\n  state.depth--`
    } else if (shape?.kind === "record") body = this.fieldWriterBody(shape)
    else throw new Error("a record case written by hand")
    this.define("fieldWrite", s, name, "w, a, cx, depth, enumerable", body)
    return name
  }

  /** As codec.ts's `writeFields`, each field with its key as constant text. */
  private fieldWriterBody(shape: Extract<Shape, { kind: "record" }>): string {
    const lines = [
      "  if (typeof a !== \"object\" || a === null) fail()",
      "  if (depth >= cx.maxDepth) fail()",
      "  const tight = w.tight",
      "  let v",
    ]
    // Whether something was written before a field: no, yes, or only known when writing.
    let written: "no" | "yes" | "maybe" = "no"
    const usesFirst = shape.entries.some(([, schema]) => schema.optional === true)
    if (usesFirst) lines.push("  let first = true")
    for (const [key, schema] of shape.entries) {
      const writer = this.write(schema)
      const k = JSON.stringify(key)
      const text = keyText(key)
      const separator = written === "no" ? "w.open" : written === "yes" ? "w.comma" : "(first ? w.open : w.comma)"
      const write = [
        `w.s += ${separator} + (tight ? ${JSON.stringify(`${text}:`)} : ${JSON.stringify(`${text}: `)})`,
        ...(usesFirst ? ["first = false"] : []),
        `${writer}(w, v, cx, depth + 1)`,
      ]
      lines.push(`  v = (enumerable ? isEnumerable.call(a, ${k}) : hasOwn(a, ${k})) ? a${member(key)} : undefined`)
      if (schema.optional === true) {
        lines.push(`  if (v !== undefined) { ${write.join("; ")} }`)
        if (written === "no") written = "maybe"
      } else {
        lines.push(`  ${write.join("; ")}`)
        written = "yes"
      }
    }
    lines.push(written === "no" ? '  w.s += "{}"' : written === "yes" ? "  w.s += w.close" : '  w.s += first ? "{}" : w.close')
    return lines.join("\n")
  }

  private variantWriteBody(open: boolean, shapes: ReadonlyMap<string, CaseShape>): string {
    const tags = [...shapes.keys()]
    const index = this.ref(new Map(tags.map((t, i) => [t, i])), `the tags ${JSON.stringify(tags)}`)
    const cases = [...shapes.values()].map((c, i) => `    case ${i}: {\n${this.caseWrite(c)}\n      return\n    }\n`).join("")
    const unknown = open
      ? `  if (tag === "@unknown") {
    const raw = checkedValue(a.value, At.nested(cx, depth))
    if (raw.kind !== "variant" || ${index}.has(raw.tag)) fail()
    w.value(raw)
    return
  }\n`
      : ""
    return `  ${STEP}
  if (typeof a !== "object" || a === null) fail()
  const tag = a._tag
  if (typeof tag !== "string") fail()
${unknown}  switch (${index}.get(tag)) {
${cases}  }
  fail()`
  }

  private caseWrite(c: CaseShape): string {
    switch (c.kind) {
      case "unit":
        return "      w.s += tag"
      case "record": {
        const fields = this.fieldWriter(c.schema)
        return c.nests
          ? `      w.s += tag + w.tag\n      ${fields}(w, a.value, cx, depth, false)`
          : `      w.s += tag + w.tag\n      ${fields}(w, a, cx, depth, true)`
      }
      case "tuple": {
        const n = c.items.length
        const check = `      const values = a.values\n      if (!Array.isArray(values) || values.length !== ${n}) fail()`
        if (n === 0) return `${check}\n      w.s += tag`
        if (n === 1) return `${check}\n      if (depth >= cx.maxDepth) fail()\n      w.s += tag\n${this.argument(c.items[0]!, "values[0]", "      ")}`
        const items = c.items.map((s, i) => `${i > 0 ? "      w.s += w.comma\n" : ""}      ${this.write(s)}(w, values[${i}], cx, depth + 1)`).join("\n")
        return `${check}\n      if (depth >= cx.maxDepth) fail()\n      w.s += tag + "("\n${items}\n      w.s += ")"`
      }
      case "value":
        return `      if (depth >= cx.maxDepth) fail()\n      w.s += tag\n${this.argument(c.schema, "a.value", "      ")}`
    }
  }
}

/** After `const p = r.payload(tag)`: the one argument into `name` (codec.ts `oneArgument`), read by `read` one level deeper. */
const oneArgument = (name: string, read: string, indent = "  "): string =>
  `${indent}let ${name}
${indent}if (p === ${PAYLOAD_RECORD}) ${name} = ${read}(r, cx, depth + 1)
${indent}else {
${indent}  if (p !== ${ARGS}) fail()
${indent}  ${name} = ${read}(r, cx, depth + 1)
${indent}  r.endItem(${CLOSE_ARGS})
${indent}  if (r.more(${CLOSE_ARGS})) fail()
${indent}}`

const hashOf = (source: string): string => toHex(new Sha256().update(new TextEncoder().encode(source)).digest())

/**
 * The generated source for `roots` (each must have closure-compiled codecs:
 * `compilable`), with the runtime objects it refers to. Throws if a schema
 * can't be generated. `reuse`: call functions generated before.
 */
export const generate = (roots: readonly AnySchema[], reuse = false): Generated => {
  const g = new Generator(reuse)
  const pairs = roots.map((s) => `[${g.read(s)}, ${g.write(s)}]`)
  const source = g.source(pairs)
  return { source, env: g.env, hash: hashOf(source), made: g.made }
}

/** Whether the closures compile both of `s`'s codecs: only then is it generated. */
const compilable = (s: AnySchema): boolean => compiledReader(s) !== undefined && compiledWriter(s) !== undefined

// ── groups, built-ahead code, and the choice of path ─────────

/**
 * A schema file's schemas (`groupSchemas`), and the code @haus-fmt/import
 * built ahead for them (`registerCodecs`), generated as one unit.
 */
interface Group {
  readonly roots: readonly AnySchema[]
  prebuilt?: { readonly hash: string; readonly factory: Factory } | undefined
}

const groupOfSchemas = new WeakMap<object, Group>()
const groupOf = new WeakMap<AnySchema, Group>()

/** Mark `schemas` (a schema file's, by name) as one group, for code built ahead for them (`registerCodecs`). */
export const groupSchemas = (schemas: Readonly<Record<string, AnySchema>>): void => {
  const group: Group = { roots: Object.values(schemas) }
  groupOfSchemas.set(schemas, group)
  for (const s of group.roots) groupOf.set(s, group)
}

/**
 * The code @haus-fmt/import generated ahead for `schemas` (grouped by
 * `groupSchemas`, as `fromSchemaFile` does), with the hash of its source.
 * It is used if the source generated again at first use has the same hash.
 */
export const registerCodecs = (schemas: Readonly<Record<string, AnySchema>>, hash: string, factory: Factory): void => {
  const group = groupOfSchemas.get(schemas)
  if (group !== undefined) group.prebuilt = { hash, factory }
}

/** The roots of a group that are generated: those the closures compile. */
const groupRoots = (schemas: Readonly<Record<string, AnySchema>>): AnySchema[] => Object.values(schemas).filter(compilable)

/**
 * The source @haus-fmt/import puts in a module for a schema file's schemas
 * (`fromSchemaFile`'s): the body of a `Factory` and its hash, as
 * `registerCodecs` takes them, generated as at first use. Undefined if
 * nothing can be generated.
 */
export const generateCodecs = (schemas: Readonly<Record<string, AnySchema>>): { readonly source: string; readonly hash: string } | undefined => {
  const roots = groupRoots(schemas)
  if (roots.length === 0) return undefined
  try {
    const { source, hash } = generate(roots)
    return { source, hash }
  } catch {
    return undefined
  }
}

let evalAllowed: boolean | undefined

/** Whether `new Function` works here (not under a content security policy that forbids it). Tried once. */
const canEval = (): boolean => {
  if (evalAllowed === undefined) {
    try {
      evalAllowed = new Function("return true")() === true
    } catch {
      evalAllowed = false
    }
  }
  return evalAllowed
}

interface Codec {
  readonly read: Read
  readonly write: Write
  /** Where the code came from: built ahead (@haus-fmt/import), or made here with `new Function`. */
  readonly origin: "built ahead" | "new Function"
}

/** Each schema's generated codecs once settled (null: none). */
const codecs = new WeakMap<AnySchema, Codec | null>()

/** Run a generation: its functions published for later ones, its roots' codecs settled. */
const run = (gen: Generated, roots: readonly AnySchema[], factory: Factory, origin: Codec["origin"]): void => {
  const { roots: pairs, made } = factory((rt ??= runtime()), gen.env)
  gen.made.forEach(([kind, s], i) => {
    if (!published[kind].has(s)) published[kind].set(s, made[i])
  })
  roots.forEach((s, i) => codecs.set(s, { read: pairs[i]![0], write: pairs[i]![1], origin }))
}

/**
 * The generated codecs of `schema`, made on first use: the code built ahead
 * for its group if its hash is right (generated again here, which also gives
 * the runtime objects it uses), else with `new Function`, schema by schema
 * (calling what was generated before), unless `atRunTime` is false.
 * Undefined where there is none.
 */
const generated = (schema: AnySchema, atRunTime = true): Codec | undefined => {
  const known = codecs.get(schema)
  if (known !== undefined) return known ?? undefined
  const group = groupOf.get(schema)
  const prebuilt = group?.prebuilt
  if (group !== undefined && prebuilt !== undefined) {
    // Once per group, whatever the outcome.
    group.prebuilt = undefined
    try {
      const roots = group.roots.filter(compilable)
      const gen = generate(roots)
      if (gen.hash === prebuilt.hash) run(gen, roots, prebuilt.factory, "built ahead")
    } catch {
      // The generic path or `new Function` below.
    }
    const settled = codecs.get(schema)
    if (settled !== undefined) return settled ?? undefined
  }
  if (!atRunTime) return undefined
  codecs.set(schema, null)
  if (!canEval() || !compilable(schema)) return undefined
  try {
    const gen = generate([schema], true)
    run(gen, [schema], new Function("rt", "env", gen.source) as Factory, "new Function")
  } catch {
    codecs.set(schema, null)
  }
  return codecs.get(schema) ?? undefined
}

/** For tests and debugging: where `schema`'s generated codecs came from, once made (`codec: "generated"` makes them). */
export const generatedOrigin = (schema: AnySchema): Codec["origin"] | undefined => codecs.get(schema)?.origin

/**
 * Which codecs `h.parse` and `h.stringify` use (`Options.codec`):
 * - `"auto"` (default): generated code where @haus-fmt/import built it ahead,
 *   else the closures; the generic path for a schema neither compiles;
 * - `"generated"`, `"closures"`: only that kind of codec (`"generated"` makes
 *   it with `new Function` where it wasn't built ahead), else the generic path;
 * - `"generic"`: parse to a `Value` and decode; encode to a `Value` and format.
 *
 * All give the same values, texts and errors. `"auto"` never generates code at
 * run time: generated code is faster only for a schema used many times (up to
 * 40% for one type read and written over and over), while a corpus of hundreds
 * of types, each used a few times, runs as fast or faster on the closures,
 * which V8 optimizes once for all types. Choose `"generated"` for the former.
 */
export type CodecChoice = "auto" | "generated" | "closures" | "generic"

/** The codecs @haus-fmt/import built ahead for `schema`, once they are settled; undefined if there are none. */
const builtAhead = (schema: AnySchema): Codec | undefined => {
  const known = codecs.get(schema)
  if (known === undefined && groupOf.get(schema)?.prebuilt === undefined) return undefined
  const codec = known ?? generated(schema, false)
  return codec?.origin === "built ahead" ? codec : undefined
}

/** The reader `h.parse` uses for `schema`, or undefined for the generic path. */
export const readerFor = (schema: AnySchema, choice: CodecChoice = "auto"): Read | undefined => {
  switch (choice) {
    case "generic": return undefined
    case "closures": return compiledReader(schema)
    case "generated": return generated(schema)?.read
    default: return builtAhead(schema)?.read ?? compiledReader(schema)
  }
}

/** The writer `h.stringify` uses for `schema` (compact and minimised), or undefined for the generic path. */
export const writerFor = (schema: AnySchema, choice: CodecChoice = "auto"): Write | undefined => {
  switch (choice) {
    case "generic": return undefined
    case "closures": return compiledWriter(schema)
    case "generated": return generated(schema)?.write
    default: return builtAhead(schema)?.write ?? compiledWriter(schema)
  }
}
