/**
 * The profile @haus-fmt/uuid/rfc9562 (profiles/rfc9562.md) for Effect
 * (`@haus-fmt/effect`): a codec group.
 *
 *   import { rfc9562 } from "@haus-fmt/uuid/effect"
 *
 *   const user = yield* Haus.decode(User, rfc9562)(text)   // user.id: string, "0190c7a8-…"
 *
 * A `Uuid` decodes to its text, checked: 32 digits `0`–`9`, `a`–`f` in
 * groups 8-4-4-4-12, lowercase only, any version. The text is the UUID's one
 * spelling, so the codec keeps the value (spec §13.4).
 */
import * as Haus from "@haus-fmt/effect"
import { Effect, Schema, SchemaIssue, SchemaTransformation } from "effect"
import { isUuid, uuidProblem, UUID_ID, type Uuid } from "./index.js"

export { isUuid, uuidProblem, UUID_ID, type Uuid } from "./index.js"

const uuid: Haus.Codec<{ readonly [UUID_ID]: Uuid }, typeof UUID_ID> = {
  [Haus.CodecTypeId]: [{
    id: UUID_ID,
    apply: (base) =>
      (base as Schema.Codec<{ readonly _tag: "Uuid"; readonly values: readonly [string] }>).pipe(
        Schema.decodeTo(
          Schema.String,
          SchemaTransformation.transformEffect({
            decode: (u: { readonly _tag: "Uuid"; readonly values: readonly [string] }) => {
              const text = u.values[0]
              return isUuid(text) ? Effect.succeed(text) : Effect.fail(new SchemaIssue.InvalidValue({ message: uuidProblem(text), ...Haus.CODEC_REJECTED }))
            },
            encode: (text: string) =>
              isUuid(text)
                ? Effect.succeed({ _tag: "Uuid" as const, values: [text] as const })
                : Effect.fail(new SchemaIssue.InvalidValue({ message: uuidProblem(text) })),
          }),
        ),
      ),
  }],
}

/**
 * The rfc9562 profile's codec, for `Uuid` wherever it occurs, inside
 * imported packages too: a `Uuid` is its text. A group: a schema without a
 * `Uuid` takes it too.
 */
export const rfc9562 = Haus.codecs(uuid)
