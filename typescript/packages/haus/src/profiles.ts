/**
 * Official profiles without their codecs (spec §13.4, "A profile without its
 * codec"). A package's rule is checked only where a codec applies it, so a
 * schema that reaches `Currency` without the `iso` codec checks currencies
 * for their shape only. That is allowed, and never an error, but it shouldn't
 * be silent:
 *
 * - `missingCodecs(file, ids)`: for a binding that knows the codecs set, the
 *   warning `missing-codec` once per type id (`compileSchemaFile` reports them
 *   in `CompiledSchemaFile.warnings`);
 * - `uncheckedProfiles(text)`: for tools without codecs (editors), a note at
 *   each import of an official package that has profiles.
 */
import { BUILTINS, PRELUDE_ARITY, schemaOutline, STD_MODULES, type Definition, type Instance, type SchemaFile, type Type } from "./schema-file.js"

/** The types official profiles have a rule for, by id, with the profiles (spec §13.4). `iso`'s rule for `Money` is its currency's. */
export const PROFILED_TYPES: ReadonlyMap<string, readonly string[]> = new Map([
  ["@haus-fmt/money@1#Currency", ["iso"]],
  ["@haus-fmt/geo@1#LatLng", ["wgs84"]],
  ["@haus-fmt/geo@1#BBox", ["wgs84"]],
  ["@haus-fmt/uuid@1#Uuid", ["rfc9562"]],
])

/** The package of a type id: `@haus-fmt/money` for `@haus-fmt/money@1#Currency`. */
const packageOf = (id: string): string => id.slice(0, id.indexOf("#")).replace(/@[0-9]+$/, "")

/** The profiles of an official package (`@haus-fmt/money` → `["iso"]`), or undefined when it has none. */
export const packageProfiles = (name: string): readonly string[] | undefined => {
  const profiles = new Set([...PROFILED_TYPES].filter(([id]) => packageOf(id) === name).flatMap(([, p]) => p))
  return profiles.size > 0 ? [...profiles] : undefined
}

/**
 * A warning about the codecs set (spec §13.4): `missing-codec`, a type of an
 * official profile reached without its codec; `unused-codec`, a codec for an
 * id that no type has.
 */
export type CodecWarning =
  | {
    readonly code: "missing-codec"
    /** The type's id: `@haus-fmt/money@1#Currency`. */
    readonly id: string
    /** The profiles that have a rule for it: `["iso"]`. */
    readonly profiles: readonly string[]
    readonly message: string
  }
  | {
    readonly code: "unused-codec"
    /** The codec's id: `@haus-fmt/money@2#Money`. */
    readonly id: string
    readonly message: string
  }

export const missingCodecMessage = (id: string, profiles: readonly string[]): string =>
  `${id} has profiles (${profiles.join(", ")}), but no codec is set for it: its values are checked for their shape only`

/** The ids of the prelude's types and the standard modules' (`prelude#Decimal`, `std/time#Instant`). */
export const BUILT_IN_TYPE_IDS: ReadonlySet<string> = new Set([
  ...BUILTINS.map((name) => `prelude#${name}`),
  ...Object.keys(PRELUDE_ARITY).map((name) => `prelude#${name}`),
  ...Object.entries(STD_MODULES).flatMap(([module, names]) => names.map((name) => `${module}#${name}`)),
])

/**
 * The warning `unused-codec` for each codec id that no type has (spec §13.4):
 * not one of the prelude or a standard module, nor of the file and the files
 * and packages it imports. Such a codec never runs: a typo, or the wrong major
 * version (`@haus-fmt/money@2#Money` with a schema that imports major 1).
 */
export const unusedCodecs = (file: SchemaFile, ids: Iterable<string>): CodecWarning[] =>
  [...ids]
    .filter((id) => !BUILT_IN_TYPE_IDS.has(id) && !file.typeIds.has(id))
    .map((id) => ({ code: "unused-codec", id, message: `a codec is set for ${id}, but no type has that id: it never runs` }))

/**
 * The types of official profiles that the file's own definitions reach without
 * a codec, once per id, in the order they are reached. A type reached only
 * inside a type that has a codec doesn't count: that codec decides which
 * values it holds (a codec for `Money` covers its `Currency`).
 */
export function missingCodecs(file: SchemaFile, hasCodec: (id: string) => boolean): CodecWarning[] {
  const found = new Map<string, CodecWarning>()
  const seenInstances = new Set<Instance>()
  const seenTypes = new Set<Type>()
  // An explicit stack: types nest as deep as schema files allow, and instances form cycles.
  const stack: Type[] = []
  const visitInstance = (inst: Instance): void => {
    if (seenInstances.has(inst)) return
    seenInstances.add(inst)
    const { id } = inst.definition
    if (inst.args.length === 0 && hasCodec(id)) return
    const profiles = inst.args.length === 0 ? PROFILED_TYPES.get(id) : undefined
    if (profiles && !found.has(id)) found.set(id, { code: "missing-codec", id, profiles, message: missingCodecMessage(id, profiles) })
    stack.push(inst.body, ...inst.args)
  }
  const visitDefinition = (d: Definition): void => visitInstance(d.template)
  file.definitions.forEach(visitDefinition)
  while (stack.length > 0) {
    const t = stack.pop()!
    if (seenTypes.has(t)) continue
    seenTypes.add(t)
    switch (t.kind) {
      case "ref":
        visitInstance(t.instance)
        break
      case "array":
      case "maybe":
      case "secret":
        stack.push(t.item)
        break
      case "map":
        stack.push(t.value)
        break
      case "record":
        for (const f of t.fields) stack.push(f.type)
        break
      case "variant":
        for (const c of t.cases) {
          if (c.payload.kind === "positional") stack.push(...c.payload.items)
          else if (c.payload.kind === "record") stack.push(c.payload.named ?? c.payload.record)
        }
        break
      case "builtin":
      case "std":
      case "param":
        break
    }
  }
  return [...found.values()]
}

/** A note for tools without codecs: an import whose package's profiles are not checked there (spec §13.4). */
export interface ProfileNote {
  readonly code: "missing-codec"
  /** The package: `@haus-fmt/money`. */
  readonly module: string
  readonly profiles: readonly string[]
  readonly message: string
  /** UTF-16 offsets of the import in the schema text, `end` exclusive. */
  readonly offset: number
  readonly end: number
}

/**
 * For tools that have no codecs (editors, `haus check`): one note per import
 * of an official package with profiles, at the import. Throws
 * HausSchemaFileError when the text can't be parsed.
 */
export function uncheckedProfiles(text: string): ProfileNote[] {
  return schemaOutline(text).imports.flatMap((imp) => {
    const module = imp.module.replace(/@[0-9]+$/, "")
    const profiles = packageProfiles(module)
    if (!profiles) return []
    const message = `the rules of ${module} (profiles: ${profiles.join(", ")}) are not checked here; your application checks them by adding a codec`
    return [{ code: "missing-codec" as const, module, profiles, message, offset: imp.pos, end: imp.end }]
  })
}
