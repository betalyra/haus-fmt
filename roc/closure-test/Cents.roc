## A codec (spec §13.4) for `@haus-test/money@1#Money`: integer cents.
## `{ amount: 9.90, currency: "EUR" }` ↔ `{ cents: 990, currency: "EUR" }`;
## more than 2 decimal places is an error.
import money.HausTestMoney

Cents := [].{
	Target : { cents : I128, currency : Str }

	decode : HausTestMoney.Money -> Try(Target, Str)
	decode = |money| Ok({ cents: to_cents(money.amount)?, currency: money.currency })

	encode : Target -> HausTestMoney.Money
	encode = |{ cents, currency }| { amount: from_cents(cents), currency }
}

## `9.90` → 990.
to_cents : Str -> Try(I128, Str)
to_cents = |amount| {
	var $int = []
	var $frac = []
	var $after_dot = False
	for b in amount.to_utf8() {
		if b == '.' {
			$after_dot = True
		} else if $after_dot {
			$frac = $frac.append(b)
		} else {
			$int = $int.append(b)
		}
	}
	if $frac.len() > 2 {
		return Err("${amount} has more than 2 decimal places")
	}
	digits = $int.concat($frac).concat(List.repeat('0', 2 - $frac.len()))
	match Str.from_utf8(digits) {
		Ok(text) => I128.from_str(text).map_err(|_| "${amount} is not an amount of cents")
		Err(_) => Err("${amount} is not an amount of cents")
	}
}

## 990 → `9.90` (amounts are not negative here).
from_cents : I128 -> Str
from_cents = |cents| {
	digits = cents.to_str().to_utf8()
	padded = List.repeat('0', if (digits.len() < 3) 3 - digits.len() else 0).concat(digits)
	split = padded.len() - 2
	whole = Str.from_utf8(padded.sublist({ start: 0, len: split })) ?? "0"
	fraction = Str.from_utf8(padded.sublist({ start: split, len: 2 })) ?? "00"
	"${whole}.${fraction}"
}
