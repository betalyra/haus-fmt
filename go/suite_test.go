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
			v := Variant{Tag: MustTag(j["_tag"].(string))}
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

// inLayout is the default options in layout l.
func inLayout(l Layout) FormatOptions {
	o := DefaultFormatOptions()
	o.Layout = l
	return o
}

// withLimits is o with the limits lim.
func withLimits(o FormatOptions, lim Limits) FormatOptions {
	o.Limits = lim
	return o
}

// formatOptions reads the case's options file: the options it names, the
// defaults for the others.
func formatOptions(t *testing.T, c formatCase) FormatOptions {
	o := DefaultFormatOptions()
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

// DefaultFormatOptions is what the zero FormatOptions used to mean (indent
// 2, width 80, the default limits): over the whole format suite, every case
// without an options file comes out as its expected files, written with
// those defaults, byte for byte.
func TestDefaultFormatOptions(t *testing.T) {
	if got, want := DefaultFormatOptions(), (FormatOptions{Layout: Pretty, Indent: 2, Width: 80}); got != want {
		t.Fatalf("DefaultFormatOptions() = %+v, want %+v", got, want)
	}
	for _, c := range formatCases(t) {
		if _, err := os.Stat(filepath.Join(suite, c.expected+".options")); err == nil {
			continue
		}
		input := readSuite(t, c.input)
		for _, l := range []Layout{Pretty, Compact, Minimised} {
			if got, want := run(t, input, DefaultFormatOptions(), l), readSuite(t, c.expected+"."+l.String()); !bytes.Equal(got, want) {
				t.Errorf("%s %s:\n--- got\n%s\n--- want\n%s", c.name, l, got, want)
			}
		}
	}
}

// Indent and width are taken literally, 0 included (spec §11): the zero
// options are not the defaults.
func TestFormatZeroOptions(t *testing.T) {
	cases := []struct {
		name string
		opts FormatOptions
	}{
		{"indent-zero", FormatOptions{Indent: 0, Width: 80}},
		{"width-zero", FormatOptions{Indent: 2, Width: 0}},
	}
	for _, c := range cases {
		input := readSuite(t, "format", "cases", c.name+".haus")
		values, err := ParseAll(input)
		if err != nil {
			t.Fatal(err)
		}
		for _, l := range []Layout{Pretty, Compact, Minimised} {
			want := readSuite(t, "format", "cases", c.name+"."+l.String())
			if got := run(t, input, c.opts, l); !bytes.Equal(got, want) {
				t.Errorf("%s %s:\n--- got\n%s\n--- want\n%s", c.name, l, got, want)
			}
			// The values written alone: what the formatter writes of the
			// minimised text, which has no comments nor blank lines.
			o := c.opts
			o.Layout = l
			got, err := FormatValues(values, o)
			if err != nil {
				t.Fatal(err)
			}
			if want := run(t, run(t, input, c.opts, Minimised), c.opts, l); !bytes.Equal(got, want) {
				t.Errorf("%s FormatValues %s:\n--- got\n%s\n--- want\n%s", c.name, l, got, want)
			}
		}
		if bytes.Equal(run(t, input, c.opts, Pretty), run(t, input, DefaultFormatOptions(), Pretty)) {
			t.Errorf("%s: written as with the default options", c.name)
		}
	}
	// The zero value: no indentation, and nothing fits on one line.
	got, err := Format([]byte(`{ a: [P(1, 2)] }`), FormatOptions{})
	if want := "{\na: [\nP(\n1,\n2,\n),\n],\n}\n"; err != nil || string(got) != want {
		t.Errorf("zero options: %q, %v; want %q", got, err, want)
	}
}

// A negative indent or width is a mistake in the calling program: a plain
// error wrapping ErrInvalidOptions, without a code, returned before the text
// or the values are looked at.
func TestFormatNegativeOptions(t *testing.T) {
	bad := []FormatOptions{{Indent: -1, Width: 80}, {Indent: 2, Width: -1}, {Indent: -4, Width: -80}}
	cyclic := Array{nil}
	cyclic[0] = cyclic
	for _, o := range bad {
		for _, l := range []Layout{Pretty, Compact, Minimised} {
			o.Layout = l
			check := func(what string, err error) {
				t.Helper()
				var e *Error
				if !errors.Is(err, ErrInvalidOptions) || errors.As(err, &e) {
					t.Errorf("%s %+v: %v, want ErrInvalidOptions without a code", what, o, err)
				}
			}
			_, err := Format([]byte("{ a: 1 }"), o)
			check("Format", err)
			_, err = Format([]byte("{ a: "), o)
			check("Format of a syntax error", err)
			_, err = FormatValue(NumberFromInt(1), o)
			check("FormatValue", err)
			_, err = FormatValue(cyclic, o)
			check("FormatValue of a cyclic value", err)
			_, err = FormatValues([]Value{String("a"), String("b")}, o)
			check("FormatValues", err)
			check("Check", o.Check())
		}
	}
	if err := (FormatOptions{}).Check(); err != nil {
		t.Errorf("zero options: %v", err)
	}
}

// TestFormatOptionsSuite runs format/options.cases.haus: the pretty
// layout's indent and width, given or left unset (spec §11). FormatOptions
// holds them as ints: an unset one is the default (DefaultFormatOptions), a
// negative one is passed as it is and must be refused with ErrInvalidOptions.
func TestFormatOptionsSuite(t *testing.T) {
	vs, err := ParseAll(readSuite(t, "format", "options.cases.haus"))
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%d cases", len(vs))
	if len(vs) == 0 {
		t.Fatal("no cases")
	}
	for _, v := range vs {
		r, _ := v.(Record)
		input, _ := r.Get("input")
		result, _ := r.Get("result")
		src, okInput := input.(String)
		res, okResult := result.(Variant)
		if !okInput || !okResult {
			t.Fatalf("not a case: %v", v)
		}
		o := DefaultFormatOptions()
		for k, field := range map[string]*int{"indent": &o.Indent, "width": &o.Width} {
			if n, ok := r.Get(k); ok {
				i, ok := n.(Number).BigInt()
				if !ok || !i.IsInt64() {
					t.Fatalf("not an option: %v", n)
				}
				*field = int(i.Int64())
			}
		}
		name := mustCanonical(t, v)
		got, err := Format([]byte(src), o)
		switch res.Tag.String() {
		case "Ok":
			want := res.Args[0].(String)
			if err != nil {
				t.Errorf("%s: %v", name, err)
			} else if string(got) != string(want) {
				t.Errorf("%s:\n--- got\n%s\n--- want\n%s", name, got, want)
			}
		case "Rejected":
			if !errors.Is(err, ErrInvalidOptions) {
				t.Errorf("%s: not rejected with ErrInvalidOptions: %v, formatted as\n%s", name, err, got)
			}
		default:
			t.Fatalf("not a result: %v", result)
		}
	}
}

// The format option cases held back from the suite while the bindings
// disagreed: options taken literally, negative ones refused.
func TestFormatOptionsHeldCases(t *testing.T) {
	ok := []struct {
		input         string
		indent, width int
		want          string
	}{
		{"{ a: { b: [1] } }", 0, 80, "{\na: {\nb: [\n1,\n],\n},\n}\n"},
		{"Point(1, 2)", 2, 0, "Point(\n  1,\n  2,\n)\n"},
		{"Point(1, 2)", 0, 0, "Point(\n1,\n2,\n)\n"},
		{"{ a: Point(1, 2) }", 2, 0, "{\n  a: Point(\n    1,\n    2,\n  ),\n}\n"},
	}
	for _, c := range ok {
		got, err := Format([]byte(c.input), FormatOptions{Indent: c.indent, Width: c.width})
		if err != nil || string(got) != c.want {
			t.Errorf("%q indent %d width %d: %q, %v; want %q", c.input, c.indent, c.width, got, err, c.want)
		}
	}
	for _, o := range []FormatOptions{{Indent: 2, Width: -1}, {Indent: -1, Width: 80}, {Indent: -2, Width: 40}} {
		if _, err := Format([]byte("{ a: Point(1, 2) }"), o); !errors.Is(err, ErrInvalidOptions) {
			t.Errorf("%+v: %v, want ErrInvalidOptions", o, err)
		}
	}
}

// Text quoted in a message is escaped first and then cut to 40 characters
// as shown, never inside an escape (spec §9).
func TestQuoteForMessage(t *testing.T) {
	cases := []struct{ in, want string }{
		{"abc", `"abc"`},
		{strings.Repeat("a", 40), `"` + strings.Repeat("a", 40) + `"`},
		{strings.Repeat("a", 41), `"` + strings.Repeat("a", 39) + `…"`},
		// 10 escapes of 6 characters: 60 as shown, cut to 6 whole ones.
		{strings.Repeat("\x1b", 10), `"` + strings.Repeat(`\u{1B}`, 6) + `…"`},
		{strings.Repeat("a", 36) + "\u202e", `"` + strings.Repeat("a", 36) + `…"`},
		{strings.Repeat("a", 32) + "\u202e", `"` + strings.Repeat("a", 32) + `\u{202E}"`},
		{"a\xffb", `"a\u{FFFD}b"`},
	}
	for _, c := range cases {
		if got := quoteForMessage(c.in); got != c.want {
			t.Errorf("%q: got %s, want %s", c.in, got, c.want)
		}
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
