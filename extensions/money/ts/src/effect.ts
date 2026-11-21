/**
 * The profile @haus-fmt/money/iso (profiles/iso.md) for Effect
 * (`@haus-fmt/effect`): a codec group.
 *
 *   import { iso } from "@haus-fmt/money/effect"
 *
 *   const order = yield* Haus.decode(Order, iso)(text)   // order.total.values: [string, string]
 *
 * The codec keeps the value (spec §13.4): the amount stays the exact
 * `Decimal` text ("19.90"), and the currency, `string | Haus.Unknown`
 * without it, is its tag (`string`). It only rejects more.
 */
import * as Haus from "@haus-fmt/effect"
import { Schema } from "effect"
import { CURRENCY_ID, isCurrency, type Currency } from "./index.js"

export { CURRENCY_ID, isCurrency, MONEY_ID, type Currency, type Money } from "./index.js"

const currency: Haus.Codec<{ readonly [CURRENCY_ID]: Currency }, typeof CURRENCY_ID> = {
  [Haus.CodecTypeId]: [{
    id: CURRENCY_ID,
    apply: (base) => base.pipe(Schema.refine((c: unknown): c is Currency => isCurrency(c), { message: "a currency of the iso profile: a tag of three letters A–Z", ...Haus.CODEC_REJECTED })),
  }],
}

/**
 * The iso profile's codecs. They target `Currency`, so they apply wherever
 * one occurs, the `Money` of imported packages included: a `Money` is
 * accepted exactly when its currency is. A group: a schema without a
 * `Currency` takes it too.
 */
export const iso = Haus.codecs(currency)
