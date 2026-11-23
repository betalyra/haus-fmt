/**
 * The profile @haus-fmt/uuid/rfc9562 (profiles/rfc9562.md) for haus schemas
 * (`@haus-fmt/haus/schema`): a codec for schema files and the type as a
 * schema.
 *
 *   import { rfc9562 } from "@haus-fmt/uuid"
 *
 *   const { schemas } = compileSchemaFile(text, { ...schemaOptions(path), codecs: rfc9562 })
 *   h.parse(schemas.User!, `{ id: Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57") }`)   // { id: "0190c7a8-…" }
 *   h.parse(schemas.User!, `{ id: Uuid("0190C7A8-5B6E-7D3F-9A41-6C2E8F1B0D57") }`)   // HausDecodeError: not a UUID of the rfc9562 profile
 *
 * A `Uuid` decodes to its text, checked: 32 digits `0`–`9`, `a`–`f` in
 * groups 8-4-4-4-12, lowercase only, any version. The text is the UUID's one
 * spelling, so the codec keeps the value (spec §13.4).
 */
import type { Codec } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"

/** The type id the codec targets (spec §13.3, "Identity"). */
export const UUID_ID = "@haus-fmt/uuid@1#Uuid"

/** A UUID the rfc9562 profile accepts, as its text: `"0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57"`. */
export type Uuid = string

/** A `Uuid` as its schema decodes it, without the codec. */
interface Tagged {
  readonly _tag: "Uuid"
  readonly values: readonly [text: string]
}

const TEXT = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

const REJECTED = "not a UUID of the rfc9562 profile: 32 digits 0–9, a–f in groups of 8-4-4-4-12, joined by hyphens"

/** Whether the rfc9562 profile accepts a UUID's text: 32 digits `0`–`9`, `a`–`f` in groups 8-4-4-4-12, joined by hyphens. */
export const isUuid = (text: unknown): text is Uuid => typeof text === "string" && TEXT.test(text)

/** Why the rfc9562 profile rejects a UUID's text, or undefined. */
export const uuidProblem = (text: unknown): string | undefined => (isUuid(text) ? undefined : REJECTED)

const toText = (u: Tagged): Uuid => {
  const text = u.values[0]
  if (!isUuid(text)) throw new Error(REJECTED)
  return text
}

const fromText = (text: Uuid): Tagged => {
  if (!isUuid(text)) throw new Error(REJECTED)
  return { _tag: "Uuid", values: [text] }
}

/**
 * The rfc9562 profile's codec, for `compileSchemaFile(…, { codecs: rfc9562 })`.
 * It applies wherever a `Uuid` occurs, inside imported packages too, and
 * gives its text.
 */
export const rfc9562: readonly Codec[] = [{ id: UUID_ID, apply: (base) => h.transform(base as h.Schema<Tagged>, toText, fromText) }]

/** `Uuid` with the rfc9562 profile, for schemas written with `h.*`: `h.Record({ id: Uuid })`. */
export const Uuid: h.Schema<Uuid> = h.transform(h.Variant({ Uuid: h.Tuple(h.String) }), toText, fromText)
