/// <reference types="node" />
/**
 * Reading schema files and packages from the file system (Node): the only
 * step of the package layer that touches files (packages.md §2, "Reading is
 * separate from compiling"). Each function gives plain data, `Sources` and
 * `Package` values, which `Schema.compile` takes; compiling reads nothing.
 *
 *   const sources = await readSources("order.schema.haus", { packages: ["../vendor/acme"], folders: ["../schemas"] })
 *   const schema = Result.flatMap(sources, Schema.compile)
 *
 *   const acme = await readPackage("../vendor/acme")        // Result<Package, HausError>
 *   const folder = await readPackages("../schemas")         // Result<Folder, HausError>
 *
 * Nothing is looked for (packages.md §2): packages come only from the
 * directories and folders given, never from `node_modules`, a directory
 * above the schema, global locations or the network. The official packages
 * are built in and need no reading.
 *
 * The file rules of core §13.3 apply here:
 *
 * - The entry file's real path is read; relative imports stay inside the
 *   build's root (its directory, or the `root` option, relative to it): an
 *   import whose `..` names go above it is `import-outside-root`, before
 *   anything is looked at. Each name of a relative import must be listed by
 *   its directory with that spelling and must not be a symbolic link; a file
 *   inside a package's directory is `package-path`. Failures of relative
 *   imports are kept in the sources and reported at the import when compiling.
 * - Every file read is a regular file, opened without following a link at
 *   its last name and without blocking, checked on the open handle (type,
 *   size, the same file as `lstat` saw) and read from it, once: the entry
 *   file, relative imports, a package's `package.haus`, `schema.haus` and
 *   the `package.json` beside a package given explicitly (read leniently, for
 *   its version only). `package.haus` and `schema.haus` are spelled exactly.
 * - A package's rule documents (`rules/<name>.md`, packages.md §4) are looked
 *   at, not read: the package notes which it has, as regular files.
 *
 * Messages show paths relative to the root (or, for packages, to the
 * directory given's parent), never absolute ones.
 */
import { closeSync, constants, fstatSync, lstatSync, opendirSync, openSync, readSync, realpathSync, statSync, type BigIntStats } from "node:fs"
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path"
import { parseOptionsOf, sourcesOf, type Folder, type ReadFailure, type Sources } from "./compile.js"
import { HausPackageError, isHausError, type ErrorCode, type HausError } from "./errors.js"
import { MAX_MANIFEST_BYTES, MAX_SCHEMA_BYTES, packageOf, readManifest, SEMVER, type Package } from "./package.js"
import { Result } from "./result.js"
import { ModuleError, quoteText, schemaOutline, type ParseSchemaOptions } from "./schema-file.js"

/** A schema package's manifest. */
export const MANIFEST = "package.haus"
/** A schema package's schema file, next to its manifest. */
export const PACKAGE_SCHEMA = "schema.haus"
/** The largest package.json read, in bytes (spec §13.3). */
export const MAX_PACKAGE_JSON_BYTES = 1024 * 1024
/** The most entries a folder of packages may have (spec §13.3). */
export const MAX_FOLDER_ENTRIES = 4096
/** The most schema files of one schema, the entry file included (spec §13.3). */
const MAX_FILES = 256
const PACKAGE_JSON = "package.json"
const RULES = "rules"
const EXTENSION = ".schema.haus"

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

type Opened =
  | { readonly kind: "special" }
  | { readonly kind: "file"; readonly size: bigint; readonly text: string | undefined }

/** What one read reads: files, by real path, each opened at most once whatever roles it has (spec §13.3), and directory listings. */
interface Files {
  read(path: string, limit: number): Read
  list(dir: string): readonly string[] | undefined
  /** The directory messages show paths from (a real path). */
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
 * (spec §13.3, "Files read"): `lstat` it, open it with O_NOFOLLOW, O_NONBLOCK
 * and O_NOCTTY, check on the open handle that it is the regular file `lstat`
 * saw (device and inode), then read from the handle. Where O_NOFOLLOW doesn't
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
    if (stats.ino !== before.ino || stats.dev !== before.dev) return NOFOLLOW === undefined ? { kind: "link" } : { kind: "special" }
    if (!stats.isFile()) return { kind: "special" }
    if (stats.size > BigInt(MAX_READ)) return { kind: "file", size: stats.size, text: undefined }
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

/** The files of one read, messages relative to `root` (a real path). `onOpen` is called with the real path of each file opened. */
const filesFrom = (root: string, onOpen?: (path: string) => void): Files => {
  const opened = new Map<string, Opened>()
  const listings = new Map<string, readonly string[] | undefined>()
  const files: Files = {
    root,
    read(path, limit) {
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

/** `dir` lists `name`, spelled so (spec §13.3, "Spelling"). */
const has = (files: Files, dir: string, name: string): boolean => files.list(dir)?.includes(name) ?? false

/** The real path of `path` when it exists, else `path` made absolute. */
const real = (path: string): string => {
  try {
    return realpathSync(path)
  } catch {
    return resolve(path)
  }
}

/** `path` is `dir` or inside it (both real, absolute), compared by names. */
const inside = (dir: string, path: string): boolean => path === dir || path.startsWith(dir.endsWith(sep) ? dir : dir + sep)

const ancestors = function* (dir: string): Generator<string> {
  for (let d = dir; ; d = dirname(d)) {
    yield d
    if (dirname(d) === d) return
  }
}

const notRegular = (files: Files, what: string, path: string, read: Read): never => {
  throw new ModuleError(
    "package-path",
    read.kind === "link"
      ? `${what} ${shown(files, path)} is a symbolic link: a package's files must be regular files, not links. It is not read`
      : `${what} ${shown(files, path)} is not a regular file. It is not read`,
  )
}

// ── packages ─────────────────────────────────────────────────

/** The `version` of the package.json beside a package's manifest, read leniently (packages.md §4): one that can't be read gives none. */
const packageJsonVersion = (dir: string, files: Files): unknown => {
  if (!has(files, dir, PACKAGE_JSON)) return undefined
  const got = files.read(join(dir, PACKAGE_JSON), MAX_PACKAGE_JSON_BYTES)
  if (got.kind !== "file") return undefined
  try {
    const json: unknown = JSON.parse(got.text)
    return typeof json === "object" && json !== null && !Array.isArray(json) ? (json as Record<string, unknown>).version : undefined
  } catch {
    return undefined
  }
}

/** The `package-version` message if the package.json gives another version than the manifest, quoted only when it is a version. */
const versionMismatch = (p: { readonly name: string; readonly version: string }, npmVersion: unknown, where: string): string | undefined => {
  if (typeof npmVersion !== "string" || npmVersion === p.version) return undefined
  const theirs = SEMVER.test(npmVersion) ? `version ${quoteText(npmVersion)}` : "a version that is not a semantic version"
  return `${p.name}: its package.haus says version ${quoteText(p.version)}, its package.json ${theirs} (${where})`
}

/** The rule documents of the package in `dir`: each `rules/<name>.md` listed with that spelling, a regular file (not a link). */
const ruleDocuments = (dir: string, files: Files): ReadonlySet<string> => {
  if (!has(files, dir, RULES)) return new Set()
  const rulesDir = join(dir, RULES)
  try {
    if (lstatSync(rulesDir).isSymbolicLink()) return new Set()
  } catch {
    return new Set()
  }
  const names = files.list(rulesDir) ?? []
  return new Set(names.filter((n) => n.endsWith(".md")).filter((n) => {
    try {
      return lstatSync(join(rulesDir, n)).isFile()
    } catch {
      return false
    }
  }).map((n) => n.slice(0, -3)))
}

/**
 * The package in the real directory `dir` (core §13.3): its manifest and
 * schema, regular files of at most 64 KiB and 1 MiB, spelled exactly; a
 * package.json beside it whose version differs is `package-version`
 * (packages.md §4). Throws ModuleError or HausPackageError; `shownAs` names
 * the directory in messages.
 */
const packageIn = (dir: string, files: Files, shownAs: string, origin: "directory" | "folder"): Package => {
  const manifestPath = join(dir, MANIFEST)
  const got = has(files, dir, MANIFEST) ? files.read(manifestPath, MAX_MANIFEST_BYTES) : { kind: "missing" as const }
  if (got.kind === "missing") throw new ModuleError("import-not-found", `${shownAs} is not a schema package: it has no ${MANIFEST}`)
  if (got.kind === "link" || got.kind === "special") return notRegular(files, "the manifest", manifestPath, got)
  if (got.kind === "large") throw new ModuleError("package-manifest", `${shownAs}/${MANIFEST} is not a valid manifest: it is larger than ${MAX_MANIFEST_BYTES / 1024} KiB`)
  const manifest = readManifest(got.text, `${shownAs}/${MANIFEST}`)
  const mismatch = versionMismatch(manifest, packageJsonVersion(dir, files), shownAs)
  if (mismatch !== undefined) throw new ModuleError("package-version", mismatch)
  const schemaPath = join(dir, PACKAGE_SCHEMA)
  const schema = has(files, dir, PACKAGE_SCHEMA) ? files.read(schemaPath, MAX_SCHEMA_BYTES) : { kind: "missing" as const }
  if (schema.kind === "missing") throw new ModuleError("import-not-found", `${manifest.name} has no ${PACKAGE_SCHEMA} next to its manifest (${shownAs})`)
  if (schema.kind === "link" || schema.kind === "special") return notRegular(files, `${manifest.name}: its ${PACKAGE_SCHEMA}`, schemaPath, schema)
  if (schema.kind === "large") throw new ModuleError("file-too-large", `${manifest.name}: its ${PACKAGE_SCHEMA} is larger than ${MAX_SCHEMA_BYTES / 1024 / 1024} MiB. It is not read`)
  return packageOf({ manifest: got.text, schema: schema.text }, { kind: origin, path: shownAs }, ruleDocuments(dir, files))
}

/** A thrown read error as a HausError. */
const asHausError = (e: unknown): HausError | undefined =>
  isHausError(e) ? e : e instanceof ModuleError ? new HausPackageError(e.message, e.code) : e instanceof Error && !(e instanceof TypeError || e instanceof RangeError) ? new HausPackageError(e.message, "import-not-found") : undefined

/** `run()`, every read error as a Result's failure (a HausError); anything else (a bug) is thrown on. */
const readingNow = <A>(run: () => A): Result<A, HausError> => {
  try {
    return Result.succeed(run())
  } catch (e) {
    const failure = asHausError(e)
    if (failure === undefined) throw e
    return Result.fail(failure)
  }
}

/** `readingNow`, as a Promise that rejects only for a bug. */
const reading = <A>(run: () => A): Promise<Result<A, HausError>> => {
  try {
    return Promise.resolve(readingNow(run))
  } catch (e) {
    return Promise.reject(e)
  }
}

/** A directory given (a package, or a folder of packages), resolved against `base`. */
const givenDirectory = (base: string, path: string, files: Files, what: string): string => {
  const dir = resolve(base, path)
  let isDir = false
  try {
    isDir = statSync(dir).isDirectory()
  } catch {
    // Doesn't exist.
  }
  if (!isDir) throw new ModuleError("import-not-found", `the ${what} ${shown(files, dir)} doesn't exist`)
  return realpathSync(dir)
}

/**
 * Read the schema package in the directory `dir` (core §13.3, packages.md
 * §2): its manifest, schema and rule documents, and the version of a
 * package.json beside it. A package value, with no rules of its own: add
 * them with `Package.withRule`.
 */
export const readPackage = (dir: string): Promise<Result<Package, HausError>> =>
  reading(() => {
    const files = filesFrom(dirname(real(resolve(dir))))
    const at = givenDirectory(process.cwd(), dir, files, "package directory")
    return packageIn(at, files, shown(files, at), "directory")
  })

/** The names in the directory `dir`, at most `max`: more is `too-many-files` (spec §13.3). */
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
 * The packages of a folder (packages.md §2): each direct subdirectory with a
 * `package.haus`. One whose manifest can't be read or whose package.json
 * gives another version is skipped, and named (by the folder's last name and
 * its own) when an import isn't found.
 */
const folderIn = (folder: string, files: Files): Folder => {
  const name = basename(folder)
  const packages: Package[] = []
  const skipped: string[] = []
  const entries = folderEntries(folder, shown(files, folder), MAX_FOLDER_ENTRIES).sort()
  for (const entry of entries) {
    const dir = join(folder, entry)
    try {
      if (!statSync(dir).isDirectory() || !has(files, real(dir), MANIFEST)) continue
    } catch {
      continue
    }
    const shownAs = `${name}/${entry}`
    try {
      packages.push(packageIn(real(dir), files, quoteText(shownAs, Infinity), "folder"))
    } catch (e) {
      if (!(e instanceof Error)) throw e
      skipped.push(`${quoteText(shownAs, Infinity)} (${e.message})`)
    }
  }
  return { path: shown(files, folder), packages, skipped }
}

/** Read a folder of packages (packages.md §2): its packages, and the subdirectories skipped. */
export const readPackages = (folder: string): Promise<Result<Folder, HausError>> =>
  reading(() => {
    const files = filesFrom(dirname(real(resolve(folder))))
    return folderIn(givenDirectory(process.cwd(), folder, files, "folder of packages"), files)
  })

// ── sources ──────────────────────────────────────────────────

export interface ReadSourcesOptions {
  /**
   * The build's root (core §13.3, "The root"), relative to the entry file's
   * directory: relative imports can't go above it. Default: the entry
   * file's directory. It must contain the entry file.
   */
  readonly root?: string
  /** Package directories given explicitly (packages.md §2), relative to the working directory. */
  readonly packages?: readonly string[]
  /** Folders of packages, relative to the working directory: each subdirectory with a `package.haus` is a package. */
  readonly folders?: readonly string[]
  /** Called with the real path of each file opened (each once): for tests and tools that list what a schema read. */
  readonly onOpen?: (path: string) => void
}

/** How many `..` names a path starts with (grammar `path`: only at its start). */
const upCount = (module: string): number => /^(?:\.\.\/)*/.exec(module)![0].length / 3

/**
 * The walk down a relative import's names from the real directory `dir`
 * (spec §13.3): each name listed by its directory with that spelling, none a
 * symbolic link, each but the last a directory. The path reached has no links.
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

/** The text of the schema file at `path` (a regular file of at most 1 MiB), else the error of an import of it. */
const schemaFileText = (path: string, files: Files, code: ErrorCode = "import-not-found"): string => {
  const got = files.read(path, MAX_SCHEMA_BYTES)
  if (got.kind === "missing" || got.kind === "link") throw new ModuleError(code, `file not found: ${shown(files, path)}`)
  if (got.kind === "special") throw new ModuleError(code, `${shown(files, path)} is not a regular file. It is not read`)
  if (got.kind === "large") throw new ModuleError("file-too-large", `${shown(files, path)} is larger than ${MAX_SCHEMA_BYTES / 1024 / 1024} MiB. It is not read`)
  return got.text
}

/**
 * Read a schema (core §13.3, packages.md §2): the entry file at `path`, the
 * files it imports relatively (each once, inside the build's root, following
 * no link), and the packages and folders of packages given. Gives `Sources`
 * for `Schema.compile`. A relative import that can't be read is kept and
 * reported at the import when compiling; the entry file, a root that doesn't
 * contain it, and a package or folder given that can't be read fail here.
 */
export const readSources = (path: string, options: ReadSourcesOptions = {}): Promise<Result<Sources, HausError>> => reading(() => sourcesAt(path, options))

/** `readSources`, synchronously: for tools that must answer at once (a TypeScript content mapper, a Node loader hook). */
export const readSourcesSync = (path: string, options: ReadSourcesOptions = {}): Result<Sources, HausError> => readingNow(() => sourcesAt(path, options))

/**
 * @internal For first-party tools and tests: the schema file at `path` read
 * with its sources, and the options to parse it with (`parseSchemaFile`),
 * its imports answered as a compile answers them. Throws the read's HausError.
 */
export const schemaFileAt = (path: string, options: ReadSourcesOptions = {}): { readonly text: string; readonly options: ParseSchemaOptions } => {
  const sources = readSourcesSync(path, options)
  if (sources._tag === "Failure") throw sources.failure
  return parseOptionsOf(sources.success)
}

const sourcesAt = (path: string, options: ReadSourcesOptions): Sources => {
  {
    const key = real(path)
    const entryDir = dirname(key)
    const root = options.root === undefined ? entryDir : givenDirectory(entryDir, options.root, filesFrom(entryDir), "build's root")
    const files = filesFrom(root, options.onOpen)
    if (!inside(root, key)) {
      throw new ModuleError("import-outside-root", `the build's root (${quoteText(fromRoot(entryDir, root), Infinity)} from the entry file's directory) doesn't contain the entry file (${shown(files, key)}): give a root that does`)
    }
    if (!has(files, entryDir, basename(key))) throw new ModuleError("import-not-found", `schema file not found: ${shown(files, key)}`)
    const texts = new Map<string, string>()
    const failures = new Map<string, ReadFailure>()
    const entry = fromRoot(root, key)
    texts.set(entry, schemaFileText(key, files))
    // A package's schema.haus as the entry: its id is the package's, and it imports no files.
    const isPackageSchema = (p: string) => basename(p) === PACKAGE_SCHEMA && has(files, dirname(p), MANIFEST)
    let id: string | undefined
    if (isPackageSchema(key)) {
      try {
        const m = readManifest(schemaFileText(join(entryDir, MANIFEST), files, "package-manifest"), `${shown(files, entryDir)}/${MANIFEST}`)
        id = `${m.name}@${m.version.split(".")[0]}`
      } catch {
        // An unreadable manifest: the file is read as a file.
      }
    }
    // Every relative import, breadth first, from the real path of the file that imports it.
    const queue: string[] = [key]
    const seen = new Set<string>([key])
    while (queue.length > 0) {
      const from = queue.shift()!
      const fromKey = fromRoot(root, from)
      let imports: readonly string[]
      try {
        imports = schemaOutline(texts.get(fromKey)!).imports.map((i) => i.module).filter((m) => m.startsWith("./") || m.startsWith("../"))
      } catch {
        continue // a syntax error: the compile reports it
      }
      for (const module of imports) {
        const failure = (e: unknown): void => {
          if (!(e instanceof Error) || e instanceof TypeError || e instanceof RangeError) throw e
          failures.set(`${fromKey}\0${module}`, { code: e instanceof ModuleError ? e.code : undefined, message: e.message })
        }
        try {
          if (isPackageSchema(from)) {
            throw new ModuleError("package-path", `the schema of a package can't import files, only packages by name`)
          }
          const up = upCount(module)
          const start = resolve(dirname(from), ...Array<string>(up).fill(".."))
          const importer = shown(files, from)
          if (!inside(root, start)) throw new ModuleError("import-outside-root", `${importer} imports ${module}, which goes above the build's root (the entry file's directory, or the root option)`)
          const names = (module + EXTENSION).replace(/^\.\//, "").split("/").slice(up)
          const target = walkDown(start, names, files, `${importer} imports ${module}`)
          // An application's file doesn't reach into a package: it imports the package by name.
          for (const d of ancestors(dirname(target))) {
            if (!inside(root, d)) break
            const listed = files.list(d)
            if (listed === undefined) throw new Error(`${importer} imports ${module}, and whether ${shown(files, d)} is a package's directory can't be checked (it can't be listed). It is not read`)
            if (listed.includes(MANIFEST)) throw new ModuleError("package-path", `the file is in the package directory ${shown(files, d)}: import the package by its name`)
          }
          if (seen.has(target)) continue
          if (seen.size >= MAX_FILES) throw new ModuleError("too-many-files", `more than ${MAX_FILES} schema files are imported`)
          texts.set(fromRoot(root, target), schemaFileText(target, files))
          seen.add(target)
          queue.push(target)
        } catch (e) {
          failure(e)
        }
      }
    }
    // Packages given by their directory, and folders of packages (packages.md §2), relative to the working directory.
    const base = process.cwd()
    const packages = (options.packages ?? []).map((p) => {
      const dir = givenDirectory(base, p, files, "package directory")
      if (!has(files, dir, MANIFEST)) throw new ModuleError("import-not-found", `${shown(files, dir)} is not a schema package: it has no ${MANIFEST}`)
      return packageIn(dir, files, shown(files, dir), "directory")
    })
    const folders = (options.folders ?? []).map((f) => folderIn(givenDirectory(base, f, files, "folder of packages"), files))
    return sourcesOf({ entry, files: texts, id, failures, packages, folders })
  }
}
