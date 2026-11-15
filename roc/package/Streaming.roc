## Streams (spec §6): a file of values, each followed by a comma, read as
## the values arrive.
##
## The reader does no I/O: push chunks of bytes, split anywhere, and get
## every value that is complete. Memory holds the current value, not the
## stream. The same reader as the TypeScript and Rust bindings.
##
##     var $reader = Streaming.reader(Streaming.defaults)
##     (next, values) = Streaming.push($reader, chunk)?
##     $reader = next
##     …
##     last = Streaming.finish($reader)?
import ErrorCode
import Value

Streaming := [].{

	## A reader's state.
	Reader : {
		buf : List(U8),
		scanned : U64,
		chars : U64,
		mode : Mode,
		depth : U64,
		origin : Pos,
		started : Bool,
		options : Options,
	}

	## `limits`: the parser's limits for each value (spec §7, see `Value.Limits`).
	## `max_value_length`: the most characters in one value (spec §7: 64 Mi).
	## `require_terminator`: a stream that ends without a comma after its last
	## value is reported as cut off (recommended for network streams).
	##
	##     Streaming.reader({ ..Streaming.defaults, limits: { ..Value.default_limits, max_depth: 64 } })
	Options : { limits : Value.Limits, max_value_length : U64, require_terminator : Bool }

	defaults : Options
	defaults = { limits: Value.default_limits, max_value_length: 64 * 1024 * 1024, require_terminator: False }

	reader : Options -> Reader
	reader = |options| {
		buf: [],
		scanned: 0,
		chars: 0,
		mode: Normal,
		depth: 0,
		origin: { line: 1, column: 1 },
		started: False,
		options,
	}

	## Add a chunk; returns the reader and the values the chunk completed.
	## Fails at once if `options.limits` has a deeper `max_depth` than
	## `Value.max_supported_depth`.
	push : Reader, List(U8) -> Try((Reader, List(Value)), Value.ParseError)
	push = |state, chunk| {
		supported(state.options.limits)?
		buf = state.buf.concat(chunk)
		if !state.started and buf.len() < 3 and [0xEF, 0xBB, 0xBF].starts_with(buf) {
			return Ok(({ ..state, buf }, [])) # maybe a byte order mark: wait for more
		}
		started =
			if !state.started and buf.starts_with([0xEF, 0xBB, 0xBF]) {
				# The byte order mark is column 1, as in the whole-text parser.
				{ ..state, buf: buf.drop_first(3), origin: { ..state.origin, column: 2 }, started: True }
			} else {
				{ ..state, buf, started: True }
			}
		scan(started, False)
	}

	## The input is complete: returns the last value, if it had no comma after it.
	finish : Reader -> Try(List(Value), Value.ParseError)
	finish = |state| {
		supported(state.options.limits)?
		(rest, values) = scan(state, True)?
		text = utf8(rest.buf, rest.origin)?
		directive(text, rest.origin)?
		last = Value.parse_rest_with(text, rest.options.limits).map_err(|e| shift(e, rest.origin))?
		if !last.is_empty() and rest.options.require_terminator {
			end = after(rest.origin, rest.buf)
			return Err({ code: ErrorCode.stream_truncated, reason: "stream ended without ',' after the last value (truncated?)", line: end.line, column: end.column })
		}
		Ok(values.concat(last))
	}

	## Read a whole input given as chunks.
	all : List(List(U8)) -> Try(List(Value), Value.ParseError)
	all = |chunks| {
		var $state = reader(defaults)
		var $out = []
		for chunk in chunks {
			(next, values) = push($state, chunk)?
			$state = next
			$out = $out.concat(values)
		}
		Ok($out.concat(finish($state)?))
	}
}

## Whether this binding supports `limits` (spec §7), as an error at the start.
supported : Value.Limits -> Try({}, Value.ParseError)
supported = |limits| Value.check_limits(limits).map_err(|reason| { code: ErrorCode.unsupported_depth, reason, line: 1, column: 1 })

## What the scanner is inside of. It only tracks what it needs to find the
## commas between values; the parser checks everything else.
Mode : [Normal, Text, Block, LineComment, Comment(U64)]

Pos : { line : U64, column : U64 }

## Finds the commas between values and parses what is before them.
scan : Streaming.Reader, Bool -> Try((Streaming.Reader, List(Value)), Value.ParseError)
scan = |start, last| {
	var $s = start
	var $out = []
	var $i = $s.scanned
	var $go = True
	while $go and $i < $s.buf.len() {
		if $s.chars > $s.options.max_value_length {
			return Err({ code: ErrorCode.value_too_long, reason: "value longer than ${$s.options.max_value_length.to_str()} characters", line: $s.origin.line, column: $s.origin.column })
		}
		b = $s.buf
		c = at(b, $i)
		# `(last or $i + n < b.len())`: is the byte `n` places ahead there (or will it never come)?
		# `step` bytes are part of the value; 0: wait for more input; Cut: a comma between values.
		step = match $s.mode {
			Normal =>
				if c == '/' {
					if !(last or $i + 1 < b.len()) {
						Wait
					} else if at(b, $i + 1) == '/' {
						$s = { ..$s, mode: LineComment }
						Take(2)
					} else if at(b, $i + 1) == '*' {
						$s = { ..$s, mode: Comment(1) }
						Take(2)
					} else {
						Take(1)
					}
				} else if c == '"' {
					if !(last or $i + 2 < b.len()) {
						Wait
					} else if at(b, $i + 1) == '"' and at(b, $i + 2) == '"' {
						$s = { ..$s, mode: Block }
						Take(3)
					} else {
						$s = { ..$s, mode: Text }
						Take(1)
					}
				} else if c == '{' or c == '[' or c == '(' {
					$s = { ..$s, depth: $s.depth + 1 }
					Take(1)
				} else if c == '}' or c == ']' or c == ')' {
					if $s.depth == 0 {
						return Err(unbalanced($s, $i))
					}
					$s = { ..$s, depth: $s.depth - 1 }
					Take(1)
				} else if c == ',' and $s.depth == 0 {
					Cut
				} else {
					Take(1)
				}
			LineComment => {
				if c == '\n' {
					$s = { ..$s, mode: Normal }
				}
				Take(1)
			}
			Comment(depth) =>
				if (c == '/' or c == '*') and !(last or $i + 1 < b.len()) {
					Wait
				} else if c == '/' and at(b, $i + 1) == '*' {
					$s = { ..$s, mode: Comment(depth + 1) }
					Take(2)
				} else if c == '*' and at(b, $i + 1) == '/' {
					$s = { ..$s, mode: if (depth == 1) Normal else Comment(depth - 1) }
					Take(2)
				} else {
					Take(1)
				}
			Text =>
				if c == '\\' {
					if ((last or $i + 1 < b.len())) Take(2) else Wait
				} else if c == '"' or c == '\n' {
					# A line break can't be in a string: the parser reports it at the next cut.
					$s = { ..$s, mode: Normal }
					Take(1)
				} else {
					Take(1)
				}
			Block =>
				if c == '\\' {
					if ((last or $i + 1 < b.len())) Take(2) else Wait
				} else if c == '"' {
					if !(last or $i + 2 < b.len()) {
						Wait
					} else if at(b, $i + 1) == '"' and at(b, $i + 2) == '"' {
						$s = { ..$s, mode: Normal }
						Take(3)
					} else {
						Take(1)
					}
				} else {
					Take(1)
				}
		}
		match step {
			Wait => {
				$go = False
			}
			Cut => {
				(next, value) = cut($s, $i)?
				$s = next
				$out = $out.append(value)
				$i = 0
			}
			Take(n) => {
				end = if ($i + n > b.len()) b.len() else $i + n
				starts = b.sublist({ start: $i, len: end - $i }).keep_if(|x| x < 0x80 or x >= 0xC0).len()
				$s = { ..$s, chars: $s.chars + starts }
				$i = end
			}
		}
	}
	Ok(({ ..$s, scanned: $i }, $out))
}

## Parse the value before the comma at `comma`, and drop it from the buffer.
cut : Streaming.Reader, U64 -> Try((Streaming.Reader, Value), Value.ParseError)
cut = |s, comma| {
	piece = s.buf.sublist({ start: 0, len: comma })
	text = utf8(piece, s.origin)?
	directive(text, s.origin)?
	value = match Value.parse_rest_with(text, s.options.limits) {
		Ok([v]) => v
		Ok([]) => {
			end = after(s.origin, piece)
			return Err({ code: ErrorCode.expected_value, reason: "expected a value, found ','", line: end.line, column: end.column })
		}
		Ok(_) => return Err({ code: ErrorCode.missing_comma, reason: "expected ',' between top-level values", line: s.origin.line, column: s.origin.column })
		Err(e) => return Err(shift(e, s.origin))
	}
	origin = after(s.origin, piece.append(','))
	Ok(({ ..s, buf: s.buf.drop_first(comma + 1), scanned: 0, chars: 0, origin }, value))
}

## A closing bracket without an opening one: let the parser say what's wrong.
unbalanced : Streaming.Reader, U64 -> Value.ParseError
unbalanced = |s, i| {
	piece = s.buf.sublist({ start: 0, len: i + 1 })
	match utf8(piece, s.origin) {
		Err(e) => e
		Ok(text) =>
			match Value.parse_rest_with(text, s.options.limits) {
				Err(e) => shift(e, s.origin)
				Ok(_) => {
					end = after(s.origin, s.buf.sublist({ start: 0, len: i }))
					{ code: ErrorCode.unexpected_closer, reason: "unexpected closing bracket", line: end.line, column: end.column }
				}
			}
	}
}

## A version directive at the start of the stream (spec §10): `#haus 2`.
## The first value starts at column 1, or 2 after a byte order mark; any
## later one after at least a value and a comma.
directive : Str, Pos -> Try({}, Value.ParseError)
directive = |text, origin|
	if origin.line == 1 and origin.column <= 2 and Value.starts_with_directive(text) {
		Err({ code: ErrorCode.version_directive, reason: Value.newer_version_reason, line: origin.line, column: origin.column })
	} else {
		Ok({})
	}

## The text of `bytes`, or where they aren't UTF-8.
utf8 : List(U8), Pos -> Try(Str, Value.ParseError)
utf8 = |bytes, origin| match Str.from_utf8(bytes) {
	Ok(text) => Ok(text)
	Err(BadUtf8({ index, .. })) => {
		end = after(origin, bytes.take_first(index))
		Err({ code: ErrorCode.invalid_utf8, reason: "invalid UTF-8", line: end.line, column: end.column })
	}
}

## An error in a piece that starts at `origin` of the whole input.
shift : Value.ParseError, Pos -> Value.ParseError
shift = |e, origin| {
	code: e.code,
	reason: e.reason,
	line: origin.line + e.line - 1,
	column: if (e.line == 1) origin.column + e.column - 1 else e.column,
}

## Where the input is after `bytes`, starting at `origin`.
after : Pos, List(U8) -> Pos
after = |origin, bytes| {
	var $p = origin
	for b in bytes {
		if b == '\n' {
			$p = { line: $p.line + 1, column: 1 }
		} else if b < 0x80 or b >= 0xC0 {
			$p = { ..$p, column: $p.column + 1 }
		}
	}
	$p
}

at : List(U8), U64 -> U8
at = |s, i| match s.get(i) {
	Ok(b) => b
	Err(_) => 0
}

# ── tests ────────────────────────────────────────────────────

## All values of `text`, pushed in chunks of `size` bytes.
chunked : Str, U64 -> Try(List(Value), Value.ParseError)
chunked = |text, size| {
	bytes = text.to_utf8()
	var $chunks = []
	var $i = 0
	while $i < bytes.len() {
		$chunks = $chunks.append(bytes.sublist({ start: $i, len: size }))
		$i = $i + size
	}
	Streaming.all($chunks)
}

expect {
	text = "UserCreated { id: 1 },\nHeartbeat,\n\"a,b\", /* , */ Pair(1, 2), // ,\n\"\"\"\n  x,\n  \"\"\",\n\"Olá 😀\""
	json = |r| r.map_ok(|values| values.map(Value.to_test_json))
	whole = json(Value.parse_all(text))
	[1, 2, 3, 5, 7, 1000].all(|size| json(chunked(text, size)) == whole)
}

# Each value as soon as its comma arrives.
# Comments between values: commas, brackets and quotes inside them don't cut.
expect {
	text = "// header, with a comma\nA { x: 1 }, // after A, [unbalanced\n/* block, with } and \" and /* nested, */ */\nB(2),\n\n// before C\nC { s: \"// not a comment\" } /* before the comma */ ,\n// trailing comment, {"
	json = |r| r.map_ok(|values| values.map(Value.to_test_json))
	whole = json(Value.parse_all(text))
	whole.map_ok(|vs| vs.len()) == Ok(3) and [1, 2, 3, 4, 5, 7, 11, 1000].all(|size| json(chunked(text, size)) == whole)
}

expect {
	s0 = Streaming.reader(Streaming.defaults)
	match Streaming.push(s0, "UserCreated { id: 1 ".to_utf8()) {
		Ok((s1, [])) =>
			match Streaming.push(s1, "},\nHeart".to_utf8()) {
				Ok((s2, [_])) => Streaming.finish(s2).map_ok(|vs| vs.map(Value.to_test_json)) == Ok(["{\"tag\":\"Heart\"}"])
				_ => False
			}
		_ => False
	}
}

# Positions in the whole stream.
expect {
	match Streaming.push(Streaming.reader(Streaming.defaults), "A,\nB,\n{ ok: true },".to_utf8()) {
		Err({ line: 3, column: 7, .. }) => True
		_ => False
	}
}

expect {
	options = { ..Streaming.defaults, require_terminator: True }
	match Streaming.push(Streaming.reader(options), "1000,\n100".to_utf8()) {
		Ok((s, [_])) =>
			match Streaming.finish(s) {
				Err({ reason, .. }) => reason.contains("truncated")
				_ => False
			}
		_ => False
	}
}

expect {
	options = { ..Streaming.defaults, max_value_length: 100 }
	bytes = "[".to_utf8().concat(List.repeat("1, ".to_utf8(), 100).join())
	match Streaming.push(Streaming.reader(options), bytes) {
		Err({ reason, .. }) => reason.contains("value longer than 100")
		_ => False
	}
}

expect chunked("1,, 2,", 1).is_err()
expect chunked("[1, 2,", 2).is_err()
expect chunked("1 ] 2,", 1).is_err()

# A byte order mark is skipped only at the start of the stream, not after a comma (found by fuzz/).
expect {
	Streaming.all(["A,\u(FEFF)".to_utf8()]).is_err() and Streaming.all(["\u(FEFF)A, B".to_utf8()]).is_ok()
}

# Positions after a byte order mark are the whole-text parser's (design review S18):
# the reader skipped it without counting it, so columns on line 1 were one too small.
expect {
	same = |text| match (Value.parse_all(text), chunked(text, 1000)) {
		(Err(whole), Err(e)) => whole.line == 1 and e.line == whole.line and e.column == whole.column
		_ => False
	}
	same("\u(FEFF){ ok: true }") and same("\u(FEFF)\u(001B)") and same("\u(FEFF)\",x")
}

# A version directive at the start (spec §10) needs a newer version of haus.
expect Streaming.all(["#haus 2\n1,\n2,\n".to_utf8()]).map_ok(|vs| vs.len()).map_err(|e| e.reason) == Err("the file starts with a version directive (#haus): it needs a newer version of haus")
expect Streaming.all(["\u(FEFF)#ha".to_utf8(), "us 2\n1,\n".to_utf8()]).map_ok(|vs| vs.len()).map_err(|e| (e.reason, e.column)) == Err(("the file starts with a version directive (#haus): it needs a newer version of haus", 2))
expect Streaming.all(["1,\n#haus 2,\n".to_utf8()]).map_ok(|vs| vs.len()).map_err(|e| e.reason) == Err("expected a value, found '#'")

# The parser's limits apply to each value (`Options.limits`), with positions in the whole stream.
expect {
	options = { ..Streaming.defaults, limits: { ..Value.default_limits, max_depth: 3, max_string_length: 4 } }
	read = |text| match Streaming.push(Streaming.reader(options), text.to_utf8()) {
		Ok((s, values)) => Streaming.finish(s).map_ok(|last| values.concat(last).len()).map_err(|e| "${e.reason} at ${e.line.to_str()}:${e.column.to_str()}")
		Err(e) => Err("${e.reason} at ${e.line.to_str()}:${e.column.to_str()}")
	}
	read("[[[1]]],\n\"abcd\",\n") == Ok(2)
		and read("[[[1]]],\n[[[[1]]]],\n") == Err("nesting deeper than 3 levels at 2:4")
		and read("1,\n\"abcde\"") == Err("string longer than 4 characters at 2:1")
		and read("Abcd,\n{ abcd: 1 },\n") == Ok(2)
		and read("1,\n{ abcde: 1 },") == Err("key longer than 4 characters at 2:3")
		and read("1,\nAbcde,") == Err("tag longer than 4 characters at 2:1")
}

# Up to the supported depth; a deeper limit fails at once, naming the maximum.
expect {
	deepest = { ..Streaming.defaults, limits: { ..Value.default_limits, max_depth: Value.max_supported_depth } }
	text = "${"A(".repeat(1024)}1${")".repeat(1024)},"
	Streaming.push(Streaming.reader(deepest), text.to_utf8()).map_ok(|(_, values)| values.len()) == Ok(1)
}
expect {
	too_deep = { ..Streaming.defaults, limits: { ..Value.default_limits, max_depth: 1025 } }
	error = { code: "unsupported-depth", reason: "max_depth 1025 is more than the supported maximum, 1024", line: 1, column: 1 }
	Streaming.push(Streaming.reader(too_deep), []).map_ok(|_| {}) == Err(error)
		and Streaming.finish(Streaming.reader(too_deep)).map_ok(|_| {}) == Err(error)
}

# `max_value_length`: a value of exactly the limit is taken, one character more is not.
expect {
	options = { ..Streaming.defaults, max_value_length: 10 }
	push = |text| Streaming.push(Streaming.reader(options), text.to_utf8()).map_ok(|(_, values)| values.len())
	push("1234567890,\n 23456789,") == Ok(2) and push("12345678901,").is_err()
}

# Error codes (spec §17): the stream reader's own, and the parser's in each value.
expect {
	code = |chunks| Streaming.all(chunks.map(Str.to_utf8)).map_ok(|_| {}).map_err(|e| "${e.code} at ${e.line.to_str()}:${e.column.to_str()}")
	code(["1,", ", 2,"]) == Err("expected-value at 1:3")
		and code(["A,\nB\n", "(1),"]) == Err("payload-newline at 3:1")
		and code(["1 ]", ","]) == Err("unexpected-closer at 1:3")
		and code(["[1 2],"]) == Err("missing-comma at 1:4")
		and code(["#haus 2,"]) == Err("version-directive at 1:1")
		and code(["1,\n", "nul", "l,"]) == Err("null-literal at 2:1")
}
expect {
	options = { ..Streaming.defaults, require_terminator: True, max_value_length: 3 }
	finished = |text| match Streaming.push(Streaming.reader(options), text.to_utf8()) {
		Ok((s, _)) => Streaming.finish(s).map_ok(|_| {}).map_err(|e| e.code)
		Err(e) => Err(e.code)
	}
	finished("1,\n2") == Err("stream-truncated") and finished("1234,") == Err("value-too-long")
}
expect Streaming.all([[0x31, 0x2C, 0x0A, 0x22], [0xFF, 0x22, 0x2C]]).map_ok(|_| {}).map_err(|e| (e.code, e.line, e.column)) == Err(("invalid-utf8", 2, 2))
