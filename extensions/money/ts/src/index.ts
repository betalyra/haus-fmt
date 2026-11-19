/**
 * The profile @haus-fmt/money/iso (profiles/iso.md) for haus schemas
 * (`@haus-fmt/haus/schema`): a codec for schema files and the types as
 * schemas.
 *
 *   import { iso } from "@haus-fmt/money"
 *
 *   const { schemas } = compileSchemaFile(text, { ...schemaOptions(path), codecs: iso })
 *   h.parse(schemas.Order!, `{ total: Money(19.90, EUR) }`)   // ok
 *   h.parse(schemas.Order!, `{ total: Money(19.90, Eur) }`)   // HausDecodeError: not a currency of the iso profile
 *
 * The codec keeps the value (spec §13.4): the amount is the exact `Decimal`
 * text ("19.90"), the currency its tag ("EUR"). It only rejects more.
 */
import type { Codec } from "@haus-fmt/haus"
import * as h from "@haus-fmt/haus/schema"

/** The type ids the codec targets (spec §13.3, "Identity"). */
export const MONEY_ID = "@haus-fmt/money@1#Money"
export const CURRENCY_ID = "@haus-fmt/money@1#Currency"

/** A currency the iso profile accepts: its tag, three letters A–Z. */
export type Currency = string

/** A `Money` the iso profile accepts: the amount as its exact text ("19.90") and the currency. */
export interface Money {
  readonly _tag: "Money"
  readonly values: readonly [amount: string, currency: Currency]
}

const CODE = /^[A-Z]{3}$/

/**
 * Whether the iso profile accepts a `Currency` as decoded by its schema: a
 * tag (a string; a tag with a payload is an unknown value) of three
 * characters, each `A`–`Z`.
 */
export const isCurrency = (currency: unknown): currency is Currency => typeof currency === "string" && CODE.test(currency)

/** Why the iso profile rejects a `Currency`, or undefined. */
export const currencyProblem = (currency: unknown): string | undefined =>
  isCurrency(currency) ? undefined
  : typeof currency === "string" ? `${JSON.stringify(currency)} is not a currency of the iso profile: three letters A–Z`
  : "not a currency of the iso profile: a tag of three letters A–Z, without payload"

/**
 * The iso profile's codec, for `compileSchemaFile(…, { codecs: iso })`. It
 * targets `Currency`, so it applies wherever one occurs, the `Money` of
 * imported packages included; a `Money` is accepted exactly when its
 * currency is.
 */
export const iso: readonly Codec[] = [{ id: CURRENCY_ID, apply: (base) => h.refine(base, currencyProblem) }]

/** `Currency` with the iso profile, for schemas written with `h.*`. */
export const Currency: h.Schema<Currency> = h.refine(h.AnyTag, currencyProblem) as h.Schema<Currency>

/** `Money` with the iso profile, for schemas written with `h.*`: `h.Record({ total: Money })`. */
export const Money: h.Schema<Money> = h.Variant({ Money: h.Tuple(h.Decimal, Currency) })
