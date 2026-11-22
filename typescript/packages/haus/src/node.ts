/// <reference types="node" />
/**
 * Resolving schema imports from the file system (Node):
 *
 *   import @haus-fmt/money (Money)    → node_modules/@haus-fmt/money/package.haus and schema.haus next to it
 *   import ./common (Address)         → ./common.schema.haus, next to the importing file
 *
 *   const { text, options } = readSchemaFile(path)
 *   const file = parseSchemaFile(text, options)
 *   const { text, options } = readSchemaFile(path, { packages: ["../vendor/money"], folders: ["../schemas"] })
 *   const { text, options } = readSchemaFile(path, { folders: ["../schemas"], npm: false, root: ".." })
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
 *   instead of any installed one. A package.json beside one is read
 *   leniently: one that can't be read is ignored.
 * - Packages found in a folder of packages (`folders`) are used too, but don't
 *   replace an installed package: if the importer's node_modules has a package
 *   with that name and other files, the schema has two packages with one name.
 * - With `npm` (the default), `@org/name` is looked up as Node does: in
 *   `node_modules/@org/name` of each directory above the importing file's real
 *   path (symbolic links resolved, so pnpm's layout and workspace links work),
 *   skipping directories named `node_modules`, scope directories inside one,
 *   Windows drive and share roots and, on Unix, directories everyone may write
 *   to (`/tmp`). The first `node_modules/@org/name` that is there (as `lstat`
 *   sees it) is the package; one that is there but can't be used (a dangling
 *   link, a cycle of links, a directory that can't be listed on the way) stops
 *   the search. The search is not bounded by the build's root, as Node's isn't.
 * - Before it looks, a file must declare what it imports: a package's
 *   `schema.haus` in the package's own package.json (`dependencies`,
 *   `peerDependencies`, `optionalDependencies`), other files in the nearest
 *   package.json above their real path that has a `name` or a dependency field
 *   (`devDependencies` count too); one that isn't valid JSON or isn't a
 *   regular file (a link too: it is not followed) ends the search and declares
 *   nothing, one that is valid JSON but not an object is skipped. Given
 *   packages always count as declared.
 * - When the package's directory has a package.json with a `version` that is
 *   a string, it must be the manifest's.
 *
 * Relative imports stay inside the build's root (spec §13.3, "The root"): the
 * directory of the entry file's real path, or the `root` option (relative to
 * that directory). Only the entry file and the root are resolved to real
 * paths, and may be reached through links; a relative import follows none. It
 * is checked in the spec's order: an import whose `..` names go above the
 * root is rejected before anything is looked at (`import-outside-root`); then
 * each of its names must be listed by its directory with that spelling and
 * must not be a symbolic link (`import-not-found`, the link never followed);
 * then its file must not be in a package's directory, looked for up to the
 * root, where a directory that can't be listed fails the import
 * (`package-path`, `import-not-found`); then the file is opened. Messages
 * show paths relative to the root.
 *
 * Every file read (the entry file, relative imports, a package's
 * `package.haus`, `schema.haus` and `package.json`, a project's package.json)
 * is a regular file: opened by its real path or in a real directory without
 * following a link at its last name and without blocking, checked on the open
 * handle (type, size, the same file as `lstat` saw) and read from it. The
 * names a build looks up itself (`package.haus`, `schema.haus`,
 * `package.json`, `node_modules`, `@org/name`) and every name of a relative
 * import must be spelled as their directory lists them; a directory that
 * can't be listed has none of them.
 *
 * Files are known by their real path (ResolvedModule.key): two imports reach
 * the same file when its real path is the same. Files outside a schema
 * package are identified by the nearest package.json name and their path
 * (`my-app/src/order#Root`), or without one by their path from the resolver's
 * `base`; their relative imports can't reach into a package directory. A
 * file's id never has the form of a package's (`@org/name@N`): one that would
 * start with `@` starts with `./@` instead.
 *
 * A resolver reads each file at most once, by its real path, also when one
 * file is needed in two roles: every use sees the same bytes (spec §13.3).
 * The checks of each role (a regular file, its size) still apply to each use.
 * Make one resolver per schema (readSchemaFile and schemaOptions do), so a
 * long-running process such as a language server sees a reinstalled package.
 */
import { closeSync, constants, fstatSync, lstatSync, opendirSync, openSync, readSync, realpathSync, statSync, type BigIntStats } from "node:fs"
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path"
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
const PACKAGE_JSON = "package.json"
const NODE_MODULES = "node_modules"
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

// ── reading files: regular files, checked on the open handle ──

type Read =
  | { readonly kind: "missing" }
  | { readonly kind: "link" }
  | { readonly kind: "special" }
  | { readonly kind: "large"; readonly size: bigint }
  | { readonly kind: "file"; readonly text: string }

const NOFOLLOW: number | undefined = constants.O_NOFOLLOW
const NONBLOCK: number = constants.O_NONBLOCK ?? 0
const NOCTTY: number = constants.O_NOCTTY ?? 0
/** The most bytes read from any file: the largest limit, so one read serves every role (spec §13.3). */
const MAX_READ = Math.max(MAX_MANIFEST_BYTES, MAX_SCHEMA_BYTES, MAX_PACKAGE_JSON_BYTES)

/** A file opened: not a regular file, or one with its size and, unless it is larger than MAX_READ, its text. */
type Opened =
  | { readonly kind: "special" }
  | { readonly kind: "file"; readonly size: bigint; readonly text: string | undefined }

/**
 * What one schema reads (a resolver): files, by real path, each opened at
 * most once whatever roles it has (spec §13.3), and directory listings.
 */
interface Files {
  /**
   * `path` if it is a regular file of at most `limit` bytes. A symbolic link
   * at its last name is not followed (and not read): `link`. Each use checks
   * its own limit.
   */
  read(path: string, limit: number): Read
  /** The names `dir` lists, or undefined if it can't be listed. */
  list(dir: string): readonly string[] | undefined
  /** The build's root (a real path): relative imports stay inside it, messages show paths relative to it. */
  readonly root: string
}

const errno = (e: unknown): string | undefined => (e as NodeJS.ErrnoException | undefined)?.code
const isMissing = (e: unknown): boolean => errno(e) === "ENOENT" || errno(e) === "ENOTDIR"

/** `path` (absolute) relative to `root`, with `/`: `app/x.schema.haus`, `../vendor/x`; absolute only on another drive. */
const fromRoot = (root: string, path: string): string => {
  const r = relative(root, path)
  if (r === "") return "."
  return isAbsolute(r) ? path : r.replaceAll(sep, "/")
}

/** A path in a message: relative to the root, escaped (control and bidirectional characters), never cut (spec §13.3). */
const shown = (files: Files, path: string): string => quoteText(fromRoot(files.root, path), Infinity)

/** The text of a file read: UTF-8, as every haus file (spec §1). */
const utf8 = (bytes: Uint8Array, files: Files, path: string): string => {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes)
  } catch {
    throw new ModuleError("invalid-utf8", `${shown(files, path)} is not UTF-8 text`)
  }
}

/**
 * Open the file at `path`, whose last name must not be a link, and read it
 * (spec §13.3, "Files read"): `lstat` it (a regular file, and which one),
 * open it without following links (O_NOFOLLOW), without blocking
 * (O_NONBLOCK, so a FIFO or a device can't stall the open) and without
 * making it a controlling terminal (O_NOCTTY), and check on the open handle
 * that it is the regular file `lstat` saw (device and inode), then read from
 * the handle, so the file checked is the file read. Where O_NOFOLLOW doesn't
 * exist (Windows), the comparison with `lstat` stands in for it.
 */
const openRegular = (path: string, decode: (bytes: Uint8Array) => string): Opened | { readonly kind: "missing" } | { readonly kind: "link" } => {
  let before: BigIntStats
  try {
    before = lstatSync(path, { bigint: true })
  } catch (e) {
    if (isMissing(e)) return { kind: "missing" }
    if (errno(e) === "EACCES" || errno(e) === "EPERM") return { kind: "special" }
    throw e
  }
  if (before.isSymbolicLink()) return { kind: "link" }
  if (!before.isFile()) return { kind: "special" }
  let fd: number
  try {
    fd = openSync(path, constants.O_RDONLY | (NOFOLLOW ?? 0) | NONBLOCK | NOCTTY)
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
    // Another file than lstat saw: it changed since (a link put in its place, where O_NOFOLLOW doesn't exist).
    if (stats.ino !== before.ino || stats.dev !== before.dev) return NOFOLLOW === undefined ? { kind: "link" } : { kind: "special" }
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
    return { kind: "file", size: BigInt(total), text: decode(Buffer.concat(chunks)) }
  } finally {
    closeSync(fd)
  }
}

/**
 * The files of one schema, whose build has the root `root` (a real path).
 * `onOpen` is called with the real path of each file opened.
 */
const schemaFiles = (root: string, onOpen?: (path: string) => void): Files => {
  const opened = new Map<string, Opened>()
  const listings = new Map<string, readonly string[] | undefined>()
  const files: Files = {
    root,
    read(path, limit) {
      // The real path: its directory's, and its name, a link at its last name not followed.
      let key: string
      try {
        key = join(realpathSync(dirname(resolve(path))), basename(path))
      } catch (e) {
        if (isMissing(e) || errno(e) === "ELOOP") return { kind: "missing" }
        throw e
      }
      let o = opened.get(key)
      if (o === undefined) {
        const got = openRegular(key, (bytes) => utf8(bytes, files, key))
        if (got.kind === "missing" || got.kind === "link") return got
        onOpen?.(key)
        opened.set(key, got)
        o = got
      }
      if (o.kind === "special") return o
      if (o.text === undefined || o.size > BigInt(limit)) return { kind: "large", size: o.size }
      return { kind: "file", text: o.text }
    },
    list(dir) {
      if (listings.has(dir)) return listings.get(dir)
      let names: string[] | undefined
      try {
        const d = opendirSync(dir)
        try {
          names = []
          for (let e = d.readSync(); e !== null; e = d.readSync()) names.push(e.name)
        } finally {
          d.closeSync()
        }
      } catch {
        names = undefined
      }
      listings.set(dir, names)
      return names
    },
  }
  return files
}

/** `dir` lists `name`, spelled so (spec §13.3, "Spelling"); a directory that can't be listed lists nothing. */
const has = (files: Files, dir: string, name: string): boolean => files.list(dir)?.includes(name) ?? false

/** The real path of `path` when it exists, else `path` made absolute. */
const real = (path: string): string => {
  try {
    return realpathSync(path)
  } catch {
    return resolve(path)
  }
}

/** `path` is `dir` or inside it (both real, absolute). Compared by names, not as strings: `/a/bc` is not in `/a/b`. */
const inside = (dir: string, path: string): boolean => path === dir || path.startsWith(dir.endsWith(sep) ? dir : dir + sep)

const ancestors = function* (dir: string): Generator<string> {
  for (let d = dir; ; d = dirname(d)) {
    yield d
    if (dirname(d) === d) return
  }
}

// ── manifests ────────────────────────────────────────────────

const badManifest = (files: Files, path: string, why: string): never => {
  throw new ModuleError("package-manifest", `${shown(files, path)} is not a valid manifest: ${why}`)
}

const notRegular = (files: Files, what: string, path: string, read: Read): never => {
  throw new ModuleError(
    "package-path",
    read.kind === "link"
      ? `${what} ${shown(files, path)} is a symbolic link: a package's files must be regular files, not links. It is not read`
      : `${what} ${shown(files, path)} is not a regular file. It is not read`,
  )
}

/**
 * Read and check a schema package manifest (spec §13.3): a regular file (not
 * a link) of at most 64 KiB, listed as `package.haus` by its directory, one
 * record, `name` a lowercase `@org/name`, `version` a semantic version. Other
 * fields are ignored. Throws a ModuleError with code `package-manifest`, or
 * `package-path` for a link or a file that isn't regular; a plain Error when
 * there is no manifest.
 */
export function readManifest(path: string, files: Files = schemaFiles(dirname(real(resolve(path))))): Manifest {
  const dir = real(dirname(resolve(path)))
  const file = join(dir, MANIFEST)
  const got = has(files, dir, MANIFEST) ? files.read(file, MAX_MANIFEST_BYTES) : { kind: "missing" as const }
  if (got.kind === "missing") throw new Error(`${shown(files, dir)} is not a schema package: it has no ${MANIFEST}`)
  if (got.kind === "link" || got.kind === "special") return notRegular(files, "the manifest", file, got)
  if (got.kind === "large") return badManifest(files, file, `it is larger than ${MAX_MANIFEST_BYTES / 1024} KiB`)
  const text = got.text
  let values
  try {
    values = parseAll(text)
  } catch (e) {
    // Where, not what: the message would quote the file.
    if (e instanceof HausSyntaxError) return badManifest(files, file, `it is not valid haus (${e.code} at ${e.line}:${e.column})`)
    throw e
  }
  const [value] = values
  if (values.length !== 1 || value?.kind !== "record") return badManifest(files, file, `it must be one record: { name: "@org/name", version: "1.2.0" }`)
  const field = (key: string): string => {
    const f = value.fields.get(key)
    return f?.kind === "string" ? f.value : badManifest(files, file, `it needs a string field ${key}`)
  }
  const name = field("name")
  const version = field("version")
  if (!isPackageName(name) || name.length > MAX_NAME) {
    badManifest(files, file, `the name "${quoteText(name)}" is not a lowercase @org/name (a-z, 0-9, - . _, each part starting with a letter or digit and not node_modules, at most ${MAX_NAME} characters)`)
  }
  if (!SEMVER.test(version)) badManifest(files, file, `the version "${quoteText(version)}" is not a semantic version like 1.2.0`)
  return { name, version, dir, text }
}

// ── package.json ─────────────────────────────────────────────

type PackageJson =
  | { readonly kind: "missing" }
  /**
   * Not valid JSON, or not a regular file (a link too): declares nothing,
   * gives no version, and ends the search for the nearest one (spec §13.3).
   */
  | { readonly kind: "invalid" }
  /** Valid JSON but not an object: declares nothing, gives no version; the search goes on above it. */
  | { readonly kind: "notObject" }
  | { readonly kind: "json"; readonly json: Readonly<Record<string, unknown>> }

/**
 * The package.json in `dir` (a real directory), never followed if it is a
 * link. A package's (`dir` has a manifest) is read as its other files: a
 * regular file, never a link (`package-path`). A project's that is a link or
 * not a regular file declares nothing. A directory that can't be listed shows
 * none: for a project's, that declares nothing too (it can't be told apart
 * from one that is there). Larger than 1 MiB: `file-too-large`.
 */
const readPackageJson = (dir: string, files: Files): PackageJson => {
  const path = join(dir, PACKAGE_JSON)
  const names = files.list(dir)
  if (names === undefined) return { kind: "invalid" }
  const ofPackage = names.includes(MANIFEST)
  if (!names.includes(PACKAGE_JSON)) return { kind: "missing" }
  const got = files.read(path, MAX_PACKAGE_JSON_BYTES)
  if (got.kind === "missing") return { kind: "missing" }
  if (got.kind === "link" || got.kind === "special") return ofPackage ? notRegular(files, "the package.json", path, got) : { kind: "invalid" }
  if (got.kind === "large") throw new ModuleError("file-too-large", `${shown(files, path)} is larger than ${MAX_PACKAGE_JSON_BYTES / 1024 / 1024} MiB. It is not read`)
  try {
    const json: unknown = JSON.parse(got.text)
    return typeof json === "object" && json !== null && !Array.isArray(json) ? { kind: "json", json: json as Record<string, unknown> } : { kind: "notObject" }
  } catch {
    return { kind: "invalid" }
  }
}

/** The package.json in `dir`, read leniently: one that can't be read (a link, not a regular file, too large) is missing. */
const lenientPackageJson = (dir: string, files: Files): PackageJson => {
  try {
    return readPackageJson(dir, files)
  } catch {
    return { kind: "missing" }
  }
}

/** The `name` of the package.json in `dir`, if it can be read. */
const npmName = (dir: string, files: Files): string | undefined => {
  const p = lenientPackageJson(dir, files)
  return p.kind === "json" && typeof p.json.name === "string" && p.json.name !== "" ? p.json.name : undefined
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
const packageOf = (path: string, files: Files): Manifest | undefined =>
  basename(path) === PACKAGE_SCHEMA && has(files, dirname(path), MANIFEST) ? readManifest(join(dirname(path), MANIFEST), files) : undefined

/** The name of the package in `dir`, or the directory if its manifest can't be read. */
const packageName = (dir: string, files: Files): string => {
  try {
    return readManifest(join(dir, MANIFEST), files).name
  } catch {
    return shown(files, dir)
  }
}

const stem = (path: string) => path.replaceAll(sep, "/").replace(/\.schema\.haus$/, "")

/** A file's id never has the form of a package's, `@org/name@N` (spec §13.3, "Identity"): one that would start with `@` starts with `./`. */
const fileId = (id: string): string => (id.startsWith("@") ? `./${id}` : id)

/**
 * The identity of a schema file (ResolvedModule.id): `@org/name@N` for a
 * package's schema, `<package.json name>/<path>` for a file in an npm project,
 * and otherwise its path from `base` (default: its own directory, so just its
 * name). Different files get different ids as long as they share a `base`. A
 * file's id never has the form of a package's: one that would start with `@`
 * (a project named `@org/name`, a file named `@x`) starts with `./` instead.
 */
export function identify(path: string, base: string = dirname(resolve(path)), files: Files = schemaFiles(dirname(real(resolve(path))))): string {
  const file = resolve(path)
  const manifest = packageOf(file, files)
  if (manifest) return `${manifest.name}@${manifest.version.split(".")[0]}`
  for (const dir of ancestors(dirname(file))) {
    const name = npmName(dir, files)
    if (name !== undefined) return fileId(`${name}/${stem(relative(dir, file))}`)
  }
  return fileId(stem(relative(base, file)))
}

/**
 * The walk down a relative import's names from the real directory `dir`
 * (spec §13.3, "Resolution"): each name must be listed by its directory with
 * that spelling, also where the file system ignores case, and must not be a
 * symbolic link (`lstat`, never followed); each name but the last must be a
 * directory. The path reached has no links. A link is neither followed nor
 * read: the message says only that the name is one, not where it points.
 * `what` names the import in messages.
 */
const walkDown = (dir: string, names: readonly string[], files: Files, what: string): string => {
  const notFound = (why: string): never => {
    throw new Error(`file not found: ${shown(files, join(dir, ...names))} (${why})`)
  }
  let current = dir
  for (const [i, name] of names.entries()) {
    const quoted = `"${quoteText(name, Infinity)}"`
    const listed = files.list(current)
    if (listed === undefined) notFound(`${shown(files, current)} can't be listed, so how ${quoted} is spelled in it can't be checked`)
    if (!listed!.includes(name)) notFound(`its directory doesn't list ${quoted} with that spelling`)
    const at = join(current, name)
    let stats
    try {
      stats = lstatSync(at)
    } catch {
      return notFound(`${quoted} can't be looked at`)
    }
    if (stats.isSymbolicLink()) throw new Error(`${what}, in which ${quoted} is a symbolic link: a relative import follows no link, and nothing behind it is read`)
    if (i < names.length - 1 && !stats.isDirectory()) notFound(`${quoted} is not a directory`)
    current = at
  }
  return current
}

/** A Windows drive root (`C:\`), or the root of a share (`\\host\share\`): their dirname is themselves. */
const windowsRoot = (dir: string): boolean => process.platform === "win32" && dirname(dir) === dir

/** Everyone may write to `dir` (Unix permissions; `/tmp`). Unix only: Windows has no such simple test (spec §13.3). */
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
 * Windows drive or share root or a directory everyone may write to; and never
 * `NODE_PATH` or the global folders.
 */
const searched = function* (from: string): Generator<string> {
  for (const d of ancestors(dirname(from))) {
    const name = basename(d)
    if (name === NODE_MODULES) continue
    if (name.startsWith("@") && basename(dirname(d)) === NODE_MODULES) continue
    if (windowsRoot(d)) continue
    if (everyoneWrites(d)) continue
    yield d
  }
}

/** The package directory `@org/name` is installed in for the file `from`, by the npm rules (spec §13.3). */
const installedPackage = (module: string, from: string, files: Files): string | undefined => {
  const [org = "", name = ""] = module.split("/")
  const stop = (why: string): never => {
    throw new Error(`${module} can't be looked up further: ${why}, so it can't be told whether the package is there`)
  }
  for (const d of searched(from)) {
    const inD = files.list(d)
    if (inD === undefined) return stop(`${shown(files, d)} can't be listed`)
    if (!inD.includes(NODE_MODULES)) continue
    const nm = join(d, NODE_MODULES)
    let isDir: boolean
    try {
      isDir = statSync(nm).isDirectory()
    } catch (e) {
      if (errno(e) === "EACCES" || errno(e) === "EPERM" || errno(e) === "ELOOP") stop(`${shown(files, nm)} can't be entered`)
      isDir = false
    }
    if (!isDir) continue
    const scopes = files.list(nm)
    if (scopes === undefined) return stop(`${shown(files, nm)} can't be listed`)
    if (!scopes.includes(org)) continue
    const scope = join(nm, org)
    const names = files.list(scope)
    if (names === undefined) return stop(`${shown(files, scope)} can't be listed`)
    if (!names.includes(name)) continue
    const dir = join(scope, name)
    // It is there (listed): the package, or the end of the search.
    try {
      statSync(dir)
    } catch {
      throw new Error(`${shown(files, dir)} is there but can't be used (a dangling link, a cycle of links, or a directory that can't be entered); the search stops there`)
    }
    return dir
  }
  return undefined
}

// ── options ──────────────────────────────────────────────────

export interface NodeResolverOptions {
  /**
   * Where relative imports of the root file resolve from if it has no key,
   * the directory relative `packages` and `folders` are taken from, and
   * where the ids of files outside any npm project are taken from (default:
   * the working directory; `schemaOptions` and `readSchemaFile` use the
   * entry file's directory).
   */
  readonly base?: string
  /**
   * The build's root directory (spec §13.3, "The root"): relative imports
   * can't go above it with their `..` names (`import-outside-root`), and
   * messages show paths relative to it. It must contain the entry file.
   * Default: the directory of the entry file's real path (`schemaOptions`,
   * `readSchemaFile`), or `base`. A relative root is taken from the
   * directory of the entry file's real path (`nodeResolver`, which has no
   * entry file: from `base`). Widen it to share files across folders, such
   * as a repository's schema directory:
   *
   *   root: "../.."
   */
  readonly root?: string
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
const schemaText = (m: Manifest, files: Files): string | undefined => {
  if (!has(files, m.dir, PACKAGE_SCHEMA)) return undefined
  const got = files.read(join(m.dir, PACKAGE_SCHEMA), MAX_SCHEMA_BYTES)
  return got.kind === "file" ? got.text : undefined
}

/** Copies of one package: their package.haus and schema.haus are the same, byte for byte. */
const sameFiles = (a: Manifest, b: Manifest, files: Files): boolean => {
  if (a.dir === b.dir) return true
  const text = schemaText(a, files)
  return a.text === b.text && text !== undefined && text === schemaText(b, files)
}

const configError = (message: string): never => {
  throw new ModuleError("import-not-found", message)
}

/** The package directories and folder subdirectories given, checked when the resolver is set up. */
interface Given {
  readonly dirs: readonly string[]
  readonly named: readonly (readonly [string, string])[]
  /** Subdirectories of folders with a `package.haus`, and how they are named: the folder's last name and their own. */
  readonly scanned: readonly (readonly [string, string])[]
}

/** The names in the directory `dir`, at most `max`: more is `too-many-files`, without listing the rest (spec §13.3). */
const folderEntries = (dir: string, shownAs: string, max: number): string[] => {
  const names: string[] = []
  const d = opendirSync(dir)
  try {
    for (let e = d.readSync(); e !== null; e = d.readSync()) {
      names.push(e.name)
      if (names.length > max) throw new ModuleError("too-many-files", `the folder of packages ${shownAs} has more than ${max} entries`)
    }
  } finally {
    d.closeSync()
  }
  return names
}

/**
 * Check the packages and folders given (spec §13.3): a package directory
 * without `package.haus` or a folder that doesn't exist is a configuration
 * error (`import-not-found`), reported now and not at some import. A folder's
 * direct subdirectories (links to directories too) with a `package.haus` are
 * its packages; more than 4096 entries is `too-many-files`.
 */
const given = (base: string, options: NodeResolverOptions, files: Files): Given => {
  const packages = options.packages ?? []
  const named = Array.isArray(packages) ? [] : Object.entries(packages as Readonly<Record<string, string>>).map(([n, d]) => [n, resolve(base, d)] as const)
  const dirs = Array.isArray(packages) ? (packages as readonly string[]).map((d) => resolve(base, d)) : named.map(([, d]) => d)
  for (const dir of dirs) if (!has(files, real(dir), MANIFEST)) configError(`${shown(files, dir)} is not a schema package: it has no ${MANIFEST}`)
  const scanned = (options.folders ?? []).flatMap((f) => {
    const folder = resolve(base, f)
    let isDir = false
    try {
      isDir = statSync(folder).isDirectory()
    } catch {
      // Doesn't exist.
    }
    if (!isDir) return configError(`the folder of packages ${shown(files, folder)} doesn't exist`)
    // Its entries are named under its real path: `./schemas/` and a link to `schemas` are both `schemas` (spec §13.3).
    const realFolder = realpathSync(folder)
    return folderEntries(realFolder, shown(files, folder), MAX_FOLDER_ENTRIES)
      .sort()
      .map((entry) => [join(realFolder, entry), `${basename(realFolder)}/${entry}`] as const)
      .filter(([dir]) => {
        try {
          return statSync(dir).isDirectory() && has(files, real(dir), MANIFEST)
        } catch {
          return false
        }
      })
  })
  return { dirs, named, scanned }
}

/** Read the manifests of the packages given. A given directory's must be valid; a folder's invalid ones are noted. */
const explicitPackages = ({ dirs, named, scanned }: Given, files: Files): Explicit => {
  const clashes = new Map<string, string>()
  const add = (into: Map<string, Manifest>, manifest: Manifest) => {
    const first = into.get(manifest.name)
    if (first === undefined) into.set(manifest.name, manifest)
    else if (!clashes.has(manifest.name) && !sameFiles(first, manifest, files)) {
      clashes.set(manifest.name, `two packages are named ${manifest.name}: ${quoteText(first.version)} in ${shown(files, first.dir)} and ${quoteText(manifest.version)} in ${shown(files, manifest.dir)}`)
    }
  }
  const givenByName = new Map<string, Manifest>()
  for (const dir of dirs) add(givenByName, readManifest(join(dir, MANIFEST), files))
  const found = new Map<string, Manifest>()
  const invalid: string[] = []
  for (const [dir, name] of scanned) {
    // Named by the folder's last name and its own, in the reason too (spec §13.3).
    const skip = (why: string) => invalid.push(`${quoteText(name, Infinity)} (${why.replaceAll(shown(files, real(dir)), quoteText(name, Infinity))})`)
    let manifest: Manifest
    try {
      manifest = readManifest(join(dir, MANIFEST), files)
    } catch (e) {
      skip(e instanceof Error ? e.message : String(e))
      continue
    }
    // Another version in its package.json: skipped the same way (spec §13.3).
    const mismatch = versionMismatch(files, manifest, versionOf(lenientPackageJson(manifest.dir, files)))
    if (mismatch !== undefined) {
      skip(mismatch)
      continue
    }
    // A package given by its directory is used instead of one found in a folder.
    if (!givenByName.has(manifest.name)) add(found, manifest)
  }
  const misnamed = new Map<string, string>()
  for (const [name, dir] of named) {
    const m = readManifest(join(dir, MANIFEST), files)
    if (m.name !== name) misnamed.set(name, `${shown(files, dir)} holds the package ${m.name}, not ${name}`)
  }
  return { given: givenByName, found, clashes, misnamed, invalid }
}

// ── the resolver ─────────────────────────────────────────────

/** The `version` of a package.json, if it gives one. */
const versionOf = (npm: PackageJson): unknown => (npm.kind === "json" ? npm.json.version : undefined)

/** The `package-version` message if the package.json gives another version than the manifest (SHOULD, spec §13.3). Quoted only when it is a version. */
const versionMismatch = (files: Files, manifest: Manifest, npmVersion: unknown): string | undefined => {
  if (typeof npmVersion !== "string" || npmVersion === manifest.version) return undefined
  const theirs = SEMVER.test(npmVersion) ? `version ${quoteText(npmVersion)}` : "a version that is not a semantic version"
  return `${manifest.name}: its package.haus says version ${quoteText(manifest.version)}, its package.json ${theirs} (${shown(files, manifest.dir)})`
}

/**
 * The schema of the package in `manifest.dir`, imported as `module`, after
 * the checks of spec §13.3. With `strict` (a package the npm rules read: one
 * found in node_modules, or in a folder given, under npm), its package.json
 * is read as its other files are (a link is `package-path`); otherwise (a
 * package given by its directory, or no npm) it only gives a version, and one
 * that can't be read is ignored.
 */
const packageSchema = (manifest: Manifest, module: string, files: Files, strict: boolean): ResolvedModule => {
  if (manifest.name !== module) throw new Error(`${shown(files, manifest.dir)} holds the package ${manifest.name}, not ${module}`)
  const npmVersion = versionOf(strict ? readPackageJson(manifest.dir, files) : lenientPackageJson(manifest.dir, files))
  const mismatch = versionMismatch(files, manifest, npmVersion)
  if (mismatch !== undefined) throw new ModuleError("package-version", mismatch)
  const key = join(manifest.dir, PACKAGE_SCHEMA)
  const got = has(files, manifest.dir, PACKAGE_SCHEMA) ? files.read(key, MAX_SCHEMA_BYTES) : { kind: "missing" as const }
  if (got.kind === "missing") throw new Error(`${manifest.name} has no ${PACKAGE_SCHEMA} next to its manifest (${shown(files, manifest.dir)})`)
  if (got.kind === "link" || got.kind === "special") return notRegular(files, `${manifest.name}: its ${PACKAGE_SCHEMA}`, key, got)
  if (got.kind === "large") throw new ModuleError("file-too-large", `${manifest.name}: its ${PACKAGE_SCHEMA} is larger than ${MAX_SCHEMA_BYTES / 1024 / 1024} MiB. It is not read`)
  return {
    key,
    id: `${manifest.name}@${manifest.version.split(".")[0]}`,
    text: got.text,
    version: manifest.version,
    package: manifest.name,
    manifest: manifest.text,
    path: fromRoot(files.root, key),
  }
}

/**
 * Spec §13.3: the file `from` (a real path) declares `module`. A package's
 * schema.haus declares in its own package.json (read leniently for a package
 * given by its directory: `lenient`); other files in the nearest package.json
 * above them that has a `name` or a dependency field. Throws
 * `undeclared-package` when it doesn't. Checked before anything is looked for.
 */
const checkDeclared = (module: string, from: string, files: Files, lenient: (dir: string) => boolean): void => {
  const dir = dirname(from)
  const pkg = packageOf(from, files)
  if (pkg !== undefined) {
    const own = lenient(pkg.dir) ? lenientPackageJson(dir, files) : readPackageJson(dir, files)
    if (own.kind === "json" && DECLARING.some((f) => declares(own.json, f, module))) return
    throw new ModuleError(
      "undeclared-package",
      own.kind === "missing"
        ? `${pkg.name} imports ${module}, but it has no package.json to declare it: a package declares what it imports in its own package.json (peerDependencies)`
        : `${pkg.name} imports ${module}, which its package.json (${shown(files, join(dir, PACKAGE_JSON))}) doesn't declare: add it to its peerDependencies (or dependencies)`,
    )
  }
  for (const d of ancestors(dir)) {
    const p = readPackageJson(d, files)
    // Not a project's: valid JSON that isn't an object, or a marker such as { "type": "module" }.
    if (p.kind === "missing" || p.kind === "notObject") continue
    if (p.kind === "json" && !Object.hasOwn(p.json, "name") && !ALL_DEPENDENCIES.some((f) => Object.hasOwn(p.json, f))) continue
    if (p.kind === "json" && ALL_DEPENDENCIES.some((f) => declares(p.json, f, module))) return
    throw new ModuleError("undeclared-package", `${module} is imported by ${shown(files, from)}, but ${shown(files, join(d, PACKAGE_JSON))} doesn't declare it: add it to its dependencies`)
  }
  throw new ModuleError(
    "undeclared-package",
    `no package.json above ${shown(files, from)} declares ${module}: give the package explicitly (packages or folders, or haus.packages in the editor), or add it to the dependencies of a package.json`,
  )
}

/** How many `..` names a path starts with (grammar `path`: only at its start). */
const upCount = (module: string): number => /^(?:\.\.\/)*/.exec(module)![0].length / 3

/**
 * Finds packages given explicitly, in node_modules above the importing file's
 * real path (unless `npm: false`), and relative files inside the root
 * (`root`, default `base`). Throws a ModuleError (`import-not-found`,
 * `too-many-files`) when the packages or folders given don't exist.
 */
export function nodeResolver(options: NodeResolverOptions = {}): ModuleResolver {
  const base = resolve(options.base ?? process.cwd())
  return resolverReading(options, schemaFiles(rootDir(base, options.root, base), options.onOpen))
}

/** The real path of the `root` option (relative to `base`), or of `fallback`. A root option that isn't a directory is `import-not-found`. */
const rootDir = (base: string, root: string | undefined, fallback: string): string => {
  if (root === undefined) return real(fallback)
  const dir = resolve(base, root)
  let isDir = false
  try {
    isDir = statSync(dir).isDirectory()
  } catch {
    // Doesn't exist.
  }
  if (!isDir) throw new ModuleError("import-not-found", `the build's root (${quoteText(fromRoot(base, dir), Infinity)}) is not a directory`)
  return realpathSync(dir)
}

/** A Node resolver that reads with `files`, shared with whoever reads the entry file. */
const resolverReading = (options: NodeResolverOptions, files: Files): ModuleResolver => {
  const base = resolve(options.base ?? process.cwd())
  const npm = options.npm ?? true
  const setup = given(base, options, files)
  let explicit: Explicit | undefined
  const packages = (): Explicit => (explicit ??= explicitPackages(setup, files))
  const notFound = (message: string, ex: Explicit): never => {
    throw new Error(ex.invalid.length === 0 ? message : `${message}; these packages could not be read: ${ex.invalid.join(", ")}`)
  }
  const byDir = (dir: string) => [...packages().given.values()].some((m) => m.dir === dir)

  /**
   * The file a relative import names (spec §13.3, "Resolution"), checked in
   * the order of the spec (`packages.relative.check-order`): its syntax (the
   * grammar, checked when the importing file is read), `..` names above the
   * root, the walk down its names, a target in a package's directory, then
   * opening the file. A package's schema, which imports no files, is
   * rejected before them all. Only the entry file and the root are reached
   * through links; a relative import follows none.
   */
  const relativeFile = (module: string, origin: string | undefined): ResolvedModule => {
    // A package is one file: its schema imports other packages by name (spec §13.3).
    if (origin !== undefined && basename(origin) === PACKAGE_SCHEMA && has(files, dirname(origin), MANIFEST)) {
      throw new ModuleError("package-path", `the schema of ${packageName(dirname(origin), files)} can't import files, only packages by name`)
    }
    // The importing file's real directory: it was reached without links (or is the entry file, by its real path).
    const dir = origin ? dirname(origin) : real(base)
    const importer = origin ? shown(files, origin) : "the schema"
    const up = upCount(module)
    const start = resolve(dir, ...Array<string>(up).fill(".."))
    // Its `..` names stay in the root: checked on the text, before anything is looked at (spec §13.3, "The root").
    if (!inside(files.root, start)) {
      throw new ModuleError("import-outside-root", `${importer} imports ${module}, which goes above the build's root (the entry file's directory, or the root option)`)
    }
    const names = (module + EXTENSION).replace(/^\.\//, "").split("/").slice(up)
    const path = walkDown(start, names, files, `${importer} imports ${module}`)
    // An application's file doesn't reach into a package: it imports the package by name.
    for (const d of ancestors(dirname(path))) {
      if (!inside(files.root, d)) break
      const listed = files.list(d)
      // A directory that can't be listed can't show whether it is a package's: never passed as one that isn't.
      if (listed === undefined) throw new Error(`${importer} imports ${module}, and whether ${shown(files, d)} is a package's directory can't be checked (it can't be listed). It is not read`)
      if (listed.includes(MANIFEST)) throw new ModuleError("package-path", `the file is in the package directory ${shown(files, d)}: import the package by its name`)
    }
    const got = files.read(path, MAX_SCHEMA_BYTES)
    if (got.kind === "missing" || got.kind === "link") throw new Error(`file not found: ${shown(files, path)}`)
    if (got.kind === "special") throw new Error(`${shown(files, path)} is not a regular file. It is not read`)
    if (got.kind === "large") throw new ModuleError("file-too-large", `${shown(files, path)} is larger than ${MAX_SCHEMA_BYTES / 1024 / 1024} MiB. It is not read`)
    return { key: path, id: identify(path, base, files), text: got.text, path: fromRoot(files.root, path) }
  }

  return {
    resolve(module, from) {
      // The importing file's real path: lookups start there, as in Node.
      const origin = from === undefined ? undefined : real(from)
      if (module.startsWith("./") || module.startsWith("../")) return relativeFile(module, origin)
      const ex = packages()
      const clash = ex.clashes.get(module)
      if (clash !== undefined) throw new ModuleError("duplicate-package", clash)
      const own = ex.given.get(module)
      // A package given by its directory: its package.json is read leniently, also under npm (spec §13.3).
      if (own) return packageSchema(own, module, files, false)
      const wrong = ex.misnamed.get(module)
      if (wrong !== undefined) throw new Error(wrong)
      const inFolder = ex.found.get(module)
      if (!npm) return inFolder ? packageSchema(inFolder, module, files, false) : notFound(`package not found: ${module} is not among the packages given`, ex)
      const importer = origin ?? join(base, "_")
      // Given packages count as declared; others must be, before anything is looked for.
      if (inFolder === undefined) checkDeclared(module, importer, files, byDir)
      // As Node: the first node_modules/@org/name above the importing file's real path.
      const installed = installedPackage(module, importer, files)
      if (inFolder !== undefined) {
        // A package found in a folder doesn't replace an installed one with other files (spec §13.3).
        if (installed !== undefined && has(files, real(installed), MANIFEST)) {
          const m = readManifest(join(installed, MANIFEST), files)
          if (m.name === module && !sameFiles(m, inFolder, files)) {
            throw new ModuleError(
              "duplicate-package",
              `two packages are named ${module}: ${quoteText(m.version)} installed in ${shown(files, m.dir)} and ${quoteText(inFolder.version)} in the folder of packages (${shown(files, inFolder.dir)})`,
            )
          }
        }
        // Used under npm: read as the npm rules read a package there (spec §13.3).
        return packageSchema(inFolder, module, files, true)
      }
      if (installed === undefined) return notFound(`package not found (no node_modules/${module} above ${shown(files, dirname(importer))})`, ex)
      // The first one found is the package: no looking further up.
      if (!has(files, real(installed), MANIFEST)) throw new Error(`${shown(files, installed)} is not a schema package: it has no ${MANIFEST}`)
      return packageSchema(readManifest(join(installed, MANIFEST), files), module, files, true)
    },
  }
}

/** The options and files for the entry file at `path`: its real path, and the build's root, which must contain it. */
const entry = (path: string, options: NodeResolverOptions): { readonly key: string; readonly base: string; readonly files: Files } => {
  const key = real(path)
  const base = resolve(options.base ?? dirname(key))
  // A relative root option is taken from the entry file's real directory (spec §13.3, "The root").
  const root = rootDir(dirname(key), options.root, dirname(key))
  const files = schemaFiles(root, options.onOpen)
  if (!inside(root, key)) {
    // Both shown relative: the root from the entry file's directory, the entry file from the root.
    throw new ModuleError("import-outside-root", `the build's root (${quoteText(fromRoot(dirname(key), root), Infinity)} from the entry file's directory) doesn't contain the entry file (${shown(files, key)}): give a root that does`)
  }
  return { key, base, files }
}

const parseOptions = (key: string, base: string, files: Files, options: NodeResolverOptions): ParseSchemaOptions =>
  // One reader for the schema: the root's identity and every import (each file read once).
  ({ key, id: identify(key, base, files), resolver: resolverReading({ ...options, base: options.base ?? dirname(key) }, files) })

/**
 * Options for parseSchemaFile for the schema file at `path`: its key (real
 * path), identity and a Node resolver. Read the file itself with
 * readSchemaFile, which reads it as every file of the schema is read.
 * Throws a ModuleError: `import-outside-root` if a `root` given doesn't
 * contain the file, `import-not-found` if it isn't a directory.
 */
export function schemaOptions(path: string, options: NodeResolverOptions = {}): ParseSchemaOptions {
  const { key, base, files } = entry(path, options)
  return parseOptions(key, base, files, options)
}

/**
 * The schema file at `path` (the entry file) and the options to parse it
 * with (as schemaOptions): it is read as every file of the schema is (spec
 * §13.3, "Files read"), by its real path, a regular file of at most 1 MiB,
 * opened without blocking and checked on the open handle.
 *
 *   const { text, options } = readSchemaFile(path, { packages: ["../vendor/money"] })
 *   const file = parseSchemaFile(text, options)
 *
 * Throws a ModuleError: `import-not-found` if it isn't a regular file,
 * `file-too-large`, `invalid-utf8`, or as schemaOptions.
 */
export function readSchemaFile(path: string, options: NodeResolverOptions = {}): { readonly text: string; readonly options: ParseSchemaOptions } {
  const { key, base, files } = entry(path, options)
  const got = has(files, dirname(key), basename(key)) ? files.read(key, MAX_SCHEMA_BYTES) : { kind: "missing" as const }
  if (got.kind === "missing" || got.kind === "link") throw new ModuleError("import-not-found", `schema file not found: ${shown(files, key)}`)
  if (got.kind === "special") throw new ModuleError("import-not-found", `${shown(files, key)} is not a regular file. It is not read`)
  if (got.kind === "large") throw new ModuleError("file-too-large", `${shown(files, key)} is larger than ${MAX_SCHEMA_BYTES / 1024 / 1024} MiB. It is not read`)
  return { text: got.text, options: parseOptions(key, base, files, options) }
}
