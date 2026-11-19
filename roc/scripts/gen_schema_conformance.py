#!/usr/bin/env python3
"""Generate roc/schema-test/ from the schema conformance suite (spec §15).

For each test-suite/schema/NAME.schema.haus, `haus-gen roc` writes the module
NAME.roc (its types, decoders and encoders), and SchemaTest.roc gets one
`expect` per case of NAME.cases.haus. The cases file is embedded as is and
parsed by the test, so the inputs keep their exact spelling. A schema whose
module changes without its attributes also gets NAMEBare.roc, generated with
`--without-attributes`, and each case runs on it too: attributes don't change
decoding or encoding (spec §15). Needs Rust (cargo) for haus-gen. Re-run after
changing test-suite/schema/ or roc.rs:

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
	var $v = Tag("Num", [Num("1")])
	var $i = 0
	while $i < 50_000 {
		$v = Tag("Neg", [Rec([("of", $v)])])
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
			Ok(values) => match values.get(i) {
				Ok(Tag("Ok", [Rec(fields)])) => match (field(fields, "type"), field(fields, "input")) {
					(Ok(Text(ty)), Ok(input)) => {
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
				Ok(Tag("Err", [Rec(fields)])) => match (field(fields, "type"), field(fields, "input"), field(fields, "code"), field(fields, "path")) {
					(Ok(Text(ty)), Ok(input), Ok(Text(code)), Ok(Text(path))) => match codec(ty, input) {
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

## The canonical form of a value that has one: every parsed or decoded value.
form : Value -> Str
form = |v| Encode.canonical(v) ?? "(no canonical form)"

"""
    + "\n\n".join(tests)
    + "\n"
    + (VALUES_BUILT_IN_CODE if "Types" in modules else ""),
    encoding="utf-8",
)
for f in [OUT / "main.roc", OUT / "SchemaTest.roc", *(OUT / f"{m}.roc" for m in modules)]:
    subprocess.run(["roc", "fmt", str(f)], check=True, capture_output=True)
print(f"wrote {OUT.relative_to(ROOT)}: {len(schemas)} schemas, {len(modules)} modules, {len(tests) - len(schemas)} expects")
