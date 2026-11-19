## The profile @haus-fmt/money/iso (../profiles/iso.md) as a codec (spec §13.4)
## for `@haus-fmt/money@1#Currency`: `EUR` ↔ `"EUR"`. A currency is accepted
## exactly when it is a tag of three letters A–Z without payload.
import HausFmtMoney

IsoCurrency := [].{

	## The currency's code: three letters A–Z.
	Target : Str

	decode : HausFmtMoney.Currency -> Try(Target, Str)
	decode = |currency| match currency {
		Bare(code) if is_code(code) => Ok(code)
		Bare(code) => Err("\"${code}\" is not a currency of the iso profile: three letters A–Z")
		Other(tag, _) => Err("${tag}(…) is not a currency of the iso profile: a tag of three letters A–Z, without payload")
	}

	encode : Target -> HausFmtMoney.Currency
	encode = |code| Bare(code)

	## Whether `code` is three letters A–Z (U+0041–U+005A).
	is_code : Str -> Bool
	is_code = |code| {
		bytes = code.to_utf8()
		bytes.len() == 3 and bytes.all(|b| b >= 'A' and b <= 'Z')
	}
}
