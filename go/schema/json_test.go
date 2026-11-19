package schema_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"

	haus "github.com/betalyra/haus-fmt/go"
	"github.com/betalyra/haus-fmt/go/schema"
)

const jsonSuite = "../../test-suite/json"

// sameJSON compares two JSON texts as data: member order and whitespace
// don't matter, numbers compare by their text.
func sameJSON(t *testing.T, got []byte, want string) bool {
	t.Helper()
	decode := func(b []byte) any {
		d := json.NewDecoder(bytes.NewReader(b))
		d.UseNumber()
		var x any
		if err := d.Decode(&x); err != nil {
			t.Fatalf("not JSON: %s: %v", b, err)
		}
		return x
	}
	return reflect.DeepEqual(decode(got), decode([]byte(want)))
}

func loadJSONSuite(t *testing.T, opts schema.Options) *schema.Schema {
	t.Helper()
	s, err := schema.Load(jsonSuite+"/schema-based.schema.haus", opts)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// TestSchemaJSONSuite runs test-suite/json/schema-based.cases.haus, on the
// schema as written and without its attributes.
func TestSchemaJSONSuite(t *testing.T) {
	src, err := os.ReadFile(jsonSuite + "/schema-based.cases.haus")
	if err != nil {
		t.Fatal(err)
	}
	cases, err := haus.ParseAll(src)
	if err != nil {
		t.Fatal(err)
	}
	for _, without := range []bool{false, true} {
		s := loadJSONSuite(t, schema.Options{WithoutAttributes: without})
		counts := map[string]int{}
		for _, v := range cases {
			x := v.(haus.Variant)
			r := x.Args[0].(haus.Record)
			ty, err := s.Type(str(get(r, "type")))
			if err != nil {
				t.Fatal(err)
			}
			text := str(get(r, "json"))
			name := x.Tag + " " + ty.Name() + " " + shortCase(text)
			counts[x.Tag]++
			got, readErr := ty.FromJSON([]byte(text))
			switch x.Tag {
			case "Ok":
				input := get(r, "input")
				decoded, err := ty.Decode(input)
				if err != nil {
					t.Errorf("%s: decode input: %v", name, err)
					continue
				}
				written, err := ty.ToJSON(decoded)
				if err != nil {
					t.Errorf("%s: write: %v", name, err)
				} else if !sameJSON(t, written, text) {
					t.Errorf("%s: wrote %s", name, written)
				}
				want := get(r, "output")
				if want == nil {
					want = input
				}
				checkRead(t, name, ty, got, readErr, want)
			case "Read":
				checkRead(t, name, ty, got, readErr, get(r, "output"))
			case "Err":
				if code, _ := codeAndPath(readErr); string(code) != str(get(r, "code")) {
					t.Errorf("%s: got %v, want %s", name, readErr, str(get(r, "code")))
				}
			default:
				t.Fatalf("unknown case %s", x.Tag)
			}
		}
		if !without {
			t.Logf("schema-based JSON: %d Ok, %d Read, %d Err", counts["Ok"], counts["Read"], counts["Err"])
		}
	}
}

func checkRead(t *testing.T, name string, ty schema.Type, got haus.Value, err error, want haus.Value) {
	t.Helper()
	if err != nil {
		t.Errorf("%s: read: %v", name, err)
		return
	}
	// The value read is a decoded value: encoding gives it back.
	encoded, err := ty.Encode(got)
	if err != nil {
		t.Errorf("%s: encode what was read: %v", name, err)
		return
	}
	if !haus.Equals(encoded, want) {
		t.Errorf("%s: read %s, want %s", name, canonical(t, encoded), canonical(t, want))
	}
}

func shortCase(s string) string {
	if len(s) > 60 {
		return s[:60] + "…"
	}
	return s
}

func TestNoJSONFormWarning(t *testing.T) {
	s, err := schema.Parse([]byte(`type Odd = < Odd { _tag: Int32 } | Fine { a: Int32 } >
type Rec = { _args: Int32 }
type Named = < N Rec >
type Nested = { items: Array (< In { _tag: String } >) }
`), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, w := range s.Warnings() {
		if w.Code == haus.CodeNoJSONForm {
			got = append(got, w.Error())
		}
	}
	want := []string{
		"1:14: Odd has a field named _tag, so it has no schema-based JSON form [no-json-form]",
		"3:16: N has a field named _args, so it has no schema-based JSON form [no-json-form]",
		"4:33: In has a field named _tag, so it has no schema-based JSON form [no-json-form]",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("got\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	// The schema is valid; converters fail on values of the case only.
	odd, _ := s.Type("Odd")
	v, _ := haus.Parse([]byte(`Odd { _tag: 1 }`))
	if _, err := odd.ToJSON(v); errCode(err) != haus.CodeNoJSONForm {
		t.Errorf("write: %v", err)
	}
	if _, err := odd.FromJSON([]byte(`{"_tag": "Odd"}`)); errCode(err) != haus.CodeNoJSONForm {
		t.Errorf("read: %v", err)
	}
	fine, err := odd.FromJSON([]byte(`{"_tag": "Fine", "a": 1}`))
	if err != nil || canonical(t, fine) != "Fine{a:1}" {
		t.Errorf("Fine: %v %v", fine, err)
	}
}

func errCode(err error) haus.ErrorCode {
	code, _ := codeAndPath(err)
	return code
}

func TestSchemaJSONPathsAndLines(t *testing.T) {
	s, err := schema.Parse([]byte(`
type Line = { sku: String, price: Decimal, key?: Secret String }
type Order = { items: Array Line, tags: Map Int32, maybe?: Maybe (Maybe Int32) }
type Event = < Log { msg: String } | Tick Int32 >
type Events = Stream Event
`), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	order, _ := s.Type("Order")
	tests := []struct {
		json, code, path string
	}{
		{`{"items": [{"sku": "a", "price": "1"}, {"sku": "b", "price": 1}], "tags": {}}`, "type-mismatch", "$.items[1].price"},
		{`{"items": [], "tags": {"pt-BR": "x"}}`, "type-mismatch", `$.tags["pt-BR"]`},
		{`{"items": [], "tags": {}, "maybe": {"_tag": "Some", "value": "x"}}`, "type-mismatch", "$.maybe.value"},
		{`{"items": [{"sku": "a", "price": "1", "key": 7}], "tags": {}}`, "invalid-secret", "$.items[0].key"},
	}
	for _, tt := range tests {
		_, err := order.FromJSON([]byte(tt.json))
		var e *haus.Error
		if !errors.As(err, &e) || string(e.Code) != tt.code || e.Path != tt.path {
			t.Errorf("%s: got %v", tt.json, err)
		}
		if tt.code == "invalid-secret" && strings.Contains(e.Message, "7") {
			t.Errorf("the secret shows in %q", e.Message)
		}
	}
	events, _ := s.Type("Events")
	values, err := events.FromJSONLines([]byte("{\"_tag\":\"Log\",\"msg\":\"hi\"}\r\n{\"_tag\":\"Tick\",\"value\":3}\n"))
	if err != nil || len(values) != 2 || canonical(t, values[1]) != "Tick(3)" {
		t.Fatalf("lines: %v %v", values, err)
	}
	out, err := events.ToJSONLines(values)
	if err != nil || string(out) != "{\"_tag\":\"Log\",\"msg\":\"hi\"}\n{\"_tag\":\"Tick\",\"value\":3}\n" {
		t.Errorf("write lines: %s %v", out, err)
	}
	_, err = events.FromJSONLines([]byte("{\"_tag\":\"Log\",\"msg\":\"hi\"}\n{\"_tag\":\"Tick\",\"value\":\"3\"}\n"))
	if code, path := codeAndPath(err); code != haus.CodeTypeMismatch || path != "$[1].value" {
		t.Errorf("line error: %v", err)
	}
}

func TestSchemaJSONLimits(t *testing.T) {
	s, err := schema.Parse([]byte(`
type Deep = Maybe (Array (Maybe (Array Int32)))
type Text = { s: String, b: Bytes }
type Open = < A >
`), schema.Options{})
	if err != nil {
		t.Fatal(err)
	}
	deep, _ := s.Type("Deep")
	// [[1]] is four haus levels: Some([Some([1])]).
	opts := schema.DecodeOptions{Limits: haus.Limits{MaxDepth: 3}}
	if _, err := deep.FromJSONWith([]byte(`[[1]]`), opts); errCode(err) != haus.CodeNestingTooDeep {
		t.Errorf("deep: %v", err)
	}
	if _, err := deep.FromJSONWith([]byte(`[null]`), opts); err != nil {
		t.Errorf("shallow: %v", err)
	}
	text, _ := s.Type("Text")
	small := schema.DecodeOptions{Limits: haus.Limits{MaxStringLength: 4}}
	if _, err := text.FromJSONWith([]byte(`{"s": "éééé", "b": "AAE="}`), small); err != nil {
		t.Errorf("within limits: %v", err)
	}
	if _, err := text.FromJSONWith([]byte(`{"s": "", "b": "AAEC"}`), small); errCode(err) != haus.CodeStringTooLong {
		t.Errorf("3 bytes are 6 characters: %v", err)
	}
	open, _ := s.Type("Open")
	v, err := open.FromJSON([]byte(`{"_tag": "B", "x": {"y": [1, null]}}`))
	if err != nil || canonical(t, v) != "B{x:{y:[1,None]}}" {
		t.Errorf("unknown: %v %v", v, err)
	}
	if _, err := open.FromJSONWith([]byte(`{"_tag": "B", "x": {"y": [1]}}`), schema.DecodeOptions{Limits: haus.Limits{MaxDepth: 2}}); errCode(err) != haus.CodeNestingTooDeep {
		t.Errorf("unknown, deep: %v", err)
	}
}
