/**
 * The errors of the Effect adapter, with the error codes of spec §17.
 *
 * Every error has a `code` (stable, the same in every binding), a `hint`, a
 * `docs` link and a JSON form (`toJSON()`, `Haus.errorJson`) that is the
 * core's: `{ code, message, line?, column?, path?, expected?, found?, hint, docs }`.
 * Errors of the core keep their codes; the issues of Effect's own decoder are
 * given the code the core would report for the same value (see `issueError`).
 */
import {
  ERROR_CODES, errorDocs, errorHint, errorJson as coreErrorJson, formatPath, HausSyntaxError, type ErrorCode, type ErrorJson, type Path, type Value,
} from "@haus-fmt/haus"
import { Option, Schema, SchemaAST } from "effect"
import { ConversionError, isRedacted, secretMessage } from "./convert.js"

/** The error codes of spec §17. */
const Code = Schema.Literals(Object.keys(ERROR_CODES) as ReadonlyArray<ErrorCode>)

/** What every error says beyond its message (spec §17). */
const details = {
  /** The error's code (spec §17): stable, the same in every binding. */
  code: Code,
  /** What can be done about it: the catalogue's fix for the code, unless the error knows a better one. */
  hint: Schema.String,
  /** What should be there, e.g. `','` or `Int`. */
  expected: Schema.optionalKey(Schema.String),
  /** What is there instead. */
  found: Schema.optionalKey(Schema.String),
}

/** `expected` and `found`, where set. */
const detailsJson = (e: { readonly expected?: string; readonly found?: string }) => ({
  ...(e.expected !== undefined ? { expected: e.expected } : {}),
  ...(e.found !== undefined ? { found: e.found } : {}),
})

/**
 * The text is not valid haus (or not valid JSON). `line` and `column` are
 * left out where the position isn't known: invalid UTF-8 in a byte stream.
 */
export class HausParseError extends Schema.TaggedError<HausParseError, { readonly brand: unique symbol }>()("HausParseError", {
  message: Schema.String,
  line: Schema.optionalKey(Schema.Int),
  column: Schema.optionalKey(Schema.Int),
  ...details,
}) {
  /** `https://haus-fmt.org/docs/errors#<code>` */
  get docs(): string {
    return errorDocs(this.code)
  }

  /** The JSON form of spec §17: `{ code, message, line?, column?, expected?, found?, hint, docs }`. */
  override toJSON(): ErrorJson {
    if (this.line === undefined || this.column === undefined) {
      return { code: this.code, message: this.message, ...detailsJson(this), hint: this.hint, docs: this.docs }
    }
    const position = ` at ${this.line}:${this.column}`
    const message = this.message.endsWith(position) ? this.message.slice(0, -position.length) : this.message
    return { code: this.code, message, line: this.line, column: this.column, ...detailsJson(this), hint: this.hint, docs: this.docs }
  }
}

/**
 * Valid haus, but it doesn't match the schema (or a value can't be encoded).
 * `index` is set for stream elements.
 */
export class HausSchemaError extends Schema.TaggedError<HausSchemaError, { readonly brand: unique symbol }>()("HausSchemaError", {
  message: Schema.String,
  index: Schema.optionalKey(Schema.Int),
  /** Where in the decoded value the error is: field names and array indexes (see `locateIssue`). */
  path: Schema.optionalKey(Schema.Array(Schema.Union([Schema.String, Schema.Int]))),
  /** Where in the haus value the error is, as spec §17 writes it: `$.items[2].price`, `$.point[1]` for an argument. */
  place: Schema.optionalKey(Schema.String),
  ...details,
}) {
  /** `https://haus-fmt.org/docs/errors#<code>` */
  get docs(): string {
    return errorDocs(this.code)
  }

  /** The JSON form of spec §17: `{ code, message, path?, expected?, found?, hint, docs }`, and the `index` of a stream element. */
  override toJSON(): ErrorJson & { readonly index?: number } {
    const at = this.path === undefined ? "" : `\n  at ${effectPath(this.path)}`
    const message = at !== "" && this.message.endsWith(at) ? this.message.slice(0, -at.length) : this.message
    return {
      code: this.code,
      message,
      ...(this.place !== undefined ? { path: this.place } : {}),
      ...detailsJson(this),
      hint: this.hint,
      docs: this.docs,
      ...(this.index !== undefined ? { index: this.index } : {}),
    }
  }
}

/**
 * Limits that can't be used (spec §7): a `maxDepth` above `MAX_SUPPORTED_DEPTH`
 * (512), or not a whole number. The message names the maximum. Its code is
 * `unsupported-depth`.
 */
export class HausLimitsError extends Schema.TaggedError<HausLimitsError, { readonly brand: unique symbol }>()("HausLimitsError", {
  message: Schema.String,
  ...details,
}) {
  /** `https://haus-fmt.org/docs/errors#<code>` */
  get docs(): string {
    return errorDocs(this.code)
  }

  /** The JSON form of spec §17: `{ code, message, hint, docs }`. */
  override toJSON(): ErrorJson {
    return { code: this.code, message: this.message, ...detailsJson(this), hint: this.hint, docs: this.docs }
  }
}

export type HausError = HausParseError | HausSchemaError | HausLimitsError

/**
 * The JSON form of an error (spec §17), for tools and agents:
 *
 *   { code, message, line?, column?, path?, expected?, found?, hint, docs }
 *
 * For the errors of this package (`HausError`) and of the core; undefined for
 * anything else.
 */
export const errorJson = (e: unknown): ErrorJson | undefined =>
  e instanceof HausParseError || e instanceof HausSchemaError || e instanceof HausLimitsError ? e.toJSON() : coreErrorJson(e)

// ── building errors ──────────────────────────────────────────

/** The fields of an error with a code: the hint of the catalogue unless one is given. */
const withCode = (code: ErrorCode, d: { readonly hint?: string; readonly expected?: string | undefined; readonly found?: string | undefined } = {}) => ({
  code,
  hint: d.hint ?? errorHint(code),
  ...(d.expected !== undefined ? { expected: d.expected } : {}),
  ...(d.found !== undefined ? { found: d.found } : {}),
})

/** A syntax error of the core (haus or JSON text) as a HausParseError. */
export const parseError = (e: HausSyntaxError): HausParseError =>
  new HausParseError({ message: e.message, line: e.line, column: e.column, ...withCode(e.code, e) })

/** Invalid UTF-8 in a byte stream (the platform's decoder doesn't say where): no line or column. */
export const invalidUtf8Error = (): HausParseError => new HausParseError({ message: "invalid UTF-8", ...withCode("invalid-utf8") })

/** A HausLimitsError (spec §7). */
export const limitsError = (message: string): HausLimitsError => new HausLimitsError({ message, ...withCode("unsupported-depth") })

/** A HausSchemaError without a place in a value (`not-one-value`, …). */
export const schemaErrorOf = (message: string, code: ErrorCode): HausSchemaError => new HausSchemaError({ message, ...withCode(code) })

/** The same error for the stream element `index`. */
export const atIndex = (e: HausSchemaError, index: number): HausSchemaError => new HausSchemaError({ ...fieldsOf(e), index })

const fieldsOf = (e: HausSchemaError) => ({
  message: e.message,
  ...(e.path !== undefined ? { path: e.path } : {}),
  ...(e.place !== undefined ? { place: e.place } : {}),
  ...withCode(e.code, e),
})

type Key = string | number

/** A path as Effect writes it in messages: `["items"][2]`. */
const effectPath = (path: ReadonlyArray<Key>) => path.map((k) => `[${JSON.stringify(k)}]`).join("")

/**
 * An error at `path` (where in the decoded value, as Effect's issues have it),
 * with its place in `input`, the haus value decoded (see `hausPath`).
 */
const located = (message: string, code: ErrorCode, path: ReadonlyArray<Key>, input: Value | undefined, d: { readonly expected?: string; readonly found?: string } = {}) =>
  new HausSchemaError({
    message: path.length === 0 ? message : `${message}\n  at ${effectPath(path)}`,
    ...(path.length === 0 ? {} : { path: [...path] }),
    place: formatPath(input === undefined ? path : hausPath(input, path, code)),
    ...withCode(code, d),
  })

/** A conversion error (convert.ts), decoding `input` or encoding. */
export const conversionError = (e: ConversionError, input?: Value): HausSchemaError => located(e.message, e.code, e.path, input)

/** An error of the core's JSON mapping (spec §16): its path is already a place in the haus value. */
export const jsonError = (e: { readonly reason: string; readonly code: ErrorCode; readonly path: Path; readonly expected?: string; readonly found?: string }): HausSchemaError =>
  new HausSchemaError({
    message: e.path.length === 0 ? e.reason : `${e.reason}\n  at ${effectPath(e.path)}`,
    ...(e.path.length === 0 ? {} : { path: [...e.path] }),
    place: formatPath(e.path),
    ...withCode(e.code, e),
  })

// ── places ───────────────────────────────────────────────────

/**
 * Where an error at the Effect path `path` is in the haus value `input`, as
 * the core reports it (spec §17): a record payload's fields are the variant's
 * own (`Circle { r }` → `$.r`), `{ values: [x, y] }` and `Some(x)` are
 * arguments (`$[1]`, `$[0]`), a missing field is the record's place, and an
 * invalid std/time text is the tag's argument (`$.on[0]`).
 */
export const hausPath = (input: Value, path: ReadonlyArray<Key>, code: ErrorCode): Path => {
  const keys = code === "missing-field" ? path.slice(0, -1) : path
  const out: Array<Key> = []
  let v: Value | undefined = input
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i]!
    if (v === undefined) {
      out.push(key)
      continue
    }
    const here: Value = v
    v = undefined
    if (here.kind === "array" && typeof key === "number") (out.push(key), (v = here.items[key]))
    else if (here.kind === "record") (out.push(key), (v = here.fields.get(String(key))))
    else if (here.kind === "variant") {
      const [first] = here.args
      const next = keys[i + 1]
      const payload = here.args.length === 1 && first!.kind === "record" ? first! : undefined
      if (here.tag === "Some" && here.args.length === 1 && key === "value") (out.push(0), (v = first))
      else if (typeof key === "number") (out.push(key), (v = here.args[key]))
      else if (payload?.fields.has(key)) (out.push(key), (v = payload.fields.get(key)))
      else if (key === "values" && typeof next === "number") (out.push(next), (v = here.args[next]), i++)
      // A payload `{ value: { … } }` (a record with a field `_tag`) is the record itself.
      else if (payload !== undefined && key === "value") v = payload
      else out.push(key)
    } else out.push(key)
  }
  if (code === "invalid-time" && v?.kind === "variant") out.push(0)
  return out
}

// ── Effect's issues ──────────────────────────────────────────

/** Annotation on a filter or an issue: its error code (spec §17), e.g. `invalid-time` for the std/time checks. */
export const CODE = "hausCode"

/** The parts of an Effect schema issue read here. */
interface IssueNode {
  readonly _tag?: string
  readonly path?: ReadonlyArray<PropertyKey>
  readonly issue?: unknown
  readonly issues?: ReadonlyArray<unknown>
  readonly ast?: SchemaAST.AST
  readonly filter?: SchemaAST.Filter<unknown>
  readonly annotations?: { readonly [key: string]: unknown }
}

/** An issue, its first nested issue, and so on: the way to the first error. */
function* firstIssues(issue: unknown): Generator<IssueNode> {
  let node = issue as IssueNode | undefined
  for (let i = 0; node && i < 1000; i++) {
    yield node
    node = (node.issue ?? node.issues?.[0]) as IssueNode | undefined
  }
}

const keysOf = (node: IssueNode): ReadonlyArray<Key> => (node.path ?? []).filter((k): k is Key => typeof k === "string" || typeof k === "number")

/** The path of the first issue: the keys of nested Pointer issues. */
export const issuePath = (issue: unknown): ReadonlyArray<Key> => [...firstIssues(issue)].flatMap(keysOf)

/** Effect's range checks: a number outside them is `out-of-range`. */
const RANGE = /^effect\/schema\/is(Between|GreaterThan|GreaterThanOrEqualTo|LessThan|LessThanOrEqualTo)(BigInt|BigDecimal|Date)?$/

const isCode = (u: unknown): u is ErrorCode => typeof u === "string" && Object.hasOwn(ERROR_CODES, u)

/**
 * The code of a failed check: its own (`Haus.Date` & co., the integer types
 * of schema files), else by the check: `isInt` is `not-an-integer`, the range
 * checks `out-of-range`, any other `type-mismatch` (a value the type doesn't accept).
 */
const filterCode = (filter: SchemaAST.Filter<unknown> | undefined): ErrorCode => {
  const own = filter?.annotations?.[CODE]
  if (isCode(own)) return own
  const id = (filter?.annotations?.["representation"] as { readonly id?: unknown } | undefined)?.id
  if (id === "effect/schema/isInt") return "not-an-integer"
  return typeof id === "string" && RANGE.test(id) ? "out-of-range" : "type-mismatch"
}

/** The code of the first issue, and the path to it (missing keys included). */
const classify = (issue: unknown): { readonly code: ErrorCode; readonly path: ReadonlyArray<Key> } => {
  const path: Array<Key> = []
  for (const node of firstIssues(issue)) {
    path.push(...keysOf(node))
    switch (node._tag) {
      case "Filter":
        return { code: filterCode(node.filter), path }
      case "MissingKey":
        return { code: typeof path.at(-1) === "number" ? "type-mismatch" : "missing-field", path }
      case "UnexpectedKey":
        return { code: typeof path.at(-1) === "number" ? "type-mismatch" : "unknown-field", path }
      case "InvalidValue": {
        const own = node.annotations?.[CODE]
        return { code: isCode(own) ? own : "type-mismatch", path }
      }
      case "InvalidType":
      case "Forbidden":
      case "OneOf":
        return { code: "type-mismatch", path }
      default:
        if (node.issue === undefined && (node.issues?.length ?? 0) === 0) return { code: "type-mismatch", path }
    }
  }
  return { code: "type-mismatch", path }
}

/**
 * An issue inside a `Schema.Redacted` (a `Secret`): its place, and a message
 * naming the type. Effect's own message there never shows the value, but
 * doesn't name the type either (spec §15 asks for both).
 */
const secretIssue = (issue: unknown): Option.Option<{ readonly path: ReadonlyArray<Key>; readonly message: string }> => {
  const path: Array<Key> = []
  for (const node of firstIssues(issue)) {
    if (node.ast && isRedacted(node.ast)) return Option.some({ path, message: secretMessage(node.ast) })
    path.push(...keysOf(node))
  }
  return Option.none()
}

/**
 * An Effect schema error as a HausSchemaError, with the code the core gives
 * the same value (spec §17): decoding `input`, or encoding (`cannot-encode`).
 * Anything inside a Secret is `invalid-secret`, at the secret's place.
 */
export const issueError = (e: { readonly message: string; readonly issue: unknown }, input: Value | undefined, mode: "decode" | "encode"): HausSchemaError =>
  Option.match(secretIssue(e.issue), {
    onSome: ({ path, message }) => located(message, "invalid-secret", path, input),
    onNone: () => {
      const { code, path } = classify(e.issue)
      const message = e.message
      const at = path.length === 0 ? "" : `\n  at ${effectPath(path)}`
      const reason = at !== "" && message.endsWith(at) ? message.slice(0, -at.length) : message
      return located(reason, mode === "encode" ? "cannot-encode" : code, path, input)
    },
  })
