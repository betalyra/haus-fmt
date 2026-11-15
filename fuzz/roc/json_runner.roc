## The Roc runner of the JSON fuzzer (../README.md): `json_runner MODE FILE`
## reads one case per line and prints one line each, `ok …` or
## `err <place> <code> <reason>` (the place as spec §17 writes it, `$` for an
## error in the JSON text, and the error code; `-` for none):
## `write` and `read` (lines `SUITE TYPE HEX`) write and read plain JSON with
## a type (the modules that gen_json_schemas.ts generates), `lossless-write`
## and `lossless-read` (lines `HEX`) the lossless form, `schemaless` reads
## JSON without a schema. Reads print the canonical form of the value.
app [main!] {
	haus: "../../roc/package/main.roc",
	schemas: "../.build/roc-json/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import haus.Value
import haus.Decode
import haus.Encode
import haus.JsonValue
import haus.ErrorCode
import schemas.JsonSchemas

main! : List(OsStr) => Try({}, _)
main! = |args| {
	(mode, file) = match args.map(|a| OsStr.to_str_try(a) ?? "") {
		[m, f] => (m, f)
		_ => ("", "")
	}
	path : Path
	path = "${file}"
	bytes = path.read_bytes!()?
	var $line = []
	for b in bytes {
		if b == '\n' {
			Stdout.line!(run(mode, $line))?
			$line = []
		} else {
			$line = $line.append(b)
		}
	}
	Ok({})
}

run : Str, List(U8) -> Str
run = |mode, line| {
	if mode == "write" or mode == "read" {
		first = space(line, 0)
		second = space(line, first + 1)
		suite = text(line.sublist({ start: 0, len: first }))
		ty = text(line.sublist({ start: first + 1, len: second - first - 1 }))
		typed(mode, suite, ty, unhex(line.sublist({ start: second + 1, len: line.len() - second - 1 })))
	} else {
		untyped(mode, unhex(line))
	}
}

## `write` or `read` with a type.
typed : Str, Str, Str, List(U8) -> Str
typed = |mode, suite, ty, input| match Str.from_utf8(input) {
	Err(_) => "err $ invalid-utf8 invalid UTF-8"
	Ok(s) =>
		if mode == "write" {
			match Value.parse_all(s) {
				Ok([v]) => match JsonSchemas.write(suite, ty, v) {
					Written(Ok(json)) => "ok ${json}"
					Written(Err(e)) => "err ${clean(e)}"
					NoType => "crash no type ${suite}.${ty}"
				}
				_ => "err $ - not a single value"
			}
		} else {
			match JsonValue.parse(s) {
				Err(e) => "err $ ${e.code} ${clean(e.reason)}"
				Ok(j) => match JsonSchemas.read(suite, ty, j) {
					Read(Ok(v)) => "ok ${Encode.canonical(v)}"
					Read(Err(e)) => "err ${clean(e)}"
					NoType => "crash no type ${suite}.${ty}"
				}
			}
		}
}

## The modes without a type.
untyped : Str, List(U8) -> Str
untyped = |mode, input| match Str.from_utf8(input) {
	Err(_) => "err $ invalid-utf8 invalid UTF-8"
	Ok(s) => match mode {
		"lossless-write" => match Value.parse_all(s) {
			Ok([v]) => match JsonValue.to_lossless_json(v) {
				Ok(json) => "ok ${json}"
				Err(e) => "err ${ErrorCode.place(e.path)} ${e.code} ${clean(e.reason)}"
			}
			_ => "err $ - not a single value"
		}
		"lossless-read" => shown(JsonValue.from_lossless_json(s))
		"schemaless" => shown(JsonValue.from_json(s))
		_ => "crash bad mode ${mode}"
	}
}

shown : Try(Value, [Syntax(Value.ParseError), Decode(Decode.Error)]) -> Str
shown = |r| match r {
	Ok(v) => "ok ${Encode.canonical(v)}"
	Err(Syntax(e)) => "err $ ${e.code} ${clean(e.reason)}"
	Err(Decode(e)) => "err ${ErrorCode.place(e.path)} ${e.code} ${clean(e.reason)}"
}

## A reason on one line.
clean : Str -> Str
clean = |s| Str.from_utf8(s.to_utf8().map(|b| if b == '\n' or b == '\r' ' ' else b)) ?? "?"

unhex : List(U8) -> List(U8)
unhex = |hex| {
	var $bytes = []
	var $i = 0
	while $i + 1 < hex.len() {
		$bytes = $bytes.append(nibble(at(hex, $i)) * 16 + nibble(at(hex, $i + 1)))
		$i = $i + 2
	}
	$bytes
}

## The index of the next space from `from`, or the end.
space : List(U8), U64 -> U64
space = |line, from| {
	var $at = from
	while $at < line.len() and at(line, $at) != ' ' {
		$at = $at + 1
	}
	$at
}

text : List(U8) -> Str
text = |bs| match Str.from_utf8(bs) {
	Ok(s) => s
	Err(_) => ""
}

nibble : U8 -> U8
nibble = |c| if c >= 'a' c - 'a' + 10 else c - '0'

at : List(U8), U64 -> U8
at = |s, i| match s.get(i) {
	Ok(b) => b
	Err(_) => 0
}
