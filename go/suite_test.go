package haus

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// suite is the shared conformance suite (test-suite/README.md).
const suite = "../test-suite"

// suiteFiles returns the names (without extension) of the files dir/*.ext.
func suiteFiles(t *testing.T, dir, ext string) []string {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(suite, dir, "*"+ext))
	if err != nil || len(paths) == 0 {
		t.Fatalf("no %s files in %s: %v", ext, dir, err)
	}
	names := make([]string, len(paths))
	for i, p := range paths {
		names[i] = strings.TrimSuffix(filepath.Base(p), ext)
	}
	return names
}

func readSuite(t *testing.T, path ...string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(append([]string{suite}, path...)...))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// fromSuiteJSON reads one value of self-describing JSON as the suite writes
// it (test-suite/README.md, "Expected output encoding").
func fromSuiteJSON(t *testing.T, j any) Value {
	t.Helper()
	switch j := j.(type) {
	case string:
		return String(j)
	case []any:
		a := make(Array, len(j))
		for i, e := range j {
			a[i] = fromSuiteJSON(t, e)
		}
		return a
	case map[string]any:
		switch {
		case j["_rec"] != nil:
			var fields []Field
			for k, v := range j["_rec"].(map[string]any) {
				fields = append(fields, Field{Key: k, Value: fromSuiteJSON(t, v)})
			}
			r, err := NewRecord(fields...)
			if err != nil {
				t.Fatal(err)
			}
			return r
		case j["_num"] != nil:
			return Number{lit: j["_num"].(string)}
		case j["_bytes"] != nil:
			b, err := hex.DecodeString(j["_bytes"].(string))
			if err != nil {
				t.Fatal(err)
			}
			return Bytes(b)
		case j["_tag"] != nil:
			v := Variant{Tag: j["_tag"].(string)}
			if args, ok := j["_args"].([]any); ok {
				for _, a := range args {
					v.Args = append(v.Args, fromSuiteJSON(t, a))
				}
			}
			return v
		}
	}
	t.Fatalf("not suite JSON: %v", j)
	return nil
}

func TestValidSuite(t *testing.T) {
	for _, name := range suiteFiles(t, "valid", ".haus") {
		t.Run(name, func(t *testing.T) {
			values, err := ParseAll(readSuite(t, "valid", name+".haus"))
			if err != nil {
				t.Fatalf("parse: %v", err)
			}
			var want []Value
			for line := range strings.Lines(string(readSuite(t, "valid", name+".jsonl"))) {
				var env map[string]any
				if err := json.Unmarshal([]byte(line), &env); err != nil {
					t.Fatal(err)
				}
				want = append(want, fromSuiteJSON(t, env["_value"]))
			}
			if len(values) != len(want) {
				t.Fatalf("got %d values, want %d", len(values), len(want))
			}
			for i := range values {
				if !Equals(values[i], want[i]) {
					t.Errorf("value %d: got %s, want %s", i, mustCanonical(t, values[i]), mustCanonical(t, want[i]))
				}
			}
			var canon strings.Builder
			for _, v := range values {
				canon.WriteString(mustCanonical(t, v))
				canon.WriteByte('\n')
			}
			if got, want := canon.String(), string(readSuite(t, "valid", name+".canonical")); got != want {
				t.Errorf("canonical:\n got %q\nwant %q", got, want)
			}
			h, err := HashAll(values)
			if err != nil {
				t.Fatal(err)
			}
			if want := strings.TrimSpace(string(readSuite(t, "valid", name+".hash"))); h != want {
				t.Errorf("hash: got %s, want %s", h, want)
			}
		})
	}
}

func mustCanonical(t *testing.T, v Value) string {
	t.Helper()
	s, err := Canonical(v)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestInvalidSuite(t *testing.T) {
	for _, name := range suiteFiles(t, "invalid", ".haus") {
		t.Run(name, func(t *testing.T) {
			want := ErrorCode(strings.TrimSpace(string(readSuite(t, "invalid", name+".error"))))
			_, err := ParseAll(readSuite(t, "invalid", name+".haus"))
			var e *Error
			if !errors.As(err, &e) {
				t.Fatalf("want error %s, got %v", want, err)
			}
			if e.Code != want {
				t.Fatalf("want %s, got %v", want, err)
			}
			if e.Line < 1 || e.Column < 1 {
				t.Errorf("no position: %v", err)
			}
		})
	}
}

// formatCase is an input of the format suite and the directory of its
// expected outputs.
type formatCase struct {
	name, input, expected string
}

func formatCases(t *testing.T) []formatCase {
	var cases []formatCase
	for _, dir := range []string{"cases", "examples"} {
		for _, name := range suiteFiles(t, filepath.Join("format", dir), ".haus") {
			cases = append(cases, formatCase{dir + "/" + name,
				filepath.Join("format", dir, name+".haus"), filepath.Join("format", dir, name)})
		}
	}
	for _, name := range suiteFiles(t, "valid", ".haus") {
		cases = append(cases, formatCase{"valid/" + name,
			filepath.Join("valid", name+".haus"), filepath.Join("format", "valid", name)})
	}
	return cases
}

func formatOptions(t *testing.T, c formatCase) FormatOptions {
	var o FormatOptions
	b, err := os.ReadFile(filepath.Join(suite, c.expected+".options"))
	if err != nil {
		return o
	}
	v, err := Parse(b)
	if err != nil {
		t.Fatal(err)
	}
	r := v.(Record)
	for k, v := range r.All() {
		n, _ := v.(Number).BigInt()
		switch k {
		case "indent":
			o.Indent = int(n.Int64())
		case "width":
			o.Width = int(n.Int64())
		default:
			t.Fatalf("unknown option %s", k)
		}
	}
	return o
}

func run(t *testing.T, src []byte, o FormatOptions, l Layout) []byte {
	t.Helper()
	o.Layout = l
	out, err := Format(src, o)
	if err != nil {
		t.Fatalf("format %s: %v", l, err)
	}
	return out
}

func sameValues(t *testing.T, what string, a, b []byte) {
	t.Helper()
	va, err := ParseAll(a)
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
	vb, err := ParseAll(b)
	if err != nil {
		t.Fatal(err)
	}
	ha, _ := HashAll(va)
	hb, _ := HashAll(vb)
	if ha != hb {
		t.Errorf("%s: different values", what)
	}
}

var trailingBlanks = regexp.MustCompile(`(?m)[ \t]+$`)

func TestFormatSuite(t *testing.T) {
	cases := formatCases(t)
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			input := readSuite(t, c.input)
			o := formatOptions(t, c)
			outs := map[Layout][]byte{}
			for _, l := range []Layout{Pretty, Compact, Minimised} {
				want := readSuite(t, c.expected+"."+l.String())
				got := run(t, input, o, l)
				outs[l] = got
				if !bytes.Equal(got, want) {
					t.Errorf("%s:\n--- got\n%s\n--- want\n%s", l, got, want)
					continue
				}
				if again := run(t, got, o, l); !bytes.Equal(again, got) {
					t.Errorf("%s is not idempotent:\n%s", l, again)
				}
				sameValues(t, l.String(), got, input)
			}
			back := run(t, outs[Minimised], o, Pretty)
			if want := run(t, outs[Compact], o, Pretty); !bytes.Equal(back, want) {
				t.Errorf("minimised and compact, formatted as pretty, differ:\n%s\n%s", back, want)
			}
			if want := withoutComments(t, input, o); !bytes.Equal(withoutBlankLines(back), withoutBlankLines(want)) {
				t.Errorf("minimised, formatted as pretty, is not the pretty file without comments:\n%s\n%s", back, want)
			}
			sameValues(t, "pretty with trailing blanks trimmed", trailingBlanks.ReplaceAll(outs[Pretty], nil), input)
		})
	}
}

// withoutComments formats src as pretty with its comments removed.
func withoutComments(t *testing.T, src []byte, o FormatOptions) []byte {
	p := newParser(string(src), DefaultLimits(), true)
	_, f, err := p.file()
	if err != nil {
		t.Fatal(err)
	}
	var strip func(it *item)
	strip = func(it *item) {
		it.leading, it.trailing = nil, nil
		it.val.dangling = nil
		for _, c := range it.val.items {
			strip(c)
		}
	}
	for _, it := range f.items {
		strip(it)
	}
	f.dangling = nil
	return printFile(f, o)
}

func withoutBlankLines(b []byte) []byte {
	var out []byte
	for line := range bytes.Lines(b) {
		if len(bytes.TrimRight(line, "\n")) > 0 {
			out = append(out, line...)
		}
	}
	return out
}

func TestSuiteCodesInCatalogue(t *testing.T) {
	for _, dir := range []string{"invalid", "schema/invalid"} {
		paths, _ := filepath.Glob(filepath.Join(suite, dir, "*.error"))
		for _, p := range paths {
			b, _ := os.ReadFile(p)
			code := ErrorCode(strings.TrimSpace(string(b)))
			if _, ok := code.Info(); !ok {
				t.Errorf("%s: %s is not in the catalogue", p, code)
			}
		}
	}
	_ = fmt.Sprint
}
