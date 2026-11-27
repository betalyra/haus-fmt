/**
 * Schemas from schema files, with packages, rules and codecs (spec §13–§15,
 * packages.md): read, compile, decode, encode.
 *
 *   const schema = pipe(
 *     await readSources("order.schema.haus"),                  // @haus-fmt/haus/node; or Sources.make(…) from data
 *     Result.map(Sources.withPackage(Package.shapeOnly(acme))),
 *     Result.flatMap(Schema.compile),
 *     Result.flatMap(Schema.withCodec(instantAsDate)),
 *   )
 *   const order = Result.flatMap(schema, (s) => Schema.decode(s, Order)(text))   // Result<Order, HausError>
 *
 * Reading is the only step that touches files; `Sources.make` and
 * `Package.make` take plain data, so a compile can run with no file system.
 * A compile has the official packages built in, the packages the sources
 * carry (values and directories read), and nothing else: it never looks for
 * a package (packages.md §2). It checks the `rules` field of each package
 * the schema reaches and requires an implementation of every rule of a type
 * the schema reaches (`missing-codec`, packages.md §7), unless the package is
 * taken shape-only. Rules are checked on every value of their type that is
 * decoded or encoded, before any codec.
 *
 * Every function that can fail gives a Result; none throws (a value changed
 * after it was built is a programming error, `value-changed`).
 */
import { quoteText } from "./chars.js"
import { checkWellFormed, HausConfigError, HausDecodeError, HausPackageError, isHausError, START, type ErrorCode, type HausError } from "./errors.js"
import type { FormatOptions } from "./format.js"
import { OFFICIAL } from "./official.js"
import { checkSchemaText, RULE_NAME, sameTexts, shownPackage, type Package } from "./package.js"
import { Parser, withDefaults } from "./parser.js"
import { BUILT_IN_TYPE_IDS, type CodecWarning } from "./codec-ids.js"
import { attempt, Result } from "./result.js"
import * as h from "./schema.js"
import { fromSchemaFile, type CompiledSchemaFile } from "./schema-compile.js"
import { ModuleError, parseSchemaFile, PRELUDE_ARITY, type Definition, type Instance, type ModuleResolver, type ParseSchemaOptions, type ResolvedModule, type SchemaFile, type SchemaWarning, type Type as SchemaType } from "./schema-file.js"
import type { StandardSchemaV1 } from "./standard.js"
import type { StreamType, Type, TypeLambda, TypeOf } from "./types.js"
import { isValue, type Value } from "./value.js"

// ── Sources ──────────────────────────────────────────────────

/** Why reading a relative import failed (`readSources`), replayed at the import when compiling. */
export interface ReadFailure {
  readonly code: ErrorCode | undefined
  readonly message: string
}

/** The packages read from a folder (packages.md §2): those it has, and its subdirectories skipped, named. */
export interface Folder {
  readonly path: string
  readonly packages: readonly Package[]
  readonly skipped: readonly string[]
}

/**
 * What a compile reads, as data: the schema's files (the entry file and the
 * files it imports relatively, by their paths from the build's root, spec
 * §13.3) and the packages given to it. Make one with `readSources` (from the
 * file system, `@haus-fmt/haus/node`) or `Sources.make` (from plain data).
 */
export interface Sources {
  readonly _tag: "Sources"
  /** The entry file's path among `files`: `order.schema.haus`, `app/order.schema.haus`. */
  readonly entry: string
  /** The schema files by their paths from the build's root, `/`-separated. */
  readonly files: ReadonlyMap<string, string>
  /** The entry file's id (spec §13.3, "Identity"), when it isn't its path: a package's `schema.haus` is `@org/name@N`. */
  readonly id: string | undefined
  /** Relative imports that reading refused (`from \0 module`), reported at the import when compiling. */
  readonly failures: ReadonlyMap<string, ReadFailure>
  /** Packages given: values (`withPackage`) and directories read (`readSources`' `packages`). */
  readonly packages: readonly Package[]
  /** Folders of packages read (`readSources`' `folders`): their packages don't replace a package given. */
  readonly folders: readonly Folder[]
}

const MAX_FILES = 256
/** A path among a sources' files: names separated by `/`, none empty, `.` or `..`. */
const SOURCE_PATH = /^(?!\/)(?:(?!\.\.?(?:\/|$))[^/\0]+\/)*(?!\.\.?$)[^/\0]+$/

const isSources = (u: unknown): u is Sources => typeof u === "object" && u !== null && (u as { _tag?: unknown })._tag === "Sources"

/** @internal Sources from checked parts, for the readers. */
export const sourcesOf = (parts: Omit<Sources, "_tag">): Sources => Object.freeze({ _tag: "Sources", ...parts })

/**
 * Sources from plain data (packages.md §2: a program may have its files from
 * anywhere): the entry file's path and the files by path, from the build's
 * root. The checks of reading files, except those about the file system:
 * each path a plain relative path (`order.schema.haus`, `shared/address.schema.haus`),
 * at most 256 files of at most 1 MiB each, UTF-8 text.
 *
 *   Sources.make("order.schema.haus", { "order.schema.haus": text, "common.schema.haus": common })
 */
const make = (entry: string, files: Readonly<Record<string, string>> | ReadonlyMap<string, string>, options: { readonly id?: string } = {}): Result<Sources, HausPackageError> =>
  attempt(() => {
    const all = new Map(files instanceof Map ? files : Object.entries(files as Readonly<Record<string, string>>))
    if (all.size > MAX_FILES) throw new HausPackageError(`more than ${MAX_FILES} schema files`, "too-many-files")
    for (const [path, text] of all) {
      if (typeof path !== "string" || !SOURCE_PATH.test(path)) throw new HausPackageError(`${quoteText(String(path))} is not a path from the build's root: names separated by /, without . or ..`, "import-not-found")
      if (typeof text !== "string") throw new HausPackageError(`${quoteText(path)} must be the file's text`, "import-not-found")
      checkSchemaText(text, quoteText(path))
    }
    if (!all.has(entry)) throw new HausPackageError(`the entry file ${quoteText(entry)} is not among the files given`, "import-not-found")
    return sourcesOf({ entry, files: all, id: options.id, failures: new Map(), packages: [], folders: [] })
  }, (e): e is HausPackageError => e instanceof HausPackageError)

const withPackage: {
  (pkg: Package): (sources: Sources) => Sources
  (sources: Sources, pkg: Package): Sources
} = ((...args: [Sources, Package] | [Package]) =>
  args.length === 2 ? sourcesOf({ ...args[0], packages: [...args[0].packages, args[1]] }) : (s: Sources) => sourcesOf({ ...s, packages: [...s.packages, args[0]] })) as never

/**
 * Sources: `Sources.make(entry, files)` from plain data, and
 * `Sources.withPackage(pkg)` to give a compile a package as a value (a
 * library's bundle, `Package.shapeOnly(…)`, `Package.withRule(…)`).
 */
export const Sources = Object.freeze({ make, withPackage, is: isSources })

// ── Codecs ───────────────────────────────────────────────────

/**
 * A codec (spec §13.4): the host type of the named type `Id`, as a typed
 * pair of functions between the value the type's schema decodes (`A`, the
 * type without codecs) and the program's host value (`B`). It runs after the
 * type's schema and rule, so it can reject more values (`codec-rejected`),
 * never fewer; `encode` rejects what it can't write (`cannot-encode`).
 * Decoding what it encoded must give the same value.
 */
export interface Codec<Id extends string = string, A = never, B = unknown> {
  readonly _tag: "Codec"
  readonly id: Id
  readonly decode: (a: A) => Result<B, string>
  readonly encode: (b: B) => Result<A, string>
}

/**
 * `Codec.make(type, { decode, encode })`: a codec for a type, by its handle.
 * `decode` receives the value the type's schema decoded; a part with a codec
 * of its own is its host value there (spec §13.4, inside out).
 *
 *   const instantAsDate = Codec.make(StdTime.Instant, {
 *     decode: (s) => Result.succeed(new Date(s)),                    // lossy: the offset as written is lost
 *     encode: (d) => (isNaN(d.getTime()) ? Result.fail("an invalid Date") : Result.succeed(d.toISOString())),
 *   })
 */
const makeCodec = <F extends TypeLambda, Id extends string, B>(
  type: Type<F, Id>,
  pair: { readonly decode: (a: TypeOf<F, {}>) => Result<B, string>; readonly encode: (b: B) => Result<TypeOf<F, {}>, string> },
): Codec<Id, TypeOf<F, {}>, B> => Object.freeze({ _tag: "Codec", id: type.id, decode: pair.decode, encode: pair.encode })

export const Codec = Object.freeze({ make: makeCodec })

/** A codec as the engine applies it: a transform whose failures are thrown, so that the engine reports them at the type's place. */
const engineCodec = (c: Codec<string, unknown, unknown>) => ({
  id: c.id,
  apply: (base: h.AnySchema) =>
    h.transform(
      base,
      (a: unknown) => {
        const r = c.decode(a)
        if (r._tag === "Failure") throw new Error(r.failure)
        return r.success
      },
      (b: unknown) => {
        const r = c.encode(b)
        if (r._tag === "Failure") throw new Error(r.failure)
        return r.success
      },
    ),
})

// ── Schema ───────────────────────────────────────────────────

/** Why a rule rejects a value, or undefined: a package's rule as the engine checks it. */
type Check = (value: unknown) => string | undefined

/**
 * A compiled schema: the entry file's types, the packages it reaches with
 * their rules, and the codecs set. `H` (type-level only) holds the host
 * types the codecs choose, by type id.
 */
export interface Schema<H = {}> {
  readonly _tag: "Schema"
  /** The schema file, checked (its definitions, imports and warnings). */
  readonly file: SchemaFile
  /** The packages the schema reaches, by name, with the version used: built-in ones too. */
  readonly packages: ReadonlyMap<string, Package>
  /** Warnings: the schema file's own (`deprecated`, `unknown-attribute`, `no-json-form`) and `unused-codec`. */
  readonly warnings: readonly (SchemaWarning | CodecWarning)[]
  /** Type-level only: the codecs' host types. */
  readonly "~hosts"?: H
  /** @internal The rules checked, by type id. */
  readonly rules: ReadonlyMap<string, Check>
  /** @internal The codecs set, by type id. */
  readonly codecs: ReadonlyMap<string, Codec<string, unknown, unknown>>
  /** @internal Every named type the schema reaches, by id: zero-argument instances, and the definitions of the others. */
  readonly instances: ReadonlyMap<string, Instance>
  readonly definitions: ReadonlyMap<string, Definition>
  /** @internal The schemas of the engine, built once per Schema. */
  readonly engine: () => CompiledSchemaFile
}

const isSchema = (u: unknown): u is Schema<unknown> => typeof u === "object" && u !== null && (u as { _tag?: unknown })._tag === "Schema"

/** The package of a type id: `@acme/codes` for `@acme/codes@1#Code`. */
const packageOfId = (id: string): string => id.slice(0, id.indexOf("#")).replace(/@[0-9]+$/, "")

/** A file's id, from its path: never in the form of a package's (`@org/name@N`, spec §13.3). */
const fileIdOf = (path: string): string => {
  const stem = path.replace(/\.schema\.haus$/, "")
  return stem.startsWith("@") ? `./${stem}` : stem
}

/** The packages of a compile, by name, with the names of packages given twice with other files (packages.md §2, §3). */
interface Collected {
  readonly byName: ReadonlyMap<string, Package>
  readonly clashes: ReadonlyMap<string, string>
  readonly skipped: readonly string[]
}

/**
 * The packages a compile has: the official ones (built in), the packages
 * given (values, their bundles' dependencies, directories), and those found
 * in folders, which replace none. A copy of an official package must be the
 * built-in one byte for byte (`duplicate-package`, whether a schema imports
 * it or not); two different packages with one name are `duplicate-package`
 * when a schema imports the name.
 */
const collect = (sources: Sources): Collected => {
  const byName = new Map<string, Package>(OFFICIAL)
  const clashes = new Map<string, string>()
  const fromDirectory = new Set<string>()
  const official = (p: Package): boolean => {
    const builtIn = OFFICIAL.get(p.name)
    if (builtIn === undefined) return false
    if (!sameTexts(builtIn, p)) {
      throw new HausPackageError(`${p.name} is an official package, built in at ${quoteText(builtIn.version)}; the copy given (${shownPackage(p)}) differs from it: an official package can't be replaced`, "duplicate-package")
    }
    // The built-in one, as the program takes it (shape-only, or with rules of its own).
    const known = byName.get(p.name)!
    byName.set(p.name, merged(known, p))
    return true
  }
  const add = (p: Package): void => {
    if (official(p)) return
    const first = byName.get(p.name)
    if (first === undefined) byName.set(p.name, p)
    else if (sameTexts(first, p)) byName.set(p.name, merged(first, p))
    else if (!clashes.has(p.name)) clashes.set(p.name, `two packages are named ${p.name}: ${shownPackage(first)} and ${shownPackage(p)}`)
  }
  // Given packages, with the dependencies of bundles (each once).
  const seen = new Set<Package>()
  const given = (p: Package): void => {
    if (seen.has(p)) return
    seen.add(p)
    add(p)
    if (p.origin.kind === "directory") fromDirectory.add(p.name)
    p.dependencies.forEach(given)
  }
  sources.packages.forEach(given)
  // Folders: a package given by its directory is used instead; any other with its name and other files is a second package.
  const skipped: string[] = []
  for (const folder of sources.folders) {
    skipped.push(...folder.skipped)
    for (const p of folder.packages) {
      if (official(p)) continue
      if (fromDirectory.has(p.name)) continue
      add(p)
    }
  }
  return { byName, clashes, skipped }
}

/** One package from two copies with the same files: shape-only if either is, with the rules of both. */
const merged = (a: Package, b: Package): Package =>
  a === b ? a : Object.freeze({ ...a, shapeOnly: a.shapeOnly || b.shapeOnly, rules: new Map([...a.rules, ...b.rules]), documents: a.documents ?? b.documents })

/** The id of a package's schema: `@org/name@N`. */
const packageId = (p: Package): string => `${p.name}@${p.version.split(".")[0]}`

/** The resolver of a compile: relative files from the sources, packages by name from `collected`. Records the packages reached. */
const resolverOf = (sources: Sources, collected: Collected, reached: Map<string, Package>): ModuleResolver => ({
  resolve(module: string, from: string | undefined): ResolvedModule {
    if (module.startsWith("./") || module.startsWith("../")) {
      if (from?.startsWith("pkg:")) throw new ModuleError("package-path", `the schema of ${from.slice(4)} can't import files, only packages by name`)
      const origin = from ?? sources.entry
      const failure = sources.failures.get(`${origin}\0${module}`)
      if (failure !== undefined) throw failure.code === undefined ? new Error(failure.message) : new ModuleError(failure.code, failure.message)
      const dir = origin.split("/").slice(0, -1)
      const names = module.split("/")
      let up = 0
      while (names[up] === "..") up++
      if (up > dir.length) throw new ModuleError("import-outside-root", `${origin} imports ${module}, which goes above the build's root`)
      const path = [...dir.slice(0, dir.length - up), ...names.slice(names[0] === "." ? 1 : up)].join("/") + ".schema.haus"
      const text = sources.files.get(path)
      if (text === undefined) throw new Error(`file not found: ${path}`)
      return { key: path, id: fileIdOf(path), text, path }
    }
    const clash = collected.clashes.get(module)
    if (clash !== undefined) throw new ModuleError("duplicate-package", clash)
    const p = collected.byName.get(module)
    if (p === undefined) {
      const skipped = collected.skipped.length === 0 ? "" : `; these packages could not be read: ${collected.skipped.join(", ")}`
      throw new Error(`package not found: ${module} is not among the packages given (give it as a value with Sources.withPackage, or its directory to readSources)${skipped}`)
    }
    reached.set(p.name, p)
    return { key: `pkg:${p.name}`, id: packageId(p), text: p.schema, version: p.version, package: p.name, manifest: p.manifest, path: p.name }
  },
})

/**
 * The named types the schema reaches (packages.md §7): every instance its
 * file's definitions name, directly or through other types, in any package.
 * Zero-argument instances by id, and every definition met by id.
 */
const reach = (file: SchemaFile): { readonly instances: Map<string, Instance>; readonly definitions: Map<string, Definition> } => {
  const instances = new Map<string, Instance>()
  const definitions = new Map<string, Definition>()
  const seenInstances = new Set<Instance>()
  const seenTypes = new Set<SchemaType>()
  // An explicit stack: types nest as deep as schema files allow, and instances form cycles.
  const stack: SchemaType[] = []
  const visit = (inst: Instance): void => {
    if (seenInstances.has(inst)) return
    seenInstances.add(inst)
    definitions.set(inst.definition.id, inst.definition)
    if (inst.args.length === 0 && !instances.has(inst.definition.id)) instances.set(inst.definition.id, inst)
    stack.push(inst.body, ...inst.args)
  }
  file.definitions.forEach((d) => visit(d.template))
  while (stack.length > 0) {
    const t = stack.pop()!
    if (seenTypes.has(t)) continue
    seenTypes.add(t)
    switch (t.kind) {
      case "ref":
        visit(t.instance)
        break
      case "array":
      case "maybe":
      case "secret":
        stack.push(t.item)
        break
      case "map":
        stack.push(t.value)
        break
      case "record":
        for (const f of t.fields) stack.push(f.type)
        break
      case "variant":
        for (const c of t.cases) {
          if (c.payload.kind === "positional") stack.push(...c.payload.items)
          else if (c.payload.kind === "record") stack.push(c.payload.named ?? c.payload.record)
        }
        break
      default:
        break
    }
  }
  return { instances, definitions }
}

/**
 * The `rules` field of a package the schema reaches (packages.md §4): a
 * record from a type's name to its rule's name, each type defined in the
 * package's schema without parameters and not as a Stream, each rule's name
 * `[a-z][a-z0-9-]*`, and, for a package read from files, each rule's prose in
 * `rules/<name>.md`. Gives the rules by type name; `package-manifest` else.
 */
const rulesOf = (p: Package, resolver: ModuleResolver): ReadonlyMap<string, string> => {
  const bad = (why: string): never => {
    throw new HausPackageError(`${p.name}: its manifest's rules field ${why}`, "package-manifest")
  }
  const field = p.rulesField
  if (field === undefined) return new Map()
  if (field.kind !== "record") return bad(`must be a record from a type's name to its rule's name, as rules: { "Code": "iso" }`)
  // The package's own definitions, from its schema (its imports are packages, resolved as in the compile).
  const own = parseSchemaFile(p.schema, { key: `pkg:${p.name}`, id: packageId(p), resolver })
  const rules = new Map<string, string>()
  for (const [type, rule] of field.fields) {
    if (rule.kind !== "string") bad(`gives ${quoteText(type)} ${rule.kind === "array" ? "a list" : `a ${rule.kind}`}: a type has one rule, named by a string`)
    const name = (rule as { readonly value: string }).value
    if (!RULE_NAME.test(name)) bad(`names the rule ${quoteText(name)}: a rule's name is [a-z][a-z0-9-]*`)
    const d = own.definition(type)
    if (d === undefined) bad(`names ${quoteText(type)}, which its schema doesn't define`)
    if (d!.params.length > 0) bad(`names ${quoteText(type)}, which has type parameters: a rule is for a type without parameters`)
    if (d!.template.stream) bad(`names ${quoteText(type)}, which is a Stream: a rule decides on one value of its type`)
    if (p.documents !== undefined && !p.documents.has(name)) bad(`names the rule ${name}, whose prose rules/${name}.md the package doesn't have (a regular file, not a link)`)
    rules.set(type, name)
  }
  return rules
}

/** A rule's implementation as the engine checks it: a Result's failure is why it rejects the value. */
const checkOf = (rule: (value: unknown) => Result<unknown, string>): Check => (value) => {
  const r = rule(value)
  return r._tag === "Failure" ? r.failure : undefined
}

/** The message of `missing-codec` (packages.md §7). */
const missingMessage = (id: string, rule: string): string =>
  `${id} has the rule ${rule}, and this program has no implementation of it: add the package's rule (withRule), or take the package shape-only (shapeOnly)`

/** The Schema of `file` with `rules` and `codecs`; its engine is built when first used. */
const schemaOf = <H>(parts: Omit<Schema<H>, "_tag" | "engine" | "~hosts">): Schema<H> => {
  let engine: CompiledSchemaFile | undefined
  return Object.freeze({
    _tag: "Schema",
    ...parts,
    engine: () => (engine ??= fromSchemaFile(parts.file, { codecs: [...parts.codecs.values()].map(engineCodec), rules: parts.rules })),
  })
}

/**
 * Compile sources (spec §14, packages.md §7): the entry file and the files
 * it imports, the official packages and the packages given. Fails with the
 * schema file's errors (HausSchemaFileError, at their place), the package
 * layer's (HausPackageError: `duplicate-package`, `package-manifest`,
 * `missing-codec`), never with an exception.
 */
const compile = (sources: Sources): Result<Schema, HausError> =>
  attempt(() => {
    const collected = collect(sources)
    const reached = new Map<string, Package>()
    const resolver = resolverOf(sources, collected, reached)
    const entryText = sources.files.get(sources.entry)!
    const file = parseSchemaFile(entryText, { key: sources.entry, id: sources.id ?? fileIdOf(sources.entry), resolver })
    // Each package reached: its rules field first, whatever is reached of it (packages.md §4).
    const ruleNames = new Map<string, string>()
    for (const p of [...reached.values()]) for (const [type, rule] of rulesOf(p, resolver)) ruleNames.set(`${packageId(p)}#${type}`, rule)
    const { instances, definitions } = reach(file)
    // Every rule of a reached type needs an implementation, unless its package is taken shape-only (packages.md §7).
    const rules = new Map<string, Check>()
    const missing: string[] = []
    for (const id of instances.keys()) {
      const rule = ruleNames.get(id)
      if (rule === undefined) continue
      const p = reached.get(packageOfId(id))!
      if (p.shapeOnly) continue
      const implementation = p.rules.get(id.slice(id.indexOf("#") + 1))
      if (implementation === undefined) missing.push(missingMessage(id, rule))
      else rules.set(id, checkOf(implementation))
    }
    if (missing.length > 0) throw new HausPackageError(missing.join("; "), "missing-codec")
    const packages = new Map([...reached.values()].sort((a, b) => (a.name < b.name ? -1 : 1)).map((p) => [p.name, p]))
    return schemaOf<{}>({ file, packages, warnings: file.warnings, rules, codecs: new Map(), instances, definitions })
  }, isHausError)

/** Why the type `id` can't have a codec (packages.md §7), or undefined. */
const noCodecReason = (schema: Schema<unknown>, id: string): string | undefined => {
  const hash = id.indexOf("#")
  const name = id.slice(hash + 1)
  if (id.startsWith("prelude#") && name in PRELUDE_ARITY) return `${name} has type parameters: set the codec for the types it is applied to`
  const d = schema.definitions.get(id)
  if (d === undefined) return undefined
  if (d.params.length > 0) return `${name} has type parameters (${d.params.join(", ")}): set the codec for a type that uses it, or for its arguments`
  if (d.template.stream) {
    const item = d.template.body.kind === "ref" ? d.template.body.instance.name : "its items' type"
    return `${name} is a Stream: set the codec for ${item}`
  }
  return undefined
}

/** A codec for `Id` with the host type `B`, whatever the type it decodes from. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type CodecFor<Id extends string, B> = Codec<Id, any, B>

const withCodecOn = <H, Id extends string, B>(schema: Schema<H>, codec: CodecFor<Id, B>): Result<Schema<Omit<H, Id> & { readonly [K in Id]: B }>, HausError> =>
  attempt(() => {
    const c = codec as unknown as Codec<string, unknown, unknown>
    if (c?._tag !== "Codec") throw new HausConfigError("withCodec takes a codec (Codec.make)")
    if (schema.codecs.has(c.id)) throw new HausConfigError(`two codecs for ${c.id}: set one codec per type`)
    const why = noCodecReason(schema as Schema<unknown>, c.id)
    if (why !== undefined) throw new HausConfigError(`a codec for ${c.id} would never run: ${why}`)
    const known = BUILT_IN_TYPE_IDS.has(c.id) || schema.file.typeIds.has(c.id)
    const warnings: (SchemaWarning | CodecWarning)[] = known ? [...schema.warnings] : [...schema.warnings, { code: "unused-codec", id: c.id, message: `a codec is set for ${c.id}, but no type has that id: it never runs` }]
    const next = schemaOf<Omit<H, Id> & { readonly [K in Id]: B }>({ ...schema, warnings, codecs: new Map([...schema.codecs, [c.id, c]]) })
    // Built now: a codec that can't apply somewhere is reported here (`codec-unreachable`).
    next.engine()
    return next
  }, isHausError)

const withCodec: {
  <Id extends string, B>(codec: CodecFor<Id, B>): <H>(schema: Schema<H>) => Result<Schema<Omit<H, Id> & { readonly [K in Id]: B }>, HausError>
  <H, Id extends string, B>(schema: Schema<H>, codec: CodecFor<Id, B>): Result<Schema<Omit<H, Id> & { readonly [K in Id]: B }>, HausError>
} = ((...args: unknown[]) =>
  isSchema(args[0]) ? withCodecOn(args[0], args[1] as CodecFor<string, unknown>) : (s: Schema<unknown>) => withCodecOn(s, args[0] as CodecFor<string, unknown>)) as never

// ── decoding and encoding ────────────────────────────────────

/** Options of decoding: the limits of spec §7 and the work budget of a call. */
export type DecodeOptions = h.Limits

/** Options of encoding: the limits, and `revealSecrets` (spec §15, "Encoding a secret"). */
export interface EncodeOptions extends h.Limits {
  /** Write every `Secret` in full. Off by default: a secret is refused, `cannot-encode` at the secret. */
  readonly revealSecrets?: boolean
}

/** The engine's schema of a type handle in `schema`; a handle the schema doesn't have is a HausConfigError. */
const engineSchema = (schema: Schema<unknown>, type: Type | StreamType): h.AnySchema => {
  if (typeof type !== "object" || type === null || (type._tag !== "Type" && type._tag !== "StreamType")) throw new HausConfigError("expected a type handle (Type)")
  const builtin = builtinSchema(type.id)
  if (builtin !== undefined) return builtin(schema)
  const inst = schema.instances.get(type.id)
  if (inst === undefined) throw new HausConfigError(`the schema has no type ${type.id}${schema.definitions.has(type.id) ? " without parameters" : ""}`)
  return schema.engine().schemaOf(inst)
}

/** The schema of a prelude or std/time type by its id, with its codec: decoding with `Prelude.Decimal` alone. */
const builtinSchema = (id: string): ((schema: Schema<unknown>) => h.AnySchema) | undefined => {
  if (!BUILT_IN_TYPE_IDS.has(id) || id.slice(id.indexOf("#") + 1) in PRELUDE_ARITY) return undefined
  return (schema) => {
    const text = id.startsWith("std/time#") ? `import std/time (${id.slice(9)})\ntype X = ${id.slice(9)}` : `type X = ${id.slice(8)}`
    const file = parseSchemaFile(text)
    const codec = schema.codecs.get(id)
    return fromSchemaFile(file, { codecs: codec === undefined ? [] : [engineCodec(codec)] }).schemas["X"]!
  }
}

/** Decode errors a decoder gives: syntax and decoding, and the configuration's. */
const isDecodeError = (e: unknown): e is HausError => isHausError(e)

/** `f` on a schema's type, with every error as a Result's failure. */
const run = <A>(f: () => A): Result<A, HausError> => attempt(f, isDecodeError)

/** The decoded value of a whole text: one value, or for a stream type every item. */
const decodeText = (s: h.AnySchema, stream: boolean, text: string, options: DecodeOptions): unknown => {
  if (!stream) return h.parse(s, text, options)
  checkWellFormed(text)
  return Object.freeze(new Parser(text, START, withDefaults(options)).parseSequence().map((v, i) => decodeItem(s, v, options, i)))
}

/** Item `i` of a stream, its errors at `$[i]`. */
const decodeItem = (s: h.AnySchema, v: Value, options: DecodeOptions, i: number): unknown => {
  try {
    return h.decode(s, v, options)
  } catch (e) {
    if (e instanceof HausDecodeError) throw new HausDecodeError(e.reason, [i, ...e.path], e.code, e)
    throw e
  }
}

type Decoded<F extends TypeLambda, H> = TypeOf<F, H>

const dual3 = <S, T, I, O>(f: (schema: S, type: T, input: I, options?: never) => O) =>
  ((schema: S, type: T, ...rest: [] | [I, never?]) => (rest.length === 0 ? (input: I, options?: never) => f(schema, type, input, options) : f(schema, type, rest[0] as I, rest[1]))) as never

/**
 * Decode haus text with a type of the schema (spec §15): one value, or for
 * a stream type (`type Log = Stream Entry`) the items. Rules and codecs are
 * applied; a secret is a `Secret`.
 *
 *   Schema.decode(schema, Order)(text)          // Result<Order, HausError>
 *   Schema.decode(schema, Order, text)
 *   pipe(text, Schema.decode(schema, Order))
 */
const decode: {
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>): (text: string, options?: DecodeOptions) => Result<Decoded<F, H>, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: StreamType<F>): (text: string, options?: DecodeOptions) => Result<readonly Decoded<F, H>[], HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>, text: string, options?: DecodeOptions): Result<Decoded<F, H>, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: StreamType<F>, text: string, options?: DecodeOptions): Result<readonly Decoded<F, H>[], HausError>
} = dual3((schema: Schema<unknown>, type: Type | StreamType, text: string, options?: DecodeOptions) =>
  run(() => decodeText(engineSchema(schema, type), type._tag === "StreamType", text, options ?? {})))

/** Decode a parsed `Value` with a type of the schema (spec §15). */
const decodeValue: {
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>): (value: Value, options?: DecodeOptions) => Result<Decoded<F, H>, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>, value: Value, options?: DecodeOptions): Result<Decoded<F, H>, HausError>
} = dual3((schema: Schema<unknown>, type: Type, value: Value, options?: DecodeOptions) =>
  run(() => (isValue(value) ? h.decode(engineSchema(schema, type), value, options ?? {}) : (() => {
    throw new HausConfigError("decodeValue takes a haus Value")
  })())))

/**
 * Encode a host value with a type of the schema into a haus `Value` (spec
 * §15): rules and codecs applied, the value checked as the constructors
 * check one (spec §7). A `Secret` is refused (`cannot-encode`) unless
 * `revealSecrets`.
 */
const encode: {
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>): (value: Decoded<F, H>, options?: EncodeOptions) => Result<Value, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>, value: Decoded<F, H>, options?: EncodeOptions): Result<Value, HausError>
} = dual3((schema: Schema<unknown>, type: Type, value: unknown, options?: EncodeOptions) => run(() => h.encode(engineSchema(schema, type), value, options ?? {})))

/** Options of writing with a schema: the layout (spec §11) and the encoder's options. */
export interface WriteSchemaOptions extends EncodeOptions {
  readonly style?: NonNullable<FormatOptions["style"]>
  readonly indent?: number
  readonly width?: number
}

/**
 * Encode and write as haus text (spec §11): one value, or for a stream type
 * the items, each followed by a comma. Fails as `encode` does, and for an
 * indent or width that isn't a whole number (`WriteOptions`).
 */
const stringify: {
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>): (value: Decoded<F, H>, options?: WriteSchemaOptions) => Result<string, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: StreamType<F>): (values: Iterable<Decoded<F, H>>, options?: WriteSchemaOptions) => Result<string, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>, value: Decoded<F, H>, options?: WriteSchemaOptions): Result<string, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: StreamType<F>, values: Iterable<Decoded<F, H>>, options?: WriteSchemaOptions): Result<string, HausError>
} = dual3((schema: Schema<unknown>, type: Type | StreamType, value: unknown, options?: WriteSchemaOptions) =>
  run(() => {
    const o = options ?? {}
    for (const k of ["indent", "width"] as const) if (o[k] !== undefined && !(Number.isSafeInteger(o[k]) && o[k]! >= 0)) throw new HausConfigError(`${k} must be a whole number of at least 0, not ${String(o[k])}`)
    const s = engineSchema(schema, type)
    if (type._tag === "StreamType") return h.formatAll(s, value as Iterable<unknown>, { ...o, stream: true })
    return h.stringify(s, value, o)
  }))

/** Read the schema-based JSON of a type (spec §16.3). */
const fromJson: {
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>): (json: string, options?: DecodeOptions) => Result<Decoded<F, H>, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>, json: string, options?: DecodeOptions): Result<Decoded<F, H>, HausError>
} = dual3((schema: Schema<unknown>, type: Type, json: string, options?: DecodeOptions) => run(() => h.fromJson(engineSchema(schema, type), json, options ?? {})))

/** Write the schema-based JSON of a value of a type (spec §16.3): a secret only with `revealSecrets`. */
const toJson: {
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>): (value: Decoded<F, H>, options?: EncodeOptions) => Result<string, HausError>
  <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>, value: Decoded<F, H>, options?: EncodeOptions): Result<string, HausError>
} = dual3((schema: Schema<unknown>, type: Type, value: unknown, options?: EncodeOptions) => run(() => h.toJson(engineSchema(schema, type), value, options ?? {})))

/**
 * A Standard Schema (standardschema.dev) of a type of the schema, for
 * libraries that take one: its input is haus text or a parsed `Value`.
 */
const standard = <H, F extends TypeLambda>(schema: Schema<H>, type: Type<F>): StandardSchemaV1<string | Value, Decoded<F, H>> => ({
  "~standard": {
    version: 1,
    vendor: "haus",
    validate: (input: unknown): StandardSchemaV1.Result<Decoded<F, H>> => {
      const r = typeof input === "string" ? decode(schema, type, input) : isValue(input) ? decodeValue(schema, type, input) : undefined
      if (r === undefined) return { issues: [{ message: "expected haus text or a parsed haus Value" }] }
      if (r._tag === "Success") return { value: r.success }
      const e: HausError = r.failure
      return { issues: [{ message: e.reason, ...("path" in e ? { path: e.path } : {}) }] }
    },
  },
})

/**
 * Decode a stream of haus text (spec §6) with a type, item by item, as the
 * chunks arrive: each item a Result; after a failure the stream ends.
 */
async function* decodeStream<H, F extends TypeLambda>(schema: Schema<H>, type: Type<F> | StreamType<F>, source: import("./stream.js").ChunkSource, options: DecodeOptions = {}): AsyncGenerator<Result<Decoded<F, H>, HausError>, void, undefined> {
  let s: h.AnySchema
  try {
    s = engineSchema(schema as Schema<unknown>, type)
  } catch (e) {
    if (isHausError(e)) return void (yield Result.fail(e))
    throw e
  }
  const items = h.decodeStream(s, source, options)
  for (;;) {
    let next: IteratorResult<unknown>
    try {
      next = await items.next()
    } catch (e) {
      if (isHausError(e)) return void (yield Result.fail(e))
      throw e
    }
    if (next.done === true) return
    yield Result.succeed(next.value as Decoded<F, H>)
  }
}

/**
 * Mark a type as read and written very often: `decode` and `stringify` use
 * generated code for it (`new Function`, or code `@haus-fmt/import` built
 * ahead). Values, texts and errors are the same.
 */
const optimize = <H>(schema: Schema<H>, type: Type): Schema<H> => {
  try {
    h.optimize(engineSchema(schema as Schema<unknown>, type))
  } catch {
    // A type the schema doesn't have: nothing to optimize.
  }
  return schema
}

/**
 * Compiled schemas (spec §14, §15, packages.md §7):
 *
 * - `Schema.compile(sources)`: `Result<Schema, HausError>`.
 * - `Schema.withCodec(codec)` (or `Schema.withCodec(schema, codec)`): the
 *   schema with a codec; two for one id, or one for a type that can't have
 *   one, is a HausConfigError.
 * - `Schema.decode`, `Schema.decodeValue`, `Schema.encode`, `Schema.stringify`,
 *   `Schema.fromJson`, `Schema.toJson`: `(schema, type)(input)` or
 *   `(schema, type, input)`, each a Result.
 * - `Schema.decodeStream`, `Schema.standard`, `Schema.optimize`.
 */
export const Schema = Object.freeze({ compile, withCodec, decode, decodeValue, encode, stringify, fromJson, toJson, decodeStream, standard, optimize, is: isSchema })

// ── for tools ────────────────────────────────────────────────

/** @internal The engine's schema of a type in a compiled schema (for first-party tools: @haus-fmt/effect, @haus-fmt/import). */
export const engineSchemaOf = (schema: Schema<unknown>, type: Type | StreamType): h.AnySchema => engineSchema(schema, type)

/**
 * @internal The entry file's text and the options to parse it with
 * (`parseSchemaFile`), its imports answered from the sources as a compile
 * answers them: for tools that parse a schema file themselves (checks,
 * hovers, declarations). Throws HausPackageError for packages that can't be
 * given together (an official package replaced).
 */
export const parseOptionsOf = (sources: Sources): { readonly text: string; readonly options: ParseSchemaOptions } => ({
  text: sources.files.get(sources.entry)!,
  options: { key: sources.entry, id: sources.id ?? fileIdOf(sources.entry), resolver: resolverOf(sources, collect(sources), new Map()) },
})

/** A package whose rules a tool doesn't check (packages.md §7, "Tools"): its name and `Type: rule` list. */
export interface UncheckedRules {
  readonly name: string
  readonly rules: string
}

const shapeOnlyWithoutRules = (p: Package): Package => (OFFICIAL.has(p.name) || p.rules.size > 0 ? p : Object.freeze({ ...p, shapeOnly: true }))

/**
 * @internal A compile for tools that check schemas without a program (an
 * editor, packages.md §7 "Tools"): the official packages' rules are checked
 * (built in), every other package without implementations is taken
 * shape-only, and the packages whose rules go unchecked are listed, for a
 * hint at their imports.
 */
export const compileForTool = (sources: Sources): Result<{ readonly schema: Schema; readonly unchecked: readonly UncheckedRules[] }, HausError> => {
  const shaped = sourcesOf({
    ...sources,
    packages: sources.packages.map(shapeOnlyWithoutRules),
    folders: sources.folders.map((f) => ({ ...f, packages: f.packages.map(shapeOnlyWithoutRules) })),
  })
  return Result.map(compile(shaped), (schema) => ({
    schema,
    unchecked: [...schema.packages.values()]
      .filter((p) => p.shapeOnly && p.rulesField?.kind === "record")
      .map((p) => ({ name: p.name, rules: [...(p.rulesField as Extract<Value, { kind: "record" }>).fields].map(([t, r]) => `${t}: ${r.kind === "string" ? r.value : "?"}`).join(", ") })),
  }))
}
