// The same order, decoded with the schema's own types and with the app's
// codecs. The same steps as rust/examples/order, on the same files.
// Run: pnpm start
import { pipe, Result, Schema, type HausError } from "@haus-fmt/haus";
import { readFileSync } from "node:fs";
import { cents, geojson, jsDate, userId } from "./codecs.ts";
// The official packages (@haus-fmt/money, @haus-fmt/geo) are built in: nothing to install or give.
import { Root, schema } from "../../../../examples/order.schema.haus";

const text = readFileSync(new URL("../../../../examples/order.haus", import.meta.url), "utf8");

/** The first line of an error: the reason, without the path below it. */
const reason = (e: HausError) => e.message.split("\n")[0];
const orFail = <A>(r: Result<A, HausError>): A => Result.match(r, { onSuccess: (a) => a, onFailure: (e) => { throw new Error(e.message); } });

// Without codecs: Money is { _tag: "Money", values: ["44.40", "EUR"] }, the Decimal as its exact text.
const plain = orFail(Schema.decode(schema, Root)(text));
const [amount, currency] = plain.total.values;
console.log(`plain:  ${plain.customer.values[0]} pays ${amount} ${String(currency)}`);

// With codecs: the fields have the codecs' types (hover `typed`).
const withCodecs = orFail(pipe(
  Schema.withCodec(schema, userId),
  Result.flatMap((s) => Schema.withCodec(s, cents)),
  Result.flatMap((s) => Schema.withCodec(s, geojson)),
  Result.flatMap((s) => Schema.withCodec(s, jsDate)),
));
const typed = orFail(Schema.decode(withCodecs, Root)(text));
console.log(`typed:  ${typed.customer} pays ${typed.total.cents} cents, deliver to [lng, lat] [${typed.deliverTo.join(", ")}]`);
const weekday = typed.placed.toLocaleDateString("en", { weekday: "long", timeZone: "UTC" });
console.log(`placed: ${typed.placed.toISOString().slice(0, 10)}, a ${weekday}`);

// Variants are tagged unions: narrow them by _tag.
const status = typed.status;
console.log(status._tag === "Shipped" ? `status: shipped, tracking ${status.tracking}` : "status: not on its way");

// Encoding with the same codecs gives back the same haus text.
console.log(orFail(Schema.stringify(withCodecs, Root)(typed, { style: "compact" })));

// Package rules are on by default: Eur is a valid tag, but not a currency of the rule iso.
const eur = text.replace("EUR", "Eur");
Result.match(Schema.decode(schema, Root)(eur), { onSuccess: () => console.log("Eur: accepted"), onFailure: (e) => console.log(`Eur: ${reason(e)}`) });
Result.match(Schema.decode(withCodecs, Root)(text.replace("44.40", "44.405")), { onSuccess: () => console.log("44.405: accepted"), onFailure: (e) => console.log(`44.405 with codecs: ${reason(e)}`) });
