## Writing your own Roc types as plain JSON (spec §16.3): the building blocks
## that generated modules (`haus-gen roc --json`) use, like `Encode` for haus.
##
## A writer is a function `a -> Try(JsonValue, Encode.Error)`. It fails only
## for a value that has no plain JSON: a `Value` built in code that isn't a
## valid haus value (the raw value of an `Any` or an unknown variant), or a
## record payload with a field named `_tag`.
##
##     ToJson.to_str({ id: 1 }, |u| ToJson.object([("id", Present(ToJson.i32(u.id)))]))
##     # Ok("{\"id\":1}")
import Int
import JsonValue
import Secret
import Value
import Encode

ToJson := [].{
	# ── documents ───────────────────────────────────────────

	## A value as plain JSON text, on one line.
	to_str : a, (a -> Try(JsonValue, Encode.Error)) -> Try(Str, Encode.Error)
	to_str = |x, writer| to_str_with(x, writer, Value.default_limits)

	## `to_str` for a reader with other limits (see `JsonValue.to_str_with`):
	## numbers and strings within them, and the JSON nested at most 4·d + 1
	## levels for a depth limit d. Fails if d is more than
	## `Value.max_supported_depth`.
	to_str_with : a, (a -> Try(JsonValue, Encode.Error)), Value.Limits -> Try(Str, Encode.Error)
	to_str_with = |x, writer, limits| {
		Value.check_limits(limits).map_err(|reason| { reason, path: "" })?
		JsonValue.to_str_with(writer(x)?, limits)
	}

	## Values as JSON Lines: each on its own line, followed by a line feed.
	## Errors say which value: `[3].total`.
	lines : List(a), (a -> Try(JsonValue, Encode.Error)) -> Try(Str, Encode.Error)
	lines = |values, writer| lines_with(values, writer, Value.default_limits)

	## `lines` for a reader with other limits (see `to_str_with`).
	lines_with : List(a), (a -> Try(JsonValue, Encode.Error)), Value.Limits -> Try(Str, Encode.Error)
	lines_with = |values, writer, limits| {
		Value.check_limits(limits).map_err(|reason| { reason, path: "" })?
		var $out = []
		var $i = 0.U64
		for v in values {
			$out = $out.append(within(writer(v), "[${$i.to_str()}]")?)
			$i = $i + 1
		}
		JsonValue.write_lines_with($out, limits)
	}

	# ── scalars ─────────────────────────────────────────────

	str : Str -> Try(JsonValue, Encode.Error)
	str = |s| Ok(String(s))

	## `Bytes`: base64 with padding (RFC 4648 §4).
	bytes : List(U8) -> Try(JsonValue, Encode.Error)
	bytes = |b| Ok(String(JsonValue.base64(b)))

	## The prelude's `Bool`: `true` or `false`.
	bool : Bool -> Try(JsonValue, Encode.Error)
	bool = |b| Ok(Boolean(b))

	i8 : I8 -> Try(JsonValue, Encode.Error)
	i8 = |n| Ok(Number(n.to_str()))

	i16 : I16 -> Try(JsonValue, Encode.Error)
	i16 = |n| Ok(Number(n.to_str()))

	i32 : I32 -> Try(JsonValue, Encode.Error)
	i32 = |n| Ok(Number(n.to_str()))

	u8 : U8 -> Try(JsonValue, Encode.Error)
	u8 = |n| Ok(Number(n.to_str()))

	u16 : U16 -> Try(JsonValue, Encode.Error)
	u16 = |n| Ok(Number(n.to_str()))

	u32 : U32 -> Try(JsonValue, Encode.Error)
	u32 = |n| Ok(Number(n.to_str()))

	## `Int64`: a string, since many JSON parsers round integers beyond 2⁵³.
	i64 : I64 -> Try(JsonValue, Encode.Error)
	i64 = |n| Ok(String(n.to_str()))

	## `UInt64`: a string.
	u64 : U64 -> Try(JsonValue, Encode.Error)
	u64 = |n| Ok(String(n.to_str()))

	## `Int`: a string, the decimal integer.
	int : Int -> Try(JsonValue, Encode.Error)
	int = |n| Ok(String(n.to_str()))

	## `Float64`: a number in the spelling of spec §15, or `"NaN"`,
	## `"Infinity"`, `"-Infinity"`.
	f64 : F64 -> Try(JsonValue, Encode.Error)
	f64 = |x| float(Encode.f64(x))

	## `Float32`: as `f64`, in the spelling of a binary32.
	f32 : F32 -> Try(JsonValue, Encode.Error)
	f32 = |x| float(Encode.f32(x))

	## `Decimal`: a string, the normalized literal (`"19.90"`).
	decimal : Str -> Try(JsonValue, Encode.Error)
	decimal = |text| {
		written = Encode.to_str(Num(text))?
		match Value.parse(written) {
			Ok(Num(n)) => Ok(String(n))
			_ => Err({ reason: "not a number literal", path: "" })
		}
	}

	## A std/time value: its string, as written.
	time : Str -> Try(JsonValue, Encode.Error)
	time = |s| Ok(String(s))

	## `Any`: the lossless form (spec §16.2), checked as `Encode.to_str` checks it.
	any : Value -> Try(JsonValue, Encode.Error)
	any = |v| JsonValue.lossless(v)

	## `< >`: any tag, as an unknown value.
	any_tag : [Bare(Str), Other(Str, List(Value))] -> Try(JsonValue, Encode.Error)
	any_tag = |t| match t {
		Bare(tag) => unknown(tag, [])
		Other(tag, args) => unknown(tag, args)
	}

	## `Secret a`: the value in full (the receiver needs it); an error says
	## only that it isn't a valid `what`, never where in it.
	secret : Secret(a), Str, (a -> Try(JsonValue, Encode.Error)) -> Try(JsonValue, Encode.Error)
	secret = |s, what, writer| match writer(s.expose()) {
		Ok(j) => Ok(j)
		Err(_) => Err({ reason: "not a valid ${what} (the value is hidden)", path: "" })
	}

	# ── containers ──────────────────────────────────────────

	list : List(a), (a -> Try(JsonValue, Encode.Error)) -> Try(JsonValue, Encode.Error)
	list = |items, writer| {
		var $out = []
		var $i = 0.U64
		for x in items {
			$out = $out.append(within(writer(x), "[${$i.to_str()}]")?)
			$i = $i + 1
		}
		Ok(Array($out))
	}

	## `Map v`: an object.
	map : List((Str, a)), (a -> Try(JsonValue, Encode.Error)) -> Try(JsonValue, Encode.Error)
	map = |entries, writer| {
		var $out = []
		for (k, x) in entries {
			$out = $out.append((k, within(writer(x), ".${k}")?))
		}
		Ok(Object($out))
	}

	## `Maybe a`: `null` or `a`, when `a`'s JSON can't be `null` (`nullable`
	## is False); otherwise `{"_tag": "None"}` or `{"_tag": "Some", "value": …}`.
	maybe : [None, Some(a)], Bool, (a -> Try(JsonValue, Encode.Error)) -> Try(JsonValue, Encode.Error)
	maybe = |m, nullable, writer| match m {
		None => if (nullable) tagged("None", []) else Ok(Null)
		Some(x) => if (nullable) tagged("Some", [writer(x)]) else writer(x)
	}

	## `Result e a`: `{"_tag": "Ok", "value": …}` or `{"_tag": "Err", "value": …}`.
	result : Try(a, e), (a -> Try(JsonValue, Encode.Error)), (e -> Try(JsonValue, Encode.Error)) -> Try(JsonValue, Encode.Error)
	result = |r, ok, err| match r {
		Ok(x) => tagged("Ok", [ok(x)])
		Err(x) => tagged("Err", [err(x)])
	}

	# ── records and variants ────────────────────────────────

	## An optional field (`key?: T`): left out when `Missing`.
	optional : [Missing, Present(a)], (a -> Try(JsonValue, Encode.Error)) -> [Missing, Present(Try(JsonValue, Encode.Error))]
	optional = |o, writer| match o {
		Missing => Missing
		Present(x) => Present(writer(x))
	}

	## An object from fields in order, leaving out missing optional ones.
	object : List((Str, [Missing, Present(Try(JsonValue, Encode.Error))])) -> Try(JsonValue, Encode.Error)
	object = |fields| members(fields).map_ok(|ms| Object(ms))

	## A case with a record payload: `{"_tag": "Circle", "r": 1.5}`.
	tagged_object : Str, List((Str, [Missing, Present(Try(JsonValue, Encode.Error))])) -> Try(JsonValue, Encode.Error)
	tagged_object = |tag, fields| members(fields).map_ok(|ms| Object([("_tag", String(tag))].concat(ms)))

	## A case with positional values: `{"_tag": "Empty"}`, `{"_tag": "Wrap",
	## "value": 3}`, `{"_tag": "Point", "values": [1, 2]}`.
	tagged : Str, List(Try(JsonValue, Encode.Error)) -> Try(JsonValue, Encode.Error)
	tagged = |tag, values| {
		head = ("_tag", String(tag))
		match values {
			[] => Ok(Object([head]))
			[one] => Ok(Object([head, ("value", within(one, ".value")?)]))
			_ => {
				var $out = []
				var $i = 0.U64
				for v in values {
					$out = $out.append(within(v, ".values[${$i.to_str()}]")?)
					$i = $i + 1
				}
				Ok(Object([head, ("values", Array($out))]))
			}
		}
	}

	## A closed variant whose tags have no payload: the tag as a string.
	tag_name : Str -> Try(JsonValue, Encode.Error)
	tag_name = |tag| Ok(String(tag))

	## An unknown value: `{"_tag": "Hexagon"}`, with `"args"` in the lossless
	## form if it has any (spec §16.3).
	unknown : Str, List(Value) -> Try(JsonValue, Encode.Error)
	unknown = |tag, args| {
		if !JsonValue.is_tag_name(tag) {
			return Err({ reason: "not a tag name: A to Z, then letters, digits and _", path: "" })
		}
		if args.is_empty() {
			return Ok(Object([("_tag", String(tag))]))
		}
		var $out = []
		var $i = 0.U64
		for a in args {
			$out = $out.append(within(JsonValue.lossless(a), ".args[${$i.to_str()}]")?)
			$i = $i + 1
		}
		Ok(Object([("_tag", String(tag)), ("args", Array($out))]))
	}

	## A case whose record payload has a field named `_tag`: it has no plain form (spec §16.3).
	no_plain_form : Str -> Try(JsonValue, Encode.Error)
	no_plain_form = |tag| Err({ reason: "${tag} has a field named _tag, so it has no plain JSON form", path: "" })
}

within : Try(a, Encode.Error), Str -> Try(a, Encode.Error)
within = |result, segment| result.map_err(|{ reason, path }| { reason, path: "${segment}${path}" })

## The members of an object, leaving out missing optional fields.
members : List((Str, [Missing, Present(Try(JsonValue, Encode.Error))])) -> Try(List((Str, JsonValue)), Encode.Error)
members = |fields| {
	var $out = []
	for (key, field) in fields {
		match field {
			Present(j) => {
				$out = $out.append((key, within(j, ".${key}")?))
			}
			Missing => {}
		}
	}
	Ok($out)
}

## A float the haus encoder wrote, as JSON.
float : Value -> Try(JsonValue, Encode.Error)
float = |v| match v {
	Num(text) => Ok(Number(text))
	Tag("NaN", []) => Ok(String("NaN"))
	Tag("Infinity", []) => Ok(String("Infinity"))
	_ => Ok(String("-Infinity"))
}

expect ToJson.to_str([1, 2], |xs| ToJson.list(xs, ToJson.i32)) == Ok("[1,2]")
expect ToJson.to_str(-12, ToJson.i64) == Ok("\"-12\"")
expect ToJson.to_str(0.1, ToJson.f64) == Ok("0.1")
expect ToJson.to_str(-0.0, ToJson.f64) == Ok("-0")
expect ToJson.to_str(0.0 / 0.0, ToJson.f64) == Ok("\"NaN\"")
expect ToJson.to_str("1E5", ToJson.decimal) == Ok("\"1e5\"")
expect ToJson.to_str([0x0B, 0x34], ToJson.bytes) == Ok("\"CzQ=\"")
expect ToJson.to_str(Some(None), |m| ToJson.maybe(m, True, |x| ToJson.maybe(x, False, ToJson.i32))) == Ok("{\"_tag\":\"Some\",\"value\":null}")
expect ToJson.to_str(Some(5), |m| ToJson.maybe(m, False, ToJson.i32)) == Ok("5")
expect ToJson.to_str(Ok(1), |r| ToJson.result(r, ToJson.i32, ToJson.str)) == Ok("{\"_tag\":\"Ok\",\"value\":1}")
expect ToJson.to_str({ id: 1, nick: Missing }, |u| ToJson.object([("id", Present(ToJson.i32(u.id))), ("nick", ToJson.optional(u.nick, ToJson.str))])) == Ok("{\"id\":1}")
expect ToJson.unknown("Hexagon", [Num("1")]).map_ok(JsonValue.to_str) == Ok(Ok("{\"_tag\":\"Hexagon\",\"args\":[{\"num\":\"1\"}]}"))
expect ToJson.unknown("Hexagon", [Num("x")]) == Err({ reason: "not a number literal", path: ".args[0]" })
expect ToJson.lines([1, 2], ToJson.u8) == Ok("1\n2\n")

# Writing for a reader with other limits.
small : Value.Limits
small = { ..Value.default_limits, max_depth: 2, max_string_length: 3 }

expect ToJson.to_str_with("abc", ToJson.str, small) == Ok("\"abc\"") and ToJson.to_str_with("abcd", ToJson.str, small) == Err({ reason: "string longer than 3 characters", path: "" })
expect ToJson.lines_with(["a", "abcd"], ToJson.str, small) == Err({ reason: "string longer than 3 characters", path: "[1]" })
expect ToJson.lines_with(["a", "b"], ToJson.str, small) == Ok("\"a\"\n\"b\"\n")
expect ToJson.to_str_with("a", ToJson.str, { ..Value.default_limits, max_depth: 1025 }) == Err({ reason: "max_depth 1025 is more than the supported maximum, 1024", path: "" })
expect ToJson.lines_with([], ToJson.str, { ..Value.default_limits, max_depth: 1025 }) == Err({ reason: "max_depth 1025 is more than the supported maximum, 1024", path: "" })
