/**
 * Helpers of the tests: a schema file's text compiled as a program compiles
 * one (`Haus.Sources.make`, `Haus.compile`: packages built in, rules on).
 */
import { Cause, Effect, Exit, Option } from "effect"
import * as Haus from "../src/index.js"

export interface TextOptions {
  /** Other files of the schema, by path beside `main.schema.haus`. */
  readonly files?: Readonly<Record<string, string>>
  /** Packages given to the compile. */
  readonly packages?: readonly Haus.PackageType[]
  /** The entry file's id (spec §13.3): `app/order`, `@haus-fmt/money@1`. */
  readonly id?: string
}

/** `compileText` as an Effect. */
export const compileTextEffect = (text: string, options: TextOptions = {}) =>
  Haus.Sources.make("main.schema.haus", { ...options.files, "main.schema.haus": text }, options.id === undefined ? {} : { id: options.id }).pipe(
    Effect.map((sources) => (options.packages ?? []).reduce((s, p) => Haus.Sources.withPackage(s, p), sources)),
    Effect.flatMap(Haus.compile),
  )

/** The schema file `text` (`main.schema.haus`), compiled with the official packages and `options.packages`; throws its compile error. */
export const compileText = (text: string, options: TextOptions = {}): Haus.CompiledSchema => Effect.runSync(compileTextEffect(text, options))

/** The typed error an effect fails with (not a defect); throws if it succeeds or dies. */
export const failureOf = <E>(effect: Effect.Effect<unknown, E>): E => {
  const exit = Effect.runSyncExit(effect)
  if (Exit.isSuccess(exit)) throw new Error("expected a failure, got a success")
  return Option.getOrThrowWith(Cause.findErrorOption(exit.cause), () => new Error(`expected a typed failure: ${Cause.pretty(exit.cause)}`))
}
