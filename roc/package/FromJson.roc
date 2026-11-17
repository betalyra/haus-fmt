## Reading schema-based JSON (spec §16.3) into your own Roc types: the building
## blocks that generated modules (`haus-gen roc --json`) use, like `Decode`
## for haus values.
##
## A reader is a function `JsonValue -> Try(a, Decode.Error)`. Errors name
## the place in the JSON (`.items[2].price`, `.values[1]`), built on the way
## out, and never the content of a string.
##
##     user = FromJson.one("{\"id\": 1}", |j| {
##         fs = FromJson.object(j, "User")?
##         Ok({ id: FromJson.field(fs, "id", FromJson.i32)? })
##     })
##
## Errors have the codes of spec §17 (`ErrorCode`), as decoding haus does,
## and those of schema-based JSON: `missing-member`, `unexpected-member`,
## `invalid-base64`, `invalid-number` for a string that should hold a number,
## and `haus-json-form` for an `Any` or an unknown value's `"_args"` that
## isn't self-describing JSON.
import ErrorCode
import Int
import JsonValue
import Secret
import Time
import Value
import Decode
import Encode

FromJson := [].{
	# ── documents ───────────────────────────────────────────

	## Read a JSON text holding one value with `reader`.
	one : Str, (JsonValue -> Try(a, Decode.Error)) -> Try(a, [Syntax(Value.ParseError), Decode(Decode.Error)])
	one = |text, reader| one_with(text, Value.default_limits, reader)

	## `one` with your own limits for reading the JSON (see `JsonValue.parse_with`).
	## A generated `from_json_<name>` checks the value's depth and lengths
	## against the default limits; for `limits`, read with `read_json_<name>`
	## and check with `within_limits`.
	one_with : Str, Value.Limits, (JsonValue -> Try(a, Decode.Error)) -> Try(a, [Syntax(Value.ParseError), Decode(Decode.Error)])
	one_with = |text, limits, reader| {
		json = JsonValue.parse_with(text, limits).map_err(|e| Syntax(e))?
		reader(json).map_err(|e| Decode(e))
	}

	## Read JSON Lines (see `JsonValue.lines`), every line with `reader`.
	## Decode errors say which value: `[3].total`.
	lines : Str, (JsonValue -> Try(a, Decode.Error)) -> Try(List(a), [Syntax(Value.ParseError), Decode(Decode.Error)])
	lines = |text, reader| lines_with(text, Value.default_limits, reader)

	## `lines` with your own limits for reading the JSON (see `one_with`).
	lines_with : Str, Value.Limits, (JsonValue -> Try(a, Decode.Error)) -> Try(List(a), [Syntax(Value.ParseError), Decode(Decode.Error)])
	lines_with = |text, limits, reader| {
		values = JsonValue.lines_with(text, limits).map_err(|e| Syntax(e))?
		var $out = []
		var $i = 0.U64
		for v in values {
			$out = $out.append(at(reader(v), "[${$i.to_str()}]").map_err(|e| Decode(e))?)
			$i = $i + 1
		}
		Ok($out)
	}

	## A reader's result, if the haus value it encodes to (with `encode`)
	## nests at most 256 levels (spec §16, "Limits": a form can take
	## several JSON levels for one haus level, so the JSON may nest deeper and
	## the value is checked after reading). A generated `from_json_<name>`
	## checks its result so; the readers it is built from don't.
	within_depth : Try(a, Decode.Error), (a -> Value) -> Try(a, Decode.Error)
	within_depth = |result, encode| within_limits(result, encode, Value.default_limits)

	## `within_depth` for the depth limit of `limits`, which must be at most
	## `Value.max_supported_depth`:
	##
	##     FromJson.one_with(text, limits, |j| FromJson.within_limits(Order.read_json_order(j), Order.encode_order, limits))
	##
	## Lengths are checked here too, on the haus value (spec §16, "Limits"): a
	## string's characters after its escapes are read, keys and tags as haus keys
	## and tags, bytes as two characters per byte, as in the hex of a haus byte
	## string, although JSON spells them in base64.
	within_limits : Try(a, Decode.Error), (a -> Value), Value.Limits -> Try(a, Decode.Error)
	within_limits = |result, encode, limits| {
		Value.check_limits(limits).map_err(|reason| { code: ErrorCode.unsupported_depth, reason, path: "" })?
		x = result?
		value = encode(x)
		if depth(value) > limits.max_depth {
			Decode.fail(ErrorCode.nesting_too_deep, "nesting deeper than ${limits.max_depth.to_str()} levels")
		} else {
			lengths(value, limits.max_string_length).map_ok(|_| x)
		}
	}

	# ── scalars ─────────────────────────────────────────────

	str : JsonValue -> Try(Str, Decode.Error)
	str = |j| match j {
		String(s) => Ok(s)
		_ => expected("a string", j)
	}

	## `Bytes`: base64 with padding (RFC 4648 §4), canonical only.
	bytes : JsonValue -> Try(List(U8), Decode.Error)
	bytes = |j| match j {
		String(s) => JsonValue.from_base64(s).map_err(|_| { code: ErrorCode.invalid_base64, reason: "not base64 with padding (Bytes)", path: "" })
		_ => expected("a base64 string (Bytes)", j)
	}

	## The prelude's `Bool`: `true` or `false`.
	bool : JsonValue -> Try(Bool, Decode.Error)
	bool = |j| match j {
		Boolean(b) => Ok(b)
		_ => expected("true or false", j)
	}

	i8 : JsonValue -> Try(I8, Decode.Error)
	i8 = |j| number(j, "Int8", Decode.i8)

	i16 : JsonValue -> Try(I16, Decode.Error)
	i16 = |j| number(j, "Int16", Decode.i16)

	i32 : JsonValue -> Try(I32, Decode.Error)
	i32 = |j| number(j, "Int32", Decode.i32)

	u8 : JsonValue -> Try(U8, Decode.Error)
	u8 = |j| number(j, "UInt8", Decode.u8)

	u16 : JsonValue -> Try(U16, Decode.Error)
	u16 = |j| number(j, "UInt16", Decode.u16)

	u32 : JsonValue -> Try(U32, Decode.Error)
	u32 = |j| number(j, "UInt32", Decode.u32)

	## `Int64`: a string holding the decimal integer.
	i64 : JsonValue -> Try(I64, Decode.Error)
	i64 = |j| Decode.i64(Num(integer(j, "Int64")?))

	## `UInt64`: a string holding the decimal integer.
	u64 : JsonValue -> Try(U64, Decode.Error)
	u64 = |j| Decode.u64(Num(integer(j, "UInt64")?))

	## `Int`: a string holding the decimal integer, of any size a haus literal can hold.
	int : JsonValue -> Try(Int, Decode.Error)
	int = |j| {
		text = integer(j, "Int")?
		_ = Encode.to_str(Num(text)).map_err(|e| { code: e.code, reason: e.reason, path: "" })?
		Decode.int(Num(text))
	}

	## `Float64`: a number rounded to the nearest binary64 value (spec §15), or
	## the strings `"NaN"`, `"Infinity"` and `"-Infinity"`.
	f64 : JsonValue -> Try(F64, Decode.Error)
	f64 = |j| Decode.f64(float(j, "Float64")?)

	## `Float32`: as `f64`, rounded to binary32.
	f32 : JsonValue -> Try(F32, Decode.Error)
	f32 = |j| Decode.f32(float(j, "Float32")?)

	## `Decimal`: a string holding a JSON number (`"19.90"`, `"1E+05"`), kept
	## as its normalized literal (`"1e5"`).
	decimal : JsonValue -> Try(Str, Decode.Error)
	decimal = |j| match j {
		String(s) if JsonValue.is_number(s) => {
			text = JsonValue.normalize_number(s)
			_ = Encode.to_str(Num(text)).map_err(|e| { code: e.code, reason: e.reason, path: "" })?
			Ok(text)
		}
		String(_) => Decode.fail(ErrorCode.invalid_number, "expected a number in a string (Decimal)")
		_ => expected("a string holding a number (Decimal)", j)
	}

	## A std/time value: the string, checked by the std/time profile.
	time : Str -> (JsonValue -> Try(Str, Decode.Error))
	time = |name| |j| match j {
		String(s) => {
			Time.check(name, s).map_err(|reason| { code: ErrorCode.invalid_time, reason, path: "" })?
			Ok(s)
		}
		_ => expected("a string (${name})", j)
	}

	## `Any`: its self-describing value (spec §16.2), without the envelope.
	any : JsonValue -> Try(Value, Decode.Error)
	any = |j| JsonValue.from_haus_json_value(j)

	## `< >`: any tag, as an unknown value.
	any_tag : JsonValue -> Try([Bare(Str), Other(Str, List(Value))], Decode.Error)
	any_tag = |j| {
		(tag, members) = variant(j, "a tag")?
		match unknown(tag, members)? {
			[] => Ok(Bare(tag))
			args => Ok(Other(tag, args))
		}
	}

	## `Secret a`: read with `reader`, but an error says only that the value
	## isn't a valid `what` (`"Secret String"`), never what was found or where in it.
	secret : JsonValue, Str, (JsonValue -> Try(a, Decode.Error)) -> Try(Secret(a), Decode.Error)
	secret = |j, what, reader| match reader(j) {
		Ok(x) => Ok(Secret.new(x))
		Err(_) => Decode.fail(ErrorCode.invalid_secret, "not a valid ${what} (the value is hidden)")
	}

	## A type with a codec: its base reader first, then the codec (spec §13.4).
	codec : JsonValue, (JsonValue -> Try(b, Decode.Error)), (b -> Try(t, Str)) -> Try(t, Decode.Error)
	codec = |j, base, decode| match base(j) {
		Ok(x) => decode(x).map_err(|reason| { code: ErrorCode.type_mismatch, reason, path: "" })
		Err(e) => Err(e)
	}

	# ── containers ──────────────────────────────────────────

	list : JsonValue, (JsonValue -> Try(a, Decode.Error)) -> Try(List(a), Decode.Error)
	list = |j, reader| match j {
		Array(items) => {
			var $out = []
			var $i = 0.U64
			for x in items {
				$out = $out.append(at(reader(x), "[${$i.to_str()}]")?)
				$i = $i + 1
			}
			Ok($out)
		}
		_ => expected("an array", j)
	}

	## `Map v`: an object used as a dictionary.
	map : JsonValue, (JsonValue -> Try(a, Decode.Error)) -> Try(List((Str, a)), Decode.Error)
	map = |j, reader| match j {
		Object(members) => {
			var $out = []
			for (k, x) in members {
				$out = $out.append((k, at(reader(x), ErrorCode.path_key(k))?))
			}
			Ok($out)
		}
		_ => expected("an object (Map)", j)
	}

	## `Maybe a`: `null` or `a` when `a`'s JSON can't be `null` (`nullable` is
	## False); otherwise `{"_tag": "None"}` or `{"_tag": "Some", "value": …}`.
	maybe : JsonValue, Bool, (JsonValue -> Try(a, Decode.Error)) -> Try([None, Some(a)], Decode.Error)
	maybe = |j, nullable, reader|
		if !nullable {
			match j {
				Null => Ok(None)
				_ => Ok(Some(reader(j)?))
			}
		} else {
			(tag, members) = variant(j, "Maybe")?
			match tag {
				"None" => {
					_ = args(members, 0)?
					Ok(None)
				}
				"Some" => match args(members, 1)? {
					[x] => Ok(Some(arg(1, 0, x, reader)?))
					_ => arity("Some", 1)
				}
				_ => at(Decode.unknown_tag(tag, ["None", "Some"]), "._tag")
			}
		}

	## `Result e a`: `{"_tag": "Ok", "value": …}` or `{"_tag": "Err", "value": …}`.
	result : JsonValue, (JsonValue -> Try(a, Decode.Error)), (JsonValue -> Try(e, Decode.Error)) -> Try(Try(a, e), Decode.Error)
	result = |j, ok, err| {
		(tag, members) = variant(j, "Result")?
		if tag != "Ok" and tag != "Err" {
			return at(Decode.unknown_tag(tag, ["Ok", "Err"]), "._tag")
		}
		match (tag, args(members, 1)?) {
			("Ok", [x]) => Ok(Ok(arg(1, 0, x, ok)?))
			(_, [x]) => Ok(Err(arg(1, 0, x, err)?))
			_ => arity(tag, 1)
		}
	}

	# ── records and variants ────────────────────────────────

	## The members of an object (a record); `what` names the type in errors.
	object : JsonValue, Str -> Try(List((Str, JsonValue)), Decode.Error)
	object = |j, what| match j {
		Object(members) => Ok(members)
		_ => expected("an object (${what})", j)
	}

	## A required member: `missing-field` if the record doesn't have it.
	field : List((Str, JsonValue)), Str, (JsonValue -> Try(a, Decode.Error)) -> Try(a, Decode.Error)
	field = |members, key, reader| match members.find_first(|(k, _)| k == key) {
		Ok((_, v)) => at(reader(v), ErrorCode.path_key(key))
		Err(_) => Decode.fail(ErrorCode.missing_field, "missing member ${key}")
	}

	## An optional field (`key?: T`): `Missing` when the member is missing.
	optional_field : List((Str, JsonValue)), Str, (JsonValue -> Try(a, Decode.Error)) -> Try([Missing, Present(a)], Decode.Error)
	optional_field = |members, key, reader| match members.find_first(|(k, _)| k == key) {
		Err(_) => Ok(Missing)
		Ok((_, v)) => Ok(Present(at(reader(v), ErrorCode.path_key(key))?))
	}

	## A closed record has only the members listed (a record payload lists `"_tag"` too).
	closed : List((Str, JsonValue)), List(Str) -> Try({}, Decode.Error)
	closed = |members, known| match members.find_first(|(k, _)| !known.contains(k)) {
		Ok((k, _)) => at(Decode.fail(ErrorCode.unknown_field, "unknown member \"${k}\" in a closed record"), ErrorCode.path_key(k))
		Err(_) => Ok({})
	}

	## A variant's object: its `"_tag"`, and its members (`"_tag"` included).
	## Without a `"_tag"` that is a string, `missing-member`.
	variant : JsonValue, Str -> Try((Str, List((Str, JsonValue))), Decode.Error)
	variant = |j, what| match j {
		Object(members) => match members.find_first(|(k, _)| k == "_tag") {
			Ok((_, String(tag))) => Ok((tag, members))
			Ok((_, other)) => at(Decode.fail(ErrorCode.missing_member, "expected a string, found ${JsonValue.describe(other)}"), "._tag")
			Err(_) => Decode.fail(ErrorCode.missing_member, "expected an object with \"_tag\" (${what})")
		}
		_ => expected("an object with \"_tag\" (${what})", j)
	}

	## The payload of a positional case with `n` values: nothing besides
	## `"_tag"` for none, `"value"` for one, `"values"` (an array of `n`) for more.
	args : List((Str, JsonValue)), U64 -> Try(List(JsonValue), Decode.Error)
	args = |members, n| {
		name = if (n == 1) "value" else "values"
		match members.find_first(|(k, _)| k != "_tag" and (n == 0 or k != name)) {
			Ok((k, _)) => return at(Decode.fail(ErrorCode.unexpected_member, "unexpected member \"${k}\""), ErrorCode.path_key(k))
			Err(_) => {}
		}
		if n == 0 {
			return Ok([])
		}
		match members.find_first(|(k, _)| k == name) {
			Err(_) => Decode.fail(ErrorCode.missing_member, "missing member ${name}")
			Ok((_, v)) if n == 1 => Ok([v])
			Ok((_, Array(items))) if items.len() == n => Ok(items)
			Ok((_, Array(items))) => at(Decode.fail(ErrorCode.wrong_payload, "expected ${n.to_str()} values, found ${items.len().to_str()}"), ".values")
			Ok((_, other)) => at(Decode.fail(ErrorCode.wrong_payload, "expected an array, found ${JsonValue.describe(other)}"), ".values")
		}
	}

	## Payload value `i` of a case with `n`: `.value`, or `.values[i]` in errors.
	arg : U64, U64, JsonValue, (JsonValue -> Try(a, Decode.Error)) -> Try(a, Decode.Error)
	arg = |n, i, j, reader| at(reader(j), if (n == 1) ".value" else ".values[${i.to_str()}]")

	## A case with the wrong number of payload values (`args` rules this out).
	arity : Str, U64 -> Try(a, Decode.Error)
	arity = |tag, n| Decode.fail(ErrorCode.wrong_payload, "${tag} takes ${n.to_str()} value(s)")

	## The arguments of a tag the variant doesn't list (spec §16.3): none for
	## only `"_tag"`; with `"_args"` and no other member, the arguments as
	## self-describing values (without the envelope), a non-empty array;
	## otherwise the other members are a record payload, read by the import
	## (§16.1): `{"_tag": "Hexagon", "sides": 6}` is `Hexagon { sides: 6 }`.
	unknown : Str, List((Str, JsonValue)) -> Try(List(Value), Decode.Error)
	unknown = |tag, members| {
		if !JsonValue.is_tag_name(tag) {
			return at(Decode.fail(ErrorCode.invalid_tag, "\"${tag}\" is not a tag name"), "._tag")
		}
		others = members.keep_if(|(k, _)| k != "_tag")
		match others {
			[] => Ok([])
			[("_args", Array([]))] => at(Decode.fail(ErrorCode.haus_json_form, "a tag without arguments has no \"_args\""), "._args")
			[("_args", Array(items))] => {
				var $out = []
				var $i = 0.U64
				for x in items {
					$out = $out.append(at(JsonValue.from_haus_json_value(x), "._args[${$i.to_str()}]")?)
					$i = $i + 1
				}
				Ok($out)
			}
			[("_args", other)] => at(Decode.fail(ErrorCode.haus_json_form, "expected an array, found ${JsonValue.describe(other)}"), "._args")
			_ => Ok([JsonValue.import_value(Object(others))?])
		}
	}

	## The record of a record case whose record is a named type (`Box BoxRec`
	## with `type BoxRec = { w: Int32 }`, spec §15), read with `reader` from
	## the members of the tag's object other than `"_tag"`, as for `Box { w:
	## Int32 }`.
	record_case : List((Str, JsonValue)), (JsonValue -> Try(a, Decode.Error)) -> Try(a, Decode.Error)
	record_case = |members, reader| reader(Object(members.keep_if(|(k, _)| k != "_tag")))

	## A closed variant whose tags have no payload: the tag, a string.
	tag_name : JsonValue, Str -> Try(Str, Decode.Error)
	tag_name = |j, what| match j {
		String(tag) => Ok(tag)
		_ => expected("a string (${what})", j)
	}

	## A case whose record payload has a field named `_tag` or `_args`
	## (`name`): it has no schema-based form (spec §16.3).
	no_json_form : Str, Str -> Try(a, Decode.Error)
	no_json_form = |tag, name| Decode.fail(ErrorCode.no_json_form, "${tag} has a field named ${name}, so it has no schema-based JSON form")
}

## How deep a value nests, counted as the haus writer counts it (`Tag { … }`
## is one level).
depth : Value -> U64
depth = |value| match value {
	Arr(items) => 1 + deepest(items)
	Rec(fields) => 1 + deepest(fields.map(|(_, v)| v))
	Tag(_, [Rec(fields)]) => 1 + deepest(fields.map(|(_, v)| v))
	Tag(_, []) => 0
	Tag(_, args) => 1 + deepest(args)
	_ => 0
}

## The first string, key, tag or byte string in `value` longer than `max`
## characters, as an error: counted on the haus value, in code points, and
## bytes as two characters each.
lengths : Value, U64 -> Try({}, Decode.Error)
lengths = |value, max| {
	long = |s| {
		b = s.to_utf8()
		b.len() > max and b.count_if(|c| c < 0x80 or c >= 0xC0) > max
	}
	too_long = |code, what| Decode.fail(code, "${what} longer than ${max.to_str()} characters")
	match value {
		Text(s) => if (long(s)) too_long(ErrorCode.string_too_long, "string") else Ok({})
		Bytes(b) => if (b.len() > max // 2) too_long(ErrorCode.string_too_long, "byte string") else Ok({})
		Arr(items) => {
			for x in items {
				lengths(x, max)?
			}
			Ok({})
		}
		Rec(fields) => {
			for (k, x) in fields {
				if long(k) {
					return too_long(ErrorCode.key_too_long, "key")
				}
				lengths(x, max)?
			}
			Ok({})
		}
		Tag(name, args) => {
			if long(name) {
				return too_long(ErrorCode.tag_too_long, "tag")
			}
			for x in args {
				lengths(x, max)?
			}
			Ok({})
		}
		_ => Ok({})
	}
}

## The depth of the deepest of `items`; 0 for none.
deepest : List(Value) -> U64
deepest = |items| {
	var $max = 0
	for x in items {
		d = depth(x)
		if d > $max {
			$max = d
		}
	}
	$max
}

## Prefix the path of an error coming out of a nested reader.
at : Try(a, Decode.Error), Str -> Try(a, Decode.Error)
at = |result, segment| result.map_err(|e| { ..e, path: "${segment}${e.path}" })

## A JSON value of another kind than the type reads: a `type-mismatch`.
expected : Str, JsonValue -> Try(a, Decode.Error)
expected = |what, j| Decode.fail(ErrorCode.type_mismatch, "expected ${what}, found ${JsonValue.describe(j)}")

## A small integer: a JSON number, whole by its spelling, in range.
number : JsonValue, Str, (Value -> Try(n, Decode.Error)) -> Try(n, Decode.Error)
number = |j, name, decode| match j {
	Number(text) => decode(Num(text))
	_ => expected("a number (${name})", j)
}

## The decimal integer in a JSON string: `-?(0|[1-9][0-9]*)`.
integer : JsonValue, Str -> Try(Str, Decode.Error)
integer = |j, name| match j {
	String(text) => {
		b = text.to_utf8()
		digits = if (b.first() == Ok('-')) b.drop_first(1) else b
		canonical = digits == ['0'] or (!digits.is_empty() and digits.first() != Ok('0') and digits.all(|c| c >= '0' and c <= '9'))
		# A JSON number that isn't whole (`"1e3"`) is `not-an-integer`, anything else `invalid-number`.
		code = if (JsonValue.is_number(text)) ErrorCode.not_an_integer else ErrorCode.invalid_number
		if (canonical) Ok(if (text == "-0") "0" else text) else Decode.fail(code, "expected a decimal integer in a string (${name})")
	}
	_ => expected("a string holding a decimal integer (${name})", j)
}

## A float as the haus value `Decode.f64` and `Decode.f32` read.
float : JsonValue, Str -> Try(Value, Decode.Error)
float = |j, name| match j {
	Number(text) => Ok(Num(JsonValue.normalize_number(text)))
	String("NaN") => Ok(Tag("NaN", []))
	String("Infinity") => Ok(Tag("Infinity", []))
	String("-Infinity") => Ok(Tag("NegInfinity", []))
	_ => expected("a number, \"NaN\", \"Infinity\" or \"-Infinity\" (${name})", j)
}

expect FromJson.one("[1, -0]", |j| FromJson.list(j, FromJson.u8)) == Ok([1, 0])
expect FromJson.one("1.0", FromJson.i32).map_err(|_| {}) == Err({})
expect FromJson.one("\"-12\"", FromJson.i64) == Ok(-12)
expect FromJson.one("\"007\"", FromJson.i64).is_err()
expect FromJson.one("\"123456789012345678901234567890\"", FromJson.int).map_ok(|n| n.to_str()) == Ok("123456789012345678901234567890")
expect FromJson.one("\"1E+05\"", FromJson.decimal) == Ok("1e5")
expect FromJson.one("\"0xFF\"", FromJson.decimal).is_err()
expect FromJson.one("\"CzQ=\"", FromJson.bytes) == Ok([0x0B, 0x34])
expect FromJson.one("\"-Infinity\"", FromJson.f64) == Ok(-1.0 / 0.0)
expect FromJson.one("1e400", FromJson.f64).is_err()
expect FromJson.one("null", |j| FromJson.maybe(j, False, FromJson.i32)) == Ok(None)
expect FromJson.one("{\"_tag\": \"Some\", \"value\": null}", |j| FromJson.maybe(j, True, |x| FromJson.maybe(x, False, FromJson.i32))) == Ok(Some(None))
expect FromJson.one("{\"_tag\": \"Some\", \"value\": null, \"x\": 1}", |j| FromJson.maybe(j, True, |x| FromJson.maybe(x, False, FromJson.i32))).is_err()
expect FromJson.one("{\"_tag\": \"Ok\", \"value\": \"x\"}", |j| FromJson.result(j, FromJson.i32, FromJson.str)).map_err(
	|e| match e {
		Decode(d) => Decode.message(d)
		Syntax(_) => ""
	},
) == Err(".value: expected a number (Int32), found a string")
expect FromJson.one("{\"_tag\": \"Hexagon\", \"sides\": 6}", FromJson.any_tag).map_ok(
	|t| match t {
		Other(tag, args) => Encode.canonical(Tag(tag, args))
		Bare(tag) => tag
	},
) == Ok("Hexagon{sides:6}")
# `_args` alone: the arguments; beside other members, or `args`: a record payload.
expect FromJson.one("{\"_tag\": \"Hexagon\", \"_args\": [{\"_num\": \"1\"}, \"a\"]}", FromJson.any_tag).map_ok(
	|t| match t {
		Other(tag, args) => Encode.canonical(Tag(tag, args))
		Bare(tag) => tag
	},
) == Ok("Hexagon(1,\"a\")")
expect FromJson.one("{\"_tag\": \"Run\", \"args\": [1, 2]}", FromJson.any_tag).map_ok(
	|t| match t {
		Other(tag, args) => Encode.canonical(Tag(tag, args))
		Bare(tag) => tag
	},
) == Ok("Run{args:[1,2]}")
expect FromJson.one("{\"_tag\": \"Hexagon\", \"_args\": [{\"_num\": \"1\"}], \"x\": 2}", FromJson.any_tag).map_ok(
	|t| match t {
		Other(tag, args) => Encode.canonical(Tag(tag, args))
		Bare(tag) => tag
	},
) == Ok("Hexagon{_args:[{_num:\"1\"}],x:2}")
# `Any` inside schema-based JSON accepts raw DEL, C1 and bidi controls.
expect FromJson.one("\"a\u(7F)\u(85)\u(202E)\"", FromJson.any).map_ok(Encode.canonical) == Ok("\"a\\u{7F}\\u{85}\\u{202E}\"")
expect FromJson.one(
	"{\"pin\": 98765}",
	|j| {
		fs = FromJson.object(j, "Login")?
		FromJson.field(fs, "pin", |x| FromJson.secret(x, "Secret UInt16", FromJson.u16))
	},
).map_err(
	|e| match e {
		Decode(d) => Decode.message(d)
		Syntax(_) => ""
	},
) == Err(".pin: not a valid Secret UInt16 (the value is hidden)")
expect FromJson.lines("1\n2\n", FromJson.u8) == Ok([1, 2])
expect FromJson.within_depth(Ok(Arr([Rec([("a", Tag("Some", [Arr([])]))])])), |v| v).map_ok(Encode.canonical) == Ok("[{a:Some([])}]")
expect FromJson.within_depth(Ok(nest(256)), |v| v).is_ok()
expect FromJson.within_depth(Ok(nest(257)), |v| v).map_ok(|_| {}).map_err(Decode.message) == Err("nesting deeper than 256 levels")
expect FromJson.within_depth(Ok(Tag("Box", [Rec([("w", nest(255))])])), |v| v).is_ok()
expect FromJson.within_depth(Ok(Tag("Box", [Rec([("w", nest(256))])])), |v| v).is_err()

## `n` nested `Some(…)` around `None`.
nest : U64 -> Value
nest = |n| {
	var $v = Tag("None", [])
	var $i = 0.U64
	while $i < n {
		$v = Tag("Some", [$v])
		$i = $i + 1
	}
	$v
}

# Your own limits: for the JSON text, and with `within_limits` for the value.
small : Value.Limits
small = { ..Value.default_limits, max_depth: 2, max_number_length: 3 }

expect FromJson.one_with("[[[[[[[[[0]]]]]]]]]", small, |_| Ok({})) == Ok({})
expect FromJson.one_with("[[[[[[[[[[0]]]]]]]]]]", small, |_| Ok({})) == Err(Syntax({ code: "nesting-too-deep", reason: "JSON nested deeper than 9 levels", line: 1, column: 10 }))
expect FromJson.one_with("123", small, FromJson.u16) == Ok(123)
expect FromJson.one_with("1234", small, FromJson.u16) == Err(Syntax({ code: "number-too-long", reason: "number literal longer than 3 characters", line: 1, column: 1 }))
expect FromJson.lines_with("123\n123\n", small, FromJson.u16) == Ok([123, 123]) and FromJson.lines_with("123\n1234\n", small, FromJson.u16).is_err()
expect FromJson.within_limits(Ok(nest(2)), |v| v, small).is_ok()
expect FromJson.within_limits(Ok(nest(3)), |v| v, small).map_ok(|_| {}).map_err(Decode.message) == Err("nesting deeper than 2 levels")

# Lengths count on the haus value (spec §16, "Limits"): a string's characters after
# its escapes are read, bytes two characters per byte although JSON spells them in
# base64. Exactly at the limit is accepted, one more is not.
limited : Str, U64, (JsonValue -> Try(a, Decode.Error)), (a -> Value) -> Str
limited = |text, max, reader, encode| {
	limits = { ..Value.default_limits, max_string_length: max }
	match FromJson.one_with(text, limits, |j| FromJson.within_limits(reader(j), encode, limits)) {
		Ok(_) => "ok"
		Err(Decode(e)) => e.code
		Err(Syntax(e)) => e.code
	}
}

expect limited("\"\\u00e9\\u00e9\\u00e9\\u00e9\"", 4, FromJson.str, |s| Text(s)) == "ok" and limited("\"\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\"", 4, FromJson.str, |s| Text(s)) == "string-too-long"
expect limited("\"\\ud83d\\ude00abc\"", 4, FromJson.str, |s| Text(s)) == "ok"
expect limited("\"AAA=\"", 4, FromJson.bytes, |b| Bytes(b)) == "ok" and limited("\"AAAA\"", 4, FromJson.bytes, |b| Bytes(b)) == "string-too-long"
expect limited("\"AAAA\"", 6, FromJson.bytes, |b| Bytes(b)) == "ok" and limited("\"AAAAAA==\"", 6, FromJson.bytes, |b| Bytes(b)) == "string-too-long"
# One byte is 2 characters, although its base64 has 4.
expect limited("\"AA==\"", 2, FromJson.bytes, |b| Bytes(b)) == "ok"
# Map keys are keys; Int64 and Decimal strings are numbers, which the number limit bounds.
expect limited("{\"abcd\": 1}", 4, |j| FromJson.map(j, FromJson.i32), |m| Rec(m.map(|(k, n)| (k, Num(n.to_str()))))) == "ok"
expect limited("{\"abcde\": 1}", 4, |j| FromJson.map(j, FromJson.i32), |m| Rec(m.map(|(k, n)| (k, Num(n.to_str()))))) == "key-too-long"
expect limited("\"123456\"", 4, FromJson.i64, |n| Num(n.to_str())) == "ok"
expect limited("{\"_tag\": \"Abcde\"}", 4, FromJson.any_tag, |_| Tag("Abcde", [])) == "tag-too-long"

# Up to the supported depth; a deeper limit is an error that names the maximum.
at_max : Value.Limits
at_max = { ..Value.default_limits, max_depth: Value.max_supported_depth }

expect FromJson.within_limits(Ok(nest(1024)), |v| v, at_max).is_ok()
expect FromJson.within_limits(Ok(nest(1025)), |v| v, at_max).map_ok(|_| {}).map_err(Decode.message) == Err("nesting deeper than 1024 levels")
expect {
	text = "${"{\"_tag\":\"Some\",\"value\":".repeat(1024)}{\"_tag\":\"None\"}${"}".repeat(1024)}"
	FromJson.one_with(text, at_max, |j| FromJson.within_limits(loop(j), |v| v, at_max)).is_ok()
}
too_deep : Value.Limits
too_deep = { ..Value.default_limits, max_depth: 1025 }

unsupported : Str
unsupported = "max_depth 1025 is more than the supported maximum, 1024"
expect FromJson.one_with("1", too_deep, FromJson.u16) == Err(Syntax({ code: "unsupported-depth", reason: unsupported, line: 1, column: 1 }))
expect FromJson.lines_with("1", too_deep, FromJson.u16) == Err(Syntax({ code: "unsupported-depth", reason: unsupported, line: 1, column: 1 }))
expect FromJson.within_limits(Ok(nest(1)), |v| v, too_deep).map_ok(|_| {}).map_err(Decode.message) == Err(unsupported)

## `type Loop = Maybe Loop` read from schema-based JSON, as its haus value.
loop : JsonValue -> Try(Value, Decode.Error)
loop = |j| FromJson.maybe(j, True, loop).map_ok(
	|m| match m {
		None => Tag("None", [])
		Some(v) => Tag("Some", [v])
	},
)

# Error codes (spec §17) of schema-based JSON.
code_of : Str, (JsonValue -> Try(a, Decode.Error)) -> Str
code_of = |text, reader| match FromJson.one(text, reader) {
	Ok(_) => "ok"
	Err(Decode(e)) => "${e.code} at ${ErrorCode.place(e.path)}"
	Err(Syntax(e)) => e.code
}

expect code_of("\"CzQ\"", FromJson.bytes) == "invalid-base64 at $" and code_of("1", FromJson.bytes) == "type-mismatch at $"
expect code_of("\"-12\"", FromJson.i32) == "type-mismatch at $" and code_of("1.0", FromJson.i32) == "not-an-integer at $" and code_of("2147483648", FromJson.i32) == "out-of-range at $"
expect code_of("123", FromJson.int) == "type-mismatch at $" and code_of("\"1e3\"", FromJson.int) == "not-an-integer at $" and code_of("\"+1\"", FromJson.int) == "invalid-number at $" and code_of("\"007\"", FromJson.int) == "invalid-number at $"
# An `Int` string within the number limit (spec §16.3), whether or not its hex form would fit; a bounded type checks its range.
expect FromJson.one("\"-${"9".repeat(999)}\"", FromJson.int).map_ok(|n| n.to_str()) == Ok("-${"9".repeat(999)}")
expect code_of("\"1${"0".repeat(1000)}\"", FromJson.int) == "number-too-long at $" and code_of("\"1${"0".repeat(1000)}\"", FromJson.u64) == "out-of-range at $"
expect code_of("\"9223372036854775808\"", FromJson.i64) == "out-of-range at $" and code_of("1e400", FromJson.f64) == "out-of-range at $" and code_of("\"1.5\"", FromJson.f64) == "type-mismatch at $"
expect code_of("19.90", FromJson.decimal) == "type-mismatch at $" and code_of("\"19,90\"", FromJson.decimal) == "invalid-number at $" and code_of("\"2026-02-30\"", FromJson.time("Date")) == "invalid-time at $"
expect code_of("null", |j| FromJson.maybe(j, True, |x| FromJson.maybe(x, False, FromJson.i32))) == "type-mismatch at $"
expect code_of("{\"_tag\": \"Some\", \"value\": null, \"x\": 1}", |j| FromJson.maybe(j, True, |x| FromJson.maybe(x, False, FromJson.i32))) == "unexpected-member at $.x"
expect code_of("{\"_tag\": \"Just\", \"value\": 1}", |j| FromJson.maybe(j, True, FromJson.i32)) == "unknown-tag at $._tag" and code_of("{\"value\": 1}", |j| FromJson.maybe(j, True, FromJson.i32)) == "missing-member at $"
expect code_of("{\"_tag\": \"Some\"}", |j| FromJson.maybe(j, True, FromJson.i32)) == "missing-member at $" and code_of("{\"_tag\": 1}", |j| FromJson.maybe(j, True, FromJson.i32)) == "missing-member at $._tag"
expect code_of("{\"_tag\": \"Fine\"}", |j| FromJson.result(j, FromJson.i32, FromJson.str)) == "unknown-tag at $._tag" and code_of("{\"_tag\": \"Ok\", \"value\": \"x\"}", |j| FromJson.result(j, FromJson.i32, FromJson.str)) == "type-mismatch at $.value"
expect code_of("{\"_tag\": \"hexagon\"}", FromJson.any_tag) == "invalid-tag at $._tag" and code_of("{\"_tag\": \"Hexagon\", \"_args\": []}", FromJson.any_tag) == "haus-json-form at $._args" and code_of("{\"_tag\": \"Hexagon\", \"_args\": 5}", FromJson.any_tag) == "haus-json-form at $._args"
expect code_of("{\"_tag\": \"Hexagon\", \"_args\": [1]}", FromJson.any_tag) == "haus-json-form at $._args[0]" and code_of("{\"_tag\": \"Hexagon\", \"_args\": [{\"_haus\": 1, \"_value\": \"a\"}]}", FromJson.any_tag) == "haus-json-form at $._args[0]"
expect code_of("{\"pin\": 98765}", |j| FromJson.field(FromJson.object(j, "Login")?, "pin", |x| FromJson.secret(x, "Secret UInt16", FromJson.u16))) == "invalid-secret at $.pin"
expect code_of("{\"id\": 1, \"x\": 2}", |j| FromJson.closed(FromJson.object(j, "Strict")?, ["id"])) == "unknown-field at $.x" and code_of("{}", |j| FromJson.field(FromJson.object(j, "User")?, "id", FromJson.i32)) == "missing-field at $"
expect code_of("{\"_tag\": \"Point\", \"values\": [1]}", |j| FromJson.args(FromJson.variant(j, "Shape")?.1, 2)) == "wrong-payload at $.values" and code_of("1", FromJson.any) == "haus-json-form at $" and code_of("{\"_haus\": 1, \"_value\": \"x\"}", FromJson.any) == "haus-json-form at $"
expect code_of("{\"a\": 1, \"a\": 2}", |j| FromJson.map(j, FromJson.i32)) == "duplicate-key" and code_of("{\"pt-BR\": \"x\"}", |j| FromJson.map(j, FromJson.i32)) == "type-mismatch at $[\"pt-BR\"]"
expect code_of("1", |_| FromJson.no_json_form("Odd", "_args")) == "no-json-form at $" and FromJson.within_depth(Ok(nest(257)), |v| v).map_ok(|_| {}).map_err(|e| e.code) == Err("nesting-too-deep")
# A record case by name: the record is read from the tag's object, without `"_tag"`.
expect {
	box = |j| {
		(_, ms) = FromJson.variant(j, "Boxed")?
		FromJson.record_case(
			ms,
			|r| {
				fs = FromJson.object(r, "BoxRec")?
				FromJson.closed(fs, ["w"])?
				FromJson.field(fs, "w", FromJson.i32)
			},
		)
	}
	FromJson.one("{\"_tag\": \"Box\", \"w\": 1}", box) == Ok(1) and code_of("{\"_tag\": \"Box\", \"w\": 1, \"x\": 2}", box) == "unknown-field at $.x" and code_of("{\"_tag\": \"Box\", \"value\": {\"w\": 1}}", box) == "unknown-field at $.value"
}
