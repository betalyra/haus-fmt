/** The corpus sources a step runs on: all, or those `--sources` names. */
import { Effect, Option } from "effect"
import { UnknownSourceError } from "./errors.ts"
import { Manifest } from "./manifest.ts"

/** Source names from `--sources`; none: every source in the manifest. */
export type Selection = Option.Option<readonly string[]>

export const selectSources = Effect.fn("sources.select")(function* (only: Selection) {
  const { corpus } = yield* Manifest
  if (Option.isNone(only)) return corpus
  const unknown = only.value.find((name) => !corpus.some((s) => s.name === name))
  if (unknown !== undefined) return yield* new UnknownSourceError({ source: unknown, message: `no corpus source ${unknown} in sources.haus` })
  return corpus.filter((s) => only.value.includes(s.name))
})
