package schema_test

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// sameError reports whether two errors are the same: both nil, or two
// *haus.Error with the same fields.
func sameError(a, b error) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	var x, y *haus.Error
	if !errors.As(a, &x) || !errors.As(b, &y) {
		return a.Error() == b.Error()
	}
	return *x == *y
}

// onePassLimits are the limits the one-pass paths are compared with: the
// defaults, and small ones that the values of the suite and of the fuzzer
// reach (a float's spelling longer than its literal, nesting).
var onePassLimits = []haus.Limits{{}, {MaxNumberLength: 6}, {MaxDepth: 3}, {MaxDepth: 1, MaxStringLength: 3}}

// checkFormat: Type.Format writes what Type.Encode followed by
// haus.FormatValue writes, or fails with the same error, in every layout.
func checkFormat(t *testing.T, label string, ty schema.Type, v haus.Value) {
	t.Helper()
	for _, lim := range onePassLimits {
		for _, layout := range []haus.Layout{haus.Minimised, haus.Compact, haus.Pretty} {
			opts := haus.FormatOptions{Layout: layout, Limits: lim}
			var want []byte
			enc, werr := ty.EncodeWith(v, schema.DecodeOptions{Limits: lim})
			if werr == nil {
				want, werr = haus.FormatValue(enc, opts)
			}
			got, err := ty.Format(v, opts)
			if !bytes.Equal(got, want) || !sameError(err, werr) {
				t.Fatalf("%s: Format (%s, %+v) gives %q (%v), Encode and FormatValue %q (%v)", label, layout, lim, got, err, want, werr)
			}
		}
	}
}

// checkParse: Type.Parse reads what haus.Parse followed by Type.Decode
// reads, or fails with the same error.
func checkParse(t *testing.T, label string, ty schema.Type, src []byte) {
	t.Helper()
	for _, lim := range onePassLimits {
		opts := schema.DecodeOptions{Limits: lim}
		var want haus.Value
		v, werr := haus.ParseWith(src, lim)
		if werr == nil {
			want, werr = ty.DecodeWith(v, opts)
		}
		got, err := ty.ParseWith(src, opts)
		if !sameError(err, werr) || err == nil && !haus.Equals(got, want) {
			t.Fatalf("%s: Parse (%+v) of %q gives %v (%v), Parse and Decode %v (%v)", label, lim, src, got, err, want, werr)
		}
	}
}

// checkOnePass compares the one-pass paths with the two passes for a value
// and the texts it is written as.
func checkOnePass(t *testing.T, label string, ty schema.Type, v haus.Value) {
	t.Helper()
	checkFormat(t, label, ty, v)
	for _, layout := range []haus.Layout{haus.Minimised, haus.Pretty} {
		if text, err := haus.FormatValue(v, haus.FormatOptions{Layout: layout}); err == nil {
			checkParse(t, label, ty, text)
		}
	}
	if out, err := ty.Decode(v); err == nil {
		checkFormat(t, label+" (decoded)", ty, out)
	}
}

// typesOf returns the types of a schema that can describe a whole value.
func typesOf(s *schema.Schema) []schema.Type {
	var out []schema.Type
	for _, d := range s.Definitions() {
		if ty, err := s.Type(d.Name); err == nil {
			out = append(out, ty)
		}
	}
	return out
}

// TestOnePassSuite: every input of test-suite/schema, with every type of its
// schema file, is written by Type.Format and read by Type.Parse as in two
// passes, errors included.
func TestOnePassSuite(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(suite, "*.schema.haus"))
	count := 0
	for _, file := range files {
		name := strings.TrimSuffix(filepath.Base(file), ".schema.haus")
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		s, err := schema.Parse(src, schema.Options{})
		if err != nil {
			t.Fatal(err)
		}
		types := typesOf(s)
		for _, c := range readCases(t, filepath.Join(suite, name+".cases.haus")) {
			for _, ty := range types {
				checkOnePass(t, name+": "+c.name+" as "+ty.Name(), ty, c.input)
				count++
			}
		}
	}
	if count == 0 {
		t.Fatal("no cases")
	}
	t.Logf("one pass: %d values and types", count)
}

// FuzzOnePass: for any text and any type of the suite's schemas, Type.Parse
// gives what haus.Parse and Type.Decode give, and Type.Format of each value
// of the text what Type.Encode and haus.FormatValue give, errors included.
func FuzzOnePass(f *testing.F) {
	var types []schema.Type
	seedSchemas(f, func(src string) {
		if s, err := schema.Parse([]byte(src), schema.Options{}); err == nil {
			types = append(types, typesOf(s)...)
		}
	})
	files, _ := filepath.Glob(filepath.Join(suite, "*.cases.haus"))
	for _, file := range files {
		b, _ := os.ReadFile(file)
		values, _ := haus.ParseAll(b)
		for _, v := range values {
			r := v.(haus.Variant).Args[0].(haus.Record)
			if in, ok := r.Get("input"); ok {
				if text, err := haus.FormatValue(in, haus.FormatOptions{Layout: haus.Minimised}); err == nil {
					f.Add(text)
				}
			}
		}
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		values, perr := haus.ParseAll(data)
		for _, ty := range types {
			checkParse(t, ty.Name(), ty, data)
			if perr != nil {
				continue
			}
			for _, v := range values {
				checkFormat(t, ty.Name(), ty, v)
			}
		}
	})
}
