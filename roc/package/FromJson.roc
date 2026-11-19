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
	## against the default limits; for `limits`, check with `within_limits`:
	## `|j| FromJson.within_limits(j, Order.read_json_order, Order.encode_order, limits)`.
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

	## What `reader` (a generated `read_json_<name>`) reads from `json`, if
	## the haus value it encodes to (with `encode`) nests at most 256 levels
	## (spec §16, "Limits": a form can take several JSON levels for one haus
	## level, so the JSON may nest deeper and the value is checked after
	## reading). Before reading, the JSON must nest at most 4·256 + 1 levels,
	## as the parser takes it, so that JSON built in code nested deeper fails
	## with `nesting-too-deep` instead of overflowing the stack, and have at
	## most `Value.max_nodes` values, so that JSON built in code that shares
	## its parts (a DAG), which reading visits each time they are reached,
	## fails with `too-many-nodes` instead of expanding without bound (spec
	## §9.8). A generated `from_json_<name>` reads so; the readers it is built
	## from don't check.
	within_depth : JsonValue, (JsonValue -> Try(a, Decode.Error)), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)) -> Try(a, Decode.Error)
	within_depth = |json, reader, encode| within_limits(json, reader, encode, Value.default_limits)

	## `within_depth` for the depth limit of `limits`, which must be at most
	## `Value.max_supported_depth`:
	##
	##     FromJson.one_with(text, limits, |j| FromJson.within_limits(j, Order.read_json_order, Order.encode_order, limits))
	##
	## Lengths are checked here too, on the haus value (spec §16, "Limits"): a
	## string's characters after its escapes are read, keys and tags as haus keys
	## and tags, bytes as two characters per byte, as in the hex of a haus byte
	## string, although JSON spells them in base64. The value is checked as
	## `encode` checks it for these limits; like its errors inside a `Secret`,
	## these say what, not where.
	within_limits : JsonValue, (JsonValue -> Try(a, Decode.Error)), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)), Value.Limits -> Try(a, Decode.Error)
	within_limits = |json, reader, encode, limits| read_within(json, reader, encode, limits, Value.max_nodes)

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

	## A type with a codec whose parts have codecs of their own: `check`
	## runs the parts' codecs first, each at its own place in the JSON, then
	## the base reader and the codec run (spec §13.4, as `Decode.codec_inside`).
	codec_inside : JsonValue, (JsonValue -> Try({}, Decode.Error)), (JsonValue -> Try(b, Decode.Error)), (b -> Try(t, Str)) -> Try(t, Decode.Error)
	codec_inside = |j, check, base, decode| {
		check(j)?
		codec(j, base, decode)
	}

	# The checks of a codec's type for the codecs of its parts, as
	# `Decode.check_items` and the others do for haus values: JSON of another
	# shape is left to the base reader, which runs next and reports it.

	## Each item of an array.
	check_items : JsonValue, (JsonValue -> Try({}, Decode.Error)) -> Try({}, Decode.Error)
	check_items = |j, check| match j {
		Array(items) => {
			var $i = 0.U64
			for x in items {
				at(check(x), "[${$i.to_str()}]")?
				$i = $i + 1
			}
			Ok({})
		}
		_ => Ok({})
	}

	## Each member of an object used as a `Map`.
	check_entries : JsonValue, (JsonValue -> Try({}, Decode.Error)) -> Try({}, Decode.Error)
	check_entries = |j, check| match j {
		Object(members) => {
			for (k, x) in members {
				at(check(x), ErrorCode.path_key(k))?
			}
			Ok({})
		}
		_ => Ok({})
	}

	## The members of a record (or of a record case's object) that have checks, where present.
	check_fields : JsonValue, List((Str, (JsonValue -> Try({}, Decode.Error)))) -> Try({}, Decode.Error)
	check_fields = |j, checks| match j {
		Object(members) => {
			for (k, x) in members {
				match checks.find_first(|(name, _)| name == k) {
					Ok((_, check)) => at(check(x), ErrorCode.path_key(k))?
					Err(_) => {}
				}
			}
			Ok({})
		}
		_ => Ok({})
	}

	## `Maybe a` (see `maybe`): the value of `Some`.
	check_maybe : JsonValue, Bool, (JsonValue -> Try({}, Decode.Error)) -> Try({}, Decode.Error)
	check_maybe = |j, nullable, check|
		if !nullable {
			match j {
				Null => Ok({})
				_ => check(j)
			}
		} else {
			check_cases(j, [("Some", Args([check]))])
		}

	## The payload of a variant's case: its positional values (`Args`:
	## `"value"`, or `"values"` for two or more), or the members of its
	## record beside `"_tag"` (`Fields`).
	check_cases : JsonValue, List((Str, [Args(List((JsonValue -> Try({}, Decode.Error)))), Fields(List((Str, (JsonValue -> Try({}, Decode.Error)))))])) -> Try({}, Decode.Error)
	check_cases = |j, cases| match j {
		Object(members) =>
			match members.find_first(|(k, _)| k == "_tag") {
				Ok((_, String(tag))) =>
					match cases.find_first(|(name, _)| name == tag) {
						Ok((_, Fields(checks))) => check_fields(j, checks)
						Ok((_, Args([check]))) =>
							match members.find_first(|(k, _)| k == "value") {
								Ok((_, x)) => at(check(x), ".value")
								Err(_) => Ok({})
							}
						Ok((_, Args(checks))) =>
							match members.find_first(|(k, _)| k == "values") {
								Ok((_, Array(items))) if items.len() == checks.len() => {
									var $i = 0.U64
									for (x, check) in items.map2(checks, |x, check| (x, check)) {
										at(check(x), ".values[${$i.to_str()}]")?
										$i = $i + 1
									}
									Ok({})
								}
								_ => Ok({})
							}
						Err(_) => Ok({})
					}
				_ => Ok({})
			}
		_ => Ok({})
	}

	## Inside a `Secret`: an error says only that it isn't a valid `what`, at the secret.
	check_secret : JsonValue, Str, (JsonValue -> Try({}, Decode.Error)) -> Try({}, Decode.Error)
	check_secret = |j, what, check| match check(j) {
		Ok({}) => Ok({})
		Err(_) => Decode.fail(ErrorCode.invalid_secret, "not a valid ${what} (the value is hidden)")
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
				_ => Decode.unknown_tag(tag, ["None", "Some"])
			}
		}

	## `Result e a`: `{"_tag": "Ok", "value": …}` or `{"_tag": "Err", "value": …}`.
	result : JsonValue, (JsonValue -> Try(a, Decode.Error)), (JsonValue -> Try(e, Decode.Error)) -> Try(Try(a, e), Decode.Error)
	result = |j, ok, err| {
		(tag, members) = variant(j, "Result")?
		if tag != "Ok" and tag != "Err" {
			return Decode.unknown_tag(tag, ["Ok", "Err"])
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
	## Without a `"_tag"`, `missing-member`; with one that isn't a string, or
	## isn't a tag (spec §4), `invalid-tag` (spec §16.3). Errors about the tag
	## are at the variant's object, as an unknown tag is.
	variant : JsonValue, Str -> Try((Str, List((Str, JsonValue))), Decode.Error)
	variant = |j, what| match j {
		Object(members) => match members.find_first(|(k, _)| k == "_tag") {
			Ok((_, String(tag))) if JsonValue.is_tag_name(tag) => Ok((tag, members))
			Ok((_, String(_))) => Decode.fail(ErrorCode.invalid_tag, "\"_tag\" is not a tag name (A to Z, then letters, digits and _)")
			Ok((_, other)) => Decode.fail(ErrorCode.invalid_tag, "expected a tag name in \"_tag\", found ${JsonValue.describe(other)}")
			Err(_) => Decode.fail(ErrorCode.missing_member, "expected an object with \"_tag\" (${what})")
		}
		_ => expected("an object with \"_tag\" (${what})", j)
	}

	## The payload of a positional case with `n` values: nothing besides
	## `"_tag"` for none, `"value"` for one, `"values"` (an array of `n`) for
	## more. A `"values"` that isn't an array of `n` is `wrong-payload`, at the
	## variant's object (spec §16.3).
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
			Ok((_, Array(items))) => Decode.fail(ErrorCode.wrong_payload, "expected ${n.to_str()} values in \"values\", found ${items.len().to_str()}")
			Ok((_, other)) => Decode.fail(ErrorCode.wrong_payload, "expected an array of ${n.to_str()} values in \"values\", found ${JsonValue.describe(other)}")
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
			return Decode.fail(ErrorCode.invalid_tag, "\"_tag\" is not a tag name (A to Z, then letters, digits and _)")
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

## `within_limits`, with at most `max_nodes` values in `json`.
read_within : JsonValue, (JsonValue -> Try(a, Decode.Error)), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)), Value.Limits, U64 -> Try(a, Decode.Error)
read_within = |json, reader, encode, limits, max_nodes| {
	Value.check_limits(limits).map_err(|reason| { code: ErrorCode.unsupported_depth, reason, path: "" })?
	nests_within(json, 4 * limits.max_depth + 1, max_nodes)?
	x = reader(json)?
	match encode(x, Encode.top_with(limits)) {
		Ok(_) => Ok(x)
		Err(e) => Err({ ..e, path: "" })
	}
}

## Whether `json` nests at most `max` levels of arrays and objects, as the
## parser takes it, and has at most `max_nodes` values, a part shared in JSON
## built in code counted each time it is reached: `nesting-too-deep` at the
## first array or object too deep, or `too-many-nodes`, otherwise. Walked
## with a list rather than recursion, so that JSON built in code, however
## deep, is checked without overflowing the stack.
nests_within : JsonValue, U64, U64 -> Try({}, Decode.Error)
nests_within = |json, max, max_nodes| {
	# The containers from `json` down to the one being walked, each with its next item.
	var $path = []
	var $next = if (opens(json)) Ok(json) else Err({})
	var $nodes = 1.U64
	while True {
		match $next {
			Ok(j) => {
				if $path.len().to_u64() >= max {
					return Decode.fail(ErrorCode.nesting_too_deep, "JSON nested deeper than ${max.to_str()} levels")
				}
				$path = $path.append((j, 0.U64))
			}
			Err(_) => {}
		}
		match $path.last() {
			Ok((j, i)) => {
				$path = $path.drop_last(1)
				match item(j, i) {
					Ok(x) => {
						$nodes = $nodes + 1
						if $nodes > max_nodes {
							return Decode.fail(ErrorCode.too_many_nodes, "JSON value has more than ${max_nodes.to_str()} nodes")
						}
						$path = $path.append((j, i + 1))
						$next = if (opens(x)) Ok(x) else Err({})
					}
					Err(_) => {
						$next = Err({})
					}
				}
			}
			Err(_) => {
				return Ok({})
			}
		}
	}
}

## An array or an object.
opens : JsonValue -> Bool
opens = |j| match j {
	Array(_) | Object(_) => True
	_ => False
}

## Item `i` of an array, or the value of member `i` of an object.
item : JsonValue, U64 -> Try(JsonValue, [OutOfBounds])
item = |j, i| match j {
	Array(items) => items.get(i)
	Object(members) => members.get(i).map_ok(|(_, v)| v)
	_ => Err(OutOfBounds)
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
		Other(tag, args) => canonical_text(Tag(tag, args))
		Bare(tag) => tag
	},
) == Ok("Hexagon{sides:6}")
# `_args` alone: the arguments; beside other members, or `args`: a record payload.
expect FromJson.one("{\"_tag\": \"Hexagon\", \"_args\": [{\"_num\": \"1\"}, \"a\"]}", FromJson.any_tag).map_ok(
	|t| match t {
		Other(tag, args) => canonical_text(Tag(tag, args))
		Bare(tag) => tag
	},
) == Ok("Hexagon(1,\"a\")")
expect FromJson.one("{\"_tag\": \"Run\", \"args\": [1, 2]}", FromJson.any_tag).map_ok(
	|t| match t {
		Other(tag, args) => canonical_text(Tag(tag, args))
		Bare(tag) => tag
	},
) == Ok("Run{args:[1,2]}")
expect FromJson.one("{\"_tag\": \"Hexagon\", \"_args\": [{\"_num\": \"1\"}], \"x\": 2}", FromJson.any_tag).map_ok(
	|t| match t {
		Other(tag, args) => canonical_text(Tag(tag, args))
		Bare(tag) => tag
	},
) == Ok("Hexagon{_args:[{_num:\"1\"}],x:2}")
# `Any` inside schema-based JSON accepts raw DEL, C1 and bidi controls.
expect FromJson.one("\"a\u(7F)\u(85)\u(202E)\"", FromJson.any).map_ok(canonical_text) == Ok("\"a\\u{7F}\\u{85}\\u{202E}\"")
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
# In JSON Lines a place starts with the line's index (spec §16.3); an empty
# line, or a byte order mark at the start of a later line, is `json-syntax` at its line.
expect code_of_lines("1\n2\n\"x\"\n", FromJson.u8) == "type-mismatch at $[2]"
expect code_of_lines("{\"price\": 1}\n{\"price\": \"1\"}", |j| FromJson.field(FromJson.object(j, "Item")?, "price", FromJson.i32)) == "type-mismatch at $[1].price"
expect code_of_lines("1\n\n2\n", FromJson.u8) == "json-syntax at line 2" and code_of_lines("1\r\n\u(FEFF)2\r\n", FromJson.u8) == "json-syntax at line 2"
expect FromJson.within_depth(Null, |_| Ok(Arr([Rec([("a", Tag("Some", [Arr([])]))])])), Encode.any).map_ok(canonical_text) == Ok("[{a:Some([])}]")
expect FromJson.within_depth(Null, |_| Ok(nest(256)), Encode.any).is_ok()
expect FromJson.within_depth(Null, |_| Ok(nest(257)), Encode.any).map_ok(|_| {}).map_err(Decode.message) == Err("nesting deeper than 256 levels")
expect FromJson.within_depth(Null, |_| Ok(Tag("Box", [Rec([("w", nest(255))])])), Encode.any).is_ok()
expect FromJson.within_depth(Null, |_| Ok(Tag("Box", [Rec([("w", nest(256))])])), Encode.any).is_err()

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
expect FromJson.within_limits(Null, |_| Ok(nest(2)), Encode.any, small).is_ok()
expect FromJson.within_limits(Null, |_| Ok(nest(3)), Encode.any, small).map_ok(|_| {}).map_err(Decode.message) == Err("nesting deeper than 2 levels")

# Lengths count on the haus value (spec §16, "Limits"): a string's characters after
# its escapes are read, bytes two characters per byte although JSON spells them in
# base64. Exactly at the limit is accepted, one more is not.
limited : Str, U64, (JsonValue -> Try(a, Decode.Error)), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)) -> Str
limited = |text, max, reader, encode| {
	limits = { ..Value.default_limits, max_string_length: max }
	match FromJson.one_with(text, limits, |j| FromJson.within_limits(j, reader, encode, limits)) {
		Ok(_) => "ok"
		Err(Decode(e)) => e.code
		Err(Syntax(e)) => e.code
	}
}

expect limited("\"\\u00e9\\u00e9\\u00e9\\u00e9\"", 4, FromJson.str, Encode.str) == "ok" and limited("\"\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\"", 4, FromJson.str, Encode.str) == "string-too-long"
expect limited("\"\\ud83d\\ude00abc\"", 4, FromJson.str, Encode.str) == "ok"
expect limited("\"AAA=\"", 4, FromJson.bytes, Encode.bytes) == "ok" and limited("\"AAAA\"", 4, FromJson.bytes, Encode.bytes) == "string-too-long"
expect limited("\"AAAA\"", 6, FromJson.bytes, Encode.bytes) == "ok" and limited("\"AAAAAA==\"", 6, FromJson.bytes, Encode.bytes) == "string-too-long"
# One byte is 2 characters, although its base64 has 4.
expect limited("\"AA==\"", 2, FromJson.bytes, Encode.bytes) == "ok"
# Map keys are keys; Int64 and Decimal strings are numbers, which the number limit bounds.
expect limited("{\"abcd\": 1}", 4, |j| FromJson.map(j, FromJson.i32), |m, e| Encode.map(m, e, |n, e1| Encode.number(n.to_str(), e1))) == "ok"
expect limited("{\"abcde\": 1}", 4, |j| FromJson.map(j, FromJson.i32), |m, e| Encode.map(m, e, |n, e1| Encode.number(n.to_str(), e1))) == "key-too-long"
expect limited("\"123456\"", 4, FromJson.i64, |n, e| Encode.number(n.to_str(), e)) == "ok"
expect limited("{\"_tag\": \"Abcde\"}", 4, FromJson.any_tag, Encode.any_tag) == "tag-too-long"

# Up to the supported depth; a deeper limit is an error that names the maximum.
at_max : Value.Limits
at_max = { ..Value.default_limits, max_depth: Value.max_supported_depth }

expect FromJson.within_limits(Null, |_| Ok(nest(1024)), Encode.any, at_max).is_ok()
expect FromJson.within_limits(Null, |_| Ok(nest(1025)), Encode.any, at_max).map_ok(|_| {}).map_err(Decode.message) == Err("nesting deeper than 1024 levels")
expect {
	text = "${"{\"_tag\":\"Some\",\"value\":".repeat(1024)}{\"_tag\":\"None\"}${"}".repeat(1024)}"
	FromJson.one_with(text, at_max, |j| FromJson.within_limits(j, loop, Encode.any, at_max)).is_ok()
}
too_deep : Value.Limits
too_deep = { ..Value.default_limits, max_depth: 1025 }

unsupported : Str
unsupported = "max_depth 1025 is more than the supported maximum, 1024"
expect FromJson.one_with("1", too_deep, FromJson.u16) == Err(Syntax({ code: "unsupported-depth", reason: unsupported, line: 1, column: 1 }))
expect FromJson.lines_with("1", too_deep, FromJson.u16) == Err(Syntax({ code: "unsupported-depth", reason: unsupported, line: 1, column: 1 }))
expect FromJson.within_limits(Null, |_| Ok(nest(1)), Encode.any, too_deep).map_ok(|_| {}).map_err(Decode.message) == Err(unsupported)

## `type Loop = Maybe Loop` read from schema-based JSON, as its haus value.
loop : JsonValue -> Try(Value, Decode.Error)
loop = |j| FromJson.maybe(j, True, loop).map_ok(
	|m| match m {
		None => Tag("None", [])
		Some(v) => Tag("Some", [v])
	},
)

# Error codes (spec §17) of schema-based JSON Lines, with the place.
code_of_lines : Str, (JsonValue -> Try(a, Decode.Error)) -> Str
code_of_lines = |text, reader| match FromJson.lines(text, reader) {
	Ok(_) => "ok"
	Err(Decode(e)) => "${e.code} at ${ErrorCode.place(e.path)}"
	Err(Syntax(e)) => "${e.code} at line ${e.line.to_str()}"
}

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
expect code_of("{\"_tag\": \"Just\", \"value\": 1}", |j| FromJson.maybe(j, True, FromJson.i32)) == "unknown-tag at $" and code_of("{\"value\": 1}", |j| FromJson.maybe(j, True, FromJson.i32)) == "missing-member at $"
expect code_of("{\"_tag\": \"Some\"}", |j| FromJson.maybe(j, True, FromJson.i32)) == "missing-member at $" and code_of("{\"_tag\": 1}", |j| FromJson.maybe(j, True, FromJson.i32)) == "invalid-tag at $"
expect code_of("{\"_tag\": \"Fine\"}", |j| FromJson.result(j, FromJson.i32, FromJson.str)) == "unknown-tag at $" and code_of("{\"_tag\": \"Ok\", \"value\": \"x\"}", |j| FromJson.result(j, FromJson.i32, FromJson.str)) == "type-mismatch at $.value"
expect code_of("{\"_tag\": \"hexagon\"}", FromJson.any_tag) == "invalid-tag at $" and code_of("{\"_tag\": \"Hexagon\", \"_args\": []}", FromJson.any_tag) == "haus-json-form at $._args" and code_of("{\"_tag\": \"Hexagon\", \"_args\": 5}", FromJson.any_tag) == "haus-json-form at $._args"
expect code_of("{\"_tag\": \"Hexagon\", \"_args\": [1]}", FromJson.any_tag) == "haus-json-form at $._args[0]" and code_of("{\"_tag\": \"Hexagon\", \"_args\": [{\"_haus\": 1, \"_value\": \"a\"}]}", FromJson.any_tag) == "haus-json-form at $._args[0]"
expect code_of("{\"pin\": 98765}", |j| FromJson.field(FromJson.object(j, "Login")?, "pin", |x| FromJson.secret(x, "Secret UInt16", FromJson.u16))) == "invalid-secret at $.pin"
expect code_of("{\"id\": 1, \"x\": 2}", |j| FromJson.closed(FromJson.object(j, "Strict")?, ["id"])) == "unknown-field at $.x" and code_of("{}", |j| FromJson.field(FromJson.object(j, "User")?, "id", FromJson.i32)) == "missing-field at $"
expect code_of("{\"_tag\": \"Point\", \"values\": [1]}", |j| FromJson.args(FromJson.variant(j, "Shape")?.1, 2)) == "wrong-payload at $" and code_of("1", FromJson.any) == "haus-json-form at $" and code_of("{\"_haus\": 1, \"_value\": \"x\"}", FromJson.any) == "haus-json-form at $"
expect code_of("{\"a\": 1, \"a\": 2}", |j| FromJson.map(j, FromJson.i32)) == "duplicate-key" and code_of("{\"pt-BR\": \"x\"}", |j| FromJson.map(j, FromJson.i32)) == "type-mismatch at $[\"pt-BR\"]"
# A `"_tag"` that isn't a string, or isn't a tag, is `invalid-tag`; a `"values"` that isn't an array of the case's length `wrong-payload`: both at the variant (spec §16.3).
expect ["{\"_tag\": 1}", "{\"_tag\": null}", "{\"_tag\": [\"A\"]}", "{\"_tag\": \"\"}", "{\"_tag\": \"a\"}"].map(|s| code_of(s, FromJson.any_tag)) == ["invalid-tag at $", "invalid-tag at $", "invalid-tag at $", "invalid-tag at $", "invalid-tag at $"]
expect code_of("{\"_tag\": \"some\", \"value\": 1}", |j| FromJson.maybe(j, True, FromJson.i32)) == "invalid-tag at $" and code_of("{\"_tag\": true}", |j| FromJson.result(j, FromJson.i32, FromJson.str)) == "invalid-tag at $"
expect ["5", "null", "{}", "[]", "[1]", "[1, 2, 3]"].map(|vs| code_of("{\"_tag\": \"Point\", \"values\": ${vs}}", |j| FromJson.args(FromJson.variant(j, "Shape")?.1, 2))) == ["wrong-payload at $", "wrong-payload at $", "wrong-payload at $", "wrong-payload at $", "wrong-payload at $", "wrong-payload at $"]
expect code_of("1", |_| FromJson.no_json_form("Odd", "_args")) == "no-json-form at $" and FromJson.within_depth(Null, |_| Ok(nest(257)), Encode.any).map_ok(|_| {}).map_err(|e| e.code) == Err("nesting-too-deep")
# Codecs run from the inside out (spec §13.4): a part's codec, checked first,
# rejects at its own place in the JSON.
expect {
	currency = |c| FromJson.codec(
		c,
		FromJson.any_tag,
		|t| match t {
			Bare("EUR") => Ok({})
			_ => Err("not a currency")
		},
	)
	check = |j| FromJson.check_cases(j, [("Money", Args([|_| Ok({}), currency]))])
	money = |j| FromJson.codec_inside(
		j,
		check,
		FromJson.any_tag,
		|t| match t {
			Other("Money", _) => Ok({})
			_ => Err("not money")
		},
	)
	m = |c| "{\"_tag\": \"Money\", \"values\": [\"1\", {\"_tag\": \"${c}\"}]}"
	code_of("[${m("EUR")}, ${m("Eur")}]", |j| FromJson.list(j, money)) == "type-mismatch at $[1].values[1]" and code_of("[${m("EUR")}]", |j| FromJson.list(j, money)) == "ok"
}
expect {
	fails = |_| Decode.fail("type-mismatch", "no")
	at_place = |text, check| code_of(text, check)
	at_place("[1, 2]", |j| FromJson.check_items(j, fails)) == "type-mismatch at $[0]"
		and at_place("{\"pt-BR\": 1}", |j| FromJson.check_entries(j, fails)) == "type-mismatch at $[\"pt-BR\"]"
		and at_place("{\"_tag\": \"Circle\", \"r\": 1}", |j| FromJson.check_cases(j, [("Circle", Fields([("r", fails)]))])) == "type-mismatch at $.r"
		and at_place("{\"_tag\": \"Wrap\", \"value\": 1}", |j| FromJson.check_cases(j, [("Wrap", Args([fails]))])) == "type-mismatch at $.value"
		and at_place("{\"_tag\": \"Some\", \"value\": 1}", |j| FromJson.check_maybe(j, True, fails)) == "type-mismatch at $.value"
		and at_place("1", |j| FromJson.check_maybe(j, False, fails)) == "type-mismatch at $" and at_place("null", |j| FromJson.check_maybe(j, False, fails)) == "ok"
		and at_place("1", |j| FromJson.check_secret(j, "Secret Money", fails)) == "invalid-secret at $"
}

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

# JSON built in code may nest deeper than any parser takes: `within_depth`
# checks it before reading (at most 4·256 + 1 levels, as the parser takes it),
# instead of overflowing the stack. 150,000 levels: about as deep as `roc test`
# drops a value.
expect {
	var $j = Array([])
	var $i = 0
	while $i < 150_000 {
		$j = Array([$j])
		$i = $i + 1
	}
	FromJson.within_depth($j, |x| FromJson.list(x, |_| Ok({})), |_, e| Encode.made(Num("0"), e)).map_ok(|_| {}) == Err({ code: "nesting-too-deep", reason: "JSON nested deeper than 1025 levels", path: "" })
}

## `n` nested `{"_tag": "Some", "value": …}` around `{"_tag": "None"}`.
somes : U64 -> JsonValue
somes = |n| {
	var $j = Object([("_tag", String("None"))])
	var $i = 0
	while $i < n {
		$j = Object([("_tag", String("Some")), ("value", $j)])
		$i = $i + 1
	}
	$j
}

expect FromJson.within_depth(somes(256), loop, Encode.any).is_ok() and FromJson.within_depth(somes(257), loop, Encode.any).map_err(|e| e.reason).map_ok(|_| {}) == Err("nesting deeper than 256 levels")
expect FromJson.within_depth(somes(1026), loop, Encode.any).map_err(|e| e.reason).map_ok(|_| {}) == Err("JSON nested deeper than 1025 levels")

# JSON built in code may share its parts (a DAG, spec §9.8): `shared_json(n)`
# is n + 1 arrays in memory but 2^(n + 1) − 1 values, which reading visits.
# They are counted first, so 2^41 − 1 fail at the limit, before anything is read.
shared_json : U64 -> JsonValue
shared_json = |levels| {
	var $j = Array([])
	var $i = 0
	while $i < levels {
		$j = Array([$j, $j])
		$i = $i + 1
	}
	$j
}

## The values in nested arrays, as reading visits them.
values_in : JsonValue -> Try(U64, Decode.Error)
values_in = |j| FromJson.list(j, values_in).map_ok(|counts| counts.fold(1, |a, b| a + b))

## How `values_in` writes what it read: as many empty arrays.
encode_count : U64, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)
encode_count = |n, e| Encode.list(List.repeat(n, 0), e, |_, e1| Encode.list([], e1, |_, e2| Encode.number("0", e2)))

expect read_within(shared_json(40), values_in, encode_count, Value.default_limits, 100_000).map_ok(|_| {}) == Err({ code: "too-many-nodes", reason: "JSON value has more than 100000 nodes", path: "" })
# A shared part counts each time it is reached: 2^4 − 1 for three levels, at the limit and one under, read as the tree it stands for.
expect {
	tree = JsonValue.parse("[[[[],[]],[[],[]]],[[[],[]],[[],[]]]]") ?? Null
	[shared_json(3), tree].all(|j| read_within(j, values_in, encode_count, Value.default_limits, 15) == Ok(15) and read_within(j, values_in, encode_count, Value.default_limits, 14).map_err(|e| e.code) == Err("too-many-nodes"))
		and FromJson.within_depth(shared_json(3), values_in, encode_count) == Ok(15)
}

## The canonical form of a value that has one: every parsed value.
canonical_text : Value -> Str
canonical_text = |v| Encode.canonical(v) ?? "(no canonical form)"
