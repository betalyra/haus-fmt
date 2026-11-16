## JSON (spec §16): a strict JSON reader and writer, and the two forms that
## need no schema.
##
## - JSON import (§16.1), `JsonValue.import_json`, reads any JSON as a `Value`:
##   `null` is `None`, `true` is `True`, numbers keep their text.
## - Self-describing JSON (§16.2), `JsonValue.to_haus_json` and
##   `JsonValue.from_haus_json`, carries every haus value through JSON and
##   back, in an envelope: `{"_haus": 1, "_value": {"_num": "19.90"}}`.
##
## Schema-based JSON (§16.3) needs the schema type: see `FromJson` and
## `ToJson`, which generated modules (`haus-gen roc --json`) use.
##
## The reader takes RFC 8259 JSON restricted to I-JSON (RFC 7493): UTF-8, no
## duplicate member names, no unpaired surrogates in `\u` escapes; a leading
## byte order mark is ignored. Numbers keep their text. The writer escapes
## control characters (C0, DEL, C1) and the bidi controls, so that what it
## writes can't display differently from what it holds; the self-describing
## reader rejects them raw, the others accept them.
##
## The limits of spec §7 apply to the haus value that results. A form can
## take several JSON levels for one haus level, so schema-based JSON may nest
## 4·256 + 1 = 1025 levels, self-describing JSON one more for the envelope,
## and the resulting value is then checked against 256. The import's JSON may
## nest 256 levels. The `_with` functions take other limits (`Value.Limits`);
## a depth limit d then allows 4·d + 1 JSON levels (4·d + 2 self-describing).
## They fail if d is more than `Value.max_supported_depth`.
##
##     JsonValue.parse("{\"a\": [1, null]}")  # Ok(Object([("a", Array([Number("1"), Null]))]))
##     JsonValue.to_haus_json(Num("19.90"))  # Ok("{\"_haus\":1,\"_value\":{\"_num\":\"19.90\"}}")
##
## Errors have codes (spec §17, `ErrorCode`): `json-syntax` for text that
## isn't JSON, `duplicate-key`, `unpaired-surrogate`, the codes of the limits,
## and for self-describing JSON `haus-json-form`, `haus-json-version`,
## `haus-json-number`, `haus-json-bytes`, `invalid-tag`, `control-character`
## and `bidi-control`.
import ErrorCode
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
	parse = |text| parse_with(text, Value.default_limits)

	## `parse` with your own limits (see `Value.Limits`): numbers and strings
	## within them, and the JSON nested at most 4·d + 1 levels for a depth
	## limit d.
	parse_with : Str, Value.Limits -> Try(JsonValue, Value.ParseError)
	parse_with = |text, limits| read_json(text, limits, json_depth(limits), { bom: True, strict: False })

	## Write JSON on one line, without spaces. A `JsonValue` built in code is checked
	## as it is written: numbers must be JSON numbers within the number limits,
	## strings within the string limit, member names unique and the nesting
	## within what the reader takes. These errors say what, not where (the
	## place could be inside a `Secret`).
	to_str : JsonValue -> Try(Str, Encode.Error)
	to_str = |json| to_str_with(json, Value.default_limits)

	## `to_str` for a reader with other limits (see `parse_with`): numbers and
	## strings within them, and the JSON nested at most 4·d + 1 levels for a
	## depth limit d.
	to_str_with : JsonValue, Value.Limits -> Try(Str, Encode.Error)
	to_str_with = |json, limits| {
		supported(limits)?
		write(json, 0, json_depth(limits), limits).map_ok(bytes_to_str)
	}

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

	# ── JSON import (§16.1) ─────────────────────────────────

	## Read any JSON as a haus value: an object as a record, an array as an
	## array, a string as a string, a number as a number with its literal
	## normalized (`1E+05` is `1e5`), `true` / `false` as `True` / `False`, and
	## `null` as `None`. Nothing in the data is special: `{"_tag": "Circle"}`
	## and `{"_haus": 1, "_value": 2}` are records.
	import_json : Str -> Try(Value, [Syntax(Value.ParseError), Decode(Decode.Error)])
	import_json = |text| import_json_with(text, Value.default_limits)

	## `import_json` with your own limits: the JSON nests at most d levels.
	import_json_with : Str, Value.Limits -> Try(Value, [Syntax(Value.ParseError), Decode(Decode.Error)])
	import_json_with = |text, limits| {
		json = read_json(text, limits, limits.max_depth, { bom: True, strict: False }).map_err(|e| Syntax(e))?
		imported(json, 0, limits).map_err(|e| Decode(e))
	}

	## A `JsonValue` as a haus value, as `import_json` reads it. The value nests at
	## most 256 levels.
	import_value : JsonValue -> Try(Value, Decode.Error)
	import_value = |json| imported(json, 0, Value.default_limits)

	# ── self-describing JSON (§16.2) ────────────────────────

	## A value as self-describing JSON text, in its envelope:
	## `{"_haus":1,"_value":{"_num":"19.90"}}`. Fails, saying where, for a
	## `Value` built in code that isn't a valid haus value within the limits.
	to_haus_json : Value -> Try(Str, Encode.Error)
	to_haus_json = |value| to_haus_json_with(value, Value.default_limits)

	## `to_haus_json` for a reader with other limits.
	to_haus_json_with : Value, Value.Limits -> Try(Str, Encode.Error)
	to_haus_json_with = |value, limits| {
		envelope = Object([("_haus", Number("1")), ("_value", haus_json_value_with(value, limits)?)])
		write(envelope, 0, haus_json_depth(limits), limits).map_ok(bytes_to_str)
	}

	## Read self-describing JSON, and nothing else: a text without the
	## envelope (`haus-json-form`), an envelope of another version
	## (`haus-json-version`), a bare number, `true`, `false`, `null`, objects
	## with other members, and raw DEL, C1 and bidi controls are errors.
	from_haus_json : Str -> Try(Value, [Syntax(Value.ParseError), Decode(Decode.Error)])
	from_haus_json = |text| from_haus_json_with(text, Value.default_limits)

	## `from_haus_json` with your own limits, for the JSON and the value.
	from_haus_json_with : Str, Value.Limits -> Try(Value, [Syntax(Value.ParseError), Decode(Decode.Error)])
	from_haus_json_with = |text, limits| {
		json = read_json(text, limits, haus_json_depth(limits), { bom: True, strict: True }).map_err(|e| Syntax(e))?
		unwrap(json, limits).map_err(|e| Decode(e))
	}

	## Values as self-describing JSON Lines: each in its own envelope, on its
	## own line, followed by a line feed. Errors say which value: `[3]`.
	to_haus_json_lines : List(Value) -> Try(Str, Encode.Error)
	to_haus_json_lines = |values| to_haus_json_lines_with(values, Value.default_limits)

	## `to_haus_json_lines` for a reader with other limits.
	to_haus_json_lines_with : List(Value), Value.Limits -> Try(Str, Encode.Error)
	to_haus_json_lines_with = |values, limits| {
		supported(limits)?
		var $out = []
		var $i = 0.U64
		for v in values {
			line = to_haus_json_with(v, limits).map_err(|e| { ..e, path: "[${$i.to_str()}]${e.path}" })?
			$out = $out.concat(line.to_utf8()).append('\n')
			$i = $i + 1
		}
		Ok(bytes_to_str($out))
	}

	## Read self-describing JSON Lines (see `lines`): every line an envelope.
	## Syntax errors give the line, the others say which value: `[3]._rec.a`.
	from_haus_json_lines : Str -> Try(List(Value), [Syntax(Value.ParseError), Decode(Decode.Error)])
	from_haus_json_lines = |text| from_haus_json_lines_with(text, Value.default_limits)

	## `from_haus_json_lines` with your own limits, for each line.
	from_haus_json_lines_with : Str, Value.Limits -> Try(List(Value), [Syntax(Value.ParseError), Decode(Decode.Error)])
	from_haus_json_lines_with = |text, limits| {
		jsons = read_lines(text, limits, haus_json_depth(limits), True).map_err(|e| Syntax(e))?
		var $out = []
		var $i = 0.U64
		for j in jsons {
			$out = $out.append(unwrap(j, limits).map_err(|e| Decode({ ..e, path: "[${$i.to_str()}]${e.path}" }))?)
			$i = $i + 1
		}
		Ok($out)
	}

	## The self-describing form of a value without the envelope, as inside
	## schema-based JSON (`Any`, an unknown value's `_args`):
	## `{"_num": "19.90"}`, `{"_bytes": "0b34"}`, `{"_rec": {…}}`,
	## `{"_tag": "Some", "_args": […]}`; strings and arrays as themselves.
	## The value is checked as `Encode.to_str` checks it, and numbers are
	## written normalized (`Num("1E5")` as `{"_num": "1e5"}`).
	haus_json_value : Value -> Try(JsonValue, Encode.Error)
	haus_json_value = |value| haus_json_value_with(value, Value.default_limits)

	## `haus_json_value` for a reader with other limits.
	haus_json_value_with : Value, Value.Limits -> Try(JsonValue, Encode.Error)
	haus_json_value_with = |value, limits| {
		# The writer checks the value; reading what it wrote normalizes it.
		text = Encode.to_str_with(value, limits)?
		match Value.parse_with(text, limits) {
			Ok(normalized) => Ok(self_describing(normalized))
			Err(e) => Err({ code: e.code, reason: e.reason, path: "" })
		}
	}

	## A value from its self-describing form without the envelope, as inside
	## schema-based JSON. (The JSON is already read, so raw controls in its
	## strings aren't checked: schema-based JSON accepts them.)
	from_haus_json_value : JsonValue -> Try(Value, Decode.Error)
	from_haus_json_value = |json| described(json, 0, Value.default_limits)

	# ── JSON Lines ──────────────────────────────────────────

	## The JSON texts of JSON Lines: one per line. The last line may end
	## without a line feed, lines may end with CR LF, and a byte order mark is
	## ignored at the start of the stream (not of each line); empty lines are
	## errors. Errors give the line.
	lines : Str -> Try(List(JsonValue), Value.ParseError)
	lines = |text| lines_with(text, Value.default_limits)

	## `lines` with your own limits (see `parse_with`), for each line.
	lines_with : Str, Value.Limits -> Try(List(JsonValue), Value.ParseError)
	lines_with = |text, limits| read_lines(text, limits, json_depth(limits), False)

	## JSON Lines: each JSON text on its own line, followed by a line feed.
	## Errors say which value: `[3]`.
	write_lines : List(JsonValue) -> Try(Str, Encode.Error)
	write_lines = |values| write_lines_with(values, Value.default_limits)

	## `write_lines` for a reader with other limits (see `to_str_with`).
	write_lines_with : List(JsonValue), Value.Limits -> Try(Str, Encode.Error)
	write_lines_with = |values, limits| {
		supported(limits)?
		var $out = []
		var $i = 0.U64
		for v in values {
			line = write(v, 0, json_depth(limits), limits).map_err(|e| { ..e, path: "[${$i.to_str()}]${e.path}" })?
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

Fail : { code : Str, reason : Str, pos : U64 }

## Text that isn't JSON.
syntax : Str, U64 -> Fail
syntax = |reason, pos| { code: ErrorCode.json_syntax, reason, pos }

## How deep JSON may nest for haus values within `limits`: 4·d + 1 levels (see the module doc).
json_depth : Value.Limits -> U64
json_depth = |limits| 4 * limits.max_depth + 1

## Self-describing JSON: one level more, for the envelope.
haus_json_depth : Value.Limits -> U64
haus_json_depth = |limits| json_depth(limits) + 1

## How a JSON text is read: whether a byte order mark at the start is
## skipped (`bom`), and whether raw DEL, C1 and bidi controls in strings are
## errors (`strict`, for self-describing JSON).
Reading : { bom : Bool, strict : Bool }

# ── reading ──────────────────────────────────────────────────

## One JSON text within `limits`, nested at most `max` levels.
read_json : Str, Value.Limits, U64, Reading -> Try(JsonValue, Value.ParseError)
read_json = |text, limits, max, { bom, strict }| {
	Value.check_limits(limits).map_err(|reason| { code: ErrorCode.unsupported_depth, reason, line: 1, column: 1 })?
	src = text.to_utf8()
	start = if (bom and src.starts_with([0xEF, 0xBB, 0xBF])) 3 else 0
	(value, after) = read_value(src, skip_ws(src, start), 0, { max, limits, strict }).map_err(|f| locate(src, f))?
	end = skip_ws(src, after)
	if end < src.len() {
		Err(locate(src, syntax("unexpected ${describe(src, end)} after the JSON value", end)))
	} else {
		Ok(value)
	}
}

## The JSON texts of JSON Lines, each nested at most `max` levels.
read_lines : Str, Value.Limits, U64, Bool -> Try(List(JsonValue), Value.ParseError)
read_lines = |text, limits, max, strict| {
	body = if (text.ends_with("\n")) text.drop_suffix("\n") else text
	if body.is_empty() {
		return Ok([])
	}
	var $out = []
	var $line = 1.U64
	for l in body.split_on("\n") {
		json = read_json(l, limits, max, { bom: $line == 1, strict }).map_err(|e| { ..e, line: $line })?
		$out = $out.append(json)
		$line = $line + 1
	}
	Ok($out)
}

## What the reader of one text needs: the deepest JSON nesting, the limits,
## and whether raw DEL, C1 and bidi controls are errors.
Reader : { max : U64, limits : Value.Limits, strict : Bool }

read_value : List(U8), U64, U64, Reader -> Try((JsonValue, U64), Fail)
read_value = |src, pos, depth, r| {
	c = at(src, pos)
	if c == '{' {
		read_object(src, pos, depth, r)
	} else if c == '[' {
		read_array(src, pos, depth, r)
	} else if c == '"' {
		(s, after) = read_string(src, pos, r)?
		Ok((String(s), after))
	} else if c == '-' or is_digit(c) {
		read_number(src, pos, r.limits)
	} else if starts_at(src, pos, "true") {
		Ok((Boolean(True), pos + 4))
	} else if starts_at(src, pos, "false") {
		Ok((Boolean(False), pos + 5))
	} else if starts_at(src, pos, "null") {
		Ok((Null, pos + 4))
	} else {
		Err(syntax("expected a JSON value, found ${describe(src, pos)}", pos))
	}
}

read_object : List(U8), U64, U64, Reader -> Try((JsonValue, U64), Fail)
read_object = |src, open, depth, r| {
	if depth + 1 > r.max {
		return Err(json_too_deep(r.max, open))
	}
	var $members = []
	var $seen = Set.empty()
	var $pos = skip_ws(src, open + 1)
	var $done = at(src, $pos) == '}'
	while !$done {
		if at(src, $pos) != '"' {
			return Err(syntax("expected a member name, found ${describe(src, $pos)}", $pos))
		}
		name_pos = $pos
		(name, after_name) = read_string(src, $pos, r)?
		if $seen.contains(name) {
			return Err({ code: ErrorCode.duplicate_key, reason: "duplicate member name ${quote_str(name)}", pos: name_pos })
		}
		$seen = $seen.insert(name)
		colon = skip_ws(src, after_name)
		if at(src, colon) != ':' {
			return Err(syntax("expected ':', found ${describe(src, colon)}", colon))
		}
		(value, after_value) = read_value(src, skip_ws(src, colon + 1), depth + 1, r)?
		$members = $members.append((name, value))
		p = skip_ws(src, after_value)
		if at(src, p) == ',' {
			$pos = skip_ws(src, p + 1)
		} else if at(src, p) == '}' {
			$pos = p
			$done = True
		} else {
			return Err(syntax("expected ',' or '}', found ${describe(src, p)}", p))
		}
	}
	Ok((Object($members), $pos + 1))
}

read_array : List(U8), U64, U64, Reader -> Try((JsonValue, U64), Fail)
read_array = |src, open, depth, r| {
	if depth + 1 > r.max {
		return Err(json_too_deep(r.max, open))
	}
	var $items = []
	var $pos = skip_ws(src, open + 1)
	var $done = at(src, $pos) == ']'
	while !$done {
		(value, after) = read_value(src, $pos, depth + 1, r)?
		$items = $items.append(value)
		p = skip_ws(src, after)
		if at(src, p) == ',' {
			$pos = skip_ws(src, p + 1)
		} else if at(src, p) == ']' {
			$pos = p
			$done = True
		} else {
			return Err(syntax("expected ',' or ']', found ${describe(src, p)}", p))
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

## JSON nested deeper than the limit.
json_too_deep : U64, U64 -> Fail
json_too_deep = |max, open| { code: ErrorCode.nesting_too_deep, reason: "JSON nested deeper than ${max.to_str()} levels", pos: open }

## A JSON number's text within the number limits, or why not.
check_number : List(U8), Value.Limits -> Try({}, { code : Str, reason : Str })
check_number = |b, limits| {
	if b.len() > limits.max_number_length {
		return Err({ code: ErrorCode.number_too_long, reason: "number literal longer than ${limits.max_number_length.to_str()} characters" })
	}
	match b.find_first_index(|c| c == 'e' or c == 'E') {
		Ok(i) => {
			digits = drop_leading_zeros(b.drop_first(i + 1).drop_if(|c| c == '+' or c == '-'))
			if digits.len() > 18 or (U64.from_str(bytes_to_str(digits)) ?? 0) > limits.max_exponent {
				Err({ code: ErrorCode.exponent_too_large, reason: "exponent larger than ${limits.max_exponent.to_str()}" })
			} else {
				Ok({})
			}
		}
		Err(_) => Ok({})
	}
}

read_number : List(U8), U64, Value.Limits -> Try((JsonValue, U64), Fail)
read_number = |src, start, limits| {
	end = number_end(src, start).map_err(|reason| syntax(reason, start))?
	text = src.sublist({ start, len: end - start })
	check_number(text, limits).map_err(|{ code, reason }| { code, reason, pos: start })?
	Ok((Number(bytes_to_str(text)), end))
}

read_string : List(U8), U64, Reader -> Try((Str, U64), Fail)
read_string = |src, open, r| {
	limits = r.limits
	var $out = []
	var $pos = open + 1
	var $done = False
	while !$done {
		c = at(src, $pos)
		if $pos >= src.len() {
			return Err({ code: ErrorCode.unterminated_string, reason: "unclosed string", pos: open })
		} else if c == '"' {
			$done = True
		} else if c == '\\' {
			(bytes, after) = read_escape(src, $pos)?
			$out = $out.concat(bytes)
			$pos = after
		} else if c < 0x20 {
			return Err({ code: ErrorCode.control_character, reason: "raw control character U+00${hex2(c)} in a string (escape it)", pos: $pos })
		} else if r.strict and escaped(src, $pos) != 0 {
			cp = escaped(src, $pos)
			code = if (cp < 0x100) ErrorCode.control_character else ErrorCode.bidi_control
			what = if (cp < 0x100) "control character" else "bidi control"
			return Err({ code, reason: "raw ${what} U+${hex4_of(cp)} in self-describing JSON (escape it)", pos: $pos })
		} else {
			$out = $out.append(c)
			$pos = $pos + 1
		}
	}
	if $out.len() > limits.max_string_length and code_points($out) > limits.max_string_length {
		return Err({ code: ErrorCode.string_too_long, reason: "string longer than ${limits.max_string_length.to_str()} characters", pos: open })
	}
	Ok((bytes_to_str($out), $pos + 1))
}

## At a backslash: the escaped bytes and the position after the escape.
read_escape : List(U8), U64 -> Try((List(U8), U64), Fail)
read_escape = |src, start| {
	e = at(src, start + 1)
	unpaired = { code: ErrorCode.unpaired_surrogate, reason: "unpaired surrogate in a \\u escape", pos: start }
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
		bad_hex = |at_digits| { code: ErrorCode.invalid_unicode_escape, reason: "\\u takes four hex digits", pos: at_digits }
		unit = hex4(src, start + 2).map_err(|_| bad_hex(start + 2))?
		if unit >= 0xD800 and unit <= 0xDBFF {
			low = if (starts_at(src, start + 6, "\\u")) hex4(src, start + 8).map_err(|_| bad_hex(start + 8))? else 0
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
		Err({ code: ErrorCode.invalid_escape, reason: "invalid escape: use \\\" \\\\ \\/ \\b \\f \\n \\r \\t or \\uXXXX", pos: start })
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

## Whether this binding supports `limits` (spec §7).
supported : Value.Limits -> Try({}, Encode.Error)
supported = |limits| Value.check_limits(limits).map_err(|reason| { code: ErrorCode.unsupported_depth, reason, path: "" })

## `json` at `depth`, nested at most `max` levels.
write : JsonValue, U64, U64, Value.Limits -> Try(List(U8), Encode.Error)
write = |json, depth, max, limits| match json {
	Null => Ok("null".to_utf8())
	Boolean(b) => Ok((if (b) "true" else "false").to_utf8())
	Number(n) => {
		b = n.to_utf8()
		if number_end(b, 0) != Ok(b.len()) {
			fail(ErrorCode.cannot_encode, "not a JSON number")
		} else {
			check_number(b, limits).map_err(|{ code, reason }| { code, reason, path: "" })?
			Ok(b)
		}
	}
	String(s) => quote(s, limits)
	Array(items) => {
		open(depth, max)?
		var $out = ['[']
		for x in items {
			item = write(x, depth + 1, max, limits)?
			$out = if ($out.len() == 1) $out.concat(item) else $out.append(',').concat(item)
		}
		Ok($out.append(']'))
	}
	Object(members) => {
		open(depth, max)?
		var $seen = Set.empty()
		var $out = ['{']
		for (k, v) in members {
			if $seen.contains(k) {
				return fail(ErrorCode.duplicate_key, "a member name is used twice in an object")
			}
			$seen = $seen.insert(k)
			member = quote(k, limits)?.append(':').concat(write(v, depth + 1, max, limits)?)
			$out = if ($out.len() == 1) $out.concat(member) else $out.append(',').concat(member)
		}
		Ok($out.append('}'))
	}
}

open : U64, U64 -> Try({}, Encode.Error)
open = |depth, max| {
	if (depth >= max) fail(ErrorCode.nesting_too_deep, "JSON nested deeper than ${max.to_str()} levels") else Ok({})
}

fail : Str, Str -> Try(a, Encode.Error)
fail = |code, reason| Err({ code, reason, path: "" })

## A JSON string. Escaped: what JSON requires, and DEL, C1 and the bidi
## controls (spec §16, "JSON that is written").
quote : Str, Value.Limits -> Try(List(U8), Encode.Error)
quote = |s, limits| {
	b = s.to_utf8()
	max = limits.max_string_length
	if b.len() > max and code_points(b) > max {
		return fail(ErrorCode.string_too_long, "string longer than ${max.to_str()} characters")
	}
	var $out = ['"']
	var $i = 0.U64
	while $i < b.len() {
		c = at(b, $i)
		cp = escaped(b, $i)
		$out =
			if cp != 0 {
				$out.concat(['\\', 'u']).concat(hex4_of(cp).to_utf8())
			} else if c == '"' {
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
		$i = if (cp > 0xFF) $i + 3 else if (cp > 0x7F) $i + 2 else $i + 1
	}
	Ok($out.append('"'))
}

## The code point of the DEL, C1 or bidi control that starts at `pos` in
## UTF-8, or 0 if there is none there: what is escaped beyond what JSON requires.
escaped : List(U8), U64 -> U64
escaped = |b, pos| {
	c = at(b, pos)
	next = at(b, pos + 1)
	if c == 0x7F {
		0x7F
	} else if c == 0xC2 and next >= 0x80 and next <= 0x9F {
		next.to_u64()
	} else if c == 0xE2 and next == 0x80 and at(b, pos + 2) >= 0xAA and at(b, pos + 2) <= 0xAE {
		0x2000 + at(b, pos + 2).to_u64() - 0x80
	} else if c == 0xE2 and next == 0x81 and at(b, pos + 2) >= 0xA6 and at(b, pos + 2) <= 0xA9 {
		0x2040 + at(b, pos + 2).to_u64() - 0x80
	} else {
		0
	}
}

# ── values ───────────────────────────────────────────────────

## JSON imported (§16.1), at `depth` haus levels.
imported : JsonValue, U64, Value.Limits -> Try(Value, Decode.Error)
imported = |json, depth, limits| match json {
	Null => Ok(Tag("None", []))
	Boolean(True) => Ok(Tag("True", []))
	Boolean(False) => Ok(Tag("False", []))
	Number(n) => Ok(Num(JsonValue.normalize_number(n)))
	String(s) => Ok(Text(s))
	Array(items) => {
		enter(depth, limits)?
		var $out = []
		var $i = 0.U64
		for x in items {
			$out = $out.append(within(imported(x, depth + 1, limits), "[${$i.to_str()}]")?)
			$i = $i + 1
		}
		Ok(Arr($out))
	}
	Object(members) => {
		enter(depth, limits)?
		var $out = []
		for (k, x) in members {
			within(key(k, limits), ErrorCode.path_key(k))?
			$out = $out.append((k, within(imported(x, depth + 1, limits), ErrorCode.path_key(k))?))
		}
		Ok(Rec($out))
	}
}

## A member name as a record key: within the string limit (spec §7).
key : Str, Value.Limits -> Try({}, Decode.Error)
key = |k, limits| text_within(k, "key", limits)

## A key or tag (`what`) within the string limit, counted in code points.
text_within : Str, Str, Value.Limits -> Try({}, Decode.Error)
text_within = |s, what, limits| {
	b = s.to_utf8()
	max = limits.max_string_length
	code = if (what == "key") ErrorCode.key_too_long else if (what == "tag") ErrorCode.tag_too_long else ErrorCode.string_too_long
	if (b.len() > max and code_points(b) > max) Decode.fail(code, "${what} longer than ${max.to_str()} characters") else Ok({})
}

enter : U64, Value.Limits -> Try({}, Decode.Error)
enter = |depth, limits| if (depth >= limits.max_depth) Decode.fail(ErrorCode.nesting_too_deep, "nesting deeper than ${limits.max_depth.to_str()} levels") else Ok({})

within : Try(a, Decode.Error), Str -> Try(a, Decode.Error)
within = |result, segment| result.map_err(|e| { ..e, path: "${segment}${e.path}" })

## The self-describing form of a value the parser gave (so it is valid and
## normalized), without the envelope.
self_describing : Value -> JsonValue
self_describing = |value| match value {
	Num(n) => Object([("_num", String(n))])
	Text(s) => String(s)
	Bytes(b) => Object([("_bytes", String(hex_lower(b)))])
	Arr(items) => Array(items.map(self_describing))
	Rec(fields) => Object([("_rec", Object(fields.map(|(k, x)| (k, self_describing(x)))))])
	Tag(name, []) => Object([("_tag", String(name))])
	Tag(name, args) => Object([("_tag", String(name)), ("_args", Array(args.map(self_describing)))])
}

## The value of a self-describing JSON text: the envelope
## `{"_haus": 1, "_value": …}` around a self-describing value. The envelope
## adds no segment to the path.
unwrap : JsonValue, Value.Limits -> Try(Value, Decode.Error)
unwrap = |json, limits| match json {
	Object([("_haus", version), ("_value", value)]) => enveloped(version, value, limits)
	Object([("_value", value), ("_haus", version)]) => enveloped(version, value, limits)
	Object(_) => Decode.fail(ErrorCode.haus_json_form, "expected self-describing JSON, an object {\"_haus\": 1, \"_value\": …} with no other members, found another object")
	_ => Decode.fail(ErrorCode.haus_json_form, "expected self-describing JSON, an object {\"_haus\": 1, \"_value\": …}, found ${describe_json(json)}")
}

enveloped : JsonValue, JsonValue, Value.Limits -> Try(Value, Decode.Error)
enveloped = |version, value, limits| match version {
	Number("1") => described(value, 0, limits)
	_ => Decode.fail(ErrorCode.haus_json_version, "expected version 1 of self-describing JSON (\"_haus\": 1), found ${describe_json(version)}")
}

forms : Str
forms = "a self-describing value: a string, an array, or an object {\"_num\"}, {\"_bytes\"}, {\"_rec\"} or {\"_tag\", \"_args\"?}"

## A value from its self-describing form, at `depth` haus levels (counted as
## the haus writer counts them: `Tag { … }` is one level).
described : JsonValue, U64, Value.Limits -> Try(Value, Decode.Error)
described = |json, depth, limits| match json {
	String(s) => Ok(Text(s))
	Array(items) => {
		enter(depth, limits)?
		Ok(Arr(described_items(items, depth + 1, limits)?))
	}
	Object([("_num", n)]) => within(described_number(n, limits), "._num")
	Object([("_bytes", h)]) => within(described_bytes(h), "._bytes")
	Object([("_rec", r)]) => within(described_record(r, depth, limits), "._rec")
	Object([("_tag", t)]) => Ok(Tag(described_tag(t, limits)?, []))
	Object([("_tag", t), ("_args", a)]) => described_variant(t, a, depth, limits)
	Object([("_args", a), ("_tag", t)]) => described_variant(t, a, depth, limits)
	_ => Decode.fail(ErrorCode.haus_json_form, "expected ${forms}, found ${describe_json(json)}")
}

described_items : List(JsonValue), U64, Value.Limits -> Try(List(Value), Decode.Error)
described_items = |items, depth, limits| {
	var $out = []
	var $i = 0.U64
	for x in items {
		$out = $out.append(within(described(x, depth, limits), "[${$i.to_str()}]")?)
		$i = $i + 1
	}
	Ok($out)
}

## `"19.90"`: a normalized literal (spec §2) that a reader with `limits` takes.
described_number : JsonValue, Value.Limits -> Try(Value, Decode.Error)
described_number = |json, limits| match json {
	String(n) => {
		# Writing it and reading it back gives the same text only if it is normalized.
		same = match Encode.to_str_with(Num(n), limits) {
			Ok(written) => match Value.parse_with(written, limits) {
				Ok(Num(m)) => m == n
				_ => Bool.False
			}
			# A literal beyond the limits has the limit's code.
			Err(e) => return Decode.fail(if (e.code == ErrorCode.cannot_encode) ErrorCode.haus_json_number else e.code, e.reason)
		}
		if (same) Ok(Num(n)) else Decode.fail(ErrorCode.haus_json_number, "${quote_str(n)} is not a normalized number literal")
	}
	_ => Decode.fail(ErrorCode.haus_json_number, "expected a string, found ${describe_json(json)}")
}

## `"0b34ff"`: two lowercase hex digits per byte.
described_bytes : JsonValue -> Try(Value, Decode.Error)
described_bytes = |json| match json {
	String(text) => {
		b = text.to_utf8()
		is_lower_hex = |c| is_digit(c) or (c >= 'a' and c <= 'f')
		if b.len() % 2 != 0 or !b.all(is_lower_hex) {
			Decode.fail(ErrorCode.haus_json_bytes, "expected two lowercase hex digits per byte")
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
	_ => Decode.fail(ErrorCode.haus_json_bytes, "expected a string, found ${describe_json(json)}")
}

described_record : JsonValue, U64, Value.Limits -> Try(Value, Decode.Error)
described_record = |json, depth, limits| match json {
	Object(members) => {
		enter(depth, limits)?
		var $seen = Set.empty()
		var $out = []
		for (k, x) in members {
			if $seen.contains(k) {
				return within(Decode.fail(ErrorCode.duplicate_key, "the key ${quote_str(k)} is used twice"), ErrorCode.path_key(k))
			}
			$seen = $seen.insert(k)
			within(key(k, limits), ErrorCode.path_key(k))?
			$out = $out.append((k, within(described(x, depth + 1, limits), ErrorCode.path_key(k))?))
		}
		Ok(Rec($out))
	}
	_ => Decode.fail(ErrorCode.haus_json_form, "expected an object, found ${describe_json(json)}")
}

## `"Circle"`: a tag name within the string limit.
described_tag : JsonValue, Value.Limits -> Try(Str, Decode.Error)
described_tag = |json, limits| match json {
	String(t) if is_tag(t) => within(text_within(t, "tag", limits), "._tag").map_ok(|_| t)
	String(t) => within(Decode.fail(ErrorCode.invalid_tag, "${quote_str(t)} is not a tag name (A to Z, then letters, digits and _)"), "._tag")
	_ => within(Decode.fail(ErrorCode.invalid_tag, "expected a string, found ${describe_json(json)}"), "._tag")
}

described_variant : JsonValue, JsonValue, U64, Value.Limits -> Try(Value, Decode.Error)
described_variant = |tag, args, depth, limits| {
	name = described_tag(tag, limits)?
	values = match args {
		Array([]) => return within(Decode.fail(ErrorCode.haus_json_form, "a tag without arguments has no \"_args\""), "._args")
		# `Tag { … }`: the record is the payload's only level.
		Array([Object([("_rec", r)])]) => [within(within(described_record(r, depth, limits), "._rec"), "._args[0]")?]
		Array(items) => {
			within(enter(depth, limits), "._args")?
			within(described_items(items, depth + 1, limits), "._args")?
		}
		_ => return within(Decode.fail(ErrorCode.haus_json_form, "expected an array, found ${describe_json(args)}"), "._args")
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

## Four lowercase hex digits, for a code point below U+10000.
hex4_of : U64 -> Str
hex4_of = |cp| bytes_to_str([cp // 4096, (cp // 256) % 16, (cp // 16) % 16, cp % 16].map(|d| hex_digit(d.to_u8_wrap())))

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
quote_str = |s| match quote(s, Value.default_limits) {
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
locate = |src, { code, reason, pos }| {
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
	{ code, reason, line: $line, column: $column }
}

# ── tests ────────────────────────────────────────────────────

expect JsonValue.parse(" {\"a\": [1, -0.5e+3, true, false, null]}\r\n") == Ok(Object([("a", Array([Number("1"), Number("-0.5e+3"), Boolean(True), Boolean(False), Null]))]))
expect JsonValue.parse("\"\\u00e9\\ud83d\\ude00\\n\\/\"") == Ok(String("é😀\n/"))
expect JsonValue.parse("\"\u(10FFFF)\u(7F)\"") == Ok(String("\u(10FFFF)\u(7F)"))
expect JsonValue.parse("{\"a\": 1, \"a\": 2}") == Err({ code: "duplicate-key", reason: "duplicate member name \"a\"", line: 1, column: 10 })
expect JsonValue.parse("\"\\ud83d\"").map_err(|e| e.reason) == Err("unpaired surrogate in a \\u escape")
expect JsonValue.parse("\"\\ude00\\ud83d\"").map_err(|e| e.reason) == Err("unpaired surrogate in a \\u escape")
expect JsonValue.parse("\"a\u(1)\"").map_err(|e| e.reason) == Err("raw control character U+0001 in a string (escape it)")
expect JsonValue.parse("[1,]") == Err({ code: "json-syntax", reason: "expected a JSON value, found ']'", line: 1, column: 4 })
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

expect JsonValue.to_str(String("\"\\\n\r\t\u(8)\u(C)\u(1)\u(7F)é")) == Ok("\"\\\"\\\\\\n\\r\\t\\b\\f\\u0001\\u007fé\"")
# DEL, C1 and the bidi controls are escaped too, in strings and member names (spec §16).
expect JsonValue.to_str(Object([("a\u(85)", String("\u(9F)\u(A0)\u(202A)\u(202E)\u(202F)\u(2066)\u(2069)\u(206A)"))])) == Ok("{\"a\\u0085\":\"\\u009f\u(A0)\\u202a\\u202e\u(202F)\\u2066\\u2069\u(206A)\"}")
expect JsonValue.to_str(Object([("a", Array([Number("1.5"), Null, Boolean(True)]))])) == Ok("{\"a\":[1.5,null,true]}")
expect JsonValue.to_str(Number("01")) == Err({ code: "cannot-encode", reason: "not a JSON number", path: "" })
expect JsonValue.to_str(Object([("a", Null), ("a", Null)])) == Err({ code: "duplicate-key", reason: "a member name is used twice in an object", path: "" })

expect JsonValue.import_json("{\"a\": 1E+05, \"b\": [true, null], \"c\": \"x\"}").map_ok(Encode.canonical) == Ok("{a:1e5,b:[True,None],c:\"x\"}")
expect JsonValue.import_json("${Str.repeat("[", 256)}${Str.repeat("]", 256)}").is_ok()
expect JsonValue.import_json("${Str.repeat("[", 257)}${Str.repeat("]", 257)}").is_err()
expect JsonValue.import_json("\u(FEFF)[1]").map_ok(Encode.canonical) == Ok("[1]")

## A self-describing value in its envelope, as these tests write it.
env : Str -> Str
env = |value| "{\"_haus\": 1, \"_value\": ${value}}"

## A self-describing value in its envelope, as the writer writes it.
enveloped_as_written : Str -> Str
enveloped_as_written = |value| "{\"_haus\":1,\"_value\":${value}}"

expect JsonValue.to_haus_json(Tag("Point", [Num("1"), Num("2.50")])) == Ok(enveloped_as_written("{\"_tag\":\"Point\",\"_args\":[{\"_num\":\"1\"},{\"_num\":\"2.50\"}]}"))
expect JsonValue.to_haus_json(Num("1E5")) == Ok(enveloped_as_written("{\"_num\":\"1e5\"}"))
expect JsonValue.haus_json_value(Num("1E5")) == Ok(Object([("_num", String("1e5"))]))
expect JsonValue.to_haus_json(Arr([Num("1"), Num("abc")])) == Err({ code: "cannot-encode", reason: "not a number literal", path: "[1]" })
expect JsonValue.from_haus_json(env("{\"_num\": \"1E5\"}")).is_err()
expect JsonValue.from_haus_json(env("{\"_tag\": \"T\", \"_args\": []}")).is_err()
expect JsonValue.from_haus_json(env("{\"_args\": [{\"_num\": \"1\"}], \"_tag\": \"T\"}")).map_ok(Encode.canonical) == Ok("T(1)")

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

# Your own limits (`_with`): at each limit, and just past it.
small : Value.Limits
small = { max_depth: 2, max_number_length: 4, max_exponent: 9, max_string_length: 4 }

expect JsonValue.parse_with("[\"abcd\", 1234, 1e9, [[[[[[[[0]]]]]]]]]", small).is_ok()
expect JsonValue.parse_with("\"abcde\"", small).map_err(|e| e.reason) == Err("string longer than 4 characters")
expect JsonValue.parse_with("12345", small).map_err(|e| e.reason) == Err("number literal longer than 4 characters")
expect JsonValue.parse_with("1e10", small).map_err(|e| e.reason) == Err("exponent larger than 9")
expect JsonValue.parse_with("[[[[[[[[[[0]]]]]]]]]]", small).map_err(|e| e.reason) == Err("JSON nested deeper than 9 levels")
# Without a schema the JSON nests as deep as the value.
expect JsonValue.import_json_with("[[0]]", small).is_ok() and JsonValue.import_json_with("[[[0]]]", small).is_err()
expect JsonValue.lines_with("[[0]]\n\"abcd\"", small).is_ok() and JsonValue.lines_with("1\n\"abcde\"", small).map_err(|e| e.line) == Err(2)
# Self-describing: the value within the limits too. (Its envelope's member
# names count against the string limit, as every JSON string does.)
small6 : Value.Limits
small6 = { ..small, max_string_length: 6 }

expect JsonValue.from_haus_json_with(env("[[{\"_num\": \"1e9\"}]]"), small6).is_ok()
expect JsonValue.from_haus_json_with(env("[[[\"a\"]]]"), small6).is_err()
# Member names that become keys, and tags, count against the string limit.
expect JsonValue.import_json_with("{\"abcd\": 1}", small).is_ok()
expect JsonValue.from_haus_json_with(env("{\"_rec\": {\"abcdef\": \"x\"}}"), small6).is_ok() and JsonValue.from_haus_json_with(env("{\"_tag\": \"Abcdef\"}"), small6).is_ok()
expect JsonValue.import_value(Object([("abcde", Null)])).is_ok()
expect imported(Object([("abcde", Null)]), 0, small).map_ok(|_| {}).map_err(Decode.message) == Err(".abcde: key longer than 4 characters")
expect described(Object([("_rec", Object([("abcde", String("x"))]))]), 0, small).map_ok(|_| {}).map_err(Decode.message) == Err("._rec.abcde: key longer than 4 characters")
expect described(Object([("_tag", String("Abcde"))]), 0, small).map_ok(|_| {}).map_err(Decode.message) == Err("._tag: tag longer than 4 characters")
expect described(Object([("_tag", String("Abcde")), ("_args", Array([String("x")]))]), 0, small).map_ok(|_| {}).map_err(Decode.message) == Err("._tag: tag longer than 4 characters")
# Writing for a reader with other limits.
expect JsonValue.to_str_with(Array([Array([String("abcd"), Number("1234")])]), small) == Ok("[[\"abcd\",1234]]")
expect JsonValue.to_str_with(String("abcde"), small) == Err({ code: "string-too-long", reason: "string longer than 4 characters", path: "" })
expect JsonValue.to_str_with(Number("12345"), small) == Err({ code: "number-too-long", reason: "number literal longer than 4 characters", path: "" })
expect JsonValue.to_str_with(Array([Array([Array([Array([Array([Array([Array([Array([Array([Null])])])])])])])])]), small) == Ok("[[[[[[[[[null]]]]]]]]]")
expect JsonValue.to_str_with(Array([Array([Array([Array([Array([Array([Array([Array([Array([Array([Null])])])])])])])])])]), small) == Err({ code: "nesting-too-deep", reason: "JSON nested deeper than 9 levels", path: "" })
expect JsonValue.write_lines_with([Number("1"), String("abcde")], small) == Err({ code: "string-too-long", reason: "string longer than 4 characters", path: "[1]" })
expect JsonValue.to_haus_json_with(Arr([Arr([Num("1")])]), small6) == Ok(enveloped_as_written("[[{\"_num\":\"1\"}]]"))
expect JsonValue.to_haus_json_with(Arr([Arr([Arr([Num("1")])])]), small) == Err({ code: "nesting-too-deep", reason: "nesting deeper than 2 levels", path: "[0][0]" })
expect JsonValue.to_haus_json_with(Rec([("abcde", Num("1"))]), small) == Err({ code: "key-too-long", reason: "key longer than 4 characters", path: ".abcde" })
# Up to the supported depth; a deeper limit is an error that names the maximum.
deepest : Value.Limits
deepest = { ..Value.default_limits, max_depth: Value.max_supported_depth }
expect {
	deep = "${Str.repeat("{\"_tag\":\"A\",\"_args\":[", 1024)}\"a\"${Str.repeat("]}", 1024)}"
	match JsonValue.from_haus_json_with(env(deep), deepest) {
		Ok(v) => JsonValue.to_haus_json_with(v, deepest) == Ok(enveloped_as_written(deep))
		Err(_) => Bool.False
	}
}
expect JsonValue.import_json_with("${Str.repeat("[", 1024)}${Str.repeat("]", 1024)}", deepest).is_ok()
expect JsonValue.parse_with("${Str.repeat("[", 4097)}${Str.repeat("]", 4097)}", deepest).is_ok()
too_deep : Value.Limits
too_deep = { ..Value.default_limits, max_depth: 1025 }
unsupported : Str
unsupported = "max_depth 1025 is more than the supported maximum, 1024"
expect JsonValue.parse_with("1", too_deep) == Err({ code: "unsupported-depth", reason: unsupported, line: 1, column: 1 })
expect JsonValue.lines_with("1", too_deep).map_err(|e| e.reason) == Err(unsupported)
expect JsonValue.import_json_with("1", too_deep).map_ok(|_| {}) == Err(Syntax({ code: "unsupported-depth", reason: unsupported, line: 1, column: 1 }))
expect JsonValue.from_haus_json_with(env("\"a\""), too_deep).map_ok(|_| {}) == Err(Syntax({ code: "unsupported-depth", reason: unsupported, line: 1, column: 1 }))
expect JsonValue.to_str_with(Null, too_deep) == Err({ code: "unsupported-depth", reason: unsupported, path: "" })
expect JsonValue.write_lines_with([], too_deep) == Err({ code: "unsupported-depth", reason: unsupported, path: "" })
expect JsonValue.to_haus_json_with(Num("1"), too_deep) == Err({ code: "unsupported-depth", reason: unsupported, path: "" })

expect JsonValue.from_haus_json_with(env("{\"_num\": \"1e10\"}"), small6).map_ok(|_| {}).map_err(
	|e| match e {
		Decode(d) => Decode.message(d)
		Syntax(_) => ""
	},
) == Err("._num: exponent larger than 9")

# Error codes (spec §17).
json_code : Try(a, [Syntax(Value.ParseError), Decode(Decode.Error)]) -> Str
json_code = |result| match result {
	Ok(_) => "ok"
	Err(Syntax(e)) => "${e.code} at ${e.line.to_str()}:${e.column.to_str()}"
	Err(Decode(e)) => "${e.code} at ${ErrorCode.place(e.path)}"
}

expect json_code(JsonValue.import_json("[1,]")) == "json-syntax at 1:4" and json_code(JsonValue.import_json("NaN")) == "json-syntax at 1:1" and json_code(JsonValue.import_json("1 2")) == "json-syntax at 1:3"
expect json_code(JsonValue.import_json("\"\\ud83d\"")) == "unpaired-surrogate at 1:2" and json_code(JsonValue.import_json("\"\\u12\"")) == "invalid-unicode-escape at 1:4"
expect json_code(JsonValue.import_json("\"\\ud83d\\u12\"")) == "invalid-unicode-escape at 1:10" and json_code(JsonValue.import_json("\"\\ud83d\\u0041\"")) == "unpaired-surrogate at 1:2" and json_code(JsonValue.import_json("\"\\x\"")) == "invalid-escape at 1:2"
expect json_code(JsonValue.import_json("\"a\u(1)\"")) == "control-character at 1:3" and json_code(JsonValue.import_json("\"a")) == "unterminated-string at 1:1" and json_code(JsonValue.import_json("{\"a\": 1, \"a\": 2}")) == "duplicate-key at 1:10"
expect json_code(JsonValue.import_json("1.")) == "json-syntax at 1:1" and json_code(JsonValue.import_json(Str.repeat("1", 1001))) == "number-too-long at 1:1" and json_code(JsonValue.import_json("1e6145")) == "exponent-too-large at 1:1"
expect json_code(JsonValue.from_haus_json(env("1"))) == "haus-json-form at $" and json_code(JsonValue.from_haus_json(env("{\"_num\": \"1\", \"x\": 2}"))) == "haus-json-form at $"
expect json_code(JsonValue.from_haus_json(env("{\"_num\": \"01\"}"))) == "haus-json-number at $._num" and json_code(JsonValue.from_haus_json(env("{\"_num\": 1}"))) == "haus-json-number at $._num"
expect json_code(JsonValue.from_haus_json(env("{\"_num\": \"1e9999\"}"))) == "exponent-too-large at $._num" and json_code(JsonValue.from_haus_json(env("{\"_bytes\": \"0B34\"}"))) == "haus-json-bytes at $._bytes"
expect json_code(JsonValue.from_haus_json(env("{\"_tag\": \"circle\"}"))) == "invalid-tag at $._tag" and json_code(JsonValue.from_haus_json(env("{\"_tag\": \"T\", \"_args\": []}"))) == "haus-json-form at $._args"
expect json_code(JsonValue.from_haus_json(env("{\"_rec\": {\"a\": 1}}"))) == "haus-json-form at $._rec.a" and json_code(JsonValue.from_haus_json(env("{\"_rec\": {\"pt-BR\": 1}}"))) == "haus-json-form at $._rec[\"pt-BR\"]"
expect JsonValue.from_haus_json_value(Object([("_rec", Object([("a", String("x")), ("a", String("y"))]))])).map_ok(|_| {}).map_err(|e| (e.code, e.path)) == Err(("duplicate-key", "._rec.a"))
expect JsonValue.to_haus_json(Tag("lower", [])).map_err(|e| e.code) == Err("invalid-tag")

# The envelope (spec §16.2): exactly `_haus` and `_value`, version 1, read in any order.
expect JsonValue.from_haus_json("{\"_value\": \"a\", \"_haus\": 1}").map_ok(Encode.canonical) == Ok("\"a\"")
expect json_code(JsonValue.from_haus_json("\"a\"")) == "haus-json-form at $" and json_code(JsonValue.from_haus_json("{\"_num\": \"1\"}")) == "haus-json-form at $"
expect json_code(JsonValue.from_haus_json("{\"_haus\": 1}")) == "haus-json-form at $" and json_code(JsonValue.from_haus_json("{\"_haus\": 1, \"_value\": \"a\", \"x\": 1}")) == "haus-json-form at $"
expect json_code(JsonValue.from_haus_json("{\"_haus\": 2, \"_value\": \"a\"}")) == "haus-json-version at $" and json_code(JsonValue.from_haus_json("{\"_haus\": \"1\", \"_value\": \"a\"}")) == "haus-json-version at $"
expect json_code(JsonValue.from_haus_json("{\"_haus\": 1.0, \"_value\": \"a\"}")) == "haus-json-version at $" and json_code(JsonValue.from_haus_json("{\"_haus\": 2, \"_value\": 1}")) == "haus-json-version at $"
# Raw DEL, C1 and bidi controls: rejected in self-describing JSON, accepted elsewhere.
expect json_code(JsonValue.from_haus_json(env("\"a\u(7F)b\""))) == "control-character at 1:26" and json_code(JsonValue.from_haus_json(env("\"a\u(85)b\""))) == "control-character at 1:26"
expect json_code(JsonValue.from_haus_json(env("\"a\u(202E)b\""))) == "bidi-control at 1:26" and json_code(JsonValue.from_haus_json(env("{\"_rec\": {\"a\u(2066)\": \"b\"}}"))) == "bidi-control at 1:36"
expect JsonValue.from_haus_json(env("\"a\\u007f\\u0085\\u202eb\"")).map_ok(Encode.canonical) == Ok("\"a\\u{7F}\\u{85}\\u{202E}b\"")
expect JsonValue.from_haus_json(env("\"\u(A0)\u(202F)\u(2065)\u(206A)\"")).is_ok()
expect JsonValue.import_json("\"a\u(7F)\u(85)\u(202E)b\"").map_ok(Encode.canonical) == Ok("\"a\\u{7F}\\u{85}\\u{202E}b\"") and JsonValue.parse("\"\u(2069)\"") == Ok(String("\u(2069)"))
expect JsonValue.from_haus_json_value(Object([("_haus", Number("1")), ("_value", String("x"))])).map_ok(|_| {}).map_err(|e| e.code) == Err("haus-json-form")
# The import reads the envelope as a record.
expect JsonValue.import_json(env("{\"_num\": \"1\"}")).map_ok(Encode.canonical) == Ok("{_haus:1,_value:{_num:\"1\"}}")
# Self-describing JSON Lines: an envelope per line.
expect JsonValue.to_haus_json_lines([Num("1"), Text("a")]) == Ok("${enveloped_as_written("{\"_num\":\"1\"}")}\n${enveloped_as_written("\"a\"")}\n")
expect JsonValue.to_haus_json_lines([]) == Ok("")
expect JsonValue.to_haus_json_lines([Text("a"), Num("x")]).map_err(|e| e.path) == Err("[1]")
expect JsonValue.from_haus_json_lines("\u(FEFF)${env("\"a\"")}\r\n${env("[]")}").map_ok(|vs| vs.map(Encode.canonical)) == Ok(["\"a\"", "[]"])
expect JsonValue.from_haus_json_lines("").map_ok(List.len) == Ok(0)
expect json_code(JsonValue.from_haus_json_lines("${env("\"a\"")}\n\"b\"\n")) == "haus-json-form at $[1]" and json_code(JsonValue.from_haus_json_lines("${env("\"a\"")}\n${env("\"\u(85)\"")}")) == "control-character at 2:25"
# The envelope's level: 4·d + 2 JSON levels for self-describing JSON.
# `A { a: B { b: 1 } }` nests 2 haus levels and 4·2 + 2 = 10 JSON levels.
expect {
	deepest_form = "{\"_tag\":\"A\",\"_args\":[{\"_rec\":{\"a\":{\"_tag\":\"B\",\"_args\":[{\"_rec\":{\"b\":{\"_num\":\"1\"}}}]}}}]}"
	match JsonValue.from_haus_json_with(env(deepest_form), small6) {
		Ok(v) => JsonValue.to_haus_json_with(v, small6) == Ok(enveloped_as_written(deepest_form))
		Err(_) => Bool.False
	}
}
