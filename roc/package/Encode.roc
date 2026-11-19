## Writing haus: the compact layout (spec §11: one value per line, normal
## spacing), the minimised layout (the same without spaces), and the building
## blocks that generated encoders use.
##
##     Encode.to_str(Rec([("name", Text("Ada"))]))      # Ok("{ name: \"Ada\" }")
##     Encode.minimised(Rec([("name", Text("Ada"))]))   # Ok("{name:\"Ada\"}")
##
## The writer checks what it writes (spec §9.8). What generated encoders give
## is always fine; a `Value` built in code, such as the raw value of an `Any`
## or an unknown variant, may hold anything: `Num("abc")` is an error.
import ErrorCode
import Int
import Secret
import Value

Encode := [].{

	## One value on one line. The value is checked as it is written, against
	## what a reader takes: number literals (normalized as the parser reads
	## them, so `Num("1E5")` is written `1e5`), tag names, unique keys, and the
	## parser's limits (nesting depth 256, number literals of 1000 characters,
	## exponents up to 6144, strings of 16 Mi characters).
	to_str : Value -> Try(Str, Error)
	to_str = |value| to_str_with(value, Value.default_limits)

	## `to_str` for a reader with other limits (see `Value.Limits`): the value
	## must be within them, so an integer whose decimal form is longer than the
	## number limit is `number-too-long`. Fails if `limits.max_depth` is more
	## than `Value.max_supported_depth`.
	to_str_with : Value, Value.Limits -> Try(Str, Error)
	to_str_with = |value, limits| {
		supported(limits)?
		line(value, 0, { limits, spaced: True }, { bytes: [], steps: 0 }).map_ok(|out| bytes_to_str(out.bytes))
	}

	## One value on one line in the minimised layout (spec §11): the compact
	## layout without the whitespace between tokens, for the wire and storage.
	## Checked as `to_str` checks it.
	##
	##     Encode.minimised(Tag("Person", [Rec([("age", Num("30"))])]))   # Ok("Person{age:30}")
	minimised : Value -> Try(Str, Error)
	minimised = |value| minimised_with(value, Value.default_limits)

	## `minimised` for a reader with other limits (see `to_str_with`).
	minimised_with : Value, Value.Limits -> Try(Str, Error)
	minimised_with = |value, limits| {
		supported(limits)?
		line(value, 0, { limits, spaced: False }, { bytes: [], steps: 0 }).map_ok(|out| bytes_to_str(out.bytes))
	}

	## `.extra[1]: not a number literal`, or just the reason at the root.
	message : Error -> Str
	message = |e| if (e.path == "") e.reason else "${e.path}: ${e.reason}"

	## The JSON form of an error (spec §17), on one line, with its place as
	## `$.extra[1]` (see `ErrorCode.place`):
	## `{"code":"cannot-encode","message":"not a number literal","path":"$.extra[1]","hint":…,"docs":…}`.
	error_json : Error -> Str
	error_json = |e| ErrorCode.json({ code: e.code, message: e.reason, at: Path(e.path) })

	## The canonical form (spec §12): one exact text per value, the same in
	## every binding, so equal values (§2) give identical text. Every value
	## has one, whatever a reader's limits: an integer is written in decimal
	## with all its digits, however long.
	##
	##     Encode.canonical(Rec([("b", Num("1")), ("a", Num("255"))]))   # "{a:255,b:1}"
	canonical : Value -> Str
	canonical = |value| bytes_to_str(canonical_bytes(value))

	## The SHA-256 digest of the canonical form, as 64 lowercase hex digits
	## (spec §12): the same whatever the layout, comments or key order.
	hash : Value -> Str
	hash = |value| Crypto.SHA256.hash(canonical_bytes(value)).to_hex()

	## The hash of a list of values, such as a whole file or stream (spec
	## §12): the SHA-256 digest of their canonical forms joined by `,`. A list
	## of one value hashes like the value: `hash_all([v])` is `hash(v)`.
	hash_all : List(Value) -> Str
	hash_all = |values| values.fold(HashAll.empty, HashAll.add).digest()

	## `hash_all` of a list as it grows, e.g. a stream while it is read: `add`
	## each value, and `digest` at any time gives `hash_all` of the values
	## added so far. Memory stays bounded by the largest value.
	##
	##     var $hash = Encode.HashAll.empty
	##     for value in values {
	##         $hash = $hash.add(value)
	##     }
	##     $hash.digest() # Encode.hash_all(values)
	HashAll :: { sha : Crypto.SHA256.Hasher, count : U64 }.{
		empty : Encode.HashAll
		empty = { sha: Crypto.SHA256.Hasher.empty(), count: 0 }

		## Add the next value.
		add : Encode.HashAll, Value -> Encode.HashAll
		add = |h, value| {
			sha = if (h.count > 0) h.sha.write([',']) else h.sha
			{ sha: sha.write(canonical_bytes(value)), count: h.count + 1 }
		}

		## `hash_all` of the values added so far, as 64 lowercase hex digits.
		digest : Encode.HashAll -> Str
		digest = |h| h.sha.finish().to_hex()
	}

	## Whether two values are equal (spec §2): the same canonical form.
	equals : Value, Value -> Bool
	equals = |a, b| canonical_bytes(a) == canonical_bytes(b)

	## Orders values by the bytes of their canonical forms (spec §12): a total
	## order consistent with `equals`, for sorting (`values.sort_with(Encode.compare)`).
	## Not numeric order: `10` sorts before `9`.
	compare : Value, Value -> [Before, Same, After]
	compare = |a, b| compare_bytes(canonical_bytes(a), canonical_bytes(b))

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
		made(Text(s), e)
	}

	bytes : List(U8), Encoder -> Try(Encoded(Value), Error)
	bytes = |b, e| {
		check_bytes(b, e.limits)?
		made(Bytes(b), e)
	}

	bool : Bool, Encoder -> Try(Encoded(Value), Error)
	bool = |b, e| tag(if (b) "True" else "False", e)

	## `Int`: an integer of any size, as its digits.
	int : Int, Encoder -> Try(Encoded(Value), Error)
	int = |n, e| number(n.to_str(), e)

	## A number literal (`Int8`…`UInt64` as `n.to_str()`), normalized as the
	## parser reads it, within the number limits.
	number : Str, Encoder -> Try(Encoded(Value), Error)
	number = |text, e| made(Num(bytes_to_str(literal(text, e.limits)?)), e)

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
		Ok({ value: Arr($out), steps: $steps })
	}

	## `Map v`: a record used as a dictionary. A key used twice is `duplicate-key`.
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
		Ok({ value: Rec($out), steps: $steps })
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
		Ok({ value: Rec($out), steps: $steps })
	}

	## A tag without payload: `None`, `Circle`.
	tag : Str, Encoder -> Try(Encoded(Value), Error)
	tag = |name, e| {
		check_tag(name, e.limits)?
		made(Tag(name, []), e)
	}

	## A tag with one argument, which `encode` encodes inside it: `Some(1)`,
	## and `Wrap { w: 1 }` for a record (`Tag { … }` takes one level, spec §7).
	tagged : Str, Encoder, (Encoder -> Try(Encoded(Value), Error)) -> Try(Encoded(Value), Error)
	tagged = |name, e, encode| {
		check_tag(name, e.limits)?
		inner = payload(e)?
		match encode({ ..inner, steps: step(e)? }) {
			Ok(arg) => Ok({ value: Tag(name, [arg.value]), steps: arg.steps })
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
		Ok({ value: Tag(name, $out), steps: $steps })
	}

	## A tag with a record payload: `Circle { r: 1.5 }`, as `record` takes it.
	tagged_record : Str, Encoder, List((Str, [Missing, Present(Encoder -> Try(Encoded(Value), Error))])) -> Try(Encoded(Value), Error)
	tagged_record = |name, e, fields| {
		check_tag(name, e.limits)?
		inner = within(payload(e), "(${name})")?
		r = within(record({ ..inner, steps: step(e)? }, fields), "(${name})")?
		Ok({ value: Tag(name, [r.value]), steps: r.steps })
	}

	## An unknown variant kept as it was, checked as the writer checks it.
	unknown : Str, List(Value), Encoder -> Try(Encoded(Value), Error)
	unknown = |name, args, e| any(Tag(name, args), e)

	## `Any`: the value as it was, checked as the writer checks it here, a
	## step for each value in it.
	any : Value, Encoder -> Try(Encoded(Value), Error)
	any = |v, e| {
		supported(e.limits)?
		# A record that is a tag's only argument shares the tag's level.
		depth = match v {
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
		Bare(name) => any(Tag(name, []), e)
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
## A number that isn't a literal is `cannot-encode`, a tag that isn't a tag
## name `invalid-tag`, a key used twice `duplicate-key`; what is beyond the
## limits has the limit's code (`string-too-long`).
Error : { code : Str, reason : Str, path : Str }

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

## Keys are unique (spec §1): a map built in code might repeat one.
unique_keys : List(Str) -> Try({}, Error)
unique_keys = |keys| {
	var $numbered = List.with_capacity(keys.len())
	for k in keys {
		$numbered = $numbered.append((k, $numbered.len()))
	}
	match Value.first_repeated($numbered) {
		Ok((k, _)) => Err({ code: ErrorCode.duplicate_key, reason: "the key is used twice in this record", path: ErrorCode.path_key(k) })
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

## A tag name (`[A-Z][A-Za-z0-9_]*`) within the string limit.
check_tag : Str, Value.Limits -> Try({}, Error)
check_tag = |name, limits|
	if is_tag(name) {
		check_text(name, "tag", limits)
	} else {
		fail(ErrorCode.invalid_tag, "not a tag name: A to Z, then letters, digits and _")
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
	match value {
		Num(text) => Ok({ ..out, bytes: out.bytes.concat(literal(text, limits)?) })
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
			check_tag(name, limits)?
			named = { ..out, bytes: out.bytes.concat(name.to_utf8()) }
			match args {
				[] => Ok(named)
				[Rec(fields)] => within(record_line(fields, depth, writer, { ..named, bytes: named.bytes.concat(space(writer)) }), "(${name})")
				_ => {
					open(depth, limits)?
					inside = within(items_line(args, depth + 1, writer, { ..named, bytes: named.bytes.append('(') }), "(${name})")?
					Ok({ ..inside, bytes: inside.bytes.append(')') })
				}
			}
		}
	}
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
	# Keys are unique (spec §1): a record built in code might repeat one.
	unique_keys(fields.map(|(k, _)| k))?
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

## A tag name: `[A-Z][A-Za-z0-9_]*`.
is_tag : Str -> Bool
is_tag = |name| {
	b = name.to_utf8()
	first = byte_at(b, 0)
	first >= 'A' and first <= 'Z' and b.all(|c| (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')
}

## The text a number is written as, or why it can't be: its normalized
## literal (spec §2), always decimal, within the limits.
literal : Str, Value.Limits -> Try(List(U8), Error)
literal = |text, limits| {
	b = text.to_utf8()
	literal_chars = b.all(|c| (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == 'x' or c == '.' or c == '_' or c == '+' or c == '-')
	n =
		if is_normalized(b) {
			b
		} else if !literal_chars {
			return fail(ErrorCode.cannot_encode, "not a number literal")
		} else if b.len() > limits.max_number_length {
			return fail(ErrorCode.number_too_long, "number literal longer than ${limits.max_number_length.to_str()} characters")
		} else {
			match Value.parse_with(text, limits) {
				Ok(Num(normalized)) => normalized.to_utf8()
				_ => return fail(ErrorCode.cannot_encode, "not a number literal")
			}
		}
	# The exponent: `e`, an optional `-`, digits without leading zeros.
	match n.find_first_index(|c| c == 'e') {
		Ok(i) => {
			# The length first, as a parser meets it (spec §7).
			if n.len() > limits.max_number_length {
				return fail(ErrorCode.number_too_long, "number literal longer than ${limits.max_number_length.to_str()} characters")
			}
			digits = n.drop_first(i + 1).drop_if(|c| c == '-')
			too_large = digits.len() > 18 or (U64.from_str(bytes_to_str(digits)) ?? 0) > limits.max_exponent
			if too_large {
				return fail(ErrorCode.exponent_too_large, "exponent larger than ${limits.max_exponent.to_str()}")
			}
		}
		Err(_) => {}
	}
	# Integers too: always decimal (spec §11), so one longer than the limit has no text a reader with it takes.
	if n.len() > limits.max_number_length {
		fail(ErrorCode.number_too_long, "number literal longer than ${limits.max_number_length.to_str()} characters")
	} else {
		Ok(n)
	}
}

## Whether a literal is normalized (spec §2), as the parser gives it:
## `-?(0|[1-9][0-9]*)(.[0-9]+)?(e(0|-?[1-9][0-9]*))?`.
is_normalized : List(U8) -> Bool
is_normalized = |b| {
	digit = |c| c >= '0' and c <= '9'
	whole = |s| s == ['0'] or (byte_at(s, 0) >= '1' and byte_at(s, 0) <= '9' and s.all(digit))
	(mantissa, exp) = match b.find_first_index(|c| c == 'e') {
		Ok(i) => (b.take_first(i), Ok(b.drop_first(i + 1)))
		Err(_) => (b, Err({}))
	}
	unsigned = if (byte_at(mantissa, 0) == '-') mantissa.drop_first(1) else mantissa
	(int, frac) = match unsigned.find_first_index(|c| c == '.') {
		Ok(i) => (unsigned.take_first(i), Ok(unsigned.drop_first(i + 1)))
		Err(_) => (unsigned, Err({}))
	}
	frac_ok = match frac {
		Ok(f) => !f.is_empty() and f.all(digit)
		Err(_) => True
	}
	exp_ok = match exp {
		Ok(e) => whole(e) or (byte_at(e, 0) == '-' and e != ['-', '0'] and whole(e.drop_first(1)))
		Err(_) => True
	}
	whole(int) and frac_ok and exp_ok
}

## The canonical form: no spaces, fields sorted by key, numbers as their
## normalized decimal literal, however long.
canonical_bytes : Value -> List(U8)
canonical_bytes = |value| match value {
	Num(text) => text.to_utf8()
	Text(s) => quote(s)
	Bytes(b) => "x\"".to_utf8().concat(hex(b)).append('"')
	Arr(items) => ['['].concat(comma_joined(items.map(canonical_bytes))).append(']')
	Rec(fields) => canonical_record(fields)
	Tag(name, []) => name.to_utf8()
	Tag(name, [Rec(fields)]) => name.to_utf8().concat(canonical_record(fields))
	Tag(name, args) => name.to_utf8().append('(').concat(comma_joined(args.map(canonical_bytes))).append(')')
}

## Fields sorted by their keys' UTF-8 bytes, which is the order of code points.
canonical_record : List((Str, Value)) -> List(U8)
canonical_record = |fields| {
	sorted = fields.map(|(k, v)| (k.to_utf8(), k, v)).sort_with(|(a, _, _), (b, _, _)| compare_bytes(a, b))
	entries = sorted.map(|(_, k, v)| key(k).append(':').concat(canonical_bytes(v)))
	['{'].concat(comma_joined(entries)).append('}')
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

expect Encode.to_str(Rec([("name", Text("Ada")), ("pt-BR", Num("1"))])) == Ok("{ name: \"Ada\", \"pt-BR\": 1 }")
expect Encode.to_str(Tag("Shipped", [Rec([("tracking", Text("DE-4711"))])])) == Ok("Shipped { tracking: \"DE-4711\" }")
expect Encode.to_str(Tag("Money", [Num("44.40"), Tag("EUR", [])])) == Ok("Money(44.40, EUR)")
expect Encode.to_str(Arr([Bytes([0x0b, 0xff]), Rec([]), Arr([])])) == Ok("[x\"0bff\", {}, []]")
expect Encode.to_str(Text("a\"b\\\n\u(202E)")) == Ok("\"a\\\"b\\\\\\n\\u{202E}\"")
expect Encode.stream([Tag("A", []), Num("1")]) == Ok("A,\n1,\n")
expect Int.from_str("340282366920938463463374607431768211457").map_ok(|n| written(n, Encode.int)) == Ok(Ok("340282366920938463463374607431768211457"))
expect written({ a: 1.I32, b: Missing }, |r, e| Encode.record(e, [("a", Present(|inner| Encode.number(r.a.to_str(), inner))), ("b", Encode.optional(r.b, Encode.str))])) == Ok("{ a: 1 }")
expect written({ a: "x", b: Present("y") }, |r, e| Encode.record(e, [("a", Encode.required(r.a, Encode.str)), ("b", Encode.optional(r.b, Encode.str))])) == Ok("{ a: \"x\", b: \"y\" }")
expect Encode.to_str(Text("\u(1B)\u(7F)\u(85)")) == Ok("\"\\u{1B}\\u{7F}\\u{85}\"")
# U+2028 and U+2029 are escaped too, so a line never ends inside a string (spec §11).
expect Encode.to_str(Text("a\u(2028)b\u(2029)\u(2027)\u(202F)")) == Ok("\"a\\u{2028}b\\u{2029}\u(2027)\u(202F)\"")

## `x` encoded with `encode` and written.
written : a, (a, Encoder -> Try(Encoded(Value), Error)) -> Try(Str, Error)
written = |x, encode| Encode.to_str(Encode.value(x, encode)?)

# The minimised layout (spec §11): compact without the whitespace between tokens.
person : Str, Str, Str -> Value
person = |name, age, kind| Tag("Person", [Rec([("name", Text(name)), ("age", Num(age)), ("type", Tag(kind, []))])])

expect Encode.minimised(person("John Doe", "30", "Engineer")) == Ok("Person{name:\"John Doe\",age:30,type:Engineer}")
expect Encode.stream_minimised([person("John Doe", "30", "Engineer"), person("Jane Smith", "28", "Designer")]) == Ok("Person{name:\"John Doe\",age:30,type:Engineer},\nPerson{name:\"Jane Smith\",age:28,type:Designer},\n")
expect Encode.minimised(Arr([Num("1"), Tag("Pair", [Num("1E5"), Text("a b")]), Rec([]), Arr([]), Bytes([0x0b, 0xff]), Tag("None", [])])) == Ok("[1,Pair(1e5,\"a b\"),{},[],x\"0bff\",None]")
expect Encode.minimised(Rec([("pt-BR", Rec([("a", Arr([Num("1"), Num("2")]))])), ("b", Tag("Circle", [Rec([("r", Num("1"))])]))])) == Ok("{\"pt-BR\":{a:[1,2]},b:Circle{r:1}}")
# Strings as in compact: never across lines.
expect Encode.minimised(Text("two\nlines\t\u(2028)\u(202E)")) == Ok("\"two\\nlines\\t\\u{2028}\\u{202E}\"")
# Checked as `to_str` checks, with the same places in errors.
expect Encode.minimised(Rec([("extra", Arr([Num("1"), Num("abc")]))])).map_err(Encode.message) == Err(".extra[1]: not a number literal")
expect Encode.stream_minimised([Num("1"), Num("x")]) == Err({ code: "cannot-encode", reason: "not a number literal", path: "[1]" })
expect Encode.minimised_with(Arr([Arr([Num("1")])]), { ..Value.default_limits, max_depth: 1 }).map_err(|e| e.code) == Err("nesting-too-deep")
# An empty record, array or record payload is a level, written or built (spec §7).
expect {
	small_depth = |d| { ..Value.default_limits, max_depth: d }
	fits = |v, d| Encode.minimised_with(v, small_depth(d)).is_ok()
	empties = [Arr([]), Rec([]), Tag("A", [Rec([])]), Tag("Some", [Arr([])])]
	empties.map(|v| (fits(v, 0), fits(v, 1))) == [(False, True), (False, True), (False, True), (False, False)]
		and Encode.value_with([], |l, e| Encode.list(l, e, |n, e1| Encode.number(n.to_str(), e1)), small_depth(0)).map_err(|e| e.code).map_ok(|_| {}) == Err("nesting-too-deep")
		and Encode.value_with({}, |_, e| Encode.record(e, []), small_depth(0)).map_err(|e| e.code).map_ok(|_| {}) == Err("nesting-too-deep")
		and Encode.value_with({}, |_, e| Encode.tagged_record("A", e, []), small_depth(0)).map_err(|e| e.code).map_ok(|_| {}) == Err("nesting-too-deep")
		and Encode.value_with({}, |_, e| Encode.tagged_record("A", e, []), small_depth(1)).map_ok(Encode.canonical) == Ok("A{}")
		and Encode.value_with([], |l, e| Encode.map(l, e, |n, e1| Encode.number(n.to_str(), e1)), small_depth(0)).map_err(|e| e.code).map_ok(|_| {}) == Err("nesting-too-deep")
}
expect Encode.stream_minimised_with([Num("1000000000000")], { ..Value.default_limits, max_number_length: 13 }) == Ok("1000000000000,\n")
expect Encode.stream_minimised_with([Num("1000000000000")], { ..Value.default_limits, max_number_length: 12 }).map_err(|e| e.code) == Err("number-too-long")
expect Encode.minimised_with(Num("1"), { ..Value.default_limits, max_depth: 1025 }).map_err(|e| e.code) == Err("unsupported-depth")
# Minimised and compact differ only in spaces, and both parse back to the value.
expect {
	texts = ["Order { id: 0xFF, lines: [Line(1, \"A 1\"), Line(2, \"B\")], note: \"\"\"\n  a\n  b\n  \"\"\", \"x-y\": {}, e: [] }", "Some(Circle { r: 1.50 })", "[x\"00 ff\", -0x0, 1_000]"]
	texts.all(
		|t| match Value.parse(t) {
			Ok(v) =>
				match (Encode.minimised(v), Encode.to_str(v)) {
					(Ok(m), Ok(c)) => Value.parse(m).map_ok(Encode.canonical) == Ok(Encode.canonical(v)) and Value.parse(c).map_ok(Encode.canonical) == Ok(Encode.canonical(v)) and m.count_utf8_bytes() < c.count_utf8_bytes()
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
	Ok([v]) => Encode.canonical(v)
	_ => "(not one value)"
}

equal_texts : Str, Str -> Bool
equal_texts = |a, b| match (Value.parse_all(a), Value.parse_all(b)) {
	(Ok([x]), Ok([y])) => Encode.equals(x, y)
	_ => False
}

compare_texts : Str, Str -> [Before, Same, After]
compare_texts = |a, b| match (Value.parse_all(a), Value.parse_all(b)) {
	(Ok([x]), Ok([y])) => Encode.compare(x, y)
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
	Ok(vs) => vs.sort_with(Encode.compare).map(Encode.canonical) == ["\"😀\"", "-1", "10", "9", "Some(1)", "[]", "{a:2,b:1}"]
	_ => False
}
expect compare_texts("{ b: 1, a: 2 }", "{ a: 2, b: 1 }") == Same and compare_texts("1.0", "1") == After
# Hashing (spec §12): SHA-256 of the canonical form; a list joins the forms with `,`.
expect match Value.parse_all("{ a: 1 }") {
	Ok([v]) => Encode.hash(v) == "f09a9231c12685ac5f0b6f0b06c9154f13dc3a5b3548db5142c19bde1383f261"
	_ => False
}
expect Encode.hash_all([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
expect match (Value.parse_all("{ b: 1, a: 0x2 }, \"x\", [None]"), Value.parse_all("{a:2,b:1},\"x\",[None]")) {
	(Ok(vs), Ok(same)) => {
		joined = Crypto.SHA256.hash("{a:2,b:1},\"x\",[None]".to_utf8()).to_hex()
		one = vs.take_first(1)
		Encode.hash_all(vs) == joined and Encode.hash_all(same) == joined and Encode.hash_all(one) == Encode.hash_all(same.take_first(1)) and one.map(Encode.hash) == [Encode.hash_all(one)]
	}
	_ => False
}
# The running hash gives `hash_all` of what was added so far, at any time.
expect match Value.parse_all("1, \"two\", Three { n: 3 }") {
	Ok(vs) => {
		var $h = Encode.HashAll.empty
		var $digests = [$h.digest()]
		for v in vs {
			$h = $h.add(v)
			$digests = $digests.append($h.digest())
		}
		$digests == [0, 1, 2, 3].map(|n| Encode.hash_all(vs.take_first(n)))
	}
	_ => False
}
# Every value has a canonical form and a hash, whatever a reader's limits (spec §12): a 1300-digit
# integer, parsed with a raised limit or built in code, is written with all its digits.
huge_digits : Str
huge_digits = "1${"0".repeat(1299)}"

expect match Value.parse_all_with(huge_digits, { ..Value.default_limits, max_number_length: 2000 }) {
	Ok([v]) => Encode.canonical(v) == huge_digits and Encode.hash(v) == Crypto.SHA256.hash(huge_digits.to_utf8()).to_hex()
	_ => False
}
expect {
	built = Rec([("b", Num("1")), ("a", Arr([Text("x"), Num(huge_digits)]))])
	form = "{a:[\"x\",${huge_digits}],b:1}"
	Encode.canonical(built) == form and Encode.hash(built) == Crypto.SHA256.hash(form.to_utf8()).to_hex() and Encode.hash_all([Num("1"), built]) == Crypto.SHA256.hash("1,${form}".to_utf8()).to_hex() and Encode.HashAll.empty.add(built).digest() == Encode.hash(built)
}
expect Encode.equals(Num(huge_digits), Num("1${"0".repeat(1299)}")) and !Encode.equals(Num(huge_digits), Num("1")) and Encode.compare(Num(huge_digits), Num("2")) == Before
# The compact writer writes a huge integer in decimal (spec §11); one too long for the reader is an error.
expect match Value.parse_all("0x${"f".repeat(829)}") {
	Ok([v]) => Encode.to_str(v) == Ok(Encode.canonical(v))
	_ => False
}
expect Encode.to_str(Num(huge_digits)).map_err(|e| e.code) == Err("number-too-long")

# The writer checks what it writes (spec §9.8): a Value built in code may hold anything.
error_of : Value -> Str
error_of = |v| match Encode.to_str(v) {
	Ok(text) => "wrote ${text}"
	Err(e) => Encode.message(e)
}

expect Encode.to_str(Arr([Num("1E5"), Num("0xFF"), Num("1_000"), Num("-0x0"), Num("1e-0"), Num("1E+05")])) == Ok("[1e5, 255, 1000, -0, 1e0, 1e5]")
expect ["", "-", "1.", ".5", "01", "1e", "+1", "0x", "1 ", "1 // c", "NaN", "1e5.5", "abc", "--1"].map(|n| error_of(Num(n))) == List.repeat("not a number literal", 14)
expect error_of(Rec([("extra", Arr([Num("1"), Num("abc")]))])) == ".extra[1]: not a number literal"
expect error_of(Num("1e6145")) == "exponent larger than 6144"
expect error_of(Num("1e-99999")) == "exponent larger than 6144"
expect error_of(Num("1.5".repeat(400))) == "number literal longer than 1000 characters"
expect error_of(Num("9".repeat(1300))) == "number literal longer than 1000 characters"
expect error_of(Tag("lower", [])) == "not a tag name: A to Z, then letters, digits and _"
expect error_of(Tag("Hexagon", [Num("1"), Num("--1")])) == "(Hexagon)[1]: not a number literal"
expect error_of(Tag("Hexagon", [Rec([("side", Num("x"))])])) == "(Hexagon).side: not a number literal"
expect error_of(Rec([("a", Num("1")), ("a", Num("2"))])) == ".a: the key is used twice in this record"
expect error_of(Bytes(List.repeat(0, 8 * 1024 * 1024 + 1))) == "byte string longer than 16777216 characters"
expect error_of(Text("x".repeat(16 * 1024 * 1024 + 1))) == "string longer than 16777216 characters"
expect Encode.stream([Num("1"), Num("x")]) == Err({ code: "cannot-encode", reason: "not a number literal", path: "[1]" })
# Nesting: as deep as the parser reads, and no deeper.
nested : U64, Value, (Value -> Value) -> Value
nested = |n, inner, wrap| {
	var $v = inner
	var $i = 0
	while $i < n {
		$v = wrap($v)
		$i = $i + 1
	}
	$v
}

expect Encode.to_str(nested(256, Num("1"), |v| Arr([v]))).is_ok() and error_of(nested(257, Num("1"), |v| Arr([v]))).ends_with("nesting deeper than 256 levels")
expect Encode.to_str(nested(256, Tag("N", []), |v| Tag("C", [Num("1"), v]))).is_ok() and error_of(nested(257, Tag("N", []), |v| Tag("C", [Num("1"), v]))).ends_with("nesting deeper than 256 levels")
expect Encode.to_str(nested(255, Rec([]), |v| Tag("A", [Rec([("a", v)])]))).is_ok() and error_of(nested(256, Rec([]), |v| Tag("A", [Rec([("a", v)])]))).ends_with("nesting deeper than 256 levels")
# Every value the parser gives is written again, and parses back to itself.
expect {
	texts = ["${"[".repeat(256)}${"]".repeat(256)}", "0x${"f".repeat(829)}", "-0x${"F".repeat(829)}", "1e6144", "-0", "A { a: [1, B(2)] }"]
	texts.all(
		|t| match Value.parse(t) {
			Ok(v) => Encode.to_str(v).map_ok(|w| Value.parse(w).map_ok(Encode.canonical)) == Ok(Ok(Encode.canonical(v)))
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

expect Encode.to_str_with(nested(3, Num("1"), |v| Arr([v])), small) == Ok("[[[1]]]")
expect error_with(nested(4, Num("1"), |v| Arr([v]))) == "[0][0][0]: nesting deeper than 3 levels"
expect Encode.to_str_with(Num("12345678"), small) == Ok("12345678") and error_with(Num("123456789")) == "number literal longer than 8 characters"
# An integer longer than the number limit is too long, though its hex form would fit: 10^12 is 0xe8d4a51000 (12 characters).
expect Encode.to_str_with(Num("1000000000000"), { ..small, max_number_length: 12 }) == Err({ code: "number-too-long", reason: "number literal longer than 12 characters", path: "" })
expect Encode.to_str_with(Num("1e99"), small) == Ok("1e99") and error_with(Num("1e100")) == "exponent larger than 99"
expect Encode.to_str_with(Text("abcd"), small) == Ok("\"abcd\"") and error_with(Text("abcde")) == "string longer than 4 characters"
expect Encode.stream_with([Num("1"), Num("1e100")], small) == Err({ code: "exponent-too-large", reason: "exponent larger than 99", path: "[1]" })
# Record keys and tags count against the string limit.
expect Encode.to_str_with(Rec([("abcd", Num("1"))]), small) == Ok("{ abcd: 1 }") and error_with(Rec([("abcde", Num("1"))])) == ".abcde: key longer than 4 characters"
expect Encode.to_str_with(Rec([("äöüß", Num("1"))]), small) == Ok("{ \"äöüß\": 1 }")
expect Encode.to_str_with(Tag("Abcd", []), small) == Ok("Abcd") and error_with(Tag("Abcde", [])) == "tag longer than 4 characters"
expect error_with(Tag("A", [Tag("Abcde", [])])) == "(A)[0]: tag longer than 4 characters"
# Up to the supported depth; a deeper limit is an error that names the maximum.
expect Encode.to_str_with(nested(1024, Num("1"), |v| Tag("A", [v])), { ..Value.default_limits, max_depth: Value.max_supported_depth }).is_ok()
expect Encode.to_str_with(Num("1"), { ..Value.default_limits, max_depth: 1025 }) == Err({ code: "unsupported-depth", reason: "max_depth 1025 is more than the supported maximum, 1024", path: "" })
expect Encode.stream_with([], { ..Value.default_limits, max_depth: 1025 }) == Err({ code: "unsupported-depth", reason: "max_depth 1025 is more than the supported maximum, 1024", path: "" })
# Larger limits than the defaults: exponents past 9999 too.
expect Encode.to_str_with(Num("1e12345"), { ..Value.default_limits, max_exponent: 20000 }) == Ok("1e12345")

# Error codes (spec §17), and the place in the value.
code_of : Value -> Str
code_of = |v| match Encode.to_str(v) {
	Ok(_) => "ok"
	Err(e) => "${e.code} at ${ErrorCode.place(e.path)}"
}

expect code_of(Arr([Num("1"), Num("x")])) == "cannot-encode at $[1]" and code_of(Tag("lower", [])) == "invalid-tag at $"
expect code_of(Rec([("pt-BR", Num("1")), ("pt-BR", Num("2"))])) == "duplicate-key at $[\"pt-BR\"]" and code_of(Tag("A", [Rec([("b", Num("1e9999"))])])) == "exponent-too-large at $.b"
expect code_of(Text("x".repeat(16 * 1024 * 1024 + 1))) == "string-too-long at $" and code_of(Num("9".repeat(1300))) == "number-too-long at $"
expect code_of(nested(257, Num("1"), |v| Arr([v]))).starts_with("nesting-too-deep at $[0]")
expect Encode.to_str_with(Rec([("abcde", Num("1"))]), small).map_err(|e| e.code) == Err("key-too-long") and Encode.to_str_with(Tag("Abcde", []), small).map_err(|e| e.code) == Err("tag-too-long")
expect Encode.to_str(Num("x")).map_err(Encode.error_json) == Err("{\"code\":\"cannot-encode\",\"message\":\"not a number literal\",\"path\":\"$\",\"hint\":\"Pass a value of the host type the binding documents for the type.\",\"docs\":\"https://haus-fmt.org/docs/errors#cannot-encode\"}")

# Encoding native values (spec §9.8): what the writer checks, checked as each value is encoded.
Login : { user : Str, creds : Secret(List((Str, Value))) }

encode_login : Login, Encoder -> Try(Encoded(Value), Error)
encode_login = |l, e| Encode.record(e, [("user", Encode.required(l.user, Encode.str)), ("creds", Present(|inner| Encode.secret(l.creds, "Secret (Map Any)", inner, |m, e1| Encode.map(m, e1, Encode.any))))])

login : Value -> Login
login = |v| { user: "ada", creds: Secret.new([("ok", Text("fine")), ("alice-pw", v)]) }

# An error inside a Secret is at the secret, and says nothing of the value: not the
# map key, not where in the Any (spec §15), whatever went wrong in it.
expect {
	bad = [Num("hunter2"), Rec([("x", Num("1")), ("x", Num("2"))]), Tag("hunter2", []), Text("hunter2hunter2"), nested(5, Num("1"), |v| Arr([v]))]
	bad.all(
		|v| match encode_login(login(v), { ..Encode.top, limits: { ..Value.default_limits, max_depth: 4, max_string_length: 10 } }) {
			Err(e) => e == { code: "invalid-secret", reason: "not a valid Secret (Map Any) (the value is hidden)", path: ".creds" }
			Ok(_) => False
		},
	)
}
expect Encode.value(login(Num("1")), encode_login).map_ok(Encode.canonical) == Ok("{creds:{\"alice-pw\":1,ok:\"fine\"},user:\"ada\"}")
# Inside a tag's argument: the secret's place, as the writer names it.
expect Encode.value(Some(login(Num("x"))), |m, e| Encode.maybe(m, e, encode_login)).map_err(|e| (e.code, e.path)).map_ok(Encode.canonical) == Err(("invalid-secret", "(Some).creds"))
# Outside a secret, the place in the value, as the writer gives it.
expect Encode.value([("a", Num("1")), ("pt-BR", Arr([Num("x")]))], |m, e| Encode.map(m, e, Encode.any)).map_ok(Encode.canonical) == Err({ code: "cannot-encode", reason: "not a number literal", path: "[\"pt-BR\"][0]" })
expect Encode.value([("a", 1.I32), ("a", 2)], |m, e| Encode.map(m, e, |n, e1| Encode.number(n.to_str(), e1))).map_err(|e| (e.code, e.path)).map_ok(Encode.canonical) == Err(("duplicate-key", ".a"))

# A native value nested far deeper than any limit: the encoder stops at the
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
	deep.map_err(|e| (e.code, e.reason, e.path.count_utf8_bytes())).map_ok(Encode.canonical) == Err(("nesting-too-deep", "nesting deeper than 256 levels", 256 * "(Link)[0]".count_utf8_bytes()))
}
# At the limit, and one past it: the same as the writer, for every limit.
expect [1, 2, 255, 256].all(|n| encode_chain(chain(n), Encode.top).is_ok()) and encode_chain(chain(257), Encode.top).is_err()
expect [0, 1, 3, 1024].all(
	|d| {
		limits = { ..Value.default_limits, max_depth: d }
		Encode.value_with(chain(d), encode_chain, limits).is_ok() and Encode.value_with(chain(d + 1), encode_chain, limits).map_ok(Encode.canonical) == Encode.to_str_with(nested(d + 1, Tag("End", []), |v| Tag("Link", [v])), limits)
	},
)
# Records as a tag's only argument share its level (`Tag { … }`), as in the writer.
expect {
	tree = |n| nested(n, Rec([]), |v| Rec([("a", v)]))
	wrap = |v, e| Encode.tagged("A", e, |inner| Encode.any(v, inner))
	limits = { ..Value.default_limits, max_depth: 3 }
	[2, 3].all(|n| (wrap(tree(n), Encode.top_with(limits)).map_ok(|_| {})) == (Encode.to_str_with(Tag("A", [tree(n)]), limits).map_ok(|_| {})))
}
expect Encode.value_with([1.I32], |l, e| Encode.list(l, e, |n, e1| Encode.number(n.to_str(), e1)), { ..Value.default_limits, max_depth: 2000 }).map_err(|e| e.code).map_ok(Encode.canonical) == Err("unsupported-depth")

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
	var $v = Arr([])
	var $i = 0
	while $i < levels {
		$v = Arr([$v, $v])
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
expect Encode.value_with([1.I32, 2, 3], |l, e| Encode.list(l, e, |n, e1| Encode.number(n.to_str(), e1)), budget(4)).map_ok(Encode.canonical) == Ok("[1,2,3]")
# Each value of a stream has a budget of its own.
expect Encode.stream_with([shared(3), shared(3)], budget(15)).is_ok() and Encode.stream_with([Num("1"), shared(3)], budget(14)).map_err(|err| (err.code, err.path.starts_with("[1][1]"))) == Err(("step-budget", True))
