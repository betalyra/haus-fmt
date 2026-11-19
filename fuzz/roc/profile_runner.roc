## The Roc runner of the profile fuzzer (../README.md, "Profiles"):
## `profile_runner FILE` reads lines `TYPE HEX` (a value's haus text as
## hex-encoded UTF-8), decodes the value with the codec of the official
## profile for the type, as generated code runs a codec (`Decode.codec`):
## money.Iso for `Money`, money.IsoCurrency for `Currency`, geo.Wgs84 for
## `LatLng`, geo.Wgs84BBox for `BBox`. It encodes the result and prints one
## line each: `ok <canonical form>` or `err <place> <code> <reason>` (`-` for
## an input that isn't one value).
app [main!] {
	haus: "../../roc/package/main.roc",
	money: "../../extensions/money/roc/main.roc",
	geo: "../../extensions/geo/roc/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import haus.Value
import haus.Decode
import haus.Encode
import haus.ErrorCode
import money.HausFmtMoney
import money.Iso
import money.IsoCurrency
import geo.HausFmtGeo
import geo.Wgs84
import geo.Wgs84BBox

main! : List(OsStr) => Try({}, _)
main! = |args| {
	file = match args.map(|a| OsStr.to_str_try(a) ?? "") {
		[f] => f
		_ => ""
	}
	path : Path
	path = "${file}"
	bytes = path.read_bytes!()?
	var $line = []
	for b in bytes {
		if b == '\n' {
			Stdout.line!(run($line))?
			$line = []
		} else {
			$line = $line.append(b)
		}
	}
	Ok({})
}

## One line: `TYPE HEX`.
run : List(U8) -> Str
run = |line| {
	sp = space(line, 0)
	ty = text(line.sublist({ start: 0, len: sp }))
	hex = line.sublist({ start: sp + 1, len: line.len() - sp - 1 })
	var $bytes = []
	var $i = 0
	while $i + 1 < hex.len() {
		$bytes = $bytes.append(nibble(at(hex, $i)) * 16 + nibble(at(hex, $i + 1)))
		$i = $i + 2
	}
	match Str.from_utf8($bytes) {
		Ok(input) => match Value.parse_all(input) {
			Ok([v]) => match ty {
				"Money" => coded(v, HausFmtMoney.decode_money, HausFmtMoney.encode_money, Iso.decode, Iso.encode)
				"Currency" => coded(v, HausFmtMoney.decode_currency, HausFmtMoney.encode_currency, IsoCurrency.decode, IsoCurrency.encode)
				"LatLng" => coded(v, HausFmtGeo.decode_lat_lng, HausFmtGeo.encode_lat_lng, Wgs84.decode, Wgs84.encode)
				"BBox" => coded(v, HausFmtGeo.decode_b_box, HausFmtGeo.encode_b_box, Wgs84BBox.decode, Wgs84BBox.encode)
				_ => "crash no type ${ty}"
			}
			_ => "err $ - not a single value"
		}
		Err(_) => "err $ - invalid UTF-8"
	}
}

## Decode with the base type's decoder and the codec, encode what it decoded.
coded : Value, (Value -> Try(b, Decode.Error)), (b, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)), (b -> Try(t, Str)), (t -> b) -> Str
coded = |v, decode_base, encode_base, decode, encode| match Decode.codec(v, decode_base, decode) {
	Ok(x) => match Encode.value(encode(x), encode_base) {
		Ok(encoded) => "ok ${Encode.canonical(encoded)}"
		Err(e) => "crash encoding failed: ${one_line(Encode.message(e))}"
	}
	Err(e) => "err ${ErrorCode.place(e.path)} ${e.code} ${one_line(e.reason)}"
}

## A reason on one line.
one_line : Str -> Str
one_line = |s| s.replace_each("\r", "\\r").replace_each("\n", "\\n")

## The index of the next space from `from`, or the end.
space : List(U8), U64 -> U64
space = |line, from| {
	var $at = from
	while $at < line.len() and at(line, $at) != ' ' {
		$at = $at + 1
	}
	$at
}

text : List(U8) -> Str
text = |bs| match Str.from_utf8(bs) {
	Ok(s) => s
	Err(_) => ""
}

nibble : U8 -> U8
nibble = |c| if c >= 'a' c - 'a' + 10 else c - '0'

at : List(U8), U64 -> U8
at = |s, i| match s.get(i) {
	Ok(b) => b
	Err(_) => 0
}
