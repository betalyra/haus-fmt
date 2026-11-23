package schema_test

import (
	"fmt"
	"slices"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

// issueSet is the issues as sorted "severity code path" lines: a set, as
// spec §14 ("Every error") specifies which issues, not their order.
func issueSet(r schema.CheckResult) []string {
	out := make([]string, len(r.Issues))
	for i, is := range r.Issues {
		out[i] = fmt.Sprintf("%s %s %s", is.Severity, is.Code, is.Path)
	}
	slices.Sort(out)
	return out
}

func errorCount(r schema.CheckResult) int {
	n := 0
	for _, is := range r.Issues {
		if is.Severity == schema.SeverityError {
			n++
		}
	}
	return n
}

func checkResult(t *testing.T, src, data string, opts schema.CheckOptions) schema.CheckResult {
	t.Helper()
	s, err := schema.Parse([]byte(src), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return s.CheckTextResult("Root", []byte(data), opts)
}

// The multi-error Data cases added to test-suite/check/cases.haus for spec
// §14, "Every error".
var everyErrorCases = []struct {
	schema, data string
	issues       []string
}{
	{"type Root = { a: Int, b: String, c: Bool }", `{ a: "x", b: 1, c: True }`,
		[]string{"error type-mismatch $.a", "error type-mismatch $.b"}},
	{"type Root = closed { a: Int, b: Int }", `{ a: "x", z: 1 }`,
		[]string{"error missing-field $", "error type-mismatch $.a", "error unknown-field $.z"}},
	{"type Root = { items: Array { id: Int } }", `{ items: { id: "x" } }`,
		[]string{"error type-mismatch $.items"}},
	{"type Root = Array Int8", `[1, 300, "x", -200]`,
		[]string{"error out-of-range $[1]", "error type-mismatch $[2]", "error out-of-range $[3]"}},
	{"type Root = Map Int", `{ a: "x", b: 2, c: "y" }`,
		[]string{"error type-mismatch $.a", "error type-mismatch $.c"}},
	{"type Root = closed < A { x: Int } >", `B { x: "y" }`, []string{"error unknown-tag $"}},
	{"type Root = Array (closed < P { x: Int } | Q >)", `[P { x: "a" }, P { x: 1 }, Q(1), P { x: "b" }]`,
		[]string{"error type-mismatch $[0].x", "error wrong-payload $[2]", "error type-mismatch $[3].x"}},
	{"type Root = { k: Secret { a: Int, b: Int }, n: Int }", `{ k: { a: "x", b: "y" }, n: "z" }`,
		[]string{"error invalid-secret $.k", "error type-mismatch $.n"}},
	{"type Root = { name: String, n: Int }", `{ nmae: "a", n: "x" }`,
		[]string{"error missing-field $", "hint unlisted-field $.nmae", "error type-mismatch $.n"}},
}

func TestEveryErrorAndTheFirst(t *testing.T) {
	for _, c := range everyErrorCases {
		all := checkResult(t, c.schema, c.data, schema.CheckOptions{})
		want := slices.Clone(c.issues)
		slices.Sort(want)
		if got := issueSet(all); !slices.Equal(got, want) || all.Stopped {
			t.Errorf("%s / %s: got %v (stopped %v), want %v", c.schema, c.data, got, all.Stopped, want)
		}
		// First: one error, of the full set, with only hints besides.
		first := checkResult(t, c.schema, c.data, schema.CheckOptions{First: true})
		if errorCount(first) != 1 {
			t.Errorf("%s: --first gave %v", c.data, first.Issues)
		}
		for _, is := range issueSet(first) {
			if !slices.Contains(want, is) {
				t.Errorf("%s: %s is not in the full set", c.data, is)
			}
		}
	}
}

func TestFirstKeepsTheHintsBeforeItsError(t *testing.T) {
	r := checkResult(t, "type Root = { a: Int, b: Int }", `{ zz: 1, a: "x", yy: 2, b: "y" }`, schema.CheckOptions{First: true})
	want := []string{"error type-mismatch $.a", "hint unlisted-field $.zz"}
	if got := issueSet(r); !slices.Equal(got, want) {
		t.Errorf("got %v", got)
	}
}

func TestASyntaxErrorIsTheOnlyError(t *testing.T) {
	for _, first := range []bool{false, true} {
		r := checkResult(t, "type Root = { a: Int }", `{ a: "x", b: [ }`, schema.CheckOptions{First: first})
		if len(r.Issues) != 1 || r.Issues[0].Code != haus.CodeExpectedValue || r.Issues[0].Line != 1 {
			t.Errorf("got %v", r.Issues)
		}
	}
}

func TestSaysWhenItStoppedAtTheCap(t *testing.T) {
	items := func(n int) string { return "[" + strings.Repeat(`"x", `, n-1) + `"x"]` }
	exactly := checkResult(t, "type Root = Array Int", items(schema.MaxIssues), schema.CheckOptions{})
	if len(exactly.Issues) != schema.MaxIssues || exactly.Stopped {
		t.Errorf("exactly the cap: %d issues, stopped %v", len(exactly.Issues), exactly.Stopped)
	}
	more := checkResult(t, "type Root = Array Int", items(schema.MaxIssues+1), schema.CheckOptions{})
	if len(more.Issues) != schema.MaxIssues || !more.Stopped || more.OK() {
		t.Errorf("past the cap: %d issues, stopped %v", len(more.Issues), more.Stopped)
	}
	s, _ := schema.Parse([]byte("type Root = Array Int"), schema.Options{})
	values, _ := haus.ParseAll([]byte(items(schema.MaxIssues + 1)))
	if r := s.CheckValues("Root", values, schema.CheckOptions{}); !r.Stopped || len(r.Issues) != schema.MaxIssues {
		t.Errorf("values: %d issues, stopped %v", len(r.Issues), r.Stopped)
	}
}
