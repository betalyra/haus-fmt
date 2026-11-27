// Codecs: the application chooses host types for named haus types. Each is a
// typed pair of functions between the value the type's schema decoded and the
// host value. The package rules run first (Money's currency is checked by the
// rule iso whatever these codecs do), and the haus text never changes.
import { Codec, Result, StdTime } from "@haus-fmt/haus";
import { LatLng } from "@haus-fmt/haus/geo";
import { Money } from "@haus-fmt/haus/money";
import { UserId } from "../../../../examples/order.schema.haus";

/** 4440n → "44.40": cents as a haus Decimal with two places. */
const centsText = (cents: bigint): string => {
  const digits = (cents < 0n ? -cents : cents).toString().padStart(3, "0");
  return `${cents < 0n ? "-" : ""}${digits.slice(0, -2)}.${digits.slice(-2)}`;
};

/** Integer cents, as payment APIs want them; more than 2 decimal places is an error. */
export interface Cents {
  readonly cents: bigint;
  readonly currency: string;
}

export const cents = Codec.make(Money, {
  // The amount is the Decimal's exact text ("44.40").
  decode: ({ values: [amount, currency] }) => {
    const m = /^(-?)(\d+)(?:\.(\d{1,2}))?$/.exec(amount);
    if (m === null) return Result.fail(`${amount} has more than 2 decimal places`);
    const [, sign = "", whole = "0", fraction = ""] = m;
    const value = BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0"));
    return Result.succeed<Cents>({ cents: sign === "-" ? -value : value, currency: typeof currency === "string" ? currency : currency.tag });
  },
  encode: ({ cents, currency }: Cents) => Result.succeed({ _tag: "Money" as const, values: [centsText(cents), currency] as const }),
});

/** GeoJSON and Turf order: [longitude, latitude]. The swap happens here, once. */
export const geojson = Codec.make(LatLng, {
  decode: ({ values: [lat, lng] }) => Result.succeed([lng, lat] as const),
  encode: ([lng, lat]: readonly [number, number]) => Result.succeed({ _tag: "LatLng" as const, values: [lat, lng] as const }),
});

/** The app's own type: UserId("usr_ada") ↔ "usr_ada" as a branded string. */
export type UserIdText = string & { readonly __brand: "UserId" };
export const userId = Codec.make(UserId, {
  decode: ({ values: [id] }) => Result.succeed(id as UserIdText),
  encode: (id: UserIdText) => Result.succeed({ _tag: "UserId" as const, values: [id] as const }),
});

/** std/time types take codecs too: Date("2026-11-09") ↔ a JS Date at midnight UTC. */
export const jsDate = Codec.make(StdTime.Date, {
  decode: (s) => Result.succeed(new globalThis.Date(`${s}T00:00:00Z`)),
  encode: (d: globalThis.Date) => (Number.isNaN(d.getTime()) ? Result.fail("an invalid Date") : Result.succeed(d.toISOString().slice(0, 10))),
});
