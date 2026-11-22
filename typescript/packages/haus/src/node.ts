/// <reference types="node" />
/**
 * Resolving schema imports from the file system (Node):
 *
 *   import @haus-fmt/money (Money)    → node_modules/@haus-fmt/money/package.haus and schema.haus next to it
 *   import ./common (Address)         → ./common.schema.haus, next to the importing file
 *
 *   const file = parseSchemaFile(text, schemaOptions(path))
 *   const file = parseSchemaFile(text, schemaOptions(path, { packages: ["../vendor/money"], folders: ["../schemas"] }))
 *   const file = parseSchemaFile(text, schemaOptions(path, { folders: ["../schemas"], npm: false }))
 *
 * A schema package is a directory with a manifest, `package.haus`, and one
 * schema file, `schema.haus` (spec §13.3):
 *
 *   { name: "@haus-fmt/money", version: "1.2.0" }
 *
 * The manifest gives types their identity in every language
 * (`@haus-fmt/money@1#Money`), independent of how a package manager names the
 * package. A package's schema imports other packages by name, never files.
 *
 * Where packages are found (spec §13.3), and nowhere else (never `NODE_PATH`,
 * global folders or the network):
 *
 * - Packages given by their directory (`packages`) are used for their names,
 *   instead of any installed one.
 * - Packages found in a folder of packages (`folders`) are used too, but don't
 *   replace an installed package: if the importer's node_modules has a package
 *   with that name and other files, the schema has two packages with one name.
 * - With `npm` (the default), `@org/name` is looked up as Node does: in
 *   `node_modules/@org/name` of each directory above the importing file's real
 *   path (symbolic links resolved, so pnpm's layout and workspace links work),
 *   skipping directories named `node_modules`, scope directories inside one,
 *   Windows drive roots and directories everyone may write to (`/tmp`). The
 *   first `node_modules/@org/name` that exists is the package.
 * - Before it looks, a file must declare what it imports: a package's
 *   `schema.haus` in the package's own package.json (`dependencies`,
 *   `peerDependencies`, `optionalDependencies`), other files in the nearest
 *   package.json above their real path that has a `name` or a dependency field
 *   (`devDependencies` count too); one that isn't valid JSON or isn't a
 *   regular file ends the search and declares nothing, one that is valid JSON
 *   but not an object is skipped. Given packages always count as declared.
 * - When the package's directory has a package.json with a `version` that is
 *   a string, it must be the manifest's.
 *
 * A package's `package.haus`, `schema.haus` and `package.json` must be regular
 * files, never links (the package directory may be one). They are opened
 * without following links, checked on the open handle (type, size) and read
 * from it. A relative import reads a file whose real path ends in
 * `.schema.haus` and whose path is spelled as its directories list it.
 *
 * Files are known by their real path (ResolvedModule.key): two imports reach
 * the same file when its real path is the same. Files outside a schema
 * package are identified by the nearest package.json name and their path
 * (`my-app/src/order#Root`), or without one by their path from the resolver's
 * `base`; their relative imports can't reach into a package directory.
 *
 * A resolver reads each file at most once, by its real path, also when one
 * file is needed in two roles (a project's package.json that is a link to a
 * schema file): every use sees the same bytes (spec §13.3). The checks of each
 * role (a regular file, not a link, its size) still apply to each use. Make
 * one resolver per schema (schemaOptions does), so a long-running process
 * such as a language server sees a reinstalled package.
 */
import { closeSync, constants, existsSync, fstatSync, lstatSync, openSync, readdirSync, readSync, realpathSync, statSync, type BigIntStats } from "node:fs"
import { basename, dirname, join, relative, resolve, sep } from "node:path"
import { HausSyntaxError } from "./errors.js"
import { parseAll } from "./index.js"
import { isPackageName, ModuleError, quoteText, type ModuleResolver, type ParseSchemaOptions, type ResolvedModule } from "./schema-file.js"

/** A schema package's manifest. */
export const MANIFEST = "package.haus"
/** A schema package's schema file, next to its manifest. */
export const PACKAGE_SCHEMA = "schema.haus"
/** The largest manifest read, in bytes (spec §13.3). */
export const MAX_MANIFEST_BYTES = 64 * 1024
/** The largest schema file read, in bytes (spec §13.3). */
export const MAX_SCHEMA_BYTES = 1024 * 1024
/** The largest package.json read, in bytes (spec §13.3). */
export const MAX_PACKAGE_JSON_BYTES = 1024 * 1024
/** The most entries a folder of packages may have (spec §13.3). */
export const MAX_FOLDER_ENTRIES = 4096
const EXTENSION = ".schema.haus"
const MAX_NAME = 214
/** A semantic version (SemVer 2.0), with pre-release and build. ASCII digits only (`\d` without the u flag). */
const SEMVER = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/

export interface Manifest {
  readonly name: string
  readonly version: string
  /** The package directory (its real path), with the manifest and `schema.haus`. */
  readonly dir: string
  /** The manifest's text: copies of a package are one when it and `schema.haus` are the same. */
  readonly text: string
}

/** A schema file: `*.schema.haus`, or a package's `schema.haus`. */
export const isSchemaFile = (path: string): boolean => path.endsWith(EXTENSION) || basename(path) === PACKAGE_SCHEMA

/** A path in a message: escaped (control and bidirectional characters), never cut. */
const shown = (path: string): string => quoteText(path, Infinity)

// ── reading files: regular files, checked on the open handle ──

type Read =
  | { readonly kind: "missing" }
  | { readonly kind: "link" }
  | { readonly kind: "special" }
  | { readonly kind: "large"; readonly size: bigint }
  | { readonly kind: "file"; readonly text: string }

const NOFOLLOW: number | undefined = constants.O_NOFOLLOW
const NONBLOCK: number = constants.O_NONBLOCK ?? 0
/** The most bytes read from any file: the largest limit, so one read serves every role (spec §13.3). */
const MAX_READ = Math.max(MAX_MANIFEST_BYTES, MAX_SCHEMA_BYTES, MAX_PACKAGE_JSON_BYTES)

/** A file opened: not a regular file, or one with its size and, unless it is larger than MAX_READ, its text. */
type Opened =
  | { readonly kind: "special" }
  | { readonly kind: "file"; readonly size: bigint; readonly text: string | undefined }

/**
 * Reads files for one schema (a resolver): `read(path, limit, follow)` reads
 * `path` if it is a regular file of at most `limit` bytes. Unless `follow`, a
 * symbolic link at its last component is not followed (and not read): `link`.
 * Each file is opened at most once, by its real path, whatever roles it has
 * (spec §13.3); each use checks its own limit.
 */
type Reader = (path: string, limit: number, follow?: boolean) => Read

const errno = (e: unknown): string | undefined => (e as NodeJS.ErrnoException | undefined)?.code
const isMissing = (e: unknown): boolean => errno(e) === "ENOENT" || errno(e) === "ENOTDIR"

/** The text of a file read: UTF-8, as every haus file (spec §1). */
const utf8 = (bytes: Uint8Array, path: string): string => {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes)
  } catch {
    throw new ModuleError("invalid-utf8", `${shown(path)} is not UTF-8 text`)
  }
}

/**
 * Open the file at `path`, whose last component must not be a link, and read
 * it. It is opened without following links (O_NOFOLLOW) and without blocking
 * (O_NONBLOCK, so a FIFO can't stall the open); the type and size are checked
 * on the open handle, and the text read from it, so the file checked is the
 * file read. Where O_NOFOLLOW doesn't exist (Windows), the path is checked
 * with lstat first and the handle must be the same file.
 */
const openRegular = (path: string): Opened | { readonly kind: "missing" } | { readonly kind: "link" } => {
  let before: BigIntStats | undefined
  if (NOFOLLOW === undefined) {
    try {
      before = lstatSync(path, { bigint: true })
    } catch (e) {
      if (isMissing(e)) return { kind: "missing" }
      throw e
    }
    if (before.isSymbolicLink()) return { kind: "link" }
    if (!before.isFile()) return { kind: "special" }
  }
  let fd: number
  try {
    fd = openSync(path, constants.O_RDONLY | (NOFOLLOW ?? 0) | NONBLOCK)
  } catch (e) {
    const code = errno(e)
    if (isMissing(e)) return { kind: "missing" }
    // O_NOFOLLOW on a link: ELOOP (Linux, macOS), EMLINK (FreeBSD), EFTYPE (NetBSD).
    if (code === "ELOOP" || code === "EMLINK" || code === "EFTYPE") return { kind: "link" }
    if (code === "EISDIR" || code === "ENXIO" || code === "EACCES" || code === "EPERM") return { kind: "special" }
    throw e
  }
  try {
    const stats = fstatSync(fd, { bigint: true })
    if (before !== undefined && (stats.ino !== before.ino || stats.dev !== before.dev)) return { kind: "link" }
    if (!stats.isFile()) return { kind: "special" }
    if (stats.size > BigInt(MAX_READ)) return { kind: "file", size: stats.size, text: undefined }
    // Read from the handle, never more than MAX_READ (the file may grow meanwhile).
    const chunks: Buffer[] = []
    let total = 0
    for (;;) {
      const chunk = Buffer.alloc(64 * 1024)
      const n = readSync(fd, chunk, 0, chunk.length, null)
      if (n === 0) break
      total += n
      if (total > MAX_READ) return { kind: "file", size: BigInt(total), text: undefined }
      chunks.push(chunk.subarray(0, n))
    }
    return { kind: "file", size: BigInt(total), text: utf8(Buffer.concat(chunks), path) }
  } finally {
    closeSync(fd)
  }
}

/**
 * A Reader with its own files, by real path: what one schema reads.
 * `onOpen` is called with the real path of each file opened.
 */
const reader = (onOpen?: (path: string) => void): Reader => {
  const files = new Map<string, Opened>()
  return (path, limit, follow = false) => {
    // The real path: the file's own (follow), or its directory's and its name, a link not followed.
    let key: string
    try {
      key = follow ? realpathSync(path) : join(realpathSync(dirname(resolve(path))), basename(path))
    } catch (e) {
      if (isMissing(e)) return { kind: "missing" }
      throw e
    }
    let opened = files.get(key)
    if (opened === undefined) {
      const o = openRegular(key)
      if (o.kind === "missing") return o
      // A link at a real path: it changed since. Followed, it is not this file.
      if (o.kind === "link") return follow ? { kind: "special" } : o
      onOpen?.(key)
      files.set(key, o)
      opened = o
    }
    if (opened.kind === "special") return opened
    if (opened.text === undefined || opened.size > BigInt(limit)) return { kind: "large", size: opened.size }
    return { kind: "file", text: opened.text }
  }
}

/** `path` exists, as a link or not (never followed). */
const present = (path: string): boolean => {
  try {
    lstatSync(path)
    return true
  } catch {
    return false
  }
}

/** The real path of `path` when it exists, else `path` made absolute. */
const real = (path: string): string => (existsSync(path) ? realpathSync(path) : resolve(path))

const ancestors = function* (dir: string): Generator<string> {
  for (let d = dir; ; d = dirname(d)) {
    yield d
    if (dirname(d) === d) return
  }
}

// ── manifests ────────────────────────────────────────────────

const badManifest = (path: string, why: string): never => {
  throw new ModuleError("package-manifest", `${shown(path)} is not a valid manifest: ${why}`)
}

const notRegular = (what: string, path: string, read: Read): never => {
  throw new ModuleError(
    "package-path",
    read.kind === "link"
      ? `${what} ${shown(path)} is a symbolic link: a package's files must be regular files, not links. It is not read`
      : `${what} ${shown(path)} is not a regular file. It is not read`,
  )
}

/**
 * Read and check a schema package manifest (spec §13.3): a regular file (not
 * a link) of at most 64 KiB, one record, `name` a lowercase `@org/name`,
 * `version` a semantic version. Other fields are ignored. Throws a
 * ModuleError with code `package-manifest`, or `package-path` for a link or
 * a file that isn't regular; a plain Error when there is no manifest.
 */
export function readManifest(path: string, read: Reader = reader()): Manifest {
  const dir = real(dirname(resolve(path)))
  const file = join(dir, MANIFEST)
  const got = read(file, MAX_MANIFEST_BYTES)
  if (got.kind === "missing") throw new Error(`${shown(dir)} is not a schema package: it has no ${MANIFEST}`)
  if (got.kind === "link" || got.kind === "special") return notRegular("the manifest", file, got)
  if (got.kind === "large") return badManifest(file, `it is larger than ${MAX_MANIFEST_BYTES / 1024} KiB`)
  const text = got.text
  let values
  try {
    values = parseAll(text)
  } catch (e) {
    // Where, not what: the message would quote the file.
    if (e instanceof HausSyntaxError) return badManifest(file, `it is not valid haus (${e.code} at ${e.line}:${e.column})`)
    throw e
  }
  const [value] = values
  if (values.length !== 1 || value?.kind !== "record") return badManifest(file, `it must be one record: { name: "@org/name", version: "1.2.0" }`)
  const field = (key: string): string => {
    const f = value.fields.get(key)
    return f?.kind === "string" ? f.value : badManifest(file, `it needs a string field ${key}`)
  }
  const name = field("name")
  const version = field("version")
  if (!isPackageName(name) || name.length > MAX_NAME) {
    badManifest(file, `the name "${quoteText(name)}" is not a lowercase @org/name (a-z, 0-9, - . _, each part starting with a letter or digit and not node_modules, at most ${MAX_NAME} characters)`)
  }
  if (!SEMVER.test(version)) badManifest(file, `the version "${quoteText(version)}" is not a semantic version like 1.2.0`)
  return { name, version, dir, text }
}

// ── package.json ─────────────────────────────────────────────

type PackageJson =
  | { readonly kind: "missing" }
  /**
   * Not valid JSON, or not a regular file: declares nothing, gives no
   * version, and ends the search for the nearest one (spec §13.3).
   */
  | { readonly kind: "invalid" }
  /** Valid JSON but not an object: declares nothing, gives no version; the search goes on above it. */
  | { readonly kind: "notObject" }
  | { readonly kind: "json"; readonly json: Readonly<Record<string, unknown>> }

/**
 * The package.json in `dir`. A package's (`dir` has a manifest) is read as its
 * other files: a regular file, never a link (`package-path`). Larger than
 * 1 MiB: `file-too-large`.
 */
const readPackageJson = (dir: string, read: Reader): PackageJson => {
  const path = join(dir, "package.json")
  const ofPackage = present(join(dir, MANIFEST))
  const got = read(path, MAX_PACKAGE_JSON_BYTES, !ofPackage)
  if (got.kind === "missing") return { kind: "missing" }
  if (got.kind === "link") return notRegular("the package.json", path, got)
  if (got.kind === "special") return ofPackage ? notRegular("the package.json", path, got) : { kind: "invalid" }
  if (got.kind === "large") throw new ModuleError("file-too-large", `${shown(path)} is larger than ${MAX_PACKAGE_JSON_BYTES / 1024 / 1024} MiB. It is not read`)
  try {
    const json: unknown = JSON.parse(got.text)
    return typeof json === "object" && json !== null && !Array.isArray(json) ? { kind: "json", json: json as Record<string, unknown> } : { kind: "notObject" }
  } catch {
    return { kind: "invalid" }
  }
}

/** The `name` of the package.json in `dir`, if it can be read. */
const npmName = (dir: string, read: Reader): string | undefined => {
  try {
    const p = readPackageJson(dir, read)
    return p.kind === "json" && typeof p.json.name === "string" && p.json.name !== "" ? p.json.name : undefined
  } catch {
    return undefined
  }
}

const DECLARING = ["dependencies", "peerDependencies", "optionalDependencies"] as const
const ALL_DEPENDENCIES = [...DECLARING, "devDependencies"] as const

/** A dependency field declares names only when it is an object (`dependencies-not-an-object`). */
const declares = (json: Readonly<Record<string, unknown>>, field: string, name: string): boolean => {
  const deps = json[field]
  return typeof deps === "object" && deps !== null && !Array.isArray(deps) && Object.hasOwn(deps, name)
}

// ── packages and files ───────────────────────────────────────

/** The manifest of the package whose schema is the file at `path` (absolute), if it is one. */
const packageOf = (path: string, read: Reader): Manifest | undefined =>
  basename(path) === PACKAGE_SCHEMA && present(join(dirname(path), MANIFEST)) ? readManifest(join(dirname(path), MANIFEST), read) : undefined

/** The package directory a file is in, if any: the nearest directory above it with a manifest. */
const packageDirOf = (path: string): string | undefined => {
  for (const dir of ancestors(dirname(path))) if (present(join(dir, MANIFEST))) return dir
  return undefined
}

/** The name of the package in `dir`, or the directory if its manifest can't be read. */
const packageName = (dir: string, read: Reader): string => {
  try {
    return readManifest(join(dir, MANIFEST), read).name
  } catch {
    return shown(dir)
  }
}

const stem = (path: string) => path.replaceAll(sep, "/").replace(/\.schema\.haus$/, "")

/**
 * The identity of a schema file (ResolvedModule.id): `@org/name@N` for a
 * package's schema, `<package.json name>/<path>` for a file in an npm project,
 * and otherwise its path from `base` (default: its own directory, so just its
 * name). Different files get different ids as long as they share a `base`.
 */
export function identify(path: string, base: string = dirname(resolve(path)), read: Reader = reader()): string {
  const file = resolve(path)
  const manifest = packageOf(file, read)
  if (manifest) return `${manifest.name}@${manifest.version.split(".")[0]}`
  for (const dir of ancestors(dirname(file))) {
    const name = npmName(dir, read)
    if (name !== undefined) return `${name}/${stem(relative(dir, file))}`
  }
  return stem(relative(base, file))
}

/** Each name of `path` (relative, with `/`) is spelled as the directory above it lists it (spec §13.3). */
const spelled = (dir: string, path: string): boolean => {
  let current = dir
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue
    if (part === "..") {
      current = dirname(current)
      continue
    }
    let names: string[]
    try {
      names = readdirSync(current)
    } catch {
      return false
    }
    if (!names.includes(part)) return false
    current = join(current, part)
  }
  return true
}

/** A Windows drive root (`C:\`), or another root of a file system there (`\\host\share\`). */
const windowsRoot = (dir: string): boolean => process.platform === "win32" && dirname(dir) === dir

/** Everyone may write to `dir` (Unix permissions; `/tmp`). */
const everyoneWrites = (dir: string): boolean => {
  if (process.platform === "win32") return false
  try {
    return (statSync(dir).mode & 0o002) !== 0
  } catch {
    return false
  }
}

/**
 * The directories `D` whose `node_modules` may hold packages for the file
 * `from` (absolute, real), nearest first (spec §13.3). As Node walks them, but
 * not a `D` named node_modules, a scope directory directly inside one, a
 * Windows drive root or a directory everyone may write to; and never
 * `NODE_PATH` or the global folders.
 */
const nodeModules = function* (from: string): Generator<string> {
  for (const d of ancestors(dirname(from))) {
    const name = basename(d)
    if (name === "node_modules") continue
    if (name.startsWith("@") && basename(dirname(d)) === "node_modules") continue
    if (windowsRoot(d)) continue
    if (everyoneWrites(d)) continue
    yield join(d, "node_modules")
  }
}

// ── options ──────────────────────────────────────────────────

export interface NodeResolverOptions {
  /**
   * Where relative imports of the root file resolve from if it has no key,
   * the directory relative `packages` and `folders` are taken from, and where
   * the ids of files outside any npm project are taken from (default: the
   * working directory; `schemaOptions` uses the root file's directory).
   */
  readonly base?: string
  /**
   * Packages given explicitly (spec §13.3): each a package directory, with
   * `package.haus` and `schema.haus`. The manifests name them, not the
   * directories. They are used instead of node_modules for their names, and
   * always count as declared dependencies.
   *
   *   packages: ["../vendor/money", "/opt/schemas/geo"]
   *
   * The older form, packages by name, still works; the manifest must have
   * that name: `{ "@haus-fmt/money": "../extensions/money" }`.
   */
  readonly packages?: readonly string[] | Readonly<Record<string, string>>
  /**
   * Folders of packages: each direct subdirectory with a `package.haus` is a
   * package (at most 4096 entries). They count as declared, but don't replace
   * a package installed in node_modules: one with the same name and other
   * files is a `duplicate-package`. A subdirectory whose manifest is invalid
   * is ignored; an import that isn't found names it.
   *
   *   folders: ["../schemas"]   // schemas/orders-v1/package.haus names @acme/orders
   */
  readonly folders?: readonly string[]
  /**
   * Look for packages in node_modules (default true). With `false`, only the
   * packages given in `packages` and `folders` exist.
   */
  readonly npm?: boolean
  /**
   * Called with the real path of each file the resolver opens; each is opened
   * at most once (spec §13.3). For tests and tools that list what a schema read.
   */
  readonly onOpen?: (path: string) => void
}

/** The packages given explicitly, by manifest name; read when the first package is resolved. */
interface Explicit {
  /** Packages given by their directory: used instead of any other. */
  readonly given: ReadonlyMap<string, Manifest>
  /** Packages found in folders. */
  readonly found: ReadonlyMap<string, Manifest>
  /** Two different packages with one name: the duplicate-package message. */
  readonly clashes: ReadonlyMap<string, string>
  /** Names of the older form whose directory holds another package: the import-not-found message. */
  readonly misnamed: ReadonlyMap<string, string>
  /** Subdirectories of folders whose manifest can't be read, with why. */
  readonly invalid: readonly string[]
}

/** The text of the package's `schema.haus`, if it is a regular file that can be read. */
const schemaText = (m: Manifest, read: Reader): string | undefined => {
  const got = read(join(m.dir, PACKAGE_SCHEMA), MAX_SCHEMA_BYTES)
  return got.kind === "file" ? got.text : undefined
}

/** Copies of one package: their package.haus and schema.haus are the same, byte for byte. */
const sameFiles = (a: Manifest, b: Manifest, read: Reader): boolean => {
  if (a.dir === b.dir) return true
  const text = schemaText(a, read)
  return a.text === b.text && text !== undefined && text === schemaText(b, read)
}

const configError = (message: string): never => {
  throw new ModuleError("import-not-found", message)
}

/** The package directories and folder subdirectories given, checked when the resolver is set up. */
interface Given {
  readonly dirs: readonly string[]
  readonly named: readonly (readonly [string, string])[]
  readonly scanned: readonly string[]
}

/**
 * Check the packages and folders given (spec §13.3): a package directory
 * without `package.haus` or a folder that doesn't exist is a configuration
 * error (`import-not-found`), reported now and not at some import. A folder's
 * direct subdirectories (links to directories too) with a `package.haus` are
 * its packages; more than 4096 entries is `too-many-files`.
 */
const given = (base: string, options: NodeResolverOptions): Given => {
  const packages = options.packages ?? []
  const named = Array.isArray(packages) ? [] : Object.entries(packages as Readonly<Record<string, string>>).map(([n, d]) => [n, resolve(base, d)] as const)
  const dirs = Array.isArray(packages) ? (packages as readonly string[]).map((d) => resolve(base, d)) : named.map(([, d]) => d)
  for (const dir of dirs) if (!present(join(dir, MANIFEST))) configError(`${shown(dir)} is not a schema package: it has no ${MANIFEST}`)
  const scanned = (options.folders ?? []).flatMap((f) => {
    const folder = resolve(base, f)
    let isDir = false
    try {
      isDir = statSync(folder).isDirectory()
    } catch {
      // Doesn't exist.
    }
    if (!isDir) return configError(`the folder of packages ${shown(folder)} doesn't exist`)
    // Its entries are named under its real path: `./schemas/` and a link to `schemas` are both `schemas` (spec §13.3).
    const realFolder = realpathSync(folder)
    const entries = readdirSync(realFolder)
    if (entries.length > MAX_FOLDER_ENTRIES) {
      throw new ModuleError("too-many-files", `the folder of packages ${shown(folder)} has ${entries.length} entries, more than ${MAX_FOLDER_ENTRIES}`)
    }
    return entries
      .sort()
      .map((entry) => join(realFolder, entry))
      .filter((dir) => {
        try {
          return statSync(dir).isDirectory() && present(join(dir, MANIFEST))
        } catch {
          return false
        }
      })
  })
  return { dirs, named, scanned }
}

/** Read the manifests of the packages given. A given directory's must be valid; a folder's invalid ones are noted. */
const explicitPackages = ({ dirs, named, scanned }: Given, read: Reader): Explicit => {
  const clashes = new Map<string, string>()
  const add = (into: Map<string, Manifest>, manifest: Manifest) => {
    const first = into.get(manifest.name)
    if (first === undefined) into.set(manifest.name, manifest)
    else if (!clashes.has(manifest.name) && !sameFiles(first, manifest, read)) {
      clashes.set(manifest.name, `two packages are named ${manifest.name}: ${quoteText(first.version)} in ${shown(first.dir)} and ${quoteText(manifest.version)} in ${shown(manifest.dir)}`)
    }
  }
  const givenByName = new Map<string, Manifest>()
  for (const dir of dirs) add(givenByName, readManifest(join(dir, MANIFEST), read))
  const found = new Map<string, Manifest>()
  const invalid: string[] = []
  for (const dir of scanned) {
    let manifest: Manifest
    try {
      manifest = readManifest(join(dir, MANIFEST), read)
    } catch (e) {
      invalid.push(`${shown(dir)} (${e instanceof Error ? e.message : String(e)})`)
      continue
    }
    // Another version in its package.json: skipped the same way (spec §13.3).
    const mismatch = versionMismatch(manifest, lenientVersion(dir, read))
    if (mismatch !== undefined) {
      invalid.push(`${shown(dir)} (${mismatch})`)
      continue
    }
    // A package given by its directory is used instead of one found in a folder.
    if (!givenByName.has(manifest.name)) add(found, manifest)
  }
  const misnamed = new Map<string, string>()
  for (const [name, dir] of named) {
    const m = readManifest(join(dir, MANIFEST), read)
    if (m.name !== name) misnamed.set(name, `${shown(dir)} holds the package ${m.name}, not ${name}`)
  }
  return { given: givenByName, found, clashes, misnamed, invalid }
}

// ── the resolver ─────────────────────────────────────────────

/** The `version` of a package.json, if it gives one. */
const versionOf = (npm: PackageJson): unknown => (npm.kind === "json" ? npm.json.version : undefined)

/**
 * The version of the package.json beside a package's manifest, read
 * leniently: outside npm mode one that can't be read (a link, not a regular
 * file, too large, not JSON) is ignored and gives no version (spec §13.3).
 */
const lenientVersion = (dir: string, read: Reader): unknown => {
  try {
    return versionOf(readPackageJson(dir, read))
  } catch {
    return undefined
  }
}

/** The `package-version` message if the package.json gives another version than the manifest (SHOULD, spec §13.3). Quoted only when it is a version. */
const versionMismatch = (manifest: Manifest, npmVersion: unknown): string | undefined => {
  if (typeof npmVersion !== "string" || npmVersion === manifest.version) return undefined
  const theirs = SEMVER.test(npmVersion) ? `version ${quoteText(npmVersion)}` : "a version that is not a semantic version"
  return `${manifest.name}: its package.haus says version ${quoteText(manifest.version)}, its package.json ${theirs} (${shown(manifest.dir)})`
}

/**
 * The schema of the package in `manifest.dir`, imported as `module`, after
 * the checks of spec §13.3. With `npm`, its package.json is read as its other
 * files are (a link is `package-path`); without, it only gives a version, and
 * one that can't be read is ignored.
 */
const packageSchema = (manifest: Manifest, module: string, read: Reader, npm: boolean): ResolvedModule => {
  if (manifest.name !== module) throw new Error(`${shown(manifest.dir)} holds the package ${manifest.name}, not ${module}`)
  const npmVersion = npm ? versionOf(readPackageJson(manifest.dir, read)) : lenientVersion(manifest.dir, read)
  const mismatch = versionMismatch(manifest, npmVersion)
  if (mismatch !== undefined) throw new ModuleError("package-version", mismatch)
  const key = join(manifest.dir, PACKAGE_SCHEMA)
  const got = read(key, MAX_SCHEMA_BYTES)
  if (got.kind === "missing") throw new Error(`${manifest.name} has no ${PACKAGE_SCHEMA} next to its manifest (${shown(manifest.dir)})`)
  if (got.kind === "link" || got.kind === "special") return notRegular(`${manifest.name}: its ${PACKAGE_SCHEMA}`, key, got)
  if (got.kind === "large") throw new ModuleError("file-too-large", `${manifest.name}: its ${PACKAGE_SCHEMA} is larger than ${MAX_SCHEMA_BYTES / 1024 / 1024} MiB. It is not read`)
  return {
    key,
    id: `${manifest.name}@${manifest.version.split(".")[0]}`,
    text: got.text,
    version: manifest.version,
    package: manifest.name,
    manifest: manifest.text,
    path: key,
  }
}

/**
 * Spec §13.3: the file `from` (a real path) declares `module`. A package's
 * schema.haus declares in its own package.json; other files in the nearest
 * package.json above them that has a `name` or a dependency field. Throws
 * `undeclared-package` when it doesn't. Checked before anything is looked for.
 */
const checkDeclared = (module: string, from: string, read: Reader): void => {
  const dir = dirname(from)
  const pkg = packageOf(from, read)
  if (pkg !== undefined) {
    const own = readPackageJson(dir, read)
    if (own.kind === "json" && DECLARING.some((f) => declares(own.json, f, module))) return
    throw new ModuleError(
      "undeclared-package",
      own.kind === "missing"
        ? `${pkg.name} imports ${module}, but it has no package.json to declare it: a package declares what it imports in its own package.json (peerDependencies)`
        : `${pkg.name} imports ${module}, which its package.json (${shown(join(dir, "package.json"))}) doesn't declare: add it to its peerDependencies (or dependencies)`,
    )
  }
  for (const d of ancestors(dir)) {
    const p = readPackageJson(d, read)
    // Not a project's: valid JSON that isn't an object, or a marker such as { "type": "module" }.
    if (p.kind === "missing" || p.kind === "notObject") continue
    if (p.kind === "json" && !Object.hasOwn(p.json, "name") && !ALL_DEPENDENCIES.some((f) => Object.hasOwn(p.json, f))) continue
    if (p.kind === "json" && ALL_DEPENDENCIES.some((f) => declares(p.json, f, module))) return
    throw new ModuleError("undeclared-package", `${module} is imported by ${shown(from)}, but ${shown(join(d, "package.json"))} doesn't declare it: add it to its dependencies`)
  }
  throw new ModuleError(
    "undeclared-package",
    `no package.json above ${shown(from)} declares ${module}: give the package explicitly (packages or folders, or haus.packages in the editor), or add it to the dependencies of a package.json`,
  )
}

/**
 * Finds packages given explicitly, in node_modules above the importing file's
 * real path (unless `npm: false`), and relative files. Throws a ModuleError
 * (`import-not-found`, `too-many-files`) when the packages or folders given
 * don't exist.
 */
export function nodeResolver(options: NodeResolverOptions = {}): ModuleResolver {
  return resolverReading(options, reader(options.onOpen))
}

/** A Node resolver that reads with `read`, shared with whoever identifies the root file. */
const resolverReading = (options: NodeResolverOptions, read: Reader): ModuleResolver => {
  const base = resolve(options.base ?? process.cwd())
  const npm = options.npm ?? true
  const setup = given(base, options)
  let explicit: Explicit | undefined
  const packages = (): Explicit => (explicit ??= explicitPackages(setup, read))
  const notFound = (message: string, ex: Explicit): never => {
    throw new Error(ex.invalid.length === 0 ? message : `${message}; these packages could not be read: ${ex.invalid.join(", ")}`)
  }

  const relativeFile = (module: string, from: string | undefined, origin: string | undefined): ResolvedModule => {
    // A package is one file: its schema imports other packages by name (spec §13.3).
    const pkg = from === undefined ? undefined : (packageDirOf(resolve(from)) ?? (origin ? packageDirOf(origin) : undefined))
    if (pkg !== undefined) throw new ModuleError("package-path", `the schema of ${packageName(pkg, read)} can't import files, only packages by name`)
    const dir = origin ? dirname(origin) : base
    const path = resolve(dir, module + EXTENSION)
    // An application's file doesn't reach into a package: it imports the package by name.
    const into = packageDirOf(path) ?? (existsSync(path) ? packageDirOf(realpathSync(path)) : undefined)
    if (into !== undefined) throw new ModuleError("package-path", `the file is in the package directory ${shown(into)}: import the package by its name`)
    // Spelled as the directories list it, also where the file system ignores case.
    if (!existsSync(path) || !spelled(dir, module + EXTENSION)) throw new Error(`file not found: ${shown(path)}`)
    const key = realpathSync(path)
    if (!key.endsWith(EXTENSION)) throw new Error(`${shown(path)} is not a schema file: its real path doesn't end in ${EXTENSION}. It is not read`)
    const got = read(key, MAX_SCHEMA_BYTES)
    if (got.kind === "missing" || got.kind === "link") throw new Error(`file not found: ${shown(path)}`)
    if (got.kind === "special") throw new Error(`${shown(path)} is not a regular file. It is not read`)
    if (got.kind === "large") throw new ModuleError("file-too-large", `${shown(path)} is larger than ${MAX_SCHEMA_BYTES / 1024 / 1024} MiB. It is not read`)
    return { key, id: identify(key, base, read), text: got.text, path: key }
  }

  return {
    resolve(module, from) {
      // The importing file's real path: lookups start there, as in Node.
      const origin = from === undefined ? undefined : real(from)
      if (module.startsWith("./") || module.startsWith("../")) return relativeFile(module, from, origin)
      const ex = packages()
      const clash = ex.clashes.get(module)
      if (clash !== undefined) throw new ModuleError("duplicate-package", clash)
      const own = ex.given.get(module)
      if (own) return packageSchema(own, module, read, npm)
      const wrong = ex.misnamed.get(module)
      if (wrong !== undefined) throw new Error(wrong)
      const inFolder = ex.found.get(module)
      if (!npm) return inFolder ? packageSchema(inFolder, module, read, npm) : notFound(`package not found: ${module} is not among the packages given`, ex)
      const importer = origin ?? join(base, "_")
      // Given packages count as declared; others must be, before anything is looked for.
      if (inFolder === undefined) checkDeclared(module, importer, read)
      // As Node: the first node_modules/@org/name above the importing file's real path.
      let installed: string | undefined
      for (const nm of nodeModules(importer)) {
        const dir = join(nm, ...module.split("/"))
        if (existsSync(dir)) {
          installed = dir
          break
        }
      }
      if (inFolder !== undefined) {
        // A package found in a folder doesn't replace an installed one with other files (spec §13.3).
        if (installed !== undefined && present(join(installed, MANIFEST))) {
          const m = readManifest(join(installed, MANIFEST), read)
          if (m.name === module && !sameFiles(m, inFolder, read)) {
            throw new ModuleError(
              "duplicate-package",
              `two packages are named ${module}: ${quoteText(m.version)} installed in ${shown(m.dir)} and ${quoteText(inFolder.version)} in the folder of packages (${shown(inFolder.dir)})`,
            )
          }
        }
        return packageSchema(inFolder, module, read, npm)
      }
      if (installed === undefined) return notFound(`package not found (no node_modules/${module} above ${shown(dirname(importer))})`, ex)
      // The first one found is the package: no looking further up.
      if (!present(join(installed, MANIFEST))) throw new Error(`${shown(installed)} is not a schema package: it has no ${MANIFEST}`)
      return packageSchema(readManifest(join(installed, MANIFEST), read), module, read, npm)
    },
  }
}

/** Options for parseSchemaFile for the schema file at `path`: its key (real path), identity and a Node resolver. */
export function schemaOptions(path: string, options: NodeResolverOptions = {}): ParseSchemaOptions {
  const key = real(path)
  // One reader for the schema: the root's identity and every import (each file read once).
  const read = reader(options.onOpen)
  return { key, id: identify(key, resolve(options.base ?? dirname(key)), read), resolver: resolverReading({ base: dirname(key), ...options }, read) }
}
