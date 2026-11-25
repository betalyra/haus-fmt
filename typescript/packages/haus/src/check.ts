/**
 * Check data against a schema file, for editors and `haus check`: every
 * problem with its position, in one linear pass over the data.
 *
 *   const file = parseSchemaFile(schemaText)
 *   const issues = checkData(file, "Root", parseWithLocations(dataText))
 *
 * Errors are values the schema doesn't allow. Hints are fields and tags an
 * open type doesn't list: allowed (a reader ignores them, or reads the tag as
 * unknown), but maybe a typo, so editors mark them gently; and fields and
 * tags the schema marks `@deprecated` (spec §14).
 *
 * Values of a `Secret` type are never shown (spec §15): a problem inside one
 * is reported as one error at the secret, with its type and not its value.
 */
import { deprecationNote, type Case, type Field, type Instance, type RecordType, type SchemaFile, type StdType, type Type, type VariantType } from "./schema-file.js"
import { checkWellFormed, formatPath, HausSyntaxError, payloadHint, type CasePayload, type ErrorCode } from "./errors.js"
import { Parser, withDefaults, type Limits } from "./parser.js"
import { toFloat } from "./float.js"
import { checkStdTime } from "./std-time.js"
import type { HRecord, HVariant, Value } from "./value.js"

export interface CheckIssue {
  readonly severity: "error" | "hint"
  /** Its code (spec §17), e.g. `missing-field`, or `unlisted-field` for a hint. */
  readonly code: ErrorCode
  readonly message: string
  /** A concrete fix, where the checker knows one (`wrong-payload`: what the tag's case takes); otherwise the catalogue's fix for the code applies. */
  readonly hint?: string
  /** The place of a problem with the data (spec §15): `$.items[2].price`. None for a syntax or limit error of the text. */
  readonly path?: string
  /** For a syntax or limit error of the text (`checkText`): its line and column (spec §8). */
  readonly line?: number
  readonly column?: number
  /** UTF-16 offsets into the data text, `end` exclusive. */
  readonly start: number
  readonly end: number
}

/** A check stops after this many errors (hints don't count) and says so (spec §14, "Every error"). */
export const MAX_ERRORS = 200


const RANGES: Record<string, readonly [bigint, bigint]> = {
  Int8: [-(2n ** 7n), 2n ** 7n - 1n],
  Int16: [-(2n ** 15n), 2n ** 15n - 1n],
  Int32: [-(2n ** 31n), 2n ** 31n - 1n],
  Int64: [-(2n ** 63n), 2n ** 63n - 1n],
  UInt8: [0n, 2n ** 8n - 1n],
  UInt16: [0n, 2n ** 16n - 1n],
  UInt32: [0n, 2n ** 32n - 1n],
  UInt64: [0n, 2n ** 64n - 1n],
}

/** The integer value of a number literal, if it is a whole number. */
function integer(text: string): bigint | undefined {
  const t = text.replaceAll("_", "")
  const negative = t.startsWith("-")
  const body = negative ? t.slice(1) : t
  if (!/^(0x[0-9a-fA-F]+|0b[01]+|\d+)$/.test(body)) return undefined
  const n = BigInt(body)
  return negative ? -n : n
}

/** Edit distance, for "did you mean". Short strings only. */
function distance(a: string, b: string): number {
  if (Math.abs(a.length - b.length) > 2 || a.length > 64 || b.length > 64) return 3
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i)
  for (let i = 1; i <= a.length; i++) {
    const cur = [i]
    for (let j = 1; j <= b.length; j++) cur[j] = Math.min(prev[j]! + 1, cur[j - 1]! + 1, prev[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1))
    prev = cur
  }
  return prev[b.length]!
}

const suggest = (word: string, candidates: Iterable<string>): string => {
  let best: string | undefined
  let bestDistance = 3
  for (const c of candidates) {
    const d = distance(word.toLowerCase(), c.toLowerCase())
    if (d < bestDistance) (best = c), (bestDistance = d)
  }
  return best === undefined ? "" : ` Did you mean ${best}?`
}

const quoteKey = (k: string) => (/^[a-z_][A-Za-z0-9_]*$/.test(k) ? k : JSON.stringify(k))

/** A short description of a value, for messages. */
function found(v: Value): string {
  switch (v.kind) {
    case "string":
      return v.value.length > 20 ? "a string" : `the string ${JSON.stringify(v.value)}`
    case "number":
      return `the number ${v.text.length > 20 ? v.text.slice(0, 20) + "…" : v.text}`
    case "bytes":
      return "bytes"
    case "array":
      return "an array"
    case "record":
      return "a record"
    case "variant":
      return `the tag ${v.tag}`
  }
}

/** A short description of a type, for messages. */
function describe(t: Type): string {
  switch (t.kind) {
    case "builtin":
    case "std":
      return t.name
    case "array":
      return `Array ${atom(t.item)}`
    case "map":
      return `Map ${atom(t.value)}`
    case "maybe":
      return `Maybe ${atom(t.item)}`
    case "secret":
      return `Secret ${atom(t.item)}`
    case "record":
      return "a record"
    case "variant":
      return tags(t)
    case "ref":
      return t.instance.args.length === 0 ? t.instance.name : `${t.instance.name} ${t.instance.args.map(atom).join(" ")}`
    case "param":
      return t.name
  }
}
/** A record type's fields, as in the schema: `{ r: Float64, label?: String }` (long ones shortened). */
const recordFields = (r: RecordType): string => {
  const fields = r.fields.map((f) => `${quoteKey(f.key)}${f.optional ? "?" : ""}: ${describe(f.type)}`)
  const shown = fields.length > 6 ? [...fields.slice(0, 6), "…"] : fields
  return shown.length === 0 ? "{}" : `{ ${shown.join(", ")} }`
}

/** A short description of a type, as in the schema: `Array Line`, `Maybe Int`, `one of A, B`. */
export const describeType = (t: Type): string => describe(t)

const atom = (t: Type) => {
  const d = describe(t)
  return d.includes(" ") && !d.startsWith("<") ? `(${d})` : d
}
const tags = (v: VariantType) => {
  const names = v.cases.map((c) => c.tag)
  return names.length === 0 ? "any tag" : `one of ${names.slice(0, 6).join(", ")}${names.length > 6 ? ", …" : ""}`
}

/** How to check (`checkData`, `checkText`). */
export interface CheckOptions {
  /**
   * Called for every value with the type the schema expects there (as
   * written: `Comment`, not its body). `secret` is true for a value of a
   * `Secret` type and the values inside it, which tools should not show.
   * A secret's value is passed twice: with its `Secret` type, then with the type inside.
   */
  readonly onValue?: (value: Value, type: Type, secret: boolean) => void
  /**
   * Stop at the first error (`haus check --first`), with the hints found
   * before it. By default every error is reported (spec §14, "Every error"),
   * up to MAX_ERRORS errors per check (hints don't count).
   */
  readonly first?: boolean
}

/** What a check found: the issues, as a set (their order is not specified, spec §14), and whether it stopped at MAX_ERRORS with more to check. */
export interface CheckReport {
  readonly issues: readonly CheckIssue[]
  /** The check stopped after MAX_ERRORS errors: the data has more. */
  readonly stopped: boolean
}

/**
 * Check parsed values (with locations, see `parseWithLocations`) against
 * type `typeName` of a schema file. A Stream type checks every value; any
 * other type expects exactly one. To check a text (a stream item by item,
 * with its syntax error), use `checkText`.
 */
export function checkData(file: SchemaFile, typeName: string, values: readonly Value[], options: CheckOptions = {}): CheckIssue[] {
  const walk = walker(file, typeName, options)
  if (walk === undefined) return rootIssues(file, typeName)
  walk.document(values)
  return walk.issues
}

/**
 * Check a data text against type `typeName` of a schema file, as `haus
 * check` does (spec §14, "Every error"). A `Stream` type is read item by
 * item, each item parsed then checked, so a syntax or limit error ends the
 * check after the errors of the items before it; any other type is parsed
 * whole first, and a syntax error is its only issue. A syntax or limit
 * error is an issue with its `line` and `column` and no `path`.
 */
export function checkText(file: SchemaFile, typeName: string, text: string, options: CheckOptions & { readonly limits?: Partial<Limits> } = {}): CheckReport {
  const walk = walker(file, typeName, options)
  if (walk === undefined) return { issues: rootIssues(file, typeName), stopped: false }
  const parser = new Parser(text, undefined, withDefaults(options.limits ?? {}), true)
  // An unpaired surrogate has no UTF-8 form: a syntax error at its place (the items before it are read and checked).
  const surrogate = wellFormedError(text)
  try {
    if (!walk.stream) {
      if (surrogate !== undefined) throw surrogate
      walk.document(parser.parseSequence())
    } else {
      let i = 0
      for (const item of parser.sequence()) {
        // There is more: at the cap, the check says it stopped.
        if (walk.halt()) break
        if (surrogate !== undefined && (item.end ?? 0) > surrogate.offset) throw surrogate
        walk.item(item, i++)
      }
      if (surrogate !== undefined) throw surrogate
    }
  } catch (e) {
    if (!(e instanceof HausSyntaxError)) throw e
    walk.syntax(surrogate !== undefined && surrogate.offset <= e.offset ? surrogate : e)
  }
  return { issues: walk.issues, stopped: walk.stopped() }
}

const wellFormedError = (text: string): HausSyntaxError | undefined => {
  try {
    checkWellFormed(text)
    return undefined
  } catch (e) {
    if (e instanceof HausSyntaxError) return e
    throw e
  }
}

/** The issue of a type that can't describe a whole file: none in the schema, or one with parameters. */
const rootIssues = (file: SchemaFile, typeName: string): CheckIssue[] => [
  file.definition(typeName) === undefined
    ? { severity: "error", code: "unknown-type", message: `the schema has no type ${typeName}`, path: "$", start: 0, end: 1 }
    : { severity: "error", code: "wrong-arity", message: `${typeName} needs arguments, so it can't describe a whole file`, path: "$", start: 0, end: 1 },
]

interface Walk {
  /** What was found so far. */
  readonly issues: CheckIssue[]
  /** Whether the type is a `Stream`. */
  readonly stream: boolean
  /** The values of a whole text: every item of a stream, else exactly one. */
  readonly document: (values: readonly Value[]) => void
  /** The item at `index` of a stream. */
  readonly item: (value: Value, index: number) => void
  /** A syntax or limit error of the text: the last issue. */
  readonly syntax: (e: HausSyntaxError) => void
  /** Whether nothing more is checked, asked when there is more: at the cap (the check then says it stopped), or after the first error when asked to. */
  readonly halt: () => boolean
  /** Whether the check stopped at the cap with more to check. */
  readonly stopped: () => boolean
}

function walker(file: SchemaFile, typeName: string, options: CheckOptions): Walk | undefined {
  const definition = file.definition(typeName)
  if (!definition || definition.params.length > 0) return undefined
  const root: Instance = definition.template
  const issues: CheckIssue[] = []
  /** The place being checked (spec §15): keys and indexes from `$`. */
  const path: (string | number)[] = []
  let errors = 0
  let capped = false

  const done = (): boolean => errors >= MAX_ERRORS || (options.first === true && errors > 0)
  /** Whether nothing more is checked; at the cap, the check says it stopped. */
  const halt = (): boolean => {
    if (errors >= MAX_ERRORS) capped = true
    return done()
  }
  const report = (severity: CheckIssue["severity"], code: ErrorCode, message: string, start = 0, end = start + 1, hint?: string) => {
    if (halt()) return
    if (severity === "error") errors++
    issues.push({ severity, code, message, ...(hint === undefined ? {} : { hint }), path: formatPath(path), start, end: Math.max(end, start + 1) })
  }
  /** `f` one step further in: a field's key, or an index. */
  const inside = (step: string | number, f: () => void): void => {
    path.push(step)
    f()
    path.pop()
  }
  /** A known tag with another payload than its case takes: the hint names the case. */
  const wrongPayload = (v: HVariant, message: string, takes: CasePayload) => report("error", "wrong-payload", message, ...at(v), payloadHint(v.tag, takes))
  const at = (v: Value) => [v.start ?? 0, v.end ?? (v.start ?? 0) + 1] as const
  const mismatch = (v: Value, t: Type, code: ErrorCode = "type-mismatch", hint?: string) => report("error", code, `expected ${describe(t)}, found ${found(v)}`, ...at(v), hint)
  /** For a closed variant with these tags (`Bool`, `Maybe`): an unknown tag, a known one with the wrong payload, or another kind of value. */
  const notCase = (v: Value, tags: readonly string[]): ErrorCode =>
    v.kind !== "variant" ? "type-mismatch" : tags.includes(v.tag) ? "wrong-payload" : "unknown-tag"
  const tagSpan = (v: HVariant) => [v.start ?? 0, (v.start ?? 0) + v.tag.length] as const

  const resolve = (t: Type): Type => {
    for (let i = 0; t.kind === "ref" && i < 10_000; i++) t = t.instance.body
    return t
  }

  /** How many `Secret`s the value being checked is inside. */
  let hidden = 0

  const check = (v: Value, type: Type): void => {
    const t = resolve(type)
    options.onValue?.(v, type, hidden > 0 || t.kind === "secret")
    if (halt()) return
    switch (t.kind) {
      case "builtin":
        return builtin(v, t.name, type)
      case "std":
        return std(v, t.name, type)
      case "array":
        if (v.kind !== "array") return mismatch(v, type)
        v.items.forEach((item, i) => inside(i, () => check(item, t.item)))
        return
      case "map":
        if (v.kind !== "record") return mismatch(v, type)
        for (const [key, x] of v.fields) inside(key, () => check(x, t.value))
        return
      case "maybe":
        if (v.kind === "variant" && v.tag === "None" && v.args.length === 0) return
        if (v.kind === "variant" && v.tag === "Some" && v.args.length === 1) return inside(0, () => check(v.args[0]!, t.item))
        return v.kind === "variant" && (v.tag === "None" || v.tag === "Some")
          ? wrongPayload(v, `expected None or Some(…) (${describe(type)}), found ${found(v)}`, v.tag === "None" ? { kind: "none" } : { kind: "args", types: [describe(t.item)] })
          : report("error", notCase(v, ["None", "Some"]), `expected None or Some(…) (${describe(type)}), found ${found(v)}`, ...at(v))
      case "secret": {
        // Check what's inside, then replace whatever was found there (messages
        // quote values, keys and tags of the data) by one error without them.
        const before = issues.length
        hidden++
        try {
          check(v, t.item)
        } finally {
          hidden--
        }
        const within = issues.splice(before).filter((i) => i.severity === "error").length
        errors -= within
        if (within > 0) report("error", "invalid-secret", `expected ${describe(t.item)} (a Secret: the value is not shown)`, ...at(v))
        return
      }
      case "record":
        if (v.kind !== "record") return mismatch(v, type)
        return record(v, t)
      case "variant":
        return variant(v, t, type)
      case "ref":
      case "param":
        return
    }
  }

  const builtin = (v: Value, name: string, type: Type): void => {
    switch (name) {
      case "Any":
        return
      case "String":
        if (v.kind !== "string") mismatch(v, type)
        return
      case "Bytes":
        if (v.kind !== "bytes") mismatch(v, type)
        return
      case "Bool":
        if (v.kind !== "variant" || (v.tag !== "True" && v.tag !== "False") || v.args.length > 0) mismatch(v, type, notCase(v, ["True", "False"]), v.kind === "variant" && (v.tag === "True" || v.tag === "False") ? payloadHint(v.tag, { kind: "none" }) : undefined)
        return
      case "Float32":
      case "Float64":
        if (v.kind === "variant" && ["NaN", "Infinity", "NegInfinity"].includes(v.tag) && v.args.length === 0) return
        if (v.kind !== "number") return mismatch(v, type)
        // Rounded to the nearest value; a number too large for the type is an error (spec §15).
        if (toFloat(v.text, name) === undefined) report("error", "out-of-range", `${v.text} is too large for ${name}`, ...at(v))
        return
      case "Decimal":
        // Any number: `0xFF` is 255, as the parser reads it (spec §2), and decodes as such.
        if (v.kind !== "number") mismatch(v, type)
        return
      default: {
        if (v.kind !== "number") return mismatch(v, type)
        const n = integer(v.text)
        if (n === undefined) return report("error", "not-an-integer", `expected a whole number (${name}), found ${v.text}`, ...at(v))
        const range = RANGES[name]
        if (range && (n < range[0] || n > range[1])) report("error", "out-of-range", `${v.text} is out of range for ${name} (${range[0]} to ${range[1]})`, ...at(v))
      }
    }
  }

  const std = (v: Value, name: StdType, type: Type): void => {
    if (v.kind !== "variant" || v.tag !== name) return mismatch(v, type)
    const [arg] = v.args
    if (v.args.length !== 1 || arg!.kind !== "string") return report("error", "type-mismatch", `write ${name}("…") with one string`, ...at(v))
    // The std/time profile (spec/std/time.md): built-in rules, like the ranges of Int8.
    const reason = checkStdTime(name, arg!.value)
    if (reason !== undefined) inside(0, () => report("error", "invalid-time", reason, ...at(arg!)))
  }

  const record = (v: HRecord, t: RecordType): void => {
    const known = new Map<string, Field>(t.fields.map((f) => [f.key, f]))
    // Each missing field is an error of its own, at the record (spec §14, "Every error").
    const start = v.start ?? 0
    for (const f of t.fields) if (!f.optional && !v.fields.has(f.key)) report("error", "missing-field", `missing field ${quoteKey(f.key)}`, start, start + 1)
    for (const [key, x] of v.fields) {
      const f = known.get(key)
      if (f) {
        const note = deprecationNote(quoteKey(key), f.attributes)
        inside(key, () => {
          if (note !== undefined) report("hint", "deprecated", note, ...(v.keySpans?.get(key) ?? at(x)))
          check(x, f.type)
        })
        continue
      }
      const [keyStart, keyEnd] = v.keySpans?.get(key) ?? at(x)
      const hint = suggest(key, [...known.keys()].filter((k) => !v.fields.has(k)))
      inside(key, () =>
        t.closed
          ? report("error", "unknown-field", `${quoteKey(key)} is not a field of this closed record.${hint}`, keyStart, keyEnd)
          : report("hint", "unlisted-field", `${quoteKey(key)} is not in the schema; a reader ignores it.${hint}`, keyStart, keyEnd),
      )
    }
  }

  const variant = (v: Value, t: VariantType, type: Type): void => {
    if (v.kind !== "variant") return mismatch(v, type)
    const c: Case | undefined = t.cases.find((x) => x.tag === v.tag)
    if (!c) {
      const hint = suggest(v.tag, t.cases.map((x) => x.tag))
      // `< >` lists no tags: any tag is meant, so there is nothing to hint.
      if (t.open) {
        if (t.cases.length > 0) report("hint", "unlisted-tag", `${v.tag} is not in the schema; a reader keeps it as an unknown value.${hint}`, ...tagSpan(v))
      }
      else report("error", "unknown-tag", `${v.tag} is not allowed here: expected ${tags(t)}.${hint}`, ...tagSpan(v))
      return
    }
    const note = deprecationNote(v.tag, c.attributes)
    if (note !== undefined) report("hint", "deprecated", note, ...tagSpan(v))
    const [first] = v.args
    switch (c.payload.kind) {
      case "none":
        if (v.args.length > 0) wrongPayload(v, `${v.tag} takes no payload`, { kind: "none" })
        return
      case "record":
        // One argument that is a record: `Circle(1.5)` is the wrong payload, at the variant (spec §15).
        if (v.args.length !== 1 || first!.kind !== "record") return wrongPayload(v, `${v.tag} takes one argument, a record`, { kind: "record", type: recordFields(c.payload.record) })
        return record(first!, c.payload.record)
      case "positional": {
        const items = c.payload.items
        if (v.args.length !== items.length) {
          return wrongPayload(v, `${v.tag} takes ${items.length} argument${items.length === 1 ? "" : "s"} (${items.map(describe).join(", ")}), found ${v.args.length}`, { kind: "args", types: items.map(describe) })
        }
        v.args.forEach((arg, i) => inside(i, () => check(arg, items[i]!)))
      }
    }
  }

  const item = (v: Value, index: number): void => inside(index, () => check(v, root.body))
  return {
    issues,
    stream: root.stream,
    item,
    document: (values) => {
      if (root.stream) values.forEach(item)
      else if (values.length !== 1) {
        const extra = values[1]
        report("error", "not-one-value", `expected one value (${typeName} is not a Stream), found ${values.length}`, ...(extra ? at(extra) : [0, 1] as const))
      } else check(values[0]!, root.body)
    },
    syntax: (e) => {
      if (halt()) return
      errors++
      issues.push({ severity: "error", code: e.code, message: e.reason, ...(e.hint === undefined ? {} : { hint: e.hint }), line: e.line, column: e.column, start: e.offset, end: e.offset + 1 })
    },
    halt,
    stopped: () => capped,
  }
}
