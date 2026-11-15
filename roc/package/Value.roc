## The haus data model and parser.
##
## `Value.parse_all(text)` parses a whole file: a sequence of top-level values.
## Numbers are kept as exact literal text, variants are generic: applying a
## schema (decoding into your own tag unions) happens afterwards.
##
## A syntax error is a `ParseError`: its `code` (spec §17, see `ErrorCode`),
## a `reason` for people, and the `line` and `column` where it is.
import ErrorCode

Value := [
	Num(Str),
	Text(Str),
	Bytes(List(U8)),
	Arr(List(Value)),
	Rec(List((Str, Value))),
	Tag(Str, List(Value)),
].{

	## Parse a whole file into its top-level values.
	parse_all : Str -> Try(List(Value), ParseError)
	parse_all = |text| parse_all_with(text, default_limits)

	## `parse_all` with your own limits.
	parse_all_with : Str, Limits -> Try(List(Value), ParseError)
	parse_all_with = |text, limits| {
		check_limits(limits).map_err(unsupported)?
		src = text.to_utf8()
		start = if (src.starts_with([0xEF, 0xBB, 0xBF])) 3 else 0
		# Reserved for a version directive (spec §10): `#haus 2`.
		if starts_at(src, start, "#haus") {
			return Err(locate(src, { code: ErrorCode.version_directive, reason: newer_version_reason, pos: start }))
		}
		parse_sequence(src, start, limits).map_err(|f| locate(src, f))
	}

	## The rest of a stream: like `parse_all`, but not at the start of the input,
	## so a byte order mark is not skipped (the stream reader removes the one at
	## the start).
	parse_rest : Str -> Try(List(Value), ParseError)
	parse_rest = |text| parse_rest_with(text, default_limits)

	## `parse_rest` with your own limits.
	parse_rest_with : Str, Limits -> Try(List(Value), ParseError)
	parse_rest_with = |text, limits| {
		check_limits(limits).map_err(unsupported)?
		src = text.to_utf8()
		parse_sequence(src, 0, limits).map_err(|f| locate(src, f))
	}

	## Whether a file that starts with `text` needs a newer version of haus:
	## it starts with a version directive (`#haus 2`, spec §10). The reason to
	## report then is `Value.newer_version_reason`.
	starts_with_directive : Str -> Bool
	starts_with_directive = |text| text.starts_with("#haus")

	newer_version_reason : Str
	newer_version_reason = "the file starts with a version directive (#haus): it needs a newer version of haus"

	## Parse raw bytes, which must be valid UTF-8 (`invalid-utf8` where they
	## aren't).
	parse_bytes : List(U8) -> Try(List(Value), ParseError)
	parse_bytes = |bytes| parse_bytes_with(bytes, default_limits)

	## `parse_bytes` with your own limits.
	parse_bytes_with : List(U8), Limits -> Try(List(Value), ParseError)
	parse_bytes_with = |bytes, limits| match Str.from_utf8(bytes) {
		Ok(text) => parse_all_with(text, limits)
		Err(BadUtf8({ index, .. })) => Err(locate(bytes, { code: ErrorCode.invalid_utf8, reason: "invalid UTF-8", pos: index }))
	}

	## Parse a text that must contain exactly one value (`not-one-value` if it
	## has none or several).
	parse : Str -> Try(Value, ParseError)
	parse = |text| parse_with(text, default_limits)

	## `parse` with your own limits.
	parse_with : Str, Limits -> Try(Value, ParseError)
	parse_with = |text, limits| {
		values = parse_all_with(text, limits)?
		match values {
			[v] => Ok(v)
			_ => Err({ code: ErrorCode.not_one_value, reason: "expected exactly one value, found ${values.len().to_str()}", line: 1, column: 1 })
		}
	}

	## The JSON form of a parse error (spec §17), on one line:
	## `{"code":"missing-comma","message":"expected ',' or ']', found '2'","line":1,"column":4,"hint":"Add a comma between the two values.","docs":"https://haus-fmt.org/docs/errors#missing-comma"}`.
	error_json : ParseError -> Str
	error_json = |e| ErrorCode.json({ code: e.code, message: e.reason, at: Position(e.line, e.column) })

	## Resource limits (spec §7), enforced while parsing: nesting depth (records,
	## arrays and payloads, at most `max_supported_depth`), characters in one
	## number literal, the largest absolute exponent (6144 allows `1e6144`, not
	## `1e6145`), and characters (code points) in one decoded string, record
	## key or tag, or between the quotes of a byte string. A value of exactly
	## a limit is accepted.
	##
	##     Value.parse_all_with(text, { ..Value.default_limits, max_depth: 64 })
	Limits : { max_depth : U64, max_number_length : U64, max_exponent : U64, max_string_length : U64 }

	## The largest `max_depth` this binding supports (spec §7): 1024. The
	## parser, decoding, encoding and the JSON mappings recurse once per level
	## of nesting, so the depth limit bounds the call stack they use. Every
	## function that takes limits fails, before reading or writing anything,
	## if `max_depth` is larger, with an error that names this maximum
	## (see `check_limits`).
	max_supported_depth : U64
	max_supported_depth = 1024

	## `Ok({})` if this binding supports `limits`, or the reason it doesn't:
	## `max_depth 2000 is more than the supported maximum, 1024`. Every
	## function that takes limits checks them so, and fails with the code
	## `unsupported-depth`.
	check_limits : Limits -> Try({}, Str)
	check_limits = |limits|
		if limits.max_depth > max_supported_depth {
			Err("max_depth ${limits.max_depth.to_str()} is more than the supported maximum, ${max_supported_depth.to_str()}")
		} else {
			Ok({})
		}

	## The spec's defaults: depth 256, number literals of 1000 characters,
	## exponents up to 6144, strings of 16 Mi characters. Every reader must
	## take what is within them.
	default_limits : Limits
	default_limits = { max_depth: 256, max_number_length: 1000, max_exponent: 6144, max_string_length: 16 * 1024 * 1024 }

	## Encode in the conformance suite's JSON form (see test-suite/README.md).
	to_test_json : Value -> Str
	to_test_json = |value| match value {
		Num(t) => "{\"num\":${json_str(t)}}"
		Text(s) => json_str(s)
		Bytes(bytes) => "{\"bytes\":\"${hex_lower(bytes)}\"}"
		Arr(items) => "[${Str.join_with(items.map(to_test_json), ",")}]"
		Rec(fields) => {
			parts = fields.map(|(k, v)| "${json_str(k)}:${to_test_json(v)}")
			"{\"rec\":{${Str.join_with(parts, ",")}}}"
		}
		Tag(name, []) => "{\"tag\":${json_str(name)}}"
		Tag(name, args) => "{\"tag\":${json_str(name)},\"args\":[${Str.join_with(args.map(to_test_json), ",")}]}"
	}
}

## A syntax error: its code (spec §17, `ErrorCode`), what is wrong, and where
## (1-based, columns in code points).
ParseError : { code : Str, reason : Str, line : U64, column : U64 }

Fail : { code : Str, reason : Str, pos : U64 }

## Limits this binding doesn't support, as an error at the start.
unsupported : Str -> ParseError
unsupported = |reason| { code: ErrorCode.unsupported_depth, reason, line: 1, column: 1 }

# ── structure ────────────────────────────────────────────────

parse_sequence : List(U8), U64, Value.Limits -> Try(List(Value), Fail)
parse_sequence = |src, start, limits| {
	var $out = []
	var $pos = skip_trivia(src, start)?
	var $done = $pos >= src.len()
	while !$done {
		(value, after) = parse_value(src, $pos, 0, limits)?
		$out = $out.append(value)
		p = skip_trivia(src, after)?
		if p >= src.len() {
			$done = True
		} else if at(src, p) == ',' {
			$pos = skip_trivia(src, p + 1)?
			$done = $pos >= src.len()
		} else {
			return Err(separator(src, p, value, "expected ',' between top-level values"))
		}
	}
	Ok($out)
}

## After `previous`, something other than a comma (or the closing bracket):
## which mistake it is, as the reference parser decides (spec §17). A payload
## `(…)` or `{…}` after a tag without one (a line break or a comment came
## between them), a closing bracket of the wrong kind, or a missing comma.
separator : List(U8), U64, Value, Str -> Fail
separator = |src, pos, previous, expected| {
	c = at(src, pos)
	bare = match previous {
		Tag(_, []) => True
		_ => False
	}
	code =
		if (c == '(' or c == '{') and bare {
			ErrorCode.payload_newline
		} else if c == '}' or c == ']' or c == ')' {
			ErrorCode.unexpected_closer
		} else {
			ErrorCode.missing_comma
		}
	{ code, reason: "${expected}, found ${describe(src, pos)}", pos }
}

parse_value : List(U8), U64, U64, Value.Limits -> Try((Value, U64), Fail)
parse_value = |src, pos, depth, limits| {
	c = at(src, pos)
	if c == '{' {
		(fields, after) = parse_record(src, pos, depth, limits)?
		Ok((Rec(fields), after))
	} else if c == '[' {
		(items, after) = parse_list(src, pos, depth, ']', limits)?
		Ok((Arr(items), after))
	} else if c == '"' {
		(s, after) = (if (starts_at(src, pos, "\"\"\"")) parse_block_string(src, pos, limits) else parse_basic_string(src, pos, limits))?
		Ok((Text(s), after))
	} else if c == 'x' and at(src, pos + 1) == '"' {
		(bytes, after) = parse_bytes_literal(src, pos, limits)?
		Ok((Bytes(bytes), after))
	} else if c == '-' or is_digit(c) {
		parse_number(src, pos, limits)
	} else if is_upper(c) {
		parse_variant(src, pos, depth, limits)
	} else if is_lower_start(c) {
		(word, _) = read_ident(src, pos)
		(code, hint) =
			if word == "true" or word == "false" {
				(ErrorCode.boolean_literal, " (booleans are the variants True / False)")
			} else if word == "null" {
				(ErrorCode.null_literal, " (use the variant None)")
			} else {
				(ErrorCode.bare_identifier, "")
			}
		Err({ code, reason: "unexpected identifier '${word}': lowercase identifiers can only be record keys${hint}", pos })
	} else {
		# `+1` and `.5`: a number written the way other languages allow.
		code = if (c == '+' or c == '.') ErrorCode.invalid_number else ErrorCode.expected_value
		Err({ code, reason: "expected a value, found ${describe(src, pos)}", pos })
	}
}

nesting_error : Value.Limits, U64 -> Fail
nesting_error = |limits, open| { code: ErrorCode.nesting_too_deep, reason: "nesting deeper than ${limits.max_depth.to_str()} levels", pos: open }

unclosed : List(U8), U64 -> Fail
unclosed = |src, open| { code: ErrorCode.unclosed_bracket, reason: "unclosed '${byte_str(at(src, open))}'", pos: open }

parse_record : List(U8), U64, U64, Value.Limits -> Try((List((Str, Value)), U64), Fail)
parse_record = |src, open, depth, limits| {
	if depth + 1 > limits.max_depth {
		return Err(nesting_error(limits, open))
	}
	var $fields = []
	var $seen = Set.empty()
	var $pos = skip_trivia(src, open + 1)?
	while at(src, $pos) != '}' {
		if $pos >= src.len() {
			return Err(unclosed(src, open))
		}
		key_pos = $pos
		(key, after_key) = parse_key(src, $pos, limits)?
		colon = skip_trivia(src, after_key)?
		if at(src, colon) != ':' {
			return Err({ code: ErrorCode.missing_colon, reason: "expected ':' after key '${key}', found ${describe(src, colon)}", pos: colon })
		}
		(value, after_value) = parse_value(src, skip_trivia(src, colon + 1)?, depth + 1, limits)?
		if $seen.contains(key) {
			return Err({ code: ErrorCode.duplicate_key, reason: "duplicate key '${key}'", pos: key_pos })
		}
		$fields = $fields.append((key, value))
		$seen = $seen.insert(key)
		p = skip_trivia(src, after_value)?
		if at(src, p) == ',' {
			$pos = skip_trivia(src, p + 1)?
		} else if at(src, p) == '}' {
			$pos = p
		} else if p >= src.len() {
			return Err(unclosed(src, open))
		} else {
			return Err(separator(src, p, value, "expected ',' or '}'"))
		}
	}
	Ok(($fields, $pos + 1))
}

parse_key : List(U8), U64, Value.Limits -> Try((Str, U64), Fail)
parse_key = |src, pos, limits| {
	c = at(src, pos)
	if c == '"' {
		if starts_at(src, pos, "\"\"\"") {
			Err({ code: ErrorCode.block_string_key, reason: "block strings can't be record keys", pos })
		} else {
			parse_basic_string(src, pos, limits)
		}
	} else if is_lower_start(c) {
		name(src, pos, "key", limits)
	} else if is_upper(c) {
		(word, _) = read_ident(src, pos)
		Err({ code: ErrorCode.uppercase_key, reason: "record keys must start with a lowercase letter or '_'; quote it: \"${word}\"", pos })
	} else {
		Err({ code: ErrorCode.expected_key, reason: "expected a record key, found ${describe(src, pos)}", pos })
	}
}

## `open value, value, ... close` with an optional trailing comma.
parse_list : List(U8), U64, U64, U8, Value.Limits -> Try((List(Value), U64), Fail)
parse_list = |src, open, depth, close, limits| {
	if depth + 1 > limits.max_depth {
		return Err(nesting_error(limits, open))
	}
	var $items = []
	var $pos = skip_trivia(src, open + 1)?
	while at(src, $pos) != close {
		if $pos >= src.len() {
			return Err(unclosed(src, open))
		}
		(value, after) = parse_value(src, $pos, depth + 1, limits)?
		$items = $items.append(value)
		p = skip_trivia(src, after)?
		if at(src, p) == ',' {
			$pos = skip_trivia(src, p + 1)?
		} else if at(src, p) == close {
			$pos = p
		} else if p >= src.len() {
			return Err(unclosed(src, open))
		} else {
			return Err(separator(src, p, value, "expected ',' or '${byte_str(close)}'"))
		}
	}
	Ok(($items, $pos + 1))
}

parse_variant : List(U8), U64, U64, Value.Limits -> Try((Value, U64), Fail)
parse_variant = |src, pos, depth, limits| {
	(tag, after_tag) = name(src, pos, "tag", limits)?
	# The payload must follow on the same line: only spaces and tabs in between.
	var $p = after_tag
	while at(src, $p) == ' ' or at(src, $p) == '\t' {
		$p = $p + 1
	}
	p = $p
	if at(src, p) == '(' {
		(args, after) = parse_list(src, p, depth, ')', limits)?
		if args.is_empty() {
			Err({ code: ErrorCode.empty_payload, reason: "empty payload: write '${tag}' without parentheses", pos: p })
		} else {
			Ok((Tag(tag, args), after))
		}
	} else if at(src, p) == '{' {
		(fields, after) = parse_record(src, p, depth, limits)?
		Ok((Tag(tag, [Rec(fields)]), after))
	} else {
		Ok((Tag(tag, []), after_tag))
	}
}

# ── numbers ──────────────────────────────────────────────────

parse_number : List(U8), U64, Value.Limits -> Try((Value, U64), Fail)
parse_number = |src, start, limits| {
	# Checked in the reference's order: the literal (a linear scan), what
	# follows it, its length, its exponent. Converted only then, so huge
	# literals stay cheap.
	neg = at(src, start) == '-'
	digits_start = if (neg) start + 1 else start
	radix = if (starts_at(src, digits_start, "0x")) 16 else if (starts_at(src, digits_start, "0b")) 2 else 10
	is_valid = |b| if (radix == 16) is_hex(b) else b == '0' or b == '1'
	end =
		if radix == 10 {
			decimal_end(src, start, digits_start)?
		} else {
			digit_run(src, digits_start + 2, is_valid).map_err(|_| invalid_number(src, start))?
		}
	next = at(src, end)
	if is_ident_char(next) or next == '.' {
		return Err(invalid_number(src, start))
	}
	if end - start > limits.max_number_length {
		return Err({ code: ErrorCode.number_too_long, reason: "number literal longer than ${limits.max_number_length.to_str()} characters", pos: start })
	}
	if radix == 10 and exponent_larger(src.sublist({ start, len: end - start }), limits.max_exponent) {
		return Err({ code: ErrorCode.exponent_too_large, reason: "exponent larger than ${limits.max_exponent.to_str()}", pos: start })
	}
	text = if (radix == 10) decimal_text(src, start, end) else radix_text(src, digits_start + 2, end, radix, neg)
	Ok((Num(text), end))
}

## Digits with optional single `_` between them. Returns the end position.
digit_run : List(U8), U64, (U8 -> Bool) -> Try(U64, {})
digit_run = |src, start, is_valid| {
	if !is_valid(at(src, start)) {
		return Err({})
	}
	var $p = start + 1
	var $go = True
	while $go {
		c = at(src, $p)
		if is_valid(c) {
			$p = $p + 1
		} else if c == '_' and is_valid(at(src, $p + 1)) {
			$p = $p + 2
		} else {
			$go = False
		}
	}
	Ok($p)
}

## `invalid number '0x'`, at the start of the literal, like the other bindings.
invalid_number : List(U8), U64 -> Fail
invalid_number = |src, start| {
	var $e = start + 1
	while is_ident_char(at(src, $e)) or at(src, $e) == '.' {
		$e = $e + 1
	}
	{ code: ErrorCode.invalid_number, reason: "invalid number '${slice_str(src, start, $e)}'", pos: start }
}

## Where the decimal literal at `start` (digits from `digits_start`) ends:
## `int frac? exp?`, each part only if it is complete.
decimal_end : List(U8), U64, U64 -> Try(U64, Fail)
decimal_end = |src, start, digits_start| {
	bad = |_| { code: ErrorCode.invalid_number, reason: "invalid number", pos: start }
	int_end =
		if at(src, digits_start) == '0' {
			digits_start + 1
		} else if is_nonzero_digit(at(src, digits_start)) {
			digit_run(src, digits_start, is_digit).map_err(bad)?
		} else {
			return Err(bad({}))
		}
	frac_end =
		if at(src, int_end) == '.' and is_digit(at(src, int_end + 1)) {
			digit_run(src, int_end + 1, is_digit).map_err(bad)?
		} else {
			int_end
		}
	c = at(src, frac_end)
	if c == 'e' or c == 'E' {
		sign = at(src, frac_end + 1)
		exp_start = if (sign == '+' or sign == '-') frac_end + 2 else frac_end + 1
		Ok(digit_run(src, exp_start, is_digit) ?? frac_end)
	} else {
		Ok(frac_end)
	}
}

## The normalized text of a decimal literal (spec §2): without `_`, the
## exponent as its value.
decimal_text : List(U8), U64, U64 -> Str
decimal_text = |src, start, end| {
	text = src
		.sublist({ start, len: end - start })
		.keep_if(|b| b != '_')
		.map(|b| if (b == 'E') 'e' else b)
	bytes_to_str(normalize_exponent(text))
}

## Whether a decimal literal's exponent is larger than `max`.
exponent_larger : List(U8), U64 -> Bool
exponent_larger = |literal, max| match literal.find_first_index(|b| b == 'e' or b == 'E') {
	Err(_) => False
	Ok(i) => {
		var $exp = 0
		for b in literal.drop_first(i + 1) {
			if is_digit(b) {
				$exp = $exp * 10 + (b - '0').to_u64()
				if $exp > max {
					return True
				}
			}
		}
		False
	}
}

## The exponent of a decimal literal as its value (§2): `1e+05` is `1e5`, `1e-0` is `1e0`.
normalize_exponent : List(U8) -> List(U8)
normalize_exponent = |text| {
	var $at = 0
	while $at < text.len() and at(text, $at) != 'e' {
		$at = $at + 1
	}
	if $at == text.len() {
		return text
	}
	mantissa = text.sublist({ start: 0, len: $at + 1 })
	rest = text.sublist({ start: $at + 1, len: text.len() - $at - 1 })
	negative = at(rest, 0) == '-'
	var $p = if (at(rest, 0) == '+' or negative) 1 else 0
	while $p + 1 < rest.len() and at(rest, $p) == '0' {
		$p = $p + 1
	}
	digits = rest.sublist({ start: $p, len: rest.len() - $p })
	sign = if (negative and digits != ['0']) ['-'] else []
	mantissa.concat(sign).concat(digits)
}

## Hex or binary digits from `start` to `end`, converted to a decimal integer of any size.
radix_text : List(U8), U64, U64, U64, Bool -> Str
radix_text = |src, start, end, radix, neg| {
	# Little-endian decimal digits; multiply by radix and add each digit.
	var $decimal = [0]
	for b in src.sublist({ start, len: end - start }) {
		if b != '_' {
			$decimal = mul_add($decimal, radix, hex_value(b))
		}
	}
	digits = bytes_to_str(reverse($decimal).map(|d| d.to_u8_wrap() + '0'))
	sign = if (neg and digits != "0") "-" else ""
	"${sign}${digits}"
}

mul_add : List(U64), U64, U64 -> List(U64)
mul_add = |digits, factor, add| {
	var $carry = add
	var $out = []
	for d in digits {
		v = d * factor + $carry
		$out = $out.append(v % 10)
		$carry = v // 10
	}
	while $carry > 0 {
		$out = $out.append($carry % 10)
		$carry = $carry // 10
	}
	$out
}

# ── strings ──────────────────────────────────────────────────

## Raw bidirectional controls (U+202A–U+202E, U+2066–U+2069, "Trojan Source")
## are not allowed outside escapes. In UTF-8: E2 80 AA–AE and E2 81 A6–A9.
bidi_at : List(U8), U64 -> Bool
bidi_at = |src, p|
	if at(src, p) != 0xE2 {
		False
	} else {
		b1 = at(src, p + 1)
		b2 = at(src, p + 2)
		(b1 == 0x80 and b2 >= 0xAA and b2 <= 0xAE) or (b1 == 0x81 and b2 >= 0xA6 and b2 <= 0xA9)
	}

## Raw control characters (C0, DEL, C1: U+0000–U+001F, U+007F, U+0080–U+009F)
## are allowed outside escapes only as tab and line breaks, where the grammar
## says. In UTF-8, C1 is C2 80–9F.
control_at : List(U8), U64 -> Bool
control_at = |src, p| {
	c = at(src, p)
	c < 0x20 or c == 0x7F or (c == 0xC2 and at(src, p + 1) >= 0x80 and at(src, p + 1) <= 0x9F)
}

## A control character that is allowed in comments: tab, LF, and CR before LF.
comment_control_ok : List(U8), U64 -> Bool
comment_control_ok = |src, p| {
	c = at(src, p)
	c == '\t' or c == '\n' or (c == '\r' and at(src, p + 1) == '\n')
}

control_error : U64, Str -> Fail
control_error = |pos, place| { code: ErrorCode.control_character, reason: "raw control character in ${place} (write it as an escape, e.g. \\u{1B})", pos }

## A control character in a comment that isn't allowed there: a carriage
## return without a line feed, or another control character.
comment_error : List(U8), U64 -> Fail
comment_error = |src, pos|
	if at(src, pos) == '\r' {
		lone_cr(pos)
	} else {
		control_error(pos, "comment")
	}

lone_cr : U64 -> Fail
lone_cr = |pos| { code: ErrorCode.lone_carriage_return, reason: "carriage return without a line feed (line breaks are LF or CRLF)", pos }

bidi_error : U64 -> Fail
bidi_error = |pos| { code: ErrorCode.bidi_control, reason: "raw bidirectional control character (write it as an escape, e.g. \\u{202E})", pos }

check_string_length : List(U8), U64, Value.Limits -> Try({}, Fail)
check_string_length = |bytes, open, limits| {
	# Count code points: every byte that isn't a UTF-8 continuation byte.
	chars = bytes.keep_if(|b| b < 0x80 or b >= 0xC0).len()
	if chars > limits.max_string_length {
		Err({ code: ErrorCode.string_too_long, reason: "string longer than ${limits.max_string_length.to_str()} characters", pos: open })
	} else {
		Ok({})
	}
}

parse_basic_string : List(U8), U64, Value.Limits -> Try((Str, U64), Fail)
parse_basic_string = |src, open, limits| {
	var $out = []
	var $pos = open + 1
	while at(src, $pos) != '"' {
		if $pos >= src.len() {
			return Err({ code: ErrorCode.unterminated_string, reason: "unterminated string", pos: open })
		}
		c = at(src, $pos)
		if c == '\\' {
			(bytes, after) = read_escape(src, $pos)?
			$out = $out.concat(bytes)
			$pos = after
		} else if c == '\n' {
			return Err({ code: ErrorCode.string_line_break, reason: "line break in string (use \\n or a \"\"\" block string)", pos: $pos })
		} else if c == '\t' {
			return Err({ code: ErrorCode.control_character, reason: "raw tab in string (use \\t)", pos: $pos })
		} else if control_at(src, $pos) {
			return Err(control_error($pos, "string"))
		} else if bidi_at(src, $pos) {
			return Err(bidi_error($pos))
		} else {
			$out = $out.append(c)
			$pos = $pos + 1
		}
	}
	check_string_length($out, open, limits)?
	Ok((bytes_to_str($out), $pos + 1))
}

## At a backslash. Returns the escaped bytes and the position after the escape.
read_escape : List(U8), U64 -> Try((List(U8), U64), Fail)
read_escape = |src, start| {
	e = at(src, start + 1)
	if e == '"' {
		Ok((['"'], start + 2))
	} else if e == '\\' {
		Ok((['\\'], start + 2))
	} else if e == 'n' {
		Ok((['\n'], start + 2))
	} else if e == 'r' {
		Ok((['\r'], start + 2))
	} else if e == 't' {
		Ok((['\t'], start + 2))
	} else if e == 'u' {
		# Also `\\u0041` without braces, as JSON writes it.
		bad = { code: ErrorCode.invalid_unicode_escape, reason: "invalid unicode escape: expected \\u{1-6 hex digits}", pos: start }
		if at(src, start + 2) != '{' {
			return Err(bad)
		}
		var $p = start + 3
		var $cp = 0
		while is_hex(at(src, $p)) and $p - (start + 3) < 6 {
			$cp = $cp * 16 + hex_value(at(src, $p))
			$p = $p + 1
		}
		if $p == start + 3 or at(src, $p) != '}' {
			return Err(bad)
		}
		if $cp > 0x10FFFF or ($cp >= 0xD800 and $cp <= 0xDFFF) {
			return Err({ code: ErrorCode.invalid_unicode_escape, reason: "\\u{${slice_str(src, start + 3, $p)}} is not a Unicode scalar value", pos: start })
		}
		Ok((utf8_encode($cp), $p + 1))
	} else {
		Err({ code: ErrorCode.invalid_escape, reason: "invalid escape '\\${byte_str(e)}'", pos: start })
	}
}

parse_block_string : List(U8), U64, Value.Limits -> Try((Str, U64), Fail)
parse_block_string = |src, open, limits| {
	var $p = open + 3
	while at(src, $p) == ' ' or at(src, $p) == '\t' {
		$p = $p + 1
	}
	content_start =
		if starts_at(src, $p, "\r\n") {
			$p + 2
		} else if at(src, $p) == '\n' {
			$p + 1
		} else {
			return Err({ code: ErrorCode.block_string_opening, reason: "opening \"\"\" must be followed by a line break", pos: if ($p >= src.len()) open else $p })
		}

	# Find the closing """, skipping escaped characters.
	var $i = content_start
	var $close = src.len()
	while $i < src.len() {
		if at(src, $i) == '\\' {
			$i = $i + 2
		} else if starts_at(src, $i, "\"\"\"") {
			$close = $i
			$i = src.len()
		} else {
			$i = $i + 1
		}
	}
	if $close == src.len() {
		return Err({ code: ErrorCode.unterminated_block_string, reason: "unterminated block string", pos: open })
	}

	# Lines as (start, end) ranges; CR before LF is dropped.
	var $lines = []
	var $line_start = content_start
	var $j = content_start
	while $j < $close {
		if at(src, $j) == '\n' {
			end = if ($j > $line_start and at(src, $j - 1) == '\r') $j - 1 else $j
			$lines = $lines.append(($line_start, end))
			$line_start = $j + 1
		}
		$j = $j + 1
	}
	indent_bytes = src.sublist({ start: $line_start, len: $close - $line_start })
	if !is_blank(indent_bytes) {
		return Err({ code: ErrorCode.block_string_closing, reason: "closing \"\"\" must be on its own line", pos: $close })
	}
	indent_len = indent_bytes.len()

	var $out = []
	var $first = True
	for (s, e) in $lines {
		line = src.sublist({ start: s, len: e - s })
		decoded =
			if line.starts_with(indent_bytes) {
				decode_block_line(src, s + indent_len, e)?
			} else if is_blank(line) {
				[]
			} else {
				return Err({ code: ErrorCode.block_string_indent, reason: "line is indented less than the closing \"\"\"", pos: s })
			}
		$out = if ($first) $out.concat(decoded) else $out.append('\n').concat(decoded)
		$first = False
	}
	check_string_length($out, open, limits)?
	Ok((bytes_to_str($out), $close + 3))
}

decode_block_line : List(U8), U64, U64 -> Try(List(U8), Fail)
decode_block_line = |src, start, end| {
	var $out = []
	var $p = start
	while $p < end {
		c = at(src, $p)
		if c == '\\' {
			(bytes, after) = read_escape(src, $p)?
			$out = $out.concat(bytes)
			$p = after
		} else if c != '\t' and control_at(src, $p) {
			return Err(control_error($p, "block string"))
		} else if bidi_at(src, $p) {
			return Err(bidi_error($p))
		} else {
			$out = $out.append(c)
			$p = $p + 1
		}
	}
	Ok($out)
}

# ── byte strings ─────────────────────────────────────────

## `x"9f86 d081"`: two hex digits per byte, spaces and tabs between bytes.
parse_bytes_literal : List(U8), U64, Value.Limits -> Try((List(U8), U64), Fail)
parse_bytes_literal = |src, start, limits| {
	open = start + 1
	var $out = []
	var $pos = open + 1
	while at(src, $pos) != '"' {
		c = at(src, $pos)
		if $pos >= src.len() {
			return Err({ code: ErrorCode.unterminated_bytes, reason: "unterminated byte string", pos: start })
		} else if c == ' ' or c == '\t' {
			$pos = $pos + 1
		} else if c == '\n' or c == '\r' {
			return Err({ code: ErrorCode.bytes_not_hex, reason: "line break in byte string", pos: $pos })
		} else if is_hex(c) {
			d = at(src, $pos + 1)
			if $pos + 1 >= src.len() {
				return Err({ code: ErrorCode.unterminated_bytes, reason: "unterminated byte string", pos: start })
			}
			if !is_hex(d) {
				return Err({ code: ErrorCode.bytes_odd_digits, reason: "incomplete byte in byte string: two hex digits per byte", pos: $pos })
			}
			$out = $out.append((hex_value(c) * 16 + hex_value(d)).to_u8_wrap())
			$pos = $pos + 2
		} else {
			return Err({ code: ErrorCode.bytes_not_hex, reason: "invalid character ${describe(src, $pos)} in byte string (only hex digits, spaces and tabs)", pos: $pos })
		}
	}
	# Same limit as strings, counted over the literal's characters (all ASCII).
	if $pos - (open + 1) > limits.max_string_length {
		return Err({ code: ErrorCode.string_too_long, reason: "byte string longer than ${limits.max_string_length.to_str()} characters", pos: start })
	}
	Ok(($out, $pos + 1))
}

hex_lower : List(U8) -> Str
hex_lower = |bytes| {
	digits = "0123456789abcdef".to_utf8()
	var $out = []
	for b in bytes {
		$out = $out.append(at(digits, (b // 16).to_u64())).append(at(digits, (b % 16).to_u64()))
	}
	bytes_to_str($out)
}

# ── trivia ───────────────────────────────────────────────────

skip_trivia : List(U8), U64 -> Try(U64, Fail)
skip_trivia = |src, start| {
	var $p = start
	var $go = True
	while $go {
		c = at(src, $p)
		if c == ' ' or c == '\t' or c == '\n' {
			$p = $p + 1
		} else if c == '\r' and at(src, $p + 1) == '\n' {
			$p = $p + 2
		} else if c == '\r' {
			return Err(lone_cr($p))
		} else if c == '/' and at(src, $p + 1) == '/' {
			while $p < src.len() and at(src, $p) != '\n' {
				if bidi_at(src, $p) {
					return Err(bidi_error($p))
				}
				if control_at(src, $p) and !comment_control_ok(src, $p) {
					return Err(comment_error(src, $p))
				}
				$p = $p + 1
			}
		} else if c == '/' and at(src, $p + 1) == '*' {
			$p = skip_block_comment(src, $p)?
		} else if c == '/' {
			return Err({ code: ErrorCode.stray_slash, reason: "unexpected '/' (comments are // or /* */)", pos: $p })
		} else {
			$go = False
		}
	}
	Ok($p)
}

skip_block_comment : List(U8), U64 -> Try(U64, Fail)
skip_block_comment = |src, open| {
	var $depth = 0
	var $p = open
	while $p < src.len() {
		if starts_at(src, $p, "/*") {
			$depth = $depth + 1
			$p = $p + 2
		} else if starts_at(src, $p, "*/") {
			$depth = $depth - 1
			$p = $p + 2
			if $depth == 0 {
				return Ok($p)
			}
		} else if bidi_at(src, $p) {
			return Err(bidi_error($p))
		} else if control_at(src, $p) and !comment_control_ok(src, $p) {
			return Err(comment_error(src, $p))
		} else {
			$p = $p + 1
		}
	}
	Err({ code: ErrorCode.unterminated_comment, reason: "unterminated block comment", pos: open })
}

# ── helpers ──────────────────────────────────────────────────

reverse : List(a) -> List(a)
reverse = |list| {
	var $out = []
	for x in list {
		$out = [x].concat($out)
	}
	$out
}

## The byte at `pos`, or 0 past the end (0 never matches anything we look for).
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

## An identifier key or a tag (`what`) at `start`, within the string limit
## (spec §7). Identifiers are ASCII: one byte is one character.
name : List(U8), U64, Str, Value.Limits -> Try((Str, U64), Fail)
name = |src, start, what, limits| {
	(word, end) = read_ident(src, start)
	if end - start > limits.max_string_length {
		code = if (what == "key") ErrorCode.key_too_long else ErrorCode.tag_too_long
		Err({ code, reason: "${what} longer than ${limits.max_string_length.to_str()} characters", pos: start })
	} else {
		Ok((word, end))
	}
}

read_ident : List(U8), U64 -> (Str, U64)
read_ident = |src, start| {
	var $p = start
	while is_ident_char(at(src, $p)) {
		$p = $p + 1
	}
	(slice_str(src, start, $p), $p)
}

is_digit = |b| b >= '0' and b <= '9'

is_nonzero_digit = |b| b >= '1' and b <= '9'

is_upper = |b| b >= 'A' and b <= 'Z'

is_lower_start = |b| (b >= 'a' and b <= 'z') or b == '_'

is_ident_char = |b| is_digit(b) or is_upper(b) or is_lower_start(b)

is_hex = |b| is_digit(b) or (b >= 'a' and b <= 'f') or (b >= 'A' and b <= 'F')

is_blank = |bytes| bytes.all(|b| b == ' ' or b == '\t')

hex_value : U8 -> U64
hex_value = |b|
	if b >= 'a' {
		(b - 'a').to_u64() + 10
	} else if b >= 'A' {
		(b - 'A').to_u64() + 10
	} else {
		(b - '0').to_u64()
	}

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

slice_str : List(U8), U64, U64 -> Str
slice_str = |src, start, end| bytes_to_str(src.sublist({ start, len: end - start }))

byte_str : U8 -> Str
byte_str = |b| bytes_to_str([b])

describe : List(U8), U64 -> Str
describe = |src, pos|
	if pos >= src.len() {
		"end of input"
	} else if at(src, pos) == '\n' {
		"line break"
	} else {
		"'${byte_str(at(src, pos))}'"
	}

## Line and column (1-based, in code points) of a byte position.
locate : List(U8), Fail -> ParseError
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

json_str : Str -> Str
json_str = |s| {
	var $out = ['"']
	for b in s.to_utf8() {
		$out =
			if b == '"' {
				$out.concat(['\\', '"'])
			} else if b == '\\' {
				$out.concat(['\\', '\\'])
			} else if b == '\n' {
				$out.concat(['\\', 'n'])
			} else if b == '\r' {
				$out.concat(['\\', 'r'])
			} else if b == '\t' {
				$out.concat(['\\', 't'])
			} else if b < 0x20 {
				# Other C0 controls as JSON writes them: \u001b
				$out.concat(['\\', 'u', '0', '0', hex_digit(b // 16), hex_digit(b % 16)])
			} else {
				$out.append(b)
			}
	}
	bytes_to_str($out.append('"'))
}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'a' + n - 10

# A version directive (spec §10) needs a newer version of haus; anywhere else `#` is a syntax error.
expect Value.parse_all("#haus 2\n{ a: 1 }").map_ok(|vs| vs.len()) == Err({ code: "version-directive", reason: "the file starts with a version directive (#haus): it needs a newer version of haus", line: 1, column: 1 })
expect Value.parse_all("\u(FEFF)#haus 2\n1").map_ok(|vs| vs.len()) == Err({ code: "version-directive", reason: "the file starts with a version directive (#haus): it needs a newer version of haus", line: 1, column: 2 })
expect Value.parse_all(" #haus 2").map_ok(|vs| vs.len()).map_err(|e| e.reason) == Err("expected a value, found '#'")

# Your own limits (`parse_all_with`): each at the limit, and just past it.
small : Value.Limits
small = { max_depth: 3, max_number_length: 8, max_exponent: 99, max_string_length: 4 }

within_small : Str -> Try(U64, Str)
within_small = |text| Value.parse_all_with(text, small).map_ok(|vs| vs.len()).map_err(|e| "${e.code}: ${e.reason} at ${e.line.to_str()}:${e.column.to_str()}")

expect within_small("[[[1]]], { a: { b: [] } }, A(B(C(1))), A { b: B { c: [] } }") == Ok(4)
expect within_small("[[[[1]]]]") == Err("nesting-too-deep: nesting deeper than 3 levels at 1:4")
expect within_small("A(B(C(D(1))))") == Err("nesting-too-deep: nesting deeper than 3 levels at 1:8")
expect within_small("{ a: { b: { c: {} } } }") == Err("nesting-too-deep: nesting deeper than 3 levels at 1:16")
expect within_small("12345678, -1234567, 1_234_56, 0xFFFFFF") == Ok(4)
expect within_small("123456789") == Err("number-too-long: number literal longer than 8 characters at 1:1")
expect within_small("1e99, 1e-99") == Ok(2)
expect within_small("1e100") == Err("exponent-too-large: exponent larger than 99 at 1:1")
expect within_small("\"abcd\", \"éééé\", \"a\\u{1F600}cd\", x\"abcd\", x\"ab\"") == Ok(5)
expect within_small("\"abcde\"") == Err("string-too-long: string longer than 4 characters at 1:1")
expect within_small("\"\"\"\n  abcde\n  \"\"\"") == Err("string-too-long: string longer than 4 characters at 1:1")
# A byte string counts the characters between its quotes, spaces too.
expect within_small("x\"abcdef\"") == Err("string-too-long: byte string longer than 4 characters at 1:1")
expect within_small("x\"ab cd\"") == Err("string-too-long: byte string longer than 4 characters at 1:1")
expect Value.parse_with("[[[1]]]", small).is_ok() and Value.parse_with("[[[[1]]]]", small).is_err()
expect Value.parse_bytes_with("12345678".to_utf8(), small).is_ok() and Value.parse_bytes_with("123456789".to_utf8(), small).is_err()
# Record keys and tags count against the string limit: an identifier key or a
# tag where it starts; a quoted key is a string.
expect within_small("{ abcd: 1 }, { \"abcd\": 1 }, Abcd, Abcd(1), Abcd { a: 1 }") == Ok(5)
expect within_small("{ abcde: 1 }") == Err("key-too-long: key longer than 4 characters at 1:3")
expect within_small("{ a: 1, abcde: 1 }") == Err("key-too-long: key longer than 4 characters at 1:9")
expect within_small("{ \"abcde\": 1 }") == Err("string-too-long: string longer than 4 characters at 1:3")
expect within_small("[Abcde]") == Err("tag-too-long: tag longer than 4 characters at 1:2")
expect within_small("[1, Abcde(1)]") == Err("tag-too-long: tag longer than 4 characters at 1:5")
expect within_small("Abcde { a: 1 }") == Err("tag-too-long: tag longer than 4 characters at 1:1")
# Larger limits than the defaults, up to the supported depth.
expect Value.parse_all_with("${"[".repeat(300)}${"]".repeat(300)}, 1e7000", { ..Value.default_limits, max_depth: 300, max_exponent: 7000 }).is_ok()
deepest : Value.Limits
deepest = { ..Value.default_limits, max_depth: Value.max_supported_depth }
expect Value.parse_with("${"A(".repeat(1024)}1${")".repeat(1024)}", deepest).is_ok()
expect Value.parse_with("${"{ a: ".repeat(1024)}1${" }".repeat(1024)}", deepest).is_ok()
expect Value.parse_with("${"A { a: ".repeat(1024)}1${" }".repeat(1024)}", deepest).is_ok()
expect Value.parse_with("${"[".repeat(1025)}1${"]".repeat(1025)}", deepest).map_ok(|_| {}).map_err(|e| e.reason) == Err("nesting deeper than 1024 levels")
# A deeper limit than this binding supports is an error that names the maximum, at the start.
too_deep : Value.Limits
too_deep = { ..Value.default_limits, max_depth: 1025 }
expect Value.check_limits(deepest) == Ok({}) and Value.check_limits(too_deep) == Err("max_depth 1025 is more than the supported maximum, 1024")
expect Value.parse_all_with("[]", too_deep).map_ok(|_| {}) == Err({ code: "unsupported-depth", reason: "max_depth 1025 is more than the supported maximum, 1024", line: 1, column: 1 })
expect Value.parse_with("", too_deep).is_err() and Value.parse_bytes_with([], too_deep).is_err() and Value.parse_rest_with("1", too_deep).is_err()
expect Value.parse_all("${"[".repeat(256)}${"]".repeat(256)}").is_ok() and Value.parse_all("${"[".repeat(257)}${"]".repeat(257)}").is_err()

# Error codes (spec §17), decided as the reference parser decides.
code_at : Str -> Str
code_at = |text| match Value.parse_all(text) {
	Ok(_) => "ok"
	Err(e) => "${e.code} at ${e.line.to_str()}:${e.column.to_str()}"
}

# After a value: a payload on a later line, a closing bracket, or a missing comma.
expect code_at("Heartbeat\n{ at: 1 }") == "payload-newline at 2:1"
expect code_at("[A /* c */ (1)]") == "payload-newline at 1:12"
expect code_at("[A(1)\n(2)]") == "missing-comma at 2:1"
expect code_at("[1 }") == "unexpected-closer at 1:4" and code_at("{ a: 1 ]") == "unexpected-closer at 1:8" and code_at("1 )") == "unexpected-closer at 1:3"
expect code_at("[1 2]") == "missing-comma at 1:4" and code_at("{ a: 1 b: 2 }") == "missing-comma at 1:8" and code_at("1 2") == "missing-comma at 1:3"
# Where a value should be: `+` and `.` start numbers elsewhere; lowercase words.
expect code_at("+1") == "invalid-number at 1:1" and code_at("[.5]") == "invalid-number at 1:2" and code_at("{ a: }") == "expected-value at 1:6"
expect code_at("null") == "null-literal at 1:1" and code_at("[true]") == "boolean-literal at 1:2" and code_at("false") == "boolean-literal at 1:1" and code_at("{ a: nil }") == "bare-identifier at 1:6"
# Comments and escapes.
expect code_at("/* a\rb */ 1") == "lone-carriage-return at 1:5" and code_at("// a\rb\n1") == "lone-carriage-return at 1:5" and code_at("1 \r") == "lone-carriage-return at 1:3"
expect code_at("/* \u(1B) */ 1") == "control-character at 1:4" and code_at("/* 1") == "unterminated-comment at 1:1" and code_at("1 / 2") == "stray-slash at 1:3"
expect code_at("\"\\u0041\"") == "invalid-unicode-escape at 1:2" and code_at("\"\\u{D800}\"") == "invalid-unicode-escape at 1:2" and code_at("\"\\x\"") == "invalid-escape at 1:2"
# Numbers: the literal, what follows it, its length, its exponent.
expect code_at("1.") == "invalid-number at 1:1" and code_at("007") == "invalid-number at 1:1" and code_at("0x") == "invalid-number at 1:1"
expect Value.parse_all_with("123456789x", small).map_ok(|_| {}).map_err(|e| e.code) == Err("invalid-number")
expect Value.parse_all_with("1234567e100", small).map_ok(|_| {}).map_err(|e| e.code) == Err("number-too-long")
expect Value.parse_all_with("1e100", small).map_ok(|_| {}).map_err(|e| e.code) == Err("exponent-too-large") and Value.parse_all_with("0xe100", small).is_ok()
# Byte strings: an odd digit before the closing quote, or the input ending.
expect code_at("x\"abc\"") == "bytes-odd-digits at 1:5" and code_at("x\"ab\nc\"") == "bytes-not-hex at 1:5" and code_at("x\"ag\"") == "bytes-odd-digits at 1:3"
expect code_at("x\"a") == "unterminated-bytes at 1:1" and code_at("x\"ab") == "unterminated-bytes at 1:1"
# Strings, keys, records.
expect code_at("\"a\nb\"") == "string-line-break at 1:3" and code_at("\"a\tb\"") == "control-character at 1:3" and code_at("\"\u(202E)\"") == "bidi-control at 1:2"
expect code_at("{ A: 1 }") == "uppercase-key at 1:3" and code_at("{ 1: 1 }") == "expected-key at 1:3" and code_at("{ a 1 }") == "missing-colon at 1:5"
expect code_at("{ a: 1, a: 2 }") == "duplicate-key at 1:9" and code_at("{ \"\"\"\n\"\"\": 1 }") == "block-string-key at 1:3" and code_at("[1, 2") == "unclosed-bracket at 1:1"
expect code_at("A()") == "empty-payload at 1:2" and code_at("\"\"\"x\n\"\"\"") == "block-string-opening at 1:4" and code_at("\"\"\"\n  a\n b\"\"\"") == "block-string-closing at 3:3"
# Invalid UTF-8 is reported where it is; exactly one value where one is expected.
expect Value.parse_bytes([0x5B, 0x31, 0x0A, 0x22, 0xFF, 0x22, 0x5D]).map_ok(|_| {}).map_err(|e| (e.code, e.line, e.column)) == Err(("invalid-utf8", 2, 2))
expect Value.parse("1, 2").map_ok(|_| {}).map_err(|e| e.code) == Err("not-one-value") and Value.parse("").map_ok(|_| {}).map_err(|e| e.code) == Err("not-one-value")
expect Value.parse_all("[1 2]").map_ok(|_| {}).map_err(Value.error_json) == Err("{\"code\":\"missing-comma\",\"message\":\"expected ',' or ']', found '2'\",\"line\":1,\"column\":4,\"hint\":\"Add a comma between the two values.\",\"docs\":\"https://haus-fmt.org/docs/errors#missing-comma\"}")
