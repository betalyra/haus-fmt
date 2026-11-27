/**
 * Which ids codecs may name (spec §13.4, packages.md §7): the built-in
 * types' (`prelude#Decimal`, `std/time#Instant`) and those of the schema's
 * files and packages. A codec for an id no type has never runs: the warning
 * `unused-codec`.
 */
import { BUILTINS, PRELUDE_ARITY, STD_MODULES, type SchemaFile } from "./schema-file.js"

/** A warning about the codecs set (packages.md §7): `unused-codec`, a codec for an id that no type has. */
export interface CodecWarning {
  readonly code: "unused-codec"
  /** The codec's id: `@haus-fmt/money@2#Money`. */
  readonly id: string
  readonly message: string
}

/** The ids of the prelude's types and the standard modules' (`prelude#Decimal`, `std/time#Instant`). */
export const BUILT_IN_TYPE_IDS: ReadonlySet<string> = new Set([
  ...BUILTINS.map((name) => `prelude#${name}`),
  ...Object.keys(PRELUDE_ARITY).map((name) => `prelude#${name}`),
  ...Object.entries(STD_MODULES).flatMap(([module, names]) => names.map((name) => `${module}#${name}`)),
])

/**
 * The warning `unused-codec` for each codec id that no type has (packages.md
 * §7): not one of the prelude or a standard module, nor of the file and the
 * files and packages it imports. Such a codec never runs: a typo, or the
 * wrong major version (`@haus-fmt/money@2#Money` with a schema that imports
 * major 1).
 */
export const unusedCodecs = (file: SchemaFile, ids: Iterable<string>): CodecWarning[] =>
  [...ids]
    .filter((id) => !BUILT_IN_TYPE_IDS.has(id) && !file.typeIds.has(id))
    .map((id) => ({ code: "unused-codec", id, message: `a codec is set for ${id}, but no type has that id: it never runs` }))
