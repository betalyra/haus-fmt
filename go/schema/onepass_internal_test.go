package schema

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
)

// TestOnePassTaken: Type.Format writes in one pass every value of
// test-suite/schema that encodes and can be written, with the default
// limits (the comparison with two passes, errors included, is
// TestOnePassSuite), and what it writes is what two passes write.
func TestOnePassTaken(t *testing.T) {
	files, _ := filepath.Glob("../../test-suite/schema/*.schema.haus")
	written, total := 0, 0
	for _, file := range files {
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		s, err := Parse(src, Options{})
		if err != nil {
			t.Fatal(err)
		}
		cases, err := os.ReadFile(file[:len(file)-len(".schema.haus")] + ".cases.haus")
		if err != nil {
			t.Fatal(err)
		}
		values, err := haus.ParseAll(cases)
		if err != nil {
			t.Fatal(err)
		}
		for _, c := range values {
			input, _ := c.(haus.Variant).Args[0].(haus.Record).Get("input")
			for _, d := range s.Definitions() {
				ty, err := s.Type(d.Name)
				if err != nil {
					continue
				}
				for _, layout := range []haus.Layout{haus.Minimised, haus.Compact} {
					opts := haus.FormatOptions{Layout: layout}
					enc, err := ty.Encode(input)
					if err != nil {
						continue
					}
					want, err := haus.FormatValue(enc, opts)
					if err != nil {
						continue
					}
					total++
					got, ok := ty.formatOnePass(input, opts)
					if !ok {
						t.Errorf("%s as %s: not written in one pass", want, d.Name)
						continue
					}
					if !bytes.Equal(got, want) {
						t.Errorf("%s as %s: written in one pass as %s", want, d.Name, got)
					}
					written++
				}
			}
		}
	}
	if total == 0 {
		t.Fatal("no values")
	}
	t.Logf("written in one pass: %d of %d", written, total)
}
