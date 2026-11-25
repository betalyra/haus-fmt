package schema_test

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// showEntry writes Tag(a, b, …) as "Tag a b …", strings and numbers as
// their text.
func showEntry(t *testing.T, v haus.Value) string {
	t.Helper()
	x, ok := v.(haus.Variant)
	if !ok {
		t.Fatalf("not an entry: %v", v)
	}
	parts := []string{x.Tag.String()}
	for _, a := range x.Args {
		switch a := a.(type) {
		case haus.String:
			parts = append(parts, string(a))
		case haus.Number:
			parts = append(parts, a.String())
		default:
			parts = append(parts, canonical(t, a))
		}
	}
	return strings.Join(parts, " ")
}

func showEntries(t *testing.T, v haus.Value) []string {
	t.Helper()
	a, ok := v.(haus.Array)
	if !ok {
		t.Fatalf("not an array: %v", v)
	}
	out := []string{}
	for _, e := range a {
		out = append(out, showEntry(t, e))
	}
	return out
}

// TestCheckSuite runs test-suite/check/cases.haus (spec §14, §15, §16): the
// warnings of schema files (Schema.Warnings), and the hints and errors of
// checking data text (Schema.CheckTextResult, every error or the first),
// each compared as a multiset of (code, place).
func TestCheckSuite(t *testing.T) {
	src, err := os.ReadFile(filepath.Join(suite, "..", "check", "cases.haus"))
	if err != nil {
		t.Fatal(err)
	}
	values, err := haus.ParseAll(src)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("%d cases", len(values))
	if len(values) == 0 {
		t.Fatal("no cases")
	}
	for _, v := range values {
		x, ok := v.(haus.Variant)
		if !ok || x.Tag.String() != "Schema" && x.Tag.String() != "Data" || len(x.Args) != 1 {
			t.Fatalf("not a case: %v", v)
		}
		r := x.Args[0].(haus.Record)
		text := str(get(r, "schema"))
		s, err := schema.Parse([]byte(text), schema.Options{})
		if err != nil {
			t.Errorf("%q: %v", text, err)
			continue
		}
		var got, want []string
		var name string
		switch x.Tag.String() {
		case "Schema":
			name = fmt.Sprintf("schema %q", text)
			want = showEntries(t, get(r, "warnings"))
			got = []string{}
			for _, w := range s.Warnings() {
				got = append(got, fmt.Sprintf("Warning %s %d %d", w.Code, w.Line, w.Column))
			}
		case "Data":
			typ, data := str(get(r, "type")), str(get(r, "data"))
			name = fmt.Sprintf("data %q as %s of %q", data, typ, text)
			want = showEntries(t, get(r, "issues"))
			first := false
			if f, ok := r.Get("first"); ok {
				first = f.(haus.Variant).Tag.String() == "True"
				name += " (first)"
			}
			result := s.CheckTextResult(typ, []byte(data), schema.CheckOptions{First: first})
			got = []string{}
			for _, i := range result.Issues {
				switch {
				case i.Path == "": // a syntax or limit error of the text
					got = append(got, fmt.Sprintf("Syntax %s %d %d", i.Code, i.Line, i.Column))
				case i.Severity == schema.SeverityHint:
					got = append(got, fmt.Sprintf("Hint %s %s", i.Code, i.Path))
				default:
					got = append(got, fmt.Sprintf("Error %s %s", i.Code, i.Path))
				}
			}
		}
		// Multisets of (code, place): no order (spec §14), each as often as listed.
		slices.Sort(got)
		slices.Sort(want)
		if !slices.Equal(got, want) {
			t.Errorf("%s:\n got %q\nwant %q", name, got, want)
		}
	}
}
