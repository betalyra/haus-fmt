## The fuzzing runner (../../fuzz/README.md): `runner [--stream] DIR N` parses
## DIR/00000.haus … DIR/{N-1}.haus and prints one line each: `ok <values>` in
## the test-suite JSON encoding, or `err <line> <column> <code> <reason>` with
## the error code of spec §17 (invalid UTF-8 at `0 0`, as the other runners
## that report codes give it). With
## `--stream`, each file goes through the stream reader in chunks (see `chunks`);
## with `--canonical`, `ok` is followed by the canonical form of each value
## (spec §12) as a JSON array of strings.
app [main!] {
	haus: "../package/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import haus.Encode
import haus.ErrorCode
import haus.Streaming
import haus.Value

main! : List(OsStr) => Try({}, _)
main! = |args| {
	(mode, dir, n) = match args.map(|a| OsStr.to_str_try(a) ?? "") {
		["--stream", d, count] => (Stream, d, U64.from_str(count) ?? 0)
		["--canonical", d, count] => (Canonical, d, U64.from_str(count) ?? 0)
		[d, count] => (Parse, d, U64.from_str(count) ?? 0)
		_ => (Parse, "", 0)
	}
	var $i = 0
	while $i < n {
		path : Path
		path = "${dir}/${pad($i)}.haus"
		bytes = path.read_bytes!()?
		output = match mode {
			Stream => line(streamed(bytes, $i))
			Canonical => canonical_line(Value.parse_bytes(bytes))
			Parse => line(Value.parse_bytes(bytes))
		}
		Stdout.line!(output)?
		$i = $i + 1
	}
	Ok({})
}

line : Try(List(Value), Value.ParseError) -> Str
line = |result| match result {
	Ok(values) => "ok [${Str.join_with(values.map(Value.to_test_json), ",")}]"
	# One line per case: line breaks in the reason are written as \n.
	Err({ code, reason, line: l, column }) => {
		place = if (code == ErrorCode.invalid_utf8) "0 0" else "${l.to_str()} ${column.to_str()}"
		"err ${place} ${code} ${reason.replace_each("\r", "\\r").replace_each("\n", "\\n")}"
	}
}

## With `--canonical`: the canonical form of each value (spec §12), as JSON
## strings. A value without one (`number-too-long`, which the default number
## limit rules out) is an `err` at line and column 0.
canonical_line : Try(List(Value), Value.ParseError) -> Str
canonical_line = |result| match result.map_ok(|values| values.map_try(Encode.canonical)) {
	Ok(Ok(forms)) => "ok [${Str.join_with(forms.map(|form| Value.to_test_json(Text(form))), ",")}]"
	Ok(Err(e)) => "err 0 0 ${e.code} ${e.reason}"
	Err(e) => line(Err(e))
}

## The chunks of case `i`, the same in every runner: chunk k has size
## sizes[(i + k) % 7], so cuts fall inside escapes, comments and UTF-8 sequences.
chunks : List(U8), U64 -> List(List(U8))
chunks = |bytes, i| {
	sizes = [1, 2, 3, 5, 8, 13, 64]
	var $out = []
	var $at = 0
	var $k = 0
	while $at < bytes.len() {
		size = match sizes.get((i + $k) % 7) {
			Ok(s) => s
			Err(_) => 1
		}
		$out = $out.append(bytes.sublist({ start: $at, len: size }))
		$at = $at + size
		$k = $k + 1
	}
	$out
}

streamed : List(U8), U64 -> Try(List(Value), Value.ParseError)
streamed = |bytes, i| {
	var $reader = Streaming.reader(Streaming.defaults)
	var $values = []
	for chunk in chunks(bytes, i) {
		(next, completed) = Streaming.push($reader, chunk)?
		$reader = next
		$values = $values.concat(completed)
	}
	Ok($values.concat(Streaming.finish($reader)?))
}

## 7 → "00007"
pad : U64 -> Str
pad = |i| {
	s = i.to_str()
	"${Str.repeat("0", 5 - s.count_utf8_bytes())}${s}"
}
