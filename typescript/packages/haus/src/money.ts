/**
 * `@haus-fmt/money` (an official package, built into every compile):
 * exact amounts with a currency, with the rule iso
 * (extensions/money/profiles/iso.md) for `Currency`: a tag of three letters
 * A–Z. A `Money` is checked through its currency.
 *
 *   import { Money } from "@haus-fmt/haus/money"
 *   Schema.decode(schema, Money)(`Money(19.90, EUR)`)   // { _tag: "Money", values: ["19.90", "EUR"] }
 *   Schema.decode(schema, Money)(`Money(19.90, Eur)`)   // Failure: codec-rejected (the rule iso)
 *
 * `money` is the package value: give `Package.shapeOnly(money)` to a compile
 * to check currencies for their shape only.
 */
import { currencyProblem, money } from "./official.js"
import type { Unknown } from "./schema.js"
import { Type, type Host, type TypeLambda } from "./types.js"

export { currencyProblem, money }

/** The ids of the package's types (spec §13.3, "Identity"). */
export const MONEY_ID = "@haus-fmt/money@1#Money"
export const CURRENCY_ID = "@haus-fmt/money@1#Currency"

/** A currency as decoded: its tag (`"EUR"`); a tag with a payload is an `Unknown`. */
export type Currency<H = {}> = string | Unknown
/** An exact amount: the `Decimal` as its literal text (`"19.90"`) and the currency. */
export type Money<H = {}> = {
  readonly _tag: "Money"
  readonly values: readonly [amount: Host<H, "prelude#Decimal", string>, currency: Host<H, typeof CURRENCY_ID, Currency<H>>]
}

export interface Currency$ extends TypeLambda {
  readonly type: Host<this["hosts"], typeof CURRENCY_ID, Currency<this["hosts"]>>
}
export interface Money$ extends TypeLambda {
  readonly type: Host<this["hosts"], typeof MONEY_ID, Money<this["hosts"]>>
}

/** The handle of `@haus-fmt/money@1#Money`. */
export const Money: Type<Money$, typeof MONEY_ID> = Type.make(MONEY_ID)
/** The handle of `@haus-fmt/money@1#Currency`. */
export const Currency: Type<Currency$, typeof CURRENCY_ID> = Type.make(CURRENCY_ID)
