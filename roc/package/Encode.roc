## Writing haus: the compact layout (spec §11: one value per line, normal
## spacing), the minimised layout (the same without spaces), and the building
## blocks that generated encoders use.
##
##     ada = Value.rec([("name", Value.text("Ada"))])?
##     Encode.to_str(ada)      # Ok("{ name: \"Ada\" }")
##     Encode.minimised(ada)   # Ok("{name:\"Ada\"}")
##
## Every `Value` is a haus value: its constructors reject anything else
## (spec §11, "Values built in code"). So the writers check only that a
## value is within what a reader takes (spec §7, §9.8): its nesting, the
## length of its numbers, strings, keys and tags, its exponents, and the
## steps it takes to write. The canonical form has no limits.
import ErrorCode
import Int
import Secret
import Value

Encode := [].{

	## One value on one line, checked as it is written against the parser's
	## limits (nesting depth 256, number literals of 1000 characters,
	## exponents up to 6144, strings of 16 Mi characters). Numbers are
	## written as their normalized literal, integers always in decimal.
	to_str : Value -> Try(Str, Error)
	to_str = |v| to_str_with(v, Value.default_limits)

	## `to_str` for a reader with other limits (see `Value.Limits`): the value
	## must be within them, so an integer whose decimal form is longer than the
	## number limit is `number-too-long`. Fails if `limits.max_depth` is more
	## than `Value.max_supported_depth`.
	to_str_with : Value, Value.Limits -> Try(Str, Error)
	to_str_with = |v, limits| {
		supported(limits)?
		line(v, 0, { limits, spaced: True }, { bytes: [], steps: 0 }).map_ok(|out| bytes_to_str(out.bytes))
	}

	## One value on one line in the minimised layout (spec §11): the compact
	## layout without the whitespace between tokens, for the wire and storage.
	## Checked as `to_str` checks it.
	##
	##     person = Value.tag("Person", [Value.rec([("age", Value.num("30")?)])?])?
	##     Encode.minimised(person)   # Ok("Person{age:30}")
	minimised : Value -> Try(Str, Error)
	minimised = |v| minimised_with(v, Value.default_limits)

	## `minimised` for a reader with other limits (see `to_str_with`).
	minimised_with : Value, Value.Limits -> Try(Str, Error)
	minimised_with = |v, limits| {
		supported(limits)?
		line(v, 0, { limits, spaced: False }, { bytes: [], steps: 0 }).map_ok(|out| bytes_to_str(out.bytes))
	}

	## `.extra[1]: number literal longer than 1000 characters`, or just the
	## reason at the root.
	message : Error -> Str
	message = |e| if (e.path == "") e.reason else "${e.path}: ${e.reason}"

	## The JSON form of an error (spec §17), on one line, with its place as
	## `$.extra[1]` (see `ErrorCode.place`):
	## `{"code":"number-too-long","message":"number literal longer than 1000 characters","path":"$.extra[1]","hint":…,"docs":…}`.
	error_json : Error -> Str
	error_json = |e| ErrorCode.json({ code: e.code, message: e.reason, at: Path(e.path) })

	## The canonical form (spec §12): one exact text per value, the same in
	## every binding, so equal values (§2) give identical text. It has no
	## limits: an integer is written in decimal with all its digits, however
	## long, and any exponent goes. Every value has one, and a number built
	## in another spelling is normalized already (`Value.num("0xFF")` is
	## `255`). It fails only for a `Value` built in code that nests deeper
	## than any parser takes, or shares its parts so much that its text would
	## be enormous (spec §9.8): beyond `Value.max_supported_depth` levels
	## with `nesting-too-deep`, and beyond `Value.max_nodes` values, a shared
	## part counted each time it is reached, with `too-many-nodes` (see
	## `Value.within_bounds`). A parsed value never fails.
	##
	##     Encode.canonical(Value.rec([("b", Value.num("1")?), ("a", Value.num("0xFF")?)])?)   # Ok("{a:255,b:1}")
	canonical : Value -> Try(Str, Error)
	canonical = |v| canonical_within(v, Value.max_nodes).map_ok(bytes_to_str)

	## The SHA-256 digest of the canonical form, as 64 lowercase hex digits
	## (spec §12): the same whatever the layout, comments or key order. Fails
	## as `canonical` does.
	hash : Value -> Try(Str, Error)
	hash = |v| canonical_within(v, Value.max_nodes).map_ok(|form| Crypto.SHA256.hash(form).to_hex())

	## The hash of a list of values, such as a whole file (spec §12): the
	## SHA-256 digest of their canonical forms joined by `,`. A list of one
	## value hashes like the value: `hash_all([v])` is `hash(v)`. The items of
	## a stream are hashed one by one with `hash`. Fails as `canonical` does,
	## saying which value: `[3]`.
	hash_all : List(Value) -> Try(Str, Error)
	hash_all = |values| {
		var $bytes = []
		var $i = 0.U64
		for v in values {
			form = at_index(canonical_within(v, Value.max_nodes), $i, "")?
			$bytes = if ($i > 0) $bytes.append(',').concat(form) else form
			$i = $i + 1
		}
		Ok(Crypto.SHA256.hash($bytes).to_hex())
	}

	## Whether two values are equal (spec §2): the same canonical form. Fails
	## as `canonical` does.
	equals : Value, Value -> Try(Bool, Error)
	equals = |a, b| Ok(canonical_within(a, Value.max_nodes)? == canonical_within(b, Value.max_nodes)?)

	## Orders values by the bytes of their canonical forms (spec §12): a total
	## order consistent with `equals`. Not numeric order: `10` sorts before
	## `9`. Fails as `canonical` does. To sort values, which any parser gave,
	## `values.sort_with(|a, b| Encode.compare(a, b) ?? Same)`.
	compare : Value, Value -> Try([Before, Same, After], Error)
	compare = |a, b| Ok(compare_bytes(canonical_within(a, Value.max_nodes)?, canonical_within(b, Value.max_nodes)?))

	## A stream: one value per line, each followed by a comma. Errors say
	## which value: `[3].total`.
	stream : List(Value) -> Try(Str, Error)
	stream = |values| stream_with(values, Value.default_limits)

	## `stream` for a reader with other limits (see `to_str_with`).
	stream_with : List(Value), Value.Limits -> Try(Str, Error)
	stream_with = |values, limits| write_stream(values, { limits, spaced: True })

	## A stream in the minimised layout (spec §11): one value per line, each
	## followed by a comma, without spaces: `Person{age:30},`.
	stream_minimised : List(Value) -> Try(Str, Error)
	stream_minimised = |values| stream_minimised_with(values, Value.default_limits)

	## `stream_minimised` for a reader with other limits (see `to_str_with`).
	stream_minimised_with : List(Value), Value.Limits -> Try(Str, Error)
	stream_minimised_with = |values, limits| write_stream(values, { limits, spaced: False })

	# ── building blocks ─────────────────────────────────────
	#
	# What generated encoders (`encode_<name> : T, Encode.Encoder ->
	# Try(Encode.Encoded(Value), Encode.Error)`) are built from. Each checks
	# what it builds as the writer will (spec §9.8), at its place: a container
	# fails with `nesting-too-deep` at the depth limit, before its contents
	# are encoded, so a native value nested deeper than the limit (a long
	# linked list, a deep tree) never recurses past it. Each also counts the
	# values it makes, one step each, and gives the count on with the value:
	# a value whose parts are shared (a DAG, which Roc can't tell from a
	# tree) fails with `step-budget` at `limits.max_steps` instead of
	# expanding without bound.

	## At the top, for a reader with the default limits: `Thread.encode_comment(c, Encode.top)`.
	top : Encoder
	top = top_with(Value.default_limits)

	## At the top, for a reader with `limits`: encode for the limits you
	## write with (`to_str_with`), so that every error is found here, where
	## the type is known (an error inside a `Secret` says nothing of the value).
	top_with : Value.Limits -> Encoder
	top_with = |limits| { limits, depth: 0, payload: False, steps: 0 }

	## The value `encode` (a generated `encode_<name>`) gives for `x`, for a
	## reader with the default limits:
	##
	##     encoded = Encode.value(comment, Thread.encode_comment)?
	##     text = Encode.to_str(encoded)?
	value : a, (a, Encoder -> Try(Encoded(Value), Error)) -> Try(Value, Error)
	value = |x, encode| value_with(x, encode, Value.default_limits)

	## `value` for a reader with `limits` (see `top_with`).
	value_with : a, (a, Encoder -> Try(Encoded(Value), Error)), Value.Limits -> Try(Value, Error)
	value_with = |x, encode, limits| encode(x, top_with(limits)).map_ok(|o| o.value)

	## Inside one more container (a record, an array, a payload): fails with
	## `nesting-too-deep` at the depth limit, or `unsupported-depth` if the
	## limit is more than `Value.max_supported_depth`.
	nested : Encoder -> Try(Encoder, Error)
	nested = |e| {
		supported(e.limits)?
		open(e.depth, e.limits)?
		Ok({ ..e, depth: e.depth + 1, payload: False })
	}

	## Inside a record or map: one more level, unless the record is a tag's
	## only argument (`Tag { … }`) and so shares its level.
	record_level : Encoder -> Try(Encoder, Error)
	record_level = |e| if (e.payload) Ok({ ..e, payload: False }) else nested(e)

	## Inside a tag's only argument: one more level, where a record takes none of its own.
	payload : Encoder -> Try(Encoder, Error)
	payload = |e| nested(e).map_ok(|inner| { ..inner, payload: True })

	## The steps after one more value made here: `step-budget` beyond
	## `limits.max_steps`.
	step : Encoder -> Try(U64, Error)
	step = |e| counted(e.steps, e.limits)

	## `x`, one value made here (a scalar): `Encode.made(Number(n.to_str()), e)`.
	made : a, Encoder -> Try(Encoded(a), Error)
	made = |x, e| Ok({ value: x, steps: step(e)? })

	str : Str, Encoder -> Try(Encoded(Value), Error)
	str = |s, e| {
		check_length(s, e.limits)?
		made(Value.text(s), e)
	}

	bytes : List(U8), Encoder -> Try(Encoded(Value), Error)
	bytes = |b, e| {
		check_bytes(b, e.limits)?
		made(Value.bytes(b), e)
	}

	bool : Bool, Encoder -> Try(Encoded(Value), Error)
	bool = |b, e| tag(if (b) "True" else "False", e)

	## `Int`: an integer of any size, as its digits.
	int : Int, Encoder -> Try(Encoded(Value), Error)
	int = |n, e| number(n.to_str(), e)

	## A number literal (`Int8`…`UInt64` as `n.to_str()`), normalized as the
	## parser reads it (`Value.num`), within the number limits. A text that
	## isn't a number literal, such as a `Decimal`'s, is `cannot-encode`.
	number : Str, Encoder -> Try(Encoded(Value), Error)
	number = |text, e| {
		v = Value.num(text).map_err(|err| { code: ErrorCode.cannot_encode, reason: err.reason, path: "" })?
		match v.view() {
			Num(literal) => check_number(literal, e.limits)?
			_ => {}
		}
		made(v, e)
	}

	## An exact decimal, as its text: `19.90`.
	decimal : Str, Encoder -> Try(Encoded(Value), Error)
	decimal = |text, e| number(text, e)

	## A Float64 in its one spelling (spec §15): the fewest digits that read
	## back as the same binary64 value, laid out like JavaScript's
	## `Number.prototype.toString` without `+` in the exponent (`1e21`,
	## `1.5e-7`, `-0`). NaN and the infinities are tags (prelude).
	f64 : F64, Encoder -> Try(Encoded(Value), Error)
	f64 = |x, e|
		if x != x {
			tag("NaN", e)
		} else if x > 1.7976931348623157e308 {
			tag("Infinity", e)
		} else if x < -1.7976931348623157e308 {
			tag("NegInfinity", e)
		} else {
			# Roc's `to_str` has the digits the spec asks for: the fewest that read
			# back as the same float, the closest of them, ties to even.
			number(float_text(x.to_str()), e)
		}

	## A Float32 in its one spelling: the fewest digits that read back as the
	## same binary32 value (`0.1`, not `0.10000000149011612`), laid out as for `f64`.
	f32 : F32, Encoder -> Try(Encoded(Value), Error)
	f32 = |x, e|
		if x != x {
			tag("NaN", e)
		} else if x > 3.4028235e38 {
			tag("Infinity", e)
		} else if x < -3.4028235e38 {
			tag("NegInfinity", e)
		} else {
			number(float_text(x.to_str()), e)
		}

	## A std/time value: `Date("2026-11-09")`.
	time : Str -> (Str, Encoder -> Try(Encoded(Value), Error))
	time = |name| |text, e| tagged(name, e, |inner| str(text, inner))

	list : List(a), Encoder, (a, Encoder -> Try(Encoded(Value), Error)) -> Try(Encoded(Value), Error)
	list = |items, e, encode| {
		inner = nested(e)?
		var $steps = step(e)?
		var $out = List.with_capacity(items.len())
		for x in items {
			item = at_index(encode(x, { ..inner, steps: $steps }), $out.len(), "")?
			$out = $out.append(item.value)
			$steps = item.steps
		}
		Ok({ value: Value.arr($out), steps: $steps })
	}

	## `Map v`: a record used as a dictionary. A key used twice is
	## `duplicate-key`, at the key, before any value is encoded.
	map : List((Str, a)), Encoder, (a, Encoder -> Try(Encoded(Value), Error)) -> Try(Encoded(Value), Error)
	map = |entries, e, encode| {
		inner = record_level(e)?
		unique_keys(entries.map(|(k, _)| k))?
		var $steps = step(e)?
		var $out = List.with_capacity(entries.len())
		for (k, x) in entries {
			entry = field(k, encode(x, { ..inner, steps: $steps }), inner)?
			$out = $out.append((k, entry.value))
			$steps = entry.steps
		}
		Ok({ value: constructed(Value.rec($out))?, steps: $steps })
	}

	maybe : [None, Some(a)], Encoder, (a, Encoder -> Try(Encoded(Value), Error)) -> Try(Encoded(Value), Error)
	maybe = |m, e, encode| match m {
		None => tag("None", e)
		Some(x) => tagged("Some", e, |inner| encode(x, inner))
	}

	result : Try(a, x), Encoder, (a, Encoder -> Try(Encoded(Value), Error)), (x, Encoder -> Try(Encoded(Value), Error)) -> Try(Encoded(Value), Error)
	result = |r, e, ok, err| match r {
		Ok(x) => tagged("Ok", e, |inner| ok(x, inner))
		Err(x) => tagged("Err", e, |inner| err(x, inner))
	}

	## A required field: `x`, encoded with `encode` inside the record, after
	## the fields before it.
	required : a, (a, Encoder -> Try(Encoded(Value), Error)) -> [Missing, Present(Encoder -> Try(Encoded(Value), Error))]
	required = |x, encode| Present(|inner| encode(x, inner))

	## An optional field (`key?: T`): left out of the record when `Missing`.
	optional : [Missing, Present(a)], (a, Encoder -> Try(Encoded(Value), Error)) -> [Missing, Present(Encoder -> Try(Encoded(Value), Error))]
	optional = |o, encode| match o {
		Missing => Missing
		Present(x) => Present(|inner| encode(x, inner))
	}

	## A record from its fields in order, leaving out missing optional ones.
	## Each field is encoded inside the record, after the one before it:
	##
	##     Encode.record(e, [("id", Encode.required(u.id, Encode.int)), ("nick", Encode.optional(u.nick, Encode.str))])
	record : Encoder, List((Str, [Missing, Present(Encoder -> Try(Encoded(Value), Error))])) -> Try(Encoded(Value), Error)
	record = |e, fields| {
		inner = record_level(e)?
		var $steps = step(e)?
		var $out = []
		for (k, f) in fields {
			match f {
				Present(encode) => {
					entry = field(k, encode({ ..inner, steps: $steps }), inner)?
					$out = $out.append((k, entry.value))
					$steps = entry.steps
				}
				Missing => {}
			}
		}
		Ok({ value: constructed(Value.rec($out))?, steps: $steps })
	}

	## A tag without payload: `None`, `Circle`.
	tag : Str, Encoder -> Try(Encoded(Value), Error)
	tag = |name, e| {
		check_tag(name, e.limits)?
		made(constructed(Value.tag(name, []))?, e)
	}

	## A tag with one argument, which `encode` encodes inside it: `Some(1)`,
	## and `Wrap { w: 1 }` for a record (`Tag { … }` takes one level, spec §7).
	tagged : Str, Encoder, (Encoder -> Try(Encoded(Value), Error)) -> Try(Encoded(Value), Error)
	tagged = |name, e, encode| {
		check_tag(name, e.limits)?
		inner = payload(e)?
		match encode({ ..inner, steps: step(e)? }) {
			Ok(arg) => Ok({ value: constructed(Value.tag(name, [arg.value]))?, steps: arg.steps })
			Err(err) => Err({ ..err, path: payload_path(name, err.path) })
		}
	}

	## A tag with two or more arguments, each encoded inside it after the
	## one before: `Point(1, 2)`.
	tagged_args : Str, Encoder, List(Encoder -> Try(Encoded(Value), Error)) -> Try(Encoded(Value), Error)
	tagged_args = |name, e, encoders| {
		check_tag(name, e.limits)?
		inner = nested(e)?
		var $steps = step(e)?
		var $out = []
		for encode in encoders {
			arg = at_index(encode({ ..inner, steps: $steps }), $out.len(), "(${name})")?
			$out = $out.append(arg.value)
			$steps = arg.steps
		}
		Ok({ value: constructed(Value.tag(name, $out))?, steps: $steps })
	}

	## A tag with a record payload: `Circle { r: 1.5 }`, as `record` takes it.
	tagged_record : Str, Encoder, List((Str, [Missing, Present(Encoder -> Try(Encoded(Value), Error))])) -> Try(Encoded(Value), Error)
	tagged_record = |name, e, fields| {
		check_tag(name, e.limits)?
		inner = within(payload(e), "(${name})")?
		r = within(record({ ..inner, steps: step(e)? }, fields), "(${name})")?
		Ok({ value: constructed(Value.tag(name, [r.value]))?, steps: r.steps })
	}

	## An unknown variant kept as it was (`invalid-tag` if `name` isn't a tag
	## name), checked as the writer checks it.
	unknown : Str, List(Value), Encoder -> Try(Encoded(Value), Error)
	unknown = |name, args, e| any(constructed(Value.tag(name, args))?, e)

	## `Any`: the value as it was, checked as the writer checks it here, a
	## step for each value in it.
	any : Value, Encoder -> Try(Encoded(Value), Error)
	any = |v, e| {
		supported(e.limits)?
		# A record that is a tag's only argument shares the tag's level.
		depth = match v.view() {
			Rec(_) if e.payload => e.depth - 1
			_ => e.depth
		}
		written_out = line(v, depth, { limits: e.limits, spaced: False }, { bytes: [], steps: e.steps })?
		Ok({ value: v, steps: written_out.steps })
	}

	## `Secret a`: the value in full (the receiver needs it). An error inside
	## it is reported at the secret, saying only that it isn't a valid `what`
	## (`"Secret Any"`), with the code `invalid-secret`: never the value, nor
	## where in it, since a key of a `Map` or an `Any` in the path could reveal
	## it (spec §15).
	secret : Secret(a), Str, Encoder, (a, Encoder -> Try(Encoded(Value), Error)) -> Try(Encoded(Value), Error)
	secret = |s, what, e, encode| match encode(s.expose(), e) {
		Ok(v) => Ok(v)
		Err(_) => fail(ErrorCode.invalid_secret, "not a valid ${what} (the value is hidden)")
	}

	## `< >`: a bare tag, or any other variant kept as it was.
	any_tag : [Bare(Str), Other(Str, List(Value))], Encoder -> Try(Encoded(Value), Error)
	any_tag = |t, e| match t {
		Bare(name) => unknown(name, [], e)
		Other(name, args) => unknown(name, args, e)
	}
}

## Roc's float text (`1e20`, `1e-6`, `-0`, `0.30000000000000004`) laid out as
## spec §15 says, like JavaScript's `Number.prototype.toString` without `+`
## in the exponent. Roc's `to_str` already has the right digits.
float_text : Str -> Str
float_text = |shortest| {
	(sign, magnitude) = if (shortest.starts_with("-")) ("-", shortest.drop_prefix("-")) else ("", shortest)
	(mantissa, exp) = match magnitude.split_on("e") {
		[m, e] => (m, I64.from_str(e.drop_prefix("+")) ?? 0)
		_ => (magnitude, 0)
	}
	(whole, fraction) = match mantissa.split_on(".") {
		[w, f] => (w, f)
		_ => (mantissa, "")
	}
	# The digits without the zeros around them, d₁…dₖ, and n with the value 0.d₁…dₖ × 10ⁿ.
	digits = whole.to_utf8().concat(fraction.to_utf8())
	match (digits.find_first_index(|c| c != '0'), digits.find_last_index(|c| c != '0')) {
		(Ok(first), Ok(last)) => {
			d = digits.sublist({ start: first, len: last + 1 - first })
			n = whole.count_utf8_bytes().to_i64_wrap() + exp - first.to_i64_wrap()
			"${sign}${bytes_to_str(layout(d, n))}"
		}
		_ => "${sign}0"
	}
}

## The digits d₁…dₖ of the value 0.d₁…dₖ × 10ⁿ, laid out like JavaScript's
## `Number.prototype.toString`: `123000`, `1.5`, `0.000001`, `1.5e-7`.
layout : List(U8), I64 -> List(U8)
layout = |d, n| {
	k = d.len().to_i64_wrap()
	zeros = |count| List.repeat('0', count.to_u64_wrap())
	digits = |start, len| d.sublist({ start: start.to_u64_wrap(), len: len.to_u64_wrap() })
	if k <= n and n <= 21 {
		d.concat(zeros(n - k))
	} else if 0 < n and n <= 21 {
		digits(0, n).append('.').concat(digits(n, k - n))
	} else if -6 < n and n <= 0 {
		['0', '.'].concat(zeros(-n)).concat(d)
	} else {
		fraction = if (k > 1) ['.'].concat(digits(1, k - 1)) else []
		digits(0, 1).concat(fraction).append('e').concat((n - 1).to_str().to_utf8())
	}
}

## What's wrong: its code (spec §17, `ErrorCode`) and reason, and where in the
## value (`.extra[1]`, empty at the root): the same paths as `Decode.Error`.
## What is beyond the limits has the limit's code (`string-too-long`). An
## encoder that builds a value checks it as the constructors do (spec §11,
## "Values built in code"): a tag that isn't a tag name is `invalid-tag`, a
## key used twice `duplicate-key`, and a host number type's text that isn't
## a number literal, such as a `Decimal`'s, `cannot-encode`.
Error : { code : Str, reason : Str, path : Str }

## A value a constructor built, or why it didn't, at the current place.
constructed : Try(Value, Value.ValueError) -> Try(Value, Error)
constructed = |result| result.map_err(|e| { code: e.code, reason: e.reason, path: "" })

## Prefix the path of an error coming out of a nested value.
within : Try(a, Error), Str -> Try(a, Error)
within = |result, segment| result.map_err(|e| { ..e, path: "${segment}${e.path}" })

fail : Str, Str -> Try(a, Error)
fail = |code, reason| Err({ code, reason, path: "" })

## Where a value is encoded (spec §7, §9.8): for a reader with `limits`,
## inside `depth` containers (records, arrays, payloads), counted as the
## writer counts them, after `steps` values made so far. `payload`: the
## value is a tag's only argument, so a record here is written `Tag { … }`
## and takes no level of its own. Start with `Encode.top` or
## `Encode.top_with(limits)`; containers take `Encode.nested`.
Encoder : { limits : Value.Limits, depth : U64, payload : Bool, steps : U64 }

## What an encoder gives: the value it made, and the steps taken so far,
## its own included, for the next value to count on from.
Encoded(a) : { value : a, steps : U64 }

## The steps after one more value made, after `steps`: `step-budget` beyond
## `limits.max_steps` (spec §9.8).
counted : U64, Value.Limits -> Try(U64, Error)
counted = |steps, limits|
	if steps >= limits.max_steps {
		fail(ErrorCode.step_budget, "encode budget of ${limits.max_steps.to_str()} steps exceeded (a value whose parts are shared expands when written)")
	} else {
		Ok(steps + 1)
	}

## A field's value, under its key, with the key checked as the writer checks it.
field : Str, Try(a, Error), Encoder -> Try(a, Error)
field = |k, v, e| {
	segment = ErrorCode.path_key(k)
	within(check_text(k, "key", e.limits), segment)?
	within(v, segment)
}

## Keys are unique (spec §1): a native map might repeat one.
unique_keys : List(Str) -> Try({}, Error)
unique_keys = |keys| {
	var $numbered = List.with_capacity(keys.len())
	for k in keys {
		$numbered = $numbered.append((k, $numbered.len()))
	}
	match Value.first_repeated($numbered) {
		Ok((k, _)) => Err({ code: ErrorCode.duplicate_key, reason: "duplicate key '${ErrorCode.shown(k)}'", path: ErrorCode.path_key(k) })
		Err(_) => Ok({})
	}
}

## The result of item `i`, with `[i]` after `prefix` in the path of an error.
at_index : Try(a, Error), U64, Str -> Try(a, Error)
at_index = |result, i, prefix| match result {
	Ok(x) => Ok(x)
	Err(e) => Err({ ..e, path: "${prefix}[${i.to_str()}]${e.path}" })
}

## Where an error inside a tag's only argument is, as the writer says it: a
## record's fields are right inside the tag (`(Wrap).w`), anything else is
## its first argument (`(Some)[0]`).
payload_path : Str, Str -> Str
payload_path = |name, path|
	if path.starts_with(".") or path.starts_with("[\"") {
		"(${name})${path}"
	} else {
		"(${name})[0]${path}"
	}

## A tag name (`Value.tag` checks it) within the string limit, checked
## before the arguments are encoded.
check_tag : Str, Value.Limits -> Try({}, Error)
check_tag = |name, limits| {
	_ = constructed(Value.tag(name, []))?
	check_text(name, "tag", limits)
}

## A byte string within the string limit: two hex digits per byte.
check_bytes : List(U8), Value.Limits -> Try({}, Error)
check_bytes = |b, limits|
	if b.len() > limits.max_string_length // 2 {
		fail(ErrorCode.string_too_long, "byte string longer than ${limits.max_string_length.to_str()} characters")
	} else {
		Ok({})
	}

## Whether this binding supports `limits` (spec §7).
supported : Value.Limits -> Try({}, Error)
supported = |limits| Value.check_limits(limits).map_err(|reason| { code: ErrorCode.unsupported_depth, reason, path: "" })

## How a line is written: for a reader with `limits`, with spaces between
## tokens (compact) or without (minimised).
Writer : { limits : Value.Limits, spaced : Bool }

write_stream : List(Value), Writer -> Try(Str, Error)
write_stream = |values, writer| {
	supported(writer.limits)?
	var $out = []
	var $i = 0.U64
	for v in values {
		# Each value has a budget of its own.
		written_out = within(line(v, 0, writer, { bytes: $out, steps: 0 }), "[${$i.to_str()}]")?
		$out = written_out.bytes.concat([',', '\n'])
		$i = $i + 1
	}
	Ok(bytes_to_str($out))
}

## The text written so far, and the values written (one step each).
Out : { bytes : List(U8), steps : U64 }

## `value`, inside `depth` containers (records, arrays, payloads), written
## after `out`: a step for it and each value in it (spec §9.8), so that a
## value built in code whose parts are shared (a DAG) fails with
## `step-budget` instead of expanding without bound.
line : Value, U64, Writer, Out -> Try(Out, Error)
line = |value, depth, writer, before| {
	limits = writer.limits
	out = { ..before, steps: counted(before.steps, limits)? }
	match value.view() {
		Num(literal) => {
			check_number(literal, limits)?
			Ok({ ..out, bytes: out.bytes.concat(literal.to_utf8()) })
		}
		Text(s) => {
			check_length(s, limits)?
			Ok({ ..out, bytes: out.bytes.concat(quote(s)) })
		}
		Bytes(b) => {
			check_bytes(b, limits)?
			Ok({ ..out, bytes: out.bytes.concat("x\"".to_utf8()).concat(hex(b)).append('"') })
		}
		Arr(items) => {
			open(depth, limits)?
			inside = items_line(items, depth + 1, writer, { ..out, bytes: out.bytes.append('[') })?
			Ok({ ..inside, bytes: inside.bytes.append(']') })
		}
		Rec(fields) => record_line(fields, depth, writer, out)
		Tag(name, args) => {
			check_text(name, "tag", limits)?
			named = { ..out, bytes: out.bytes.concat(name.to_utf8()) }
			if args.is_empty() {
				return Ok(named)
			}
			match payload_fields(args) {
				Ok(fields) => within(record_line(fields, depth, writer, { ..named, bytes: named.bytes.concat(space(writer)) }), "(${name})")
				Err(_) => {
					open(depth, limits)?
					inside = within(items_line(args, depth + 1, writer, { ..named, bytes: named.bytes.append('(') }), "(${name})")?
					Ok({ ..inside, bytes: inside.bytes.append(')') })
				}
			}
		}
	}
}

## The fields of a tag's arguments that are one record, written `Tag { … }`.
payload_fields : List(Value) -> Try(List((Str, Value)), [NotOneRecord])
payload_fields = |args| match args {
	[arg] =>
		match arg.view() {
			Rec(fields) => Ok(fields)
			_ => Err(NotOneRecord)
		}
	_ => Err(NotOneRecord)
}

## A space between tokens, unless minimised.
space : Writer -> List(U8)
space = |writer| if (writer.spaced) [' '] else []

## Opening a container inside `depth` others.
open : U64, Value.Limits -> Try({}, Error)
open = |depth, limits| if (depth >= limits.max_depth) fail(ErrorCode.nesting_too_deep, "nesting deeper than ${limits.max_depth.to_str()} levels") else Ok({})

## Items separated by `, ` (`,` minimised), each at `depth`.
items_line : List(Value), U64, Writer, Out -> Try(Out, Error)
items_line = |items, depth, writer, before| {
	separator = [','].concat(space(writer))
	var $out = before
	var $i = 0.U64
	for x in items {
		$out = if ($i == 0) $out else { ..$out, bytes: $out.bytes.concat(separator) }
		$out = within(line(x, depth, writer, $out), "[${$i.to_str()}]")?
		$i = $i + 1
	}
	Ok($out)
}

record_line : List((Str, Value)), U64, Writer, Out -> Try(Out, Error)
record_line = |fields, depth, writer, before| {
	limits = writer.limits
	open(depth, limits)?
	if fields.is_empty() {
		return Ok({ ..before, bytes: before.bytes.concat(['{', '}']) })
	}
	sp = space(writer)
	var $out = { ..before, bytes: before.bytes.append('{').concat(sp) }
	var $first = True
	for (k, v) in fields {
		within(check_text(k, "key", limits), ErrorCode.path_key(k))?
		separated = if ($first) $out.bytes else $out.bytes.append(',').concat(sp)
		$out = within(line(v, depth + 1, writer, { ..$out, bytes: separated.concat(key(k)).append(':').concat(sp) }), ErrorCode.path_key(k))?
		$first = False
	}
	Ok({ ..$out, bytes: $out.bytes.concat(sp).append('}') })
}

## A string within the string limit, counted in code points.
check_length : Str, Value.Limits -> Try({}, Error)
check_length = |s, limits| check_text(s, "string", limits)

## A string, key or tag (`what`) within the string limit (spec §7), counted in code points.
check_text : Str, Str, Value.Limits -> Try({}, Error)
check_text = |s, what, limits| {
	b = s.to_utf8()
	too_long = b.len() > limits.max_string_length and b.count_if(|c| c < 0x80 or c >= 0xC0) > limits.max_string_length
	code = if (what == "key") ErrorCode.key_too_long else if (what == "tag") ErrorCode.tag_too_long else ErrorCode.string_too_long
	if (too_long) fail(code, "${what} longer than ${limits.max_string_length.to_str()} characters") else Ok({})
}

## A number's normalized literal (as `Value.num` makes it) within the limits
## of a reader: its length, then its exponent, as a parser meets them
## (spec §7). Integers are always written in decimal (spec §11), so one
## longer than the limit has no text a reader with it takes.
check_number : Str, Value.Limits -> Try({}, Error)
check_number = |literal, limits| {
	b = literal.to_utf8()
	if b.len() > limits.max_number_length {
		return fail(ErrorCode.number_too_long, "number literal longer than ${limits.max_number_length.to_str()} characters")
	}
	# The exponent: `e`, an optional `-`, digits without leading zeros.
	match b.find_first_index(|c| c == 'e') {
		Ok(i) => {
			digits = b.drop_first(i + 1).drop_if(|c| c == '-')
			too_large = digits.len() > 18 or (U64.from_str(bytes_to_str(digits)) ?? 0) > limits.max_exponent
			if (too_large) fail(ErrorCode.exponent_too_large, "exponent larger than ${limits.max_exponent.to_str()}") else Ok({})
		}
		Err(_) => Ok({})
	}
}

## The canonical form of a value with at most `max_nodes` values, nested at
## most `Value.max_supported_depth` levels (spec §9.8), so that a value built
## in code whose parts are shared (a DAG) fails at once, and the recursion of
## `canonical_bytes` is bounded.
canonical_within : Value, U64 -> Try(List(U8), Error)
canonical_within = |value, max_nodes| {
	Value.within_bounds(value, Value.max_supported_depth, max_nodes)?
	Ok(canonical_bytes(value))
}

## The canonical form: no spaces, fields sorted by key, numbers as their
## normalized literal, however long. Every value has one.
canonical_bytes : Value -> List(U8)
canonical_bytes = |value| match value.view() {
	Num(literal) => literal.to_utf8()
	Text(s) => quote(s)
	Bytes(b) => "x\"".to_utf8().concat(hex(b)).append('"')
	Arr(items) => ['['].concat(comma_joined(items.map(canonical_bytes))).append(']')
	Rec(fields) => canonical_record(fields)
	Tag(name, []) => name.to_utf8()
	Tag(name, args) =>
		match payload_fields(args) {
			Ok(fields) => name.to_utf8().concat(canonical_record(fields))
			Err(_) => name.to_utf8().append('(').concat(comma_joined(args.map(canonical_bytes))).append(')')
		}
}

## Fields sorted by their keys' UTF-8 bytes, which is the order of code points.
canonical_record : List((Str, Value)) -> List(U8)
canonical_record = |fields| {
	sorted = fields.map(|(k, v)| (k.to_utf8(), k, v)).sort_with(|(a, _, _), (b, _, _)| compare_bytes(a, b))
	['{'].concat(comma_joined(sorted.map(|(_, k, v)| key(k).append(':').concat(canonical_bytes(v))))).append('}')
}

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |a, b| {
	var $i = 0
	while $i < a.len() and $i < b.len() {
		x = byte_at(a, $i)
		y = byte_at(b, $i)
		if x < y {
			return Before
		}
		if x > y {
			return After
		}
		$i = $i + 1
	}
	if (a.len() < b.len()) Before else if (a.len() > b.len()) After else Same
}

byte_at : List(U8), U64 -> U8
byte_at = |bytes, i| match bytes.get(i) {
	Ok(b) => b
	Err(_) => 0
}

## Items separated by `,`.
comma_joined : List(List(U8)) -> List(U8)
comma_joined = |items| {
	var $out = []
	var $first = True
	for item in items {
		$out = if ($first) item else $out.append(',').concat(item)
		$first = False
	}
	$out
}

## A key without quotes if it is an identifier: `name`, `_id`.
key : Str -> List(U8)
key = |k| {
	b = k.to_utf8()
	first = match b.get(0) {
		Ok(c) => c
		Err(_) => 0
	}
	bare = ((first >= 'a' and first <= 'z') or first == '_') and b.all(|c| (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')
	if (bare) b else quote(k)
}

## A `"…"` string with the minimal escapes, as in the canonical form (spec §12).
quote : Str -> List(U8)
quote = |s| ErrorCode.haus_string(s).to_utf8()

digit_chars : List(U8)
digit_chars = "0123456789abcdef".to_utf8()

hex : List(U8) -> List(U8)
hex = |bytes| {
	var $out = []
	for b in bytes {
		$out = $out.append(hex_digit(b // 16)).append(hex_digit(b % 16))
	}
	$out
}

hex_digit : U8 -> U8
hex_digit = |d| match digit_chars.get(d.to_u64()) {
	Ok(c) => c
	Err(_) => '0'
}

bytes_to_str : List(U8) -> Str
bytes_to_str = |bytes| match Str.from_utf8(bytes) {
	Ok(s) => s
	Err(_) => ""
}

# ── tests ────────────────────────────────────────────────────

# Values built in code, for the tests: the constructors' value, or a string
# that says which one failed.
num : Str -> Value
num = |literal| Value.num(literal) ?? Value.text("(not a number: ${literal})")

rec : List((Str, Value)) -> Value
rec = |fields| Value.rec(fields) ?? Value.text("(not a record)")

variant : Str, List(Value) -> Value
variant = |name, args| Value.tag(name, args) ?? Value.text("(not a tag: ${name})")

expect Encode.to_str(rec([("name", Value.text("Ada")), ("pt-BR", num("1"))])) == Ok("{ name: \"Ada\", \"pt-BR\": 1 }")
expect Encode.to_str(variant("Shipped", [rec([("tracking", Value.text("DE-4711"))])])) == Ok("Shipped { tracking: \"DE-4711\" }")
expect Encode.to_str(variant("Money", [num("44.40"), variant("EUR", [])])) == Ok("Money(44.40, EUR)")
expect Encode.to_str(Value.arr([Value.bytes([0x0b, 0xff]), rec([]), Value.arr([])])) == Ok("[x\"0bff\", {}, []]")
expect Encode.to_str(Value.text("a\"b\\\n\u(202E)")) == Ok("\"a\\\"b\\\\\\n\\u{202E}\"")
expect Encode.stream([variant("A", []), num("1")]) == Ok("A,\n1,\n")
expect Int.from_str("340282366920938463463374607431768211457").map_ok(|n| written(n, Encode.int)) == Ok(Ok("340282366920938463463374607431768211457"))
expect written({ a: 1.I32, b: Missing }, |r, e| Encode.record(e, [("a", Present(|inner| Encode.number(r.a.to_str(), inner))), ("b", Encode.optional(r.b, Encode.str))])) == Ok("{ a: 1 }")
expect written({ a: "x", b: Present("y") }, |r, e| Encode.record(e, [("a", Encode.required(r.a, Encode.str)), ("b", Encode.optional(r.b, Encode.str))])) == Ok("{ a: \"x\", b: \"y\" }")
expect Encode.to_str(Value.text("\u(1B)\u(7F)\u(85)")) == Ok("\"\\u{1B}\\u{7F}\\u{85}\"")
# U+2028 and U+2029 are escaped too, so a line never ends inside a string (spec §11).
expect Encode.to_str(Value.text("a\u(2028)b\u(2029)\u(2027)\u(202F)")) == Ok("\"a\\u{2028}b\\u{2029}\u(2027)\u(202F)\"")

## `x` encoded with `encode` and written.
written : a, (a, Encoder -> Try(Encoded(Value), Error)) -> Try(Str, Error)
written = |x, encode| Encode.to_str(Encode.value(x, encode)?)

# The minimised layout (spec §11): compact without the whitespace between tokens.
person : Str, Str, Str -> Value
person = |name, age, kind| variant("Person", [rec([("name", Value.text(name)), ("age", num(age)), ("type", variant(kind, []))])])

expect Encode.minimised(person("John Doe", "30", "Engineer")) == Ok("Person{name:\"John Doe\",age:30,type:Engineer}")
expect Encode.stream_minimised([person("John Doe", "30", "Engineer"), person("Jane Smith", "28", "Designer")]) == Ok("Person{name:\"John Doe\",age:30,type:Engineer},\nPerson{name:\"Jane Smith\",age:28,type:Designer},\n")
expect Encode.minimised(Value.arr([num("1"), variant("Pair", [num("1E5"), Value.text("a b")]), rec([]), Value.arr([]), Value.bytes([0x0b, 0xff]), variant("None", [])])) == Ok("[1,Pair(1e5,\"a b\"),{},[],x\"0bff\",None]")
expect Encode.minimised(rec([("pt-BR", rec([("a", Value.arr([num("1"), num("2")]))])), ("b", variant("Circle", [rec([("r", num("1"))])]))])) == Ok("{\"pt-BR\":{a:[1,2]},b:Circle{r:1}}")
# Strings as in compact: never across lines.
expect Encode.minimised(Value.text("two\nlines\t\u(2028)\u(202E)")) == Ok("\"two\\nlines\\t\\u{2028}\\u{202E}\"")
# Checked as `to_str` checks, with the same places in errors.
expect Encode.minimised(rec([("extra", Value.arr([num("1"), num("1e7000")]))])).map_err(Encode.message) == Err(".extra[1]: exponent larger than 6144")
expect Encode.stream_minimised([num("1"), num("1e7000")]) == Err({ code: "exponent-too-large", reason: "exponent larger than 6144", path: "[1]" })
expect Encode.minimised_with(Value.arr([Value.arr([num("1")])]), { ..Value.default_limits, max_depth: 1 }).map_err(|e| e.code) == Err("nesting-too-deep")
# An empty record, array or record payload is a level, written or built (spec §7).
expect {
	small_depth = |d| { ..Value.default_limits, max_depth: d }
	fits = |v, d| Encode.minimised_with(v, small_depth(d)).is_ok()
	empties = [Value.arr([]), rec([]), variant("A", [rec([])]), variant("Some", [Value.arr([])])]
	empties.map(|v| (fits(v, 0), fits(v, 1))) == [(False, True), (False, True), (False, True), (False, False)]
		and Encode.value_with([], |l, e| Encode.list(l, e, |n, e1| Encode.number(n.to_str(), e1)), small_depth(0)).map_err(|e| e.code).map_ok(|_| {}) == Err("nesting-too-deep")
		and Encode.value_with({}, |_, e| Encode.record(e, []), small_depth(0)).map_err(|e| e.code).map_ok(|_| {}) == Err("nesting-too-deep")
		and Encode.value_with({}, |_, e| Encode.tagged_record("A", e, []), small_depth(0)).map_err(|e| e.code).map_ok(|_| {}) == Err("nesting-too-deep")
		and Encode.value_with({}, |_, e| Encode.tagged_record("A", e, []), small_depth(1)).map_ok(canonical_text) == Ok("A{}")
		and Encode.value_with([], |l, e| Encode.map(l, e, |n, e1| Encode.number(n.to_str(), e1)), small_depth(0)).map_err(|e| e.code).map_ok(|_| {}) == Err("nesting-too-deep")
}
expect Encode.stream_minimised_with([num("1000000000000")], { ..Value.default_limits, max_number_length: 13 }) == Ok("1000000000000,\n")
expect Encode.stream_minimised_with([num("1000000000000")], { ..Value.default_limits, max_number_length: 12 }).map_err(|e| e.code) == Err("number-too-long")
expect Encode.minimised_with(num("1"), { ..Value.default_limits, max_depth: 1025 }).map_err(|e| e.code) == Err("unsupported-depth")
# Minimised and compact differ only in spaces, and both parse back to the value.
expect {
	texts = ["Order { id: 0xFF, lines: [Line(1, \"A 1\"), Line(2, \"B\")], note: \"\"\"\n  a\n  b\n  \"\"\", \"x-y\": {}, e: [] }", "Some(Circle { r: 1.50 })", "[x\"00 ff\", -0x0, 1_000]"]
	texts.all(
		|t| match Value.parse(t) {
			Ok(v) =>
				match (Encode.minimised(v), Encode.to_str(v)) {
					(Ok(m), Ok(c)) => Value.parse(m).map_ok(canonical_text) == Ok(canonical_text(v)) and Value.parse(c).map_ok(canonical_text) == Ok(canonical_text(v)) and m.count_utf8_bytes() < c.count_utf8_bytes()
					_ => False
				}
			Err(_) => False
		},
	)
}

# Floats in their one spelling (spec §15).
expect [1.0, 100.0, 123000.0, 1.5, 12.25, 0.1, 0.000001, 1e-7, 1.5e-7, 1e20, 1e21, -1.5, 0.30000000000000004, 5e-324, 1.7976931348623157e308].map(|x| written(x, Encode.f64) ?? "") == ["1", "100", "123000", "1.5", "12.25", "0.1", "0.000001", "1e-7", "1.5e-7", "100000000000000000000", "1e21", "-1.5", "0.30000000000000004", "5e-324", "1.7976931348623157e308"]
expect [0.0, -0.0, 0.0 / 0.0, 1.0 / 0.0, -1.0 / 0.0].map(|x| written(x, Encode.f64) ?? "") == ["0", "-0", "NaN", "Infinity", "NegInfinity"]
expect [0.1.F32, 16777216.0, 1.0000001, 3.4028235e38, 1e21, -0.0].map(|x| written(x, Encode.f32) ?? "") == ["0.1", "16777216", "1.0000001", "3.4028235e38", "1e21", "-0"]
# Exactly half way between the two closest shortest candidates: the even one, like JavaScript.
expect [1690060720831323.25, -1690060720831323.25].map(|x| written(x, Encode.f64) ?? "") == ["1690060720831323.2", "-1690060720831323.2"]
expect [2097152.25.F32, 2097152.75, 1048576.125, 4498.53125].map(|x| written(x, Encode.f32) ?? "") == ["2097152.2", "2097152.8", "1048576.1", "4498.5312"]

# The canonical form (spec §12): the same cases as the TypeScript and Rust bindings.
canonical_of : Str -> Str
canonical_of = |src| match Value.parse_all(src) {
	Ok([v]) => canonical_text(v)
	_ => "(not one value)"
}

## The canonical form of a value that has one: every parsed value.
canonical_text : Value -> Str
canonical_text = |v| Encode.canonical(v) ?? "(no canonical form)"

equal_texts : Str, Str -> Bool
equal_texts = |a, b| match (Value.parse_all(a), Value.parse_all(b)) {
	(Ok([x]), Ok([y])) => Encode.equals(x, y) ?? False
	_ => False
}

compare_texts : Str, Str -> [Before, Same, After]
compare_texts = |a, b| match (Value.parse_all(a), Value.parse_all(b)) {
	(Ok([x]), Ok([y])) => Encode.compare(x, y) ?? Same
	_ => Same
}

expect canonical_of("Order { total: 19.90, id: 0xFF, \"x-y\": 1e+5, p: Point(1, 2) }") == "Order{id:255,p:Point(1,2),total:19.90,\"x-y\":1e5}"
expect canonical_of("{ b: [1_000, 0b11], /* c */ a: Tag({ x: x\"0B 34\" }) }") == "{a:Tag{x:x\"0b34\"},b:[1000,3]}"
expect equal_texts("{ b: [1_000, 0b11], /* c */ a: Tag({ x: x\"0B 34\" }) }", "{a:Tag{x:x\"0b34\"},b:[1000,3]}")
expect !equal_texts("1.0", "1") and !equal_texts("{}", "{ x: None }") and !equal_texts("-0", "0")
expect !equal_texts("\"caf\\u{E9}\"", "\"cafe\\u{301}\"") and !equal_texts("-0x0", "0")
# `-0x0` is `-0` (spec §2): equal, the same canonical form and hash.
expect equal_texts("-0x0", "-0") and equal_texts("-0b0", "-0") and canonical_of("[-0x0, -0b0, 0x0]") == "[-0,-0,0]"
# U+2028 and U+2029 are escaped (spec §12), as some software splits lines at them; their neighbours are not.
expect canonical_of("\"a\u(2028)b\u(2029)\\u{2027}\\u{202F}\"") == "\"a\\u{2028}b\\u{2029}\u(2027)\u(202F)\""
expect canonical_of("{ \"\u(2028)\": 1 }") == "{\"\\u{2028}\":1}"
expect canonical_of("\"tab\\tquote\\\" \\u{41} \\u{1b} \\u{202e} café 😀\"") == "\"tab\\tquote\\\" A \\u{1B} \\u{202E} café 😀\""
expect canonical_of("\"\"\"\n  two\n  lines\n  \"\"\"") == "\"two\\nlines\""
expect canonical_of("{ \"😀\": 1, \"\u(FFFD)\": 2, a: 3, \"Z\": 4 }") == "{\"Z\":4,a:3,\"\u(FFFD)\":2,\"😀\":1}"
expect canonical_of("[None, Some(1), Circle({ r: 1 }), Pair({ a: 1 }, 2)]") == "[None,Some(1),Circle{r:1},Pair({a:1},2)]"
# Always decimal: the longest hex literal (829 digits) is 999 decimal digits.
expect {
	form = canonical_of("0x${"f".repeat(829)}")
	form.starts_with("16423496480701302824") and form.ends_with("5554113535") and form.count_utf8_bytes() == 999 and canonical_of("-0x${"f".repeat(829)}") == "-${form}"
}
expect match Value.parse_all("9, 10, [], \"😀\", { b: 1, a: 2 }, Some(1), -1") {
	Ok(vs) => vs.sort_with(|a, b| Encode.compare(a, b) ?? Same).map(canonical_text) == ["\"😀\"", "-1", "10", "9", "Some(1)", "[]", "{a:2,b:1}"]
	_ => False
}
expect compare_texts("{ b: 1, a: 2 }", "{ a: 2, b: 1 }") == Same and compare_texts("1.0", "1") == After
# Hashing (spec §12): SHA-256 of the canonical form; a list joins the forms with `,`.
expect match Value.parse_all("{ a: 1 }") {
	Ok([v]) => Encode.hash(v) == Ok("f09a9231c12685ac5f0b6f0b06c9154f13dc3a5b3548db5142c19bde1383f261")
	_ => False
}
expect Encode.hash_all([]) == Ok("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
# A value built in code is a haus value (spec §11), its numbers normalized when
# built, so equal values hash alike, and its canonical form has no limits.
expect Encode.canonical(num("1e+05")) == Ok("1e5") and Encode.canonical(num("0xFF")) == Ok("255") and Encode.canonical(num("1_000")) == Ok("1000")
expect Encode.hash(num("1E+05")) == Encode.hash(num("1e5")) and Encode.canonical(num("0x${Str.repeat("F", 1200)}")).is_ok()
expect Encode.canonical(num("1e99999999999999999999")) == Ok("1e99999999999999999999") and Encode.canonical(variant("Point", [num("1E+05"), num("0xFF")])) == Ok("Point(1e5,255)")
expect Encode.canonical(rec([("b", num("1E+05")), ("a", variant("Some", [rec([("z", Value.bytes([0xAB])), ("pt-BR", Value.arr([]))])]))])) == Ok("{a:Some{\"pt-BR\":[],z:x\"ab\"},b:1e5}")
expect Encode.equals(rec([("a", num("0x10")), ("b", Value.bool(True))]), rec([("b", Value.bool(True)), ("a", num("16"))])) == Ok(True)
expect match (Value.parse_all("{ b: 1, a: 0x2 }, \"x\", [None]"), Value.parse_all("{a:2,b:1},\"x\",[None]")) {
	(Ok(vs), Ok(same)) => {
		joined = Crypto.SHA256.hash("{a:2,b:1},\"x\",[None]".to_utf8()).to_hex()
		one = vs.take_first(1)
		Encode.hash_all(vs) == Ok(joined) and Encode.hash_all(same) == Ok(joined) and Encode.hash_all(one) == Encode.hash_all(same.take_first(1)) and one.map(Encode.hash) == [Encode.hash_all(one)]
	}
	_ => False
}
# Every value has a canonical form and a hash, whatever a reader's limits (spec §12): a 1300-digit
# integer, parsed with a raised limit or built in code, is written with all its digits.
huge_digits : Str
huge_digits = "1${"0".repeat(1299)}"

expect match Value.parse_all_with(huge_digits, { ..Value.default_limits, max_number_length: 2000 }) {
	Ok([v]) => Encode.canonical(v) == Ok(huge_digits) and Encode.hash(v) == Ok(Crypto.SHA256.hash(huge_digits.to_utf8()).to_hex())
	_ => False
}
expect {
	built = rec([("b", num("1")), ("a", Value.arr([Value.text("x"), num(huge_digits)]))])
	form = "{a:[\"x\",${huge_digits}],b:1}"
	Encode.canonical(built) == Ok(form) and Encode.hash(built) == Ok(Crypto.SHA256.hash(form.to_utf8()).to_hex()) and Encode.hash_all([num("1"), built]) == Ok(Crypto.SHA256.hash("1,${form}".to_utf8()).to_hex()) and Encode.hash_all([built]) == Encode.hash(built)
}
expect Encode.equals(num(huge_digits), num("1${"0".repeat(1299)}")) == Ok(True) and Encode.equals(num(huge_digits), num("1")) == Ok(False) and Encode.compare(num(huge_digits), num("2")) == Ok(Before)
# The compact writer writes a huge integer in decimal (spec §11); one too long for the reader is an error.
expect match Value.parse_all("0x${"f".repeat(829)}") {
	Ok([v]) => Encode.to_str(v) == Encode.canonical(v)
	_ => False
}
expect Encode.to_str(num(huge_digits)).map_err(|e| e.code) == Err("number-too-long")

# The writer checks what it writes against a reader's limits (spec §7, §9.8).
error_of : Value -> Str
error_of = |v| match Encode.to_str(v) {
	Ok(text) => "wrote ${text}"
	Err(e) => Encode.message(e)
}

expect Encode.to_str(Value.arr([num("1E5"), num("0xFF"), num("1_000"), num("-0x0"), num("1e-0"), num("1E+05")])) == Ok("[1e5, 255, 1000, -0, 1e0, 1e5]")
expect error_of(rec([("extra", Value.arr([num("1"), num("1e7000")]))])) == ".extra[1]: exponent larger than 6144"
expect error_of(num("1e6145")) == "exponent larger than 6144"
expect error_of(num("1e-99999")) == "exponent larger than 6144"
expect error_of(num("1.${"5".repeat(999)}")) == "number literal longer than 1000 characters"
expect error_of(num("9".repeat(1300))) == "number literal longer than 1000 characters"
expect error_of(variant("Hexagon", [num("1"), num("1e9999")])) == "(Hexagon)[1]: exponent larger than 6144"
expect error_of(variant("Hexagon", [rec([("side", num("9".repeat(1001)))])])) == "(Hexagon).side: number literal longer than 1000 characters"
expect error_of(Value.bytes(List.repeat(0, 8 * 1024 * 1024 + 1))) == "byte string longer than 16777216 characters"
expect error_of(Value.text("x".repeat(16 * 1024 * 1024 + 1))) == "string longer than 16777216 characters"
expect Encode.stream([num("1"), num("1e7000")]) == Err({ code: "exponent-too-large", reason: "exponent larger than 6144", path: "[1]" })
# Encoders build values as the constructors do (spec §11): a tag that isn't a tag
# name, a key used twice, and a number type's text that isn't a number literal fail.
expect Encode.value({}, |_, e| Encode.tag("lower", e)).map_ok(|_| {}) == Err({ code: "invalid-tag", reason: "invalid tag 'lower': a tag is A to Z, then letters, digits and _", path: "" })
expect Encode.value([Value.text("a")], |args, e| Encode.unknown("Hexagon", args, e)).map_ok(canonical_text) == Ok("Hexagon(\"a\")")
expect Encode.value([], |args, e| Encode.unknown("hexagon", args, e)).map_err(|e| e.code).map_ok(|_| {}) == Err("invalid-tag") and Encode.value(Bare("x"), Encode.any_tag).map_err(|e| e.code).map_ok(|_| {}) == Err("invalid-tag")
expect Encode.value(Some(1.I32), |m, e| Encode.maybe(m, e, |_, e1| Encode.tag("no", e1))).map_err(|e| (e.code, e.path)).map_ok(|_| {}) == Err(("invalid-tag", "(Some)[0]"))
expect Encode.value("19.9O", Encode.decimal).map_err(|e| (e.code, e.reason)).map_ok(|_| {}) == Err(("cannot-encode", "invalid number '19.9O': not a number literal"))
expect Encode.value({}, |_, e| Encode.record(e, [("a", Encode.required("x", Encode.str)), ("a", Encode.required("y", Encode.str))])).map_err(|e| (e.code, e.reason)).map_ok(|_| {}) == Err(("duplicate-key", "duplicate key 'a'"))
# Nesting: as deep as the parser reads, and no deeper.
wrapped : U64, Value, (Value -> Value) -> Value
wrapped = |n, inner, wrap| {
	var $v = inner
	var $i = 0
	while $i < n {
		$v = wrap($v)
		$i = $i + 1
	}
	$v
}

expect Encode.to_str(wrapped(256, num("1"), |v| Value.arr([v]))).is_ok() and error_of(wrapped(257, num("1"), |v| Value.arr([v]))).ends_with("nesting deeper than 256 levels")
expect Encode.to_str(wrapped(256, variant("N", []), |v| variant("C", [num("1"), v]))).is_ok() and error_of(wrapped(257, variant("N", []), |v| variant("C", [num("1"), v]))).ends_with("nesting deeper than 256 levels")
expect Encode.to_str(wrapped(255, rec([]), |v| variant("A", [rec([("a", v)])]))).is_ok() and error_of(wrapped(256, rec([]), |v| variant("A", [rec([("a", v)])]))).ends_with("nesting deeper than 256 levels")
# Every value the parser gives is written again, and parses back to itself.
expect {
	texts = ["${"[".repeat(256)}${"]".repeat(256)}", "0x${"f".repeat(829)}", "-0x${"F".repeat(829)}", "1e6144", "-0", "A { a: [1, B(2)] }"]
	texts.all(
		|t| match Value.parse(t) {
			Ok(v) => Encode.to_str(v).map_ok(|w| Value.parse(w).map_ok(canonical_text)) == Ok(Ok(canonical_text(v)))
			Err(_) => False
		},
	)
}

# Writing for a reader with other limits (`to_str_with`): at each limit, and just past it.
small : Value.Limits
small = { ..Value.default_limits, max_depth: 3, max_number_length: 8, max_exponent: 99, max_string_length: 4 }

error_with : Value -> Str
error_with = |v| match Encode.to_str_with(v, small) {
	Ok(_) => ""
	Err(e) => Encode.message(e)
}

expect Encode.to_str_with(wrapped(3, num("1"), |v| Value.arr([v])), small) == Ok("[[[1]]]")
expect error_with(wrapped(4, num("1"), |v| Value.arr([v]))) == "[0][0][0]: nesting deeper than 3 levels"
expect Encode.to_str_with(num("12345678"), small) == Ok("12345678") and error_with(num("123456789")) == "number literal longer than 8 characters"
# An integer longer than the number limit is too long, though its hex form would fit: 10^12 is 0xe8d4a51000 (12 characters).
expect Encode.to_str_with(num("1000000000000"), { ..small, max_number_length: 12 }) == Err({ code: "number-too-long", reason: "number literal longer than 12 characters", path: "" })
expect Encode.to_str_with(num("1e99"), small) == Ok("1e99") and error_with(num("1e100")) == "exponent larger than 99"
expect Encode.to_str_with(Value.text("abcd"), small) == Ok("\"abcd\"") and error_with(Value.text("abcde")) == "string longer than 4 characters"
expect Encode.stream_with([num("1"), num("1e100")], small) == Err({ code: "exponent-too-large", reason: "exponent larger than 99", path: "[1]" })
# Record keys and tags count against the string limit.
expect Encode.to_str_with(rec([("abcd", num("1"))]), small) == Ok("{ abcd: 1 }") and error_with(rec([("abcde", num("1"))])) == ".abcde: key longer than 4 characters"
expect Encode.to_str_with(rec([("äöüß", num("1"))]), small) == Ok("{ \"äöüß\": 1 }")
expect Encode.to_str_with(variant("Abcd", []), small) == Ok("Abcd") and error_with(variant("Abcde", [])) == "tag longer than 4 characters"
expect error_with(variant("A", [variant("Abcde", [])])) == "(A)[0]: tag longer than 4 characters"
# Up to the supported depth; a deeper limit is an error that names the maximum.
expect Encode.to_str_with(wrapped(1024, num("1"), |v| variant("A", [v])), { ..Value.default_limits, max_depth: Value.max_supported_depth }).is_ok()
expect Encode.to_str_with(num("1"), { ..Value.default_limits, max_depth: 1025 }) == Err({ code: "unsupported-depth", reason: "max_depth 1025 is more than the supported maximum, 1024", path: "" })
expect Encode.stream_with([], { ..Value.default_limits, max_depth: 1025 }) == Err({ code: "unsupported-depth", reason: "max_depth 1025 is more than the supported maximum, 1024", path: "" })
# Larger limits than the defaults: exponents past 9999 too.
expect Encode.to_str_with(num("1e12345"), { ..Value.default_limits, max_exponent: 20000 }) == Ok("1e12345")

# Error codes (spec §17), and the place in the value.
code_of : Value -> Str
code_of = |v| match Encode.to_str(v) {
	Ok(_) => "ok"
	Err(e) => "${e.code} at ${ErrorCode.place(e.path)}"
}

expect code_of(Value.arr([num("1"), num("1e7000")])) == "exponent-too-large at $[1]" and code_of(variant("A", [rec([("b", num("1e9999"))])])) == "exponent-too-large at $.b"
expect code_of(rec([("pt-BR", Value.arr([Value.arr([num("9".repeat(1300))])]))])) == "number-too-long at $[\"pt-BR\"][0][0]"
expect code_of(Value.text("x".repeat(16 * 1024 * 1024 + 1))) == "string-too-long at $" and code_of(num("9".repeat(1300))) == "number-too-long at $"
expect code_of(wrapped(257, num("1"), |v| Value.arr([v]))).starts_with("nesting-too-deep at $[0]")
expect Encode.to_str_with(rec([("abcde", num("1"))]), small).map_err(|e| e.code) == Err("key-too-long") and Encode.to_str_with(variant("Abcde", []), small).map_err(|e| e.code) == Err("tag-too-long")
expect Encode.to_str(num("1e7000")).map_err(Encode.error_json) == Err("{\"code\":\"exponent-too-large\",\"message\":\"exponent larger than 6144\",\"path\":\"$\",\"hint\":\"${ErrorCode.hint("exponent-too-large")}\",\"docs\":\"https://haus-fmt.org/docs/errors#exponent-too-large\"}")

# Encoding native values (spec §9.8): what the writer checks, checked as each value is encoded.
Login : { user : Str, creds : Secret(List((Str, Value))) }

encode_login : Login, Encoder -> Try(Encoded(Value), Error)
encode_login = |l, e| Encode.record(e, [("user", Encode.required(l.user, Encode.str)), ("creds", Present(|inner| Encode.secret(l.creds, "Secret (Map Any)", inner, |m, e1| Encode.map(m, e1, Encode.any))))])

login : Value -> Login
login = |v| { user: "ada", creds: Secret.new([("ok", Value.text("fine")), ("alice-pw", v)]) }

# An error inside a Secret is at the secret, and says nothing of the value: not the
# map key, not where in the Any (spec §15), whatever went wrong in it.
expect {
	bad = [num("123456"), variant("Hunter2hunter2", []), Value.text("hunter2hunter2"), wrapped(5, num("1"), |v| Value.arr([v]))]
	bad.all(
		|v| match encode_login(login(v), { ..Encode.top, limits: { ..Value.default_limits, max_depth: 4, max_number_length: 5, max_string_length: 10 } }) {
			Err(e) => e == { code: "invalid-secret", reason: "not a valid Secret (Map Any) (the value is hidden)", path: ".creds" }
			Ok(_) => False
		},
	)
}
expect Encode.value(login(num("1")), encode_login).map_ok(canonical_text) == Ok("{creds:{\"alice-pw\":1,ok:\"fine\"},user:\"ada\"}")
# Inside a tag's argument: the secret's place, as the writer names it.
expect Encode.value(Some(login(num("1e7000"))), |m, e| Encode.maybe(m, e, encode_login)).map_err(|e| (e.code, e.path)).map_ok(canonical_text) == Err(("invalid-secret", "(Some).creds"))
# Outside a secret, the place in the value, as the writer gives it.
expect Encode.value([("a", num("1")), ("pt-BR", Value.arr([num("1e7000")]))], |m, e| Encode.map(m, e, Encode.any)).map_ok(canonical_text) == Err({ code: "exponent-too-large", reason: "exponent larger than 6144", path: "[\"pt-BR\"][0]" })
expect Encode.value([("a", 1.I32), ("a", 2)], |m, e| Encode.map(m, e, |n, e1| Encode.number(n.to_str(), e1))).map_err(|e| (e.code, e.path)).map_ok(canonical_text) == Err(("duplicate-key", ".a"))

# A native value wrapped far deeper than any limit: the encoder stops at the
# limit (nesting-too-deep, at the place the writer names), without recursing on.
# (Encoding all of a chain of 150,000 links, then checking the depth, overflows
# the stack of `roc test`; Roc can't drop a chain of 250,000, so 200,000 it is.)
Chain := [End, Link(Chain)]

encode_chain : Chain, Encoder -> Try(Encoded(Value), Error)
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

expect {
	deep = Encode.value(chain(200_000), encode_chain)
	deep.map_err(|e| (e.code, e.reason, e.path.count_utf8_bytes())).map_ok(canonical_text) == Err(("nesting-too-deep", "nesting deeper than 256 levels", 256 * "(Link)[0]".count_utf8_bytes()))
}
# At the limit, and one past it: the same as the writer, for every limit.
expect [1, 2, 255, 256].all(|n| encode_chain(chain(n), Encode.top).is_ok()) and encode_chain(chain(257), Encode.top).is_err()
expect [0, 1, 3, 1024].all(
	|d| {
		limits = { ..Value.default_limits, max_depth: d }
		Encode.value_with(chain(d), encode_chain, limits).is_ok() and Encode.value_with(chain(d + 1), encode_chain, limits).map_ok(canonical_text) == Encode.to_str_with(wrapped(d + 1, variant("End", []), |v| variant("Link", [v])), limits)
	},
)
# Records as a tag's only argument share its level (`Tag { … }`), as in the writer.
expect {
	tree = |n| wrapped(n, rec([]), |v| rec([("a", v)]))
	wrap = |v, e| Encode.tagged("A", e, |inner| Encode.any(v, inner))
	limits = { ..Value.default_limits, max_depth: 3 }
	[2, 3].all(|n| (wrap(tree(n), Encode.top_with(limits)).map_ok(|_| {})) == (Encode.to_str_with(variant("A", [tree(n)]), limits).map_ok(|_| {})))
}
expect Encode.value_with([1.I32], |l, e| Encode.list(l, e, |n, e1| Encode.number(n.to_str(), e1)), { ..Value.default_limits, max_depth: 2000 }).map_err(|e| e.code).map_ok(canonical_text) == Err("unsupported-depth")

# A native value whose parts are shared (a DAG): each level holds the level
# below twice, so `levels` levels are 2^(levels + 1) − 1 values when written
# out. Encoding counts the values it makes (spec §9.8) and stops at the budget.
Dag := [Leaf, Two(Dag, Dag)]

encode_dag : Dag, Encoder -> Try(Encoded(Value), Error)
encode_dag = |d, e| match d {
	Leaf => Encode.list([], e, encode_dag)
	Two(a, b) => Encode.list([a, b], e, encode_dag)
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

## A DAG of Values built in code, as `dag`.
shared : U64 -> Value
shared = |levels| {
	var $v = Value.arr([])
	var $i = 0
	while $i < levels {
		$v = Value.arr([$v, $v])
		$i = $i + 1
	}
	$v
}

budget : U64 -> Value.Limits
budget = |max| { ..Value.default_limits, max_steps: max }

# 2^41 − 1 values. (At the default budget, 16 Mi, `roc test` takes some 8 seconds to get there.)
expect Value.default_limits.max_steps == 16 * 1024 * 1024
expect {
	e = Encode.value_with(dag(40), encode_dag, budget(100_000)).map_ok(|_| {})
	e.map_err(|err| (err.code, err.reason)) == Err(("step-budget", "encode budget of 100000 steps exceeded (a value whose parts are shared expands when written)"))
}
expect Encode.value_with(dag(40), encode_dag, budget(1000)).map_err(|err| (err.code, err.path.starts_with("[0][0][0][0][0][0][0][0]"))).map_ok(|_| {}) == Err(("step-budget", True))
# The writer counts the values it writes, and `Any` the values in it.
expect Encode.to_str_with(shared(40), budget(100_000)).map_err(|err| err.code) == Err("step-budget") and Encode.minimised_with(shared(40), budget(1000)).map_err(|err| err.code) == Err("step-budget")
expect Encode.value_with(shared(40), Encode.any, budget(1000)).map_err(|err| err.code).map_ok(|_| {}) == Err("step-budget")
# Exactly a step per value: 2^4 − 1 for three levels, at the budget and one under.
expect Encode.value_with(dag(3), encode_dag, budget(15)).is_ok() and Encode.value_with(dag(3), encode_dag, budget(14)).is_err()
expect Encode.to_str_with(shared(3), budget(15)).is_ok() and Encode.to_str_with(shared(3), budget(14)).is_err()
expect Encode.value_with(shared(3), Encode.any, budget(15)).is_ok() and Encode.value_with(shared(3), Encode.any, budget(14)).is_err()
expect Encode.value_with([1.I32, 2, 3], |l, e| Encode.list(l, e, |n, e1| Encode.number(n.to_str(), e1)), budget(4)).map_ok(canonical_text) == Ok("[1,2,3]")
# Each value of a stream has a budget of its own.
expect Encode.stream_with([shared(3), shared(3)], budget(15)).is_ok() and Encode.stream_with([num("1"), shared(3)], budget(14)).map_err(|err| (err.code, err.path.starts_with("[1][1]"))) == Err(("step-budget", True))

# The canonical form, the hash and equality of a DAG (spec §9.8): `shared(n)` is
# n + 1 arrays in memory, but a tree of 2^(n + 1) − 1 values, which the canonical
# form writes out. They are counted first, so 2^41 − 1 fail at the limit, before
# anything is written. (At the default limit, `Value.max_nodes`, that
# takes some 1.5 seconds built with `--opt=speed`, but half a minute in `roc
# test`, so these tests take a smaller one.)
expect {
	e = canonical_within(shared(40), 100_000).map_ok(|_| {})
	e.map_err(|err| (err.code, err.reason, err.path.starts_with("[0][0][0][0][0][0][0][0]"))) == Err(("too-many-nodes", "value has more than 100000 nodes", True))
}
expect canonical_within(shared(40), 1000).map_err(|e| e.code).map_ok(|_| {}) == Err("too-many-nodes")
# A shared part counts each time it is reached: as many values as the tree it
# stands for, 2^4 − 1 for three levels, at the limit and one under, and the
# same canonical form, hash and order.
expect {
	text = "[[[[],[]],[[],[]]],[[[],[]],[[],[]]]]"
	tree = Value.parse(text) ?? num("0")
	[shared(3), tree].all(|v| canonical_within(v, 15).map_ok(bytes_to_str) == Ok(text) and canonical_within(v, 14).map_err(|e| e.code).map_ok(|_| {}) == Err("too-many-nodes"))
		and Encode.canonical(shared(3)) == Ok(text)
		and Encode.hash(shared(3)) == Encode.hash(tree)
		and Encode.hash_all([shared(3), num("1")]) == Encode.hash_all([tree, num("1")])
		and Encode.equals(shared(3), tree) == Ok(True)
		and Encode.equals(shared(3), shared(2)) == Ok(False)
		and Encode.compare(shared(2), tree) == Ok(After)
}
# `Tag { … }` is two values, the tag and its record, as the parser makes them.
expect {
	built = variant("A", [rec([("a", num("1"))])])
	canonical_within(built, 3).map_ok(bytes_to_str) == Ok("A{a:1}") and canonical_within(built, 2).map_err(|e| (e.code, e.path)).map_ok(|_| {}) == Err(("too-many-nodes", "(A).a"))
}
# Nested deeper than any parser takes (`Value.max_supported_depth`, 1024 levels):
# no canonical form, so no hash and no equality, rather than a deep recursion.
expect {
	deep = wrapped(1024, Value.arr([]), |v| Value.arr([v]))
	fails = |r| r.map_err(|e| (e.code, e.reason)).map_ok(|_| {}) == Err(("nesting-too-deep", "nesting deeper than 1024 levels"))
	Encode.canonical(wrapped(1023, Value.arr([]), |v| Value.arr([v]))).is_ok()
		and Encode.canonical(deep).map_err(|e| e.path) == Err("[0]".repeat(1024))
		and fails(Encode.canonical(deep))
		and fails(Encode.hash(deep))
		and fails(Encode.hash_all([deep]))
		and fails(Encode.equals(num("1"), deep))
		and fails(Encode.compare(deep, num("1")))
		and Encode.hash_all([num("1"), deep]).map_err(|e| (e.code, e.path.starts_with("[1][0][0]"))) == Err(("nesting-too-deep", True))
}
expect Value.max_nodes == 64 * 1024 * 1024
