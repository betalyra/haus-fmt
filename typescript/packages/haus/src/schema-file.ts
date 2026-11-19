/**
 * Schema files (`.schema.haus`): parse, resolve and check them.
 *
 *   import std/time (Instant)            built in (spec §13)
 *   import @haus-fmt/money (Money)       a schema package, found by a ModuleResolver
 *   import ./common (Address)            a schema file next to this one
 *   type Comment = < Comment { author: String, at: Instant, replies: Array Comment } >
 *   type Root = Comment
 *
 * The result is a set of resolved types that bindings turn into their own
 * schemas (the Effect adapter builds Effect schemas from it). The checker
 * enforces what keeps checking data linear (spec §9.9, §9.10):
 *
 * - recursion must pass through a record field, array element or variant
 *   payload (`type A = B`, `type B = A` is rejected);
 * - generic types can't grow without bound: no type parameter passes,
 *   inside a bigger type, along a cycle of references back to itself
 *   (`type List a = < Nil | Cons a (List a) >`, not `T (Pair a a)`);
 * - records and variants are open (other fields are ignored, other tags kept
 *   as unknown) unless marked `closed`;
 * - `...Name` copies the cases of a named variant (`< ...UserEvent | Ping >`)
 *   or the fields of a named record (`{ ...Entity, name: String }`). Whether
 *   the result is open or closed is decided by its own `closed` alone.
 *
 * Attributes (`@deprecated("use email")`) before a type, a field or a tag are
 * metadata for tools (spec §14): they are kept on Definition, Field and Case
 * for tools (declarations, `checkData`), and decoding never reads them.
 * Attributes this version doesn't define are accepted, given no meaning, and
 * reported in `SchemaFile.warnings`.
 *
 * Errors are HausSchemaFileError, with the position in the schema file.
 */
import { HausSyntaxError, locate, START, type ErrorCode, type ErrorDetails } from "./errors.js"
import { DEFAULT_LIMITS, Parser } from "./parser.js"
import type { Value } from "./value.js"

/** A type used without its import, and the standard module or official extension that has it. */
export interface MissingImport {
  readonly module: string
  readonly name: string
}

/** What a schema-file error can say beyond its message. */
export interface SchemaErrorDetails extends ErrorDetails {
  /** A known type used without its import in the file itself (for an editor's quick fix). */
  readonly missingImport?: MissingImport
}

export class HausSchemaFileError extends HausSyntaxError {
  /** Set when the error is a known type used without its import in the file itself (for an editor's quick fix). */
  readonly missingImport?: MissingImport

  constructor(reason: string, offset: number, line: number, column: number, code: ErrorCode, details: SchemaErrorDetails = {}) {
    super(reason, offset, line, column, code, details)
    if (details.missingImport !== undefined) this.missingImport = details.missingImport
  }
}

// ── resolved types ───────────────────────────────────────────

export const BUILTINS = [
  "String", "Bytes", "Bool", "Decimal", "Int",
  "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64",
  "Float32", "Float64", "Any",
] as const
export type Builtin = (typeof BUILTINS)[number]

/** Types of the standard modules (spec §13), by module. Only std/time: everything else is an ordinary schema package. */
export const STD_MODULES = {
  "std/time": ["Date", "Time", "DateTime", "Instant", "ZonedDateTime", "Duration", "YearMonth", "TimeZone"],
} as const

/** Modules that used to be standard, and where they went. */
const MOVED_MODULES: Record<string, string> = { "std/money": "@haus-fmt/money" }
export type StdType = (typeof STD_MODULES)[keyof typeof STD_MODULES][number]

/**
 * The official extensions and their types. They are ordinary schema packages
 * (spec §13.3), installed with the language's package manager; the table only
 * lets an unknown type say where it comes from.
 */
export const OFFICIAL_EXTENSIONS: Readonly<Record<string, readonly string[]>> = {
  "@haus-fmt/money": ["Money", "Currency"],
  "@haus-fmt/geo": ["LatLng", "BBox"],
}

/** The standard module or official extension that has a type of this name. */
export const moduleOfType = (name: string): string | undefined =>
  Object.entries({ ...STD_MODULES, ...OFFICIAL_EXTENSIONS }).find(([, names]) => (names as readonly string[]).includes(name))?.[0]

/** How to get a known type into scope: the import, and for a package, installing it. */
export const importHint = ({ module, name }: MissingImport): string =>
  `import it with: import ${module} (${name})${module.startsWith("@") ? `, and install ${module} with your package manager` : ""}`

export type Type =
  | { readonly kind: "builtin"; readonly name: Builtin }
  | { readonly kind: "std"; readonly name: StdType }
  | { readonly kind: "array"; readonly item: Type }
  | { readonly kind: "map"; readonly value: Type }
  | { readonly kind: "maybe"; readonly item: Type }
  /** `Secret a`: the same data as `a`, hidden on the host side (spec §15). */
  | { readonly kind: "secret"; readonly item: Type }
  | RecordType
  | VariantType
  | { readonly kind: "ref"; readonly instance: Instance }
  /** A type parameter, only in the template of a generic type. */
  | { readonly kind: "param"; readonly name: string }

/**
 * An attribute written before a type, field or tag: `@deprecated("use email")`.
 * Metadata for tools; decoding never depends on it (spec §14, §15).
 */
export interface Attribute {
  readonly name: string
  readonly args: readonly Value[]
}

/** The attributes this version defines (spec §14). Others are accepted, without meaning, with a warning. */
export const ATTRIBUTES = ["deprecated"] as const

const isDefinedAttribute = (name: string): name is (typeof ATTRIBUTES)[number] => (ATTRIBUTES as readonly string[]).includes(name)

/**
 * `@deprecated` among `attributes`: its message ("" when it has none), or
 * undefined when there is no `@deprecated`.
 */
export const deprecation = (attributes: readonly Attribute[] | undefined): string | undefined => {
  const d = attributes?.find((a) => a.name === "deprecated")
  if (!d) return undefined
  const [message] = d.args
  return message?.kind === "string" ? message.value : ""
}

/** What tools say about `name` when `attributes` mark it `@deprecated`: "name is deprecated: why"; undefined when they don't. */
export const deprecationNote = (name: string, attributes: readonly Attribute[] | undefined): string | undefined => {
  const why = deprecation(attributes)
  return why === undefined ? undefined : `${name} is deprecated${why ? `: ${why}` : ""}`
}

/**
 * Something a tool should point out in a schema file, without failing (spec
 * §14, §16): an attribute this version doesn't define, a use of a deprecated
 * type, or a case that has no schema-based JSON form.
 */
export interface SchemaWarning {
  /**
   * `unknown-attribute`: `@since(…)` and the like; `deprecated`: a reference to a `@deprecated` type;
   * `no-json-form`: a record case with a field named `_tag` or `_args` (spec §16).
   */
  readonly kind: SchemaWarningKind
  /** Its code (spec §17): the same as `kind`. */
  readonly code: SchemaWarningKind
  readonly message: string
  /** UTF-16 offsets into the schema file, `end` exclusive. */
  readonly offset: number
  readonly end: number
  readonly line: number
  readonly column: number
}

export type SchemaWarningKind = Extract<ErrorCode, "unknown-attribute" | "deprecated" | "no-json-form">

export interface Field {
  readonly key: string
  readonly optional: boolean
  readonly type: Type
  /** Its attributes (a spread copies them with the field). Never read when decoding. */
  readonly attributes?: readonly Attribute[]
}

export interface RecordType {
  readonly kind: "record"
  readonly fields: readonly Field[]
  /** `closed { … }`: other fields are an error. Records are open otherwise (other fields are ignored). */
  readonly closed: boolean
}

/**
 * What a case takes. A case with one argument whose type is a record is a
 * record case (spec §15), however the record is written: `Box { w: Int32 }`,
 * `Box ({ w: Int32 })`, `Box BoxRec` with `type BoxRec = { w: Int32 }` (through
 * any aliases) or `Found (Page Int32)` with `type Page a = { … }` all give
 * `record`. A type parameter is never a record, even where its argument is
 * one: `Ok a` of `Result` and `Box a` of `type GenBox a = < Box a >` stay
 * `positional`.
 */
export type Payload =
  | { readonly kind: "none" }
  | {
      readonly kind: "record"
      readonly record: RecordType
      /** The argument as written when it names the record (`BoxRec`, `Page Int32`): a reference, whose chain of aliases ends in `record`. */
      readonly named?: Type
    }
  | { readonly kind: "positional"; readonly items: readonly Type[] }

export interface Case {
  readonly tag: string
  readonly payload: Payload
  /** Its attributes (a spread copies them with the case). Never read when decoding. */
  readonly attributes?: readonly Attribute[]
}

export interface VariantType {
  readonly kind: "variant"
  readonly cases: readonly Case[]
  /** Not `closed`: other tags are accepted as unknown values. */
  readonly open: boolean
}

/**
 * A named type applied to its arguments: `Comment`, `List Int`. Type
 * references point here, which is how recursive types are represented.
 */
export class Instance {
  body: Type = { kind: "variant", cases: [], open: false }
  /** `type Events = Stream Event`: the file is a stream of `body`. */
  stream = false
  /** @internal */
  state: "new" | "evaluating" | "done" = "new"

  constructor(
    readonly definition: Definition,
    readonly args: readonly Type[],
    readonly key: string,
  ) {}

  get name(): string {
    return this.definition.name
  }
}

export interface Definition {
  readonly name: string
  /**
   * The type's identity, the same in every language: `@haus-fmt/money@1#Money`
   * for a type of a schema package, `<id>#Name` for a file with an id, or
   * just the name.
   */
  readonly id: string
  /** The identity of the file that defines it; undefined for the file being parsed when it has no id. */
  readonly module: string | undefined
  readonly params: readonly string[]
  /** The `//` comment lines just above the definition. */
  readonly doc: string
  /** The definition's source text, with its comment and attributes. */
  readonly source: string
  /** Its attributes, such as `@deprecated("use Customer")`. */
  readonly attributes: readonly Attribute[]
  readonly offset: number
  /**
   * The type for non-generic definitions; for generic ones the template,
   * with `param` types for the parameters.
   */
  readonly template: Instance
}

export interface SchemaFile {
  /** The file's own definitions, in source order. */
  readonly definitions: readonly Definition[]
  /** Types imported from std modules. */
  readonly imports: ReadonlyMap<string, StdType>
  /** Types imported from other schema files and packages, by the name they have here. */
  readonly imported: ReadonlyMap<string, Definition>
  /** The file's identity (ParseSchemaOptions.id), if it has one. */
  readonly id: string | undefined
  /** The definition named `name`, if any. */
  definition(name: string): Definition | undefined
  /**
   * What to point out in this file (not in the files it imports), in source
   * order: attributes this version doesn't define, each place that uses a
   * deprecated type (outside deprecated types), and each case whose record
   * has a field named `_tag` or `_args` (no schema-based JSON form, spec §16).
   */
  readonly warnings: readonly SchemaWarning[]
}

// ── lexer ────────────────────────────────────────────────────

type Token =
  | { readonly t: "upper" | "lower" | "string" | "module" | "attribute"; readonly value: string; readonly pos: number }
  | { readonly t: "punct"; readonly value: string; readonly pos: number }
  | { readonly t: "eof"; readonly value: ""; readonly pos: number }

const PUNCT = ["...", "{", "}", "<", ">", "(", ")", "|", ":", "?", ",", "=", "/"]

/** The version an import may name: a major version, without leading zeros (spec §13.3). */
const MAJOR = /^(?:0|[1-9][0-9]*)$/

/** `@haus-fmt/money@1.1`, `@01`, `@x`: an import names only a major version (code `import-version`). */
const importVersionError = (fail: Fail, name: string, version: string, pos: number): never => {
  const digits = /^([0-9]+)(\.|$)/.exec(version)
  const major = digits?.[1]!.replace(/^0+(?=[0-9])/, "")
  if (digits?.[2] === ".") {
    return fail("import-version", `${name}@${version}: an import names only the major version (${name}@${major})`, pos, {
      hint: "An import names only the major version (`@1`); the minimum minor goes in your package manager's dependency range.",
    })
  }
  if (digits) {
    return fail("import-version", `${name}@${version}: a major version has no leading zeros (${name}@${major})`, pos, {
      hint: "Write the major version without leading zeros (`@1`).",
    })
  }
  return fail("import-version", `${name}@${version}: expected a major version after '@', like ${name}@1`, pos, {
    hint: "An import names only the major version (`@1`), or none.",
  })
}

class Lexer {
  /** After a byte order mark at the start, as in data files. */
  pos: number
  /** Comments, whitespace and `"…"` strings are those of data files (spec §14), read by the data parser. */
  private readonly data: Parser
  constructor(readonly text: string, readonly fail: Fail) {
    this.pos = text.startsWith("\ufeff") ? 1 : 0
    this.data = new Parser(text, START, DEFAULT_LIMITS)
  }

  /** Runs the data parser, its errors (with their codes) put where they are in the schema file. */
  private read<R>(f: () => R): R {
    try {
      return f()
    } catch (e) {
      if (e instanceof HausSyntaxError) this.fail(e.code, e.reason, e.offset)
      throw e
    }
  }

  /** Skip whitespace and comments. */
  skip(): void {
    this.pos = this.read(() => this.data.triviaEnd(this.pos))
  }

  next(): Token {
    this.skip()
    const s = this.text
    const pos = this.pos
    if (pos >= s.length) return { t: "eof", value: "", pos }
    const ident = /[A-Za-z_][A-Za-z0-9_]*/y
    ident.lastIndex = pos
    const m = ident.exec(s)
    if (m) {
      this.pos += m[0].length
      return { t: /^[A-Z]/.test(m[0]) ? "upper" : "lower", value: m[0], pos }
    }
    // A package or file after `import`: @org/name, @org/name@1, ./file, ../dir/file.
    // Package names are checked when the import is loaded (lowercase, spec §13.3), for a clear message.
    const module = /(@[A-Za-z0-9_.~-]+\/[A-Za-z0-9_.~-]+)(?:@([A-Za-z0-9_.+-]*))?|\.\.?\/[A-Za-z0-9_./-]*/y
    if (s[pos] === "@" || s.startsWith("./", pos) || s.startsWith("../", pos)) {
      module.lastIndex = pos
      const mm = module.exec(s)
      if (mm) {
        const [, name, version] = mm
        if (version !== undefined && !MAJOR.test(version)) importVersionError(this.fail, name!, version, pos)
        this.pos += mm[0].length
        return { t: "module", value: mm[0], pos }
      }
    }
    // An attribute: @deprecated (its arguments are parsed by the parser).
    if (s[pos] === "@") {
      const attribute = /@([a-z_][A-Za-z0-9_]*)/y
      attribute.lastIndex = pos
      const am = attribute.exec(s)
      if (!am) this.fail("schema-syntax", "expected an attribute name after '@', like @deprecated", pos)
      this.pos += am[0].length
      return { t: "attribute", value: am[1]!, pos }
    }
    if (s[pos] === '"') {
      const { value, end } = this.read(() => this.data.basicStringAt(pos))
      this.pos = end
      return { t: "string", value, pos }
    }
    for (const p of PUNCT) {
      if (s.startsWith(p, pos)) {
        this.pos += p.length
        return { t: "punct", value: p, pos }
      }
    }
    return this.fail("schema-syntax", `unexpected character '${quoteText(String.fromCodePoint(s.codePointAt(pos)!))}'`, pos)
  }
}

// ── syntax tree ──────────────────────────────────────────────

type Node =
  | { readonly t: "name"; readonly name: string; readonly pos: number }
  | { readonly t: "var"; readonly name: string; readonly pos: number }
  | { readonly t: "app"; readonly head: string; readonly args: readonly Node[]; readonly pos: number }
  | RecordNode
  | VariantNode

/**
 * `...Name`: the fields or cases of the named type, copied in. `at` is how
 * many own fields or cases come before it, to keep the written order.
 */
interface SpreadNode {
  readonly name: string
  readonly at: number
  readonly pos: number
}

/** `@name` or `@name(value, …)`, `end` exclusive. */
interface AttributeNode extends Attribute {
  readonly pos: number
  readonly end: number
}

/** A warning at a span of its file, before it is located (line and column). */
interface RawWarning {
  readonly kind: SchemaWarningKind
  readonly message: string
  readonly pos: number
  readonly end: number
}

interface FieldNode {
  readonly key: string
  readonly optional: boolean
  readonly type: Node
  readonly pos: number
  readonly attributes: readonly Attribute[]
}

interface RecordNode {
  readonly t: "record"
  readonly fields: readonly FieldNode[]
  readonly spreads: readonly SpreadNode[]
  readonly closed: boolean
  readonly pos: number
}

interface CaseNode {
  readonly tag: string
  readonly args: readonly Node[]
  readonly pos: number
  readonly attributes: readonly Attribute[]
}

interface VariantNode {
  readonly t: "variant"
  readonly cases: readonly CaseNode[]
  readonly spreads: readonly SpreadNode[]
  readonly closed: boolean
  readonly pos: number
}

interface TypeDecl {
  readonly name: string
  readonly params: readonly { readonly name: string; readonly pos: number }[]
  readonly body: Node
  readonly pos: number
  readonly end: number
  readonly docStart: number
  readonly doc: string
  readonly attributes: readonly Attribute[]
}

interface ImportDecl {
  readonly module: string
  readonly names: readonly { readonly name: string; readonly pos: number }[]
  readonly pos: number
  /** Just after the `)`. */
  readonly end: number
}

const MAX_NESTING = 128

class SchemaParser {
  private tok: Token
  private readonly lexer: Lexer
  private depth = 0
  private lastEnd = 0
  /** Every attribute, in source order. */
  readonly attributes: AttributeNode[] = []
  /** Attributes this version doesn't define: a warning each. */
  readonly warnings: RawWarning[] = []

  constructor(readonly text: string, readonly fail: Fail) {
    this.lexer = new Lexer(text, fail)
    this.tok = this.lexer.next()
  }

  private advance(): Token {
    const t = this.tok
    this.lastEnd = this.lexer.pos
    this.tok = this.lexer.next()
    return t
  }

  /** The current token (a method, so TypeScript doesn't keep narrowing it across advance()). */
  private cur(): Token {
    return this.tok
  }

  private is(value: string): boolean {
    return this.tok.t === "punct" && this.tok.value === value
  }

  private expect(value: string): Token {
    if (!this.is(value)) this.unexpected(`'${value}'`)
    return this.advance()
  }

  private unexpected(what: string, code: ErrorCode = "schema-syntax"): never {
    const found = this.tok.t === "eof" ? "end of file" : `'${quoteText(this.tok.value)}'`
    return this.fail(code, `expected ${what}, found ${found}`, this.tok.pos, { expected: what, found })
  }

  private keyword(): string | undefined {
    const t = this.tok
    return t.t === "lower" && (t.value === "type" || t.value === "import" || t.value === "closed") ? t.value : undefined
  }

  parseFile(): { imports: ImportDecl[]; types: TypeDecl[] } {
    const imports: ImportDecl[] = []
    const types: TypeDecl[] = []
    while (this.tok.t !== "eof") {
      const attributes = this.parseAttributes()
      const kw = this.keyword()
      if (kw === "type") types.push(this.parseType(attributes))
      else if (attributes.length > 0) this.unexpected("a type definition after the attribute (attributes go before a type, a field or a tag)")
      else if (kw === "import") imports.push(this.parseImport())
      else this.unexpected("'type' or 'import'")
    }
    return { imports, types }
  }

  /**
   * The attributes before a type, field or tag (spec §14): `@deprecated`,
   * `@deprecated("use email")`, or one this version doesn't define (kept as
   * written, without meaning, with a warning).
   */
  private parseAttributes(): AttributeNode[] {
    const out: AttributeNode[] = []
    while (this.tok.t === "attribute") {
      const attribute = this.parseAttribute()
      this.checkAttribute(attribute, out)
      out.push(attribute)
      this.attributes.push(attribute)
    }
    return out
  }

  /** `@name` or `@name(value, …)`, the current token being the `@name`. */
  private parseAttribute(): AttributeNode {
    const t = this.advance()
    const nameEnd = t.pos + 1 + t.value.length
    let args: readonly Value[] = []
    if (this.is("(")) {
      if (this.tok.pos !== nameEnd) this.fail("attribute-space", `no space is allowed between @${t.value} and '('`, nameEnd)
      args = this.parseAttributeArgs(this.tok.pos)
    }
    return { name: t.value, args, pos: t.pos, end: this.lastEnd }
  }

  /**
   * Spec §14: an attribute this version defines takes the arguments it
   * defines, once per type, field or tag (`before`: the attributes written
   * before it there). Any other attribute is accepted as it is, even twice,
   * with a warning.
   */
  private checkAttribute(a: AttributeNode, before: readonly AttributeNode[]): void {
    if (!isDefinedAttribute(a.name)) {
      const known = ATTRIBUTES.map((name) => `@${name}`).join(", ")
      this.warnings.push({ kind: "unknown-attribute", message: `unknown attribute @${a.name}: this version of haus gives it no meaning (it knows ${known})`, pos: a.pos, end: a.end })
      return
    }
    if (before.some((b) => b.name === a.name)) this.fail("attribute-twice", `@${a.name} appears twice here`, a.pos)
    const [first, ...more] = a.args
    if (more.length > 0 || (first !== undefined && first.kind !== "string")) {
      this.fail("attribute-arguments", '@deprecated takes no argument or one string: @deprecated or @deprecated("use email")', a.pos)
    }
  }

  /** `( value, … )` at `open`: haus values, parsed by the data parser (any value, comments between them). */
  private parseAttributeArgs(open: number): Value[] {
    const values: Value[] = []
    const lexer = this.lexer
    const data = new Parser(this.text, START, DEFAULT_LIMITS)
    lexer.pos = open + 1
    for (;;) {
      lexer.skip()
      const c = this.text[lexer.pos]
      if (c === ")") {
        if (values.length === 0) this.fail("attribute-arguments", "an attribute's ( … ) needs at least one value; write the attribute without parentheses", open)
        break
      }
      if (c === undefined) this.fail("unclosed-bracket", "unclosed '(' of an attribute", open)
      try {
        const { value, end } = data.valueAt(lexer.pos)
        values.push(value)
        lexer.pos = end
      } catch (e) {
        if (e instanceof HausSyntaxError) this.fail(e.code, e.reason, e.offset)
        throw e
      }
      lexer.skip()
      if (this.text[lexer.pos] === ",") lexer.pos++
      else if (this.text[lexer.pos] !== ")") this.fail("missing-comma", `expected ',' or ')' in the attribute's arguments`, lexer.pos)
    }
    lexer.pos++ // )
    this.lastEnd = lexer.pos
    this.tok = lexer.next()
    return values
  }

  private parseImport(): ImportDecl {
    const pos = this.advance().pos
    const parts: string[] = []
    if (this.cur().t === "module") parts.push(this.advance().value)
    else {
      do {
        if (this.tok.t !== "lower") this.unexpected("a module like std/time, @org/name or ./file")
        parts.push(this.advance().value)
      } while (this.is("/") && this.advance())
    }
    this.expect("(")
    const names: { name: string; pos: number }[] = []
    while (!this.is(")")) {
      if (this.cur().t !== "upper") this.unexpected("a type name")
      const t = this.advance()
      names.push({ name: t.value, pos: t.pos })
      if (!this.is(")")) this.expect(",")
    }
    if (names.length === 0) this.unexpected("a type name (an import names at least one type)", "unknown-import")
    this.advance()
    return { module: parts.join("/"), names, pos, end: this.lastEnd }
  }

  private parseType(attributes: readonly AttributeNode[]): TypeDecl {
    const pos = this.advance().pos
    if (this.tok.t !== "upper") this.unexpected("a type name (starting with a capital letter)")
    const name = this.advance().value
    const params: { name: string; pos: number }[] = []
    while (this.cur().t === "lower" && !this.keyword()) {
      if (this.cur().value.startsWith("_")) this.unexpected("a type parameter (starting with a lowercase letter)", "invalid-parameter")
      const t = this.advance()
      params.push({ name: t.value, pos: t.pos })
    }
    this.expect("=")
    const body = this.parseApp()
    const { start, doc } = docComment(this.text, attributes[0]?.pos ?? pos)
    return { name, params, body, pos, end: this.lastEnd, docStart: start, doc, attributes: attributes.map(attributeOf) }
  }

  private nested<T>(pos: number, f: () => T): T {
    if (++this.depth > MAX_NESTING) this.fail("type-too-deep", `types nested deeper than ${MAX_NESTING} levels`, pos)
    try {
      return f()
    } finally {
      this.depth--
    }
  }

  /** `Name atom*`, or a single atom. */
  private parseApp(): Node {
    if (this.tok.t === "upper") {
      const head = this.advance()
      const args: Node[] = []
      while (this.startsAtom()) args.push(this.parseAtom())
      return args.length === 0 ? { t: "name", name: head.value, pos: head.pos } : { t: "app", head: head.value, args, pos: head.pos }
    }
    return this.parseAtom()
  }

  private startsAtom(): boolean {
    const t = this.tok
    if (t.t === "upper") return true
    if (t.t === "lower") return this.keyword() === undefined || t.value === "closed"
    return t.t === "punct" && (t.value === "(" || t.value === "{" || t.value === "<")
  }

  private parseAtom(): Node {
    const t = this.tok
    if (t.t === "upper") {
      this.advance()
      return { t: "name", name: t.value, pos: t.pos }
    }
    if (t.t === "lower" && t.value === "closed") {
      this.advance()
      if (this.is("{")) return this.nested(t.pos, () => this.parseRecord(true))
      if (this.is("<")) return this.nested(t.pos, () => this.parseVariant(true))
      return this.unexpected("a record { … } or a variant < … > after 'closed'")
    }
    if (t.t === "lower" && !this.keyword()) {
      if (t.value === "_") this.fail("underscore-type", "types are open by default, so there is no _: write < > for any tag, or use a type parameter", t.pos)
      this.advance()
      return { t: "var", name: t.value, pos: t.pos }
    }
    if (this.is("(")) {
      this.advance()
      const inner = this.nested(t.pos, () => this.parseApp())
      this.expect(")")
      return inner
    }
    if (this.is("{")) return this.nested(t.pos, () => this.parseRecord(false))
    if (this.is("<")) return this.nested(t.pos, () => this.parseVariant(false))
    return this.unexpected("a type")
  }

  /** `...Name`, after the `...`. */
  private parseSpread(at: number): SpreadNode {
    const t = this.tok
    if (t.t === "lower" && !this.keyword()) {
      return this.fail("row-parameter", `row parameters (...${t.value}) aren't supported; spread a named type instead: ...UserEvent`, t.pos)
    }
    if (t.t !== "upper") this.unexpected("a type name after '...': ...UserEvent")
    this.advance()
    return { name: t.value, at, pos: t.pos }
  }

  private parseRecord(closed: boolean): RecordNode {
    const pos = this.advance().pos
    if (this.is("|")) this.fail("schema-syntax", "{| … |} is gone: write closed { … } for a closed record", this.tok.pos)
    const fields: FieldNode[] = []
    const spreads: SpreadNode[] = []
    while (!this.is("}")) {
      const attributes = this.parseAttributes()
      if (this.is("...")) {
        if (attributes.length > 0) this.fail("attribute-on-spread", "attributes can't be put on a spread: the fields it copies keep their own", attributes[0]!.pos)
        this.advance()
        spreads.push(this.parseSpread(fields.length))
      } else {
        const k = this.tok
        if (k.t !== "lower" && k.t !== "string") this.unexpected(attributes.length > 0 ? "a field name after the attribute" : "a field name, ...Name or '}'")
        this.advance()
        const optional = this.is("?")
        if (optional) this.advance()
        this.expect(":")
        const type = this.parseApp()
        fields.push({ key: k.value, optional, type, pos: k.pos, attributes: attributes.map(attributeOf) })
      }
      if (this.is(",")) this.advance()
      else if (!this.is("}")) this.unexpected("',' or '}'")
    }
    this.expect("}")
    return { t: "record", fields, spreads, closed, pos }
  }

  private parseVariant(closed: boolean): VariantNode {
    const pos = this.advance().pos
    const cases: CaseNode[] = []
    const spreads: SpreadNode[] = []
    if (this.is("|")) this.advance()
    while (!this.is(">")) {
      const attributes = this.parseAttributes()
      if (this.cur().t === "upper") {
        const tag = this.advance()
        const args: Node[] = []
        while (this.startsAtom()) args.push(this.parseAtom())
        cases.push({ tag: tag.value, args, pos: tag.pos, attributes: attributes.map(attributeOf) })
      } else if (this.is("...")) {
        if (attributes.length > 0) this.fail("attribute-on-spread", "attributes can't be put on a spread: the tags it copies keep their own", attributes[0]!.pos)
        this.advance()
        spreads.push(this.parseSpread(cases.length))
      } else this.unexpected(attributes.length > 0 ? "a tag after the attribute" : "a tag, ...Name or '>'")
      if (this.is(">")) break
      this.expect("|")
    }
    this.advance()
    if (closed && cases.length === 0 && spreads.length === 0) this.fail("closed-empty-variant", "a closed variant needs at least one tag", pos)
    return { t: "variant", cases, spreads, closed, pos }
  }
}

/** An attribute without its position. */
const attributeOf = ({ name, args }: AttributeNode): Attribute => ({ name, args })

/** The type nodes directly inside `n`. */
const childNodes = (n: Node): readonly Node[] =>
  n.t === "app" ? n.args
  : n.t === "record" ? n.fields.map((f) => f.type)
  : n.t === "variant" ? n.cases.flatMap((c) => c.args)
  : []

/** `n` and every type node inside it, depth first (nesting is limited to MAX_NESTING). */
function* nodesOf(n: Node): Generator<Node> {
  yield n
  for (const child of childNodes(n)) yield* nodesOf(child)
}

/** The type names `n` refers to, spreads included, with their positions. */
const namesIn = (n: Node): readonly { readonly name: string; readonly pos: number }[] =>
  [...nodesOf(n)].flatMap((x): readonly { readonly name: string; readonly pos: number }[] =>
    x.t === "name" ? [{ name: x.name, pos: x.pos }]
    : x.t === "app" ? [{ name: x.head, pos: x.pos }]
    : x.t === "record" || x.t === "variant" ? x.spreads
    : [])

/**
 * The schema file without its attributes: each one replaced by spaces (line
 * breaks kept), so positions stay the same. Decoding with the result is the
 * same as with the file (spec §15, "Attributes don't matter"). Throws
 * HausSchemaFileError when the file can't be parsed.
 */
export function withoutAttributes(text: string): string {
  const parser = new SchemaParser(text, failIn(text))
  parser.parseFile()
  let out = ""
  let from = 0
  for (const a of parser.attributes) {
    out += text.slice(from, a.pos) + text.slice(a.pos, a.end).replace(/[^\n]/g, " ")
    from = a.end
  }
  return out + text.slice(from)
}

/** A schema file as written, without resolving anything: what an editor needs to fix its imports. */
export interface SchemaOutline {
  readonly imports: readonly {
    readonly module: string
    readonly names: readonly { readonly name: string; readonly pos: number }[]
    readonly pos: number
    readonly end: number
  }[]
  /** Its own types; `start` is where the doc comment or attributes before one start. */
  readonly types: readonly { readonly name: string; readonly start: number }[]
  /** Every type name the definitions use, in order. */
  readonly uses: readonly { readonly name: string; readonly pos: number }[]
}

/** Parse a schema file without resolving it. Throws HausSchemaFileError when the file can't be parsed. */
export function schemaOutline(text: string): SchemaOutline {
  const { imports, types } = new SchemaParser(text, failIn(text)).parseFile()
  return {
    imports,
    types: types.map((t) => ({ name: t.name, start: t.docStart })),
    uses: types.flatMap((t) => namesIn(t.body)),
  }
}

/** The `//` lines directly above `pos` (no blank line in between). */
function docComment(text: string, pos: number): { start: number; doc: string } {
  const lines: string[] = []
  let start = text.lastIndexOf("\n", pos - 1) + 1
  while (start > 0) {
    const prevStart = text.lastIndexOf("\n", start - 2) + 1
    const line = text.slice(prevStart, start - 1).trim()
    if (!line.startsWith("//")) break
    lines.unshift(line.replace(/^\/\/ ?/, ""))
    start = prevStart
  }
  return { start, doc: lines.join("\n") }
}

// ── imports ──────────────────────────────────────────────────

/** A schema file found for an import. */
export interface ResolvedModule {
  /** Unique for each file (e.g. its absolute path); passed back as `from` for the file's own imports. */
  readonly key: string
  /**
   * The file's identity, the same in every language: `@haus-fmt/money@1` for a
   * package's schema (from its manifest), `<package>/<path>` for other files.
   */
  readonly id: string
  readonly text: string
  /** The package version (semver), checked against an `@major` in the import. */
  readonly version?: string
  /**
   * For a package's schema: the package's name (its manifest's). One schema
   * reaches at most one package per name (spec §13.3); without it, the file
   * is not a package and two files may share nothing but their text.
   */
  readonly package?: string
  /** For a package's schema: its manifest's text. Copies whose manifest and schema are the same, byte for byte, are one package. */
  readonly manifest?: string
  /** Where the file is, for messages (such as its path); default `key`. */
  readonly path?: string
}

/**
 * Finds the schema files that imports name. Resolution happens when the
 * schema is built, never while data is parsed (spec §9.2). Throw an Error
 * with a readable message when a module can't be found (code
 * `import-not-found`), or a ModuleError for another code.
 */
export interface ModuleResolver {
  /** `module` as written (`@haus-fmt/money`, `@haus-fmt/money@1`, `./common`), imported by the file `from` (undefined: the root file without a key). */
  resolve(module: string, from: string | undefined): ResolvedModule
}

/**
 * An error a ModuleResolver throws for a code other than `import-not-found`:
 * `package-path` for a file outside its package (spec §13.3). The message
 * never quotes a file the resolver refused to read.
 */
export class ModuleError extends Error {
  constructor(readonly code: ErrorCode, message: string) {
    super(message)
    this.name = "ModuleError"
  }
}

export interface ParseSchemaOptions {
  /** Finds imported packages and files. Without one, only std modules can be imported. */
  readonly resolver?: ModuleResolver
  /** The root file's key for the resolver (e.g. its path), so relative imports resolve from it. */
  readonly key?: string
  /** The root file's identity, for the ids of its types (see ResolvedModule.id). */
  readonly id?: string
}

// ── resolution ───────────────────────────────────────────────

const PRELUDE_GENERIC: Record<string, number> = { Array: 1, Map: 1, Maybe: 1, Result: 2, Secret: 1, Stream: 1 }
const MAX_INSTANCES = 10_000
const MAX_FILES = 256

/** What each type parameter stands for while a generic type is evaluated. */
type Env = ReadonlyMap<string, Type>

type Fail = (code: ErrorCode, reason: string, pos: number, details?: SchemaErrorDetails) => never

/** Fails with a HausSchemaFileError at an offset of `text`. */
const failIn = (text: string): Fail => (code, reason, pos, details) => {
  const at = locate(text, pos, START)
  throw new HausSchemaFileError(reason, at.offset, at.line, at.column, code, details)
}

/** One schema file: the root, or one it imports (directly or not). */
interface Unit {
  readonly root: boolean
  readonly id: string | undefined
  readonly text: string
  readonly fail: Fail
  /** Its own definitions, by name: what other files can import. */
  readonly own: Map<string, Def>
  /** Every named type in scope: its own definitions and imported ones. */
  readonly scope: Map<string, Def>
  readonly std: Map<string, StdType>
  readonly warnings: readonly RawWarning[]
}

interface Def {
  readonly decl: TypeDecl
  readonly params: readonly string[]
  readonly unit: Unit
  definition?: Definition
}

/** npm's rules for scoped names, in lowercase (spec §13.3): `@org/name`, each part starting with a letter or digit. */
const PACKAGE_NAME = /^@([a-z0-9][a-z0-9._-]*)\/([a-z0-9][a-z0-9._-]*)$/

/** A package name (spec §13.3): `@org/name` in lowercase, by npm's rules, and neither part `node_modules`. The length is checked separately. */
export const isPackageName = (name: string): boolean => {
  const m = PACKAGE_NAME.exec(name)
  return m !== null && m[1] !== "node_modules" && m[2] !== "node_modules"
}

/** Bidirectional controls and marks, shown escaped in messages. */
const BIDI = /^[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]$/

/**
 * Text from a file, for a message (spec §9.2): control and bidirectional
 * characters escaped as `\u{…}` and at most `max` characters (default 40),
 * cut with `…`.
 */
export function quoteText(text: string, max = 40): string {
  const chars = [...text]
  const shown = chars.slice(0, max).map((c) => {
    const cp = c.codePointAt(0)!
    const escape = cp < 0x20 || (cp >= 0x7f && cp < 0xa0) || cp === 0x2028 || cp === 0x2029 || (cp >= 0xd800 && cp <= 0xdfff) || BIDI.test(c)
    return escape ? `\\u{${cp.toString(16)}}` : c
  })
  return chars.length > max ? `${shown.join("")}…` : shown.join("")
}

const majorOf = (version: string) => /^v?(\d+)/.exec(version)?.[1]

/**
 * Spec §14: each place in the file's own definitions that names a deprecated
 * type, its own or an imported one. Not inside deprecated definitions (they
 * go together), and once per place: a spread of the using type doesn't repeat it.
 */
const deprecatedUses = (unit: Unit): RawWarning[] =>
  [...unit.own.values()]
    .filter((def) => deprecation(def.decl.attributes) === undefined)
    .flatMap((def) => namesIn(def.decl.body))
    .flatMap(({ name, pos }): RawWarning[] => {
      const message = deprecationNote(name, unit.scope.get(name)?.decl.attributes)
      return message === undefined ? [] : [{ kind: "deprecated", message, pos, end: pos + name.length }]
    })

/** A reference to a definition in another one's body: by name, applied (with its arguments as written) or spread. */
interface DefRef {
  readonly to: Def
  readonly args: readonly Node[]
  readonly pos: number
}

/** The definitions `def` refers to, where it does. */
const refsOf = (def: Def): DefRef[] => {
  const at = (name: string, args: readonly Node[], pos: number): DefRef[] => {
    const to = def.unit.scope.get(name)
    return to === undefined ? [] : [{ to, args, pos }]
  }
  return [...nodesOf(def.decl.body)].flatMap((n) =>
    n.t === "name" ? at(n.name, [], n.pos)
    : n.t === "app" ? at(n.head, n.args, n.pos)
    : n.t === "record" || n.t === "variant" ? n.spreads.flatMap((sp) => at(sp.name, [], sp.pos))
    : [])
}

/**
 * The strongly connected components of a graph (Tarjan's algorithm, with a
 * stack of its own rather than recursion): the number of each node's component.
 */
function components<N>(nodes: readonly N[], next: (n: N) => readonly N[]): Map<N, number> {
  const index = new Map<N, number>()
  const low = new Map<N, number>()
  const component = new Map<N, number>()
  const stack: N[] = []
  let count = 0
  const visit = (n: N, work: [N, number][]) => {
    const i = index.size
    index.set(n, i)
    low.set(n, i)
    stack.push(n)
    work.push([n, 0])
  }
  for (const start of nodes) {
    if (index.has(start)) continue
    const work: [N, number][] = []
    visit(start, work)
    while (work.length > 0) {
      const frame = work[work.length - 1]!
      const [n, i] = frame
      const out = next(n)
      if (i < out.length) {
        frame[1] = i + 1
        const m = out[i]!
        if (!index.has(m)) visit(m, work)
        else if (!component.has(m)) low.set(n, Math.min(low.get(n)!, index.get(m)!))
        continue
      }
      work.pop()
      const parent = work[work.length - 1]
      if (parent !== undefined) low.set(parent[0], Math.min(low.get(parent[0])!, low.get(n)!))
      if (low.get(n) === index.get(n)) {
        let m: N
        do {
          m = stack.pop()!
          component.set(m, count)
        } while (m !== n)
        count++
      }
    }
  }
  return component
}

/** A type parameter of a definition: a node of the parameter graph (§9.10). */
interface ParamNode {
  readonly def: Def
  readonly index: number
}

/** Parameter `from` occurs in the argument a reference passes to parameter `to`; expanding when the argument isn't `from` itself. */
interface ParamEdge {
  readonly from: ParamNode
  readonly to: ParamNode
  readonly expanding: boolean
  readonly ref: DefRef
}

/**
 * §9.10, the expansive-cycle rule: a graph with one node per type parameter of
 * every definition, and for each reference `B t₁ … tₙ` in the body of `A`, an
 * edge from each parameter of `A` that occurs in `tᵢ` to the i-th parameter of
 * `B`, expanding when `tᵢ` isn't that parameter itself. An expanding edge on a
 * cycle (both ends in one strongly connected component) means instances could
 * grow without bound; without one there are finitely many. Checked on the
 * definitions as written, before anything is instantiated; the first such edge
 * (definitions, references, arguments and occurrences in order) is reported.
 */
function checkExpansiveCycles(defs: readonly Def[]): void {
  const nodes = new Map(defs.map((d) => [d, d.params.map((_, index): ParamNode => ({ def: d, index }))]))
  const edges: ParamEdge[] = defs.flatMap((def) =>
    refsOf(def).flatMap((ref) =>
      ref.args.slice(0, ref.to.params.length).flatMap((arg, i) =>
        [...nodesOf(arg)].flatMap((n): ParamEdge[] => {
          const from = n.t === "var" ? nodes.get(def)![def.params.indexOf(n.name)] : undefined
          return from === undefined ? [] : [{ from, to: nodes.get(ref.to)![i]!, expanding: arg.t !== "var", ref }]
        }))))
  const out = new Map<ParamNode, ParamNode[]>()
  for (const e of edges) {
    const next = out.get(e.from)
    if (next === undefined) out.set(e.from, [e.to])
    else next.push(e.to)
  }
  const component = components([...nodes.values()].flat(), (n) => out.get(n) ?? [])
  const growing = edges.find((e) => e.expanding && component.get(e.from) === component.get(e.to))
  if (growing === undefined) return
  const { from, to, ref } = growing
  const name = from.def.decl.name
  const param = from.def.params[from.index]!
  if (from === to) {
    from.def.unit.fail("growing-recursion", `${name} passes its parameter ${param} to itself inside a bigger type: instances could grow without bound`, ref.pos)
  }
  const target = to.def === from.def ? "itself" : to.def.decl.name
  const cycle = [from, ...shortestPath(to, from, (n) => (out.get(n) ?? []).filter((m) => component.get(m) === component.get(from)))]
  from.def.unit.fail(
    "growing-recursion",
    `${name} passes its parameter ${param} to ${target} inside a bigger type, and it comes back (${cycle.map((n) => n.def.decl.name).join(" → ")}): instances could grow without bound`,
    ref.pos,
  )
}

/** The nodes of a shortest path from `start` to `goal` (breadth first), both included; `goal` must be reachable. */
function shortestPath<N>(start: N, goal: N, next: (n: N) => readonly N[]): N[] {
  const parent = new Map<N, N | undefined>([[start, undefined]])
  const queue = [start]
  for (let i = 0; i < queue.length && !parent.has(goal); i++) {
    for (const m of next(queue[i]!)) {
      if (parent.has(m)) continue
      parent.set(m, queue[i])
      queue.push(m)
    }
  }
  const path: N[] = []
  for (let n: N | undefined = goal; n !== undefined; n = parent.get(n)) path.push(n)
  return path.reverse()
}

/** Parse and check a schema file and the files it imports. Throws HausSchemaFileError. */
export function parseSchemaFile(text: string, options: ParseSchemaOptions = {}): SchemaFile {
  const rootFail = failIn(text)
  const units = new Map<string, Unit>()
  const loading: string[] = []
  const allDefs: Def[] = []
  /** The file that has each id: two files with one id would give their types the same ids. */
  const ids = new Map<string, string | undefined>()
  /** The package reached for each name: one per name (spec §13.3). */
  const packages = new Map<string, ResolvedModule>()
  /** Identical copies of a loaded package whose imports were resolved too (spec §13.3), by key. */
  const copies = new Set<string>()
  /** Schema files read, the root included: units and copies. */
  const files = () => units.size + copies.size

  // ── loading: parse each file once, build its scope ──
  const load = (text: string, key: string | undefined, id: string | undefined, fail: Fail, root: boolean): Unit => {
    if (files() >= MAX_FILES) fail("too-many-files", `more than ${MAX_FILES} schema files are imported`, 0)
    const parser = new SchemaParser(text, fail)
    const { imports, types } = parser.parseFile()
    const unit: Unit = { root, id, text, fail, own: new Map(), scope: new Map(), std: new Map(), warnings: parser.warnings }
    if (key !== undefined) units.set(key, unit)
    if (id !== undefined) ids.set(id, key)
    loading.push(key ?? "")
    try {
      for (const imp of imports) {
        if (imp.module.startsWith("std/")) {
          const names = (STD_MODULES as Record<string, readonly StdType[]>)[imp.module]
          if (!names) {
            const moved = MOVED_MODULES[imp.module]
            fail("unknown-module", moved
              ? `${imp.module} is no longer a standard module; it is the package ${moved}: import ${moved} (${imp.names.map((n) => n.name).join(", ")})`
              : `unknown standard module ${imp.module} (there is ${Object.keys(STD_MODULES).join(", ")})`, imp.pos)
          }
          for (const n of imp.names) {
            if (!names!.includes(n.name as StdType)) fail("unknown-import", `${imp.module} has no type ${n.name} (it has ${names!.join(", ")})`, n.pos)
            if (unit.std.has(n.name) || unit.scope.has(n.name)) fail("duplicate-import", `${n.name} is imported twice`, n.pos)
            unit.std.set(n.name, n.name as StdType)
          }
          continue
        }
        if (!/^(@[^/]+\/|\.\.?\/)/.test(imp.module)) fail("unknown-module", `unknown module ${imp.module}: import std/…, a package @org/name or a file ./name`, imp.pos)
        const name = imp.module.replace(/@[0-9]+$/, "")
        if (name.startsWith("@") && !isPackageName(name)) {
          fail("unknown-module", `${quoteText(name)} is not a package name: package names are lowercase, @org/name with a-z, 0-9, - . _, each part starting with a letter or digit and not node_modules`, imp.pos)
        }
        const dep = loadImport(imp, key, fail)
        for (const n of imp.names) {
          const def = dep.own.get(n.name)
          if (!def) fail("unknown-import", `${imp.module} has no type ${n.name}${dep.own.size ? ` (it has ${[...dep.own.keys()].join(", ")})` : ""}`, n.pos)
          if (unit.std.has(n.name) || unit.scope.has(n.name)) fail("duplicate-import", `${n.name} is imported twice`, n.pos)
          unit.scope.set(n.name, def!)
        }
      }
      for (const decl of types) {
        if (unit.own.has(decl.name)) fail("duplicate-type", `type ${decl.name} is defined twice`, decl.pos)
        if (unit.scope.has(decl.name) || unit.std.has(decl.name)) fail("duplicate-type", `type ${decl.name} is already imported`, decl.pos)
        if ((BUILTINS as readonly string[]).includes(decl.name) || decl.name in PRELUDE_GENERIC) {
          fail("redefine-prelude", `${decl.name} is a prelude type and can't be redefined`, decl.pos)
        }
        const seen = new Set<string>()
        for (const p of decl.params) {
          if (p.name === "_") fail("invalid-parameter", "_ can't be a parameter name", p.pos)
          if (seen.has(p.name)) fail("invalid-parameter", `parameter ${p.name} appears twice`, p.pos)
          seen.add(p.name)
        }
        const def: Def = { decl, params: decl.params.map((p) => p.name), unit }
        unit.own.set(decl.name, def)
        unit.scope.set(decl.name, def)
        allDefs.push(def)
      }
    } finally {
      loading.pop()
    }
    return unit
  }

  const loadImport = (imp: ImportDecl, from: string | undefined, fail: Fail): Unit => {
    const resolver = options.resolver
    if (!resolver) return fail("import-unavailable", `can't import ${imp.module}: no module resolver (only std modules can be imported here)`, imp.pos)
    let r: ResolvedModule
    try {
      r = resolver.resolve(imp.module.replace(/@[0-9]+$/, ""), from)
    } catch (e) {
      return fail(e instanceof ModuleError ? e.code : "import-not-found", `can't import ${imp.module}: ${e instanceof Error ? e.message : String(e)}`, imp.pos)
    }
    const wanted = /^@.+@([0-9]+)$/.exec(imp.module)?.[1]
    if (wanted !== undefined && r.version !== undefined && majorOf(r.version) !== wanted) {
      fail("import-version", `${imp.module} wants major version ${wanted}, but version ${quoteText(r.version)} was found`, imp.pos)
    }
    // Errors inside an imported file are reported at the import, with their place in that file.
    const nested: Fail = (code, reason, pos, details) => {
      const at = locate(r.text, pos, START)
      return fail(code, `${imp.module} (${at.line}:${at.column}): ${reason}`, imp.pos, details?.hint === undefined ? {} : { hint: details.hint })
    }
    // One package per name; byte-identical copies are one package (spec §13.3).
    let key = r.key
    const first = r.package === undefined ? undefined : packages.get(r.package)
    const copy = first !== undefined && first.key !== r.key
    if (copy) {
      if (first.manifest === r.manifest && first.text === r.text) key = first.key
      else {
        const where = (m: ResolvedModule) => `${quoteText(m.version ?? "?")} in ${quoteText(m.path ?? m.key, Infinity)}`
        fail("duplicate-package", first.version === r.version
          ? `two copies of ${r.package} ${quoteText(r.version ?? "?")} whose files differ: ${quoteText(first.path ?? first.key, Infinity)} and ${quoteText(r.path ?? r.key, Infinity)}; one schema reaches one copy of each package`
          : `two versions of ${r.package}: ${where(first)} and ${where(r)}; one schema reaches one version of each package`, imp.pos)
      }
    }
    if (loading.includes(key)) fail("import-cycle", `import cycle: ${imp.module} imports this file again`, imp.pos)
    if (copy && !copies.has(r.key)) {
      // Copies are one package only if their imports reach the same packages too: resolve this
      // copy's imports from where it is, as if it were loaded (whichever copy came first).
      copies.add(r.key)
      if (files() > MAX_FILES) fail("too-many-files", `more than ${MAX_FILES} schema files are imported`, imp.pos)
      const { imports } = new SchemaParser(r.text, nested).parseFile()
      loading.push(key)
      try {
        for (const i of imports) if (!i.module.startsWith("std/")) loadImport(i, r.key, nested)
      } finally {
        loading.pop()
      }
    }
    const cached = units.get(key)
    if (cached) return cached
    if (r.package !== undefined) packages.set(r.package, r)
    if (ids.has(r.id) && ids.get(r.id) !== r.key) {
      fail("duplicate-package", r.package === undefined && r.version === undefined
        ? `${imp.module} has the id ${r.id}, as another file does (${r.path ?? r.key}): the module resolver must give different files different ids`
        : `${imp.module} is ${r.id}, but another file already is (${r.path ?? r.key})`, imp.pos)
    }
    return load(r.text, r.key, r.id, nested, false)
  }

  const root = load(text, options.key, options.id, rootFail, true)
  for (const def of allDefs) {
    const { fail } = def.unit
    const params = new Set(def.params)
    // Every lowercase name in a type must be one of the definition's parameters.
    for (const n of nodesOf(def.decl.body)) if (n.t === "var" && !params.has(n.name)) fail("unknown-parameter", `unknown type parameter ${n.name}`, n.pos)
  }
  checkExpansiveCycles(allDefs)

  // ── evaluation ──
  const instances = new Map<string, Instance>()
  const defOf = new Map<Instance, Def>()
  /** The file whose nodes are being evaluated: names resolve in its scope, errors point into it. */
  let current: Unit = root
  const fail: Fail = (code, reason, pos, details) => current.fail(code, reason, pos, details)
  const within = <R>(unit: Unit, f: () => R): R => {
    const saved = current
    current = unit
    try {
      return f()
    } finally {
      current = saved
    }
  }

  // Keys tell instances apart. They never hold the whole of their arguments, which can grow
  // exponentially with legitimate nesting (`P a a` inside `P a a` …): an instance is keyed by
  // its number, a record or variant by the number of its shape, so a key is as long as one type
  // expression. Each record or variant object is keyed once.
  const instanceIds = new Map<Instance, number>()
  const shapes = new Map<string, string>()
  const shapeOf = new WeakMap<Type, string>()
  const keyOf = (t: Type): string => {
    switch (t.kind) {
      case "builtin":
      case "std":
        return t.name
      case "param":
        return `'${t.name}`
      case "array":
        return `Array(${keyOf(t.item)})`
      case "map":
        return `Map(${keyOf(t.value)})`
      case "maybe":
        return `Maybe(${keyOf(t.item)})`
      case "secret":
        return `Secret(${keyOf(t.item)})`
      case "ref":
        return `#${instanceIds.get(t.instance)!}`
      case "record":
      case "variant": {
        const known = shapeOf.get(t)
        if (known !== undefined) return known
        const shape = t.kind === "record" ? recordShape(t) : `<${t.cases.map((c) => c.tag + payloadKey(c.payload)).join("|")}${t.open ? "|_" : ""}>`
        let key = shapes.get(shape)
        if (key === undefined) shapes.set(shape, (key = `~${shapes.size}`))
        shapeOf.set(t, key)
        return key
      }
    }
  }
  const recordShape = (r: RecordType): string =>
    `{${r.closed ? "|" : ""}${r.fields.map((f) => `${JSON.stringify(f.key)}${f.optional ? "?" : ""}:${keyOf(f.type)}`).join(",")}}`
  const payloadKey = (p: Payload): string =>
    p.kind === "none" ? "" : p.kind === "record" ? `{${keyOf(p.record)}}` : `(${p.items.map(keyOf).join(",")})`

  /** Types of other files are keyed by their id, so equal names in two files stay apart. */
  const nameKey = (def: Def) => (def.unit.root ? def.decl.name : definitionOf(def).id)

  const instance = (def: Def, args: readonly Type[], pos: number): Instance => {
    const key = args.length === 0 ? nameKey(def) : `${nameKey(def)}(${args.map(keyOf).join(",")})`
    let inst = instances.get(key)
    if (inst) return inst
    if (instances.size >= MAX_INSTANCES) fail("growing-recursion", `more than ${MAX_INSTANCES} type instances: a generic type grows without bound`, pos)
    inst = new Instance(definitionOf(def), args, key)
    instanceIds.set(inst, instances.size)
    instances.set(key, inst)
    defOf.set(inst, def)
    queue.push([inst, def])
    return inst
  }
  const queue: [Instance, Def][] = []

  const evaluateInstance = (inst: Instance, def: Def): void =>
    within(def.unit, () => {
      if (inst.state === "done") return
      if (inst.state === "evaluating") fail("spread-cycle", `type ${def.decl.name} spreads itself (directly or through another type)`, def.decl.pos)
      inst.state = "evaluating"
      const env: Env = new Map(def.params.map((p, i) => [p, inst.args[i]!]))
      const body = def.decl.body
      if ((body.t === "app" && body.head === "Stream") || (body.t === "name" && body.name === "Stream")) {
        if (body.t !== "app" || body.args.length !== 1) return fail("wrong-arity", "Stream needs 1 argument", body.pos)
        inst.stream = true
        inst.body = evaluate(body.args[0]!, env)
      } else inst.body = evaluate(body, env)
      inst.state = "done"
    })

  /** The body of a type, evaluating it now if necessary. */
  const bodyOf = (inst: Instance): Type => {
    evaluateInstance(inst, defOf.get(inst)!)
    return inst.body
  }

  /** The type a reference stands for; with `throughSecret`, also what a `Secret` holds (it guards nothing: §9.9). */
  const resolveRef = (t: Type, pos: number, throughSecret = false): Type => {
    const seen = new Set<Instance>()
    while (t.kind === "ref" || (throughSecret && t.kind === "secret")) {
      if (t.kind === "secret") {
        t = t.item
        continue
      }
      if (seen.has(t.instance)) fail("unguarded-recursion", `type ${t.instance.name} refers to itself without a record, array or variant in between`, pos)
      seen.add(t.instance)
      t = bodyOf(t.instance)
    }
    return t
  }

  const lookupName = (name: string, pos: number): Type => {
    const def = current.scope.get(name)
    if (def) {
      if (def.params.length > 0) fail("wrong-arity", `${name} needs ${def.params.length} argument${def.params.length > 1 ? "s" : ""} (${[name, ...def.params].join(" ")})`, pos)
      return refTo(instance(def, [], pos), pos)
    }
    const std = current.std.get(name)
    if (std) return { kind: "std", name: std }
    if ((BUILTINS as readonly string[]).includes(name)) return { kind: "builtin", name: name as Builtin }
    if (name in PRELUDE_GENERIC) fail("wrong-arity", `${name} needs ${PRELUDE_GENERIC[name]} argument${PRELUDE_GENERIC[name]! > 1 ? "s" : ""}`, pos)
    const module = moduleOfType(name)
    if (!module) return fail("unknown-type", `unknown type ${name}`, pos)
    return fail("unknown-type", `unknown type ${name}; ${importHint({ module, name })}`, pos, { missingImport: { module, name }, hint: `I${importHint({ module, name }).slice(1)}.` })
  }

  const refTo = (inst: Instance, pos: number): Type => {
    if (inst.state === "done" && inst.stream) fail("misplaced-stream", `${inst.name} is a Stream; a stream can only be the whole file, not part of a type`, pos)
    pendingStreamChecks.push([inst, pos, current])
    return { kind: "ref", instance: inst }
  }
  const pendingStreamChecks: [Instance, number, Unit][] = []
  /** Cases with one named argument, which are record cases if it stands for a record. */
  const pendingCases: [Case, Type, number, Unit][] = []
  /** Each case as written, with where its tag is: the cases to warn about (no-json-form). */
  const writtenCases: [Case, number, Unit][] = []

  const evaluate = (n: Node, env: Env): Type => {
    switch (n.t) {
      case "name":
        if (n.name === "Stream") return fail("wrong-arity", "Stream needs 1 argument", n.pos)
        return lookupName(n.name, n.pos)
      case "var":
        return env.get(n.name)!
      case "app":
        return apply(n, env)
      case "record":
        return evaluateRecord(n, env)
      case "variant":
        return evaluateVariant(n, env)
    }
  }

  const apply = (n: Extract<Node, { t: "app" }>, env: Env): Type => {
    const arity = PRELUDE_GENERIC[n.head]
    if (arity !== undefined) {
      if (n.args.length !== arity) fail("wrong-arity", `${n.head} needs ${arity} argument${arity > 1 ? "s" : ""}`, n.pos)
      const [a, b] = n.args.map((x) => evaluate(x, env)) as [Type, Type]
      switch (n.head) {
        case "Array":
          return { kind: "array", item: a }
        case "Map":
          return { kind: "map", value: a }
        case "Maybe":
          return { kind: "maybe", item: a }
        case "Secret":
          return { kind: "secret", item: a }
        case "Result":
          return {
            kind: "variant",
            open: false,
            cases: [
              { tag: "Err", payload: { kind: "positional", items: [a] } },
              { tag: "Ok", payload: { kind: "positional", items: [b] } },
            ],
          }
        default:
          return fail("misplaced-stream", "Stream can only be the whole type of a definition: type Events = Stream Event", n.pos)
      }
    }
    const def = current.scope.get(n.head)
    if (!def) {
      if (current.std.has(n.head) || (BUILTINS as readonly string[]).includes(n.head)) fail("wrong-arity", `${n.head} takes no arguments`, n.pos)
      return lookupName(n.head, n.pos)
    }
    if (n.args.length !== def.params.length) {
      fail("wrong-arity", `${n.head} needs ${def.params.length} argument${def.params.length === 1 ? "" : "s"} (${[n.head, ...def.params].join(" ")}), got ${n.args.length}`, n.pos)
    }
    return refTo(instance(def, n.args.map((a) => evaluate(a, env)), n.pos), n.pos)
  }

  /** The record or variant that `...Name` copies from, evaluated now if necessary. */
  const spreadOf = (sp: SpreadNode, want: "record" | "variant"): RecordType | VariantType => {
    const def = current.scope.get(sp.name)
    if (!def) {
      // A built-in, prelude or imported standard type is known, and not a
      // record or variant of this file: the same error as for any other type
      // that isn't one. An unknown type is reported as such, with an import hint.
      const known = current.std.has(sp.name) || (BUILTINS as readonly string[]).includes(sp.name) || sp.name in PRELUDE_GENERIC
      if (!known) lookupName(sp.name, sp.pos)
      return fail("invalid-spread", `${sp.name} is not a ${want}, so it can't be spread here`, sp.pos)
    }
    if (def.params.length > 0) {
      fail("invalid-spread", `${sp.name} has parameters (${[sp.name, ...def.params].join(" ")}); only a type without parameters can be spread`, sp.pos)
    }
    const inst = instance(def, [], sp.pos)
    const t = resolveRef({ kind: "ref", instance: inst }, sp.pos)
    if (inst.stream) fail("invalid-spread", `${sp.name} is a Stream and can't be spread`, sp.pos)
    if (t.kind !== want) fail("invalid-spread", `${sp.name} is not a ${want}, so it can't be spread here`, sp.pos)
    return t as RecordType | VariantType
  }

  /** Own entries and spread ones, in the order they are written. */
  const inOrder = <T>(own: readonly T[], spreads: readonly SpreadNode[], spread: (sp: SpreadNode) => readonly T[]): T[] => {
    const out: T[] = []
    own.forEach((x, i) => {
      for (const sp of spreads) if (sp.at === i) out.push(...spread(sp))
      out.push(x)
    })
    for (const sp of spreads) if (sp.at === own.length) out.push(...spread(sp))
    return out
  }

  /** Reports a field or tag that appears twice, saying where each one came from. */
  const once = (what: "field" | "tag") => {
    const seen = new Map<string, string>()
    return (name: string, from: string, pos: number) => {
      const before = seen.get(name)
      if (before !== undefined) {
        const where = [before, from].filter(Boolean).join(" and ")
        fail(what === "field" ? "duplicate-field" : "duplicate-tag", `${what} ${name} appears twice${where ? ` (${where})` : ""}`, pos)
      }
      seen.set(name, from)
    }
  }

  const evaluateRecord = (n: RecordNode, env: Env): RecordType => {
    const check = once("field")
    const own = n.fields.map((f) => ({ field: { key: f.key, optional: f.optional, type: evaluate(f.type, env), attributes: f.attributes } as Field, from: "", pos: f.pos }))
    const fields = inOrder(own, n.spreads, (sp) =>
      (spreadOf(sp, "record") as RecordType).fields.map((field) => ({ field, from: `from ...${sp.name}`, pos: sp.pos })),
    ).map(({ field, from, pos }) => (check(field.key, from, pos), field))
    // Open or closed is decided here alone, never by what is spread in.
    return { kind: "record", fields, closed: n.closed }
  }

  const evaluateVariant = (n: VariantNode, env: Env): VariantType => {
    const check = once("tag")
    const own = n.cases.map((c) => {
      const [first] = c.args
      const payload: Payload =
        c.args.length === 0 ? { kind: "none" }
        : c.args.length === 1 && first!.t === "record" ? { kind: "record", record: evaluateRecord(first!, env) }
        : { kind: "positional", items: c.args.map((a) => evaluate(a, env)) }
      const out = { tag: c.tag, payload, attributes: c.attributes } as Case
      // One named argument may stand for a record (`Box BoxRec`, `Found (Page Int32)`): decided
      // once every type is evaluated, since it may name the type being evaluated (`< S Nat >`).
      // A type parameter (`Box a`) never makes a record case, whatever it is applied to.
      if (payload.kind === "positional" && payload.items.length === 1 && payload.items[0]!.kind === "ref" && first!.t !== "var") pendingCases.push([out, payload.items[0], first!.pos, current])
      writtenCases.push([out, c.pos, current])
      return { c: out, from: "", pos: c.pos }
    })
    const cases = inOrder(own, n.spreads, (sp) =>
      (spreadOf(sp, "variant") as VariantType).cases.map((c) => ({ c, from: `from ...${sp.name}`, pos: sp.pos })),
    ).map(({ c, from, pos }) => (check(c.tag, from, pos), c))
    // Open or closed is decided here alone, never by what is spread in.
    return { kind: "variant", cases, open: !n.closed }
  }

  const definitionOf = (def: Def): Definition => {
    if (def.definition) return def.definition
    const d = def.decl
    def.definition = {
      name: d.name,
      id: def.unit.id === undefined ? d.name : `${def.unit.id}#${d.name}`,
      module: def.unit.id,
      params: def.params,
      doc: d.doc,
      source: def.unit.text.slice(d.docStart, d.end).trim(),
      attributes: d.attributes,
      offset: d.pos,
      template: undefined as unknown as Instance, // set below, once the definition exists
    }
    return def.definition
  }

  // Evaluate every definition of every file (templates for generic ones), so all errors surface.
  for (const def of allDefs) {
    const definition = definitionOf(def)
    const args = def.params.map((p): Type => ({ kind: "param", name: p }))
    const inst = within(def.unit, () => instance(def, args, def.decl.pos))
    ;(definition as { template: Instance }).template = inst
    while (queue.length > 0) {
      const [i, d] = queue.shift()!
      evaluateInstance(i, d)
    }
  }
  for (const [inst, pos, unit] of pendingStreamChecks) {
    if (inst.stream) unit.fail("misplaced-stream", `${inst.name} is a Stream; a stream can only be the whole file, not part of a type`, pos)
  }
  // §9.9: every cycle passes through a record, array or variant.
  for (const inst of instances.values()) within(defOf.get(inst)!.unit, () => resolveRef({ kind: "ref", instance: inst }, inst.definition.offset, true))
  // §15: a case whose one argument names a record is a record case. Spreads share the
  // Case objects, so setting the payload here reaches every variant that copied the case.
  for (const [c, arg, pos, unit] of pendingCases) {
    const t = within(unit, () => resolveRef(arg, pos))
    if (t.kind === "record") (c as { payload: Payload }).payload = { kind: "record", record: t, named: arg }
  }

  // §16: a record case with a field named _tag or _args has no schema-based JSON form. The schema
  // is valid; warn at the case, once (a generic type's instances share where the case is written).
  const noJsonForm = new Map<number, RawWarning>()
  for (const [c, pos, unit] of writtenCases) {
    if (unit !== root || noJsonForm.has(pos) || c.payload.kind !== "record") continue
    const field = c.payload.record.fields.find((f) => f.key === "_tag" || f.key === "_args")
    if (field === undefined) continue
    noJsonForm.set(pos, {
      kind: "no-json-form",
      message: `${c.tag} has no schema-based JSON form: its record has a field named ${field.key}, which that form uses itself. Rename the field, or use self-describing JSON`,
      pos,
      end: pos + c.tag.length,
    })
  }

  const definitions = [...root.own.values()].map((d) => d.definition!)
  const byName = new Map(definitions.map((d) => [d.name, d]))
  const imported = new Map([...root.scope].filter(([, d]) => d.unit !== root).map(([name, d]) => [name, d.definition!]))
  const warnings = [...root.warnings, ...deprecatedUses(root), ...noJsonForm.values()]
    .sort((a, b) => a.pos - b.pos)
    .map(({ kind, message, pos, end }): SchemaWarning => {
      const at = locate(text, pos, START)
      return { kind, code: kind, message, offset: at.offset, end, line: at.line, column: at.column }
    })
  return { definitions, imports: root.std, imported, id: options.id, definition: (name) => byName.get(name) ?? imported.get(name), warnings }
}

/**
 * The instance of a non-generic definition, or of a generic one applied to
 * concrete types. Use for building schemas.
 */
export function instanceOf(file: SchemaFile, name: string): Instance | undefined {
  const d = file.definition(name)
  return d && d.params.length === 0 ? d.template : undefined
}
