## The profile @haus-fmt/money/iso (../profiles/iso.md) as a codec (spec §13.4)
## for `@haus-fmt/money@1#Money`: `Money(19.90, EUR)` ↔
## `{ amount: "19.90", currency: "EUR" }`. A Money is accepted exactly when
## its currency is (IsoCurrency); any amount is. The value is kept: the
## amount is its exact text, scale included.
import HausFmtMoney
import IsoCurrency

Iso := [].{

	## The amount as its exact text, and the currency's code.
	Target : { amount : Str, currency : IsoCurrency.Target }

	decode : HausFmtMoney.Money -> Try(Target, Str)
	decode = |money| match money {
		Money(amount, currency) => Ok({ amount, currency: IsoCurrency.decode(currency)? })
	}

	encode : Target -> HausFmtMoney.Money
	encode = |{ amount, currency }| Money(amount, IsoCurrency.encode(currency))
}
