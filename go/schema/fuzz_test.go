package schema_test

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"unicode/utf8"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// seedSchemas adds the suite's schema files to a fuzz corpus.
func seedSchemas(f *testing.F, add func(string)) {
	for _, pattern := range []string{"*.schema.haus", "invalid/*.schema.haus"} {
		files, _ := filepath.Glob(filepath.Join(suite, pattern))
		for _, file := range files {
			b, err := os.ReadFile(file)
			if err != nil {
				f.Fatal(err)
			}
			add(string(b))
		}
	}
}

// checkError: an error from a schema file has a code from the catalogue and
// a place in the text.
func checkError(t *testing.T, src string, err error) {
	var e *haus.Error
	if !errors.As(err, &e) {
		t.Fatalf("not a *haus.Error: %v", err)
	}
	if _, ok := e.Code.Info(); !ok {
		t.Fatalf("a code that isn't in the catalogue: %s", e.Code)
	}
	if e.Code != haus.CodeImportUnavailable && (e.Line < 1 || e.Column < 1) {
		t.Fatalf("no place: %v", err)
	}
	if e.Line > 1+countLines(src) {
		t.Fatalf("a place past the end: %v", err)
	}
}

func countLines(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			n++
		}
	}
	return n
}

// FuzzSchemaParse: any text either is a schema, every definition of which
// decodes values without failing in other ways than with an error, or is
// rejected with a catalogue code at a place in the text.
func FuzzSchemaParse(f *testing.F) {
	seedSchemas(f, func(s string) { f.Add(s) })
	f.Add("type A = < ...B | X >\ntype B = < Y { a?: Maybe (Array A) } >")
	f.Add("@deprecated(\"x\", [1]) type A r = { ...r }")
	values := []haus.Value{}
	for _, src := range []string{"1", "\"x\"", "None", "Some(1)", "{ a: 1, b: [True] }", "X { y: 1.5 }", "Date(\"2026-11-13\")", "[[], {}]"} {
		v, _ := haus.Parse([]byte(src))
		values = append(values, v)
	}
	f.Fuzz(func(t *testing.T, src string) {
		s, err := schema.Parse([]byte(src), schema.Options{})
		if err != nil {
			checkError(t, src, err)
			return
		}
		if !utf8.ValidString(src) {
			t.Fatal("a schema that isn't UTF-8")
		}
		for _, d := range s.Definitions() {
			ty, err := s.Type(d.Name)
			if err != nil {
				continue
			}
			for _, v := range values {
				out, err := ty.Decode(v)
				if err != nil {
					continue
				}
				// Decoding what decoding gave gives it again.
				again, err := ty.Encode(out)
				if err != nil || !haus.Equals(again, out) {
					t.Fatalf("%s: %v decodes to %v, which encodes to %v (%v)", d.Name, v, out, again, err)
				}
			}
		}
	})
}

// FuzzDecode: decoding any value with a schema of the suite either fails
// with a catalogue code and a path, or gives a value that decodes to itself.
func FuzzDecode(f *testing.F) {
	var schemas []*schema.Schema
	seedSchemas(f, func(src string) {
		if s, err := schema.Parse([]byte(src), schema.Options{}); err == nil {
			schemas = append(schemas, s)
		}
	})
	files, _ := filepath.Glob(filepath.Join(suite, "*.cases.haus"))
	for _, file := range files {
		b, _ := os.ReadFile(file)
		f.Add(string(b))
	}
	path := regexp.MustCompile(`^\$(\.[a-z_][A-Za-z0-9_]*|\[[0-9]+\]|\["(?:[^"\\]|\\.)*"\])*$`)
	f.Fuzz(func(t *testing.T, data string) {
		values, err := haus.ParseAll([]byte(data))
		if err != nil {
			return
		}
		for _, s := range schemas {
			for _, d := range s.Definitions() {
				ty, err := s.Type(d.Name)
				if err != nil {
					continue
				}
				for _, v := range values {
					out, err := ty.Decode(v)
					if err != nil {
						var e *haus.Error
						if !errors.As(err, &e) || e.Path == "" || !path.MatchString(e.Path) {
							t.Fatalf("%s: an error without a path: %v", d.Name, err)
						}
						if _, ok := e.Code.Info(); !ok {
							t.Fatalf("a code that isn't in the catalogue: %s", e.Code)
						}
						continue
					}
					again, err := ty.Decode(out)
					if err != nil || !haus.Equals(again, out) {
						t.Fatalf("%s: %v decodes to %v, which decodes to %v (%v)", d.Name, v, out, again, err)
					}
				}
			}
		}
	})
}

// TestCodesAreConstants: the package sets codes only through the generated
// constants, so every code it reports is in the catalogue.
func TestCodesAreConstants(t *testing.T) {
	files, _ := filepath.Glob("*.go")
	literal := regexp.MustCompile(`Code:\s*"|haus\.ErrorCode\("`)
	for _, file := range files {
		b, _ := os.ReadFile(file)
		if filepath.Ext(file) == ".go" && !regexp.MustCompile(`_test\.go$`).MatchString(file) && literal.Match(b) {
			t.Errorf("%s sets a code from a string literal", file)
		}
	}
}
