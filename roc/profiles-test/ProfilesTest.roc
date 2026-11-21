## Tests of the official profiles' codecs: every test vector, the rules'
## edge cases, and the codecs inside another package's types.
import haus.Decode
import haus.Encode
import haus.ErrorCode
import haus.Value
import money.HausFmtMoney
import money.Iso
import money.IsoCurrency
import geo.HausFmtGeo
import geo.Wgs84
import geo.Wgs84BBox
import travel.HausTestTravel
import Travel
import "../../extensions/money/profiles/iso.vectors.haus" as iso_vectors : Str
import "../../extensions/geo/profiles/wgs84.vectors.haus" as wgs84_vectors : Str

ProfilesTest := [].{

	## The vectors of a file that fail, with why. `Accept { type, value,
	## output? }` decodes through the codec and encodes back to `output` (or
	## `value`), in the one spelling of the type (spec §15); `Reject { type,
	## value }` is valid under the schema and rejected by the codec.
	failures : Str -> List(Str)
	failures = |vectors| match Value.parse_all(vectors) {
		Ok(all) =>
			all.keep_oks(
				|v| match check(v) {
					Ok({}) => Err({})
					Err(why) => Ok("${Encode.canonical(v) ?? "(no canonical form)"}: ${why}")
				},
			)
		Err(e) => ["the vectors don't parse: ${e.reason}"]
	}

	## How many vectors a file has: (accepted, rejected).
	counts : Str -> (U64, U64)
	counts = |vectors| match Value.parse_all(vectors) {
		Ok(all) => (all.count_if(|v| verdict(v) == "Accept"), all.count_if(|v| verdict(v) == "Reject"))
		Err(_) => (0, 0)
	}

	iso : Str
	iso = iso_vectors

	wgs84 : Str
	wgs84 = wgs84_vectors

	## The same travel as rust/haus-build-tests/tests/profiles.rs.
	travel : Str
	travel =
		\\{ trips: [{ fare: Money(12.50, EUR), area: BBox(LatLng(0, 170), LatLng(10, -170)), stops: [LatLng(-0, 0), LatLng(38.7223, -9.1393)], legs: [Walk, Ride { fare: Money(3.10, EUR), from: LatLng(38.7, -9.1), to: LatLng(38.8, -9.2) }, Tip(CHF)] }], traveller: { name: "Ada" }, budget: Money(100.00, USD) }
}

## The vector's codec, by its type.
check : Value -> Try({}, Str)
check = |vector| match vector.view() {
	Tag(tag, [payload]) => {
		fields = Decode.strict_record(payload).map_err(|_| "not a vector")?
		ty = text(fields, "type")?
		value = text(fields, "value")?
		output = text(fields, "output") ?? value
		match ty {
			"Money" => run(tag, value, output, HausFmtMoney.decode_money, HausFmtMoney.encode_money, Iso.decode, Iso.encode)
			"Currency" => run(tag, value, output, HausFmtMoney.decode_currency, HausFmtMoney.encode_currency, IsoCurrency.decode, IsoCurrency.encode)
			"LatLng" => run(tag, value, output, HausFmtGeo.decode_lat_lng, HausFmtGeo.encode_lat_lng, Wgs84.decode, Wgs84.encode)
			"BBox" => run(tag, value, output, HausFmtGeo.decode_b_box, HausFmtGeo.encode_b_box, Wgs84BBox.decode, Wgs84BBox.encode)
			_ => Err("no codec for ${ty}")
		}
	}
	_ => Err("not a vector")
}

verdict : Value -> Str
verdict = |v| match v.view() {
	Tag(tag, _) => tag
	_ => ""
}

text : List((Str, Value)), Str -> Try(Str, Str)
text = |fields, key| match fields.find_first(|(k, _)| k == key).map_ok(|(_, v)| v.view()) {
	Ok(Text(s)) => Ok(s)
	_ => Err("no ${key}")
}

## `x` encoded with `encode` (at the top, for a reader with the default limits), as text.
encoded_text : b, (b, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)) -> Try(Str, Encode.Error)
encoded_text = |x, encode| Encode.to_str(Encode.value(x, encode)?)

## Checks one vector with its type's decoder and encoder and its codec, as
## generated code runs a codec (`Decode.codec`).
run : Str, Str, Str, (Value -> Try(b, Decode.Error)), (b, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)), (b -> Try(t, Str)), (t -> b) -> Try({}, Str)
run = |tag, value, output, decode_base, encode_base, decode, encode| {
	# The one spelling of a text: decoded with the schema alone, encoded.
	normal = |s| match Decode.one(s, decode_base) {
		Ok(b) => encoded_text(b, encode_base).map_err(|e| "can't write it: ${Encode.message(e)}")
		Err(_) => Err("the schema rejects ${s}")
	}
	coded = |s| Decode.one(s, |v| Decode.codec(v, decode_base, decode))
	write = |x| encoded_text(encode(x), encode_base).map_err(|e| "can't write it: ${Encode.message(e)}")
	# Every vector is valid under the schema: what the codec rejects, the profile rejects.
	written = normal(value)?
	match (tag, coded(value)) {
		("Reject", Err(Decode(e))) if e.code == "codec-rejected" => Ok({})
		("Reject", Err(Decode(e))) => Err("rejected with ${e.code}: ${Decode.message(e)}")
		("Reject", Ok(_)) => Err("accepted")
		("Accept", Ok(x)) => {
			encoded = write(x)?
			want = normal(output)?
			if encoded != want {
				Err("encoded as ${encoded}, expected ${want}")
			} else if encoded != written {
				# The codec changes no value: it writes what the schema alone decodes.
				Err("encoded as ${encoded}, but the schema alone writes ${written}")
			} else {
				# Decode, encode, decode is decode.
				match coded(encoded) {
					Ok(again) if write(again) == Ok(encoded) => Ok({})
					_ => Err("${encoded} doesn't decode again to the same value")
				}
			}
		}
		("Accept", Err(Decode(e))) => Err("rejected: ${Decode.message(e)}")
		(_, Err(Syntax(e))) => Err("doesn't parse: ${e.reason}")
		_ => Err("neither Accept nor Reject")
	}
}

# ── the vectors ──

expect ProfilesTest.failures(ProfilesTest.iso) == []
expect ProfilesTest.failures(ProfilesTest.wgs84) == []
expect {
	((iso_accepted, iso_rejected), (wgs84_accepted, wgs84_rejected)) = (ProfilesTest.counts(ProfilesTest.iso), ProfilesTest.counts(ProfilesTest.wgs84))
	iso_accepted > 0 and iso_rejected > 0 and wgs84_accepted > 0 and wgs84_rejected > 0
}

# ── the iso rule's edge cases ──

money = |s| Decode.one(s, |v| Decode.codec(v, HausFmtMoney.decode_money, Iso.decode))

money_text = |s| money(s).map_ok(|m| encoded_text(Iso.encode(m), HausFmtMoney.encode_money))

# The amount is kept as written: scale, sign, exponent.
expect money("Money(19.90, EUR)") == Ok({ amount: "19.90", currency: "EUR" })
expect money_text("Money(-0, EUR)") == Ok(Ok("Money(-0, EUR)"))
expect money_text("Money(0.000, EUR)") == Ok(Ok("Money(0.000, EUR)"))
expect money_text("Money(1e3, EUR)") == Ok(Ok("Money(1e3, EUR)"))

# A code is three letters A–Z: not lower case, digits, the letters around A and Z, or non-ASCII capitals.
expect ["EUR", "USD", "BTC", "AAA", "ZZZ"].all(IsoCurrency.is_code)
expect !(["", "EU", "EURO", "Eur", "eur", "E1R", "@AA", "[AA", "ÄUR", "E_R", "EUR "].any(IsoCurrency.is_code))

# A currency with a payload is rejected, alone and in a Money.
expect money("Money(1, EUR(1))").is_err()
expect IsoCurrency.decode(Other("CHF", [Value.num("1") ?? Value.text("")])).is_err()

# ── the wgs84 rule's edge cases ──

point = |s| Decode.one(s, |v| Decode.codec(v, HausFmtGeo.decode_lat_lng, Wgs84.decode))

point_text = |s| point(s).map_ok(|p| encoded_text(Wgs84.encode(p), HausFmtGeo.encode_lat_lng))

box = |s| Decode.one(s, |v| Decode.codec(v, HausFmtGeo.decode_b_box, Wgs84BBox.decode))

# Checked on the decoded float: rounds to 90 (and 180), accepted, written as the float it is.
expect point_text("LatLng(90.00000000000000001, 180.00000000000000001)") == Ok(Ok("LatLng(90, 180)"))
expect point_text("LatLng(-90.00000000000000001, -180.00000000000000001)") == Ok(Ok("LatLng(-90, -180)"))
# The next floats beyond 90 and 180 are not.
expect point("LatLng(90.00000000000001, 0)").is_err()
expect point("LatLng(0, 180.00000000000003)").is_err()

# Negative zero is kept.
expect point_text("LatLng(-0, -0)") == Ok(Ok("LatLng(-0, -0)"))
expect point_text("LatLng(0, 0)") == Ok(Ok("LatLng(0, 0)"))

# NaN and the infinities are rejected in either position.
expect ["NaN", "Infinity", "NegInfinity"].all(|x| point("LatLng(${x}, 0)").is_err() and point("LatLng(0, ${x})").is_err())
expect Wgs84.point(0.0 / 0.0, 0.0).is_err() and Wgs84.point(0.0, 1.0 / 0.0).is_err() and Wgs84.point(-1.0 / 0.0, 0.0).is_err()

# The poles and the antimeridian are not normalised.
expect point_text("LatLng(90, 10)") != point_text("LatLng(90, 20)")
expect point_text("LatLng(0, -180)") == Ok(Ok("LatLng(0, -180)"))

# A box may cross the antimeridian; its latitudes are ordered.
expect box("BBox(LatLng(0, 170), LatLng(10, -170))").map_ok(Wgs84BBox.crosses_antimeridian) == Ok(True)
expect box("BBox(LatLng(0, -170), LatLng(10, 170))").map_ok(Wgs84BBox.crosses_antimeridian) == Ok(False)
expect box("BBox(LatLng(5, 5), LatLng(5, 5))").is_ok()
expect box("BBox(LatLng(0, 0), LatLng(-0, 0))").is_ok()
expect box("BBox(LatLng(10, 0), LatLng(0, 1))").is_err()
expect box("BBox(LatLng(0, 0), LatLng(91, 1))").is_err()

# ── the codecs inside another package's types (the codec closure) ──

expect {
	match Decode.one(ProfilesTest.travel, Travel.decode_travel) {
		Ok(t) =>
			match t.trips {
				[trip] =>
					t.budget == { amount: "100.00", currency: "USD" }
						and trip.fare == { amount: "12.50", currency: "EUR" }
						and Wgs84BBox.crosses_antimeridian(trip.area)
						and trip.stops.map(|p| p.lng) == [0.0, -9.1393]
						and match trip.legs {
							[Walk, Ride({ fare, from, .. }), Tip(code)] => fare.amount == "3.10" and from.lat == 38.7 and code == "CHF"
							_ => False
						}
				_ => False
			}
		Err(_) => False
	}
}

# The types without the codecs' types are the package's own; encoded back to the same text.
expect {
	match Decode.one(ProfilesTest.travel, Travel.decode_travel) {
		Ok(t) => {
			traveller : HausTestTravel.Traveller
			traveller = t.traveller
			traveller.name == "Ada" and encoded_text(t, Travel.encode_travel) == Ok(ProfilesTest.travel)
		}
		Err(_) => False
	}
}

# The codecs reject what their profiles do, wherever the type is. Codecs run
# from the inside out (spec §13.4): a currency's codec runs before the codec of
# the Money that holds it, and rejects at the currency's own place.
rejected_at = |from, to| match Decode.one(ProfilesTest.travel.replace_first(from, to), Travel.decode_travel) {
	Err(Decode({ path, code, .. })) if code == "codec-rejected" => ErrorCode.place(path)
	_ => "accepted"
}
expect rejected_at("Money(3.10, EUR)", "Money(3.10, Eur)") == "$.trips[0].legs[1].fare[1]"
expect rejected_at("Tip(CHF)", "Tip(CHFR)") == "$.trips[0].legs[2][0]"
expect rejected_at("LatLng(-0, 0)", "LatLng(-0, 181)") == "$.trips[0].stops[0]"
expect rejected_at("LatLng(38.8, -9.2)", "LatLng(NaN, -9.2)") == "$.trips[0].legs[1].to"
expect rejected_at("LatLng(10, -170)", "LatLng(-10, -170)") == "$.trips[0].area"
expect rejected_at("LatLng(10, -170)", "LatLng(91, -170)") == "$.trips[0].area[1]"
expect rejected_at("Money(100.00, USD)", "Money(100.00, US)") == "$.budget[1]"
expect rejected_at("Money(12.50, EUR)", "Money(12.50, EUR(1))") == "$.trips[0].fare[1]"
# The first codec to reject gives the error: the point's, before the BBox's own rule.
expect rejected_at("BBox(LatLng(0, 170), LatLng(10, -170))", "BBox(LatLng(10, 170), LatLng(0, 181))") == "$.trips[0].area[1]"
