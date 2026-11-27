/**
 * Data files and their schema files, for both targets: which schema a data
 * file has, the declarations of a data file checked against it, and the
 * module source that compiles a schema file's schema at runtime from the
 * sources read now (no file system at runtime).
 */
import { existsSync } from "node:fs"
import { basename, dirname, join, relative } from "node:path"
import { fileURLToPath } from "node:url"
import { readSourcesSync } from "@haus-fmt/haus/node"
import { checkData, definitionDoc, fromSchemaFile, HausSyntaxError, isHausError, parseWithLocations, Schema, Sources, type Schema as SchemaValue } from "@haus-fmt/haus/internal"
import { generateCodecs } from "@haus-fmt/haus/codegen"
import { isSchemaFile } from "@haus-fmt/haus/node"
import type { Backend } from "./generate.js"
import { unwrap } from "./generate.js"

export interface Diagnostic {
  readonly message: string
  readonly offset: number
  readonly length: number
}

/** The schema of a data file: the file and the type that describes the whole file. */
export interface SchemaLink {
  readonly path: string
  readonly type: string
}

/**
 * The schema for a data file, if it has one: `Root` of the `.schema.haus`
 * file next to it. A data file never names its schema (spec §14).
 */
export function schemaFor(dataFile: string): SchemaLink | undefined {
  if (isSchemaFile(dataFile)) return undefined
  const path = dataFile.replace(/\.haus$/, ".schema.haus")
  return existsSync(path) ? { path, type: "Root" } : undefined
}

/**
 * Where declarations import a library's types from (`@haus-fmt/haus`): its
 * name when the file's project has it, otherwise the copy this package uses
 * (by absolute path). The library, not a schema package: those are never looked for.
 */
export function specifier(fileName: string, pkg: string): string {
  const name = pkg.split("/").slice(0, pkg.startsWith("@") ? 2 : 1)
  for (let dir = dirname(fileName); ; dir = dirname(dir)) {
    if (existsSync(join(dir, "node_modules", ...name, "package.json"))) return pkg
    if (dirname(dir) === dir) break
  }
  return fileURLToPath(import.meta.resolve(pkg))
}

const RESERVED = new Set(["default", "class", "function", "var", "let", "const", "new", "delete", "enum", "export", "import", "in", "this", "void", "with", "yield", "await"])

/** `user-update.haus` → `userUpdate`, a name for hovers. */
export const identifier = (fileName: string): string => {
  const stem = basename(fileName).replace(/\.haus$/, "")
  const camel = stem.replace(/[^A-Za-z0-9]+(.)?/g, (_, c: string | undefined) => (c ? c.toUpperCase() : ""))
  return /^[A-Za-z_$]/.test(camel) && !RESERVED.has(camel) ? camel : `_${camel}`
}

/** The schema file read and compiled now, with the files read (to watch). Throws its HausError. */
const compiled = (schemaPath: string, b: Backend): { readonly schema: SchemaValue; readonly files: string[]; readonly data: SourcesData } => {
  const files: string[] = []
  const read = unwrap(readSourcesSync(schemaPath, { packages: b.packages.packages, folders: b.packages.folders, ...(b.packages.root === undefined ? {} : { root: b.packages.root }), onOpen: (p) => files.push(p) }))
  const sources = b.bundles.reduce((s, bundle) => Sources.withPackage(s, bundle.package), read)
  const schema = unwrap(Schema.compile(sources))
  // Packages read from directories travel as their texts; bundles are imported by the module; official ones are built in.
  const packages = [...schema.packages.values()]
    .filter((p) => p.origin.kind === "directory" || p.origin.kind === "folder")
    .map((p) => ({ manifest: p.manifest, schema: p.schema }))
  return { schema, files, data: { entry: read.entry, files: Object.fromEntries(read.files), ...(read.id === undefined ? {} : { id: read.id }), packages } }
}

/** What a generated module compiles at runtime: the sources as plain data (no absolute paths) and the packages read. */
export interface SourcesData {
  readonly entry: string
  readonly files: Readonly<Record<string, string>>
  readonly id?: string
  readonly packages: readonly { readonly manifest: string; readonly schema: string }[]
}

/** Declarations for a data file with a schema, plus where the data doesn't match it. */
export function dataModule(text: string, fileName: string, link: SchemaLink, b: Backend): { text: string; diagnostics: Diagnostic[] } {
  const name = identifier(fileName)
  const schemaName = basename(link.path)
  const fallback = (message: string) => ({
    text: `declare const ${name}: unknown;\nexport default ${name};\n`,
    diagnostics: [{ message, offset: 0, length: 1 }],
  })
  if (!existsSync(link.path)) return fallback(`schema file not found: ${link.path}`)
  let schema: SchemaValue
  try {
    schema = compiled(link.path, b).schema
  } catch (e) {
    if (isHausError(e)) return fallback(`${schemaName}: ${e.message}`)
    throw e
  }
  const file = schema.file
  const definition = file.definition(link.type)
  if (!definition || definition.params.length > 0) return fallback(`${schemaName} has no type ${link.type} (without parameters) to describe the whole file`)
  const values = parseWithLocations(text)
  const path = relative(dirname(fileName), link.path).replaceAll("\\", "/")
  const type = definition.template.stream ? `ReadonlyArray<${link.type}>` : link.type
  const doc = definitionDoc(definition, `${basename(fileName)}, checked against ${schemaName}:\n\n`)
  const diagnostics = checkData(file, link.type, values)
    .filter((i) => i.severity === "error")
    .map((i) => ({ message: `${i.message} (${schemaName}: ${link.type})`, offset: i.start, length: i.end - i.start }))
  return {
    text: `import type { ${link.type} } from ${JSON.stringify(path.startsWith(".") ? path : `./${path}`)};\n${doc}declare const ${name}: ${type};\nexport default ${name};\n`,
    diagnostics,
  }
}

// ── runtime modules ──────────────────────────────────────────

/** The imports of the bundles (`b0`, `b1`, …) and the expression of their list. */
const bundleImports = (b: Backend): { readonly code: string; readonly list: string } => ({
  code: b.bundles.map((bundle, i) => (bundle.name === "default" ? `import b${i} from ${JSON.stringify(bundle.module)};\n` : `import { ${bundle.name} as b${i} } from ${JSON.stringify(bundle.module)};\n`)).join(""),
  list: `[${b.bundles.map((_, i) => `b${i}`).join(", ")}]`,
})

/** Module source that compiles a schema file's schema at runtime (`const schema = …`), and the files it was built from. */
function schemaModule(schemaPath: string, runtime: string, b: Backend): { code: string; files: string[]; schema: SchemaValue } {
  const { schema, files, data } = compiled(schemaPath, b)
  const bundles = bundleImports(b)
  return {
    code: `import { compiled, type, stream } from ${JSON.stringify(runtime)};\n${bundles.code}` +
      `const schema = compiled(${JSON.stringify(data)}, ${bundles.list});\n`,
    files,
    schema,
  }
}

/**
 * The generated codecs of the types `optimize` (and the types they reach),
 * generated now (no `eval` at runtime): `prebuilt(schema, types, source,
 * factory)`. Empty if nothing is generated.
 */
function prebuiltCodecs(schema: SchemaValue, optimize: readonly string[]): string {
  const { schemas } = fromSchemaFile(schema.file, { rules: schema.rules })
  const source = generateCodecs(schemas, optimize)
  if (source === undefined) return ""
  return `prebuilt(schema, ${JSON.stringify(optimize)}, ${JSON.stringify(source)}, function (rt, env) {\n${source}});\n`
}

/**
 * Module source for a `.schema.haus` file (plain target): the compiled
 * `schema` and a handle per type without parameters; the generated codecs
 * of the types `optimize`, generated now. The Effect target: its schemas.
 */
export function schemaModuleSource(path: string, runtime: string, b: Backend, optimize: readonly string[] = []): { code: string; files: string[] } {
  const { code, files, schema } = schemaModule(path, runtime, b)
  const own = schema.file.definitions.filter((d) => d.params.length === 0)
  if (b.target === "effect") return { code: code + own.map((d) => `export const ${d.name} = schema.schemas[${JSON.stringify(d.name)}];\n`).join(""), files }
  const prebuilt = optimize.length > 0 ? prebuiltCodecs(schema, optimize) : ""
  const header = prebuilt === "" ? "" : `import { prebuilt } from ${JSON.stringify(runtime)};\n`
  const handles = own.map((d) => `export const ${d.name} = ${d.template.stream ? "stream" : "type"}(${JSON.stringify(d.id)});\n`).join("")
  return { code: header + code + prebuilt + "export { schema };\n" + handles, files }
}

/** Module source for a data file with a schema: decoded with it when the module loads. */
export function dataModuleSource(text: string, fileName: string, link: SchemaLink, runtime: string, b: Backend): { code: string; files: string[] } {
  const { code, files, schema } = schemaModule(link.path, runtime, b)
  const d = schema.file.definition(link.type)
  if (d === undefined) throw new HausSyntaxError(`${basename(link.path)} has no type ${link.type} to describe the whole file`, 0, 1, 1, "unknown-type")
  return {
    code: code + `import { decodeData } from ${JSON.stringify(runtime)};\nexport default decodeData(${JSON.stringify(text)}, schema, ${JSON.stringify(b.target === "effect" ? d.name : d.id)}, ${d.template.stream}, ${JSON.stringify(basename(fileName))});\n`,
    files,
  }
}
