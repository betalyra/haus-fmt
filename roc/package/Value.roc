## The haus data model and parser.
##
## A `Value` is a haus value (spec §1): a number, a string, a byte string, an
## array, a record or a variant. Numbers are kept as their normalized literal
## text (`1e5`, `19.90`), variants are generic: applying a schema (decoding
## into your own tag unions) happens afterwards.
##
## `Value.parse_all(text)` parses a whole file: a sequence of top-level
## values. A syntax error is a `ParseError`: its `code` (spec §17, see
## `ErrorCode`), a `reason` for people, and the `line` and `column` where it is.
##
## In code, values are built with the constructors, which build only haus
## values (spec §11, "Values built in code"): `num`, `rec` and `tag` fail
## with a `ValueError` for a number text that isn't a number literal
## (`invalid-number`), a record with a key twice (`duplicate-key`) or a tag
## that isn't a tag name (`invalid-tag`); `text`, `bytes`, `arr` and `bool`
## can't fail. A number is normalized as the parser reads it. Constructors
## check only that a value is valid, never a limit (spec §7): limits are the
## writer's (`Encode`), which checks every limit a value can break.
##
## `==` on values is structural: the same kinds, texts and tags, a record's
## keys in the same order, numbers as their normalized literal. Haus
## equality (spec §2), where the order of a record's fields doesn't matter,
## is `Encode.equals`.
##
##     point = Value.tag("Point", [Value.num("1E+05")?, Value.num("0xFF")?])?
##     Encode.canonical(point)   # Ok("Point(1e5,255)")
##
## `view` shows the outermost level of a value, to match on:
##
##     match point.view() {
##         Tag(name, args) => "${name} with ${args.len().to_str()} arguments"
##         _ => "something else"
##     }
import ErrorCode

Value :: [
	Num(Str),
	Text(Str),
	Bytes(List(U8)),
	Arr(List(Value)),
	Rec(List((Str, Value))),
	Tag(Str, List(Value)),
].{

	# ── building and viewing values ─────────────────────────

	## A number from a number literal in any spelling (spec §2), normalized as
	## the parser reads it: `num("1E+05")` is the number `1e5`, `num("0xFF")`
	## `255`, `num("1_000")` `1000`; the scale stays (`19.90`). A text that
	## isn't one number literal (`01`, `NaN`, `1.`, ` 1`, the empty text) is
	## `invalid-number`. There is no limit on its length or exponent: limits
	## are a writer's (spec §7).
	num : Str -> Try(Value, ValueError)
	num = |literal| {
		src = literal.to_utf8()
		match number_end(src, 0) {
			Ok((end, radix)) if end == src.len() => Ok(Num(number_text(src, 0, end, radix)))
			_ => Err({ code: ErrorCode.invalid_number, reason: "invalid number '${ErrorCode.shown(literal)}': not a number literal" })
		}
	}

	## A string.
	text : Str -> Value
	text = |s| Text(s)

	## A byte string: `x"0b34"` is `bytes([0x0B, 0x34])`.
	bytes : List(U8) -> Value
	bytes = |b| Bytes(b)

	## An array.
	arr : List(Value) -> Value
	arr = |items| Arr(items)

	## A record, its fields in order. A key used twice is `duplicate-key`
	## (spec §1: keys are unique).
	rec : List((Str, Value)) -> Try(Value, ValueError)
	rec = |fields| {
		var $keys = List.with_capacity(fields.len())
		for (k, _) in fields {
			$keys = $keys.append((k, $keys.len()))
		}
		match Value.first_repeated($keys) {
			Ok((k, _)) => Err({ code: ErrorCode.duplicate_key, reason: "duplicate key '${ErrorCode.shown(k)}'" })
			Err(_) => Ok(Rec(fields))
		}
	}

	## A variant: a tag (`[A-Z][A-Za-z0-9_]*`, else `invalid-tag`) and its
	## arguments: `tag("None", [])`, `tag("Some", [x])`, and
	## `tag("Circle", [r])` for `Circle { … }` when `r` is a record.
	tag : Str, List(Value) -> Try(Value, ValueError)
	tag = |name, args| {
		b = name.to_utf8()
		if is_upper(at(b, 0)) and b.all(is_ident_char) {
			Ok(Tag(name, args))
		} else {
			Err({ code: ErrorCode.invalid_tag, reason: "invalid tag '${ErrorCode.shown(name)}': a tag is A to Z, then letters, digits and _" })
		}
	}

	## `True` or `False` (spec §1: booleans are tags).
	bool : Bool -> Value
	bool = |b| Tag(if (b) "True" else "False", [])

	## The outermost level of a value, to match on: its kind and its parts,
	## which are values again. A record that is a tag's only argument is
	## `Tag(name, [r])`, with `r` viewing as `Rec(fields)`.
	##
	##     match v.view() {
	##         Num(literal) => literal
	##         Tag("Some", [x]) => …
	##         _ => …
	##     }
	view : Value -> View
	view = |v| match v {
		Num(literal) => Num(literal)
		Text(s) => Text(s)
		Bytes(b) => Bytes(b)
		Arr(items) => Arr(items)
		Rec(fields) => Rec(fields)
		Tag(name, args) => Tag(name, args)
	}

	## What `view` gives: one level of a value.
	View : [Num(Str), Text(Str), Bytes(List(U8)), Arr(List(Value)), Rec(List((Str, Value))), Tag(Str, List(Value))]

	## `==` is structural, as in Rust: the same kind, text, tag, a record's
	## keys in the same order, numbers with the same normalized literal as
	## stored, and equal parts. It is not haus equality (spec §2), where the
	## order of a record's fields doesn't matter: that is `Encode.equals`, so
	## `{ a: 1, b: 2 }` and `{ b: 2, a: 1 }` differ with `==` and are equal
	## with `Encode.equals`. Compared with a list rather than recursion, so
	## that values of any depth compare.
	is_eq : Value, Value -> Bool
	is_eq = |a, b| {
		# The pairs of parts still to compare.
		var $todo = [(a, b)]
		while True {
			match $todo.last() {
				Err(_) => return True
				Ok((x, y)) => {
					(same, parts) = match (x, y) {
						(Num(p), Num(q)) => (p == q, [])
						(Text(p), Text(q)) => (p == q, [])
						(Bytes(p), Bytes(q)) => (p == q, [])
						(Arr(p), Arr(q)) => (p.len() == q.len(), p.map2(q, |i, j| (i, j)))
						(Rec(p), Rec(q)) => (p.len() == q.len() and p.map2(q, |(k, _), (l, _)| k == l).all(|same_key| same_key), p.map2(q, |(_, i), (_, j)| (i, j)))
						(Tag(s, p), Tag(t, q)) => (s == t and p.len() == q.len(), p.map2(q, |i, j| (i, j)))
						_ => (False, [])
					}
					if !same {
						return False
					}
					$todo = $todo.drop_last(1).concat(parts)
				}
			}
		}
	}

	# ── parsing ─────────────────────────────────────────────

	## Parse a whole file into its top-level values.
	parse_all : Str -> Try(List(Value), ParseError)
	parse_all = |input| parse_all_with(input, default_limits)

	## `parse_all` with your own limits.
	parse_all_with : Str, Limits -> Try(List(Value), ParseError)
	parse_all_with = |input, limits| {
		check_limits(limits).map_err(unsupported)?
		src = input.to_utf8()
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
	parse_rest = |input| parse_rest_with(input, default_limits)

	## `parse_rest` with your own limits.
	parse_rest_with : Str, Limits -> Try(List(Value), ParseError)
	parse_rest_with = |input, limits| {
		check_limits(limits).map_err(unsupported)?
		src = input.to_utf8()
		parse_sequence(src, 0, limits).map_err(|f| locate(src, f))
	}

	## Whether a file that starts with `input` needs a newer version of haus:
	## it starts with a version directive (`#haus 2`, spec §10). The reason to
	## report then is `Value.newer_version_reason`.
	starts_with_directive : Str -> Bool
	starts_with_directive = |input| input.starts_with("#haus")

	newer_version_reason : Str
	newer_version_reason = "the file starts with a version directive (#haus): it needs a newer version of haus"

	## Parse raw bytes, which must be valid UTF-8 (`invalid-utf8` where they
	## aren't).
	parse_bytes : List(U8) -> Try(List(Value), ParseError)
	parse_bytes = |input| parse_bytes_with(input, default_limits)

	## `parse_bytes` with your own limits.
	parse_bytes_with : List(U8), Limits -> Try(List(Value), ParseError)
	parse_bytes_with = |input, limits| match Str.from_utf8(input) {
		Ok(decoded) => parse_all_with(decoded, limits)
		Err(BadUtf8({ index, .. })) => Err(locate(input, { code: ErrorCode.invalid_utf8, reason: "invalid UTF-8", pos: index }))
	}

	## Parse a text that must contain exactly one value: a single document
	## (`not-one-value` at the end of the input if it has none or several,
	## spec §8).
	parse : Str -> Try(Value, ParseError)
	parse = |input| parse_with(input, default_limits)

	## `parse` with your own limits.
	parse_with : Str, Limits -> Try(Value, ParseError)
	parse_with = |input, limits| {
		values = parse_all_with(input, limits)?
		match values {
			[v] => Ok(v)
			_ => {
				src = input.to_utf8()
				Err(locate(src, { code: ErrorCode.not_one_value, reason: "expected exactly one value, found ${values.len().to_str()}", pos: src.len() }))
			}
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
	## a limit is accepted. Writers check a value against the same limits.
	##
	## `max_nodes` is the node limit (spec §7, "Values written"): the values
	## written for one value, the value itself and every element, field value
	## and argument in it, a part that is shared (`Value.arr([w, w])`)
	## counted each time it is written. Writers, the canonical form, hashing,
	## equality and order fail with `too-many-nodes` above it, for each
	## top-level value; so does decoding a `Value` built in code. Parsing
	## doesn't use it: a parsed value has fewer values than its text has
	## characters.
	##
	## `max_steps` bounds the work of encoding one native value with a
	## generated `encode_<name>` (spec §9.8): the values it makes, a step
	## each, so that a native value whose parts are shared (a DAG) fails with
	## `step-budget` instead of expanding without bound; parsing, decoding and
	## the writers of values don't use it.
	##
	##     Value.parse_all_with(text, { ..Value.default_limits, max_depth: 64 })
	Limits : { max_depth : U64, max_number_length : U64, max_exponent : U64, max_string_length : U64, max_nodes : U64, max_steps : U64 }

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
	## exponents up to 6144, strings of 16 Mi characters, 64 Mi values written
	## for one value (`max_nodes`). Every reader must take what is within
	## them. Encoding one native value takes at most 16 Mi steps, as in
	## TypeScript and Rust.
	default_limits : Limits
	default_limits = { max_depth: 256, max_number_length: 1000, max_exponent: 6144, max_string_length: 16 * 1024 * 1024, max_nodes: 64 * 1024 * 1024, max_steps: 16 * 1024 * 1024 }

	## The default node limit (spec §7, "Values written"), `max_nodes` of
	## `default_limits`: 64 Mi (67,108,864) values written for one value. A
	## `Value` built in code may share its parts (`Value.arr([w, w])` holds `w`
	## twice, not a copy), and a shared part counts each time it is written:
	## 40 levels that each hold the one below twice are 2^41 − 1 values, which
	## fail with `too-many-nodes` instead of taking days. A parsed value is a
	## tree, no larger than its text.
	max_nodes : U64
	max_nodes = 64 * 1024 * 1024

	## `Ok(n)`: `v` writes `n` values, at most `limit` (spec §7, "Values
	## written"): itself and every element, field value and argument in it,
	## a shared part counted each time it is written, so `Tag { … }` is two
	## (the tag and its record). `Err(TooManyNodes)` above the limit, found
	## after at most `limit` steps however much `v` shares. Walked with a list
	## rather than recursion, so any depth is counted.
	##
	##     Value.count_nodes(Value.arr([Value.text("a"), Value.text("b")]), 3)   # Ok(3)
	count_nodes : Value, U64 -> Try(U64, [TooManyNodes])
	count_nodes = |v, limit| {
		var $todo = [v]
		var $nodes = 0.U64
		while True {
			match $todo.last() {
				Err(_) => return Ok($nodes)
				Ok(x) => {
					$nodes = $nodes + 1
					if $nodes > limit {
						return Err(TooManyNodes)
					}
					$todo = match x {
						Arr(items) => $todo.drop_last(1).concat(items)
						Rec(fields) => $todo.drop_last(1).concat(fields.map(|(_, f)| f))
						Tag(_, args) => $todo.drop_last(1).concat(args)
						_ => $todo.drop_last(1)
					}
				}
			}
		}
	}

	## `Ok({})` if `v` nests at most `max_depth` levels, counted as the parser
	## counts them (each array, record and tag with arguments is a level, and
	## a tag's only argument, a record, shares the tag's: `Tag { … }`), and
	## has at most `max_nodes` values, a shared part counted each time it is
	## reached (see `Value.max_nodes`). Otherwise `nesting-too-deep` at the
	## first container too deep, or `too-many-nodes` at the first value
	## beyond, with its place (`[0].items[2]`). Walked with a list rather than
	## recursion, so that a value built in code, however deep, is checked
	## without overflowing the stack, a step per value counted, so that it
	## stops after at most `max_nodes` steps however much it shares.
	##
	##     Value.within_bounds(Value.arr([Value.text("a")]), 256, Value.max_nodes)   # Ok({})
	within_bounds : Value, U64, U64 -> Try({}, { code : Str, reason : Str, path : Str })
	within_bounds = |v, depth_limit, node_limit| {
		too_many = |path| Err({ code: ErrorCode.too_many_nodes, reason: "value has more than ${node_limit.to_str()} nodes", path })
		too_deep = |path| Err({ code: ErrorCode.nesting_too_deep, reason: "nesting deeper than ${depth_limit.to_str()} levels", path })
		# `Tag { … }`: its record is a value too, at the tag's level.
		root_nodes = if (has_payload(v)) 2 else 1
		if root_nodes > node_limit {
			return too_many("")
		}
		if !opens(v) {
			return Ok({})
		}
		if depth_limit == 0 {
			return too_deep("")
		}
		# The containers from `v` down to the one being walked, and the next item of each.
		var $containers = [v]
		var $next = [0.U64]
		var $nodes = root_nodes
		while True {
			match $containers.last() {
				Ok(container) => {
					top = $containers.len() - 1
					i = $next.get(top) ?? 0
					match child(container, i) {
						Ok(x) => {
							$next = $next.set(top, i + 1) ?? $next
							$nodes = $nodes + (if (has_payload(x)) 2 else 1)
							if $nodes > node_limit {
								return too_many(path_of($containers, $next))
							}
							if opens(x) {
								if $containers.len().to_u64() >= depth_limit {
									return too_deep(path_of($containers, $next))
								}
								$containers = $containers.append(x)
								$next = $next.append(0)
							}
						}
						Err(_) => {
							$containers = $containers.drop_last(1)
							$next = $next.drop_last(1)
						}
					}
				}
				Err(_) => {
					return Ok({})
				}
			}
		}
	}

	## The first of `keys` (each with where it is: an offset or an index)
	## that repeats an earlier one, if any: the key a duplicate-key error
	## names (spec §1). The keys are sorted and neighbours compared, so this
	## takes O(n log n) for any keys (spec §7): a hash table would need a
	## seed attackers can't predict, which Roc's `Dict` doesn't promise.
	first_repeated : List((Str, U64)) -> Try((Str, U64), [NoneRepeated])
	first_repeated = |keys| {
		sorted = keys.map(|(k, pos)| (k.to_utf8(), k, pos)).sort_with(
			|(a, _, i), (b, _, j)| match compare_bytes(a, b) {
				Same => if (i < j) Before else if (i > j) After else Same
				order => order
			},
		)
		var $first = Err(NoneRepeated)
		var $i = 1.U64
		while $i < sorted.len() {
			match (sorted.get($i - 1), sorted.get($i)) {
				(Ok((a, _, _)), Ok((b, k, pos))) if a == b => {
					$first = match $first {
						Ok((_, earlier)) if earlier < pos => $first
						_ => Ok((k, pos))
					}
				}
				_ => {}
			}
			$i = $i + 1
		}
		$first
	}

	## Encode in the conformance suite's JSON form (see test-suite/README.md).
	to_test_json : Value -> Str
	to_test_json = |value| match value {
		Num(t) => "{\"num\":${json_str(t)}}"
		Text(s) => json_str(s)
		Bytes(b) => "{\"bytes\":\"${hex_lower(b)}\"}"
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

## Why a constructor didn't build a value: its code (spec §17, `ErrorCode`:
## `invalid-number`, `invalid-tag` or `duplicate-key`) and what is wrong.
ValueError : { code : Str, reason : Str }

Fail : { code : Str, reason : Str, pos : U64 }

## Limits this binding doesn't support, as an error at the start.
unsupported : Str -> ParseError
unsupported = |reason| { code: ErrorCode.unsupported_depth, reason, line: 1, column: 1 }

# ── the shape of a value (`within_bounds`) ───────────────────

## An array, a record or a tag with arguments: a level.
opens : Value -> Bool
opens = |v| match v {
	Arr(_) | Rec(_) => True
	Tag(_, args) => !args.is_empty()
	_ => False
}

## `Tag { … }`: a tag whose only argument, a record, is at the tag's level.
has_payload : Value -> Bool
has_payload = |v| match v {
	Tag(_, [Rec(_)]) => True
	_ => False
}

## Item `i` of a container: of an array, a record's field, a tag's
## argument; of `Tag { … }`, a field of its record.
child : Value, U64 -> Try(Value, [OutOfBounds])
child = |v, i| match v {
	Arr(items) => items.get(i)
	Rec(fields) | Tag(_, [Rec(fields)]) => fields.get(i).map_ok(|(_, x)| x)
	Tag(_, args) => args.get(i)
	_ => Err(OutOfBounds)
}

## The place of the item last taken from each of `containers`, given the
## index of the next item of each, as an error path says it: `[0].a(Some)[0]`.
path_of : List(Value), List(U64) -> Str
path_of = |containers, next| Str.join_with(containers.map2(next, |c, n| place_of(c, n - 1)), "")

## Where item `i` of a container is, as an error path says it: `[0]`, `.a`,
## `(Some)[0]`, `(Circle).r`.
place_of : Value, U64 -> Str
place_of = |v, i| match v {
	Arr(_) => "[${i.to_str()}]"
	Rec(fields) => fields.get(i).map_ok(|(k, _)| ErrorCode.path_key(k)) ?? ""
	Tag(name, [Rec(fields)]) => "(${name})${fields.get(i).map_ok(|(k, _)| ErrorCode.path_key(k)) ?? ""}"
	Tag(name, _) => "(${name})[${i.to_str()}]"
	_ => ""
}

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
		(content, after) = parse_bytes_literal(src, pos, limits)?
		Ok((Bytes(content), after))
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
		Err({ code, reason: "unexpected identifier '${ErrorCode.shown(word)}': lowercase identifiers can only be record keys${hint}", pos })
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
	# Each key and where it is, taken as soon as the key is read, before its
	# colon and value. A key that repeats an earlier one is reported at the
	# second key, before any later error (spec §8), so the keys are checked
	# for repeats when the record ends, or before an error after them. Sorted
	# then, so a record takes O(n log n) whatever its keys (spec §7).
	var $keys = []
	var $pos = skip_trivia(src, open + 1)?
	while at(src, $pos) != '}' {
		if $pos >= src.len() {
			return Err(repeated_first($keys, unclosed(src, open)))
		}
		key_pos = $pos
		(key, after_key) = match parse_key(src, $pos, limits) {
			Ok(read) => read
			Err(e) => return Err(repeated_first($keys, e))
		}
		$keys = $keys.append((key, key_pos))
		(value, after_value) = match record_value(src, key, after_key, depth, limits) {
			Ok(entry) => entry
			Err(e) => return Err(repeated_first($keys, e))
		}
		$fields = $fields.append((key, value))
		$pos = match record_next(src, after_value, open, value) {
			Ok(next) => next
			Err(e) => return Err(repeated_first($keys, e))
		}
	}
	match Value.first_repeated($keys) {
		Ok((key, pos)) => Err(duplicate_key(key, pos))
		Err(_) => Ok(($fields, $pos + 1))
	}
}

## After a record's key: its colon, its value, and where the value ends.
record_value : List(U8), Str, U64, U64, Value.Limits -> Try((Value, U64), Fail)
record_value = |src, key, after_key, depth, limits| {
	colon = skip_trivia(src, after_key)?
	if at(src, colon) != ':' {
		return Err({ code: ErrorCode.missing_colon, reason: "expected ':' after key '${ErrorCode.shown(key)}', found ${describe(src, colon)}", pos: colon })
	}
	parse_value(src, skip_trivia(src, colon + 1)?, depth + 1, limits)
}

## After a record's entry: where the next one starts, or the closing `}`.
record_next : List(U8), U64, U64, Value -> Try(U64, Fail)
record_next = |src, after_value, open, value| {
	p = skip_trivia(src, after_value)?
	if at(src, p) == ',' {
		skip_trivia(src, p + 1)
	} else if at(src, p) == '}' {
		Ok(p)
	} else if p >= src.len() {
		Err(unclosed(src, open))
	} else {
		Err(separator(src, p, value, "expected ',' or '}'"))
	}
}

## `e`, unless one of the keys before it repeats an earlier one: reading in
## order, that error comes first.
repeated_first : List((Str, U64)), Fail -> Fail
repeated_first = |keys, e| match Value.first_repeated(keys) {
	Ok((key, pos)) => duplicate_key(key, pos)
	Err(_) => e
}

duplicate_key : Str, U64 -> Fail
duplicate_key = |key, pos| { code: ErrorCode.duplicate_key, reason: "duplicate key '${ErrorCode.shown(key)}'", pos }

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
		Err({ code: ErrorCode.uppercase_key, reason: "record keys must start with a lowercase letter or '_'; quote it: \"${ErrorCode.shown(word)}\"", pos })
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
	(tag_name, after_tag) = name(src, pos, "tag", limits)?
	# The payload must follow on the same line: only spaces and tabs in between.
	var $p = after_tag
	while at(src, $p) == ' ' or at(src, $p) == '\t' {
		$p = $p + 1
	}
	p = $p
	if at(src, p) == '(' {
		(args, after) = parse_list(src, p, depth, ')', limits)?
		if args.is_empty() {
			Err({ code: ErrorCode.empty_payload, reason: "empty payload: write '${ErrorCode.shown(tag_name)}' without parentheses", pos: p })
		} else {
			Ok((Tag(tag_name, args), after))
		}
	} else if at(src, p) == '{' {
		(fields, after) = parse_record(src, p, depth, limits)?
		Ok((Tag(tag_name, [Rec(fields)]), after))
	} else {
		Ok((Tag(tag_name, []), after_tag))
	}
}

# ── numbers ──────────────────────────────────────────────────

parse_number : List(U8), U64, Value.Limits -> Try((Value, U64), Fail)
parse_number = |src, start, limits| {
	# Checked in the reference's order: the literal (a linear scan), what
	# follows it, its length, its exponent. Converted only then, so huge
	# literals stay cheap.
	(end, radix) = number_end(src, start)?
	if end - start > limits.max_number_length {
		return Err({ code: ErrorCode.number_too_long, reason: "number literal longer than ${limits.max_number_length.to_str()} characters", pos: start })
	}
	# More hex digits would make an integer longer than the limit in decimal (spec §7).
	if radix == 16 {
		most = max_hex_digits(limits.max_number_length)
		digits_start = (if (at(src, start) == '-') start + 1 else start) + 2
		if src.sublist({ start: digits_start, len: end - digits_start }).count_if(|b| b != '_') > most {
			return Err({ code: ErrorCode.number_too_long, reason: "hex literal with more than ${most.to_str()} hex digits", pos: start })
		}
	}
	if radix == 10 and exponent_larger(src.sublist({ start, len: end - start }), limits.max_exponent) {
		return Err({ code: ErrorCode.exponent_too_large, reason: "exponent larger than ${limits.max_exponent.to_str()}", pos: start })
	}
	Ok((Num(number_text(src, start, end, radix)), end))
}

## Where the number literal at `start` ends, and its radix (10, 16 or 2):
## the literal, and nothing that would make it another token after it.
number_end : List(U8), U64 -> Try((U64, U64), Fail)
number_end = |src, start| {
	digits_start = if (at(src, start) == '-') start + 1 else start
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
	Ok((end, radix))
}

## The normalized text (spec §2) of the number literal from `start` to `end`.
number_text : List(U8), U64, U64, U64 -> Str
number_text = |src, start, end, radix| {
	neg = at(src, start) == '-'
	digits_start = if (neg) start + 1 else start
	if (radix == 10) decimal_text(src, start, end) else radix_text(src, digits_start + 2, end, radix, neg)
}

## The most hex digits in one hex literal for the number limit `n` (spec §7):
## the largest h with 16^h ≤ 10^(n − 1), so that every integer that parses has
## a decimal form, sign included, of at most n characters. 829 for 1000.
##
## Exact, never from a literal: ⌊(n − 1) · log₁₆ 10⌋ with two 18-digit bounds
## of log₁₆ 10, which agree for every limit below 10⁷ and almost every larger
## one; where they don't, a power of 16 decides.
max_hex_digits : U64 -> U64
max_hex_digits = |n| {
	if n == 0 {
		return 0
	}
	m = (n - 1).to_u128()
	# log₁₆ 10 = 0.830482023721840586967…
	low = (m * 830482023721840586 // 1000000000000000000).to_u64_wrap()
	high = (m * 830482023721840587 // 1000000000000000000).to_u64_wrap()
	if low == high {
		return low
	}
	# 16^high ≤ 10^(n − 1) exactly when 16^high, never a power of 10, has at most n − 1 digits.
	var $power = [1]
	var $i = 0
	while $i < high {
		$power = mul_add($power, 16, 0)
		$i = $i + 1
	}
	if ($power.len() <= n - 1) high else low
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
	{ code: ErrorCode.invalid_number, reason: "invalid number '${ErrorCode.shown(slice_str(src, start, $e))}'", pos: start }
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
	literal = src
		.sublist({ start, len: end - start })
		.keep_if(|b| b != '_')
		.map(|b| if (b == 'E') 'e' else b)
	bytes_to_str(normalize_exponent(literal))
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
normalize_exponent = |literal| {
	var $at = 0
	while $at < literal.len() and at(literal, $at) != 'e' {
		$at = $at + 1
	}
	if $at == literal.len() {
		return literal
	}
	mantissa = literal.sublist({ start: 0, len: $at + 1 })
	rest = literal.sublist({ start: $at + 1, len: literal.len() - $at - 1 })
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
	# The sign stays, also on zero: `-0x0` is `-0`, as `-0` is (spec §2).
	sign = if (neg) "-" else ""
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
check_string_length = |decoded, open, limits| {
	# Count code points: every byte that isn't a UTF-8 continuation byte.
	chars = decoded.keep_if(|b| b < 0x80 or b >= 0xC0).len()
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
			(escaped, after) = read_escape(src, $pos)?
			$out = $out.concat(escaped)
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
			return Err({ code: ErrorCode.invalid_unicode_escape, reason: "\\u{${ErrorCode.shown(slice_str(src, start + 3, $p))}} is not a Unicode scalar value", pos: start })
		}
		Ok((utf8_encode($cp), $p + 1))
	} else {
		Err({ code: ErrorCode.invalid_escape, reason: "invalid escape '\\${ErrorCode.shown(char_str(src, start + 1))}'", pos: start })
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
			return Err({ code: ErrorCode.block_string_opening, reason: "opening \"\"\" must be followed by a line break", pos: $p })
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
			(escaped, after) = read_escape(src, $p)?
			$out = $out.concat(escaped)
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
hex_lower = |content| {
	digits = "0123456789abcdef".to_utf8()
	var $out = []
	for b in content {
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
	expected = prefix.to_utf8()
	src.sublist({ start: pos, len: expected.len() }) == expected
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

is_blank = |content| content.all(|b| b == ' ' or b == '\t')

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
bytes_to_str = |content| match Str.from_utf8(content) {
	Ok(s) => s
	Err(_) => "" # unreachable: input is valid UTF-8 and escapes are encoded correctly
}

slice_str : List(U8), U64, U64 -> Str
slice_str = |src, start, end| bytes_to_str(src.sublist({ start, len: end - start }))

## Byte strings in order: a prefix comes first.
compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |a, b| {
	var $i = 0
	while $i < a.len() and $i < b.len() {
		x = at(a, $i)
		y = at(b, $i)
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

byte_str : U8 -> Str
byte_str = |b| bytes_to_str([b])

## The whole character that starts at `pos`.
char_str : List(U8), U64 -> Str
char_str = |src, pos| {
	c = at(src, pos)
	len = if (c < 0x80) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else 4
	bytes_to_str(src.sublist({ start: pos, len }))
}

describe : List(U8), U64 -> Str
describe = |src, pos|
	if pos >= src.len() {
		"end of input"
	} else if at(src, pos) == '\n' {
		"line break"
	} else {
		"'${ErrorCode.shown(char_str(src, pos))}'"
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
small = { ..Value.default_limits, max_depth: 3, max_number_length: 8, max_exponent: 99, max_string_length: 4 }

within_small : Str -> Try(U64, Str)
within_small = |input| Value.parse_all_with(input, small).map_ok(|vs| vs.len()).map_err(|e| "${e.code}: ${e.reason} at ${e.line.to_str()}:${e.column.to_str()}")

expect within_small("[[[1]]], { a: { b: [] } }, A(B(C(1))), A { b: B { c: [] } }") == Ok(4)
expect within_small("[[[[1]]]]") == Err("nesting-too-deep: nesting deeper than 3 levels at 1:4")
expect within_small("A(B(C(D(1))))") == Err("nesting-too-deep: nesting deeper than 3 levels at 1:8")
expect within_small("{ a: { b: { c: {} } } }") == Err("nesting-too-deep: nesting deeper than 3 levels at 1:16")
expect within_small("12345678, -1234567, 1_234_56, 0xF_FFFF") == Ok(4)
expect within_small("123456789") == Err("number-too-long: number literal longer than 8 characters at 1:1")
# Five hex digits for a limit of 8: -0xFFFFFF would be -16777215, 9 characters.
expect within_small("0xFFFFFF") == Err("number-too-long: hex literal with more than 5 hex digits at 1:1")
# A hex literal has at most 829 hex digits (spec §7): leading zeros count, `_` doesn't.
expect ["0x${"f".repeat(829)}", "-0x${"f".repeat(829)}", "0x${Str.join_with(List.repeat("f".repeat(100), 8), "_")}_${"f".repeat(29)}"].all(|t| Value.parse_all(t).is_ok())
expect ["0x${"f".repeat(830)}", "-0x${"0".repeat(830)}", "[1, 0x${"F".repeat(830)}]"].map(|t| Value.parse_all(t).map_ok(|_| {}).map_err(|e| (e.code, e.reason, e.column))) == [Err(("number-too-long", "hex literal with more than 829 hex digits", 1)), Err(("number-too-long", "hex literal with more than 829 hex digits", 1)), Err(("number-too-long", "hex literal with more than 829 hex digits", 5))]
# 829 hex digits are at most 999 decimal digits; binary literals need no limit of their own.
expect match Value.parse_all("-0x${"f".repeat(829)}, 0b${"1".repeat(998)}") {
	Ok([Num(hex), Num(bin)]) => hex.count_utf8_bytes() == 1000 and bin.count_utf8_bytes() == 301
	_ => False
}
# The hex digit limit follows the number limit: the largest h with 16^h ≤ 10^(n − 1).
expect [0, 1, 2, 3, 12, 1000, 2000, 1000000].map(max_hex_digits) == [0, 0, 0, 1, 9, 829, 1660, 830481]
expect Value.parse_all_with("0x${"f".repeat(9)}", { ..small, max_number_length: 12 }).is_ok() and Value.parse_all_with("0x${"f".repeat(10)}", { ..small, max_number_length: 12 }).map_ok(|_| {}).map_err(|e| e.reason) == Err("hex literal with more than 9 hex digits")
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
code_at = |input| match Value.parse_all(input) {
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
# Hex and binary keep the sign, also on zero: `-0x0` is `-0` (spec §2).
expect Value.parse_all("-0x0, -0b0, -0x0_0, 0x0, 0b0, -0, -0xFF").map_ok(|vs| vs.map(Value.to_test_json)) == Ok(["-0", "-0", "-0", "0", "0", "-0", "-255"].map(|n| "{\"num\":\"${n}\"}"))
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
# `block-string-opening` at what follows the opening quotes and their spaces, or at the end of the input.
expect code_at("\"\"\"") == "block-string-opening at 1:4" and code_at("[\"\"\"  ") == "block-string-opening at 1:7"
expect code_at("A()") == "empty-payload at 1:2" and code_at("\"\"\"x\n\"\"\"") == "block-string-opening at 1:4" and code_at("\"\"\"\n  a\n b\"\"\"") == "block-string-closing at 3:3"
# Invalid UTF-8 is reported where it is; exactly one value where one is expected.
expect Value.parse_bytes([0x5B, 0x31, 0x0A, 0x22, 0xFF, 0x22, 0x5D]).map_ok(|_| {}).map_err(|e| (e.code, e.line, e.column)) == Err(("invalid-utf8", 2, 2))
expect Value.parse("1, 2").map_ok(|_| {}).map_err(|e| e.code) == Err("not-one-value") and Value.parse("").map_ok(|_| {}).map_err(|e| e.code) == Err("not-one-value")
# `not-one-value` is at the end of the input (spec §8).
expect ["1, 2", "", "// c\n", "\u(FEFF)1,\n2 "].map(|text| Value.parse(text).map_ok(|_| {}).map_err(|e| (e.code, e.line, e.column))) == [(1, 5), (1, 1), (2, 1), (2, 3)].map(|(l, c)| Err(("not-one-value", l, c)))
expect Value.parse_all("[1 2]").map_ok(|_| {}).map_err(Value.error_json) == Err("{\"code\":\"missing-comma\",\"message\":\"expected ',' or ']', found '2'\",\"line\":1,\"column\":4,\"hint\":\"Add a comma between the two values.\",\"docs\":\"https://haus-fmt.org/docs/errors#missing-comma\"}")

# Duplicate keys (spec §7): keys are sorted and neighbours compared, so a
# record or object with many keys takes O(n log n), whatever the keys are.
expect Value.first_repeated([("b", 0), ("a", 1), ("c", 2), ("a", 3), ("b", 4)]) == Ok(("a", 3))
expect Value.first_repeated([("x", 9), ("x", 2), ("x", 5)]) == Ok(("x", 5)) and Value.first_repeated([("a", 0), ("ab", 1), ("", 2)]) == Err(NoneRepeated)
expect Value.first_repeated([]) == Err(NoneRepeated) and Value.first_repeated([("é", 0), ("e\u(301)", 1)]) == Err(NoneRepeated)
expect {
	n = 100000
	match Value.parse_all(many_keys(n, "")) {
		Ok([Rec(fields)]) => fields.len() == n
		_ => Bool.False
	}
}
expect {
	input = many_keys(100000, ", k99999: 0")
	match Value.parse_all(input) {
		Err({ code, column, .. }) => code == "duplicate-key" and column == input.count_utf8_bytes() - 10
		_ => Bool.False
	}
}
# A repeated key is reported at the second key as soon as it is read, before
# its colon and value (spec §8), and so before an error after it, and after
# one before it.
expect code_at("{ a: 1, b: 2, a: 3, c: }") == "duplicate-key at 1:15" and code_at("{ a: 1, a: [ }") == "duplicate-key at 1:9" and code_at("{ a: [, a: 1 }") == "expected-value at 1:7"
expect code_at("{ a: 1, a: \"\\q\" }") == "duplicate-key at 1:9" and code_at("{ a: 1, a: [1 2] }") == "duplicate-key at 1:9" and code_at("{ a: 1,\n  \"a\" 2 }") == "duplicate-key at 2:3"
expect code_at("[Point { x: 1, y: 2, x: \"\"\"\n }]") == "duplicate-key at 1:22" and code_at("Point({ x: 1, x: 1e99999 })") == "duplicate-key at 1:15" and code_at("{ a: 1, a }") == "duplicate-key at 1:9"
expect code_at("{ a: 1, a: 2 x }") == "duplicate-key at 1:9" and code_at("{ a: 1, a: 2") == "duplicate-key at 1:9" and code_at("{ a: { b: 1, b: 2 }, a: 1 }") == "duplicate-key at 1:14"

## `{ k0: 0, k1: 1, … }` with `n` keys, then `more`.
many_keys : U64, Str -> Str
many_keys = |n, more| {
	var $parts = List.with_capacity(n)
	var $i = 0.U64
	while $i < n {
		$parts = $parts.append("k${$i.to_str()}: ${$i.to_str()}")
		$i = $i + 1
	}
	"{ ${Str.join_with($parts, ", ")}${more} }"
}

# `count_nodes` (spec §7, "Values written"): the value and every element,
# field value and argument, `Tag { … }` two, a shared part each time.
expect Value.count_nodes(Arr([Num("1"), Rec([("a", Text("x"))]), Tag("A", [Rec([("b", Num("1"))])])]), 7) == Ok(7) and Value.count_nodes(Arr([Arr([]), Arr([])]), 2) == Err(TooManyNodes)
expect Value.count_nodes(Num("1"), 1) == Ok(1) and Value.count_nodes(Num("1"), 0) == Err(TooManyNodes) and Value.count_nodes(Tag("None", []), 1) == Ok(1)
expect {
	# 40 levels that each hold the one below twice: 2^41 − 1 values, stopped at the limit.
	var $v = Arr([])
	var $i = 0
	while $i < 40 {
		$v = Arr([$v, $v])
		$i = $i + 1
	}
	Value.count_nodes($v, 100_000) == Err(TooManyNodes)
}

# `within_bounds` (spec §9.8): `Tag { … }` is two values, and the place of the first one beyond.
expect Value.within_bounds(Arr([Num("1")]), 256, Value.max_nodes) == Ok({})
expect Value.within_bounds(Tag("A", [Rec([("b", Num("1"))])]), 1, 3) == Ok({}) and Value.within_bounds(Tag("A", [Rec([("b", Num("1"))])]), 1, 2) == Err({ code: "too-many-nodes", reason: "value has more than 2 nodes", path: "(A).b" })
expect Value.within_bounds(Arr([Rec([("pt-BR", Arr([]))])]), 2, 9) == Err({ code: "nesting-too-deep", reason: "nesting deeper than 2 levels", path: "[0][\"pt-BR\"]" })

# Values built in code (spec §11): the constructors build only haus values, a
# number normalized as the parser reads it, without limits.
expect ["1E+05", "0xFF", "1_000", "-0x0", "1e-0", "19.90", "0b101", "1e+0005", "-1.5E-07"].map(|n| Value.num(n).map_ok(Value.view)) == ["1e5", "255", "1000", "-0", "1e0", "19.90", "5", "1e5", "-1.5e-7"].map(|n| Ok(Num(n)))
expect ["01", "NaN", "", "1.", " 1", "1 ", "1 // c", "+1", ".5", "-", "0x", "1e", "1e5.5", "abc", "--1", "1,", "1e5x"].all(|n| Value.num(n).map_ok(|_| {}).map_err(|e| e.code) == Err("invalid-number"))
expect Value.num("01").map_ok(|_| {}) == Err({ code: "invalid-number", reason: "invalid number '01': not a number literal" })
expect {
	long = "9".repeat(2000)
	huge_exponent = "1e99999999999999999999999"
	Value.num(long).map_ok(Value.view) == Ok(Num(long)) and Value.num(huge_exponent).map_ok(Value.view) == Ok(Num(huge_exponent)) and Value.num("0x${"F".repeat(1200)}").is_ok()
}
expect ["A", "Z9", "Some_thing", "NaN"].all(|t| Value.tag(t, []).map_ok(Value.view) == Ok(Tag(t, [])))
expect ["lower", "", "_A", "9A", "A-B", "Ä", "A b"].all(|t| Value.tag(t, []).map_ok(|_| {}).map_err(|e| e.code) == Err("invalid-tag"))
expect Value.tag("lower", []).map_ok(|_| {}) == Err({ code: "invalid-tag", reason: "invalid tag 'lower': a tag is A to Z, then letters, digits and _" })
expect Value.rec([("a", Value.text("x")), ("b", Value.bool(True)), ("a", Value.arr([]))]).map_ok(|_| {}) == Err({ code: "duplicate-key", reason: "duplicate key 'a'" })
expect match Value.rec([("b", Value.text("x")), ("a", Value.bytes([0x0B]))]).map_ok(Value.view) {
	Ok(Rec([("b", x), ("a", y)])) => Value.to_test_json(x) == "\"x\"" and Value.to_test_json(y) == "{\"bytes\":\"0b\"}"
	_ => False
}
expect [Value.bool(True), Value.bool(False)].map(Value.to_test_json) == ["{\"tag\":\"True\"}", "{\"tag\":\"False\"}"]
# A value built in code is the same value parsed.
expect match (Value.num("0x10"), Value.parse("[Point(16, \"a\"), x\"ff\"]")) {
	(Ok(n), Ok(parsed)) =>
		match Value.tag("Point", [n, Value.text("a")]) {
			Ok(point) => Value.arr([point, Value.bytes([0xFF])]) == parsed
			Err(_) => False
		}
	_ => False
}
# `==` is structural: keys in the same order (haus equality is `Encode.equals`), and any depth.
expect Value.parse("{ a: 1E5, b: [Some(x\"FF\")] }") == Value.parse("{a:1e5,b:[Some(x\"ff\")]}") and Value.parse("{ a: 1, b: 2 }") != Value.parse("{ b: 2, a: 1 }")
expect Value.parse("[1.0, A(1)]") != Value.parse("[1, A(1)]") and Value.parse("A(1)") != Value.parse("A(1, 2)") and Value.parse("\"a\"") != Value.parse("x\"61\"")
expect nest_arrays(100_000, Text("a")) == nest_arrays(100_000, Text("a")) and nest_arrays(100_000, Text("a")) != nest_arrays(100_000, Text("b"))

## `leaf` in `n` arrays.
nest_arrays : U64, Value -> Value
nest_arrays = |n, leaf| {
	var $v = leaf
	var $i = 0
	while $i < n {
		$v = Arr([$v])
		$i = $i + 1
	}
	$v
}
