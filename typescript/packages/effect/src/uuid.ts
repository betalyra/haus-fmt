/**
 * `@haus-fmt/uuid` with Effect: the official package, built into every
 * compile with its rule rfc9562 (extensions/uuid/profiles/rfc9562.md) on by
 * default, and a codec for a host type.
 *
 *   import { uuid, uuidAsString } from "@haus-fmt/effect/uuid"
 *
 *   const user = yield* Haus.decode(schemas.User, uuidAsString)(text)   // user.id: "0190c7a8-…"
 *   Haus.Package.shapeOnly(uuid)                                         // to check UUIDs for their shape only
 *
 * The rule is checked whatever the codecs (an uppercase UUID fails with
 * `codec-rejected`); the codec only chooses the host type: a `Uuid` is its
 * text. The text is the UUID's one spelling, so the codec keeps the value
 * (spec §13.4).
 */
import { UUID_ID, uuid, uuidProblem as taggedProblem } from "@haus-fmt/haus/uuid"
import { Effect, Schema, SchemaIssue, SchemaTransformation } from "effect"
import { codecs, CodecTypeId, type Codec } from "./codec.js"
import { CODEC_REJECTED } from "./index.js"

export { uuid, UUID_ID }

/** A UUID the rule rfc9562 accepts, as its text. */
export type Uuid = string

/** A `Uuid` as its schema decodes it, without the codec. */
interface Tagged {
  readonly _tag: "Uuid"
  readonly values: readonly [text: string]
}

/** Why the rule rfc9562 rejects a UUID's text, or undefined. */
export const uuidProblem = (text: unknown): string | undefined => taggedProblem({ _tag: "Uuid", values: [text] })

/** Whether the rule rfc9562 accepts a UUID's text. */
export const isUuid = (text: unknown): text is Uuid => uuidProblem(text) === undefined

const asText: Codec<{ readonly [UUID_ID]: Uuid }, typeof UUID_ID> = {
  [CodecTypeId]: [{
    id: UUID_ID,
    apply: (base) =>
      (base as Schema.Codec<Tagged>).pipe(
        Schema.decodeTo(
          Schema.String,
          SchemaTransformation.transformEffect({
            decode: (u: Tagged) => {
              const text = u.values[0]
              return isUuid(text) ? Effect.succeed(text) : Effect.fail(new SchemaIssue.InvalidValue({ message: uuidProblem(text), ...CODEC_REJECTED }))
            },
            encode: (text: string) =>
              isUuid(text) ? Effect.succeed({ _tag: "Uuid" as const, values: [text] as const }) : Effect.fail(new SchemaIssue.InvalidValue({ message: uuidProblem(text) })),
          }),
        ),
      ),
  }],
}

/**
 * A codec group: every `Uuid`, inside imported packages too, as its text.
 * A group: a schema without a `Uuid` takes it too.
 */
export const uuidAsString = codecs(asText)
