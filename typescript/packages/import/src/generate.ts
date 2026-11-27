/**
 * One generator for every way a `.haus` file is imported, so that the types
 * TypeScript sees and the values the program gets always agree:
 *
 *   typescript.ts  the content mapper: TypeScript declarations (typesFor)
 *   node.ts        the Node loader: JavaScript (moduleFor)
 *   vite.ts        the Vite plugin: JavaScript (moduleFor)
 *
 * The target decides what schemas become:
 *
 *   "plain"   type handles and the compiled `schema` of @haus-fmt/haus; no other dependencies
 *   "effect"  Effect schemas from @haus-fmt/effect
 *
 * Data files without a schema are plain values in both targets; data files
 * with a schema are decoded with it.
 *
 * Packages are never looked for (packages.md §2): the official packages are
 * built in, and every other comes from the options, as directories
 * (`packages`, `folders`) or as the bundles of libraries the project
 * depends on (`bundles`: module specifiers, imported as the program imports
 * them).
 */
import { readSourcesSync, isSchemaFile, type ReadSourcesOptions } from "@haus-fmt/haus/node"
import { Package, parseSchemaFile, Result, Schema, schemaDeclarations, Sources, type HausError, type Package as PackageValue, type Sources as SourcesValue } from "@haus-fmt/haus/internal"
import { plainDeclarations, parsePlain } from "@haus-fmt/haus/internal"
import { existsSync, realpathSync } from "node:fs"
import { createRequire } from "node:module"
import { join, resolve } from "node:path"
import { pathToFileURL } from "node:url"
import { dataModule, dataModuleSource, schemaFor, schemaModuleSource, specifier, type Diagnostic } from "./schemas.js"

export type Target = "plain" | "effect"

export interface ImportOptions {
  /** What `.haus` imports become. Default "plain". */
  readonly target?: Target
  /**
   * Schema packages given explicitly (packages.md §2), relative to the
   * project root: each a package directory with `package.haus` and
   * `schema.haus`.
   */
  readonly packages?: readonly string[]
  /** Folders of packages, relative to the project root: each direct subdirectory with a `package.haus` is a package. */
  readonly folders?: readonly string[]
  /**
   * Libraries that publish a schema package as a bundle (packages.md §3),
   * by module specifier, imported as the program imports them: their default
   * export is the package value (`"@acme/orders"`), or a named export after
   * `#` (`"@acme/orders#orders"`). Their rules come with them.
   */
  readonly bundles?: readonly string[]
  /**
   * The root directory of schema builds, relative to the project root (spec
   * §13.3, "The root"): relative imports of a schema file can't reach a file
   * outside it. Default: the directory of each schema file.
   */
  readonly root?: string
  /**
   * Plain target, Node loader and Vite plugin: types to build generated code
   * for, by schema file (relative to the project root), e.g.
   * `{ "src/github.schema.haus": ["Issue"] }`.
   */
  readonly optimize?: Readonly<Record<string, readonly string[]>>
}

/** `optimize` as given: each schema file (`key` as written, `path` absolute) and its types. */
export type OptimizeOption = readonly { readonly key: string; readonly path: string; readonly types: readonly string[] }[]

/** Where a build's packages come from: directories, folders and bundles, and the build's root. */
export interface PackageOptions {
  readonly packages: readonly string[]
  readonly folders: readonly string[]
  readonly bundles: readonly string[]
  readonly root?: string
  /** The project root: bundles are imported from it. */
  readonly project: string
}

export type { Diagnostic }

const paths = (value: unknown, what: string): readonly string[] => {
  if (value === undefined) return []
  if (Array.isArray(value) && value.every((p) => typeof p === "string")) return value as readonly string[]
  throw new Error(`@haus-fmt/import: ${what} must be a list of ${what === "bundles" ? "module specifiers" : "paths"}, found ${JSON.stringify(value)}`)
}

/**
 * The package options of `options`: `packages` and `folders` made absolute
 * against `root` (the project root: Vite's root, the tsconfig.json's
 * directory, or the working directory).
 */
export const packagesOf = (options: { readonly packages?: unknown; readonly folders?: unknown; readonly bundles?: unknown; readonly root?: unknown; readonly npm?: unknown } | undefined, root: string): PackageOptions => {
  if (options?.npm !== undefined) throw new Error(`@haus-fmt/import: the npm option is gone: no package is looked for in node_modules any more. Give a library's bundle (bundles) or a package's directory (packages)`)
  const buildRoot = options?.root
  if (buildRoot !== undefined && typeof buildRoot !== "string") throw new Error(`@haus-fmt/import: root must be a path, found ${JSON.stringify(buildRoot)}`)
  return {
    packages: paths(options?.packages, "packages").map((p) => resolve(root, p)),
    folders: paths(options?.folders, "folders").map((f) => resolve(root, f)),
    bundles: paths(options?.bundles, "bundles"),
    ...(buildRoot === undefined ? {} : { root: resolve(root, buildRoot) }),
    project: root,
  }
}

/** The `optimize` option, its paths made absolute against `root`. Its shape is checked; the files and types by `backend`. */
export const optimizeOf = (options: { readonly optimize?: unknown } | undefined, root: string): OptimizeOption => {
  const o = options?.optimize
  if (o === undefined) return []
  const types = (t: unknown) => Array.isArray(t) && t.every((n) => typeof n === "string")
  if (typeof o !== "object" || o === null || Array.isArray(o) || !Object.values(o).every(types)) {
    throw new Error(`@haus-fmt/import: optimize must map schema files to lists of type names, e.g. { "src/github.schema.haus": ["Issue"] }, found ${JSON.stringify(o)}`)
  }
  return Object.entries(o as Record<string, readonly string[]>).map(([key, types]) => ({ key, path: resolve(root, key), types }))
}

export const targetOf = (options: { readonly target?: unknown } | undefined): Target => {
  const t = options?.target ?? "plain"
  if (t !== "plain" && t !== "effect") throw new Error(`@haus-fmt/import: target must be "plain" or "effect", found ${JSON.stringify(t)}`)
  return t
}

/** A thrown Error for a failed Result of the core. */
export const unwrap = <A>(r: Result<A, HausError>): A => {
  if (r._tag === "Failure") throw r.failure
  return r.success
}

/** A bundle: its specifier, and the package value its module exports. */
export interface Bundle {
  readonly specifier: string
  readonly module: string
  readonly name: string
  readonly package: PackageValue
}

/** Import the bundles, from the project root, as the program imports them. */
const importBundles = async (options: PackageOptions): Promise<readonly Bundle[]> => {
  const require = createRequire(join(options.project, "package.json"))
  return Promise.all(options.bundles.map(async (specifier) => {
    const [module = specifier, name = "default"] = specifier.split("#")
    let path: string
    try {
      path = require.resolve(module)
    } catch {
      throw new Error(`@haus-fmt/import: the bundle ${module} can't be imported from ${options.project}: add the library to the project's dependencies`)
    }
    const exported = ((await import(pathToFileURL(path).href)) as Record<string, unknown>)[name]
    if (!Package.is(exported)) throw new Error(`@haus-fmt/import: ${specifier} exports no package value (Package) as ${name === "default" ? "its default export" : name}`)
    return { specifier, module, name, package: exported }
  }))
}

/** The read options of a schema file: the directories and folders given, the build's root. */
const readOptions = (options: PackageOptions): ReadSourcesOptions => ({
  packages: options.packages,
  folders: options.folders,
  ...(options.root === undefined ? {} : { root: options.root }),
})

/** What differs between the targets. */
export interface Backend {
  readonly target: Target
  /** Declarations for a schema file (`.schema.haus`, a package's `schema.haus`): its types and their handles. */
  readonly schemaTypes: (fileName: string) => string
  /** The runtime generated modules import (runtime/plain.ts or runtime/effect.ts), as `@haus-fmt/import/runtime/<target>`. */
  readonly runtime: string
  /** Where schema packages come from. */
  readonly packages: PackageOptions
  /** The bundles, imported. */
  readonly bundles: readonly Bundle[]
  /** The sources of a schema file, read now, with the bundles given (throws a HausError). */
  readonly sources: (fileName: string) => SourcesValue
  /** The types to build generated code for, by the real path of their schema file (plain target). */
  readonly optimize: ReadonlyMap<string, readonly string[]>
}

/**
 * The backend for a target. Packages, folders and bundles that don't exist,
 * and schema files or types of `optimize` that don't, are reported now. The
 * Effect backend is loaded only when a project asks for it.
 */
export async function backend(target: Target, packages: PackageOptions = packagesOf({}, process.cwd()), optimize: OptimizeOption = []): Promise<Backend> {
  const bundles = await importBundles(packages)
  for (const dir of [...packages.packages, ...packages.folders]) {
    if (!existsSync(dir)) throw new Error(`@haus-fmt/import: ${dir} doesn't exist`)
  }
  const sources = (fileName: string): SourcesValue =>
    bundles.reduce((s, b) => Sources.withPackage(s, b.package), unwrap(readSourcesSync(fileName, readOptions(packages))))
  const compiled = (fileName: string) => unwrap(Schema.compile(sources(fileName)))
  if (target === "plain") {
    return {
      target,
      schemaTypes: (fileName) =>
        schemaDeclarations(compiled(fileName).file, { haus: specifier(fileName, "@haus-fmt/haus") }) +
        `/** The compiled schema of this file, for \`Schema.decode(schema, Type)\`. */\nexport declare const schema: import(${JSON.stringify(specifier(fileName, "@haus-fmt/haus"))}).Schema;\n`,
      runtime: "runtime/plain",
      packages,
      bundles,
      sources,
      optimize: optimizedTypes(optimize, compiled),
    }
  }
  if (optimize.length > 0) throw new Error(`@haus-fmt/import: optimize is for the plain target: Effect schemas don't use generated code`)
  const { effectSchemaTypes } = await import("./effect.js")
  return { target, schemaTypes: (fileName) => effectSchemaTypes(compiled(fileName).file, fileName), runtime: "runtime/effect", packages, bundles, sources, optimize: new Map() }
}

/** The types to build code for, by the real path of their schema file: every file a schema file, every type one of its types without parameters. */
const optimizedTypes = (optimize: OptimizeOption, compiled: (fileName: string) => Schema): ReadonlyMap<string, readonly string[]> => {
  const byFile = new Map<string, string[]>()
  for (const { key, path, types } of optimize) {
    if (!existsSync(path)) throw new Error(`@haus-fmt/import: optimize: the schema file ${key} doesn't exist (${path})`)
    if (!isSchemaFile(path)) throw new Error(`@haus-fmt/import: optimize: ${key} is not a schema file (.schema.haus)`)
    const definitions = compiled(path).file.definitions
    for (const t of types) {
      const d = definitions.find((d) => d.name === t)
      if (d === undefined) throw new Error(`@haus-fmt/import: optimize: ${key} has no type ${t}`)
      if (d.params.length > 0) throw new Error(`@haus-fmt/import: optimize: ${key}: ${t} has type parameters (list the types that use it instead)`)
    }
    const real = realpathSync(path)
    byFile.set(real, [...new Set([...(byFile.get(real) ?? []), ...types])])
  }
  return byFile
}

/** TypeScript declarations for an imported `.haus` file, with diagnostics for the file. */
export function typesFor(text: string, fileName: string, b: Backend): { text: string; diagnostics: Diagnostic[] } {
  if (isSchemaFile(fileName)) return { text: b.schemaTypes(fileName), diagnostics: [] }
  const link = schemaFor(fileName)
  if (link) return dataModule(text, fileName, link, b)
  return { text: plainDeclarations(text, fileName), diagnostics: [] }
}

/**
 * JavaScript for an imported `.haus` file, and the files it was built from
 * (to watch). `importRuntime` turns `runtime/<target>` into the specifier the
 * module imports it by.
 */
export function moduleFor(text: string, fileName: string, b: Backend, importRuntime: (path: string) => string): { code: string; files: string[] } {
  const runtime = importRuntime(b.runtime)
  if (isSchemaFile(fileName)) return schemaModuleSource(fileName, runtime, b, b.optimize.size === 0 ? [] : (b.optimize.get(realpathSync(fileName)) ?? []))
  const link = schemaFor(fileName)
  if (link) return dataModuleSource(text, fileName, link, runtime, b)
  return { code: `export default ${js(parsePlain(text))};\n`, files: [] }
}

/** A plain value as a JavaScript expression. */
function js(x: unknown): string {
  if (x === null) return "null"
  if (typeof x === "bigint") return `${x}n`
  if (x instanceof Uint8Array) return `new Uint8Array([${x.join(",")}])`
  if (Array.isArray(x)) return `[${x.map(js).join(",")}]`
  if (typeof x === "object") {
    return `{${Object.entries(x as Record<string, unknown>).map(([k, v]) => `${k === "__proto__" ? '["__proto__"]' : JSON.stringify(k)}:${js(v)}`).join(",")}}`
  }
  return JSON.stringify(x)
}

export { parseSchemaFile }
