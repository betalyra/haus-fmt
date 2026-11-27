/**
 * `@haus-fmt/money` with Effect: the official package, built into every
 * compile with its rule iso (extensions/money/profiles/iso.md) on by default,
 * and a codec for a host type.
 *
 *   import { currencyAsString, money } from "@haus-fmt/effect/money"
 *
 *   const order = yield* Haus.decode(schemas.Order, currencyAsString)(text)   // order.total.values: [string, string]
 *   Haus.Package.shapeOnly(money)                                             // to check currencies for their shape only
 *
 * The rule is checked whatever the codecs (a `Money(1, Eur)` fails with
 * `codec-rejected`); the codec only chooses the host type: a `Currency`,
 * `string | Haus.Unknown` without it, is its tag, a `string`. It keeps the
 * value (spec §13.4).
 */
import { CURRENCY_ID, currencyProblem, money, MONEY_ID } from "@haus-fmt/haus/money"
import { Schema } from "effect"
import { codecs, CodecTypeId, type Codec } from "./codec.js"
import { CODEC_REJECTED } from "./index.js"

export { CURRENCY_ID, currencyProblem, money, MONEY_ID }

/** A currency the rule iso accepts: its tag, three letters A–Z. */
export type Currency = string

/** A `Money` the rule iso accepts: the amount as its exact text ("19.90") and the currency. */
export interface Money {
  readonly _tag: "Money"
  readonly values: readonly [amount: string, currency: Currency]
}

/** Whether the rule iso accepts a `Currency` as decoded. */
export const isCurrency = (currency: unknown): currency is Currency => currencyProblem(currency) === undefined

const currency: Codec<{ readonly [CURRENCY_ID]: Currency }, typeof CURRENCY_ID> = {
  [CodecTypeId]: [{
    id: CURRENCY_ID,
    apply: (base) => base.pipe(Schema.refine((c: unknown): c is Currency => isCurrency(c), { message: "a currency of the rule iso: a tag of three letters A–Z", ...CODEC_REJECTED })),
  }],
}

/**
 * A codec group: every `Currency` (the `Money` of imported packages
 * included) as its tag, a `string`. A group: a schema without a `Currency`
 * takes it too.
 */
export const currencyAsString = codecs(currency)
