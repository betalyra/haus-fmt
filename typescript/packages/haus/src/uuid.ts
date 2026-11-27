/**
 * `@haus-fmt/uuid` (an official package, built into every compile):
 * universally unique identifiers, with the rule rfc9562
 * (extensions/uuid/profiles/rfc9562.md): the text form of RFC 9562 in
 * lowercase, 8-4-4-4-12, any version.
 *
 *   import { Uuid } from "@haus-fmt/haus/uuid"
 *   Schema.decode(schema, Uuid)(`Uuid("0190c7a8-5b6e-7d3f-9a41-6c2e8f1b0d57")`)   // { _tag: "Uuid", values: ["0190c7a8-…"] }
 *
 * A codec can make it its text: `Codec.make(Uuid, { decode: (u) => Result.succeed(u.values[0]), encode: … })`.
 */
import { uuid, uuidProblem } from "./official.js"
import { Type, type Host, type TypeLambda } from "./types.js"

export { uuid, uuidProblem }

/** The id of the package's type (spec §13.3, "Identity"). */
export const UUID_ID = "@haus-fmt/uuid@1#Uuid"

/** A UUID as decoded: `Uuid("…")`, its text checked by the rule rfc9562. */
export type Uuid<H = {}> = {
  readonly _tag: "Uuid"
  readonly values: readonly [text: Host<H, "prelude#String", string>]
}

export interface Uuid$ extends TypeLambda {
  readonly type: Host<this["hosts"], typeof UUID_ID, Uuid<this["hosts"]>>
}

/** The handle of `@haus-fmt/uuid@1#Uuid`. */
export const Uuid: Type<Uuid$, typeof UUID_ID> = Type.make(UUID_ID)
