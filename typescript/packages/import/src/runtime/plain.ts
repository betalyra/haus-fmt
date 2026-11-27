/**
 * What generated `.haus` modules of the plain target run, in Node or in a
 * browser bundle: @haus-fmt/haus, no other dependencies and no file system.
 * A schema file's sources were read when the module was generated and travel
 * with it; the bundles it was given are imported by the module itself.
 */
import { h, Package, parseWithLocations, Schema, Sources, type Package as PackageValue, type Schema as SchemaValue, type Value } from "@haus-fmt/haus/internal"
import { Type } from "@haus-fmt/haus"
import { registerCodecs, type Factory } from "@haus-fmt/haus/codegen"
import { located } from "./shared.js"

/** The sources of a schema file as the module carries them (no absolute paths), and the packages read from directories. */
export interface SourcesData {
  readonly entry: string
  readonly files: Readonly<Record<string, string>>
  readonly id?: string
  readonly packages: readonly { readonly manifest: string; readonly schema: string }[]
}

/** The schema of a schema file, compiled from the sources read when the module was generated, with the bundles given. */
export function compiled(data: SourcesData, bundles: readonly PackageValue[]): SchemaValue {
  const fail = (e: { readonly message: string }): never => {
    throw new Error(`@haus-fmt/import: ${data.entry} no longer compiles as it did when this module was generated: ${e.message}`)
  }
  const sources = Sources.make(data.entry, data.files, data.id === undefined ? {} : { id: data.id })
  if (sources._tag === "Failure") return fail(sources.failure)
  const given = [...data.packages.map((p) => {
    const made = Package.make(p)
    return made._tag === "Failure" ? fail(made.failure) : made.success
  }), ...bundles]
  const schema = Schema.compile(given.reduce((s, p) => Sources.withPackage(s, p), sources.success))
  return schema._tag === "Failure" ? fail(schema.failure) : schema.success
}

/** The handle of a type of the schema file. */
export const type = (id: string) => Type.make(id)
/** The handle of a stream type of the schema file. */
export const stream = (id: string) => Type.stream(id)

/**
 * The generated codecs @haus-fmt/import built for the types `types` of the
 * schema file (`source`, made into `factory`). Those types are marked as
 * `Schema.optimize` marks them, so the code is used, without `eval`.
 */
export function prebuilt(schema: SchemaValue, types: readonly string[], source: string, factory: Factory): void {
  // The engine's schemas of the file's own types, as one group (codegen.ts): the record the code was generated for.
  const engine = schema.engine().schemas
  registerCodecs(engine, types, source, factory)
  for (const t of types) if (Object.hasOwn(engine, t)) h.optimize(engine[t]!)
}

/** The place of a decode error's path inside a parsed value. */
function locate(value: Value, path: readonly (string | number)[]): number | undefined {
  let at: Value | undefined = value
  for (const seg of path) {
    if (!at) break
    if (at.kind === "record") at = at.fields.get(String(seg))
    else if (at.kind === "array") at = typeof seg === "number" ? at.items[seg] : undefined
    else if (at.kind === "variant") at = typeof seg === "number" ? at.args[seg] : at.args[0]?.kind === "record" ? at.args[0].fields.get(seg) : undefined
    else at = undefined
    if (at?.start === undefined) break
    value = at
  }
  return value.start
}

/** A data file's value decoded with its schema's type `id`; throws with the position of the first error. */
export function decodeData(text: string, schema: SchemaValue, id: string, stream: boolean, fileName: string): unknown {
  const type = Type.make(id)
  const decoded = parseWithLocations(text).map((value) => {
    const r = Schema.decodeValue(schema, type, value)
    if (r._tag === "Success") return r.success
    const e = r.failure
    throw located(text, fileName, locate(value, "path" in e ? e.path : []), e.message)
  })
  if (stream) return decoded
  if (decoded.length !== 1) throw new Error(`${fileName}: expected exactly one value, found ${decoded.length}`)
  return decoded[0]
}
