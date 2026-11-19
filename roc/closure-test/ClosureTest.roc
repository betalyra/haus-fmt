## The codec closure (spec §13.4): the codec for `@haus-test/money@1#Money`
## applies inside the packages' types, which Shop's modules copy
## (ShopHausTestOrders, ShopHausTestLedger); the packages' other types are
## their own modules' (HausTestOrders.Customer, HausTestLedger.Note).
import haus.Decode
import haus.Encode
import haus.FromJson
import haus.Int
import haus.ToJson
import ledger.HausTestLedger
import orders.HausTestOrders
import Shop
import ShopHausTestLedger

ClosureTest := [].{

	## The same shop as rust/haus-build-tests/tests/packages.rs.
	shop : Str
	shop =
		\\{ orders: [{ id: 1, entries: [{ amount: { amount: 9.90, currency: "EUR" }, note: { text: "tea" } }], moves: [Credit { amount: 1.50, currency: "EUR" }, Debit { amount: { amount: 0.25, currency: "EUR" } }, Fee { percent: 3 }, Memo { text: "late" }], terms: { rate: { percent: 2 }, note: { text: "net 30" } }, customer: { name: "Ada" } }], customer: { name: "Ada", note: { text: "vip" } }, price: { amount: 12.00, currency: "EUR" }, rate: { percent: 19 } }
}

# Money is cents wherever it is: in the app's own type, in ledger's Entry
# two levels deep, and in Move's payloads.
expect {
	match Decode.one(ClosureTest.shop, Shop.decode_shop) {
		Ok(s) =>
			match s.orders {
				[order] =>
					s.price == { cents: 1200, currency: "EUR" }
						and order.entries.map(|e| e.amount) == [{ cents: 990, currency: "EUR" }]
						and match order.moves {
							[Credit(c), Debit({ amount }), Fee(rate), Memo(note)] => c.cents == 150 and amount.cents == 25 and Int.to_str(rate.percent) == "3" and note.text == "late"
							_ => False
						}
				_ => False
			}
		Err(_) => False
	}
}

# The types without Money are the packages' own.
expect {
	match Decode.one(ClosureTest.shop, Shop.decode_shop) {
		Ok(s) => {
			customer : HausTestOrders.Customer
			customer = s.customer
			notes : List(HausTestLedger.Note)
			notes = s.orders.join_map(|o| o.entries.map(|e| e.note))
			customer.name == "Ada" and notes.map(|n| n.text) == ["tea"]
		}
		Err(_) => False
	}
}

# Through haus and JSON, the same text.
expect {
	match Decode.one(ClosureTest.shop, Shop.decode_shop) {
		Ok(s) =>
			match (Encode.value(s, Shop.encode_shop).map_ok(Encode.to_str), ToJson.to_str(s, Shop.to_json_shop)) {
				(Ok(Ok(text)), Ok(json)) =>
					text == ClosureTest.shop
						and match FromJson.one(json, Shop.from_json_shop) {
							Ok(again) => ToJson.to_str(again, Shop.to_json_shop) == Ok(json)
							Err(_) => False
						}
				_ => False
			}
		Err(_) => False
	}
}

# The codec rejects what it can't hold, inside the packages' types too.
expect {
	match Decode.one(ClosureTest.shop.replace_each("0.25", "0.255"), Shop.decode_shop) {
		Err(Decode({ path, reason, .. })) => path == ".orders[0].moves[1](Debit).amount" and reason == "0.255 has more than 2 decimal places"
		_ => False
	}
}

# A copied type decodes on its own too.
expect ShopHausTestLedger.decode_entry(Text("x")).is_err()
