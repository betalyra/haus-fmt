/**
 * The Effect target's declarations for a `.schema.haus` file: its types and
 * their Effect schemas. Loaded only when a project uses the Effect target.
 */
import type { SchemaFile } from "@haus-fmt/haus/internal"
import * as Haus from "@haus-fmt/effect"
import { specifier } from "./schemas.js"

export function effectSchemaTypes(file: SchemaFile, fileName: string): string {
  return Haus.schemaDeclarations(file, {
    effect: specifier(fileName, "effect"),
    haus: specifier(fileName, "@haus-fmt/effect"),
  })
}
