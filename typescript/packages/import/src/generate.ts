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
 *   "plain"   haus schemas (Standard Schemas) from @haus-fmt/haus; no other dependencies
 *   "effect"  Effect schemas from @haus-fmt/effect
 *
 * Data files without a schema are plain values in both targets; data files
 * with a schema are decoded with it.
 */
import { parseSchemaFile, schemaDeclarations } from "@haus-fmt/haus"
import { existsSync, readFileSync, realpathSync } from "node:fs"
import { resolve } from "node:path"
import { isSchemaFile, nodeResolver, schemaOptions, type NodeResolverOptions } from "@haus-fmt/haus/node"
import { parsePlain, plainDeclarations } from "@haus-fmt/haus/plain"
import { dataModule, dataModuleSource, schemaFor, schemaModuleSource, specifier, type Diagnostic } from "./schemas.js"

export type Target = "plain" | "effect"

export interface ImportOptions {
  /** What `.haus` imports become. Default "plain". */
  readonly target?: Target
  /**
   * Schema packages given explicitly (spec §13.3), relative to the project
   * root: each a package directory with `package.haus` and `schema.haus`.
   * Used instead of an installed package with the same name.
   */
  readonly packages?: readonly string[]
  /**
   * Folders of packages, relative to the project root: each direct
   * subdirectory with a `package.haus` is a package. One that is also
   * installed in node_modules must have the same files.
   */
  readonly folders?: readonly string[]
  /** Look for packages in node_modules too (default true). With `false`, only `packages` and `folders`. */
  readonly npm?: boolean
  /**
   * Plain target, Node loader and Vite plugin: types to build generated code
   * for, by schema file (relative to the project root), e.g.
   * `{ "src/github.schema.haus": ["Issue"] }`. The module of that file gets
   * the code for these types and the types they reach, and marks these types
   * as `h.optimize` does: they use it without `eval`. (`h.optimize` on a type
   * they reach uses it too.) Without it, modules carry no generated code.
   */
  readonly optimize?: Readonly<Record<string, readonly string[]>>
}

/** `optimize` as given: each schema file (`key` as written, `path` absolute) and its types. */
export type OptimizeOption = readonly { readonly key: string; readonly path: string; readonly types: readonly string[] }[]

export type { Diagnostic }

const paths = (value: unknown, what: string): readonly string[] => {
  if (value === undefined) return []
  if (Array.isArray(value) && value.every((p) => typeof p === "string")) return value as readonly string[]
  throw new Error(`@haus-fmt/import: ${what} must be a list of paths, found ${JSON.stringify(value)}`)
}

/**
 * The resolver options of `options`: `packages` and `folders` made absolute
 * against `root` (the project root: Vite's root, the tsconfig.json's
 * directory, or the working directory).
 */
export const packagesOf = (options: { readonly packages?: unknown; readonly folders?: unknown; readonly npm?: unknown } | undefined, root: string): NodeResolverOptions => {
  const npm = options?.npm ?? true
  if (typeof npm !== "boolean") throw new Error(`@haus-fmt/import: npm must be true or false, found ${JSON.stringify(npm)}`)
  return {
    packages: paths(options?.packages, "packages").map((p) => resolve(root, p)),
    folders: paths(options?.folders, "folders").map((f) => resolve(root, f)),
    npm,
  }
}

/** The `optimize` option, its paths made absolute against `root` (the project root: Vite's root or the working directory). Its shape is checked; the files and types by `backend`. */
export const optimizeOf = (options: { readonly optimize?: unknown } | undefined, root: string): OptimizeOption => {
  const o = options?.optimize
  if (o === undefined) return []
  const types = (t: unknown) => Array.isArray(t) && t.every((n) => typeof n === "string")
  if (typeof o !== "object" || o === null || Array.isArray(o) || !Object.values(o).every(types)) {
    throw new Error(`@haus-fmt/import: optimize must map schema files to lists of type names, e.g. { "src/github.schema.haus": ["Issue"] }, found ${JSON.stringify(o)}`)
  }
  return Object.entries(o as Record<string, readonly string[]>).map(([key, types]) => ({ key, path: resolve(root, key), types }))
}

/**
 * The types to build code for, by the real path of their schema file:
 * every file must exist and be a schema file, every type one of its types
 * without parameters.
 */
const optimizedTypes = (optimize: OptimizeOption, packages: NodeResolverOptions): ReadonlyMap<string, readonly string[]> => {
  const byFile = new Map<string, string[]>()
  for (const { key, path, types } of optimize) {
    if (!existsSync(path)) throw new Error(`@haus-fmt/import: optimize: the schema file ${key} doesn't exist (${path})`)
    if (!isSchemaFile(path)) throw new Error(`@haus-fmt/import: optimize: ${key} is not a schema file (.schema.haus)`)
    const definitions = parseSchemaFile(readFileSync(path, "utf8"), schemaOptions(path, packages)).definitions
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

export const targetOf = (options: { readonly target?: unknown } | undefined): Target => {
  const t = options?.target ?? "plain"
  if (t !== "plain" && t !== "effect") throw new Error(`@haus-fmt/import: target must be "plain" or "effect", found ${JSON.stringify(t)}`)
  return t
}

/** What differs between the targets. */
export interface Backend {
  readonly target: Target
  /** Declarations for a schema file (`.schema.haus`, a package's `schema.haus`): its types and schemas. */
  readonly schemaTypes: (text: string, fileName: string) => string
  /** The runtime generated modules import (runtime/plain.ts or runtime/effect.ts), as `@haus-fmt/import/runtime/<target>`. */
  readonly runtime: string
  /** Where schema packages are found (packagesOf). */
  readonly packages: NodeResolverOptions
  /** The types to build generated code for, by the real path of their schema file (plain target). */
  readonly optimize: ReadonlyMap<string, readonly string[]>
}

/**
 * The backend for a target, finding schema packages with `packages`
 * (packagesOf; default: node_modules only), building generated code for the
 * types of `optimize` (optimizeOf; plain target). Packages or folders that
 * don't exist, and schema files or types of `optimize` that don't, are
 * reported now. The Effect backend is loaded only when a project asks for
 * it, so plain projects need no Effect.
 */
export async function backend(target: Target, packages: NodeResolverOptions = {}, optimize: OptimizeOption = []): Promise<Backend> {
  nodeResolver(packages)
  if (target === "plain") {
    return {
      target,
      schemaTypes: (text, fileName) =>
        schemaDeclarations(parseSchemaFile(text, schemaOptions(fileName, packages)), { haus: specifier(fileName, "@haus-fmt/haus/schema") }),
      runtime: "runtime/plain",
      packages,
      optimize: optimizedTypes(optimize, packages),
    }
  }
  if (optimize.length > 0) throw new Error(`@haus-fmt/import: optimize is for the plain target: Effect schemas don't use generated code`)
  const { effectSchemaTypes } = await import("./effect.js")
  return { target, schemaTypes: (text, fileName) => effectSchemaTypes(text, fileName, packages), runtime: "runtime/effect", packages, optimize: new Map() }
}

/** TypeScript declarations for an imported `.haus` file, with diagnostics for the file. */
export function typesFor(text: string, fileName: string, b: Backend): { text: string; diagnostics: Diagnostic[] } {
  if (isSchemaFile(fileName)) return { text: b.schemaTypes(text, fileName), diagnostics: [] }
  const link = schemaFor(fileName)
  if (link) return dataModule(text, fileName, link, b.packages)
  return { text: plainDeclarations(text, fileName), diagnostics: [] }
}

/**
 * JavaScript for an imported `.haus` file, and the files it was built from
 * (to watch). `importRuntime` turns `runtime/<target>` into the specifier the
 * module imports it by.
 */
export function moduleFor(text: string, fileName: string, b: Backend, importRuntime: (path: string) => string): { code: string; files: string[] } {
  const runtime = importRuntime(b.runtime)
  if (isSchemaFile(fileName)) return schemaModuleSource(fileName, runtime, b.packages, b.optimize.size === 0 ? [] : (b.optimize.get(realpathSync(fileName)) ?? []))
  const link = schemaFor(fileName)
  if (link) return dataModuleSource(text, fileName, link, runtime, b.packages)
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
