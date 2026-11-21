package haus

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"testing/iotest"
	"unicode/utf8"
)

// addSuiteSeeds adds every .haus file of the conformance suite as a seed.
func addSuiteSeeds(f *testing.F) {
	for _, pattern := range []string{"valid/*.haus", "invalid/*.haus", "format/cases/*.haus"} {
		paths, _ := filepath.Glob(filepath.Join(suite, pattern))
		for _, p := range paths {
			if b, err := os.ReadFile(p); err == nil {
				f.Add(b)
			}
		}
	}
}

// FuzzParse: the parser never panics; what it accepts has a canonical form
// that parses back to equal values, and every layout of it parses to the
// same values and is stable when formatted again.
func FuzzParse(f *testing.F) {
	addSuiteSeeds(f)
	f.Fuzz(func(t *testing.T, src []byte) {
		values, err := ParseAll(src)
		if err != nil {
			var e *Error
			if !errors.As(err, &e) || e.Line < 1 || e.Column < 1 {
				t.Fatalf("not a positioned *Error: %v", err)
			}
			if _, ok := e.Code.Info(); !ok {
				t.Fatalf("code %q is not in the catalogue", e.Code)
			}
			return
		}
		want, err := HashAll(values)
		if err != nil {
			t.Fatal(err)
		}
		var canon bytes.Buffer
		for i, v := range values {
			if i > 0 {
				canon.WriteByte(',')
			}
			b, _ := AppendCanonical(nil, v)
			canon.Write(b)
		}
		back, err := ParseAll(canon.Bytes())
		if err != nil {
			t.Fatalf("canonical form %q doesn't parse: %v", canon.Bytes(), err)
		}
		if !Equals(Array(back), Array(values)) {
			t.Fatalf("canonical form %q parses to other values", canon.Bytes())
		}
		for _, l := range []Layout{Pretty, Compact, Minimised} {
			out, err := Format(src, inLayout(l))
			if err != nil {
				t.Fatalf("%s: %v", l, err)
			}
			vs, err := ParseAll(out)
			if err != nil {
				t.Fatalf("%s output %q doesn't parse: %v", l, out, err)
			}
			if got, _ := HashAll(vs); got != want {
				t.Fatalf("%s output %q parses to other values", l, out)
			}
			again, err := Format(out, inLayout(l))
			if err != nil || !bytes.Equal(again, out) {
				t.Fatalf("%s is not stable:\n%q\n%q", l, out, again)
			}
		}
		for _, l := range []Layout{Pretty, Compact, Minimised} {
			out, err := FormatValues(values, withLimits(inLayout(l), Limits{MaxDepth: MaxSupportedDepth}))
			if err != nil {
				t.Fatalf("%s from values: %v", l, err)
			}
			vs, err := ParseAll(out)
			if err != nil {
				t.Fatalf("%s from values %q doesn't parse: %v", l, out, err)
			}
			if got, _ := HashAll(vs); got != want {
				t.Fatalf("%s from values %q parses to other values", l, out)
			}
		}
	})
}

// FuzzStream: reading a stream, also one byte at a time, gives the values
// of parsing the whole text, or an error with the same code and position
// (but for invalid UTF-8, see below).
func FuzzStream(f *testing.F) {
	addSuiteSeeds(f)
	f.Fuzz(func(t *testing.T, src []byte) {
		want, wantErr := ParseAll(src)
		for _, oneByte := range []bool{false, true} {
			var r = bytes.NewReader(src)
			var vs []Value
			var err error
			reader := NewStreamReader(r, StreamOptions{})
			if oneByte {
				reader = NewStreamReader(iotest.OneByteReader(bytes.NewReader(src)), StreamOptions{})
			}
			for v, e := range reader.All() {
				if e != nil {
					err = e
					break
				}
				vs = append(vs, v)
			}
			if wantErr != nil {
				var a, b *Error
				if !errors.As(err, &a) || !errors.As(wantErr, &b) {
					t.Fatalf("stream: %v, whole: %v", err, wantErr)
				}
				// The whole text is checked for UTF-8 first, a stream value by
				// value: with invalid UTF-8 and another mistake, either may be
				// reported (spec §17).
				if a.Code == CodeInvalidUTF8 || b.Code == CodeInvalidUTF8 {
					continue
				}
				if a.Code != b.Code || a.Line != b.Line || a.Column != b.Column {
					t.Fatalf("stream: %v, whole: %v", a, b)
				}
				continue
			}
			if err != nil {
				t.Fatalf("stream: %v, whole: ok", err)
			}
			if !Equals(Array(vs), Array(want)) {
				t.Fatalf("stream gives other values")
			}
		}
	})
}

// FuzzFormatString: any string, written in every layout as a value, a field
// and an argument, parses back to itself, also after an editor trims the
// trailing blanks of the pretty layout, and is stable when formatted again.
func FuzzFormatString(f *testing.F) {
	for _, s := range []string{"a", " ", "a \n\t", "\"\"\"", "\\", "\r\n", "\r", "  ", "\u0001\u202e\u2028", `\u{20}`, "x\n\n", "\n"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if !utf8.ValidString(s) {
			return
		}
		rec, _ := NewRecord(Field{"note", String(s)}, Field{"list", Array{String(s), String(s + "\n")}})
		values := []Value{String(s), rec, Variant{Tag: "Note", Args: []Value{String(s), String(s)}}}
		for _, vs := range [][]Value{values, values[:1], values[1:2]} {
			for _, l := range []Layout{Pretty, Compact, Minimised} {
				out, err := FormatValues(vs, inLayout(l))
				if err != nil {
					t.Fatal(err)
				}
				back, err := ParseAll(out)
				if err != nil || !Equals(Array(back), Array(vs)) {
					t.Fatalf("%s: %q reads back as %v (%v)", l, out, back, err)
				}
				again, err := Format(out, inLayout(l))
				if err != nil || !bytes.Equal(again, out) {
					t.Fatalf("%s is not stable: %q, %q", l, out, again)
				}
				if l == Pretty {
					trimmed, err := ParseAll(trailingBlanks.ReplaceAll(out, nil))
					if err != nil || !Equals(Array(trimmed), Array(vs)) {
						t.Fatalf("trimming %q changes it", out)
					}
				}
			}
		}
	})
}
