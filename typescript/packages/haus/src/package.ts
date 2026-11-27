/**
 * Schema packages as values (packages.md §3): a package's manifest text and
 * schema text, checked as a package read from a directory is (its manifest,
 * the limits), with the implementations of its rules in TypeScript (§6), the
 * packages its schema imports (a library's bundle carries them), and whether
 * the program takes it shape-only (§7).
 *
 *   const acme = Package.make({ manifest, schema })               // Result<Package, …>
 *   Package.shapeOnly(acme)                                        // its rules not checked
 *   Package.withRule(acme, "Id", (id) => (ulid.test(id) ? Result.succeed(id) : Result.fail("not a ULID")))
 *
 * A library that publishes a schema package exports one (a *bundle*), with
 * its rules; a program gives it to a compile (`Sources.withPackage`). The
 * official packages (`@haus-fmt/money`, `@haus-fmt/geo`, `@haus-fmt/uuid`)
 * are built in: nothing gives them, and a copy given must be the built-in
 * one byte for byte.
 */
import { quoteText } from "./chars.js"
import { HausConfigError, HausPackageError, HausSyntaxError, isHausError, START, type ErrorCode, type HausError } from "./errors.js"
import { Parser, withDefaults } from "./parser.js"
import { attempt, type Result } from "./result.js"
import { isPackageName } from "./schema-file.js"
import type { Type, TypeLambda, TypeOf } from "./types.js"
import type { Value } from "./value.js"

/** The largest manifest, in bytes (spec §13.3). */
export const MAX_MANIFEST_BYTES = 64 * 1024
/** The largest schema file, in bytes (spec §13.3). */
export const MAX_SCHEMA_BYTES = 1024 * 1024
const MAX_NAME = 214
/** A semantic version (SemVer 2.0), with pre-release and build. ASCII digits only. */
export const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/
/** A rule's name (packages.md §4). */
export const RULE_NAME = /^[a-z][a-z0-9-]*$/

/**
 * The implementation of a package's rule (packages.md §6): a check of the
 * value the type's schema decoded (before any codec), succeeding when the
 * rule accepts it, failing with why it doesn't.
 */
export type Rule<A = unknown> = (value: A) => Result<unknown, string>

/** Where a package came from, for messages and for which one wins (packages.md §2). */
export type PackageOrigin =
  | { readonly kind: "built-in" }
  | { readonly kind: "value" }
  | { readonly kind: "directory"; readonly path: string }
  | { readonly kind: "folder"; readonly path: string }

export interface Package {
  readonly _tag: "Package"
  /** The manifest's name: `@acme/orders`. */
  readonly name: string
  /** The manifest's version: `1.2.0`. */
  readonly version: string
  /** The manifest's text, `package.haus`. */
  readonly manifest: string
  /** The schema's text, `schema.haus`. */
  readonly schema: string
  /** The manifest's `rules` field as written, checked when a schema reaches the package (packages.md §4). */
  readonly rulesField: Value | undefined
  /** The implementations of its rules in TypeScript, by type name. */
  readonly rules: ReadonlyMap<string, Rule>
  /** The packages its schema imports (a bundle's direct dependencies). */
  readonly dependencies: readonly Package[]
  /** Taken shape-only (packages.md §7): its rules are not checked, and none is required. */
  readonly shapeOnly: boolean
  /** Read from a directory: the rule documents it has (`rules/iso.md` as `iso`). Undefined for a value made from data. */
  readonly documents: ReadonlySet<string> | undefined
  readonly origin: PackageOrigin
}

/** UTF-8 length of `s` (a string without lone surrogates). */
const utf8Length = (s: string): number => new TextEncoder().encode(s).length

/** A lone surrogate has no UTF-8 form (spec §4): such text can't be a file's. */
const wellFormed = (s: string): boolean => !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(s)

const fail = (code: ErrorCode, reason: string): never => {
  throw new HausPackageError(reason, code)
}

/** What a manifest says: its name, version and `rules` field (core §13.3, packages.md §4). */
export interface Manifest {
  readonly name: string
  readonly version: string
  readonly rulesField: Value | undefined
}

/**
 * Read a manifest's text (core §13.3): at most 64 KiB, one record, `name` a
 * lowercase `@org/name`, `version` a semantic version. Other fields are
 * ignored here; `rules` is kept as written. Throws HausPackageError
 * `package-manifest`; `shown` names the manifest in messages.
 */
export const readManifest = (text: string, shown: string): Manifest => {
  const bad = (why: string): never => fail("package-manifest", `${shown} is not a valid manifest: ${why}`)
  if (!wellFormed(text)) fail("invalid-utf8", `${shown} is not UTF-8 text`)
  if (utf8Length(text) > MAX_MANIFEST_BYTES) bad(`it is larger than ${MAX_MANIFEST_BYTES / 1024} KiB`)
  let values: Value[]
  try {
    values = new Parser(text, START, withDefaults({})).parseSequence()
  } catch (e) {
    // Where, not what: the message would quote the file.
    if (e instanceof HausSyntaxError) return bad(`it is not valid haus (${e.code} at ${e.line}:${e.column})`)
    throw e
  }
  const [value] = values
  if (values.length !== 1 || value?.kind !== "record") return bad(`it must be one record: { name: "@org/name", version: "1.2.0" }`)
  const field = (key: string): string => {
    const f = value.fields.get(key)
    return f?.kind === "string" ? f.value : bad(`it needs a string field ${key}`)
  }
  const name = field("name")
  const version = field("version")
  if (!isPackageName(name) || name.length > MAX_NAME) {
    bad(`the name "${quoteText(name)}" is not a lowercase @org/name (a-z, 0-9, - . _, each part starting with a letter or digit and not node_modules, at most ${MAX_NAME} characters)`)
  }
  if (!SEMVER.test(version)) bad(`the version "${quoteText(version)}" is not a semantic version like 1.2.0`)
  return { name, version, rulesField: value.fields.get("rules") }
}

/** A schema text as a package's (core §13.3): UTF-8, at most 1 MiB. */
export const checkSchemaText = (text: string, shown: string): void => {
  if (!wellFormed(text)) fail("invalid-utf8", `${shown} is not UTF-8 text`)
  if (utf8Length(text) > MAX_SCHEMA_BYTES) fail("file-too-large", `${shown} is larger than ${MAX_SCHEMA_BYTES / 1024 / 1024} MiB`)
}

/** The names of the types the `rules` field gives a rule, when it is a record (else none: it is checked at compile). */
export const ruleTypes = (field: Value | undefined): ReadonlyMap<string, string> => {
  if (field?.kind !== "record") return new Map()
  return new Map([...field.fields].flatMap(([type, rule]) => (rule.kind === "string" ? [[type, rule.value] as const] : [])))
}

/** What `Package.make` takes: a package as plain data. */
export interface PackageData {
  /** The manifest's text (`package.haus`). */
  readonly manifest: string
  /** The schema's text (`schema.haus`). */
  readonly schema: string
  /** Implementations of the package's rules, by type name (`{ Code: (c) => … }`). */
  readonly rules?: Readonly<Record<string, Rule<never>>>
  /** The packages its schema imports, for a library's bundle (packages.md §3). */
  readonly dependencies?: readonly Package[]
}

/** @internal A package from its texts, for the readers and the built-in packages. Throws HausPackageError. */
export const packageOf = (data: PackageData, origin: PackageOrigin, documents?: ReadonlySet<string>): Package => {
  const shown = origin.kind === "directory" || origin.kind === "folder" ? origin.path : "the package's manifest"
  const m = readManifest(data.manifest, origin.kind === "directory" || origin.kind === "folder" ? `${origin.path}/package.haus` : shown)
  checkSchemaText(data.schema, `${m.name}: its schema.haus`)
  const pkg: Package = Object.freeze({
    _tag: "Package",
    name: m.name,
    version: m.version,
    manifest: data.manifest,
    schema: data.schema,
    rulesField: m.rulesField,
    rules: new Map<string, Rule>(),
    dependencies: Object.freeze([...(data.dependencies ?? [])]),
    shapeOnly: false,
    documents,
    origin,
  })
  return Object.entries(data.rules ?? {}).reduce((p, [type, rule]) => withRuleOrThrow(p, type, rule as Rule), pkg)
}

/** `pkg` with `rule` for its type `type` (a name or an id of the package's); a type the manifest gives no rule is a HausConfigError. */
const withRuleOrThrow = (pkg: Package, type: string, rule: Rule): Package => {
  const hash = type.indexOf("#")
  if (hash >= 0 && type.slice(0, hash).replace(/@[0-9]+$/, "") !== pkg.name) throw new HausConfigError(`${type} is not a type of ${pkg.name}`)
  const name = hash >= 0 ? type.slice(hash + 1) : type
  if (typeof rule !== "function") throw new HausConfigError(`the rule for ${pkg.name}'s ${name} must be a function`)
  // A field that isn't a record is reported at compile (package-manifest); a record must name the type.
  if (pkg.rulesField?.kind === "record" && !ruleTypes(pkg.rulesField).has(name)) {
    throw new HausConfigError(`${pkg.name} gives ${name} no rule (its manifest's rules field), so there is no rule to supply for it`)
  }
  if (pkg.rulesField === undefined) throw new HausConfigError(`${pkg.name} has no rules field, so there is no rule to supply for ${name}`)
  return Object.freeze({ ...pkg, rules: new Map([...pkg.rules, [name, rule]]) })
}

const isPackage = (u: unknown): u is Package => typeof u === "object" && u !== null && (u as { _tag?: unknown })._tag === "Package"

const make = (data: PackageData): Result<Package, HausError> => attempt(() => packageOf(data, { kind: "value" }), isHausError)

const shapeOnly = (pkg: Package): Package => Object.freeze({ ...pkg, shapeOnly: true })

/** `withRule`'s type: a handle (whose id names the package) or the type's name in the package. */
type RuleTarget<F extends TypeLambda> = Type<F> | string

const withRule: {
  <F extends TypeLambda>(type: Type<F>, rule: Rule<TypeOf<F, {}>>): (pkg: Package) => Result<Package, HausConfigError>
  (type: string, rule: Rule): (pkg: Package) => Result<Package, HausConfigError>
  <F extends TypeLambda>(pkg: Package, type: Type<F>, rule: Rule<TypeOf<F, {}>>): Result<Package, HausConfigError>
  (pkg: Package, type: string, rule: Rule): Result<Package, HausConfigError>
} = ((...args: unknown[]) => {
  const run = (pkg: Package, type: RuleTarget<TypeLambda>, rule: Rule) =>
    attempt(() => withRuleOrThrow(pkg, typeof type === "string" ? type : type.id, rule), (e): e is HausConfigError => e instanceof HausConfigError)
  if (isPackage(args[0])) return run(args[0], args[1] as RuleTarget<TypeLambda>, args[2] as Rule)
  return (pkg: Package) => run(pkg, args[0] as RuleTarget<TypeLambda>, args[1] as Rule)
}) as never

/**
 * Package values (packages.md §3):
 *
 * - `Package.make({ manifest, schema, rules?, dependencies? })`: a package
 *   from plain data (a file, a database, memory), checked as a directory's
 *   would be except for files: its manifest, the limits.
 * - `Package.shapeOnly(pkg)`: the program takes the package shape-only
 *   (packages.md §7): its rules are not checked, and `missing-codec` is not
 *   reported for them. Official packages too.
 * - `Package.withRule(pkg, type, rule)` (or `Package.withRule(type, rule)(pkg)`):
 *   the program supplies the implementation of a rule the package's manifest
 *   names (packages.md §7); for a type it gives no rule, a HausConfigError.
 */
export const Package = Object.freeze({ make, shapeOnly, withRule, is: isPackage })

/** Two packages are one when their manifest and schema are the same byte for byte (core §13.3). */
export const sameTexts = (a: Package, b: Package): boolean => a.manifest === b.manifest && a.schema === b.schema

/** How a package is named in a message: its name and where it came from. */
export const shownPackage = (p: Package): string =>
  p.origin.kind === "directory" || p.origin.kind === "folder" ? `${quoteText(p.version)} in ${p.origin.path}` : p.origin.kind === "built-in" ? `${quoteText(p.version)} (built in)` : `${quoteText(p.version)} (given as a value)`
