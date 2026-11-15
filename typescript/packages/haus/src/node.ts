/// <reference types="node" />
/**
 * Resolving schema imports from the file system (Node):
 *
 *   import @haus-fmt/money (Money)    → node_modules/@haus-fmt/money/package.haus and schema.haus next to it
 *   import ./common (Address)         → ./common.schema.haus, next to the importing file
 *
 *   const file = parseSchemaFile(text, schemaOptions(path))
 *
 * A schema package is a directory with a manifest, `package.haus`, and one
 * schema file, `schema.haus` (spec §13.3):
 *
 *   { name: "@haus-fmt/money", version: "1.2.0" }
 *
 * The manifest gives types their identity in every language
 * (`@haus-fmt/money@1#Money`), independent of how a package manager names the
 * package. A package's schema imports other packages by name, never files.
 * Files outside a schema package are identified by the nearest package.json
 * name and their path (`my-app/src/order#Root`); their relative imports can't
 * reach into a package directory.
 */
import { existsSync, readFileSync, realpathSync } from "node:fs"
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path"
import { parse } from "./index.js"
import { ModuleError, type ModuleResolver, type ParseSchemaOptions, type ResolvedModule } from "./schema-file.js"

/** A schema package's manifest. */
export const MANIFEST = "package.haus"
/** A schema package's schema file, next to its manifest. */
export const PACKAGE_SCHEMA = "schema.haus"
const EXTENSION = ".schema.haus"

export interface Manifest {
  readonly name: string
  readonly version: string
  /** The package directory, with the manifest and `schema.haus`. */
  readonly dir: string
}

/** A schema file: `*.schema.haus`, or a package's `schema.haus`. */
export const isSchemaFile = (path: string): boolean => path.endsWith(EXTENSION) || basename(path) === PACKAGE_SCHEMA

const manifests = new Map<string, Manifest | undefined>()

/** `path` is `root` or inside it (both absolute). */
const inside = (root: string, path: string): boolean => {
  const rel = relative(root, path)
  return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel))
}

/**
 * A file read for a package stays inside it (spec §13.3): `path` (in the
 * package directory `root`) is still inside it after resolving symbolic links.
 * Checked before the file is read.
 */
const checkInside = (root: string, path: string, what: () => string): void => {
  if (existsSync(path) && !inside(realpathSync(root), realpathSync(path))) {
    throw new ModuleError("package-path", `${what()} is a symbolic link to a file outside the package ${root}`)
  }
}

/** Read a schema package manifest (cached). Fields other than `name` and `version` are ignored. */
export function readManifest(path: string): Manifest {
  const cached = manifests.get(path)
  if (cached) return cached
  checkInside(dirname(resolve(path)), resolve(path), () => `the manifest ${path}`)
  const value = parse(readFileSync(path, "utf8"))
  const field = (key: string): string => {
    const f = value.kind === "record" ? value.fields.get(key) : undefined
    if (f?.kind !== "string") throw new Error(`${path}: the manifest needs a string field ${key}`)
    return f.value
  }
  const manifest = { name: field("name"), version: field("version"), dir: dirname(path) }
  if (!/^@[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(manifest.name)) throw new Error(`${path}: name must look like @org/name, found ${manifest.name}`)
  if (!/^\d+\.\d+\.\d+/.test(manifest.version)) throw new Error(`${path}: version must be semver (1.2.0), found ${manifest.version}`)
  manifests.set(path, manifest)
  return manifest
}

/** The manifest of the package whose schema is the file at `path` (absolute), if it is one. */
const packageOf = (path: string): Manifest | undefined => {
  const m = join(dirname(path), MANIFEST)
  return basename(path) === PACKAGE_SCHEMA && existsSync(m) ? readManifest(m) : undefined
}

/** The package directory a file is in, if any: the nearest directory above it with a manifest. */
const packageDirOf = (path: string): string | undefined => {
  for (const dir of ancestors(dirname(path))) if (existsSync(join(dir, MANIFEST))) return dir
  return undefined
}

/** The name of the package in `dir`, or the directory if its manifest can't be read. */
const packageName = (dir: string): string => {
  try {
    return readManifest(join(dir, MANIFEST)).name
  } catch {
    return dir
  }
}

const ancestors = function* (dir: string): Generator<string> {
  for (let d = dir; ; d = dirname(d)) {
    yield d
    if (dirname(d) === d) return
  }
}

const stem = (path: string) => path.replaceAll(sep, "/").replace(/\.schema\.haus$/, "")

/** The identity of a schema file (ResolvedModule.id). */
export function identify(path: string): string {
  const file = resolve(path)
  const manifest = packageOf(file)
  if (manifest) return `${manifest.name}@${manifest.version.split(".")[0]}`
  for (const dir of ancestors(dirname(file))) {
    const pkg = join(dir, "package.json")
    if (existsSync(pkg)) {
      const name = (JSON.parse(readFileSync(pkg, "utf8")) as { name?: string }).name
      if (name) return `${name}/${stem(relative(dir, file))}`
    }
  }
  // Outside any package: just the file name (put a package.json above it for a unique id).
  return stem(basename(file))
}

const read = (path: string): ResolvedModule => {
  const key = resolve(path)
  const version = packageOf(key)?.version
  return { key, id: identify(key), text: readFileSync(key, "utf8"), ...(version ? { version } : {}) }
}

export interface NodeResolverOptions {
  /** Where relative imports of the root file resolve from, if it has no key (default: the working directory). */
  readonly base?: string
  /** Package directories by name, looked up before node_modules: `{ "@haus-fmt/money": "../extensions/money" }`. */
  readonly packages?: Readonly<Record<string, string>>
}

/** Finds packages in node_modules (upwards from the importing file) and relative files. */
export function nodeResolver(options: NodeResolverOptions = {}): ModuleResolver {
  const base = options.base ?? process.cwd()
  return {
    resolve(module, from) {
      const dir = from ? dirname(from) : base
      if (module.startsWith("./") || module.startsWith("../")) {
        // A package is one file: its schema imports other packages by name (spec §13.3).
        const pkg = from === undefined ? undefined : (packageDirOf(resolve(from)) ?? (existsSync(from) ? packageDirOf(realpathSync(from)) : undefined))
        if (pkg !== undefined) throw new ModuleError("package-path", `the schema of ${packageName(pkg)} can't import files, only packages by name`)
        const path = resolve(dir, module + EXTENSION)
        // An application's file doesn't reach into a package: it imports the package by name.
        const into = packageDirOf(path) ?? (existsSync(path) ? packageDirOf(realpathSync(path)) : undefined)
        if (into !== undefined) throw new ModuleError("package-path", `the file is in the package directory ${into}: import the package by its name`)
        if (!existsSync(path)) throw new Error(`file not found: ${path}`)
        return read(path)
      }
      const direct = options.packages?.[module]
      const candidates = direct !== undefined ? [join(resolve(base, direct), MANIFEST)] : []
      for (const d of ancestors(dir)) candidates.push(join(d, "node_modules", ...module.split("/"), MANIFEST))
      for (const m of candidates) {
        if (existsSync(m)) {
          const manifest = readManifest(m)
          if (manifest.name !== module) throw new Error(`${m} names the package ${manifest.name}, not ${module}`)
          const schema = join(manifest.dir, PACKAGE_SCHEMA)
          if (!existsSync(schema)) throw new Error(`${manifest.name} has no ${PACKAGE_SCHEMA} next to its manifest (${manifest.dir})`)
          checkInside(manifest.dir, schema, () => `${manifest.name}: its ${PACKAGE_SCHEMA}`)
          return read(schema)
        }
      }
      throw new Error(`package not found (no node_modules/${module}/${MANIFEST} above ${dir})`)
    },
  }
}

/** Options for parseSchemaFile for the schema file at `path`: its key, identity and a Node resolver. */
export function schemaOptions(path: string, options: NodeResolverOptions = {}): ParseSchemaOptions {
  const key = resolve(path)
  return { key, id: identify(key), resolver: nodeResolver({ base: dirname(key), ...options }) }
}
