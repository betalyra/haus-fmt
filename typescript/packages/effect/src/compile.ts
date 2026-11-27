/**
 * Schemas from schema files, with packages and their rules (spec §13–§15,
 * packages.md), as Effect schemas:
 *
 *   const program = Effect.gen(function* () {
 *     const sources = yield* Haus.readSources("order.schema.haus")           // needs SchemaFiles (a file system)
 *     const { schemas } = yield* Haus.compile(Haus.Sources.withPackage(sources, Haus.Package.shapeOnly(acme)))
 *     return yield* Haus.decode(schemas.Order!)(text)
 *   }).pipe(Effect.provide(NodeSchemaFiles.layer))                          // @haus-fmt/effect/node
 *
 * Reading is the only step that touches files: an Effect that needs the
 * `SchemaFiles` service. Compiling reads nothing: `Haus.compile` takes
 * `Sources` (read, or made from plain data with `Haus.Sources.make`) and needs
 * no service. Everything haus decides comes from `@haus-fmt/haus`: the
 * schema files, the official packages built in, the packages given, their
 * `rules` fields and `missing-codec`. This module turns the compiled schema
 * into Effect schemas, each package rule a check of its type, before any codec.
 */
import {
  Package as CorePackage, Result, Schema as CoreSchema, Sources as CoreSources, type Folder, type Package as PackageValue, type Schema as CompiledCore, type Sources as SourcesValue,
  type CodecWarning, type SchemaWarning, type TypeHandle, type TypeLambda as CoreTypeLambda, type TypeOf,
} from "@haus-fmt/haus/internal"
import { Context, Effect } from "effect"
import { compileErrorOf, HausCompileError, HausConfigError } from "./errors.js"
import { fromSchemaFile, type CompiledSchemaFile } from "./schema-file.js"

// ── errors ───────────────────────────────────────────────────

/** A core Result as an Effect: its failure (a core error) as this package's. */
const fromCore = <A>(r: Result<A, Parameters<typeof compileErrorOf>[0]>): Effect.Effect<A, HausCompileError | HausConfigError> =>
  r._tag === "Success" ? Effect.succeed(r.success) : Effect.fail(compileErrorOf(r.failure))

/** `fromCore` for steps that can only fail with a compile error (never a configuration mistake). */
const compiling = <A>(r: Result<A, Parameters<typeof compileErrorOf>[0]>): Effect.Effect<A, HausCompileError> =>
  Effect.catchTag(fromCore(r), "HausConfigError", (e) => Effect.die(e))

// ── Sources ──────────────────────────────────────────────────

/**
 * Sources (packages.md §2), as `@haus-fmt/haus` has them:
 *
 * - `Haus.Sources.make(entry, files)`: from plain data (a file, a database,
 *   memory), with the checks of reading except the file system's: each path
 *   relative, without `.` or `..`, at most 256 files of at most 1 MiB, the
 *   entry among them. Fails with a HausCompileError.
 * - `Haus.Sources.withPackage(sources, pkg)` (or `withPackage(pkg)(sources)`):
 *   give a compile a package as a value.
 */
export const Sources = Object.freeze({
  make: (entry: string, files: Readonly<Record<string, string>> | ReadonlyMap<string, string>, options: { readonly id?: string } = {}): Effect.Effect<SourcesValue, HausCompileError> =>
    compiling(CoreSources.make(entry, files, options)),
  withPackage: CoreSources.withPackage,
  is: CoreSources.is,
})

export type { Folder, PackageValue as PackageType, SourcesValue as SourcesType }

// ── Package ──────────────────────────────────────────────────

/**
 * The implementation of a package's rule (packages.md §6), in the form of an
 * Effect Schema filter: `true` (or `undefined`) accepts the value, `false`
 * or a message rejects it. It gets the value as this binding decodes the
 * type without codecs (a variant `{ _tag, values }`, a `Maybe` an `Option`).
 */
export type Rule<A = never> = (value: A) => boolean | string | undefined

/** A rule as the core takes it. */
const coreRule = (type: string, rule: Rule<unknown>) => (value: unknown) => {
  const out = rule(value)
  return out === true || out === undefined ? Result.succeed(value) : Result.fail(out === false ? `rejected by the rule of ${type}` : out)
}

const withRuleOn = (pkg: PackageValue, type: TypeHandle<CoreTypeLambda> | string, rule: Rule<never>): Effect.Effect<PackageValue, HausConfigError> => {
  const name = typeof type === "string" ? type : type.id
  return Effect.mapError(fromCore(CorePackage.withRule(pkg, name, coreRule(name, rule as Rule<unknown>))), (e) => (e._tag === "HausConfigError" ? e : new HausConfigError({ message: e.message })))
}

/** What `Haus.Package.make` takes: a package as plain data, with the implementations of its rules. */
export interface PackageData {
  /** The manifest's text (`package.haus`). */
  readonly manifest: string
  /** The schema's text (`schema.haus`). */
  readonly schema: string
  /** Implementations of the package's rules, by type name. */
  readonly rules?: Readonly<Record<string, Rule<never>>>
  /** The packages its schema imports, for a library's bundle (packages.md §3). */
  readonly dependencies?: readonly PackageValue[]
}

/**
 * Package values (packages.md §3), as `@haus-fmt/haus` has them:
 *
 * - `Haus.Package.make({ manifest, schema, rules?, dependencies? })`: a
 *   package from plain data, checked as a directory's would be except for
 *   files. A bad manifest is a HausCompileError, a rule for a type the
 *   manifest gives none a HausConfigError.
 * - `Haus.Package.shapeOnly(pkg)`: the program takes the package shape-only
 *   (packages.md §7): its rules are not checked, and `missing-codec` is not
 *   reported for them. Official packages too: `Package.shapeOnly(Haus.money)`.
 * - `Haus.Package.withRule(pkg, type, rule)` (or `withRule(type, rule)(pkg)`):
 *   the program implements a rule the package's manifest names.
 */
export const Package = Object.freeze({
  make: (data: PackageData): Effect.Effect<PackageValue, HausCompileError | HausConfigError> =>
    fromCore(CorePackage.make({
      manifest: data.manifest,
      schema: data.schema,
      ...(data.dependencies === undefined ? {} : { dependencies: data.dependencies }),
      ...(data.rules === undefined ? {} : { rules: Object.fromEntries(Object.entries(data.rules).map(([type, rule]) => [type, coreRule(type, rule as Rule<unknown>)])) }),
    })),
  shapeOnly: CorePackage.shapeOnly,
  withRule: ((...args: readonly unknown[]) =>
    CorePackage.is(args[0])
      ? withRuleOn(args[0], args[1] as TypeHandle<CoreTypeLambda> | string, args[2] as Rule<never>)
      : (pkg: PackageValue) => withRuleOn(pkg, args[0] as TypeHandle<CoreTypeLambda> | string, args[1] as Rule<never>)) as {
        <F extends CoreTypeLambda>(type: TypeHandle<F>, rule: Rule<TypeOf<F, {}>>): (pkg: PackageValue) => Effect.Effect<PackageValue, HausConfigError>
        (type: string, rule: Rule<unknown>): (pkg: PackageValue) => Effect.Effect<PackageValue, HausConfigError>
        <F extends CoreTypeLambda>(pkg: PackageValue, type: TypeHandle<F>, rule: Rule<TypeOf<F, {}>>): Effect.Effect<PackageValue, HausConfigError>
        (pkg: PackageValue, type: string, rule: Rule<unknown>): Effect.Effect<PackageValue, HausConfigError>
      },
  is: CorePackage.is,
})

// ── reading ──────────────────────────────────────────────────

/** Options of reading a schema (core §13.3, packages.md §2). */
export interface ReadSourcesOptions {
  /** The build's root, relative to the entry file's directory: relative imports can't go above it. Default: the entry file's directory. */
  readonly root?: string
  /** Package directories given explicitly, relative to the working directory. */
  readonly packages?: readonly string[]
  /** Folders of packages, relative to the working directory: each subdirectory with a `package.haus` is a package. */
  readonly folders?: readonly string[]
}

/**
 * Reading schema files and packages (packages.md §2): the one step of the
 * package layer that touches files. `@haus-fmt/effect/node` provides it for
 * Node (`NodeSchemaFiles.layer`), with the file rules of core §13.3 as
 * `@haus-fmt/haus/node` applies them; a test can provide one that answers
 * from memory (`Haus.Sources.make`).
 */
export class SchemaFiles extends Context.Service<SchemaFiles, {
  /** The entry file at `path`, the files it imports relatively, and the packages and folders given. */
  readonly readSources: (path: string, options?: ReadSourcesOptions) => Effect.Effect<SourcesValue, HausCompileError>
  /** The schema package in the directory `dir`. */
  readonly readPackage: (dir: string) => Effect.Effect<PackageValue, HausCompileError>
  /** The packages of a folder: each subdirectory with a `package.haus`. */
  readonly readPackages: (folder: string) => Effect.Effect<Folder, HausCompileError>
}>()("@haus-fmt/effect/SchemaFiles") {}

/** Read a schema: the entry file, its relative imports, the packages and folders of packages given (core §13.3, packages.md §2). */
export const readSources = Effect.fn("Haus.readSources")(function* (path: string, options: ReadSourcesOptions = {}): Effect.fn.Return<SourcesValue, HausCompileError, SchemaFiles> {
  const files = yield* SchemaFiles
  return yield* files.readSources(path, options)
})

/** Read the schema package in the directory `dir`: a package value, without rules of its own (add them with `Haus.Package.withRule`). */
export const readPackage = Effect.fn("Haus.readPackage")(function* (dir: string): Effect.fn.Return<PackageValue, HausCompileError, SchemaFiles> {
  const files = yield* SchemaFiles
  return yield* files.readPackage(dir)
})

/** Read a folder of packages: its packages, and the subdirectories skipped. */
export const readPackages = Effect.fn("Haus.readPackages")(function* (folder: string): Effect.fn.Return<Folder, HausCompileError, SchemaFiles> {
  const files = yield* SchemaFiles
  return yield* files.readPackages(folder)
})

/** @internal A core read result as this package's. */
export const readResult = compiling

// ── compiling ────────────────────────────────────────────────

/** A compiled schema: the Effect schemas of the entry file's types, with the core's compiled schema they come from. */
export interface CompiledSchema extends CompiledSchemaFile {
  /** The schema `@haus-fmt/haus` compiled: its file, packages and rules. */
  readonly compiled: CompiledCore
  /** The packages the schema reaches, by name: the official ones built in too. */
  readonly packages: ReadonlyMap<string, PackageValue>
  /** The schema file's warnings (`deprecated`, `unknown-attribute`, `no-json-form`). */
  readonly warnings: readonly (SchemaWarning | CodecWarning)[]
}

/**
 * The Effect schemas of a schema `@haus-fmt/haus` compiled
 * (`Schema.compile`): each type of its entry file, every package rule a check
 * of its type, before any codec (packages.md §6).
 */
export const fromSchema = (schema: CompiledCore): CompiledSchema => ({
  ...fromSchemaFile(schema.file, { rules: schema.rules }),
  compiled: schema,
  packages: schema.packages,
  warnings: schema.warnings,
})

/**
 * Compile sources (spec §14, packages.md §7): the entry file and the files
 * it imports, the official packages (built in) and the packages given; then
 * the Effect schemas of its types. Fails with a HausCompileError: a schema
 * file's error at its place, `duplicate-package`, `package-manifest`,
 * `missing-codec` (a rule of a reached type the program doesn't implement:
 * `Haus.Package.withRule`, or take the package `Haus.Package.shapeOnly`).
 * Reads nothing: it needs no service.
 */
export const compile = (sources: SourcesValue): Effect.Effect<CompiledSchema, HausCompileError> =>
  Effect.suspend(() => compiling(CoreSchema.compile(sources))).pipe(Effect.map(fromSchema), Effect.withSpan("Haus.compile"))
