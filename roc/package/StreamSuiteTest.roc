## The stream suite, test-suite/stream/limits.cases.haus (test-suite/README.md,
## "Stream suite"; spec §6, §7): every case read whole, one character at a time,
## and split in two at every character, with its value limit and strict mode,
## gives the case's values (compared as `Value.to_test_json` writes them) or
## error code.
import Streaming
import Value
import "../../test-suite/stream/limits.cases.haus" as stream_suite : List(U8)

StreamSuiteTest := [].{}

expect {
	cases = Value.parse_bytes(stream_suite) ?? []
	cases.len() == 19 and cases.all(|c| stream_case(c).is_ok())
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
