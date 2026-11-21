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

const suite = "../../test-suite/schema"

func canonical(t *testing.T, v haus.Value) string {
	t.Helper()
	s, err := haus.Canonical(v)
	if err != nil {
		t.Fatalf("canonical: %v", err)
	}
	return s
}

func get(r haus.Record, key string) haus.Value {
	v, _ := r.Get(key)
	return v
}

func str(v haus.Value) string {
	s, _ := v.(haus.String)
	return string(s)
}

// schemaCase is one case of a .cases.haus file.
type schemaCase struct {
	ok         bool
	typ        string
	input      haus.Value
	output     haus.Value
	code, path string
	name       string
}

func readCases(t *testing.T, path string) []schemaCase {
	t.Helper()
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	values, err := haus.ParseAll(src)
	if err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	var cases []schemaCase
	for _, v := range values {
		x, ok := v.(haus.Variant)
		if !ok || x.Tag.String() != "Ok" && x.Tag.String() != "Err" || len(x.Args) != 1 {
			t.Fatalf("%s: not a case: %v", path, v)
		}
		r := x.Args[0].(haus.Record)
		c := schemaCase{ok: x.Tag.String() == "Ok", typ: str(get(r, "type")), input: get(r, "input"),
			code: str(get(r, "code")), path: str(get(r, "path"))}
		c.output = get(r, "output")
		if c.output == nil {
			c.output = c.input
		}
		c.name = x.Tag.String() + " " + c.typ + " " + canonical(t, c.input)
		cases = append(cases, c)
	}
	return cases
}

func codeAndPath(err error) (code haus.ErrorCode, path string) {
	var e *haus.Error
	if errors.As(err, &e) {
		return e.Code, e.Path
	}
	return "", ""
}

// TestSchemaSuite runs test-suite/schema: every case on each schema file as
// written and without its attributes, which must not change any result.
func TestSchemaSuite(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(suite, "*.schema.haus"))
	if len(files) == 0 {
		t.Fatal("no schema files")
	}
	count := 0
	for _, file := range files {
		name := strings.TrimSuffix(filepath.Base(file), ".schema.haus")
		src, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		cases := readCases(t, filepath.Join(suite, name+".cases.haus"))
		for _, without := range []bool{false, true} {
			s, err := schema.Parse(src, schema.Options{WithoutAttributes: without})
			if err != nil {
				t.Fatalf("%s (without attributes: %v): %v", name, without, err)
			}
			for _, c := range cases {
				count++
				label := name + ": " + c.name
				if without {
					label += " (without attributes)"
				}
				typ, err := s.Type(c.typ)
				if err != nil {
					t.Errorf("%s: %v", label, err)
					continue
				}
				out, err := typ.Decode(c.input)
				switch {
				case c.ok && err != nil:
					t.Errorf("%s: failed to decode: %v", label, err)
				case c.ok:
					if got, want := canonical(t, out), canonical(t, c.output); got != want {
						t.Errorf("%s: decoded as %s, expected %s", label, got, want)
					}
					// Encoding the result gives it back, and decoding is idempotent.
					enc, err := typ.Encode(out)
					if err != nil {
						t.Errorf("%s: encoding the result: %v", label, err)
					} else if canonical(t, enc) != canonical(t, out) {
						t.Errorf("%s: encoded as %s", label, canonical(t, enc))
					}
					if _, err := haus.FormatValue(out, haus.DefaultFormatOptions()); err != nil {
						t.Errorf("%s: decoded, but can't be written: %v", label, err)
					}
				case err == nil:
					t.Errorf("%s: decoded as %s, expected %s", label, canonical(t, out), c.code)
				default:
					code, path := codeAndPath(err)
					if string(code) != c.code || path != c.path {
						t.Errorf("%s: failed with %s at %s (%v), expected %s at %s", label, code, path, err, c.code, c.path)
					}
					// Encoding fails alike.
					if _, eerr := typ.Encode(c.input); eerr == nil {
						t.Errorf("%s: encodes", label)
					} else if ecode, epath := codeAndPath(eerr); ecode != code || epath != path {
						t.Errorf("%s: encoding fails with %s at %s, decoding with %s at %s", label, ecode, epath, code, path)
					}
				}
			}
		}
	}
	t.Logf("schema suite: %d cases (each schema with and without its attributes)", count)
}

// TestTypedStreamSuite runs test-suite/stream/typed.cases.haus (spec §15,
// "Streams"): a Stream type decodes with Type.DecodeStream, whose errors
// carry the item's index; any other type with Type.Parse, one document.
// The decoded values are encoded and compared with output.
func TestTypedStreamSuite(t *testing.T) {
	dir := filepath.Join(suite, "..", "stream")
	src, err := os.ReadFile(filepath.Join(dir, "typed.schema.haus"))
	if err != nil {
		t.Fatal(err)
	}
	s, err := schema.Parse(src, schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	text, err := os.ReadFile(filepath.Join(dir, "typed.cases.haus"))
	if err != nil {
		t.Fatal(err)
	}
	values, err := haus.ParseAll(text)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%d cases", len(values))
	if len(values) == 0 {
		t.Fatal("no cases")
	}
	for _, v := range values {
		x, ok := v.(haus.Variant)
		if !ok || x.Tag.String() != "Ok" && x.Tag.String() != "Err" || len(x.Args) != 1 {
			t.Fatalf("not a case: %v", v)
		}
		r := x.Args[0].(haus.Record)
		data := str(get(r, "text"))
		want := "Err " + str(get(r, "code")) + " at " + str(get(r, "path"))
		if x.Tag.String() == "Ok" {
			want = "Ok " + canonical(t, get(r, "output"))
		}
		typ, err := s.Type(str(get(r, "type")))
		if err != nil {
			t.Fatal(err)
		}
		got, err := decodeText(t, typ, []byte(data))
		if got != want {
			t.Errorf("%s %q: got %s (%v), want %s", typ.Name(), data, got, err, want)
		}
	}
}

// decodeText decodes a text with the type and encodes the result: "Ok"
// and its canonical form (an array of the items for a stream), or "Err",
// the code and the path.
func decodeText(t *testing.T, typ schema.Type, data []byte) (string, error) {
	t.Helper()
	fail := func(err error) (string, error) {
		code, path := codeAndPath(err)
		return "Err " + string(code) + " at " + path, err
	}
	if !typ.IsStream() {
		v, err := typ.Parse(data)
		if err != nil {
			return fail(err)
		}
		enc, err := typ.Encode(v)
		if err != nil {
			return fail(err)
		}
		return "Ok " + canonical(t, enc), nil
	}
	out := haus.Array{}
	for v, err := range typ.DecodeStream(bytes.NewReader(data), haus.StreamOptions{}) {
		if err != nil {
			return fail(err)
		}
		enc, err := typ.Encode(v)
		if err != nil {
			return fail(err)
		}
		out = append(out, enc)
	}
	return "Ok " + canonical(t, out), nil
}

// TestInvalidSchemas: every schema in test-suite/schema/invalid is rejected
// with the code in its .error file.
func TestInvalidSchemas(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(suite, "invalid", "*.schema.haus"))
	if len(files) == 0 {
		t.Fatal("no invalid schemas")
	}
	for _, file := range files {
		want, err := os.ReadFile(strings.TrimSuffix(file, ".schema.haus") + ".error")
		if err != nil {
			t.Fatal(err)
		}
		src, _ := os.ReadFile(file)
		_, err = schema.Parse(src, schema.Options{})
		code, _ := codeAndPath(err)
		if err == nil || string(code) != strings.TrimSpace(string(want)) {
			t.Errorf("%s: got %v, want %s", filepath.Base(file), err, strings.TrimSpace(string(want)))
		}
	}
	t.Logf("invalid schemas: %d", len(files))
}
