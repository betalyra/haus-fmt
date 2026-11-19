## Writing your own Roc types as schema-based JSON (spec §16.3): the building
## blocks that generated modules (`haus-gen roc --json`) use, like `Encode` for haus.
##
## A writer is a function `a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)`:
## like a haus encoder it knows where it is, and a container fails with
## `nesting-too-deep` at the depth limit of the haus value (spec §7), before
## its contents are written; it counts the values it makes, as a haus
## encoder does, and fails with `step-budget` past `limits.max_steps`.
## Otherwise it fails only for a value that has no schema-based JSON: a
## `Value` built in code that isn't a valid haus value (the raw value of an
## `Any` or an unknown variant), or a record payload with a field named
## `_tag` or `_args`.
##
##     ToJson.to_str({ id: 1 }, |u, e| ToJson.object(e, [("id", ToJson.required(u.id, ToJson.i32))]))
##     # Ok("{\"id\":1}")
##
## Its errors have the codes of spec §17 (`ErrorCode`), like `Encode`'s, and
## `no-json-form` for a record payload with a field named `_tag` or `_args`.
import ErrorCode
import Int
import JsonValue
import Secret
import Value
import Encode

ToJson := [].{
	# ── documents ───────────────────────────────────────────

	## A value as schema-based JSON text, on one line, checked as
	## `JsonValue.to_str` checks it (numbers and nesting of the JSON), and
	## the haus value's depth by the writer. Lengths are checked by
	## `to_str_with`, which takes the value's `encode_<name>`.
	to_str : a, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Str, Encode.Error)
	to_str = |x, writer| JsonValue.to_str(value(x, writer)?)

	## `to_str` for a reader with other limits (see `JsonValue.to_str_with`):
	## the haus value that `encode` gives for `x` (a generated
	## `encode_<name>`) within them, and the JSON nested at most 4·d + 1
	## levels for a depth limit d. Lengths count on that value, not on the
	## JSON (spec §16, "Limits"): a string's characters, not its escapes; keys
	## and tags as keys and tags; bytes as two characters per byte, although
	## base64 spells them in fewer or more. The strings that hold numbers
	## (`Int64`, `Decimal`, `"NaN"`) count as numbers. Like the reader's
	## (`FromJson.within_limits`), these errors say what, not where. Fails if
	## d is more than `Value.max_supported_depth`.
	##
	##     ToJson.to_str_with(order, Order.to_json_order, Order.encode_order, limits)
	to_str_with : a, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)), Value.Limits -> Try(Str, Encode.Error)
	to_str_with = |x, writer, encode, limits| {
		Value.check_limits(limits).map_err(|reason| { code: ErrorCode.unsupported_depth, reason, path: "" })?
		within_limits(x, encode, limits)?
		JsonValue.to_str_with(value_with(x, writer, limits)?, limits)
	}

	## The JSON `writer` (a generated `to_json_<name>`) gives for `x`, for a
	## reader with the default limits.
	value : a, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(JsonValue, Encode.Error)
	value = |x, writer| value_with(x, writer, Value.default_limits)

	## `value` for a reader with `limits` (see `Encode.top_with`).
	value_with : a, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)), Value.Limits -> Try(JsonValue, Encode.Error)
	value_with = |x, writer, limits| writer(x, Encode.top_with(limits)).map_ok(|o| o.value)

	## Values as JSON Lines: each on its own line, followed by a line feed.
	## Errors say which value: `[3].total`.
	lines : List(a), (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Str, Encode.Error)
	lines = |values, writer| {
		var $out = []
		var $i = 0.U64
		for v in values {
			$out = $out.append(within(value(v, writer), "[${$i.to_str()}]")?)
			$i = $i + 1
		}
		JsonValue.write_lines($out)
	}

	## `lines` for a reader with other limits (see `to_str_with`). Errors
	## say which value: `[3]`.
	lines_with : List(a), (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)), Value.Limits -> Try(Str, Encode.Error)
	lines_with = |values, writer, encode, limits| {
		Value.check_limits(limits).map_err(|reason| { code: ErrorCode.unsupported_depth, reason, path: "" })?
		var $out = []
		var $i = 0.U64
		for v in values {
			within(within_limits(v, encode, limits), "[${$i.to_str()}]")?
			$out = $out.append(within(value_with(v, writer, limits), "[${$i.to_str()}]")?)
			$i = $i + 1
		}
		JsonValue.write_lines_with($out, limits)
	}

	# ── scalars ─────────────────────────────────────────────
	#
	# Every writer counts the values it makes, as `Encode`'s encoders do,
	# so that a value whose parts are shared fails with `step-budget`.

	str : Str, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	str = |s, e| Encode.made(String(s), e)

	## `Bytes`: base64 with padding (RFC 4648 §4).
	bytes : List(U8), Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	bytes = |b, e| Encode.made(String(JsonValue.base64(b)), e)

	## The prelude's `Bool`: `true` or `false`.
	bool : Bool, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	bool = |b, e| Encode.made(Boolean(b), e)

	i8 : I8, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	i8 = |n, e| Encode.made(Number(n.to_str()), e)

	i16 : I16, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	i16 = |n, e| Encode.made(Number(n.to_str()), e)

	i32 : I32, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	i32 = |n, e| Encode.made(Number(n.to_str()), e)

	u8 : U8, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	u8 = |n, e| Encode.made(Number(n.to_str()), e)

	u16 : U16, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	u16 = |n, e| Encode.made(Number(n.to_str()), e)

	u32 : U32, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	u32 = |n, e| Encode.made(Number(n.to_str()), e)

	## `Int64`: a string, since many JSON parsers round integers beyond 2⁵³.
	i64 : I64, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	i64 = |n, e| Encode.made(String(n.to_str()), e)

	## `UInt64`: a string.
	u64 : U64, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	u64 = |n, e| Encode.made(String(n.to_str()), e)

	## `Int`: a string, the decimal integer.
	int : Int, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	int = |n, e| Encode.made(String(n.to_str()), e)

	## `Float64`: a number in the spelling of spec §15, or `"NaN"`,
	## `"Infinity"`, `"-Infinity"`.
	f64 : F64, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	f64 = |x, e| float(Encode.f64(x, e)?)

	## `Float32`: as `f64`, in the spelling of a binary32.
	f32 : F32, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	f32 = |x, e| float(Encode.f32(x, e)?)

	## `Decimal`: a string, the normalized literal (`"19.90"`).
	decimal : Str, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	decimal = |text, e| {
		n = Encode.decimal(text, e)?
		match n.value {
			Num(literal) => Ok({ value: String(literal), steps: n.steps })
			_ => Err({ code: ErrorCode.cannot_encode, reason: "not a number literal", path: "" })
		}
	}

	## A std/time value: its string, as written.
	time : Str, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	time = |s, e| Encode.made(String(s), e)

	## `Any`: its self-describing value (spec §16.2), without the envelope,
	## checked as `Encode.any` checks it here, a step for each value in it.
	any : Value, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	any = |v, e| {
		checked = Encode.any(v, e)?
		Ok({ value: JsonValue.haus_json_value_with(v, e.limits)?, steps: checked.steps })
	}

	## `< >`: any tag, as an unknown value.
	any_tag : [Bare(Str), Other(Str, List(Value))], Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	any_tag = |t, e| match t {
		Bare(tag) => unknown(tag, [], e)
		Other(tag, args) => unknown(tag, args, e)
	}

	## `Secret a`: the value in full (the receiver needs it); an error says
	## only that it isn't a valid `what`, never where in it.
	secret : Secret(a), Str, Encode.Encoder, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	secret = |s, what, e, writer| match writer(s.expose(), e) {
		Ok(j) => Ok(j)
		Err(_) => Err({ code: ErrorCode.invalid_secret, reason: "not a valid ${what} (the value is hidden)", path: "" })
	}

	# ── containers ──────────────────────────────────────────

	list : List(a), Encode.Encoder, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	list = |items, e, writer| {
		inner = Encode.nested(e)?
		var $steps = Encode.step(e)?
		var $out = List.with_capacity(items.len())
		for x in items {
			item = at_index(writer(x, { ..inner, steps: $steps }), $out.len(), "")?
			$out = $out.append(item.value)
			$steps = item.steps
		}
		Ok({ value: Array($out), steps: $steps })
	}

	## `Map v`: an object.
	map : List((Str, a)), Encode.Encoder, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	map = |entries, e, writer| {
		inner = Encode.record_level(e)?
		var $steps = Encode.step(e)?
		var $out = List.with_capacity(entries.len())
		for (k, x) in entries {
			entry = within(writer(x, { ..inner, steps: $steps }), ErrorCode.path_key(k))?
			$out = $out.append((k, entry.value))
			$steps = entry.steps
		}
		Ok({ value: Object($out), steps: $steps })
	}

	## `Maybe a`: `null` or `a`, when `a`'s JSON can't be `null` (`nullable`
	## is False); otherwise `{"_tag": "None"}` or `{"_tag": "Some", "value": …}`.
	maybe : [None, Some(a)], Encode.Encoder, Bool, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	maybe = |m, e, nullable, writer| match m {
		None => if (nullable) tag("None", e) else Encode.made(Null, e)
		Some(x) =>
			if nullable {
				tagged("Some", e, |inner| writer(x, inner))
			} else {
				# The `Some` is a value of the haus value, if not of the JSON.
				writer(x, { ..Encode.payload(e)?, steps: Encode.step(e)? })
			}
	}

	## `Result e a`: `{"_tag": "Ok", "value": …}` or `{"_tag": "Err", "value": …}`.
	result : Try(a, x), Encode.Encoder, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)), (x, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	result = |r, e, ok, err| match r {
		Ok(x) => tagged("Ok", e, |inner| ok(x, inner))
		Err(x) => tagged("Err", e, |inner| err(x, inner))
	}

	# ── records and variants ────────────────────────────────

	## A required field: `x`, written with `writer` inside the record, after
	## the fields before it.
	required : a, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> [Missing, Present(Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error))]
	required = |x, writer| Present(|inner| writer(x, inner))

	## An optional field (`key?: T`): left out when `Missing`.
	optional : [Missing, Present(a)], (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> [Missing, Present(Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error))]
	optional = |o, writer| match o {
		Missing => Missing
		Present(x) => Present(|inner| writer(x, inner))
	}

	## An object from fields in order, leaving out missing optional ones;
	## each is written inside the record, after the one before it.
	object : Encode.Encoder, List((Str, [Missing, Present(Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error))])) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	object = |e, fields| {
		inner = Encode.record_level(e)?
		written = members(fields, { ..inner, steps: Encode.step(e)? })?
		Ok({ value: Object(written.value), steps: written.steps })
	}

	## A case with a record payload: `{"_tag": "Circle", "r": 1.5}`.
	tagged_object : Str, Encode.Encoder, List((Str, [Missing, Present(Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error))])) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	tagged_object = |name, e, fields| {
		inner = Encode.payload(e)?
		# The tag and its record: two values of the haus value.
		steps = Encode.step({ ..e, steps: Encode.step(e)? })?
		written = members(fields, { ..inner, payload: False, steps })?
		Ok({ value: Object([("_tag", String(name))].concat(written.value)), steps: written.steps })
	}

	## A record case whose record is a named type (`Box BoxRec` with `type
	## BoxRec = { w: Int32 }`, spec §15): the record's members beside
	## `"_tag"`, `{"_tag": "Box", "w": 1}`, as for `Box { w: Int32 }`.
	## `record` writes the record, inside the tag.
	record_case : Str, Encode.Encoder, (Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	record_case = |name, e, record| {
		written = record({ ..Encode.payload(e)?, steps: Encode.step(e)? })?
		match written.value {
			Object(ms) => Ok({ value: Object([("_tag", String(name))].concat(ms)), steps: written.steps })
			other => Err({ code: ErrorCode.cannot_encode, reason: "${name} takes a record, whose JSON is an object; found ${JsonValue.describe(other)}", path: "" })
		}
	}

	## A case without payload in a variant written as objects: `{"_tag": "Empty"}`.
	tag : Str, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	tag = |name, e| Encode.made(Object([("_tag", String(name))]), e)

	## A case with one positional value: `{"_tag": "Wrap", "value": 3}`.
	tagged : Str, Encode.Encoder, (Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	tagged = |name, e, writer| {
		written = within(writer({ ..Encode.payload(e)?, steps: Encode.step(e)? }), ".value")?
		Ok({ value: Object([("_tag", String(name)), ("value", written.value)]), steps: written.steps })
	}

	## A case with two or more positional values, each written after the one
	## before: `{"_tag": "Point", "values": [1, 2]}`.
	tagged_args : Str, Encode.Encoder, List(Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Encode.Encoded(JsonValue), Encode.Error)
	tagged_args = |name, e, writers| {
		inner = Encode.nested(e)?
		var $steps = Encode.step(e)?
		var $out = []
		for writer in writers {
			arg = at_index(writer({ ..inner, steps: $steps }), $out.len(), ".values")?
			$out = $out.append(arg.value)
			$steps = arg.steps
		}
		Ok({ value: Object([("_tag", String(name)), ("values", Array($out))]), steps: $steps })
	}

	## A closed variant whose tags have no payload: the tag as a string.
	tag_name : Str, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	tag_name = |name, e| Encode.made(String(name), e)

	## An unknown value: `{"_tag": "Hexagon"}`, with `"_args"`, the arguments'
	## self-describing values (without the envelope), if it has any (spec
	## §16.3), a step for each value in them.
	unknown : Str, List(Value), Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
	unknown = |name, args, e| {
		if !JsonValue.is_tag_name(name) {
			return Err({ code: ErrorCode.invalid_tag, reason: "not a tag name: A to Z, then letters, digits and _", path: "" })
		}
		if args.is_empty() {
			return Encode.made(Object([("_tag", String(name))]), e)
		}
		var $out = []
		var $i = 0.U64
		for a in args {
			$out = $out.append(within(JsonValue.haus_json_value_with(a, e.limits), "._args[${$i.to_str()}]")?)
			$i = $i + 1
		}
		# Counted, and its depth checked at its place, as the writer counts the variant.
		checked = Encode.any(Tag(name, args), e)?
		Ok({ value: Object([("_tag", String(name)), ("_args", Array($out))]), steps: checked.steps })
	}

	## A case whose record payload has a field named `_tag` or `_args`
	## (`name`): it has no schema-based form (spec §16.3).
	no_json_form : Str, Str -> Try(Encode.Encoded(JsonValue), Encode.Error)
	no_json_form = |name, field| Err({ code: ErrorCode.no_json_form, reason: "${name} has a field named ${field}, so it has no schema-based JSON form", path: "" })
}

within : Try(a, Encode.Error), Str -> Try(a, Encode.Error)
within = |result, segment| result.map_err(|e| { ..e, path: "${segment}${e.path}" })

## The members of an object, leaving out missing optional fields, each
## written after the one before, from `e`.
members : List((Str, [Missing, Present(Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error))])), Encode.Encoder -> Try(Encode.Encoded(List((Str, JsonValue))), Encode.Error)
members = |fields, e| {
	var $steps = e.steps
	var $out = []
	for (key, field) in fields {
		match field {
			Present(writer) => {
				member = within(writer({ ..e, steps: $steps }), ErrorCode.path_key(key))?
				$out = $out.append((key, member.value))
				$steps = member.steps
			}
			Missing => {}
		}
	}
	Ok({ value: $out, steps: $steps })
}

## Whether `x` is within `limits` as a haus value, as `encode` and the haus
## writer check it (lengths, depth, numbers), saying what is wrong but not where.
within_limits : a, (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)), Value.Limits -> Try({}, Encode.Error)
within_limits = |x, encode, limits| match encode(x, Encode.top_with(limits)) {
	Ok(_) => Ok({})
	Err(e) => Err({ ..e, path: "" })
}

## The result of item `i`, with `[i]` after `prefix` in the path of an error.
at_index : Try(a, Encode.Error), U64, Str -> Try(a, Encode.Error)
at_index = |result, i, prefix| match result {
	Ok(x) => Ok(x)
	Err(e) => Err({ ..e, path: "${prefix}[${i.to_str()}]${e.path}" })
}

## A float the haus encoder wrote, as JSON.
float : Encode.Encoded(Value) -> Try(Encode.Encoded(JsonValue), Encode.Error)
float = |v| Ok({
	value: match v.value {
		Num(text) => Number(text)
		Tag("NaN", []) => String("NaN")
		Tag("Infinity", []) => String("Infinity")
		_ => String("-Infinity")
	},
	steps: v.steps,
})

expect ToJson.to_str([1, 2], |xs, e| ToJson.list(xs, e, ToJson.i32)) == Ok("[1,2]")
expect ToJson.to_str(-12, ToJson.i64) == Ok("\"-12\"")
expect ToJson.to_str(0.1, ToJson.f64) == Ok("0.1")
expect ToJson.to_str(-0.0, ToJson.f64) == Ok("-0")
expect ToJson.to_str(0.0 / 0.0, ToJson.f64) == Ok("\"NaN\"")
expect ToJson.to_str("1E5", ToJson.decimal) == Ok("\"1e5\"")
expect ToJson.to_str([0x0B, 0x34], ToJson.bytes) == Ok("\"CzQ=\"")
expect ToJson.to_str(Some(None), |m, e| ToJson.maybe(m, e, True, |x, e1| ToJson.maybe(x, e1, False, ToJson.i32))) == Ok("{\"_tag\":\"Some\",\"value\":null}")
expect ToJson.to_str(Some(5), |m, e| ToJson.maybe(m, e, False, ToJson.i32)) == Ok("5")
expect ToJson.to_str(Ok(1), |r, e| ToJson.result(r, e, ToJson.i32, ToJson.str)) == Ok("{\"_tag\":\"Ok\",\"value\":1}")
expect ToJson.to_str({ id: 1, nick: Missing }, |u, e| ToJson.object(e, [("id", ToJson.required(u.id, ToJson.i32)), ("nick", ToJson.optional(u.nick, ToJson.str))])) == Ok("{\"id\":1}")
expect ToJson.to_str((1, 2), |(a, b), e| ToJson.tagged_args("Point", e, [|inner| ToJson.i32(a, inner), |inner| ToJson.i32(b, inner)])) == Ok("{\"_tag\":\"Point\",\"values\":[1,2]}")
expect ToJson.to_str({}, |_, e| ToJson.tag("Empty", e)) == Ok("{\"_tag\":\"Empty\"}")
expect ToJson.unknown("Hexagon", [Num("1")], Encode.top).map_ok(|o| JsonValue.to_str(o.value)) == Ok(Ok("{\"_tag\":\"Hexagon\",\"_args\":[{\"_num\":\"1\"}]}"))
expect ToJson.unknown("Hexagon", [Num("x")], Encode.top) == Err({ code: "cannot-encode", reason: "not a number literal", path: "._args[0]" })
expect ToJson.to_str(Tag("A", []), ToJson.any) == Ok("{\"_tag\":\"A\"}")
# DEL, C1 and bidi controls are escaped.
expect ToJson.to_str("a\u(7F)\u(85)\u(202E)", ToJson.str) == Ok("\"a\\u007f\\u0085\\u202e\"")
expect ToJson.lines([1, 2], ToJson.u8) == Ok("1\n2\n")

# Writing for a reader with other limits.
small : Value.Limits
small = { ..Value.default_limits, max_depth: 2, max_string_length: 3 }

expect ToJson.to_str_with("abc", ToJson.str, Encode.str, small) == Ok("\"abc\"") and ToJson.to_str_with("abcd", ToJson.str, Encode.str, small) == Err({ code: "string-too-long", reason: "string longer than 3 characters", path: "" })
expect ToJson.lines_with(["a", "abcd"], ToJson.str, Encode.str, small) == Err({ code: "string-too-long", reason: "string longer than 3 characters", path: "[1]" })
expect ToJson.lines_with(["a", "b"], ToJson.str, Encode.str, small) == Ok("\"a\"\n\"b\"\n")
# An empty array is a level, as when it is parsed (spec §7): `[[]]` needs depth 2.
expect {
	inner = |l, e| ToJson.list(l, e, ToJson.u8)
	outer = |l, e| ToJson.list(l, e, inner)
	encode_inner = |l, e| Encode.list(l, e, |n, e1| Encode.number(n.to_str(), e1))
	encode_outer = |l, e| Encode.list(l, e, encode_inner)
	depth = |d| { ..Value.default_limits, max_depth: d }
	ToJson.to_str_with([[]], outer, encode_outer, depth(2)) == Ok("[[]]")
		and ToJson.to_str_with([[]], outer, encode_outer, depth(1)).map_err(|e| e.code) == Err("nesting-too-deep")
		and ToJson.value_with([], inner, depth(0)).map_err(|e| e.code) == Err("nesting-too-deep")
}
expect ToJson.to_str_with("a", ToJson.str, Encode.str, { ..Value.default_limits, max_depth: 1025 }) == Err({ code: "unsupported-depth", reason: "max_depth 1025 is more than the supported maximum, 1024", path: "" })
expect ToJson.lines_with([], ToJson.str, Encode.str, { ..Value.default_limits, max_depth: 1025 }) == Err({ code: "unsupported-depth", reason: "max_depth 1025 is more than the supported maximum, 1024", path: "" })
# Lengths count on the haus value (spec §16, "Limits"), at the limit and one over:
# a string's characters, not its escapes; bytes two characters per byte, although
# base64 spells one byte in 4 and three in 4.
limited : a, (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)), U64 -> Str
limited = |x, writer, encode, max| match ToJson.to_str_with(x, writer, encode, { ..Value.default_limits, max_string_length: max }) {
	Ok(json) => json
	Err(e) => e.code
}

number : I32, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)
number = |n, e| Encode.number(n.to_str(), e)

expect limited("\u(E9)\n\"\\", ToJson.str, Encode.str, 4) == "\"\u(E9)\\n\\\"\\\\\"" and limited("\u(E9)\n\"\\x", ToJson.str, Encode.str, 4) == "string-too-long"
expect limited([0x0B], ToJson.bytes, Encode.bytes, 2) == "\"Cw==\"" and limited([0x0B, 0x34], ToJson.bytes, Encode.bytes, 2) == "string-too-long"
expect limited([0x0B, 0x34, 0xFF], ToJson.bytes, Encode.bytes, 6) == "\"CzT/\"" and limited([0x0B, 0x34, 0xFF, 0], ToJson.bytes, Encode.bytes, 6) == "string-too-long"
# Map keys are keys; Int64 and Decimal strings are numbers, which the number limit bounds.
expect limited([("abcd", 1)], |m, e| ToJson.map(m, e, ToJson.i32), |m, e| Encode.map(m, e, number), 4) == "{\"abcd\":1}" and limited([("abcde", 1)], |m, e| ToJson.map(m, e, ToJson.i32), |m, e| Encode.map(m, e, number), 4) == "key-too-long"
expect limited(-123456, ToJson.i64, |n, e| Encode.number(n.to_str(), e), 2) == "\"-123456\"" and limited("19.90", ToJson.decimal, Encode.decimal, 2) == "\"19.90\""
# A record case by name: the record's members beside `"_tag"`.
expect ToJson.record_case("Box", Encode.top, |e| ToJson.object(e, [("w", ToJson.required(1, ToJson.i32))])).map_ok(|o| o.value) == Ok(Object([("_tag", String("Box")), ("w", Number("1"))]))
expect ToJson.record_case("Box", Encode.top, |e| ToJson.i32(1, e)).map_err(|e| e.code) == Err("cannot-encode")
expect ToJson.unknown("hexagon", [], Encode.top).map_err(|e| e.code) == Err("invalid-tag") and ToJson.no_json_form("Odd", "_tag").map_err(|e| e.code) == Err("no-json-form")
expect ToJson.to_str(Secret.new("x"), |s, e| ToJson.secret(s, "Secret Decimal", e, ToJson.decimal)).map_err(|e| (e.code, e.reason)) == Err(("invalid-secret", "not a valid Secret Decimal (the value is hidden)"))
expect ToJson.to_str([("pt-BR", "1E5x")], |m, e| ToJson.map(m, e, ToJson.decimal)).map_err(|e| (e.code, ErrorCode.place(e.path))) == Err(("cannot-encode", "$[\"pt-BR\"]"))
# An error inside a Secret says nothing of the value: not a key of its Map, not where in its Any.
expect ToJson.to_str(Secret.new([("alice-pw", Rec([("a", Num("1")), ("a", Num("2"))]))]), |s, e| ToJson.secret(s, "Secret (Map Any)", e, |m, e1| ToJson.map(m, e1, ToJson.any))) == Err({ code: "invalid-secret", reason: "not a valid Secret (Map Any) (the value is hidden)", path: "" })

# A native value nested far deeper than the limit: the writer stops at the
# limit of the haus value's depth, without recursing on (see Encode's tests).
Chain := [End, Link(Chain)]

to_json_chain : Chain, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
to_json_chain = |c, e| match c {
	End => ToJson.tag("End", e)
	Link(next) => ToJson.tagged("Link", e, |inner| to_json_chain(next, inner))
}

encode_chain : Chain, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)
encode_chain = |c, e| match c {
	End => Encode.tag("End", e)
	Link(next) => Encode.tagged("Link", e, |inner| encode_chain(next, inner))
}

chain : U64 -> Chain
chain = |n| {
	var $c = End
	var $i = 0
	while $i < n {
		$c = Link($c)
		$i = $i + 1
	}
	$c
}

expect ToJson.to_str(chain(200_000), to_json_chain).map_err(|e| e.code) == Err("nesting-too-deep")
expect ToJson.to_str_with(chain(200_000), to_json_chain, encode_chain, Value.default_limits) == Err({ code: "nesting-too-deep", reason: "nesting deeper than 256 levels", path: "" })
# At the limit, and one past it: as the haus value's depth counts.
expect ToJson.to_str(chain(256), to_json_chain).is_ok() and ToJson.to_str(chain(257), to_json_chain).is_err()
expect [0, 3].all(|d| ToJson.to_str_with(chain(d), to_json_chain, encode_chain, { ..Value.default_limits, max_depth: d }).is_ok() and ToJson.to_str_with(chain(d + 1), to_json_chain, encode_chain, { ..Value.default_limits, max_depth: d }).is_err())

# A native value whose parts are shared (a DAG): 2^41 − 1 values when
# written out. Writing counts the values it makes (spec §9.8), as encoding
# haus does, and stops at the budget.
Dag := [Leaf, Two(Dag, Dag)]

to_json_dag : Dag, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)
to_json_dag = |d, e| match d {
	Leaf => ToJson.list([], e, to_json_dag)
	Two(a, b) => ToJson.list([a, b], e, to_json_dag)
}

dag : U64 -> Dag
dag = |levels| {
	var $d = Leaf
	var $i = 0
	while $i < levels {
		$d = Two($d, $d)
		$i = $i + 1
	}
	$d
}

budget : U64 -> Value.Limits
budget = |max| { ..Value.default_limits, max_steps: max }

expect ToJson.value_with(dag(40), to_json_dag, budget(100_000)).map_err(|e| (e.code, e.reason)).map_ok(|_| {}) == Err(("step-budget", "encode budget of 100000 steps exceeded (a value whose parts are shared expands when written)"))
expect ToJson.value_with(dag(3), to_json_dag, budget(15)).is_ok() and ToJson.value_with(dag(3), to_json_dag, budget(14)).map_err(|e| e.code).map_ok(|_| {}) == Err("step-budget")
# Scalars and raw values count too: a list of three numbers is four values, `[[], []]` three.
expect ToJson.value_with([1.I32, 2, 3], |l, e| ToJson.list(l, e, ToJson.i32), budget(4)).is_ok() and ToJson.value_with([1.I32, 2, 3], |l, e| ToJson.list(l, e, ToJson.i32), budget(3)).is_err()
expect ToJson.value_with(Arr([Arr([]), Arr([])]), ToJson.any, budget(3)).is_ok() and ToJson.value_with(Arr([Arr([]), Arr([])]), ToJson.any, budget(2)).is_err()
# JSON built in code, shared as much: the JSON writer counts too.
expect {
	var $j = Array([])
	var $i = 0
	while $i < 40 {
		$j = Array([$j, $j])
		$i = $i + 1
	}
	JsonValue.to_str_with($j, budget(100_000)).map_err(|e| e.code) == Err("step-budget") and JsonValue.to_str_with(Array([Array([]), Null]), budget(3)).is_ok() and JsonValue.to_str_with(Array([Array([]), Null]), budget(2)).is_err()
}
