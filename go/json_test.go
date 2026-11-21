package haus

import (
	"bytes"
	"errors"
	"math"
	"strings"
	"testing"
	"testing/iotest"
)

func TestJSONErrorsHavePositions(t *testing.T) {
	tests := []struct {
		json      string
		code      ErrorCode
		line, col int
	}{
		{"[1,\n  2,\n  x]", CodeJSONSyntax, 3, 3},
		{`{"a": 1, "a": 2}`, CodeDuplicateKey, 1, 10},
		{"\"a\tb\"", CodeControlCharacter, 1, 3},
		{`"\x"`, CodeInvalidEscape, 1, 2},
		{`"\u12g4"`, CodeInvalidUnicodeEscape, 1, 4},
		{`"abc`, CodeUnterminatedString, 1, 1},
		{"\"\xff\"", CodeInvalidUTF8, 1, 2},
		{"01", CodeJSONSyntax, 1, 2},
		{"1.", CodeJSONSyntax, 1, 3},
		{"-", CodeJSONSyntax, 1, 2},
		{"", CodeJSONSyntax, 1, 1},
		{"[1] [2]", CodeJSONSyntax, 1, 5},
		{"1e7000", CodeExponentTooLarge, 1, 1},
	}
	for _, tt := range tests {
		_, err := ImportJSON([]byte(tt.json))
		var e *Error
		if !errors.As(err, &e) || e.Code != tt.code || e.Line != tt.line || e.Column != tt.col {
			t.Errorf("%q: got %v, want %s at %d:%d", tt.json, err, tt.code, tt.line, tt.col)
		}
	}
}

func TestJSONLimitsCountTheValue(t *testing.T) {
	lim := Limits{MaxStringLength: 3, MaxDepth: 2}
	ok := []string{`"ééé"`, `"ééé"`, `{"abc": [1]}`, `[[]]`}
	for _, j := range ok {
		if _, err := ImportJSONWith([]byte(j), lim); err != nil {
			t.Errorf("import %s: %v", j, err)
		}
	}
	bad := map[string]ErrorCode{
		`"abcd"`:      CodeStringTooLong,
		`{"abcd": 1}`: CodeKeyTooLong,
		`[[[]]]`:      CodeNestingTooDeep,
		`"ééab"`:      CodeStringTooLong,
	}
	for j, code := range bad {
		if _, err := ImportJSONWith([]byte(j), lim); errorCode(err) != code {
			t.Errorf("import %s: got %v, want %s", j, err, code)
		}
	}
	// Self-describing JSON counts the haus value: bytes as two characters a
	// byte, a record payload as one level.
	sd := map[string]ErrorCode{
		`{"_haus":1,"_value":{"_bytes":"0b34"}}`:                                      "",
		`{"_haus":1,"_value":{"_bytes":"0b3456"}}`:                                    CodeStringTooLong,
		`{"_haus":1,"_value":"abc"}`:                                                  "",
		`{"_haus":1,"_value":"abcde"}`:                                                CodeStringTooLong,
		`{"_haus":1,"_value":{"_tag":"Abcde"}}`:                                       CodeTagTooLong,
		`{"_haus":1,"_value":{"_tag":"A","_args":[{"_rec":{"a":[{"_num":"1"}]}}]}}`:   "",
		`{"_haus":1,"_value":{"_tag":"A","_args":[{"_rec":{"a":[[{"_num":"1"}]]}}]}}`: CodeNestingTooDeep,
		`{"_haus":1,"_value":{"_tag":"A","_args":[[{"_num":"1"}]]}}`:                  "",
		`{"_haus":1,"_value":{"_tag":"A","_args":[[[{"_num":"1"}]]]}}`:                CodeNestingTooDeep,
	}
	for j, code := range sd {
		_, err := FromHausJSONWith([]byte(j), Limits{MaxStringLength: 4, MaxDepth: 2})
		if code == "" && err != nil || errorCode(err) != code {
			t.Errorf("read %s: got %v, want %q", j, err, code)
		}
	}
}

func TestSelfDescribingErrorPaths(t *testing.T) {
	_, err := FromHausJSON([]byte(`{"_haus":1,"_value":{"_rec":{"items":[{"_num":"1"},{"_num":"01"}]}}}`))
	var e *Error
	if !errors.As(err, &e) || e.Code != CodeHausJSONNumber || e.Path != "$._value._rec.items[1]._num" {
		t.Errorf("got %v", err)
	}
}

func TestToHausJSONEscapes(t *testing.T) {
	got, err := ToHausJSON(Array{String("a\"\\\n\x01\u007f\u0085\u2028\u202e\u2066é😀"), Bytes{0xab}, Variant{Tag: MustTag("A")}})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"_haus":1,"_value":["a\"\\\n\u0001\u007f\u0085\u2028\u202e\u2066é😀",{"_bytes":"ab"},{"_tag":"A"}]}`
	if string(got) != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
	if _, err := ToHausJSON(String("\xff")); errorCode(err) != CodeCannotEncode {
		t.Errorf("invalid UTF-8: %v", err)
	}
}

func TestJSONLines(t *testing.T) {
	text := "\uFEFF{\"_haus\":1,\"_value\":\"a\"}\r\n{\"_haus\":1,\"_value\":[]}\n{\"_haus\":1,\"_value\":{\"_tag\":\"B\"}}"
	got, err := FromHausJSONLines([]byte(text))
	if err != nil || len(got) != 3 {
		t.Fatalf("got %v, %v", got, err)
	}
	// Read in chunks of one byte, the same.
	var streamed []Value
	for v, err := range ReadHausJSONLines(iotest.OneByteReader(strings.NewReader(text)), JSONLinesOptions{}) {
		if err != nil {
			t.Fatal(err)
		}
		streamed = append(streamed, v)
	}
	if len(streamed) != 3 || !Equals(Array(streamed), Array(got)) {
		t.Errorf("streamed %v", streamed)
	}
	if v, err := FromHausJSONLines(nil); err != nil || len(v) != 0 {
		t.Errorf("empty: %v %v", v, err)
	}
	tests := []struct {
		text string
		code ErrorCode
		line int
		path string
	}{
		{"{\"_haus\":1,\"_value\":\"a\"}\n\n{\"_haus\":1,\"_value\":\"a\"}\n", CodeJSONSyntax, 2, ""},
		{"{\"_haus\":1,\"_value\":\"a\"}\n\uFEFF{\"_haus\":1,\"_value\":\"a\"}\n", CodeJSONSyntax, 2, ""},
		{"{\"_haus\":1,\"_value\":\"a\"}\n{\"_haus\":1,\"_value\":[1]}\n", CodeHausJSONForm, 0, "$[1]._value[0]"},
		{"{\"_haus\":1,\"_value\":\"a\"}\n[1,\n", CodeJSONSyntax, 2, ""},
	}
	for _, tt := range tests {
		_, err := FromHausJSONLines([]byte(tt.text))
		var e *Error
		if !errors.As(err, &e) || e.Code != tt.code || e.Line != tt.line || e.Path != tt.path {
			t.Errorf("%q: got %v (line %d, path %q)", tt.text, err, e.Line, e.Path)
		}
	}
	// JSON Lines has no value limit (spec §7): a line longer than
	// MaxValueLength is read, and the value's own limits apply.
	lim := JSONLinesOptions{Limits: Limits{MaxValueLength: 30}}
	long := "{\"_haus\":1,\"_value\":\"abcdefghijklmnop\"}\n"
	for v, err := range ReadHausJSONLines(strings.NewReader(long), lim) {
		if err != nil || v != String("abcdefghijklmnop") {
			t.Errorf("long line: %v %v", v, err)
		}
	}
	for _, text := range []string{"1\n\n2\n", "1\n\uFEFF2\n", "1\r\n\r\n"} {
		_, err := ImportJSONLines([]byte(text))
		var e *Error
		if !errors.As(err, &e) || e.Code != CodeJSONSyntax || e.Line != 2 {
			t.Errorf("import %q: got %v", text, err)
		}
	}
	values, err := ImportJSONLines([]byte("1\n{\"a\":null}\n"))
	if err != nil || len(values) != 2 {
		t.Errorf("import lines: %v %v", values, err)
	}
	out, err := ToHausJSONLines([]Value{String("a"), Number{lit: "1"}})
	if err != nil || !bytes.Equal(out, []byte("{\"_haus\":1,\"_value\":\"a\"}\n{\"_haus\":1,\"_value\":{\"_num\":\"1\"}}\n")) {
		t.Errorf("write lines: %s %v", out, err)
	}
}

func TestFloatSpelling(t *testing.T) {
	tests := map[float64]string{0.1: "0.1", 1e21: "1e21", 1.5e-7: "1.5e-7", 100: "100", 123456.75: "123456.75", 0.000001: "0.000001"}
	for f, want := range tests {
		if got := FormatFloat(f, 64); got != want {
			t.Errorf("%v: got %s, want %s", f, got, want)
		}
	}
	if got := Float32Value(2097152.25); got.(Number).String() != "2097152.2" {
		t.Errorf("float32: %v", got)
	}
	if got := FloatValue(math.Copysign(0, -1)); got.(Number).String() != "-0" {
		t.Errorf("zero: %v", got)
	}
	if f, ok := (Number{lit: "1e400"}).Float64(); ok {
		t.Errorf("1e400: %v", f)
	}
}
