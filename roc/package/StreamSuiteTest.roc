## The stream suite, test-suite/stream/limits.cases.haus (test-suite/README.md,
## "Stream suite"; spec §6, §7): every case read whole, one character at a time,
## and split in two at every character, with its value limit and strict mode,
## gives the case's values (compared as `Value.to_test_json` writes them) or
## error code. A case with `whole` parses whole (`Value.parse_all`, default
## limits) to those values. document.cases.haus: single documents
## (`Value.parse`). The typed streams (typed.cases.haus) need generated
## decoders, so they run in schema-test (roc/scripts/gen_schema_conformance.py).
import Encode
import Streaming
import Value
import "../../test-suite/stream/limits.cases.haus" as stream_suite : List(U8)
import "../../test-suite/stream/document.cases.haus" as document_suite : List(U8)

StreamSuiteTest := [].{}

expect {
	cases = Value.parse_bytes(stream_suite) ?? []
	cases.len() == 24 and cases.all(|c| stream_case(c).is_ok())
}

## A case of the stream suite: Ok, or the ways of reading it that went wrong.
stream_case : Value -> Try({}, List(Str))
stream_case = |c| {
	field = |key| match c {
		Rec(fields) => fields.find_first(|(k, _)| k == key).map_ok(|(_, v)| v)
		_ => Err(NotFound)
	}
	case = (field("text"), field("maxValueLength"), field("result"))
	(text, max, want) = match case {
		(Ok(Text(t)), Ok(Num(n)), Ok(Tag("Ok", [Arr(values)]))) => (t, n, Ok(values.map(Value.to_test_json)))
		(Ok(Text(t)), Ok(Num(n)), Ok(Tag("Err", [Text(code)]))) => (t, n, Err(code))
		_ => return Err(["not a case: ${Value.to_test_json(c)}"])
	}
	options = {
		..Streaming.defaults,
		max_value_length: U64.from_str(max) ?? 0,
		require_terminator: match field("strict") {
			Ok(Tag("True", [])) => True
			_ => False
		},
	}
	read = |chunks| {
		var $state = Streaming.reader(options)
		var $out = []
		for chunk in chunks {
			match Streaming.push($state, chunk) {
				Ok((next, values)) => {
					$state = next
					$out = $out.concat(values)
				}
				Err(e) => return Err(e.code)
			}
		}
		match Streaming.finish($state) {
			Ok(last) => Ok($out.concat(last).map(Value.to_test_json))
			Err(e) => Err(e.code)
		}
	}
	bytes = text.to_utf8()
	# Where each character starts.
	var $starts = []
	var $i = 0
	while $i < bytes.len() {
		if (bytes.get($i) ?? 0) < 0x80 or (bytes.get($i) ?? 0) >= 0xC0 {
			$starts = $starts.append($i)
		}
		$i = $i + 1
	}
	starts = $starts
	by_char = starts.map(|i| bytes.sublist({ start: i, len: (starts.find_first(|j| j > i) ?? bytes.len()) - i }))
	splits = [("whole", [bytes]), ("by character", by_char)].concat(
		starts.map(|i| ("split at byte ${i.to_str()}", [bytes.take_first(i), bytes.drop_first(i)])),
	)
	failures = splits.keep_if(|(_, chunks)| read(chunks) != want).map(|(how, _)| "${text}: ${how}")
	if (failures.is_empty()) Ok({}) else Err(failures)
}

# `whole`: parsing the whole text doesn't apply the value limit (spec §7).
expect {
	cases = Value.parse_bytes(stream_suite) ?? []
	wholes = cases.keep_if(|c| field_of(c, "whole").is_ok())
	failures = wholes.keep_if(|c| whole_case(c).is_err())
	if !failures.is_empty() {
		dbg failures.map(|c| whole_case(c))
	}
	!wholes.is_empty() and failures.is_empty()
}

# document.cases.haus: a single document (spec §6), as `Value.parse`.
expect {
	cases = Value.parse_bytes(document_suite) ?? []
	failures = cases.keep_if(|c| document_case(c).is_err())
	if !failures.is_empty() {
		dbg failures.map(|c| document_case(c))
	}
	!cases.is_empty() and failures.is_empty()
}

## A field of a case.
field_of : Value, Str -> Try(Value, [NotFound])
field_of = |c, key| match c {
	Rec(fields) => fields.find_first(|(k, _)| k == key).map_ok(|(_, v)| v)
	_ => Err(NotFound)
}

## A case with `whole: Ok([values])`: `Value.parse_all` gives these values.
whole_case : Value -> Try({}, Str)
whole_case = |c| match (field_of(c, "text"), field_of(c, "whole")) {
	(Ok(Text(text)), Ok(Tag("Ok", [Arr(want)]))) => match Value.parse_all(text) {
		Ok(got) if got.len() == want.len() and got.map2(want, |a, b| Encode.equals(a, b) == Ok(True)).all(|same| same) => Ok({})
		Ok(got) => Err("${text}: parsed whole as [${Str.join_with(got.map(Value.to_test_json), ",")}], expected [${Str.join_with(want.map(Value.to_test_json), ",")}]")
		Err(e) => Err("${text}: failed whole with ${e.code}")
	}
	_ => Err("not a case: ${Value.to_test_json(c)}")
}

## A case of document.cases.haus: `Value.parse` gives `Ok(value)`, compared
## as values (spec §2), or fails with `Err("code")`.
document_case : Value -> Try({}, Str)
document_case = |c| match (field_of(c, "text"), field_of(c, "result")) {
	(Ok(Text(text)), Ok(Tag("Ok", [want]))) => match Value.parse(text) {
		Ok(got) if Encode.equals(got, want) == Ok(True) => Ok({})
		Ok(got) => Err("${text}: parsed as ${Value.to_test_json(got)}, expected ${Value.to_test_json(want)}")
		Err(e) => Err("${text}: failed with ${e.code}, expected ${Value.to_test_json(want)}")
	}
	(Ok(Text(text)), Ok(Tag("Err", [Text(code)]))) => match Value.parse(text) {
		Err(e) if e.code == code => Ok({})
		Err(e) => Err("${text}: failed with ${e.code}, expected ${code}")
		Ok(got) => Err("${text}: parsed as ${Value.to_test_json(got)}, expected ${code}")
	}
	_ => Err("not a case: ${Value.to_test_json(c)}")
}
