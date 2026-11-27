/**
 * Retired: `@haus-fmt/uuid` is built into `@haus-fmt/haus` (import
 * `@haus-fmt/haus/uuid`), with its rule rfc9562 on by default; with Effect,
 * `@haus-fmt/effect/uuid`. This module is no longer published.
 */
import { UUID_ID, uuidProblem as taggedProblem } from "@haus-fmt/haus/uuid"

export { UUID_ID }

/** A UUID the rule rfc9562 accepts, as its text. */
export type Uuid = string

/** Why the rule rfc9562 rejects a UUID's text, or undefined. */
export const uuidProblem = (text: unknown): string | undefined => taggedProblem({ _tag: "Uuid", values: [text] })

/** Whether the rule rfc9562 accepts a UUID's text. */
export const isUuid = (text: unknown): text is Uuid => uuidProblem(text) === undefined
