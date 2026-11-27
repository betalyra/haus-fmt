/**
 * What generated `.haus` modules of the Effect target run, in Node or in a
 * browser bundle. It has no file system access: a schema file's sources were
 * read when the module was generated and travel with it; @haus-fmt/haus
 * compiles them (packages, rules), @haus-fmt/effect makes its schemas.
 */
import { parseWithLocations, type Package } from "@haus-fmt/haus/internal"
import * as Haus from "@haus-fmt/effect"
import { Effect } from "effect"
import { compiled as compiledCore, type SourcesData } from "./plain.js"
import { located } from "./shared.js"

/** Build the Effect schemas of a schema file, compiled from its sources: the packages' rules checks of their types. */
export function compiled(data: SourcesData, bundles: readonly Package[]): Haus.CompiledSchema {
  return Haus.fromSchema(compiledCore(data, bundles))
}

/** Unused by the Effect target's modules (its schemas are exported by name). */
export const type = (id: string) => id
export const stream = (id: string) => id

/** A data file's value decoded with its schema; throws with the position of the first error. */
export function decodeData(text: string, schema: Haus.CompiledSchemaFile, typeName: string, _stream: boolean, fileName: string): unknown {
  const root = schema.schemas[typeName]
  if (!root) throw new Error(`${fileName}: its schema file has no type ${typeName}`)
  const decode = Haus.decodeValue(root)
  const decoded = parseWithLocations(text).map((value) =>
    Effect.runSync(decode(value).pipe(Effect.mapError((e) => located(text, fileName, Haus.locateIssue(value, (e._tag === "HausSchemaError" && e.path) || []).start, e.message)))))
  if (schema.streams.has(typeName)) return decoded
  if (decoded.length !== 1) throw new Error(`${fileName}: expected exactly one value, found ${decoded.length}`)
  return decoded[0]
}
