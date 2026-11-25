#!/usr/bin/env python3
"""Generate roc/schema-test/ from the schema conformance suite (spec §15).

For each test-suite/schema/NAME.schema.haus, `haus-gen roc` writes the module
NAME.roc (its types, decoders and encoders), and SchemaTest.roc gets one
`expect` per case of NAME.cases.haus. The cases file is embedded as is and
parsed by the test, so the inputs keep their exact spelling. A schema whose
module changes without its attributes also gets NAMEBare.roc, generated with
`--without-attributes`, and each case runs on it too: attributes don't change
decoding or encoding (spec §15). The typed streams of the stream suite
(test-suite/stream/typed.schema.haus, typed.cases.haus) run here too, on the
module StreamTyped. Needs Rust (cargo) for haus-gen. Re-run after changing
test-suite/schema/, test-suite/stream/typed.schema.haus or roc.rs:

    python3 roc/scripts/gen_schema_conformance.py
    cd roc/schema-test && roc test main.roc
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "test-suite" / "schema"
OUT = ROOT / "roc" / "schema-test"


def pascal(s: str) -> str:
    return "".join(w[:1].upper() + w[1:] for w in re.split(r"[^A-Za-z0-9]+", s) if w)


def snake(s: str) -> str:
    """Like `snake` in rust/haus-build/src/roc.rs: `IntPair` → `int_pair`."""
    out = ""
    for i, c in enumerate(s):
        if c.isascii() and c.isupper():
            if i > 0 and not out.endswith("_"):
                out += "_"
            out += c.lower()
        elif c.isascii() and c.isalnum():
            out += c
        elif out and not out.endswith("_"):
            out += "_"
    return out


def roc_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'


def haus_gen(*args: str) -> str:
    """The module haus-gen writes for these arguments."""
    return subprocess.run(
        ["cargo", "run", "-q", "--manifest-path", str(ROOT / "rust" / "Cargo.toml"), "-p", "haus-fmt-build", "--bin", "haus-gen", "--", *args],
        check=True,
        stdout=subprocess.PIPE,
        encoding="utf-8",
    ).stdout


def codec(name: str, schema: Path, module: str, types: list[str], label: str = "") -> str:
    """`name : Str, Value -> Codec`: decode a value with a type of the module, and encode the result."""
    arms = "".join(
        f'\t\t{roc_str(t)} => Decoded(encoded({module}.decode_{snake(t)}(v), {module}.encode_{snake(t)}))\n' for t in types
    )
    return (
        f"\t## Decode a value with a type of {schema.name}{label}, and encode the result.\n"
        f"\t{name} : Str, Value -> Codec\n"
        f"\t{name} = |ty, v| match ty {{\n{arms}\t\t_ => NoType\n\t}}\n"
    )


OUT.mkdir(exist_ok=True)
schemas = sorted(SUITE.glob("*.schema.haus"))
# Generated code with values built in code (spec §9.8), with `Expr` of
# types.schema.haus: a decoder checks the depth before it recurses, and an
# encoder counts the values it makes.
VALUES_BUILT_IN_CODE = """
# A value built far deeper than the parser takes (50,000 levels; `roc test`
# can't drop much deeper ones of this shape): the decoder stops at the depth limit.
expect {
	var $v = Value.tag("Num", [Value.num("1") ?? Value.text("")]) ?? Value.text("")
	var $i = 0
	while $i < 50_000 {
		$v = Value.tag("Neg", [Value.rec([("of", $v)]) ?? $v]) ?? $v
		$i = $i + 1
	}
	Types.decode_expr($v).map_ok(|_| {}).map_err(|e| (e.code, e.path == "(Neg).of".repeat(256))) == Err(("nesting-too-deep", True))
}

# A value whose parts are shared: 2^41 − 1 values written out. The encoder
# stops at the budget, a step per value.
expect {
	var $x = Types.Expr.Num(Int.from_i128(1))
	var $i = 0
	while $i < 40 {
		$x = Types.Expr.Add($x, $x)
		$i = $i + 1
	}
	budget = |max| { ..Value.default_limits, max_steps: max }
	small = Types.Expr.Add(Types.Expr.Num(Int.from_i128(1)), Types.Expr.Num(Int.from_i128(2)))
	shared = Encode.value_with($x, Types.encode_expr, budget(100_000)).map_err(|e| e.code).map_ok(|_| {}) == Err("step-budget")
	# `Add(Num(1), Num(2))`: five values.
	shared and Encode.value_with(small, Types.encode_expr, budget(5)).map_ok(form) == Ok("Add(Num(1),Num(2))") and Encode.value_with(small, Types.encode_expr, budget(4)).is_err()
}
"""

modules, imports, codecs, tests = [], [], [], []
for schema in schemas:
    name = schema.name.removesuffix(".schema.haus")
    module = pascal(name)
    modules.append(module)
    code = haus_gen("roc", str(schema), "--module", module)
    (OUT / f"{module}.roc").write_text(code, encoding="utf-8")
    # Without attributes: a module of its own if that changes the code at all.
    bare = haus_gen("roc", str(schema), "--module", f"{module}Bare", "--without-attributes")
    has_bare = bare.replace(f"{module}Bare", module) != code
    if has_bare:
        modules.append(f"{module}Bare")
        (OUT / f"{module}Bare.roc").write_text(bare, encoding="utf-8")

    # The non-generic definitions are the types a case can name.
    types = re.findall(r"^type\s+([A-Z][A-Za-z0-9_]*)\s*=", schema.read_text(encoding="utf-8"), re.M)
    codecs.append(codec(snake(name), schema, module, types))
    if has_bare:
        codecs.append(codec(f"{snake(name)}_bare", schema, f"{module}Bare", types, " without its attributes"))

    cases = SUITE / f"{name}.cases.haus"
    src = f"{snake(name)}_cases"
    imports.append(f'import "../../test-suite/schema/{cases.name}" as {src} : Str')
    # One case per line in the suite; the test checks the count, so a case
    # spread over several lines fails instead of being skipped.
    lines = [l.strip() for l in cases.read_text(encoding="utf-8").splitlines() if re.match(r"\s*(Ok|Err)\s*\{", l)]
    tests.append(f"# {cases.name}\nexpect SchemaTest.count({src}) == {len(lines)}")
    for i, line in enumerate(lines):
        tests.append(f"# {line}\nexpect SchemaTest.check({src}, {i}, SchemaTest.{snake(name)})")
        if has_bare:
            tests.append(f"# Without attributes: {line}\nexpect SchemaTest.check({src}, {i}, SchemaTest.{snake(name)}_bare)")

# Streams decoded with a type (test-suite/stream/typed.*, spec §15 "Streams"):
# the module StreamTyped from typed.schema.haus. A `Stream a` type has no
# decoder of its own (haus-gen writes a comment): its items decode with
# `Decode.all`, the binding's stream decoding, which puts the item's index in
# the path; any other type with `Decode.one`. Every case runs in one `expect`,
# which reports each failing case, so the file can change without
# regenerating this module.
STREAM = ROOT / "test-suite" / "stream"
typed_schema = STREAM / "typed.schema.haus"
modules.append("StreamTyped")
(OUT / "StreamTyped.roc").write_text(haus_gen("roc", str(typed_schema), "--module", "StreamTyped"), encoding="utf-8")
typed_text = typed_schema.read_text(encoding="utf-8")
typed_streams = dict(re.findall(r"^type\s+([A-Z][A-Za-z0-9_]*)\s*=\s*Stream\s+([A-Z][A-Za-z0-9_]*)\s*$", typed_text, re.M))
# Items of a prelude type decode with the package's own decoders.
PRELUDE_CODERS = {"String": ("Decode.str", "Encode.str")}


def item_coders(item: str) -> tuple[str, str]:
    return PRELUDE_CODERS.get(item, (f"StreamTyped.decode_{snake(item)}", f"StreamTyped.encode_{snake(item)}"))


typed_arms = "".join(
    "\t{} => Decoded(encoded_items(Decode.all(text, {}), {}))\n".format(roc_str(t), *item_coders(item))
    if (item := typed_streams.get(t))
    else f"\t{roc_str(t)} => Decoded(encoded_one(Decode.one(text, StreamTyped.decode_{snake(t)}), StreamTyped.encode_{snake(t)}))\n"
    for t in re.findall(r"^type\s+([A-Z][A-Za-z0-9_]*)\s*=", typed_text, re.M)
)
imports.append('import "../../test-suite/stream/typed.cases.haus" as typed_cases : Str')
tests.append("# stream/typed.cases.haus\nexpect typed_streams(typed_cases)")
TYPED_STREAMS = (
    """
## Every case of stream/typed.cases.haus: `Ok { type, text, output }` decodes
## `text` with `type`, and encoding the result gives `output` (an array, a
## value per item, for a stream), compared as values; `Err { type, text, code,
## path }` fails with `code` at `path`. A parse error has no path: its place is
## the whole document, `$` (the one case: `not-one-value`).
typed_streams : Str -> Bool
typed_streams = |cases| match Value.parse_all(cases) {
	Ok(all) => {
		failures = all.keep_oks(
			|c| match typed_case(c) {
				Ok({}) => Err({})
				Err(reason) => Ok("${form(c)}: ${reason}")
			},
		)
		if failures.is_empty() {
			!all.is_empty()
		} else {
			dbg failures
			False
		}
	}
	Err(e) => {
		dbg e.reason
		False
	}
}

## What decoding a text gave: the result encoded again, or the error's code,
## place and message.
Typed : [Decoded(Try(Value, (Str, Str, Str))), NoType]

typed_case : Value -> Try({}, Str)
typed_case = |c| match case_of(c) {
	Ok((tag, fields)) => match (tag, text_field(fields, "type"), text_field(fields, "text")) {
		("Ok", Ok(ty), Ok(text)) => {
			want = field(fields, "output") ?? Value.text("(no output)")
			match stream_typed(ty, text) {
				Decoded(Ok(got)) if Encode.equals(got, want) == Ok(True) => Ok({})
				Decoded(Ok(got)) => Err("wrote ${form(got)}")
				Decoded(Err((code, place, message))) => Err("failed with ${code} at ${place}: ${message}")
				NoType => Err("the schema has no type ${ty}")
			}
		}
		("Err", Ok(ty), Ok(text)) => match (text_field(fields, "code"), text_field(fields, "path")) {
			(Ok(code), Ok(path)) => match stream_typed(ty, text) {
				Decoded(Err((got_code, got_place, _))) if got_code == code and got_place == path => Ok({})
				Decoded(Err((got_code, got_place, message))) => Err("failed with ${got_code} at ${got_place}: ${message}")
				Decoded(Ok(got)) => Err("decoded, and wrote ${form(got)}")
				NoType => Err("the schema has no type ${ty}")
			}
			_ => Err("a case without a code or a path")
		}
		_ => Err("not a case")
	}
	_ => Err("not a case")
}

## Decode `text` with a type of stream/typed.schema.haus, and encode the result.
stream_typed : Str, Str -> Typed
stream_typed = |ty, text| match ty {
"""
    + typed_arms
    + """	_ => NoType
}

## A failed read: its code, its place (`$` for a parse error) and its message.
read_error : [Syntax(Value.ParseError), Decode(Decode.Error)] -> (Str, Str, Str)
read_error = |e| match e {
	Syntax(p) => (p.code, "$", "${p.reason} at ${p.line.to_str()}:${p.column.to_str()}")
	Decode(d) => (d.code, ErrorCode.place(d.path), Decode.message(d))
}

## The decoded items of a stream, each encoded again: an array.
encoded_items : Try(List(a), [Syntax(Value.ParseError), Decode(Decode.Error)]), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)) -> Try(Value, (Str, Str, Str))
encoded_items = |decoded, encode| {
	items = decoded.map_err(read_error)?
	var $out = []
	for x in items {
		$out = $out.append(Encode.value(x, encode).map_err(|e| (e.code, "(encoding)", Encode.message(e)))?)
	}
	Ok(Value.arr($out))
}

## The decoded value, encoded again.
encoded_one : Try(a, [Syntax(Value.ParseError), Decode(Decode.Error)]), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)) -> Try(Value, (Str, Str, Str))
encoded_one = |decoded, encode| {
	x = decoded.map_err(read_error)?
	Encode.value(x, encode).map_err(|e| (e.code, "(encoding)", Encode.message(e)))
}
"""
)

(OUT / "main.roc").write_text(
    "# GENERATED by roc/scripts/gen_schema_conformance.py. Do not edit.\n"
    f"package [SchemaTest, {', '.join(modules)}] {{ haus: \"../package/main.roc\" }}\n",
    encoding="utf-8",
)
(OUT / "SchemaTest.roc").write_text(
    "# GENERATED by roc/scripts/gen_schema_conformance.py from test-suite/schema/. Do not edit.\n"
    "import haus.Value\n"
    "import haus.Decode\n"
    "import haus.Encode\n"
    "import haus.ErrorCode\n"
    "import haus.Int\n"
    + "".join(f"import {m}\n" for m in modules)
    + "\n".join(imports)
    + """

SchemaTest := [].{
	## The result of decoding a value with a type of a schema, encoded again.
	Codec : [Decoded(Try(Value, Decode.Error)), NoType]

	## How many cases a cases file has.
	count : Str -> U64
	count = |cases| match Value.parse_all(cases) {
		Ok(values) => values.len()
		Err(_) => 0
	}

	## Case `i` of a cases file (see test-suite/schema/numbers.cases.haus):
	## `Ok { type, input, output? }` decodes `input` with `type`, and encoding
	## the result gives the canonical form of `output` (or of `input`), which
	## the writer takes; `Err { type, input, code, path }` doesn't decode, and
	## fails with the error code `code` (spec §17) at the place `path`
	## (spec §15, as `ErrorCode.place` writes it), compared as text.
	check : Str, U64, (Str, Value -> Codec) -> Bool
	check = |cases, i, codec| {
		ok = match Value.parse_all(cases) {
			Ok(values) => match values.get(i).map_ok(case_of) {
				Ok(Ok(("Ok", fields))) => match (text_field(fields, "type"), field(fields, "input")) {
					(Ok(ty), Ok(input)) => {
						want = field(fields, "output") ?? input
						match codec(ty, input) {
							# The writer takes it too (it checks what it writes).
							Decoded(Ok(got)) if Encode.equals(got, want) == Ok(True) => Encode.to_str(got).map_ok(|_| {}).map_err(|e| "can't be written: ${Encode.message(e)}")
							Decoded(Ok(got)) => Err("wrote ${form(got)}, expected ${form(want)}")
							Decoded(Err(e)) => Err("didn't decode: ${Decode.message(e)}")
							NoType => Err("the schema has no type ${ty}")
						}
					}
					_ => Err("a case without a type or an input")
				}
				Ok(Ok(("Err", fields))) => match (text_field(fields, "type"), field(fields, "input"), text_field(fields, "code"), text_field(fields, "path")) {
					(Ok(ty), Ok(input), Ok(code), Ok(path)) => match codec(ty, input) {
						Decoded(Err(e)) if e.code == code and ErrorCode.place(e.path) == path => Ok({})
						Decoded(Err(e)) => Err("failed with ${e.code} at ${ErrorCode.place(e.path)}, expected ${code} at ${path}: ${Decode.message(e)}")
						Decoded(Ok(got)) => Err("decoded, and wrote ${form(got)}")
						NoType => Err("the schema has no type ${ty}")
					}
					_ => Err("a case without a type, an input, a code or a path")
				}
				_ => Err("no case ${i.to_str()}")
			}
			Err(e) => Err("the cases don't parse: ${e.reason}")
		}
		match ok {
			Ok({}) => True
			Err(reason) => {
				dbg reason
				False
			}
		}
	}

"""
    + "\n".join(codecs)
    + """}

## The decoded value, encoded again.
encoded : Try(a, Decode.Error), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)) -> Try(Value, Decode.Error)
encoded = |decoded, encode| Encode.value(decoded?, encode)

field : List((Str, Value)), Str -> Try(Value, [Missing])
field = |fields, key| match fields.find_first(|(k, _)| k == key) {
	Ok((_, v)) => Ok(v)
	Err(_) => Err(Missing)
}

## A field that is a string.
text_field : List((Str, Value)), Str -> Try(Str, [Missing])
text_field = |fields, key| match field(fields, key).map_ok(Value.view) {
	Ok(Text(s)) => Ok(s)
	_ => Err(Missing)
}

## A case, `Ok { … }` or `Err { … }`: its tag and its fields.
case_of : Value -> Try((Str, List((Str, Value))), [NotACase])
case_of = |c| match c.view() {
	Tag(tag, [payload]) => match payload.view() {
		Rec(fields) => Ok((tag, fields))
		_ => Err(NotACase)
	}
	_ => Err(NotACase)
}

## The canonical form of a value that has one: every parsed or decoded value.
form : Value -> Str
form = |v| Encode.canonical(v) ?? "(no canonical form)"

"""
    + "\n\n".join(tests)
    + "\n"
    + TYPED_STREAMS
    + (VALUES_BUILT_IN_CODE if "Types" in modules else ""),
    encoding="utf-8",
)
for f in [OUT / "main.roc", OUT / "SchemaTest.roc", *(OUT / f"{m}.roc" for m in modules)]:
    subprocess.run(["roc", "fmt", str(f)], check=True, capture_output=True)
print(f"wrote {OUT.relative_to(ROOT)}: {len(schemas)} schemas, {len(modules)} modules, {len(tests) - len(schemas)} expects")
