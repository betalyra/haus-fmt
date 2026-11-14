## JSON (spec §16): a strict JSON reader and writer, and the two mappings
## between haus and JSON that need no schema.
##
## - Without a schema (§16.1), `JsonValue.from_json` reads any JSON as a `Value`:
##   `null` is `None`, `true` is `True`, numbers keep their text.
## - Lossless (§16.2), `JsonValue.to_lossless_json` and `JsonValue.from_lossless_json`
##   carry every haus value through JSON and back: `{"num": "19.90"}`,
##   `{"tag": "Some", "args": […]}`.
##
## The plain mapping (§16.3) needs the schema type: see `FromJson` and
## `ToJson`, which generated modules (`haus-gen roc --json`) use.
##
## The reader takes RFC 8259 JSON restricted to I-JSON (RFC 7493): UTF-8, no
## duplicate member names, no unpaired surrogates in `\u` escapes; a leading
## byte order mark is ignored. Numbers keep their text.
##
## The limits of spec §7 apply to the haus value that results. A mapping can
## take several JSON levels for one haus level, so JSON may nest 4·256 + 1 =
## 1025 levels, and the resulting value is then checked against 256. Without
## a schema, JSON may nest 256 levels.
##
##     JsonValue.parse("{\"a\": [1, null]}")   # Ok(Object([("a", Array([Number("1"), Null]))]))
##     JsonValue.to_lossless_json(Num("19.90")) # Ok("{\"num\":\"19.90\"}")
import Value
import Decode
import Encode

JsonValue := [
	Null,
	Boolean(Bool),

	## The number as written: `19.90`, `-1E+5`.
	Number(Str),
	String(Str),
	Array(List(JsonValue)),

	## Members in order; their names are unique in what the reader gives.
	Object(List((Str, JsonValue))),
].{

	## Read one JSON text.
	parse : Str -> Try(JsonValue, Value.ParseError)
	parse = |text| parse_with(text, max_json_depth, True)

	## Write JSON on one line, without spaces. A `JsonValue` built in code is checked
	## as it is written: numbers must be JSON numbers within the number limits,
	## strings within the string limit, member names unique and the nesting
	## within what the reader takes. These errors say what, not where (the
	## place could be inside a `Secret`).
	to_str : JsonValue -> Try(Str, Encode.Error)
	to_str = |json| write(json, 0).map_ok(bytes_to_str)

	## The same JSON: the same members in the same order.
	is_eq : JsonValue, JsonValue -> Bool
	is_eq = |a, b| match (a, b) {
		(Null, Null) => True
		(Boolean(x), Boolean(y)) => x == y
		(Number(x), Number(y)) => x == y
		(String(x), String(y)) => x == y
		(Array(xs), Array(ys)) => xs == ys
		(Object(xs), Object(ys)) => xs == ys
		_ => False
	}

	## What a JSON value is, for messages: `a string`, `the number 1.5`.
	## Never the content of a string.
	describe : JsonValue -> Str
	describe = |json| describe_json(json)

	## Whether a text is a tag name: `[A-Z][A-Za-z0-9_]*`.
	is_tag_name : Str -> Bool
	is_tag_name = |name| is_tag(name)

	## A member of an object.
	get : JsonValue, Str -> Try(JsonValue, [NotFound])
	get = |json, name| match json {
		Object(members) => match members.find_first(|(k, _)| k == name) {
			Ok((_, v)) => Ok(v)
			Err(_) => Err(NotFound)
		}
		_ => Err(NotFound)
	}

	# ── without a schema (§16.1) ────────────────────────────

	## Read any JSON as a haus value: an object as a record, an array as an
	## array, a string as a string, a number as a number with its literal
	## normalized (`1E+05` is `1e5`), `true` / `false` as `True` / `False`, and
	## `null` as `None`.
	from_json : Str -> Try(Value, [Syntax(Value.ParseError), Decode(Decode.Error)])
	from_json = |text| {
		json = parse_with(text, max_depth, True).map_err(|e| Syntax(e))?
		to_value(json).map_err(|e| Decode(e))
	}

	## A `JsonValue` as a haus value, as `from_json` reads it. The value nests at
	## most 256 levels.
	to_value : JsonValue -> Try(Value, Decode.Error)
	to_value = |json| plain_value(json, 0)

	# ── lossless (§16.2) ────────────────────────────────────

	## A value in the lossless form, as text. Fails, saying where, for a
	## `Value` built in code that isn't a valid haus value within the limits.
	to_lossless_json : Value -> Try(Str, Encode.Error)
	to_lossless_json = |value| to_str(lossless(value)?)

	## Read the lossless form, and nothing else: a bare number, `true`,
	## `false`, `null` and objects with other members are errors.
	from_lossless_json : Str -> Try(Value, [Syntax(Value.ParseError), Decode(Decode.Error)])
	from_lossless_json = |text| {
		json = parse(text).map_err(|e| Syntax(e))?
		from_lossless(json).map_err(|e| Decode(e))
	}

	## The lossless form of a value: `{"num": "19.90"}`, `{"bytes": "0b34"}`,
	## `{"rec": {…}}`, `{"tag": "Some", "args": […]}`; strings and arrays as
	## themselves. The value is checked as `Encode.to_str` checks it, and
	## numbers are written normalized (`Num("1E5")` as `{"num": "1e5"}`).
	lossless : Value -> Try(JsonValue, Encode.Error)
	lossless = |value| {
		# The writer checks the value; reading what it wrote normalizes it.
		text = Encode.to_str(value)?
		match Value.parse(text) {
			Ok(normalized) => Ok(lossless_of(normalized))
			Err(e) => Err({ reason: e.reason, path: "" })
		}
	}

	## A value from its lossless form.
	from_lossless : JsonValue -> Try(Value, Decode.Error)
	from_lossless = |json| lossless_value(json, 0)

	# ── JSON Lines ──────────────────────────────────────────

	## The JSON texts of JSON Lines: one per line. The last line may end
	## without a line feed, lines may end with CR LF, and a byte order mark is
	## ignored at the start of the stream (not of each line); empty lines are
	## errors. Errors give the line.
	lines : Str -> Try(List(JsonValue), Value.ParseError)
	lines = |text| {
		body = if (text.ends_with("\n")) text.drop_suffix("\n") else text
		if body.is_empty() {
			return Ok([])
		}
		var $out = []
		var $line = 1.U64
		for l in body.split_on("\n") {
			json = parse_with(l, max_json_depth, $line == 1).map_err(|e| { reason: e.reason, line: $line, column: e.column })?
			$out = $out.append(json)
			$line = $line + 1
		}
		Ok($out)
	}

	## JSON Lines: each JSON text on its own line, followed by a line feed.
	## Errors say which value: `[3]`.
	write_lines : List(JsonValue) -> Try(Str, Encode.Error)
	write_lines = |values| {
		var $out = []
		var $i = 0.U64
		for v in values {
			line = write(v, 0).map_err(|{ reason, path }| { reason, path: "[${$i.to_str()}]${path}" })?
			$out = $out.concat(line).append('\n')
			$i = $i + 1
		}
		Ok(bytes_to_str($out))
	}

	## Whether a text is a JSON number: `-?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?`.
	is_number : Str -> Bool
	is_number = |text| number_end(text.to_utf8(), 0) == Ok(text.count_utf8_bytes())

	## A JSON number as a normalized haus literal (spec §2): `1E+05` is `1e5`.
	normalize_number : Str -> Str
	normalize_number = |text| {
		b = text.to_utf8()
		match b.find_first_index(|c| c == 'e' or c == 'E') {
			Err(_) => text
			Ok(i) => {
				exp = b.drop_first(i + 1)
				negative = exp.first() == Ok('-')
				digits = exp.drop_if(|c| c == '+' or c == '-').drop_first(0)
				trimmed = drop_leading_zeros(digits)
				sign = if (negative and trimmed != ['0']) ['-'] else []
				bytes_to_str(b.take_first(i).append('e').concat(sign).concat(trimmed))
			}
		}
	}

	## Base64 with padding (RFC 4648 §4).
	base64 : List(U8) -> Str
	base64 = |bytes| base64_encode(bytes)

	## The bytes of a base64 text with padding, or an error. Strict: padded
	## to a multiple of four, `=` only at the end, unused bits zero.
	from_base64 : Str -> Try(List(U8), [BadBase64])
	from_base64 = |text| base64_decode(text.to_utf8())
}

Fail : { reason : Str, pos : U64 }

# Spec §7 defaults, with JSON nesting 4·d + 1 levels (see the module doc).
max_json_depth : U64
max_json_depth = 4 * 256 + 1

max_depth : U64
max_depth = 256

max_number_length : U64
max_number_length = 1000

max_exponent : U64
max_exponent = 6144

max_string_length : U64
max_string_length = 16 * 1024 * 1024

# ── reading ──────────────────────────────────────────────────

## One JSON text nested at most `max` levels; a byte order mark at the start is skipped if `bom`.
parse_with : Str, U64, Bool -> Try(JsonValue, Value.ParseError)
parse_with = |text, max, bom| {
	src = text.to_utf8()
	start = if (bom and src.starts_with([0xEF, 0xBB, 0xBF])) 3 else 0
	(value, after) = read_value(src, skip_ws(src, start), 0, max).map_err(|f| locate(src, f))?
	end = skip_ws(src, after)
	if end < src.len() {
		Err(locate(src, { reason: "unexpected ${describe(src, end)} after the JSON value", pos: end }))
	} else {
		Ok(value)
	}
}

read_value : List(U8), U64, U64, U64 -> Try((JsonValue, U64), Fail)
read_value = |src, pos, depth, max| {
	c = at(src, pos)
	if c == '{' {
		read_object(src, pos, depth, max)
	} else if c == '[' {
		read_array(src, pos, depth, max)
	} else if c == '"' {
		(s, after) = read_string(src, pos)?
		Ok((String(s), after))
	} else if c == '-' or is_digit(c) {
		read_number(src, pos)
	} else if starts_at(src, pos, "true") {
		Ok((Boolean(True), pos + 4))
	} else if starts_at(src, pos, "false") {
		Ok((Boolean(False), pos + 5))
	} else if starts_at(src, pos, "null") {
		Ok((Null, pos + 4))
	} else {
		Err({ reason: "expected a JSON value, found ${describe(src, pos)}", pos })
	}
}

read_object : List(U8), U64, U64, U64 -> Try((JsonValue, U64), Fail)
read_object = |src, open, depth, max| {
	if depth + 1 > max {
		return Err({ reason: "JSON nested deeper than ${max.to_str()} levels", pos: open })
	}
	var $members = []
	var $seen = Set.empty()
	var $pos = skip_ws(src, open + 1)
	var $done = at(src, $pos) == '}'
	while !$done {
		if at(src, $pos) != '"' {
			return Err({ reason: "expected a member name, found ${describe(src, $pos)}", pos: $pos })
		}
		name_pos = $pos
		(name, after_name) = read_string(src, $pos)?
		if $seen.contains(name) {
			return Err({ reason: "duplicate member name ${quote_str(name)}", pos: name_pos })
		}
		$seen = $seen.insert(name)
		colon = skip_ws(src, after_name)
		if at(src, colon) != ':' {
			return Err({ reason: "expected ':', found ${describe(src, colon)}", pos: colon })
		}
		(value, after_value) = read_value(src, skip_ws(src, colon + 1), depth + 1, max)?
		$members = $members.append((name, value))
		p = skip_ws(src, after_value)
		if at(src, p) == ',' {
			$pos = skip_ws(src, p + 1)
		} else if at(src, p) == '}' {
			$pos = p
			$done = True
		} else {
			return Err({ reason: "expected ',' or '}', found ${describe(src, p)}", pos: p })
		}
	}
	Ok((Object($members), $pos + 1))
}

read_array : List(U8), U64, U64, U64 -> Try((JsonValue, U64), Fail)
read_array = |src, open, depth, max| {
	if depth + 1 > max {
		return Err({ reason: "JSON nested deeper than ${max.to_str()} levels", pos: open })
	}
	var $items = []
	var $pos = skip_ws(src, open + 1)
	var $done = at(src, $pos) == ']'
	while !$done {
		(value, after) = read_value(src, $pos, depth + 1, max)?
		$items = $items.append(value)
		p = skip_ws(src, after)
		if at(src, p) == ',' {
			$pos = skip_ws(src, p + 1)
		} else if at(src, p) == ']' {
			$pos = p
			$done = True
		} else {
			return Err({ reason: "expected ',' or ']', found ${describe(src, p)}", pos: p })
		}
	}
	Ok((Array($items), $pos + 1))
}

## Where a JSON number that starts at `start` ends, or an error.
number_end : List(U8), U64 -> Try(U64, Str)
number_end = |src, start| {
	var $p = if (at(src, start) == '-') start + 1 else start
	if at(src, $p) == '0' {
		$p = $p + 1
	} else if is_digit(at(src, $p)) {
		$p = skip_digits(src, $p)
	} else {
		return Err("invalid number")
	}
	if at(src, $p) == '.' {
		if !is_digit(at(src, $p + 1)) {
			return Err("invalid number: a digit must follow '.'")
		}
		$p = skip_digits(src, $p + 1)
	}
	if at(src, $p) == 'e' or at(src, $p) == 'E' {
		$p = $p + 1
		if at(src, $p) == '+' or at(src, $p) == '-' {
			$p = $p + 1
		}
		if !is_digit(at(src, $p)) {
			return Err("invalid number: a digit must follow the exponent")
		}
		$p = skip_digits(src, $p)
	}
	Ok($p)
}

## A JSON number's text within the number limits, or why not.
check_number : List(U8) -> Try({}, Str)
check_number = |b| {
	if b.len() > max_number_length {
		return Err("number literal longer than ${max_number_length.to_str()} characters")
	}
	match b.find_first_index(|c| c == 'e' or c == 'E') {
		Ok(i) => {
			digits = drop_leading_zeros(b.drop_first(i + 1).drop_if(|c| c == '+' or c == '-'))
			if digits.len() > 4 or (U64.from_str(bytes_to_str(digits)) ?? 0) > max_exponent {
				Err("exponent larger than ${max_exponent.to_str()}")
			} else {
				Ok({})
			}
		}
		Err(_) => Ok({})
	}
}

read_number : List(U8), U64 -> Try((JsonValue, U64), Fail)
read_number = |src, start| {
	end = number_end(src, start).map_err(|reason| { reason, pos: start })?
	text = src.sublist({ start, len: end - start })
	check_number(text).map_err(|reason| { reason, pos: start })?
	Ok((Number(bytes_to_str(text)), end))
}

read_string : List(U8), U64 -> Try((Str, U64), Fail)
read_string = |src, open| {
	var $out = []
	var $pos = open + 1
	var $done = False
	while !$done {
		c = at(src, $pos)
		if $pos >= src.len() {
			return Err({ reason: "unclosed string", pos: open })
		} else if c == '"' {
			$done = True
		} else if c == '\\' {
			(bytes, after) = read_escape(src, $pos)?
			$out = $out.concat(bytes)
			$pos = after
		} else if c < 0x20 {
			return Err({ reason: "raw control character U+00${hex2(c)} in a string (escape it)", pos: $pos })
		} else {
			$out = $out.append(c)
			$pos = $pos + 1
		}
	}
	if $out.len() > max_string_length and code_points($out) > max_string_length {
		return Err({ reason: "string longer than ${max_string_length.to_str()} characters", pos: open })
	}
	Ok((bytes_to_str($out), $pos + 1))
}

## At a backslash: the escaped bytes and the position after the escape.
read_escape : List(U8), U64 -> Try((List(U8), U64), Fail)
read_escape = |src, start| {
	e = at(src, start + 1)
	unpaired = { reason: "unpaired surrogate in a \\u escape", pos: start }
	if e == '"' or e == '\\' or e == '/' {
		Ok(([e], start + 2))
	} else if e == 'b' {
		Ok(([0x08], start + 2))
	} else if e == 'f' {
		Ok(([0x0C], start + 2))
	} else if e == 'n' {
		Ok((['\n'], start + 2))
	} else if e == 'r' {
		Ok((['\r'], start + 2))
	} else if e == 't' {
		Ok((['\t'], start + 2))
	} else if e == 'u' {
		unit = hex4(src, start + 2).map_err(|_| { reason: "\\u takes four hex digits", pos: start })?
		if unit >= 0xD800 and unit <= 0xDBFF {
			low = if (starts_at(src, start + 6, "\\u")) hex4(src, start + 8) ?? 0 else 0
			if low >= 0xDC00 and low <= 0xDFFF {
				Ok((utf8_encode(0x10000 + (unit - 0xD800) * 1024 + (low - 0xDC00)), start + 12))
			} else {
				Err(unpaired)
			}
		} else if unit >= 0xDC00 and unit <= 0xDFFF {
			Err(unpaired)
		} else {
			Ok((utf8_encode(unit), start + 6))
		}
	} else {
		Err({ reason: "invalid escape: use \\\" \\\\ \\/ \\b \\f \\n \\r \\t or \\uXXXX", pos: start })
	}
}

hex4 : List(U8), U64 -> Try(U64, [NotHex])
hex4 = |src, pos| {
	digits = src.sublist({ start: pos, len: 4 })
	if digits.len() == 4 and digits.all(is_hex) {
		var $n = 0.U64
		for d in digits {
			$n = $n * 16 + hex_value(d)
		}
		Ok($n)
	} else {
		Err(NotHex)
	}
}

skip_ws : List(U8), U64 -> U64
skip_ws = |src, start| {
	var $p = start
	while at(src, $p) == ' ' or at(src, $p) == '\t' or at(src, $p) == '\n' or at(src, $p) == '\r' {
		$p = $p + 1
	}
	$p
}

skip_digits : List(U8), U64 -> U64
skip_digits = |src, start| {
	var $p = start
	while is_digit(at(src, $p)) {
		$p = $p + 1
	}
	$p
}

# ── writing ──────────────────────────────────────────────────

write : JsonValue, U64 -> Try(List(U8), Encode.Error)
write = |json, depth| match json {
	Null => Ok("null".to_utf8())
	Boolean(b) => Ok((if (b) "true" else "false").to_utf8())
	Number(n) => {
		b = n.to_utf8()
		if number_end(b, 0) != Ok(b.len()) {
			fail("not a JSON number")
		} else {
			check_number(b).map_err(|reason| { reason, path: "" })?
			Ok(b)
		}
	}
	String(s) => quote(s)
	Array(items) => {
		open(depth)?
		var $out = ['[']
		for x in items {
			item = write(x, depth + 1)?
			$out = if ($out.len() == 1) $out.concat(item) else $out.append(',').concat(item)
		}
		Ok($out.append(']'))
	}
	Object(members) => {
		open(depth)?
		var $seen = Set.empty()
		var $out = ['{']
		for (k, v) in members {
			if $seen.contains(k) {
				return fail("a member name is used twice in an object")
			}
			$seen = $seen.insert(k)
			member = quote(k)?.append(':').concat(write(v, depth + 1)?)
			$out = if ($out.len() == 1) $out.concat(member) else $out.append(',').concat(member)
		}
		Ok($out.append('}'))
	}
}

open : U64 -> Try({}, Encode.Error)
open = |depth| if (depth >= max_json_depth) fail("JSON nested deeper than ${max_json_depth.to_str()} levels") else Ok({})

fail : Str -> Try(a, Encode.Error)
fail = |reason| Err({ reason, path: "" })

## A JSON string: only what JSON requires is escaped.
quote : Str -> Try(List(U8), Encode.Error)
quote = |s| {
	b = s.to_utf8()
	if b.len() > max_string_length and code_points(b) > max_string_length {
		return fail("string longer than ${max_string_length.to_str()} characters")
	}
	var $out = ['"']
	for c in b {
		$out =
			if c == '"' {
				$out.concat(['\\', '"'])
			} else if c == '\\' {
				$out.concat(['\\', '\\'])
			} else if c == '\n' {
				$out.concat(['\\', 'n'])
			} else if c == '\r' {
				$out.concat(['\\', 'r'])
			} else if c == '\t' {
				$out.concat(['\\', 't'])
			} else if c == 0x08 {
				$out.concat(['\\', 'b'])
			} else if c == 0x0C {
				$out.concat(['\\', 'f'])
			} else if c < 0x20 {
				$out.concat(['\\', 'u', '0', '0']).concat(hex2(c).to_utf8())
			} else {
				$out.append(c)
			}
	}
	Ok($out.append('"'))
}

# ── values ───────────────────────────────────────────────────

## JSON read without a schema (§16.1), at `depth` haus levels.
plain_value : JsonValue, U64 -> Try(Value, Decode.Error)
plain_value = |json, depth| match json {
	Null => Ok(Tag("None", []))
	Boolean(True) => Ok(Tag("True", []))
	Boolean(False) => Ok(Tag("False", []))
	Number(n) => Ok(Num(JsonValue.normalize_number(n)))
	String(s) => Ok(Text(s))
	Array(items) => {
		enter(depth)?
		var $out = []
		var $i = 0.U64
		for x in items {
			$out = $out.append(within(plain_value(x, depth + 1), "[${$i.to_str()}]")?)
			$i = $i + 1
		}
		Ok(Arr($out))
	}
	Object(members) => {
		enter(depth)?
		var $out = []
		for (k, x) in members {
			$out = $out.append((k, within(plain_value(x, depth + 1), ".${k}")?))
		}
		Ok(Rec($out))
	}
}

enter : U64 -> Try({}, Decode.Error)
enter = |depth| if (depth >= max_depth) Decode.fail("nesting deeper than ${max_depth.to_str()} levels") else Ok({})

within : Try(a, Decode.Error), Str -> Try(a, Decode.Error)
within = |result, segment| result.map_err(|{ reason, path }| { reason, path: "${segment}${path}" })

## The lossless form of a value the parser gave (so it is valid and normalized).
lossless_of : Value -> JsonValue
lossless_of = |value| match value {
	Num(n) => Object([("num", String(n))])
	Text(s) => String(s)
	Bytes(b) => Object([("bytes", String(hex_lower(b)))])
	Arr(items) => Array(items.map(lossless_of))
	Rec(fields) => Object([("rec", Object(fields.map(|(k, x)| (k, lossless_of(x)))))])
	Tag(name, []) => Object([("tag", String(name))])
	Tag(name, args) => Object([("tag", String(name)), ("args", Array(args.map(lossless_of)))])
}

lossless_forms : Str
lossless_forms = "a lossless value: a string, an array, or an object {\"num\"}, {\"bytes\"}, {\"rec\"} or {\"tag\", \"args\"?}"

## A value from its lossless form, at `depth` haus levels (counted as the haus
## writer counts them: `Tag { … }` is one level).
lossless_value : JsonValue, U64 -> Try(Value, Decode.Error)
lossless_value = |json, depth| match json {
	String(s) => Ok(Text(s))
	Array(items) => {
		enter(depth)?
		Ok(Arr(lossless_items(items, depth + 1)?))
	}
	Object([("num", n)]) => within(lossless_number(n), ".num")
	Object([("bytes", h)]) => within(lossless_bytes(h), ".bytes")
	Object([("rec", r)]) => within(lossless_record(r, depth), ".rec")
	Object([("tag", t)]) => Ok(Tag(lossless_tag(t)?, []))
	Object([("tag", t), ("args", a)]) => lossless_variant(t, a, depth)
	Object([("args", a), ("tag", t)]) => lossless_variant(t, a, depth)
	_ => Decode.fail("expected ${lossless_forms}, found ${describe_json(json)}")
}

lossless_items : List(JsonValue), U64 -> Try(List(Value), Decode.Error)
lossless_items = |items, depth| {
	var $out = []
	var $i = 0.U64
	for x in items {
		$out = $out.append(within(lossless_value(x, depth), "[${$i.to_str()}]")?)
		$i = $i + 1
	}
	Ok($out)
}

## `"19.90"`: a normalized literal (spec §2) that a reader with the default limits takes.
lossless_number : JsonValue -> Try(Value, Decode.Error)
lossless_number = |json| match json {
	String(n) => {
		# Writing it and reading it back gives the same text only if it is normalized.
		same = match Encode.to_str(Num(n)) {
			Ok(written) => match Value.parse(written) {
				Ok(Num(m)) => m == n
				_ => Bool.False
			}
			Err(e) => return Decode.fail(e.reason)
		}
		if (same) Ok(Num(n)) else Decode.fail("${quote_str(n)} is not a normalized number literal")
	}
	_ => Decode.fail("expected a string, found ${describe_json(json)}")
}

## `"0b34ff"`: two lowercase hex digits per byte.
lossless_bytes : JsonValue -> Try(Value, Decode.Error)
lossless_bytes = |json| match json {
	String(text) => {
		b = text.to_utf8()
		is_lower_hex = |c| is_digit(c) or (c >= 'a' and c <= 'f')
		if b.len() % 2 != 0 or !b.all(is_lower_hex) {
			Decode.fail("expected two lowercase hex digits per byte")
		} else {
			var $out = []
			var $i = 0.U64
			while $i < b.len() {
				$out = $out.append((hex_value(at(b, $i)) * 16 + hex_value(at(b, $i + 1))).to_u8_wrap())
				$i = $i + 2
			}
			Ok(Bytes($out))
		}
	}
	_ => Decode.fail("expected a string, found ${describe_json(json)}")
}

lossless_record : JsonValue, U64 -> Try(Value, Decode.Error)
lossless_record = |json, depth| match json {
	Object(members) => {
		enter(depth)?
		var $seen = Set.empty()
		var $out = []
		for (k, x) in members {
			if $seen.contains(k) {
				return Decode.fail("the key ${quote_str(k)} is used twice")
			}
			$seen = $seen.insert(k)
			$out = $out.append((k, within(lossless_value(x, depth + 1), ".${k}")?))
		}
		Ok(Rec($out))
	}
	_ => Decode.fail("expected an object, found ${describe_json(json)}")
}

## `"Circle"`: a tag name.
lossless_tag : JsonValue -> Try(Str, Decode.Error)
lossless_tag = |json| match json {
	String(t) if is_tag(t) => Ok(t)
	String(t) => within(Decode.fail("${quote_str(t)} is not a tag name (A to Z, then letters, digits and _)"), ".tag")
	_ => within(Decode.fail("expected a string, found ${describe_json(json)}"), ".tag")
}

lossless_variant : JsonValue, JsonValue, U64 -> Try(Value, Decode.Error)
lossless_variant = |tag, args, depth| {
	name = lossless_tag(tag)?
	values = match args {
		Array([]) => return within(Decode.fail("a tag without arguments has no \"args\""), ".args")
		# `Tag { … }`: the record is the payload's only level.
		Array([Object([("rec", r)])]) => [within(within(lossless_record(r, depth), ".rec"), ".args[0]")?]
		Array(items) => {
			within(enter(depth), ".args")?
			within(lossless_items(items, depth + 1), ".args")?
		}
		_ => return within(Decode.fail("expected an array, found ${describe_json(args)}"), ".args")
	}
	Ok(Tag(name, values))
}

## What a JSON value is, for messages; never the content of a string.
describe_json : JsonValue -> Str
describe_json = |json| match json {
	Null => "null"
	Boolean(True) => "true"
	Boolean(False) => "false"
	Number(n) => "the number ${n}"
	String(_) => "a string"
	Array(_) => "an array"
	Object(_) => "an object"
}

# ── base64 ───────────────────────────────────────────────────

alphabet : List(U8)
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()

base64_encode : List(U8) -> Str
base64_encode = |bytes| {
	sextet = |n, shift| at(alphabet, (n // shift) % 64)
	var $out = []
	var $i = 0.U64
	while $i < bytes.len() {
		chunk = bytes.sublist({ start: $i, len: 3 })
		n = byte_or_zero(chunk, 0) * 65536 + byte_or_zero(chunk, 1) * 256 + byte_or_zero(chunk, 2)
		$out = $out.append(sextet(n, 262144)).append(sextet(n, 4096))
		$out = $out.append(if (chunk.len() > 1) sextet(n, 64) else '=')
		$out = $out.append(if (chunk.len() > 2) sextet(n, 1) else '=')
		$i = $i + 3
	}
	bytes_to_str($out)
}

base64_decode : List(U8) -> Try(List(U8), [BadBase64])
base64_decode = |text| {
	if text.len() % 4 != 0 {
		return Err(BadBase64)
	}
	var $out = []
	var $i = 0.U64
	while $i < text.len() {
		group = text.sublist({ start: $i, len: 4 })
		padding = if (group.ends_with(['=', '='])) 2 else if (group.ends_with(['='])) 1 else 0
		if padding > 0 and $i + 4 < text.len() {
			return Err(BadBase64)
		}
		var $n = 0.U64
		for c in group.take_first(4 - padding) {
			v = alphabet.find_first_index(|a| a == c).map_err(|_| BadBase64)?
			$n = $n * 64 + v
		}
		$n = if (padding == 2) $n * 4096 else if (padding == 1) $n * 64 else $n
		# The bits the padding leaves unused must be zero.
		if (padding == 1 and $n % 256 != 0) or (padding == 2 and $n % 65536 != 0) {
			return Err(BadBase64)
		}
		decoded = [($n // 65536).to_u8_wrap(), (($n // 256) % 256).to_u8_wrap(), ($n % 256).to_u8_wrap()]
		$out = $out.concat(decoded.take_first(3 - padding))
		$i = $i + 4
	}
	Ok($out)
}

# ── helpers ──────────────────────────────────────────────────

at : List(U8), U64 -> U8
at = |src, pos| match src.get(pos) {
	Ok(b) => b
	Err(_) => 0
}

starts_at : List(U8), U64, Str -> Bool
starts_at = |src, pos, prefix| {
	bytes = prefix.to_utf8()
	src.sublist({ start: pos, len: bytes.len() }) == bytes
}

is_digit = |b| b >= '0' and b <= '9'

is_hex = |b| is_digit(b) or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F')

hex_value : U8 -> U64
hex_value = |b|
	if b >= 'a' {
		(b - 'a').to_u64() + 10
	} else if b >= 'A' {
		(b - 'A').to_u64() + 10
	} else {
		(b - '0').to_u64()
	}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

## Two lowercase hex digits.
hex2 : U8 -> Str
hex2 = |b| bytes_to_str([hex_digit(b // 16), hex_digit(b % 16)])

hex_lower : List(U8) -> Str
hex_lower = |bytes| {
	var $out = []
	for b in bytes {
		$out = $out.append(hex_digit(b // 16)).append(hex_digit(b % 16))
	}
	bytes_to_str($out)
}

byte_or_zero : List(U8), U64 -> U64
byte_or_zero = |bytes, i| at(bytes, i).to_u64()

## A tag name: `[A-Z][A-Za-z0-9_]*`.
is_tag : Str -> Bool
is_tag = |name| {
	b = name.to_utf8()
	first = at(b, 0)
	first >= 'A' and first <= 'Z' and b.all(|c| (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or is_digit(c) or c == '_')
}

drop_leading_zeros : List(U8) -> List(U8)
drop_leading_zeros = |digits| match digits.find_first_index(|c| c != '0') {
	Ok(i) => digits.drop_first(i)
	Err(_) => ['0']
}

## Code points in UTF-8 bytes: every byte that isn't a continuation byte.
code_points : List(U8) -> U64
code_points = |bytes| bytes.count_if(|b| b < 0x80 or b >= 0xC0)

utf8_encode : U64 -> List(U8)
utf8_encode = |cp|
	if cp < 0x80 {
		[cp.to_u8_wrap()]
	} else if cp < 0x800 {
		[(0xC0 + cp // 64).to_u8_wrap(), (0x80 + cp % 64).to_u8_wrap()]
	} else if cp < 0x10000 {
		[(0xE0 + cp // 4096).to_u8_wrap(), (0x80 + (cp // 64) % 64).to_u8_wrap(), (0x80 + cp % 64).to_u8_wrap()]
	} else {
		[
			(0xF0 + cp // 262144).to_u8_wrap(),
			(0x80 + (cp // 4096) % 64).to_u8_wrap(),
			(0x80 + (cp // 64) % 64).to_u8_wrap(),
			(0x80 + cp % 64).to_u8_wrap(),
		]
	}

bytes_to_str : List(U8) -> Str
bytes_to_str = |bytes| match Str.from_utf8(bytes) {
	Ok(s) => s
	Err(_) => "" # unreachable: input is valid UTF-8 and escapes are encoded correctly
}

## A string in quotes, for messages.
quote_str : Str -> Str
quote_str = |s| match quote(s) {
	Ok(b) => bytes_to_str(b)
	Err(_) => "\"…\""
}

## What is at `pos`, for messages: a whole character.
describe : List(U8), U64 -> Str
describe = |src, pos| {
	c = at(src, pos)
	if pos >= src.len() {
		"end of input"
	} else if c == '\n' {
		"line break"
	} else {
		len = if (c < 0x80) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else 4
		"'${bytes_to_str(src.sublist({ start: pos, len }))}'"
	}
}

## Line and column (1-based, in code points) of a byte position.
locate : List(U8), Fail -> Value.ParseError
locate = |src, { reason, pos }| {
	var $line = 1
	var $column = 1
	for b in src.sublist({ start: 0, len: pos }) {
		if b == '\n' {
			$line = $line + 1
			$column = 1
		} else if b < 0x80 or b >= 0xC0 {
			$column = $column + 1
		}
	}
	{ reason, line: $line, column: $column }
}

# ── tests ────────────────────────────────────────────────────

expect JsonValue.parse(" {\"a\": [1, -0.5e+3, true, false, null]}\r\n") == Ok(Object([("a", Array([Number("1"), Number("-0.5e+3"), Boolean(True), Boolean(False), Null]))]))
expect JsonValue.parse("\"\\u00e9\\ud83d\\ude00\\n\\/\"") == Ok(String("é😀\n/"))
expect JsonValue.parse("\"\u(10FFFF)\u(7F)\"") == Ok(String("\u(10FFFF)\u(7F)"))
expect JsonValue.parse("{\"a\": 1, \"a\": 2}") == Err({ reason: "duplicate member name \"a\"", line: 1, column: 10 })
expect JsonValue.parse("\"\\ud83d\"").map_err(|e| e.reason) == Err("unpaired surrogate in a \\u escape")
expect JsonValue.parse("\"\\ude00\\ud83d\"").map_err(|e| e.reason) == Err("unpaired surrogate in a \\u escape")
expect JsonValue.parse("\"a\u(1)\"").map_err(|e| e.reason) == Err("raw control character U+0001 in a string (escape it)")
expect JsonValue.parse("[1,]") == Err({ reason: "expected a JSON value, found ']'", line: 1, column: 4 })
expect JsonValue.parse("{\"a\":1,}").map_err(|e| e.reason) == Err("expected a member name, found '}'")
expect JsonValue.parse("01").map_err(|e| e.reason) == Err("unexpected '1' after the JSON value")
expect JsonValue.parse("1.").map_err(|e| e.reason) == Err("invalid number: a digit must follow '.'")
expect JsonValue.parse("NaN").map_err(|e| e.reason) == Err("expected a JSON value, found 'N'")
expect JsonValue.parse("\u(FEFF)1") == Ok(Number("1"))
expect JsonValue.parse("1\u(FEFF)").map_err(|e| e.reason) == Err("unexpected '\u(FEFF)' after the JSON value")
expect JsonValue.parse("").map_err(|e| e.reason) == Err("expected a JSON value, found end of input")
expect JsonValue.parse("[1").map_err(|e| e.reason) == Err("expected ',' or ']', found end of input")
expect JsonValue.parse("1e6145").map_err(|e| e.reason) == Err("exponent larger than 6144")
expect JsonValue.parse("1e6144").is_ok() and JsonValue.parse("1e-0006144").is_ok()
expect JsonValue.parse(Str.repeat("1", 1001)).map_err(|e| e.reason) == Err("number literal longer than 1000 characters")
expect JsonValue.parse("${Str.repeat("[", 1025)}${Str.repeat("]", 1025)}").is_ok()
expect JsonValue.parse("${Str.repeat("[", 1026)}${Str.repeat("]", 1026)}").map_err(|e| e.reason) == Err("JSON nested deeper than 1025 levels")

expect JsonValue.to_str(String("\"\\\n\r\t\u(8)\u(C)\u(1)\u(7F)é")) == Ok("\"\\\"\\\\\\n\\r\\t\\b\\f\\u0001\u(7F)é\"")
expect JsonValue.to_str(Object([("a", Array([Number("1.5"), Null, Boolean(True)]))])) == Ok("{\"a\":[1.5,null,true]}")
expect JsonValue.to_str(Number("01")) == Err({ reason: "not a JSON number", path: "" })
expect JsonValue.to_str(Object([("a", Null), ("a", Null)])) == Err({ reason: "a member name is used twice in an object", path: "" })

expect JsonValue.from_json("{\"a\": 1E+05, \"b\": [true, null], \"c\": \"x\"}").map_ok(Encode.canonical) == Ok("{a:1e5,b:[True,None],c:\"x\"}")
expect JsonValue.from_json("${Str.repeat("[", 256)}${Str.repeat("]", 256)}").is_ok()
expect JsonValue.from_json("${Str.repeat("[", 257)}${Str.repeat("]", 257)}").is_err()
expect JsonValue.from_json("\u(FEFF)[1]").map_ok(Encode.canonical) == Ok("[1]")

expect JsonValue.to_lossless_json(Tag("Point", [Num("1"), Num("2.50")])) == Ok("{\"tag\":\"Point\",\"args\":[{\"num\":\"1\"},{\"num\":\"2.50\"}]}")
expect JsonValue.to_lossless_json(Num("1E5")) == Ok("{\"num\":\"1e5\"}")
expect JsonValue.to_lossless_json(Arr([Num("1"), Num("abc")])) == Err({ reason: "not a number literal", path: "[1]" })
expect JsonValue.from_lossless_json("{\"num\": \"1E5\"}").is_err()
expect JsonValue.from_lossless_json("{\"tag\": \"T\", \"args\": []}").is_err()
expect JsonValue.from_lossless_json("{\"args\": [{\"num\": \"1\"}], \"tag\": \"T\"}").map_ok(Encode.canonical) == Ok("T(1)")

expect JsonValue.base64([0x0B, 0x34]) == "CzQ="
expect JsonValue.base64([]) == ""
expect JsonValue.base64("foo".to_utf8()) == "Zm9v"
expect JsonValue.from_base64("Zg==") == Ok("f".to_utf8())
expect JsonValue.from_base64("CzQ=") == Ok([0x0B, 0x34])
expect JsonValue.from_base64("CzQ").is_err() and JsonValue.from_base64("CzR=").is_err() and JsonValue.from_base64("Zg==Zg==").is_err() and JsonValue.from_base64("-_8=").is_err()

expect JsonValue.normalize_number("1E+05") == "1e5"
expect JsonValue.normalize_number("-0.5e-0") == "-0.5e0"
expect JsonValue.normalize_number("19.90") == "19.90"
expect JsonValue.lines("1\n[2]\n") == Ok([Number("1"), Array([Number("2")])])
expect JsonValue.lines("1\n{oops}\n").map_err(|e| (e.line, e.column)) == Err((2, 2))
expect JsonValue.lines("\u(FEFF)1\r\n2") == Ok([Number("1"), Number("2")])
expect JsonValue.lines("1\n\u(FEFF)2").map_err(|e| e.line) == Err(2)
expect JsonValue.lines("1\n\n2").map_err(|e| e.line) == Err(2)
