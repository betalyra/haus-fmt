package haus

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// jsonCase is one case of the JSON suite (test-suite/README.md, "JSON
// suite"): its tag and fields.
type jsonCase struct {
	tag    string
	fields Record
}

func (c jsonCase) str(t *testing.T, key string) string {
	t.Helper()
	v, ok := c.fields.Get(key)
	if !ok {
		t.Fatalf("case without %s", key)
	}
	return string(v.(String))
}

func (c jsonCase) value(t *testing.T, keys ...string) Value {
	t.Helper()
	for _, k := range keys {
		if v, ok := c.fields.Get(k); ok {
			return v
		}
	}
	t.Fatalf("case without %v", keys)
	return nil
}

func readJSONCases(t *testing.T, name string) []jsonCase {
	t.Helper()
	values, err := ParseAll(readSuite(t, "json", name))
	if err != nil {
		t.Fatal(err)
	}
	cases := make([]jsonCase, len(values))
	for i, v := range values {
		x := v.(Variant)
		cases[i] = jsonCase{x.Tag, x.Args[0].(Record)}
	}
	return cases
}

// sameJSON compares two JSON texts as data: member order and whitespace
// don't matter, numbers compare by their text.
func sameJSON(t *testing.T, got []byte, want string) bool {
	t.Helper()
	decode := func(b []byte) any {
		d := json.NewDecoder(bytes.NewReader(b))
		d.UseNumber()
		var x any
		if err := d.Decode(&x); err != nil {
			t.Fatalf("not JSON: %s: %v", b, err)
		}
		return x
	}
	return reflect.DeepEqual(decode(got), decode([]byte(want)))
}

func errorCode(err error) ErrorCode {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ""
}

// checkErr compares an Err case with the error: its code, and its path
// (the place in the JSON, spec §16.3 "Places") when the case gives one.
func (c jsonCase) checkErr(t *testing.T, text string, err error) {
	t.Helper()
	if code := c.str(t, "code"); errorCode(err) != ErrorCode(code) {
		t.Errorf("%s: got %v, want %s", text, err, code)
		return
	}
	if want, ok := c.fields.Get("path"); ok {
		if e := new(Error); !errors.As(err, &e) || e.Path != string(want.(String)) {
			t.Errorf("%s: got %v, want the place %q", text, err, want.(String))
		}
	}
}

func TestJSONImportSuite(t *testing.T) {
	n := 0
	for _, c := range readJSONCases(t, "import.cases.haus") {
		text := c.str(t, "json")
		got, err := ImportJSON([]byte(text))
		switch c.tag {
		case "Read":
			want := c.value(t, "output")
			if err != nil {
				t.Errorf("%s: %v", text, err)
			} else if !Equals(got, want) {
				t.Errorf("%s: got %s, want %s", text, mustCanonical(t, got), mustCanonical(t, want))
			}
		case "Err":
			c.checkErr(t, text, err)
		default:
			t.Fatalf("unknown case %s", c.tag)
		}
		n++
	}
	t.Logf("%d import cases", n)
}

func TestSelfDescribingSuite(t *testing.T) {
	n := 0
	for _, c := range readJSONCases(t, "self-describing.cases.haus") {
		text := c.str(t, "json")
		got, err := FromHausJSON([]byte(text))
		switch c.tag {
		case "Ok":
			input := c.value(t, "input")
			if err != nil {
				t.Errorf("read %s: %v", text, err)
			} else if !Equals(got, input) {
				t.Errorf("read %s: got %s", text, mustCanonical(t, got))
			}
			written, err := ToHausJSON(input)
			if err != nil {
				t.Errorf("write %s: %v", mustCanonical(t, input), err)
			} else if !sameJSON(t, written, text) {
				t.Errorf("write %s: got %s, want %s", mustCanonical(t, input), written, text)
			}
		case "Err":
			c.checkErr(t, text, err)
		default:
			t.Fatalf("unknown case %s", c.tag)
		}
		n++
	}
	t.Logf("%d self-describing cases", n)
}

// TestValidSuiteJSONLines reads every valid/NAME.jsonl as self-describing
// JSON Lines, and writes each file's values as it.
func TestValidSuiteJSONLines(t *testing.T) {
	n := 0
	for _, name := range suiteFiles(t, "valid", ".haus") {
		values, err := ParseAll(readSuite(t, "valid", name+".haus"))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		text := readSuite(t, "valid", name+".jsonl")
		got, err := FromHausJSONLines(text)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if len(got) != len(values) {
			t.Errorf("%s: %d values, want %d", name, len(got), len(values))
			continue
		}
		lines := strings.SplitAfter(string(text), "\n")
		for i := range values {
			if !Equals(got[i], values[i]) {
				t.Errorf("%s: value %d differs", name, i)
			}
			written, err := ToHausJSON(values[i])
			if err != nil {
				t.Errorf("%s: write value %d: %v", name, i, err)
			} else if !sameJSON(t, written, lines[i]) {
				t.Errorf("%s: value %d written as %s", name, i, written)
			}
			n++
		}
		all, err := ToHausJSONLines(values)
		if err != nil {
			t.Fatal(err)
		}
		again, err := FromHausJSONLines(all)
		if err != nil || len(again) != len(values) {
			t.Errorf("%s: JSON Lines round trip: %v", name, err)
		}
	}
	t.Logf("%d values of valid/*.jsonl", n)
}
