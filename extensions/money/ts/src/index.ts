/**
 * Retired: `@haus-fmt/money` is built into `@haus-fmt/haus` (import
 * `@haus-fmt/haus/money`), with its rule iso on by default; with Effect,
 * `@haus-fmt/effect/money`. This module is no longer published.
 */
import { CURRENCY_ID, currencyProblem, MONEY_ID } from "@haus-fmt/haus/money"

export { CURRENCY_ID, currencyProblem, MONEY_ID }

/** A currency the rule iso accepts: its tag, three letters A–Z. */
export type Currency = string

/** A `Money` the rule iso accepts: the amount as its exact text ("19.90") and the currency. */
export interface Money {
  readonly _tag: "Money"
  readonly values: readonly [amount: string, currency: Currency]
}

/** Whether the rule iso accepts a `Currency` as decoded by its schema. */
export const isCurrency = (currency: unknown): currency is Currency => currencyProblem(currency) === undefined
