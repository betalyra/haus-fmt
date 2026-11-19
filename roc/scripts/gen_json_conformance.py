#!/usr/bin/env python3
"""Generate roc/json-test/ from the JSON suite (test-suite/json, spec §16).

`haus-gen roc --json` writes SchemaBased.roc for
test-suite/json/schema-based.schema.haus, and JsonTest.roc gets one `expect`
per case of schema-based.cases.haus, self-describing.cases.haus and
import.cases.haus, and one per valid/NAME.jsonl of the conformance suite
(each a self-describing case: JSON Lines, one envelope per value of the
file). The cases files are embedded as they are and parsed by the
test. Each schema of test-suite/schema is also generated with JSON
(NAMEJson.roc), so that the JSON code of every kind of type compiles. Needs
Rust (cargo) for haus-gen. Re-run after changing test-suite/ or roc.rs:

    python3 roc/scripts/gen_json_conformance.py
    cd roc/json-test && roc test main.roc
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUITE = ROOT / "test-suite"
OUT = ROOT / "roc" / "json-test"


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


def cases(path: Path) -> list[str]:
    """The cases of a file, one per line in the suite; the test checks the
    count, so a case spread over several lines fails instead of being skipped."""
    return [l.strip() for l in path.read_text(encoding="utf-8").splitlines() if re.match(r"\s*(Ok|Err|Read)\s*\{", l)]


OUT.mkdir(exist_ok=True)
modules = ["SchemaBased"]
schema_based = SUITE / "json" / "schema-based.schema.haus"
(OUT / "SchemaBased.roc").write_text(haus_gen("roc", str(schema_based), "--module", "SchemaBased", "--json"), encoding="utf-8")
# Every kind of type, with JSON: these only have to compile.
for schema in sorted((SUITE / "schema").glob("*.schema.haus")):
    module = pascal(schema.name.removesuffix(".schema.haus")) + "Json"
    modules.append(module)
    (OUT / f"{module}.roc").write_text(haus_gen("roc", str(schema), "--module", module, "--json"), encoding="utf-8")

types = [t for t in re.findall(r"^type\s+([A-Z][A-Za-z0-9_]*)\s*=", schema_based.read_text(encoding="utf-8"), re.M)]
write_arms = "".join(f"\t{roc_str(t)} => written(SchemaBased.decode_{snake(t)}(v), SchemaBased.to_json_{snake(t)})\n" for t in types)
read_arms = "".join(
    f"\t{roc_str(t)} => encoded(SchemaBased.from_json_{snake(t)}(j), SchemaBased.encode_{snake(t)})\n" for t in types
)

imports, tests = [], []
for name, kind in [("schema-based", "schema_based"), ("self-describing", "self_describing"), ("import", "imported")]:
    path = SUITE / "json" / f"{name}.cases.haus"
    src = f"{name.replace('-', '_')}_cases"
    imports.append(f'import "../../test-suite/json/{path.name}" as {src} : Str')
    lines = cases(path)
    tests.append(f"# json/{path.name}\nexpect JsonTest.count({src}) == {len(lines)}")
    tests.extend(f"# {line}\nexpect JsonTest.{kind}({src}, {i})" for i, line in enumerate(lines))
# The depth of the value read from schema-based JSON (spec §16, "Limits"): `Loop`
# is a level per `Some`; `OptLoop` (`Maybe Loop`) one more, as its own `Some`
# is the `Loop` itself.
for ty, n in [("Loop", 256), ("OptLoop", 255)]:
    tests.append(
        f"# {ty}: {n} nested Somes read, {n + 1} don't\n"
        f'expect JsonTest.somes("{ty}", {n}) == Ok({{}})\n'
        f'expect JsonTest.somes("{ty}", {n + 1}) == Err("nesting deeper than 256 levels")'
    )
# A record case is the same inline (`ParenBox`), by name (`Boxed`), through an
# alias (`AliasBox`) or an applied generic type (`Found`), spec §15: the same JSON,
# and the same Roc record in the case. A type parameter (`GenRec`) is not one.
tests.append(
    """# record cases: the same JSON and Roc record, however the record is written
expect {
	v = Tag("Box", [Rec([("w", Num("1"))])])
	json = written(SchemaBased.decode_boxed(v), SchemaBased.to_json_boxed)
	same = written(SchemaBased.decode_paren_box(v), SchemaBased.to_json_paren_box) == json and written(SchemaBased.decode_alias_box(v), SchemaBased.to_json_alias_box) == json
	json == Ok("{\\"_tag\\":\\"Box\\",\\"w\\":1}") and same
}
expect {
	v = Tag("Box", [Rec([("w", Num("1"))])])
	boxed = match SchemaBased.decode_boxed(v) {
		Ok(Box(r)) => Ok(r)
		_ => Err({})
	}
	paren = match SchemaBased.decode_paren_box(v) {
		Ok(Box(r)) => Ok(r)
		_ => Err({})
	}
	alias = match SchemaBased.decode_alias_box(v) {
		Ok(Box(r)) => Ok(r)
		_ => Err({})
	}
	boxed == Ok({ w: 1 }) and paren == boxed and alias == boxed
}
expect written(SchemaBased.decode_found(Tag("Found", [Rec([("items", Arr([Num("1")]))])])), SchemaBased.to_json_found) == Ok("{\\"_tag\\":\\"Found\\",\\"items\\":[1]}")
expect written(SchemaBased.decode_gen_rec(Tag("Box", [Rec([("w", Num("1"))])])), SchemaBased.to_json_gen_rec) == Ok("{\\"_tag\\":\\"Box\\",\\"value\\":{\\"w\\":1}}")
# by name, any payload but one record is the wrong payload, as inline
expect [SchemaBased.decode_boxed(Tag("Box", [Num("1")])), SchemaBased.decode_boxed(Tag("Box", [])), SchemaBased.decode_boxed(Tag("Box", [Num("1"), Num("2")]))].map(|r| r.map_ok(|_| {}).map_err(|e| e.code)) == [Err("wrong-payload"), Err("wrong-payload"), Err("wrong-payload")]"""
)
for path in sorted((SUITE / "valid").glob("*.haus")):
    name = "valid_" + re.sub(r"[^a-z0-9]", "_", path.stem.lower())
    imports.append(f'import "../../test-suite/valid/{path.name}" as {name} : List(U8)')
    imports.append(f'import "../../test-suite/valid/{path.stem}.jsonl" as {name}_jsonl : List(U8)')
    tests.append(f"# valid/{path.stem}.jsonl\nexpect JsonTest.valid({name}, {name}_jsonl)")

(OUT / "main.roc").write_text(
    "# GENERATED by roc/scripts/gen_json_conformance.py. Do not edit.\n"
    f"package [JsonTest, {', '.join(modules)}] {{ haus: \"../package/main.roc\" }}\n",
    encoding="utf-8",
)
(OUT / "JsonTest.roc").write_text(
    "# GENERATED by roc/scripts/gen_json_conformance.py from test-suite/json/. Do not edit.\n"
    "import haus.Value\n"
    "import haus.Decode\n"
    "import haus.Encode\n"
    "import haus.JsonValue\n"
    "import haus.ToJson\n"
    "import SchemaBased\n"
    + "\n".join(imports)
    + """

JsonTest := [].{
	## How many cases a cases file has.
	count : Str -> U64
	count = |cases| match Value.parse_all(cases) {
		Ok(values) => values.len()
		Err(_) => 0
	}

	## Case `i` of schema-based.cases.haus (spec §16.3): `Ok { type, input,
	## json, output? }` writes the decoded `input` as `json`, and reading
	## `json` gives a value that encodes to `output` (or `input`); `Read {
	## type, json, output }` reads `json` as `output`; `Err { type, json, code }`
	## doesn't read, and fails with the error code `code` (spec §17).
	schema_based : Str, U64 -> Bool
	schema_based = |cases, i| report(schema_based_case(cases, i))

	## Case `i` of self-describing.cases.haus (spec §16.2): `Ok { input, json }`
	## writes `input` as `json` and reads it back; `Err { json, code }` doesn't
	## read, with the error code `code`.
	self_describing : Str, U64 -> Bool
	self_describing = |cases, i| report(self_describing_case(cases, i))

	## Case `i` of import.cases.haus (spec §16.1): `Read { json, output }`
	## reads `json` as `output`; `Err { json, code }` doesn't read, with the
	## error code `code`.
	imported : Str, U64 -> Bool
	imported = |cases, i| report(import_case(cases, i))

	## A valid file of the conformance suite and its NAME.jsonl: its values
	## as self-describing JSON Lines, both ways.
	valid : List(U8), List(U8) -> Bool
	valid = |haus, jsonl| report(valid_case(haus, jsonl))

	## Reading `n` nested `{"_tag": "Some", "value": …}` around
	## `{"_tag": "None"}` with the type `ty` (`Loop`, `OptLoop`). The haus
	## value must nest at most 256 levels (spec §16, "Limits").
	somes : Str, U64 -> Try({}, Str)
	somes = |ty, n| {
		some = "{\\"_tag\\":\\"Some\\",\\"value\\":"
		close = "}"
		json = "${some.repeat(n)}{\\"_tag\\":\\"None\\"}${close.repeat(n)}"
		read(ty, JsonValue.parse(json).map_err(|e| e.reason)?).map_ok(|_| {}).map_err(Decode.message)
	}
}

schema_based_case : Str, U64 -> Try({}, Str)
schema_based_case = |cases, i| {
	(tag, fields) = case(cases, i)?
	ty = text(fields, "type")?
	json = text(fields, "json")?
	match tag {
		"Ok" => {
			input = value(fields, "input")?
			got = write(ty, input)?
			if same_json(got, json)? {
				read_as(ty, json, value(fields, "output") ?? input)
			} else {
				Err("wrote ${got}")
			}
		}
		"Read" => read_as(ty, json, value(fields, "output")?)
		_ => {
			code = text(fields, "code")?
			match JsonValue.parse(json) {
				Ok(j) => match read(ty, j) {
					Ok(v) => Err("read as ${Encode.canonical(v)}")
					Err(e) => same_code(code, e.code, Decode.message(e))
				}
				Err(e) => same_code(code, e.code, e.reason)
			}
		}
	}
}

self_describing_case : Str, U64 -> Try({}, Str)
self_describing_case = |cases, i| {
	(tag, fields) = case(cases, i)?
	json = text(fields, "json")?
	match tag {
		"Ok" => {
			input = value(fields, "input")?
			got = JsonValue.to_haus_json(input).map_err(Encode.message)?
			if same_json(got, json)? reads_back(json, input) else Err("wrote ${got}")
		}
		_ => rejected(JsonValue.from_haus_json(json), text(fields, "code")?)
	}
}

import_case : Str, U64 -> Try({}, Str)
import_case = |cases, i| {
	(tag, fields) = case(cases, i)?
	json = text(fields, "json")?
	match (tag, JsonValue.import_json(json)) {
		("Read", Ok(v)) => {
			want = value(fields, "output")?
			if Encode.equals(v, want) Ok({}) else Err("read as ${Encode.canonical(v)}")
		}
		("Read", Err(_)) => Err("can't read it")
		(_, result) => rejected(result, text(fields, "code")?)
	}
}

## Reading failed with the error code `code` (spec §17).
rejected : Try(Value, [Syntax(Value.ParseError), Decode(Decode.Error)]), Str -> Try({}, Str)
rejected = |result, code| match result {
	Ok(v) => Err("read as ${Encode.canonical(v)}")
	Err(Syntax(e)) => same_code(code, e.code, e.reason)
	Err(Decode(e)) => same_code(code, e.code, Decode.message(e))
}

same_code : Str, Str, Str -> Try({}, Str)
same_code = |want, got, message| if (got == want) Ok({}) else Err("failed with ${got}, expected ${want}: ${message}")

valid_case : List(U8), List(U8) -> Try({}, Str)
valid_case = |haus, jsonl| {
	values = Value.parse_bytes(haus).map_err(|e| e.reason)?
	want = Str.from_utf8(jsonl).map_err(|_| "the JSON Lines aren't UTF-8")?
	got = JsonValue.to_haus_json_lines(values).map_err(Encode.message)?
	want_lines = JsonValue.lines(want).map_err(|e| "${want}: ${e.reason}")?
	got_lines = JsonValue.lines(got).map_err(|e| "${got}: ${e.reason}")?
	if want_lines.map(sorted) != got_lines.map(sorted) {
		return Err("wrote ${got}")
	}
	match JsonValue.from_haus_json_lines(want) {
		Ok(back) if back.len() == values.len() and back.map2(values, Encode.equals).all(|same| same) => Ok({})
		Ok(back) => Err("read as ${Str.join_with(back.map(Encode.canonical), ", ")}")
		Err(_) => Err("can't read it")
	}
}

## Reading the self-describing `json` gives a value equal to `want`.
reads_back : Str, Value -> Try({}, Str)
reads_back = |json, want| match JsonValue.from_haus_json(json) {
	Ok(v) if Encode.equals(v, want) => Ok({})
	Ok(v) => Err("read as ${Encode.canonical(v)}")
	Err(_) => Err("can't read it")
}

## Decode `v` with the type `ty` of schema-based.schema.haus, and write the result as schema-based JSON.
write : Str, Value -> Try(Str, Str)
write = |ty, v| match ty {
"""
    + write_arms
    + """	_ => Err("no type ${ty}")
}

## Read `j` with the type `ty` of schema-based.schema.haus, and encode the result.
read : Str, JsonValue -> Try(Value, Decode.Error)
read = |ty, j| match ty {
"""
    + read_arms
    + """	_ => Decode.fail("no-type", "no type ${ty}")
}

## The value read, encoded as haus.
encoded : Try(a, Decode.Error), (a, Encode.Encoder -> Try(Encode.Encoded(Value), Encode.Error)) -> Try(Value, Decode.Error)
encoded = |read_value, encode| Encode.value(read_value?, encode)

## The decoded value written as JSON text.
written : Try(a, Decode.Error), (a, Encode.Encoder -> Try(Encode.Encoded(JsonValue), Encode.Error)) -> Try(Str, Str)
written = |decoded, to_json| match decoded {
	Ok(x) => match ToJson.value(x, to_json) {
		Ok(j) => JsonValue.to_str(j).map_err(Encode.message)
		Err(e) => Err("can't write it: ${Encode.message(e)}")
	}
	Err(e) => Err("can't decode the input: ${Decode.message(e)}")
}

## Reading `json` with `ty` gives a value equal to `want`.
read_as : Str, Str, Value -> Try({}, Str)
read_as = |ty, json, want| {
	j = JsonValue.parse(json).map_err(|e| "can't parse the JSON: ${e.reason}")?
	got = read(ty, j).map_err(Decode.message)?
	if Encode.equals(got, want) Ok({}) else Err("read as ${Encode.canonical(got)}")
}

## Whether two JSON texts are the same data: member order and whitespace
## don't matter, numbers compare by their text.
same_json : Str, Str -> Try(Bool, Str)
same_json = |a, b| {
	x = JsonValue.parse(a).map_err(|e| "${a}: ${e.reason}")?
	y = JsonValue.parse(b).map_err(|e| "${b}: ${e.reason}")?
	Ok(sorted(x) == sorted(y))
}

## JSON with every object's members sorted by name.
sorted : JsonValue -> JsonValue
sorted = |j| match j {
	Array(items) => Array(items.map(sorted))
	Object(members) => Object(members.map(|(k, v)| (k, sorted(v))).sort_with(|(a, _), (b, _)| compare(a.to_utf8(), b.to_utf8())))
	other => other
}

compare : List(U8), List(U8) -> [Before, Same, After]
compare = |a, b| {
	var $i = 0
	while $i < a.len() and $i < b.len() {
		x = a.get($i) ?? 0
		y = b.get($i) ?? 0
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

## Case `i` of a cases file: its tag and fields.
case : Str, U64 -> Try((Str, List((Str, Value))), Str)
case = |cases, i| match Value.parse_all(cases) {
	Ok(values) => match values.get(i) {
		Ok(Tag(tag, [Rec(fields)])) => Ok((tag, fields))
		_ => Err("no case ${i.to_str()}")
	}
	Err(e) => Err("the cases don't parse: ${e.reason}")
}

value : List((Str, Value)), Str -> Try(Value, Str)
value = |fields, key| match fields.find_first(|(k, _)| k == key) {
	Ok((_, v)) => Ok(v)
	Err(_) => Err("a case without ${key}")
}

text : List((Str, Value)), Str -> Try(Str, Str)
text = |fields, key| match value(fields, key)? {
	Text(s) => Ok(s)
	_ => Err("a case whose ${key} isn't a string")
}

report : Try({}, Str) -> Bool
report = |result| match result {
	Ok({}) => True
	Err(reason) => {
		dbg reason
		False
	}
}

"""
    + "\n\n".join(tests)
    + "\n",
    encoding="utf-8",
)
for f in [OUT / "main.roc", OUT / "JsonTest.roc", *(OUT / f"{m}.roc" for m in modules)]:
    subprocess.run(["roc", "fmt", str(f)], check=True, capture_output=True)
print(f"wrote {OUT.relative_to(ROOT)}: {len(modules)} modules, {len(tests)} expects")
