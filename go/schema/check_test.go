package schema_test

import (
	"fmt"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

const checkSchema = `type Line = closed { sku: String, qty: Int32, @deprecated("use qty") count?: Int32 }
type Shape = < Circle { r: Float64 } | Point Float64 Float64 | @deprecated Old >
type Root = {
  lines: Array Line,
  shape: Shape,
  key: Secret { token: String },
  when: Maybe Date,
  quantity?: Int32,
}
type Lines = Stream Line
import std/time (Date)
`

func issues(is []schema.Issue) string {
	var b strings.Builder
	for _, i := range is {
		fmt.Fprintf(&b, "%d:%d %s %s %s | %s\n", i.Line, i.Column, i.Severity, i.Path, i.Code, i.Message)
	}
	return b.String()
}

// TestCheckText checks every issue of a file, as rust's haus check reports
// them (haus-schema's check_text). A deprecated field's hint is at the
// field's value and a deprecated tag's at the tagged value, as
// unlisted-field is (spec §14).
func TestCheckText(t *testing.T) {
	s, err := schema.Parse([]byte(checkSchema), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	data := `{
  lines: [
    { sku: "a", qty: "1", count: 2 },
    { sku: "b", qyt: 3 },
  ],
  shape: Point(1),
  key: { token: 5 },
  when: Some(Date("2026-02-30")),
  quantty: 1,
}
`
	want := `3:22 error $.lines[0].qty type-mismatch | expected Int32, found the string "1"
3:27 hint $.lines[0].count deprecated | count is deprecated: use qty
4:5 error $.lines[1] missing-field | missing field qty
4:17 error $.lines[1].qyt unknown-field | qyt is not a field of this closed record. Did you mean qty?
6:10 error $.shape wrong-payload | Point takes 2 arguments (Float64, Float64), found 1
7:8 error $.key invalid-secret | expected a record (a Secret: the value is not shown)
8:19 error $.when[0][0] invalid-time | "2026-02-30" is not a valid Date: 2026-02 has no day 30
9:3 hint $.quantty unlisted-field | quantty is not in the schema; a reader ignores it. Did you mean quantity?
`
	if got := issues(s.CheckText("Root", []byte(data))); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	// Nothing of a secret shows: not its value, not a key, not a hint.
	got := issues(s.CheckText("Root", []byte(`{ lines: [], shape: Old, key: { token: "sk-1", tokn: "sk-2" }, when: None }`)))
	if want := "1:21 hint $.shape deprecated | Old is deprecated\n"; got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	if strings.Contains(got, "sk-") || strings.Contains(got, "tokn") {
		t.Errorf("the secret shows: %s", got)
	}
}

func TestCheckStreamsAndSyntax(t *testing.T) {
	s, err := schema.Parse([]byte(checkSchema), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	got := issues(s.CheckText("Lines", []byte("{ sku: \"a\", qty: 1 },\n{ sku: 2, qty: 1 },\n{ qty: 1 },\n")))
	want := "2:8 error $[1].sku type-mismatch | expected String, found the number 2\n3:1 error $[2] missing-field | missing field sku\n"
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	got = issues(s.CheckText("Root", []byte("{ a: 1 }\n{ b: 2 }")))
	if want := "2:1 error  missing-comma | "; !strings.HasPrefix(got, want) {
		t.Errorf("syntax: got %s", got)
	}
	got = issues(s.CheckText("Line", []byte("{ sku: \"a\", qty: 1 },\n{ sku: \"b\", qty: 1 },\n")))
	if want := "2:1 error $ not-one-value | expected one value (Line is not a Stream), found 2\n"; got != want {
		t.Errorf("got %s", got)
	}
	got = issues(s.CheckText("Line", nil))
	if want := "1:1 error $ not-one-value | expected one value (Line is not a Stream), found 0\n"; got != want {
		t.Errorf("got %s", got)
	}
	// Without text: the same issues, without positions.
	v, _ := haus.Parse([]byte(`{ sku: 1, qty: 1 }`))
	if got := issues(s.Check("Line", []haus.Value{v})); got != "0:0 error $.sku type-mismatch | expected String, found the number 1\n" {
		t.Errorf("got %s", got)
	}
	// At most MaxIssues.
	var many strings.Builder
	for range 300 {
		many.WriteString("{ sku: 1, qty: 1 },\n")
	}
	if n := len(s.CheckText("Lines", []byte(many.String()))); n != schema.MaxIssues {
		t.Errorf("%d issues", n)
	}
}
