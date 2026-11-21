package haus_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"regexp"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/internal/errorcodes"
)

func catalogue(t *testing.T) []byte {
	t.Helper()
	src, err := os.ReadFile("../spec/errors.haus")
	if err != nil {
		t.Fatal(err)
	}
	return src
}

// TestErrorCodesUpToDate: error_codes.go is what the generator makes of
// spec/errors.haus.
func TestErrorCodesUpToDate(t *testing.T) {
	want, err := errorcodes.Generate(catalogue(t))
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile("error_codes.go")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Error("error_codes.go is out of date: run `go generate` in go/")
	}
}

// TestCodesUsedAreInCatalogue: every Code… constant the package's source
// uses is one the generator made, and its value is a valid code.
func TestCodesUsedAreInCatalogue(t *testing.T) {
	codeRe := regexp.MustCompile(`^[a-z][a-z0-9]*(-[a-z0-9]+)*$`)
	known := map[haus.ErrorCode]bool{}
	for _, c := range haus.ErrorCodes() {
		if !codeRe.MatchString(string(c)) {
			t.Errorf("%q is not a valid code", c)
		}
		if _, ok := c.Info(); !ok {
			t.Errorf("%s has no catalogue entry", c)
		}
		known[c] = true
	}
	entries, err := errorcodes.Read(catalogue(t))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != len(known) {
		t.Errorf("%d codes in the catalogue, %d in Go", len(entries), len(known))
	}
	// Any literal code in the source (not through a constant) would show up
	// as a string literal of kebab-case words: there must be none.
	files, _ := os.ReadDir(".")
	literal := regexp.MustCompile(`Code:\s*"`)
	for _, f := range files {
		if f.IsDir() || f.Name() == "error_codes.go" {
			continue
		}
		b, _ := os.ReadFile(f.Name())
		if literal.Match(b) {
			t.Errorf("%s sets a code from a string literal", f.Name())
		}
	}
}

// TestCatalogueExamples: each Data example of the catalogue fails to parse
// with its code (as the TypeScript tests check).
func TestCatalogueExamples(t *testing.T) {
	values, err := haus.ParseAll(catalogue(t))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, v := range values {
		rec := v.(haus.Variant).Args[0].(haus.Record)
		code, _ := rec.Get("code")
		ex, _ := rec.Get("example")
		example := ex.(haus.Variant)
		if example.Tag.String() != "Data" {
			continue
		}
		n++
		text := string(example.Args[0].(haus.String))
		_, err := haus.ParseAll([]byte(text))
		var e *haus.Error
		if !errors.As(err, &e) || string(e.Code) != string(code.(haus.String)) {
			t.Errorf("%s: %q gives %v", code, text, err)
		}
	}
	if n < 25 {
		t.Errorf("only %d Data examples", n)
	}
}

func TestErrorJSON(t *testing.T) {
	_, err := haus.ParseAll([]byte("Heartbeat\n{ at: 1 }"))
	var e *haus.Error
	if !errors.As(err, &e) {
		t.Fatal(err)
	}
	b, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"code": "payload-newline", "line": 2.0, "column": 1.0,
		"expected": "','", "found": "'{'",
		"hint": "Put the payload on the tag's line, or add a comma if they are two values.",
		"docs": "https://haus-fmt.org/docs/errors#payload-newline",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: got %v, want %v", k, got[k], v)
		}
	}
	if _, ok := got["message"].(string); !ok {
		t.Error("no message")
	}
	if _, ok := got["path"]; ok {
		t.Error("a path for an error in text")
	}
	// An error without a place in text has no line or column.
	_, err = haus.ParseWith([]byte("1"), haus.Limits{MaxDepth: haus.MaxSupportedDepth + 1})
	b, _ = json.Marshal(err)
	var notOne map[string]any
	_ = json.Unmarshal(b, &notOne)
	if notOne["code"] != "unsupported-depth" || notOne["line"] != nil {
		t.Errorf("%s", b)
	}
}
